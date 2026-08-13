const std = @import("std");
const build_options = @import("build_options");
const Cfg = @import("cfg.zig").Cfg;
const socket = @import("socket.zig");
const runtime_windows = @import("platform/runtime_windows.zig");
const local_ipc = @import("platform/local_ipc.zig");
const local_ipc_windows = @import("platform/local_ipc_windows.zig");

const WireTag = enum(u8) {
    Output = 1,
    Ack = 10,
    Send = 18,
    _,
};

const WireHeader = packed struct {
    tag: WireTag,
    len: u32,
};

const max_frame_len: usize = 256 * 1024 * 1024;

comptime {
    if (@sizeOf(WireHeader) != 8) @compileError("Windows IPC header must match ipc.Header");
    if (@intFromEnum(WireTag.Output) != 1 or @intFromEnum(WireTag.Send) != 18) {
        @compileError("Windows IPC tags must match ipc.Tag");
    }
}

fn wireTagForCommand(command: []const u8) !WireTag {
    if (std.mem.eql(u8, command, "print") or std.mem.eql(u8, command, "p")) {
        return .Output;
    }
    if (std.mem.eql(u8, command, "send") or std.mem.eql(u8, command, "s")) {
        return .Send;
    }
    return error.UnsupportedCommand;
}

fn sendFrame(connection: local_ipc.Connection, tag: WireTag, payload: []const u8) !void {
    if (payload.len > max_frame_len or payload.len > std.math.maxInt(u32)) {
        return error.FrameTooLarge;
    }
    const header = WireHeader{ .tag = tag, .len = @intCast(payload.len) };
    try connection.writeAll(std.mem.asBytes(&header));
    try connection.writeAll(payload);
}

fn sendCommand(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    session_name: []const u8,
    tag: WireTag,
    parts: []const []const u8,
) !void {
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(alloc);
    for (parts, 0..) |part, index| {
        if (index != 0) try payload.append(alloc, ' ');
        try payload.appendSlice(alloc, part);
    }
    if (payload.items.len == 0) return error.TextRequired;

    const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    try sendFrame(connection, tag, payload.items);
}

fn unsupported(io: std.Io, command: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(
        "zmx: Windows command '{s}' requires the ConPTY/session adapter and is not available in this build\n",
        .{command},
    );
    try writer.interface.flush();
    return error.UnsupportedCommand;
}

/// Windows production entry point. Transport framing and send/print dispatch
/// are native here; ConPTY-dependent commands fail explicitly until the
/// sibling-owned process adapter supplies its frozen session callbacks.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var cfg = try Cfg.init(gpa, io);
    defer cfg.deinit(gpa);

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();

    const command = args.next() orelse "version";
    if (std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "v") or
        std.mem.eql(u8, command, "-v") or
        std.mem.eql(u8, command, "--version"))
    {
        var buf: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buf);
        try writer.interface.print(
            "zmx {s} windows IPC runtime={s}\n",
            .{ build_options.version, cfg.socket_dir },
        );
        try writer.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "send") or std.mem.eql(u8, command, "s") or
        std.mem.eql(u8, command, "print") or std.mem.eql(u8, command, "p"))
    {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        while (args.next()) |part| try parts.append(gpa, part);
        return sendCommand(io, gpa, &cfg, session_name, try wireTagForCommand(command), parts.items);
    }

    return unsupported(io, command);
}

test "Windows print aliases preserve the frozen Output wire tag" {
    try std.testing.expectEqual(WireTag.Output, try wireTagForCommand("print"));
    try std.testing.expectEqual(WireTag.Output, try wireTagForCommand("p"));
    try std.testing.expectEqual(WireTag.Send, try wireTagForCommand("send"));
    try std.testing.expectEqual(WireTag.Send, try wireTagForCommand("s"));
}
