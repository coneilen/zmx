const builtin = @import("builtin");
const std = @import("std");
const events = @import("events.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("events_windows requires a Windows target");
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;
const create_event_manual_reset: windows.DWORD = 1;
const event_modify_state: windows.DWORD = 2;
const synchronize: windows.DWORD = 0x0010_0000;
const wait_object_0: windows.DWORD = 0;
const infinite: windows.DWORD = 0xffff_ffff;
const wait_timeout: windows.DWORD = 0x102;
const wait_abandoned_0: windows.DWORD = 0x80;
const max_wait_objects: usize = 64;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(
    handle: windows.HANDLE,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForMultipleObjectsEx(
    count: windows.DWORD,
    handles: [*]const windows.HANDLE,
    wait_all: c_int,
    milliseconds: windows.DWORD,
    alertable: c_int,
) callconv(.winapi) windows.DWORD;

fn monotonicNs() i128 {
    return @as(i128, @intCast(GetTickCount64())) * std.time.ns_per_ms;
}

extern "kernel32" fn SetEvent(handle: windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn ResetEvent(handle: windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn CreateEventExW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    name: ?windows.LPCWSTR,
    flags: windows.DWORD,
    desired_access: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

pub const Deadline = struct {
    end_ns: i128,

    pub fn afterMs(milliseconds: u64) Deadline {
        const now = monotonicNs();
        const delta = @as(i128, @intCast(milliseconds)) * std.time.ns_per_ms;
        return .{ .end_ns = if (std.math.maxInt(i128) - now < delta)
            std.math.maxInt(i128)
        else
            now + delta };
    }

    pub fn remainingMs(self: Deadline) ?u32 {
        const remaining = self.end_ns - monotonicNs();
        if (remaining <= 0) return 0;
        const ms = @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, @as(i128, std.math.maxInt(u32))));
    }
};

pub const Cancellation = struct {
    handle: windows.HANDLE,

    pub fn init() !Cancellation {
        const handle = CreateEventExW(
            null,
            null,
            create_event_manual_reset,
            event_modify_state | synchronize,
        ) orelse return error.SystemResources;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Cancellation) void {
        windows.CloseHandle(self.handle);
        self.handle = undefined;
    }

    pub fn cancel(self: Cancellation) !void {
        if (SetEvent(self.handle) == 0) return error.Unexpected;
    }

    pub fn reset(self: Cancellation) !void {
        if (ResetEvent(self.handle) == 0) return error.Unexpected;
    }

    pub fn isCancelled(self: Cancellation) bool {
        return WaitForSingleObject(self.handle, 0) == wait_object_0;
    }

    pub fn contract(self: *Cancellation) events.Cancellation {
        return .{
            .context = self,
            .is_cancelled_fn = isCancelledThunk,
            .reset_fn = resetThunk,
        };
    }

    fn isCancelledThunk(context: *anyopaque) bool {
        const self: *Cancellation = @ptrCast(@alignCast(context));
        return self.isCancelled();
    }

    fn resetThunk(context: *anyopaque) void {
        const self: *Cancellation = @ptrCast(@alignCast(context));
        self.reset() catch {};
    }
};

pub const Waiter = struct {
    cancellation: ?*Cancellation = null,

    pub fn wait(self: *Waiter, watches: []const events.Watch, timeout_ms: ?u32) events.Error!events.Result {
        if (watches.len == 0) return error.InvalidHandle;
        if (watches.len > max_wait_objects or
            (self.cancellation != null and watches.len == max_wait_objects))
            return error.SystemResources;

        var handles: [max_wait_objects]windows.HANDLE = undefined;
        for (watches, 0..) |watch, i| {
            if (watch.handle == 0) return error.InvalidHandle;
            handles[i] = @ptrFromInt(watch.handle);
        }
        const watch_count = watches.len;
        if (self.cancellation) |cancel| {
            handles[watch_count] = cancel.handle;
        }
        const handle_count = watch_count + @intFromBool(self.cancellation != null);
        const timeout = timeout_ms orelse infinite;
        const result = WaitForMultipleObjectsEx(
            @intCast(handle_count),
            &handles,
            0,
            timeout,
            0,
        );
        if (result == wait_timeout) return error.Timeout;
        if (result >= wait_abandoned_0 and result < wait_abandoned_0 + @as(windows.DWORD, @intCast(handle_count))) {
            return error.Cancelled;
        }
        if (result == watch_count and self.cancellation != null) return error.Cancelled;
        if (result >= @as(windows.DWORD, @intCast(watch_count))) return error.InvalidHandle;
        return .{
            .index = @intCast(result),
            .ready = .{ .read = true },
        };
    }

    pub fn waiter(self: *Waiter) events.Waiter {
        return .{
            .context = self,
            .wait_fn = waitThunk,
        };
    }

    fn waitThunk(
        context: *anyopaque,
        watches: []const events.Watch,
        timeout_ms: ?u32,
    ) events.Error!events.Result {
        const self: *Waiter = @ptrCast(@alignCast(context));
        return self.wait(watches, timeout_ms);
    }
};

pub fn waitUntil(
    waiter: *Waiter,
    watches: []const events.Watch,
    deadline: Deadline,
) events.Error!events.Result {
    return waiter.wait(watches, deadline.remainingMs());
}

test "Windows deadlines are cumulative and expire at zero" {
    const deadline = Deadline.afterMs(1);
    try std.testing.expect((deadline.remainingMs() orelse 0) <= 1);
    // Windows timer resolution can undershoot a two millisecond sleep.
    Sleep(20);
    try std.testing.expectEqual(@as(?u32, 0), deadline.remainingMs());
}

test "Windows cancellation wakes a wait without consuming the watched event" {
    var watched = try Cancellation.init();
    defer watched.deinit();
    var cancelled = try Cancellation.init();
    defer cancelled.deinit();

    var waiter = Waiter{ .cancellation = &cancelled };
    const watches = [_]events.Watch{.{
        .handle = @intFromPtr(watched.handle),
        .interest = .{ .read = true },
    }};
    try cancelled.cancel();
    try std.testing.expectError(error.Cancelled, waiter.wait(&watches, 1000));
    try cancelled.reset();
    try watched.cancel();
    const result = try waiter.wait(&watches, 1000);
    try std.testing.expectEqual(@as(usize, 0), result.index);
    try std.testing.expect(result.ready.read);
}
