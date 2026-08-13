const builtin = @import("builtin");
const std = @import("std");
const local_ipc = @import("local_ipc.zig");
const events_windows = @import("events_windows.zig");
const runtime_windows = @import("runtime_windows.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("local_ipc_windows requires a Windows target");
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    string_security_descriptor: windows.LPCWSTR,
    string_sd_revision: windows.DWORD,
    security_descriptor: *?*anyopaque,
    security_descriptor_size: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ConnectNamedPipe(
    pipe: windows.HANDLE,
    overlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DisconnectNamedPipe(pipe: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitNamedPipeW(
    name: windows.LPCWSTR,
    timeout_ms: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const Error = error{
    AccessDenied,
    AlreadyClosed,
    BrokenPipe,
    Cancelled,
    ConnectionRefused,
    ConnectionResetByPeer,
    InvalidEndpoint,
    NameTooLong,
    NotConnected,
    SystemResources,
    Timeout,
    Unexpected,
} || std.mem.Allocator.Error;

pub const default_timeout_ms: u32 = 1000;
pub const io_buffer_size: usize = 64 * 1024;
const first_pipe_instance: windows.DWORD = 0x0008_0000;
const reject_remote_clients: windows.DWORD = 0x0000_0008;

fn handleValue(handle: windows.HANDLE) local_ipc.Handle {
    return @intFromPtr(handle);
}

fn handleFromValue(value: local_ipc.Handle) windows.HANDLE {
    return @ptrFromInt(value);
}

fn mapLastError(err: windows.Win32Error) Error {
    return switch (err) {
        .ACCESS_DENIED => error.AccessDenied,
        .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
        .FILE_NOT_FOUND, .PIPE_BUSY, .PIPE_NOT_CONNECTED => error.ConnectionRefused,
        .INVALID_HANDLE => error.AlreadyClosed,
        .INVALID_NAME, .BAD_PATHNAME => error.InvalidEndpoint,
        .OPERATION_ABORTED => error.Cancelled,
        .PIPE_CONNECTED => error.ConnectionResetByPeer,
        else => error.Unexpected,
    };
}

fn completionEvent() Error!windows.HANDLE {
    return kernel32.CreateEventExW(
        null,
        null,
        windows.CREATE_EVENT_MANUAL_RESET,
        windows.EVENT_MODIFY_STATE | windows.SYNCHRONIZE,
    ) orelse error.SystemResources;
}

fn utf16Endpoint(alloc: std.mem.Allocator, endpoint: []const u8) Error![:0]u16 {
    if (!std.unicode.utf8ValidateSlice(endpoint)) return error.InvalidEndpoint;
    const path = if (std.mem.startsWith(u8, endpoint, "\\\\.\\pipe\\"))
        try alloc.dupe(u8, endpoint)
    else
        runtime_windows.endpointPath(alloc, endpoint) catch |err| switch (err) {
            error.InvalidSessionName => return error.InvalidEndpoint,
            error.NameTooLong => return error.NameTooLong,
            error.AccessDenied => return error.AccessDenied,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => return error.Unexpected,
        };
    defer alloc.free(path);

    const result = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidEndpoint,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (result.len >= runtime_windows.max_pipe_name_utf16) {
        alloc.free(result);
        return error.NameTooLong;
    }
    return result;
}

fn securitySddl(policy: local_ipc.AccessPolicy) []const u8 {
    return if (policy.owner_only)
        runtime_windows.securityDescriptorSddl
    else
        "D:P(A;;GA;;;WD)(A;;GA;;;SY)";
}

fn createPipe(
    alloc: std.mem.Allocator,
    name: [:0]const u16,
    policy: local_ipc.AccessPolicy,
    first: bool,
) Error!windows.HANDLE {
    const sddl_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, securitySddl(policy)) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidEndpoint,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(sddl_w);

    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        1,
        &descriptor,
        null,
    ) == windows.FALSE) {
        return error.AccessDenied;
    }
    defer _ = LocalFree(descriptor);

    var attributes = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = descriptor,
        .bInheritHandle = windows.FALSE,
    };
    var open_mode: windows.DWORD = windows.PIPE_ACCESS_DUPLEX | windows.FILE_FLAG_OVERLAPPED;
    if (first) open_mode |= first_pipe_instance;
    const pipe = kernel32.CreateNamedPipeW(
        name.ptr,
        open_mode,
        windows.PIPE_TYPE_BYTE |
            windows.PIPE_READMODE_BYTE |
            windows.PIPE_WAIT |
            reject_remote_clients,
        255,
        io_buffer_size,
        io_buffer_size,
        0,
        &attributes,
    );
    if (pipe == windows.INVALID_HANDLE_VALUE) {
        return mapLastError(windows.GetLastError());
    }
    return pipe;
}

