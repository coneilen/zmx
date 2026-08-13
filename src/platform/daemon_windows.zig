const builtin = @import("builtin");
const std = @import("std");
const daemon = @import("daemon.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("daemon_windows requires a Windows target");
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;

extern "kernel32" fn CreateMutexW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    initial_owner: windows.BOOL,
    name: windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

pub const SingleSession = struct {
    lifetime: daemon.Lifetime = .{},
    clients: usize = 0,

    pub fn start(self: *SingleSession) !void {
        if (self.lifetime.state != .creating) return error.AlreadyRunning;
        self.lifetime.started();
    }

    pub fn clientConnected(self: *SingleSession) !void {
        if (!self.lifetime.isRunning()) return error.NotRunning;
        self.clients += 1;
    }

    pub fn clientDisconnected(self: *SingleSession) void {
        if (self.clients > 0) self.clients -= 1;
    }

    pub fn stop(self: *SingleSession, reason: daemon.StopReason) void {
        self.lifetime.stop(reason);
        self.clients = 0;
    }

    pub fn finish(self: *SingleSession) void {
        self.lifetime.stopped();
    }
};

pub const Lease = struct {
    handle: windows.HANDLE,

    pub fn acquire(name: [:0]const u16) !Lease {
        const handle = CreateMutexW(null, windows.TRUE, name.ptr) orelse
            return error.SystemResources;
        if (windows.GetLastError() == .ALREADY_EXISTS) {
            windows.CloseHandle(handle);
            return error.AlreadyRunning;
        }
        return .{ .handle = handle };
    }

    pub fn release(self: *Lease) void {
        windows.CloseHandle(self.handle);
        self.handle = undefined;
    }
};

test "Windows daemon lifetime permits one session and records shutdown" {
    var session = SingleSession{};
    try session.start();
    try std.testing.expectError(error.AlreadyRunning, session.start());
    try session.clientConnected();
    session.clientDisconnected();
    session.stop(.requested);
    session.finish();
    try std.testing.expectEqual(daemon.State.stopped, session.lifetime.state);
}
