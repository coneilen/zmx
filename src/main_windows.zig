const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const Cfg = @import("cfg.zig").Cfg;
const socket = @import("socket.zig");
const runtime_windows = @import("platform/runtime_windows.zig");
const local_ipc = @import("platform/local_ipc.zig");
const local_ipc_windows = @import("platform/local_ipc_windows.zig");
const session_windows = @import("platform/session_windows.zig");
const pty_session_windows = @import("platform/pty_session_windows.zig");
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
    if (std.mem.eql(u8, command, "write") or std.mem.eql(u8, command, "w")) {
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
        std.mem.eql(u8, command, "i") or
        std.mem.eql(u8, command, "list") or
        std.mem.eql(u8, command, "l") or
        std.mem.eql(u8, command, "ls"))
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
    const requires_payload = switch (tag) {
        .Output, .Send, .Write, .LabelSet => true,
        else => false,
    };
    if (requires_payload and payload.items.len == 0) return error.TextRequired;

    return sendPayload(io, alloc, cfg, session_name, tag, payload.items);
}

fn sendPayload(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    session_name: []const u8,
    tag: WireTag,
    payload: []const u8,
) !void {
    const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    try sendFrame(connection, tag, payload);

    const expected = switch (tag) {
        .Info => WireTag.Info,
        .LabelGet => WireTag.LabelData,
        .LabelSet, .LabelClear, .Write => WireTag.Ack,
        else => null,
    };
    if (expected) |response_tag| {
        var frame = try wire.readFrame(alloc, connection);
        defer frame.deinit(alloc);
        if (frame.header.tag != response_tag) return error.Unexpected;
        if (response_tag == .LabelData) {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            try writer.interface.writeAll(frame.payload);
            try writer.interface.writeAll("\n");
            try writer.interface.flush();
        } else if (response_tag == .Info and frame.payload.len == @sizeOf(wire.Info)) {
            const info = std.mem.bytesToValue(wire.Info, frame.payload);
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            try writer.interface.print(
                "pid={d} clients={d}\n",
                .{ info.pid, info.clients_len },
            );
            try writer.interface.flush();
        }
    }
}

fn sendFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    session_name: []const u8,
    file_path: []const u8,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    const path_len: u32 = @intCast(file_path.len);
    try payload.appendSlice(alloc, std.mem.asBytes(&path_len));
    try payload.appendSlice(alloc, file_path);

    var read_buffer: [16 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &read_buffer);
    while (true) {
        var chunk: [16 * 1024]u8 = undefined;
        const amount = try input.interface.readSliceShort(&chunk);
        if (amount == 0) break;
        try payload.appendSlice(alloc, chunk[0..amount]);
        if (payload.items.len > max_frame_len) return error.FrameTooLarge;
    }
    try sendPayload(io, alloc, cfg, session_name, .Write, payload.items);
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
    detached: bool,
) !void {
    const spec = session_windows.HostSpec{
        .io = io,
        .alloc = alloc,
        .session_name = session_name,
        .shell = "cmd.exe",
        .task_mode = command != null,
        .command = command,
    };
    if (detached) return pty_session_windows.hostDetached(spec);
    return session_windows.host(spec, pty_session_windows.provider());
}

