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
const label = @import("label.zig");

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
        return .DetachAll;
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

fn stripPipedNewline(payload: *std.ArrayList(u8), tag: WireTag) void {
    if (tag != .Output and payload.items.len > 0 and payload.items[payload.items.len - 1] == '\n') {
        _ = payload.pop();
    }
}

fn readCommandPayload(
    alloc: std.mem.Allocator,
    io: std.Io,
    tag: WireTag,
    parts: []const []const u8,
) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(alloc);
    if (parts.len > 0) {
        for (parts, 0..) |part, index| {
            if (index != 0) try payload.append(alloc, ' ');
            try payload.appendSlice(alloc, part);
        }
    } else {
        const stdin_file = std.Io.File.stdin();
        defer stdin_file.close(io);
        if (!try stdin_file.isTty(io)) {
            var stdin_buffer: [4096]u8 = undefined;
            var reader = stdin_file.reader(io, &stdin_buffer);
            while (true) {
                var chunk: [1024]u8 = undefined;
                const amount = try reader.interface.readSliceShort(&chunk);
                if (amount == 0) break;
                if (payload.items.len > max_frame_len - amount) return error.FrameTooLarge;
                try payload.appendSlice(alloc, chunk[0..amount]);
            }
            stripPipedNewline(&payload, tag);
        }
    }
    if (payload.items.len == 0) return error.TextRequired;
    return payload.toOwnedSlice(alloc);
}

fn historyFormatByte(parts: []const []const u8) !u8 {
    if (parts.len == 0) return 0;
    if (parts.len != 1) return error.UnsupportedCommand;
    if (std.mem.eql(u8, parts[0], "--vt")) return 1;
    if (std.mem.eql(u8, parts[0], "--html")) return 2;
    return error.UnsupportedCommand;
}

fn joinCommandParts(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(alloc);
    for (parts, 0..) |part, index| {
        if (index != 0) try payload.append(alloc, ' ');
        try payload.appendSlice(alloc, part);
    }
    return payload.toOwnedSlice(alloc);
}

fn awaitResponse(
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
    expected_tag: WireTag,
) !void {
    var response = try session_windows.readFrameWithDeadline(
        alloc,
        connection,
        session_windows.Deadline.afterMs(5000),
        null,
    );
    defer response.deinit(alloc);
    if (response.header.tag != expected_tag) return error.Unexpected;
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
    if (tag == .Write) {
        if (parts.len != 1) return error.UnsupportedCommand;
        const stdin_payload = try readStdin(alloc, io);
        defer alloc.free(stdin_payload);
        const write_payload = try encodeWritePayload(alloc, parts[0], stdin_payload);
        defer alloc.free(write_payload);
        const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
        defer alloc.free(endpoint);
        var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
        defer connection.close();
        try sendFrame(connection, tag, write_payload);
        try awaitResponse(alloc, connection, .Ack);
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("file created {s}\n", .{parts[0]});
        try writer.interface.flush();
        return;
    }
    const payload = if (tag == .Output or tag == .Send)
        try readCommandPayload(alloc, io, tag, parts)
    else
        try joinCommandParts(alloc, parts);
    defer alloc.free(payload);
    const requires_payload = switch (tag) {
        .Output, .Send, .LabelSet => true,
        else => false,
    };
    if (requires_payload and payload.len == 0) return error.TextRequired;

    return sendPayload(io, alloc, cfg, session_name, tag, payload);
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
        try awaitResponse(alloc, connection, response_tag);
    }
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
    while (true) {
        var response = try session_windows.readFrameWithDeadline(
            alloc,
            connection,
            session_windows.Deadline.afterMs(5000),
            null,
        );
        if (response.header.tag == .TaskComplete) {
            response.deinit(alloc);
            continue;
        }
        if (response.header.tag != response_tag) {
            response.deinit(alloc);
            return error.Unexpected;
        }
        return response.payload;
    }
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
            try request_payload.append(alloc, try historyFormatByte(parts));
            expected = .History;
        },
        .LabelGet => {
            if (parts.len > 1) return error.UnsupportedCommand;
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
    } else if (command == .LabelGet and parts.len == 1) {
        const value = try label.getLabelValueFromPairs(parts[0], payload);
        try renderPayload(io, value);
    } else {
        try renderPayload(io, payload);
    }
}

const SessionDetails = struct {
    info: wire.Info,
    labels: []u8,
};

