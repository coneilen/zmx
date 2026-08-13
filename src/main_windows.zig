const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const Cfg = @import("cfg.zig").Cfg;
const socket = @import("socket.zig");
const runtime_windows = @import("platform/runtime_windows.zig");
const local_ipc = @import("platform/local_ipc.zig");
const local_ipc_windows = @import("platform/local_ipc_windows.zig");
const session_windows = @import("platform/session_windows.zig");
const wire = @import("platform/session_wire.zig");

const WireTag = wire.Tag;
const WireHeader = wire.Header;
const max_frame_len: usize = wire.MAX_FRAME_LEN;

pub const std_options: std.Options = .{
    .logFn = log.zmxLogFn,
    .log_level = .debug,
};

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
    if (std.mem.eql(u8, command, "write") or std.mem.eql(u8, command, "wr")) {
        return .Write;
    }
    if (std.mem.eql(u8, command, "detach") or std.mem.eql(u8, command, "d")) {
        return .Detach;
    }
    if (std.mem.eql(u8, command, "detach-all") or std.mem.eql(u8, command, "da")) {
        return .DetachAll;
    }
    if (std.mem.eql(u8, command, "kill") or std.mem.eql(u8, command, "k")) {
        return .Kill;
    }
    if (std.mem.eql(u8, command, "history") or std.mem.eql(u8, command, "hi")) {
        return .History;
    }
    if (std.mem.eql(u8, command, "get") or std.mem.eql(u8, command, "g")) {
        return .LabelGet;
    }
    if (std.mem.eql(u8, command, "set")) {
        return .LabelSet;
    }
    if (std.mem.eql(u8, command, "clear")) {
        return .LabelClear;
    }
    if (std.mem.eql(u8, command, "info") or
        std.mem.eql(u8, command, "i"))
    {
        return .Info;
    }
    return error.UnsupportedCommand;
}

fn sendFrame(connection: local_ipc.Connection, tag: WireTag, payload: []const u8) !void {
    if (payload.len > max_frame_len or payload.len > std.math.maxInt(u32)) {
        return error.FrameTooLarge;
    }
    try wire.writeFrame(connection, tag, payload);
}

fn readStdin(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(alloc);
    const stdin_file = std.Io.File.stdin();
    defer stdin_file.close(io);
    var stdin_buffer: [4096]u8 = undefined;
    var reader = stdin_file.reader(io, &stdin_buffer);
    while (true) {
        var chunk: [64 * 1024]u8 = undefined;
        const amount = try reader.interface.readSliceShort(&chunk);
        if (amount == 0) break;
        if (payload.items.len > max_frame_len - amount) return error.FrameTooLarge;
        try payload.appendSlice(alloc, chunk[0..amount]);
    }
    return payload.toOwnedSlice(alloc);
}

pub fn encodeWritePayload(
    alloc: std.mem.Allocator,
    path: []const u8,
    stdin_payload: []const u8,
) ![]u8 {
    if (path.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    if (stdin_payload.len > max_frame_len - @sizeOf(u32)) return error.FrameTooLarge;
    if (path.len > max_frame_len - @sizeOf(u32) - stdin_payload.len) {
        return error.FrameTooLarge;
    }
    const payload = try alloc.alloc(u8, @sizeOf(u32) + path.len + stdin_payload.len);
    errdefer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..@sizeOf(u32)], @intCast(path.len), .little);
    @memcpy(payload[@sizeOf(u32) .. @sizeOf(u32) + path.len], path);
    @memcpy(payload[@sizeOf(u32) + path.len ..], stdin_payload);
    return payload;
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
    if (tag == .Write) {
        if (parts.len != 1) return error.UnsupportedCommand;
        const path = parts[0];
        const stdin_payload = try readStdin(alloc, io);
        defer alloc.free(stdin_payload);
        const write_payload = try encodeWritePayload(alloc, path, stdin_payload);
        defer alloc.free(write_payload);
        const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
        defer alloc.free(endpoint);
        var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
        defer connection.close();
        return sendFrame(connection, tag, write_payload);
    }
    for (parts, 0..) |part, index| {
        if (index != 0) try payload.append(alloc, ' ');
        try payload.appendSlice(alloc, part);
    }
    const requires_payload = switch (tag) {
        .Output, .Send, .Write, .LabelSet => true,
        else => false,
    };
    if (requires_payload and payload.items.len == 0) return error.TextRequired;

    const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    try sendFrame(connection, tag, payload.items);
}