fn spawnDetached(
    io: std.Io,
    program: []const u8,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    command: ?[]const []const u8,
) !void {
    const endpoint = try runtime_windows.resolveEndpointPath(io, alloc, session_name);
    defer alloc.free(endpoint);
    if (local_ipc_windows.reconnect(
        alloc,
        .{ .name = endpoint },
        @import("platform/events_windows.zig").Deadline.afterMs(100),
        null,
    )) |existing| {
        existing.close();
        return error.SessionAlreadyExists;
    } else |_| {}

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, program);
    try argv.append(alloc, "--daemon");
    try argv.append(alloc, session_name);
    if (command) |parts| try argv.appendSlice(alloc, parts);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    if (child.id) |handle| {
        std.os.windows.CloseHandle(handle);
        child.id = null;
    }
    std.os.windows.CloseHandle(child.thread_handle);

    for (0..50) |_| {
        var probe = local_ipc_windows.reconnect(
            alloc,
            .{ .name = endpoint },
            @import("platform/events_windows.zig").Deadline.afterMs(100),
            null,
        ) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
            continue;
        };
        probe.close();
        return;
    }
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
        pty_session_windows.provider(),
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
    const program = args.next() orelse return error.InvalidCommand;

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

    if (std.mem.eql(u8, command, "--daemon")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        var command_args: std.ArrayList([]const u8) = .empty;
        defer command_args.deinit(gpa);
        while (args.next()) |part| try command_args.append(gpa, part);
        const command_slice: ?[]const []const u8 =
            if (command_args.items.len == 0) null else command_args.items;
        return runSession(io, gpa, session_name, command_slice, false);
    }

    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "r")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        var command_args: std.ArrayList([]const u8) = .empty;
        defer command_args.deinit(gpa);
        var detached = false;
        while (args.next()) |part| {
            if (std.mem.eql(u8, part, "-d") or std.mem.eql(u8, part, "--detach")) {
                detached = true;
            } else {
                try command_args.append(gpa, part);
            }
        }
        if (command_args.items.len > 0 and
            std.mem.eql(u8, command_args.items[0], "cmd/pwsh"))
        {
            command_args.items[0] = "pwsh";
        }
        const command_slice: ?[]const []const u8 =
            if (command_args.items.len == 0) null else command_args.items;
        if (detached) return spawnDetached(io, program, gpa, session_name, command_slice);
        return runSession(io, gpa, session_name, command_slice, false);
    }

    if (std.mem.eql(u8, command, "attach") or std.mem.eql(u8, command, "a")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        return attachSession(io, gpa, session_name);
    }

    if (std.mem.eql(u8, command, "write") or std.mem.eql(u8, command, "wr")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        const file_path = args.next() orelse return error.FilePathRequired;
        try runtime_windows.validateSessionName(session_name);
        return sendFile(io, gpa, &cfg, session_name, file_path);
    }

    if (std.mem.eql(u8, command, "resize")) {
        const session_name = args.next() orelse return error.SessionNameRequired;
        const cols_text = args.next() orelse return error.InvalidSize;
        const rows_text = args.next() orelse return error.InvalidSize;
        const size = wire.Resize{
            .cols = try std.fmt.parseInt(u16, cols_text, 10),
            .rows = try std.fmt.parseInt(u16, rows_text, 10),
        };
        try runtime_windows.validateSessionName(session_name);
        return sendPayload(io, gpa, &cfg, session_name, .Resize, std.mem.asBytes(&size));
    }

    if (wireTagForCommand(command)) |tag| {
        const session_name = args.next() orelse return error.SessionNameRequired;
        try runtime_windows.validateSessionName(session_name);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        while (args.next()) |part| try parts.append(gpa, part);
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
    try std.testing.expectEqual(WireTag.Detach, try wireTagForCommand("detach"));
    try std.testing.expectEqual(WireTag.DetachAll, try wireTagForCommand("detach-all"));
    try std.testing.expectEqual(WireTag.Kill, try wireTagForCommand("kill"));
    try std.testing.expectEqual(WireTag.History, try wireTagForCommand("history"));
    try std.testing.expectEqual(WireTag.LabelGet, try wireTagForCommand("get"));
    try std.testing.expectEqual(WireTag.LabelSet, try wireTagForCommand("set"));
    try std.testing.expectEqual(WireTag.LabelClear, try wireTagForCommand("clear"));
    try std.testing.expectEqual(WireTag.Info, try wireTagForCommand("list"));
}

test "Windows production commands route run and attach through the session adapter" {
    const value = pty_session_windows.provider();
    try std.testing.expect(value.host_fn != undefined);
    try std.testing.expect(value.attach_fn != undefined);
}

test "Windows root exports the logging hook through std_options" {
    const root = @import("main.zig");
    root.std_options.logFn(.debug, .default, "Windows logging hook test", .{});
}