const ServerState = struct {
    allocator: std.mem.Allocator,
    name: [:0]u16,
    policy: local_ipc.AccessPolicy,
    pipe: ?windows.HANDLE,
    closed: bool = false,
};

pub const Factory = struct {
    allocator: std.mem.Allocator,

    pub fn listener(self: *Factory) local_ipc.Listener {
        return .{
            .context = self,
            .listen_fn = listenThunk,
        };
    }

    pub fn client(self: *Factory) local_ipc.Client {
        return .{
            .context = self,
            .connect_fn = connectThunk,
        };
    }
};

pub const Adapter = Factory;

pub fn listen(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
    policy: local_ipc.AccessPolicy,
) Error!local_ipc.Server {
    const name = try utf16Endpoint(alloc, endpoint.name);
    errdefer alloc.free(name);
    const pipe = try createPipe(alloc, name, policy, true);
    errdefer windows.CloseHandle(pipe);

    const state = try alloc.create(ServerState);
    errdefer alloc.destroy(state);
    state.* = .{
        .allocator = alloc,
        .name = name,
        .policy = policy,
        .pipe = pipe,
    };
    return .{
        .handle = @intFromPtr(state),
        .accept_fn = acceptThunk,
        .close_fn = closeServerThunk,
    };
}

fn listenThunk(
    context: *anyopaque,
    endpoint: local_ipc.Endpoint,
    policy: local_ipc.AccessPolicy,
) anyerror!local_ipc.Server {
    const factory: *Factory = @ptrCast(@alignCast(context));
    return listen(factory.allocator, endpoint, policy);
}

fn connectThunk(context: *anyopaque, endpoint: local_ipc.Endpoint) anyerror!local_ipc.Connection {
    const factory: *Factory = @ptrCast(@alignCast(context));
    return connect(factory.allocator, endpoint);
}

pub fn connect(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
) Error!local_ipc.Connection {
    return connectWithDeadline(
        alloc,
        endpoint,
        events_windows.Deadline.afterMs(default_timeout_ms),
        null,
    );
}

pub fn reconnect(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
    deadline: events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    return connectWithDeadline(alloc, endpoint, deadline, cancellation);
}

/// A named-pipe endpoint has no directory entry to unlink. The kernel removes
/// it once the server's last handle is closed.
pub fn cleanupStaleEndpoint(_: []const u8) void {}

