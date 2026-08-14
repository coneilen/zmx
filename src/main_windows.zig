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
const resize = @import("platform/resize.zig");
const wire = @import("platform/session_wire.zig");
const label = @import("label.zig");
const completions = @import("completions.zig");

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
    while (true) {
        var response = try session_windows.readFrameWithDeadline(
            alloc,
            connection,
            session_windows.Deadline.afterMs(5000),
            null,
        );
        defer response.deinit(alloc);
        if (response.header.tag == expected_tag) return;
        if (response.header.tag == .Output or response.header.tag == .TaskComplete) continue;
        return error.Unexpected;
    }
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
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(alloc);
    while (true) {
        var response = try session_windows.readFrameWithDeadline(
            alloc,
            connection,
            session_windows.Deadline.afterMs(5000),
            null,
        );
        if (response.header.tag == .Output or response.header.tag == .TaskComplete) {
            response.deinit(alloc);
            continue;
        }
        if (response.header.tag != response_tag) {
            response.deinit(alloc);
            return error.Unexpected;
        }
        if (response_tag == .History) {
            if (response.payload.len == 0) {
                response.deinit(alloc);
                return history.toOwnedSlice(alloc);
            }
            try history.appendSlice(alloc, response.payload);
            response.deinit(alloc);
            continue;
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

fn printHelp(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(
        \\Usage: zmx <command> [session] [args...]
        \\
        \\Commands:
        \\  run, r       Run a task (use -d/--detach to detach)
        \\  attach, a    Attach to a session, creating it if needed
        \\  tail, t      Follow session output
        \\  send, s      Send input to the PTY
        \\  print, p     Broadcast output to attached clients and history
        \\  write, wr    Write stdin to a file through the session
        \\  list, ls     List sessions (bare `zmx` does the same)
        \\  kill, k      Kill one or more sessions (--force accepted)
        \\  detach, d   Detach all clients
        \\  wait, w      Wait for task completion
        \\  resize       Resize a session
        \\  history      Show session history (--vt or --html)
        \\  get, set     Read or set labels
        \\  unset        Remove labels
        \\  clear        Clear all labels
        \\  completions  Print shell completions
        \\  version      Show version
        \\
    );
    try writer.interface.flush();
}

fn printCompletions(io: std.Io, shell_name: []const u8) !void {
    const shell = completions.Shell.fromString(shell_name) orelse return error.UnsupportedCommand;
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(shell.getCompletionScript());
    try writer.interface.flush();
}

fn waitForTasks(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    raw_session_names: []const []const u8,
) !void {
    var matchers: std.ArrayList(socket.SessionMatch) = .empty;
    defer {
        for (matchers.items) |matcher| alloc.free(matcher.name);
        matchers.deinit(alloc);
    }
    if (raw_session_names.len == 0) {
        const current_session = try socket.resolveSessionOrEnv(alloc, io, null);
        defer alloc.free(current_session);
        try matchers.append(alloc, try socket.parseSessionArg(alloc, current_session));
    } else {
        for (raw_session_names) |raw_name| {
            try matchers.append(alloc, try socket.parseSessionArg(alloc, raw_name));
        }
    }

    var no_match_iterations: usize = 0;
    while (true) {
        var sessions = try runtime_windows.listSessionNames(io, alloc);
        defer {
            for (sessions.items) |name| alloc.free(name);
            sessions.deinit(alloc);
        }

        var total: usize = 0;
        var done: usize = 0;
        var aggregate_exit_code: u8 = 0;
        for (sessions.items) |session_name| {
            var matched = false;
            for (matchers.items) |matcher| {
                if (matcher.matches(session_name)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;

            total += 1;
            const payload = requestResponse(
                io,
                alloc,
                cfg,
                session_name,
                .Info,
                &.{},
                .Info,
            ) catch {
                aggregate_exit_code = 1;
                done += 1;
                continue;
            };
            defer alloc.free(payload);
            if (payload.len != @sizeOf(wire.Info)) return error.Unexpected;
            const info = std.mem.bytesToValue(wire.Info, payload);
            if (info.task_ended_at != 0) {
                done += 1;
                if (info.task_exit_code != 0) aggregate_exit_code = info.task_exit_code;
            }
        }

        if (total > 0 and total == done) {
            var buffer: [1024]u8 = undefined;
            var writer = std.Io.File.stdout().writer(io, &buffer);
            if (aggregate_exit_code == 0) {
                try writer.interface.print("task(s) completed!\n", .{});
            } else {
                try writer.interface.print(
                    "task(s) failed! exit_code={d}\n",
                    .{aggregate_exit_code},
                );
            }
            try writer.interface.flush();
            if (aggregate_exit_code != 0) return error.TaskFailed;
            return;
        }
        if (total == 0) {
            no_match_iterations += 1;
            if (no_match_iterations >= 5) return error.NoMatchingSessions;
        } else {
            no_match_iterations = 0;
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
    initial_size: ?resize.Size,
) !void {
    const spec = session_windows.HostSpec{
        .io = io,
        .alloc = alloc,
        .session_name = session_name,
        .shell = "cmd.exe",
        .task_mode = command != null,
        .command = command,
        .initial_size = initial_size,
    };
    if (detached) return pty_session_windows.hostDetached(spec);
    return session_windows.host(spec, pty_session_windows.provider());
}

fn attachTaskSession(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) !u8 {
    const endpoint = try runtime_windows.resolveEndpointPath(io, alloc, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    return pty_session_windows.attachForeground(
        .{
            .io = io,
            .alloc = alloc,
            .session_name = session_name,
        },
        connection,
    );
}

fn tailSession(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) !void {
    const endpoint = try runtime_windows.resolveEndpointPath(io, alloc, session_name);
    defer alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(alloc, .{ .name = endpoint });
    defer connection.close();
    const exit_code = try pty_session_windows.tail(
        .{
            .io = io,
            .alloc = alloc,
            .session_name = session_name,
        },
        connection,
    );
    if (exit_code != 0) return error.TaskFailed;
}

const TailContext = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    output_lock: std.atomic.Value(u8) = .init(0),
    error_lock: std.atomic.Value(u8) = .init(0),
    first_error: ?anyerror = null,
};

fn tailWorkerMain(context: *TailContext, session_name: []const u8) void {
    const endpoint = runtime_windows.resolveEndpointPath(
        context.io,
        context.alloc,
        session_name,
    ) catch |err| {
        lockTailError(&context.error_lock);
        if (context.first_error == null) context.first_error = err;
        unlockTailError(&context.error_lock);
        return;
    };
    defer context.alloc.free(endpoint);
    var connection = local_ipc_windows.connect(
        context.alloc,
        .{ .name = endpoint },
    ) catch |err| {
        lockTailError(&context.error_lock);
        if (context.first_error == null) context.first_error = err;
        unlockTailError(&context.error_lock);
        return;
    };
    defer connection.close();
    const exit_code = pty_session_windows.tailToWriter(
        .{
            .io = context.io,
            .alloc = context.alloc,
            .session_name = session_name,
        },
        connection,
        context.writer,
        &context.output_lock,
    ) catch |err| {
        lockTailError(&context.error_lock);
        if (context.first_error == null) context.first_error = err;
        unlockTailError(&context.error_lock);
        return;
    };
    if (exit_code != 0) {
        lockTailError(&context.error_lock);
        if (context.first_error == null) context.first_error = error.TaskFailed;
        unlockTailError(&context.error_lock);
    }
}

fn lockTailError(lock: *std.atomic.Value(u8)) void {
    while (lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockTailError(lock: *std.atomic.Value(u8)) void {
    lock.store(0, .release);
}

fn tailSessions(
    io: std.Io,
    alloc: std.mem.Allocator,
    raw_args: []const []const u8,
) !void {
    var matchers: std.ArrayList(socket.SessionMatch) = .empty;
    defer {
        for (matchers.items) |matcher| alloc.free(matcher.name);
        matchers.deinit(alloc);
    }
    if (raw_args.len == 0) {
        const current = (try socket.getSeshNameFromEnvAlloc(alloc)) orelse
            return error.SessionNameRequired;
        try matchers.append(alloc, .{ .name = current, .is_prefix = false });
    } else {
        for (raw_args) |raw| {
            if (std.mem.eql(u8, raw, "--help") or std.mem.eql(u8, raw, "-h")) {
                return printHelp(io);
            }
            if (std.mem.eql(u8, raw, ".")) {
                const current = (try socket.getSeshNameFromEnvAlloc(alloc)) orelse
                    return error.SessionNameRequired;
                try matchers.append(alloc, .{ .name = current, .is_prefix = false });
            } else {
                try matchers.append(alloc, try socket.parseSessionArg(alloc, raw));
            }
        }
    }

    var targets: std.ArrayList([]u8) = .empty;
    defer {
        for (targets.items) |target| alloc.free(target);
        targets.deinit(alloc);
    }
    var sessions: ?std.ArrayList([]u8) = null;
    defer if (sessions) |*names| {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    };

    for (matchers.items) |matcher| {
        if (matcher.is_prefix) {
            if (sessions == null) sessions = try runtime_windows.listSessionNames(io, alloc);
            for (sessions.?.items) |name| {
                if (!matcher.matches(name)) continue;
                var duplicate = false;
                for (targets.items) |target| {
                    if (std.mem.eql(u8, target, name)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try targets.append(alloc, try alloc.dupe(u8, name));
            }
        } else {
            var duplicate = false;
            for (targets.items) |target| {
                if (std.mem.eql(u8, target, matcher.name)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try targets.append(alloc, try alloc.dupe(u8, matcher.name));
        }
    }
    if (targets.items.len == 0) return error.NoMatchingSessions;

    if (targets.items.len == 1) {
        return tailSession(io, alloc, targets.items[0]);
    }

    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &output_buffer);
    var context = TailContext{
        .io = io,
        .alloc = alloc,
        .writer = &writer.interface,
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(alloc);
    for (targets.items) |target| {
        threads.append(
            alloc,
            std.Thread.spawn(.{}, tailWorkerMain, .{ &context, target }) catch |err| {
                for (threads.items) |thread| thread.join();
                return err;
            },
        ) catch |err| {
            for (threads.items) |thread| thread.join();
            return err;
        };
    }
    for (threads.items) |thread| thread.join();
    if (context.first_error) |err| return err;
    try writer.interface.flush();
}

fn runForegroundSession(
    io: std.Io,
    alloc: std.mem.Allocator,
    program: []const u8,
    session_name: []const u8,
    command: ?[]const []const u8,
) !void {
    try spawnDetached(io, program, alloc, session_name, command);
    const exit_code = try attachTaskSession(io, alloc, session_name);
    if (exit_code != 0) return error.TaskFailed;
}

fn killSessions(
    io: std.Io,
    alloc: std.mem.Allocator,
    cfg: *const Cfg,
    raw_args: []const []const u8,
) !void {
    var matchers: std.ArrayList(socket.SessionMatch) = .empty;
    defer {
        for (matchers.items) |matcher| alloc.free(matcher.name);
        matchers.deinit(alloc);
    }
    var force = false;
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return printHelp(io);
        }
        try matchers.append(alloc, try socket.parseSessionArg(alloc, arg));
    }
    if (matchers.items.len == 0) return error.SessionNameRequired;

    var sessions = try runtime_windows.listSessionNames(io, alloc);
    defer {
        for (sessions.items) |name| alloc.free(name);
        sessions.deinit(alloc);
    }
    var matched_count: usize = 0;
    for (sessions.items) |session_name| {
        var matched = false;
        for (matchers.items) |matcher| {
            if (matcher.matches(session_name)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        matched_count += 1;
        sendPayload(io, alloc, cfg, session_name, .Kill, &.{}) catch |err| {
            if (!force) return err;
        };
    }
    if (matched_count == 0) return error.NoMatchingSessions;
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
        @import("platform/events_windows.zig").Deadline.afterMs(1000),
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
    var initial_size_arg: ?[]u8 = null;
    defer if (initial_size_arg) |value| alloc.free(value);
    if (pty_session_windows.currentConsoleSize()) |size| {
        initial_size_arg = try std.fmt.allocPrint(
            alloc,
            "--zmx-initial-size={d}x{d}",
            .{ size.cols, size.rows },
        );
        try argv.append(alloc, initial_size_arg.?);
    }
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

    for (0..30) |_| {
        const probe_endpoint = runtime_windows.resolveEndpointPath(io, alloc, session_name) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
            continue;
        };
        defer alloc.free(probe_endpoint);
        var probe = local_ipc_windows.reconnect(
            alloc,
            .{ .name = probe_endpoint },
            @import("platform/events_windows.zig").Deadline.afterMs(1000),
            null,
        ) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
            continue;
        };
        probe.close();
        return;
    }
    return error.SessionStartupTimeout;
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

fn sessionIsReachable(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) !bool {
    const endpoint = try runtime_windows.resolveEndpointPath(io, alloc, session_name);
    defer alloc.free(endpoint);
    var connection = local_ipc_windows.reconnect(
        alloc,
        .{ .name = endpoint },
        @import("platform/events_windows.zig").Deadline.afterMs(1000),
        null,
    ) catch return false;
    connection.close();
    return true;
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
    if (std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "h") or
        std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--help"))
    {
        return printHelp(io);
    }
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
        var initial_size: ?resize.Size = null;
        while (args.next()) |part| try command_args.append(gpa, part);
        if (command_args.items.len > 0 and
            std.mem.startsWith(u8, command_args.items[0], "--zmx-initial-size="))
        {
            const encoded = command_args.orderedRemove(0)["--zmx-initial-size=".len..];
            const separator = std.mem.indexOfScalar(u8, encoded, 'x') orelse
                return error.InvalidSize;
            initial_size = .{
                .cols = try std.fmt.parseInt(u16, encoded[0..separator], 10),
                .rows = try std.fmt.parseInt(u16, encoded[separator + 1 ..], 10),
            };
            if (!resize.isUsable(initial_size.?)) return error.InvalidSize;
        }
        const command_slice: ?[]const []const u8 =
            if (command_args.items.len == 0) null else command_args.items;
        return runSession(io, gpa, session_name, command_slice, false, initial_size);
    }

    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "r")) {
        const raw_session_name = args.next() orelse return error.SessionNameRequired;
        if (std.mem.eql(u8, raw_session_name, "--help") or std.mem.eql(u8, raw_session_name, "-h")) {
            return printHelp(io);
        }
        const session_name = try socket.getSeshName(gpa, raw_session_name);
        defer gpa.free(session_name);
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
        return runForegroundSession(io, gpa, program, session_name, command_slice);
    }

    if (std.mem.eql(u8, command, "attach") or std.mem.eql(u8, command, "a")) {
        const raw_session_name = args.next();
        if (raw_session_name) |name| {
            if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
                return printHelp(io);
            }
        }
        const session_name = try socket.resolveSessionOrEnv(gpa, io, raw_session_name);
        defer gpa.free(session_name);
        var command_args: std.ArrayList([]const u8) = .empty;
        defer command_args.deinit(gpa);
        while (args.next()) |part| try command_args.append(gpa, part);
        if (command_args.items.len > 0 and
            std.mem.eql(u8, command_args.items[0], "cmd/pwsh"))
        {
            command_args.items[0] = "pwsh";
        }
        if (!try sessionIsReachable(io, gpa, session_name)) {
            spawnDetached(
                io,
                program,
                gpa,
                session_name,
                if (command_args.items.len == 0) null else command_args.items,
            ) catch |err| switch (err) {
                error.SessionAlreadyExists => {},
                else => return err,
            };
        }
        return attachSession(io, gpa, session_name);
    }

    if (std.mem.eql(u8, command, "tail") or std.mem.eql(u8, command, "t")) {
        var tail_args: std.ArrayList([]const u8) = .empty;
        defer tail_args.deinit(gpa);
        while (args.next()) |part| try tail_args.append(gpa, part);
        return tailSessions(io, gpa, tail_args.items);
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
        var session_args: std.ArrayList([]const u8) = .empty;
        defer session_args.deinit(gpa);
        while (args.next()) |session_arg| {
            if (std.mem.eql(u8, session_arg, "--help") or
                std.mem.eql(u8, session_arg, "-h"))
            {
                return printHelp(io);
            }
            try session_args.append(gpa, session_arg);
        }
        return waitForTasks(io, gpa, &cfg, session_args.items);
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

    if (std.mem.eql(u8, command, "kill") or std.mem.eql(u8, command, "k")) {
        var kill_args: std.ArrayList([]const u8) = .empty;
        defer kill_args.deinit(gpa);
        while (args.next()) |part| try kill_args.append(gpa, part);
        return killSessions(io, gpa, &cfg, kill_args.items);
    }

    if (std.mem.eql(u8, command, "unset")) {
        const session_name = try socket.resolveSessionOrEnv(gpa, io, args.next());
        defer gpa.free(session_name);
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(gpa);
        while (args.next()) |key| {
            if (std.mem.eql(u8, key, "--help") or std.mem.eql(u8, key, "-h")) {
                return printHelp(io);
            }
            try keys.append(gpa, key);
        }
        if (keys.items.len == 0) return error.TextRequired;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        for (keys.items, 0..) |key, index| {
            if (index != 0) try payload.append(gpa, ' ');
            try payload.appendSlice(gpa, key);
            try payload.append(gpa, '=');
        }
        return sendPayload(io, gpa, &cfg, session_name, .LabelSet, payload.items);
    }

    if (std.mem.eql(u8, command, "completions") or
        std.mem.eql(u8, command, "c"))
    {
        const shell_name = args.next() orelse return;
        if (std.mem.eql(u8, shell_name, "--help") or std.mem.eql(u8, shell_name, "-h")) {
            return printHelp(io);
        }
        if (args.next() != null) return error.UnsupportedCommand;
        return printCompletions(io, shell_name);
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