fn requestResponse(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    session_name: []const u8,
    request_tag: WireTag,
    request_payload: []const u8,
    response_tag: WireTag,
) ![]u8 {
    const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    try sendFrame(connection, request_tag, request_payload);
    var response = try session_windows.readFrameWithDeadline(
        alloc,
        connection,
        session_windows.Deadline.afterMs(5000),
        null,
    );
    errdefer response.deinit(alloc);
    if (response.header.tag != response_tag) return error.Unexpected;
    return response.payload;
}

fn renderInfo(io: std.Io, session_name: []const u8, payload: []const u8) !void {
    if (payload.len != @sizeOf(wire.Info)) return error.Unexpected;
    const info = std.mem.bytesToValue(wire.Info, payload);
    const cmd_len = @min(@as(usize, info.cmd_len), info.cmd.len);
    const cwd_len = @min(@as(usize, info.cwd_len), info.cwd.len);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print(
        "{s}\tclients={d}\tpid={d}\tcmd={s}\tcwd={s}\n",
        .{
            session_name,
            info.clients_len,
            info.pid,
            info.cmd[0..cmd_len],
            info.cwd[0..cwd_len],
        },
    );
    try writer.interface.flush();
}

fn renderPayload(io: std.Io, payload: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn responseCommand(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    session_name: []const u8,
    command: WireTag,
    parts: []const []const u8,
) !void {
    var request_payload: std.ArrayList(u8) = .empty;
    defer request_payload.deinit(alloc);
    var expected = command;
    switch (command) {
        .History => {
            try request_payload.append(alloc, 0);
            expected = .History;
        },
        .LabelGet => {
            for (parts, 0..) |part, index| {
                if (index != 0) try request_payload.append(alloc, ' ');
                try request_payload.appendSlice(alloc, part);
            }
            expected = .LabelData;
        },
        .Info => expected = .Info,
        else => return error.UnsupportedCommand,
    }
    const payload = try requestResponse(
        io,
        alloc,
        cfg,
        session_name,
        command,
        request_payload.items,
        expected,
    );
    defer alloc.free(payload);
    if (command == .Info) {
        try renderInfo(io, session_name, payload);
    } else {
        try renderPayload(io, payload);
    }
}

fn listSessions(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    parts: []const []const u8,
) !void {
    var short = false;
    for (parts) |part| {
        if (std.mem.eql(u8, part, "--short")) {
            short = true;
        } else {
            return error.UnsupportedCommand;
        }
    }
    var sessions = try runtime_windows.listSessionNames(io, alloc);
    defer {
        for (sessions.items) |name| alloc.free(name);
        sessions.deinit(alloc);
    }
    for (sessions.items) |session_name| {
        if (short) {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            try writer.interface.print("{s}\n", .{session_name});
            try writer.interface.flush();
            continue;
        }
        responseCommand(io, alloc, cfg, session_name, .Info, &.{}) catch {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            try writer.interface.print("{s}\n", .{session_name});
            try writer.interface.flush();
            continue;
        };
    }
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

fn runSession(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    command: ?[]const []const u8,
) !void {
    try session_windows.host(
        .{
            .io = io,
            .alloc = alloc,
            .session_name = session_name,
            .shell = "cmd.exe",
            .task_mode = command != null,
            .command = command,
        },
        session_windows.pendingProvider(),
    );
}

fn attachSession(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) !void {
    return session_windows.attach(
        .{
            .io = io,
            .alloc = alloc,
            .session_name = session_name,
        },
        session_windows.pendingProvider(),
    );
}

/// Windows production entry point. Session creation and attach use the
/// frozen IPC server/client contract and the sibling-owned ConPTY provider
/// boundary. Commands that do not need a PTY still use the same wire tags.
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

    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "r")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        var command_args: std.ArrayList([]const u8) = .empty;
        defer command_args.deinit(gpa);
        while (args.next()) |part| try command_args.append(gpa, part);
        const command_slice: ?[]const []const u8 =
            if (command_args.items.len == 0) null else command_args.items;
        return runSession(io, gpa, session_name, command_slice);
    }

    if (std.mem.eql(u8, command, "attach") or std.mem.eql(u8, command, "a")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        return attachSession(io, gpa, session_name);
    }

    if (std.mem.eql(u8, command, "list") or
        std.mem.eql(u8, command, "l") or
        std.mem.eql(u8, command, "ls"))
    {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        while (args.next()) |part| try parts.append(gpa, part);
        return listSessions(io, gpa, &cfg, parts.items);
    }

    if (std.mem.eql(u8, command, "wait") or std.mem.eql(u8, command, "w")) {
        return unsupported(io, "wait");
    }

    if (wireTagForCommand(command)) |tag| {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        while (args.next()) |part| try parts.append(gpa, part);
        if (tag == .History or tag == .LabelGet or tag == .Info) {
            return responseCommand(io, gpa, &cfg, session_name, tag, parts.items);
        }
        return sendCommand(io, gpa, &cfg, session_name, tag, parts.items);
    } else |_| {
        return unsupported(io, command);
    }
}