fn requestSessionDetails(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    session_name: []const u8,
) !SessionDetails {
    const endpoint = try socket.getSocketPathWithIo(io, alloc, cfg.socket_dir, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    try sendFrame(connection, .Info, "");
    try sendFrame(connection, .LabelGet, "");

    var info: ?wire.Info = null;
    var labels: ?[]u8 = null;
    errdefer if (labels) |value| alloc.free(value);
    const deadline = session_windows.Deadline.afterMs(5000);
    while (info == null or labels == null) {
        var response = try session_windows.readFrameWithDeadline(
            alloc,
            connection,
            deadline,
            null,
        );
        defer response.deinit(alloc);
        switch (response.header.tag) {
            .Info => {
                if (response.payload.len != @sizeOf(wire.Info)) return error.Unexpected;
                info = std.mem.bytesToValue(wire.Info, response.payload);
            },
            .LabelData => {
                if (labels != null) alloc.free(labels.?);
                labels = try alloc.dupe(u8, response.payload);
            },
            else => {},
        }
    }
    return .{ .info = info.?, .labels = labels.? };
}

fn writeSessionLine(
    writer: *std.Io.Writer,
    session_name: []const u8,
    info: wire.Info,
    labels: []const u8,
    short: bool,
    current_session: ?[]const u8,
) !void {
    if (short) {
        try writer.print("{s}\n", .{session_name});
        return;
    }
    const prefix = if (current_session) |current|
        if (std.mem.eql(u8, current, session_name)) "→ " else "  "
    else
        "";
    const cmd_len = @min(@as(usize, info.cmd_len), info.cmd.len);
    const cwd_len = @min(@as(usize, info.cwd_len), info.cwd.len);
    try writer.print("{s}name={s}\tpid={d}\tclients={d}\tcreated={d}", .{
        prefix,
        session_name,
        info.pid,
        info.clients_len,
        info.created_at,
    });
    if (cwd_len > 0) try writer.print("\tcwd={s}", .{info.cwd[0..cwd_len]});
    if (cmd_len > 0) try writer.print("\tcmd={s}", .{info.cmd[0..cmd_len]});
    if (info.task_ended_at > 0) {
        try writer.print("\tended={d}\texit_code={d}", .{
            info.task_ended_at,
            info.task_exit_code,
        });
    }
    var iterator = label.LabelIterator.init(labels);
    while (iterator.next()) |kv| {
        try writer.print("\t{s}={s}", .{ kv.key, kv.value });
    }
    try writer.print("\n", .{});
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
    std.mem.sort([]u8, sessions.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    const current_session = try socket.getSeshNameFromEnvAlloc(alloc);
    defer if (current_session) |name| alloc.free(name);
    if (sessions.items.len == 0) {
        if (short) return;
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        try writer.interface.print("no sessions found in {s}\n", .{cfg.socket_dir});
        try writer.interface.flush();
        return;
    }
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    for (sessions.items) |session_name| {
        const details = requestSessionDetails(io, alloc, cfg, session_name) catch |err| {
            if (!short) try writer.interface.print(
                "  name={s}\terr={s}\tstatus=unreachable\n",
                .{ session_name, @errorName(err) },
            );
            continue;
        };
        defer alloc.free(details.labels);
        try writeSessionLine(
            &writer.interface,
            session_name,
            details.info,
            details.labels,
            short,
            current_session,
        );
    }
    try writer.interface.flush();
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

fn waitForTask(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    raw_session_name: ?[]const u8,
) !void {
    const session_name = try socket.resolveSessionOrEnv(alloc, io, raw_session_name);
    defer alloc.free(session_name);
    while (true) {
        const payload = try requestResponse(
            io,
            alloc,
            cfg,
            session_name,
            .Info,
            &.{},
            .Info,
        );
        defer alloc.free(payload);
        if (payload.len != @sizeOf(wire.Info)) return error.Unexpected;
        const info = std.mem.bytesToValue(wire.Info, payload);
        if (info.task_ended_at != 0) {
            var buffer: [1024]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            if (info.task_exit_code == 0) {
                try writer.interface.print("task(s) completed!\n", .{});
            } else {
                try writer.interface.print(
                    "task(s) failed! exit_code={d}\n",
                    .{info.task_exit_code},
                );
            }
            try writer.interface.flush();
            if (info.task_exit_code != 0) return error.TaskFailed;
            return;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
    }
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

    const command = args.next() orelse {
        return listSessions(io, gpa, &cfg, &.{});
    };
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
        const session_name = try socket.resolveSessionOrEnv(gpa, io, args.next());
        defer gpa.free(session_name);
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

    if (std.mem.eql(u8, command, "detach") or
        std.mem.eql(u8, command, "d") or
        std.mem.eql(u8, command, "detach-all") or
        std.mem.eql(u8, command, "da"))
    {
        const session_name = try socket.resolveSessionOrEnv(gpa, io, args.next());
        defer gpa.free(session_name);
        if (args.next() != null) return error.UnsupportedCommand;
        return sendCommand(io, gpa, &cfg, session_name, .DetachAll, &.{});
    }

    if (std.mem.eql(u8, command, "wait") or std.mem.eql(u8, command, "w")) {
        const session_arg = args.next();
        if (args.next() != null) return error.UnsupportedCommand;
        return waitForTask(io, gpa, &cfg, session_arg);
    }

    if (std.mem.eql(u8, command, "resize")) {
        const session_name = try socket.resolveSessionOrEnv(gpa, io, args.next());
        defer gpa.free(session_name);
        const cols_text = args.next() orelse return error.InvalidSize;
        const rows_text = args.next() orelse return error.InvalidSize;
        const size = wire.Resize{
            .cols = try std.fmt.parseInt(u16, cols_text, 10),
            .rows = try std.fmt.parseInt(u16, rows_text, 10),
        };
        return sendPayload(io, gpa, &cfg, session_name, .Resize, std.mem.asBytes(&size));
    }

    if (wireTagForCommand(command)) |tag| {
        var session_arg: ?[]const u8 = null;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        if (tag == .History) {
            while (args.next()) |part| {
                if (std.mem.eql(u8, part, "--vt") or
                    std.mem.eql(u8, part, "--html"))
                {
                    try parts.append(gpa, part);
                } else if (session_arg == null) {
                    session_arg = part;
                } else {
                    try parts.append(gpa, part);
                }
            }
        } else {
            session_arg = args.next();
            while (args.next()) |part| try parts.append(gpa, part);
        }
        const session_name = if (tag == .History or tag == .LabelGet or tag == .Info)
            try socket.resolveSessionOrEnv(gpa, io, session_arg)
        else
            try socket.resolveSessionOrEnv(
                gpa,
                io,
                session_arg orelse return error.SessionNameRequired,
            );
        defer gpa.free(session_name);
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
    try std.testing.expectEqual(WireTag.DetachAll, try wireTagForCommand("detach"));
    try std.testing.expectEqual(WireTag.DetachAll, try wireTagForCommand("detach-all"));
    try std.testing.expectEqual(WireTag.Kill, try wireTagForCommand("kill"));
    try std.testing.expectEqual(WireTag.History, try wireTagForCommand("history"));
    try std.testing.expectEqual(WireTag.LabelGet, try wireTagForCommand("get"));
    try std.testing.expectEqual(WireTag.LabelSet, try wireTagForCommand("set"));
    try std.testing.expectEqual(WireTag.LabelClear, try wireTagForCommand("clear"));
    try std.testing.expectEqual(WireTag.Info, try wireTagForCommand("info"));
}

test "Windows command parity preserves stdin newline and history formats" {
    var send_payload: std.ArrayList(u8) = .empty;
    defer send_payload.deinit(std.testing.allocator);
    try send_payload.appendSlice(std.testing.allocator, "send\n");
    stripPipedNewline(&send_payload, .Send);
    try std.testing.expectEqualStrings("send", send_payload.items);

    var print_payload: std.ArrayList(u8) = .empty;
    defer print_payload.deinit(std.testing.allocator);
    try print_payload.appendSlice(std.testing.allocator, "print\n");
    stripPipedNewline(&print_payload, .Output);
    try std.testing.expectEqualStrings("print\n", print_payload.items);

    try std.testing.expectEqual(@as(u8, 0), try historyFormatByte(&.{}));
    try std.testing.expectEqual(@as(u8, 1), try historyFormatByte(&.{"--vt"}));
    try std.testing.expectEqual(@as(u8, 2), try historyFormatByte(&.{"--html"}));
    try std.testing.expectError(
        error.UnsupportedCommand,
        historyFormatByte(&.{"--unknown"}),
    );
}

test "Windows Write payload preserves path length and stdin bytes" {
    const payload = try encodeWritePayload(std.testing.allocator, "a\\b.txt", "contents");
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, payload[0..4], .little));
    try std.testing.expectEqualStrings("a\\b.txt", payload[4..11]);
    try std.testing.expectEqualStrings("contents", payload[11..]);
}

test "Windows production commands route run and attach through the session adapter" {
    const value = pty_session_windows.provider();
    try std.testing.expect(@intFromPtr(value.host_fn) != 0);
    try std.testing.expect(@intFromPtr(value.attach_fn) != 0);
}

test "Windows root exports the logging hook through std_options" {
    const root = @import("main.zig");
    root.std_options.logFn(.debug, .default, "Windows logging hook test", .{});
}
