const std = @import("std");
const build_options = @import("build_options");
const Cfg = @import("cfg.zig").Cfg;
const socket = @import("socket.zig");
const runtime_windows = @import("platform/runtime_windows.zig");

/// Windows production entry point. The ConPTY/process implementation remains
/// in the sibling-owned adapter; this smoke-safe entry point exercises the
/// native runtime and IPC selection without importing POSIX process code.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var cfg = try Cfg.init(gpa, io);
    defer cfg.deinit(gpa);

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    const command = args.next() orelse "version";
    if (std.mem.eql(u8, command, "version")) {
        var buf: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buf);
        try writer.interface.print(
            "zmx {s} windows IPC runtime={s}\n",
            .{ build_options.version, cfg.socket_dir },
        );
        try writer.interface.flush();
        return;
    }

    const session_name = try runtime_windows.validateSessionName(command);
    _ = session_name;
    const endpoint = try socket.getSocketPath(gpa, cfg.socket_dir, command);
    defer gpa.free(endpoint);
    var factory = @import("platform/local_ipc_windows.zig").Factory{ .allocator = gpa };
    _ = factory.listener();
}