test "Windows print aliases preserve the frozen Output wire tag" {
    try std.testing.expectEqual(WireTag.Output, try wireTagForCommand("print"));
    try std.testing.expectEqual(WireTag.Output, try wireTagForCommand("p"));
    try std.testing.expectEqual(WireTag.Send, try wireTagForCommand("send"));
    try std.testing.expectEqual(WireTag.Send, try wireTagForCommand("s"));
    try std.testing.expectEqual(WireTag.Write, try wireTagForCommand("write"));
    try std.testing.expectEqual(WireTag.Write, try wireTagForCommand("wr"));
    try std.testing.expectError(error.UnsupportedCommand, wireTagForCommand("w"));
    try std.testing.expectEqual(WireTag.Detach, try wireTagForCommand("detach"));
    try std.testing.expectEqual(WireTag.DetachAll, try wireTagForCommand("detach-all"));
    try std.testing.expectEqual(WireTag.Kill, try wireTagForCommand("kill"));
    try std.testing.expectEqual(WireTag.History, try wireTagForCommand("history"));
    try std.testing.expectEqual(WireTag.LabelGet, try wireTagForCommand("get"));
    try std.testing.expectEqual(WireTag.LabelSet, try wireTagForCommand("set"));
    try std.testing.expectEqual(WireTag.LabelClear, try wireTagForCommand("clear"));
    try std.testing.expectEqual(WireTag.Info, try wireTagForCommand("info"));
}

test "Windows Write payload preserves path length and stdin bytes" {
    const payload = try encodeWritePayload(std.testing.allocator, "a\\b.txt", "contents");
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, payload[0..4], .little));
    try std.testing.expectEqualStrings("a\\b.txt", payload[4..11]);
    try std.testing.expectEqualStrings("contents", payload[11..]);
}

test "Windows production commands route run and attach through the session adapter" {
    try std.testing.expectError(
        error.ConPtyProviderUnavailable,
        runSession(
            std.testing.io,
            std.testing.allocator,
            "adapter-run-test",
            null,
        ),
    );
}

test "Windows root exports the logging hook through std_options" {
    const root = @import("main.zig");
    root.std_options.logFn(.debug, .default, "Windows logging hook test", .{});
}
