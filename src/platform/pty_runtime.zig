const builtin = @import("builtin");
const std = @import("std");
const pty = @import("pty.zig");
const resize_contract = @import("resize.zig");
const pty_windows = @import("pty_windows.zig");

/// Runtime ownership for a PTY session.  POSIX daemon code still owns its
/// forkpty descriptor path; Windows owns the native ConPTY state here so the
/// daemon never needs to know about HANDLEs or synchronous pipe I/O.
pub const Runtime = struct {
    alloc: std.mem.Allocator,
    windows: if (builtin.os.tag == .windows) pty_windows.BackendState else void,

    pub fn init(alloc: std.mem.Allocator) Runtime {
        return .{
            .alloc = alloc,
            .windows = if (builtin.os.tag == .windows) pty_windows.init(alloc) else {},
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (builtin.os.tag == .windows) pty_windows.deinit(&self.windows);
    }

    pub fn backend(self: *Runtime) pty.Backend {
        if (builtin.os.tag == .windows) return pty_windows.backend(&self.windows);
        return undefined;
    }

    pub fn spawn(self: *Runtime, spec: pty.SpawnSpec) !pty.Spawned {
        if (builtin.os.tag == .windows) return pty_windows.spawn(&self.windows, spec);
        return error.UnsupportedPlatform;
    }

    pub fn read(self: *Runtime, master: pty.Handle, buffer: []u8) !usize {
        if (builtin.os.tag == .windows) return pty_windows.read(&self.windows, master, buffer);
        return error.UnsupportedPlatform;
    }

    pub fn write(self: *Runtime, master: pty.Handle, bytes: []const u8) !usize {
        if (builtin.os.tag == .windows) return pty_windows.write(&self.windows, master, bytes);
        return error.UnsupportedPlatform;
    }

    pub fn resize(self: *Runtime, master: pty.Handle, size: resize_contract.Size) !void {
        if (builtin.os.tag == .windows) return self.backend().resize(master, size);
        return error.UnsupportedPlatform;
    }

    pub fn signal(self: *Runtime, process: pty.ProcessId, value: pty.Signal) !void {
        if (builtin.os.tag == .windows) return self.backend().signal(process, value);
        return error.UnsupportedPlatform;
    }

    pub fn wait(self: *Runtime, process: pty.ProcessId) !u32 {
        if (builtin.os.tag == .windows) return pty_windows.wait(&self.windows, process);
        return error.UnsupportedPlatform;
    }

    pub fn close(self: *Runtime, master: pty.Handle) void {
        if (builtin.os.tag == .windows) self.backend().close(master);
    }

    pub fn reap(self: *Runtime, process: pty.ProcessId) void {
        if (builtin.os.tag == .windows) pty_windows.reap(&self.windows, process);
    }
};

test "PTY runtime preserves the frozen backend on unsupported targets" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    if (builtin.os.tag != .windows) {
        try std.testing.expectError(
            error.UnsupportedPlatform,
            runtime.spawn(.{
                .session_name = "unsupported",
                .shell = "sh",
                .task_mode = false,
                .command = null,
                .size = .{ .rows = 24, .cols = 80 },
            }),
        );
    }
}