pub fn connectWithDeadline(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
    deadline: events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    const name = try utf16Endpoint(alloc, endpoint.name);
    defer alloc.free(name);

    while (true) {
        if (cancellation) |cancel| {
            if (cancel.isCancelled()) return error.Cancelled;
        }
        if (deadline.remainingMs() == 0) return error.Timeout;
        const pipe = kernel32.CreateFileW(
            name.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (pipe != windows.INVALID_HANDLE_VALUE) {
            return .{
                .handle = handleValue(pipe),
                .close_fn = closeHandle,
            };
        }

        switch (windows.GetLastError()) {
            .PIPE_BUSY => {
                const remaining = deadline.remainingMs() orelse 0;
                if (remaining == 0) return error.Timeout;
                if (cancellation) |cancel| {
                    if (cancel.isCancelled()) return error.Cancelled;
                }
                const slice = @min(remaining, @as(u32, 50));
                if (WaitNamedPipeW(name.ptr, slice) == windows.FALSE) {
                    switch (windows.GetLastError()) {
                        .SEM_TIMEOUT => {
                            if (deadline.remainingMs() == 0) return error.Timeout;
                            continue;
                        },
                        .FILE_NOT_FOUND => return error.ConnectionRefused,
                        else => |err| return mapLastError(err),
                    }
                }
            },
            .FILE_NOT_FOUND => return error.ConnectionRefused,
            else => |err| return mapLastError(err),
        }
    }
}

fn acceptThunk(value: local_ipc.Handle) anyerror!local_ipc.Connection {
    const state: *ServerState = @ptrFromInt(value);
    return acceptWithDeadline(state, null, null);
}

fn acceptWithDeadline(
    state: *ServerState,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    if (state.closed) return error.AlreadyClosed;
    const pipe = state.pipe orelse return error.AlreadyClosed;
    const event = try completionEvent();
    defer windows.CloseHandle(event);

    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = event;
    const connected = ConnectNamedPipe(pipe, &overlapped);
    if (connected == windows.FALSE) {
        switch (windows.GetLastError()) {
            .PIPE_CONNECTED => {},
            .IO_PENDING => awaitCompletion(pipe, &overlapped, event, deadline, cancellation) catch |err| {
                resetPipe(state, pipe);
                return err;
            },
            else => |err| {
                resetPipe(state, pipe);
                return mapLastError(err);
            },
        }
    }

    state.pipe = null;
    const next_pipe = createPipe(state.allocator, state.name, state.policy, false) catch |err| {
        windows.CloseHandle(pipe);
        return err;
    };
    state.pipe = next_pipe;
    return .{
        .handle = handleValue(pipe),
        .close_fn = closeHandle,
    };
}

fn resetPipe(state: *ServerState, pipe: windows.HANDLE) void {
    if (state.pipe == pipe) state.pipe = null;
    _ = DisconnectNamedPipe(pipe);
    windows.CloseHandle(pipe);
    state.pipe = createPipe(state.allocator, state.name, state.policy, false) catch null;
}

pub fn acceptServerWithDeadline(
    server: local_ipc.Server,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    const state: *ServerState = @ptrFromInt(server.handle);
    return acceptWithDeadline(state, deadline, cancellation);
}

fn awaitCompletion(
    pipe: windows.HANDLE,
    overlapped: *windows.OVERLAPPED,
    event: windows.HANDLE,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!void {
    const timeout = if (deadline) |value| value.remainingMs() orelse 0 else windows.INFINITE;
    if (timeout == 0 and deadline != null) {
        _ = kernel32.CancelIoEx(pipe, overlapped);
        _ = windows.WaitForSingleObject(event, windows.INFINITE) catch {};
        return error.Timeout;
    }

    var handles: [2]windows.HANDLE = undefined;
    handles[0] = event;
    var count: usize = 1;
    if (cancellation) |cancel| {
        handles[1] = cancel.handle;
        count = 2;
    }
    const result = windows.WaitForMultipleObjectsEx(
        handles[0..count],
        false,
        timeout,
        false,
    ) catch |err| switch (err) {
        error.WaitTimeOut => {
            _ = kernel32.CancelIoEx(pipe, overlapped);
            _ = windows.WaitForSingleObject(event, windows.INFINITE) catch {};
            return error.Timeout;
        },
        error.WaitAbandoned => {
            _ = kernel32.CancelIoEx(pipe, overlapped);
            _ = windows.WaitForSingleObject(event, windows.INFINITE) catch {};
            return error.Cancelled;
        },
        else => return error.SystemResources,
    };
    if (result == 1 and count == 2) {
        _ = kernel32.CancelIoEx(pipe, overlapped);
        _ = windows.WaitForSingleObject(event, windows.INFINITE) catch {};
        return error.Cancelled;
    }

    var transferred: windows.DWORD = 0;
    if (kernel32.GetOverlappedResult(pipe, overlapped, &transferred, windows.FALSE) == windows.FALSE) {
        return mapLastError(windows.GetLastError());
    }
}

pub fn read(
    connection: local_ipc.Connection,
    buffer: []u8,
) Error!usize {
    return readWithDeadline(connection.handle, buffer, null, null);
}

pub fn readWithDeadline(
    value: local_ipc.Handle,
    buffer: []u8,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!usize {
    if (buffer.len == 0) return 0;
    try checkDeadline(deadline, cancellation);
    const pipe = handleFromValue(value);
    const event = try completionEvent();
    defer windows.CloseHandle(event);
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = event;
    var transferred: windows.DWORD = 0;
    const amount: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
    if (kernel32.ReadFile(pipe, buffer.ptr, amount, &transferred, &overlapped) == windows.FALSE) {
        switch (windows.GetLastError()) {
            .IO_PENDING => try awaitCompletion(pipe, &overlapped, event, deadline, cancellation),
            else => |err| return mapLastError(err),
        }
        if (kernel32.GetOverlappedResult(pipe, &overlapped, &transferred, windows.FALSE) == windows.FALSE) {
            return mapLastError(windows.GetLastError());
        }
    }
    return transferred;
}

pub fn write(
    connection: local_ipc.Connection,
    bytes: []const u8,
) Error!usize {
    return writeWithDeadline(connection.handle, bytes, null, null);
}

pub fn writeWithDeadline(
    value: local_ipc.Handle,
    bytes: []const u8,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!usize {
    if (bytes.len == 0) return 0;
    try checkDeadline(deadline, cancellation);
    const pipe = handleFromValue(value);
    const event = try completionEvent();
    defer windows.CloseHandle(event);
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = event;
    var transferred: windows.DWORD = 0;
    const amount: windows.DWORD = @intCast(@min(bytes.len, std.math.maxInt(windows.DWORD)));
    if (kernel32.WriteFile(pipe, bytes.ptr, amount, &transferred, &overlapped) == windows.FALSE) {
        switch (windows.GetLastError()) {
            .IO_PENDING => try awaitCompletion(pipe, &overlapped, event, deadline, cancellation),
            else => |err| return mapLastError(err),
        }
        if (kernel32.GetOverlappedResult(pipe, &overlapped, &transferred, windows.FALSE) == windows.FALSE) {
            return mapLastError(windows.GetLastError());
        }
    }
    return transferred;
}

fn checkDeadline(
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!void {
    if (cancellation) |cancel| {
        if (cancel.isCancelled()) return error.Cancelled;
    }
    if (deadline) |value| {
        if (value.remainingMs() == 0) return error.Timeout;
    }
}

pub fn writeAll(
    connection: local_ipc.Connection,
    bytes: []const u8,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try writeWithDeadline(
            connection.handle,
            bytes[offset..],
            deadline,
            cancellation,
        );
        if (count == 0) return error.BrokenPipe;
        offset += count;
    }
}

fn closeHandle(value: local_ipc.Handle) void {
    const handle = handleFromValue(value);
    _ = kernel32.CancelIoEx(handle, null);
    windows.CloseHandle(handle);
}

fn closeServerThunk(value: local_ipc.Handle) void {
    const state: *ServerState = @ptrFromInt(value);
    if (state.closed) return;
    state.closed = true;
    if (state.pipe) |pipe| {
        _ = kernel32.CancelIoEx(pipe, null);
        windows.CloseHandle(pipe);
    }
    state.allocator.free(state.name);
    state.allocator.destroy(state);
}

test "Windows IPC keeps endpoint validation separate from wire framing" {
    const endpoint = local_ipc.Endpoint{ .name = "session-\u{1F600}" };
    try runtime_windows.validateSessionName(endpoint.name);
    try std.testing.expect(endpoint.name.len > 0);
}

test "Windows named pipes support multiple clients and partial writes" {
    const alloc = std.testing.allocator;
    var server = try listen(alloc, .{ .name = "zmx-ipc-test-\u{1F600}" }, .{});
    defer server.close();

    var client_one = try connect(alloc, .{ .name = "zmx-ipc-test-\u{1F600}" });
    defer client_one.close();
    var accepted_one = try server.accept();
    defer accepted_one.close();

    const first = "partial frame";
    try std.testing.expectEqual(@as(usize, 7), try write(client_one, first[0..7]));
    try std.testing.expectEqual(@as(usize, first.len - 7), try write(client_one, first[7..]));
    var first_read: [32]u8 = undefined;
    try std.testing.expectEqual(first.len, try read(accepted_one, first_read[0..first.len]));
    try std.testing.expectEqualStrings(first, first_read[0..first.len]);

    var client_two = try connect(alloc, .{ .name = "zmx-ipc-test-\u{1F600}" });
    defer client_two.close();
    var accepted_two = try server.accept();
    defer accepted_two.close();
    try writeAll(client_two, "second", null, null);
    var second_read: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try read(accepted_two, &second_read));
    try std.testing.expectEqualStrings("second", &second_read);
}

test "Windows named pipe accept is cancellable before a client connects" {
    const alloc = std.testing.allocator;
    var server = try listen(alloc, .{ .name = "zmx-ipc-cancel-\u{1F600}" }, .{});
    defer server.close();
    var cancellation = try events_windows.Cancellation.init();
    defer cancellation.deinit();
    try cancellation.cancel();
    try std.testing.expectError(
        error.Cancelled,
        acceptServerWithDeadline(server, events_windows.Deadline.afterMs(1000), &cancellation),
    );
    try cancellation.reset();
    var client = try connect(alloc, .{ .name = "zmx-ipc-cancel-\u{1F600}" });
    defer client.close();
    var accepted = try server.accept();
    defer accepted.close();
}
