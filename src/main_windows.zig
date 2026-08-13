const std = @import("std");
const build_options = @import("build_options");
const Cfg = @import("cfg.zig").Cfg;
const socket = @import("socket.zig");
const runtime_windows = @import("platform/runtime_windows.zig");
const pty = @import("platform/pty.zig");
const pty_runtime = @import("platform/pty_runtime.zig");

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

    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "r")) {
        return run(gpa, io, &args, init.environ_map);
    }

    const session_name = try runtime_windows.validateSessionName(command);
    _ = session_name;
    const endpoint = try socket.getSocketPath(gpa, cfg.socket_dir, command);
    defer gpa.free(endpoint);
    var factory = @import("platform/local_ipc_windows.zig").Factory{ .allocator = gpa };
    _ = factory.listener();
}

fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    args: anytype,
    environ: *const std.process.Environ.Map,
) !void {
    const session_name = args.next() orelse return error.SessionNameRequired;
    try runtime_windows.validateSessionName(session_name);

    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(alloc);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
            return error.UnsupportedPlatform;
        }
        try command.append(alloc, arg);
    }

    const shell = environ.get("COMSPEC") orelse "cmd.exe";
    var runtime = pty_runtime.Runtime.init(alloc);
    defer runtime.deinit();
    const spawned = try runtime.spawn(.{
        .session_name = session_name,
        .shell = shell,
        .task_mode = true,
        .command = if (command.items.len == 0) null else command.items,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer runtime.close(spawned.master);
    defer runtime.reap(spawned.process);

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    var output_buf: [16 * 1024]u8 = undefined;
    while (true) {
        const amount = runtime.read(spawned.master, &output_buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .real) catch {};
                continue;
            },
            else => return err,
        };
        if (amount == 0) break;
        try stdout.interface.writeAll(output_buf[0..amount]);
        try stdout.interface.flush();
    }
    _ = try runtime.wait(spawned.process);
}
