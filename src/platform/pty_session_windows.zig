const builtin = @import("builtin");
const std = @import("std");
const pty = @import("pty.zig");
const pty_runtime = @import("pty_runtime.zig");
const local_ipc = @import("local_ipc.zig");
const local_ipc_windows = @import("local_ipc_windows.zig");
const runtime_windows = @import("runtime_windows.zig");
const session_windows = @import("session_windows.zig");
const wire = @import("session_wire.zig");
const windows = std.os.windows;

const kernel32 = struct {
    extern "kernel32" fn CancelSynchronousIo(thread: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetStdHandle(which: windows.DWORD) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn PeekNamedPipe(
        pipe: windows.HANDLE,
        buffer: ?[*]u8,
        buffer_length: windows.DWORD,
        bytes_read: ?*windows.DWORD,
        total_bytes_available: *windows.DWORD,
        bytes_left_this_message: ?*windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadFile(
        file: windows.HANDLE,
        buffer: [*]u8,
        length: windows.DWORD,
        read: *windows.DWORD,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
};

const std_input_handle: windows.DWORD = @bitCast(@as(i32, -10));

comptime {
    if (builtin.os.tag != .windows) @compileError("pty_session_windows requires a Windows target");
}

const Session = struct {
    alloc: std.mem.Allocator,
    spec: session_windows.HostSpec,
    server: local_ipc.Server,
    runtime: pty_runtime.Runtime,
    master: pty.Handle,
    process: pty.ProcessId,
    alive: std.atomic.Value(bool) = .init(true),
    task_complete: std.atomic.Value(bool) = .init(false),
    active_clients: std.atomic.Value(u64) = .init(0),
    lock_word: std.atomic.Value(u8) = .init(0),
    clients: std.ArrayList(*Client) = .empty,
    reader_thread: ?std.Thread = null,
    labels: std.StringHashMapUnmanaged([]const u8) = .empty,
    history: std.ArrayList(u8) = .empty,
    task_ended_at: u64 = 0,
    task_exit_code: u8 = 0,

    const max_history_bytes = Client.max_output_bytes - @sizeOf(wire.Header);

    fn lock(self: *Session) void {
        while (self.lock_word.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Session) void {
        self.lock_word.store(0, .release);
    }
};

const Client = struct {
    session: *Session,
    connection: local_ipc.Connection,
    closed: std.atomic.Value(bool) = .init(false),
    connection_closed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    output_lock: std.atomic.Value(u8) = .init(0),
    output: std.ArrayList(u8) = .empty,
    output_closed: bool = false,

    const max_output_bytes = 256 * 1024;

    fn lockOutput(self: *Client) void {
        while (self.output_lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockOutput(self: *Client) void {
        self.output_lock.store(0, .release);
    }

    fn closeOutput(self: *Client) void {
        self.lockOutput();
        self.output_closed = true;
        self.unlockOutput();
    }

    fn eject(self: *Client) void {
        self.closed.store(true, .release);
        self.lockOutput();
        self.output.clearRetainingCapacity();
        self.output_closed = true;
        self.unlockOutput();
        self.closeConnection();
    }

    fn closeConnection(self: *Client) void {
        if (self.connection_closed.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
            self.connection.close();
        }
    }

    fn enqueue(self: *Client, tag: wire.Tag, payload: []const u8) !void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.session.alloc);
        const header = wire.Header{ .tag = tag, .len = @intCast(payload.len) };
        try frame.appendSlice(self.session.alloc, std.mem.asBytes(&header));
        try frame.appendSlice(self.session.alloc, payload);

        self.lockOutput();
        defer self.unlockOutput();
        if (self.output_closed or self.output.items.len + frame.items.len > max_output_bytes) {
            self.output_closed = true;
            self.closed.store(true, .release);
            return error.WouldBlock;
        }
        try self.output.appendSlice(self.session.alloc, frame.items);
    }
};

pub fn provider() session_windows.Provider {
    return .{
        .context = undefined,
        .host_fn = hostThunk,
        .attach_fn = attachThunk,
    };
}

pub fn hostDetached(spec: session_windows.HostSpec) !void {
    return session_windows.host(spec, provider());
}

fn hostThunk(
    _: *anyopaque,
    spec: session_windows.HostSpec,
    server: local_ipc.Server,
) anyerror!void {
    const session = try createSession(spec, server);
    sessionMain(session);
}

fn attachThunk(
    _: *anyopaque,
    spec: session_windows.AttachSpec,
    connection: local_ipc.Connection,
) anyerror!void {
    return attachLoop(spec, connection);
}

fn createSession(spec: session_windows.HostSpec, server: local_ipc.Server) !*Session {
    const session = try spec.alloc.create(Session);
    errdefer spec.alloc.destroy(session);
    var runtime = pty_runtime.Runtime.init(spec.alloc);
    errdefer runtime.deinit();
    const spawned = try runtime.spawn(.{
        .session_name = spec.session_name,
        .shell = spec.shell,
        .task_mode = spec.task_mode,
        .command = spec.command,
        .size = .{ .rows = 24, .cols = 80 },
    });
    session.* = .{
        .alloc = spec.alloc,
        .spec = spec,
        .server = server,
        .runtime = runtime,
        .master = spawned.master,
        .process = spawned.process,
    };
    session.reader_thread = try std.Thread.spawn(.{}, readerMain, .{session});
    return session;
}

fn sessionMain(session: *Session) void {
    defer destroySession(session);
    while (session.alive.load(.acquire)) {
        reapClients(session);
        const connection = local_ipc_windows.acceptServerWithDeadline(
            session.server,
            @import("events_windows.zig").Deadline.afterMs(250),
            null,
        ) catch |err| switch (err) {
            error.Timeout => continue,
            error.AlreadyClosed => break,
            else => {
                session.alive.store(false, .release);
                break;
            },
        };
        const client = session.alloc.create(Client) catch {
            connection.close();
            continue;
        };
        client.* = .{ .session = session, .connection = connection };
        session.lock();
        session.clients.append(session.alloc, client) catch {
            session.unlock();
            connection.close();
            session.alloc.destroy(client);
            continue;
        };
        session.unlock();
        _ = session.active_clients.fetchAdd(1, .acq_rel);
        client.thread = std.Thread.spawn(.{}, clientMain, .{client}) catch blk: {
            client.closed.store(true, .release);
            client.closeConnection();
            _ = session.active_clients.fetchSub(1, .acq_rel);
            break :blk null;
        };
        if (client.thread != null) {
            client.writer_thread = std.Thread.spawn(.{}, writerMain, .{client}) catch blk: {
                client.closed.store(true, .release);
                client.eject();
                break :blk null;
            };
        }
    }
}

fn reapClients(session: *Session) void {
    while (true) {
        session.lock();
        var found: ?*Client = null;
        for (session.clients.items, 0..) |client, index| {
            if (!client.closed.load(.acquire)) continue;
            found = client;
            _ = session.clients.swapRemove(index);
            break;
        }
        session.unlock();

        const client = found orelse return;
        if (client.thread) |thread| thread.join();
        if (client.writer_thread) |thread| thread.join();
        client.output.deinit(session.alloc);
        session.alloc.destroy(client);
    }
}

fn destroySession(session: *Session) void {
    session.alive.store(false, .release);
    session.server.close();
    if (session.reader_thread) |thread| thread.join();

    session.lock();
    const clients = session.clients.items;
    for (clients) |client| client.closed.store(true, .release);
    session.unlock();

    for (clients) |client| {
        client.closeOutput();
        client.closeConnection();
    }
    for (clients) |client| {
        if (client.thread) |thread| thread.join();
        if (client.writer_thread) |thread| thread.join();
        client.output.deinit(session.alloc);
        session.alloc.destroy(client);
    }
    session.clients.deinit(session.alloc);
    session.history.deinit(session.alloc);
    var labels = session.labels;
    var label_it = labels.iterator();
    while (label_it.next()) |entry| {
        session.alloc.free(entry.key_ptr.*);
        session.alloc.free(entry.value_ptr.*);
    }
    labels.deinit(session.alloc);
    session.runtime.close(session.master);
    session.runtime.reap(session.process);
    session.runtime.deinit();
    session.alloc.destroy(session);
}

fn readerMain(session: *Session) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (session.alive.load(.acquire)) {
        const amount = session.runtime.read(session.master, &buffer) catch |err| switch (err) {
            error.WouldBlock => {
                _ = std.Thread.yield() catch {};
                continue;
            },
            else => break,
        };
        if (amount == 0) break;
        recordHistory(session, buffer[0..amount]);
        broadcast(session, .Output, buffer[0..amount]);
    }

    if (session.spec.task_mode and session.alive.load(.acquire)) {
        const exit_code = session.runtime.wait(session.process) catch 1;
        session.lock();
        session.task_exit_code = @intCast(@min(exit_code, @as(u32, std.math.maxInt(u8))));
        session.task_ended_at = @intCast(std.Io.Timestamp.now(session.spec.io, .real).toSeconds());
        session.task_complete.store(true, .release);
        const task_exit_code = session.task_exit_code;
        session.unlock();
        const payload = [_]u8{task_exit_code};
        broadcast(session, .TaskComplete, &payload);
        return;
    }

    session.alive.store(false, .release);
    session.server.close();
}

fn recordHistory(session: *Session, payload: []const u8) void {
    session.lock();
    defer session.unlock();
    if (payload.len >= Session.max_history_bytes) {
        session.history.clearRetainingCapacity();
        session.history.appendSlice(session.alloc, payload[payload.len - Session.max_history_bytes ..]) catch {};
        return;
    }
    const overflow = session.history.items.len + payload.len -| Session.max_history_bytes;
    if (overflow > 0) {
        const remaining = session.history.items.len - overflow;
        std.mem.copyForwards(u8, session.history.items[0..remaining], session.history.items[overflow..]);
        session.history.shrinkRetainingCapacity(remaining);
    }
    session.history.appendSlice(session.alloc, payload) catch {};
}

fn broadcast(session: *Session, tag: wire.Tag, payload: []const u8) void {
    session.lock();
    defer session.unlock();
    for (session.clients.items) |client| {
        if (client.closed.load(.acquire)) continue;
        client.enqueue(tag, payload) catch client.eject();
    }
}

fn writePty(session: *Session, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len and session.alive.load(.acquire)) {
        const amount = session.runtime.write(session.master, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => {
                _ = std.Thread.yield() catch {};
                continue;
            },
            else => return,
        };
        if (amount == 0) return;
        offset += amount;
    }
}

fn clientMain(client: *Client) void {
    const session = client.session;
    if (session.task_complete.load(.acquire)) sendTaskComplete(client);
    defer {
        client.closed.store(true, .release);
        client.closeOutput();
        client.closeConnection();
        _ = session.active_clients.fetchSub(1, .acq_rel);
    }
    while (!client.closed.load(.acquire) and session.alive.load(.acquire)) {
        var frame = wire.readFrame(session.alloc, client.connection) catch break;
        defer frame.deinit(session.alloc);
        switch (frame.header.tag) {
            .Input, .Send => writePty(session, frame.payload),
            .Output => {},
            .Resize, .Init => {
                if (frame.payload.len == @sizeOf(wire.Resize)) {
                    const size = std.mem.bytesToValue(wire.Resize, frame.payload);
                    session.runtime.resize(session.master, size) catch {};
                }
            },
            .Kill => {
                session.runtime.signal(session.process, .kill) catch {};
                session.alive.store(false, .release);
                break;
            },
            .Detach => break,
            .DetachAll => {
                detachAll(session);
                break;
            },
            .Info => sendInfo(client),
            .LabelGet => sendLabels(client),
            .LabelSet => setLabels(client, frame.payload),
            .LabelClear => clearLabels(client),
            .History => sendHistory(client, frame.payload),
            .Write => writeFile(client, frame.payload),
            else => {},
        }
    }
}

fn detachAll(session: *Session) void {
    session.lock();
    defer session.unlock();
    for (session.clients.items) |other| {
        other.closed.store(true, .release);
        other.closeOutput();
        other.closeConnection();
    }
}

fn writerMain(client: *Client) void {
    const alloc = client.session.alloc;
    while (true) {
        client.lockOutput();
        if (client.output.items.len == 0 and client.output_closed) {
            client.unlockOutput();
            return;
        }
        if (client.output.items.len == 0) {
            client.unlockOutput();
            _ = std.Thread.yield() catch {};
            continue;
        }
        var pending = std.ArrayList(u8).empty;
        std.mem.swap(std.ArrayList(u8), &client.output, &pending);
        client.unlockOutput();
        defer pending.deinit(alloc);
        client.connection.writeAll(pending.items) catch {
            client.eject();
            return;
        };
    }
}

fn sendInfo(client: *Client) void {
    var info = std.mem.zeroes(wire.Info);
    info.pid = @intCast(client.session.process);
    info.clients_len = client.session.active_clients.load(.acquire) -| 1;
    client.session.lock();
    info.task_ended_at = client.session.task_ended_at;
    info.task_exit_code = client.session.task_exit_code;
    client.session.unlock();
    const command = client.session.spec.command orelse &[_][]const u8{};
    var command_len: usize = 0;
    for (command, 0..) |part, index| {
        command_len += part.len + @intFromBool(index != 0);
    }
    info.cmd_len = @intCast(@min(command_len, info.cmd.len));
    var offset: usize = 0;
    for (command, 0..) |part, index| {
        if (index != 0 and offset < info.cmd.len) {
            info.cmd[offset] = ' ';
            offset += 1;
        }
        const amount = @min(part.len, info.cmd.len -| offset);
        @memcpy(info.cmd[offset .. offset + amount], part[0..amount]);
        offset += amount;
    }
    client.enqueue(.Info, std.mem.asBytes(&info)) catch client.eject();
}

fn sendLabels(client: *Client) void {
    const session = client.session;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(session.alloc);
    session.lock();
    var it = session.labels.iterator();
    while (it.next()) |entry| {
        if (payload.items.len != 0) payload.append(session.alloc, ' ') catch break;
        payload.appendSlice(session.alloc, entry.key_ptr.*) catch break;
        payload.append(session.alloc, '=') catch break;
        payload.appendSlice(session.alloc, entry.value_ptr.*) catch break;
    }

    session.unlock();
    client.enqueue(.LabelData, payload.items) catch client.eject();
}

fn sendTaskComplete(client: *Client) void {
    const session = client.session;
    session.lock();
    const exit_code = session.task_exit_code;
    session.unlock();
    const payload = [_]u8{exit_code};
    client.enqueue(.TaskComplete, &payload) catch client.eject();
}

fn sendHistory(client: *Client, request: []const u8) void {
    const session = client.session;
    const format: u8 = if (request.len == 0) 0 else request[0];
    session.lock();
    const history = session.alloc.dupe(u8, session.history.items) catch {
        session.unlock();
        client.eject();
        return;
    };
    session.unlock();
    defer session.alloc.free(history);
    const formatted = serializeHistory(session.alloc, history, format) catch {
        client.eject();
        return;
    };
    defer session.alloc.free(formatted);
    client.enqueue(.History, formatted) catch client.eject();
}

fn serializeHistory(
    alloc: std.mem.Allocator,
    payload: []const u8,
    format: u8,
) ![]u8 {
    switch (format) {
        0, 1 => return alloc.dupe(u8, payload),
        2 => {
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(alloc);
            try output.appendSlice(alloc, "<pre>");
            for (payload) |byte| switch (byte) {
                '&' => try output.appendSlice(alloc, "&amp;"),
                '<' => try output.appendSlice(alloc, "&lt;"),
                '>' => try output.appendSlice(alloc, "&gt;"),
                '"' => try output.appendSlice(alloc, "&quot;"),
                else => try output.append(alloc, byte),
            };
            try output.appendSlice(alloc, "</pre>\n");
            return output.toOwnedSlice(alloc);
        },
        else => return error.UnsupportedHistoryFormat,
    }
}

fn setLabels(client: *Client, payload: []const u8) void {
    const session = client.session;
    session.lock();
    var iter = std.mem.splitScalar(u8, payload, ' ');
    while (iter.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        const owned_key = session.alloc.dupe(u8, key) catch continue;
        const owned_value = session.alloc.dupe(u8, value) catch {
            session.alloc.free(owned_key);
            continue;
        };
        if (session.labels.fetchPut(session.alloc, owned_key, owned_value) catch null) |old| {
            session.alloc.free(old.key);
            session.alloc.free(old.value);
        }
    }
    session.unlock();
    client.enqueue(.Ack, "") catch client.eject();
}

fn clearLabels(client: *Client) void {
    const session = client.session;
    session.lock();
    var it = session.labels.iterator();
    while (it.next()) |entry| {
        session.alloc.free(entry.key_ptr.*);
        session.alloc.free(entry.value_ptr.*);
    }
    session.labels.clearRetainingCapacity();
    session.unlock();
    client.enqueue(.Ack, "") catch client.eject();
}

fn writeFile(client: *Client, payload: []const u8) void {
    const session = client.session;
    if (payload.len < @sizeOf(u32)) {
        client.enqueue(.Ack, "") catch client.eject();
        return;
    }
    const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
    if (payload.len < @sizeOf(u32) + path_len) {
        client.enqueue(.Ack, "") catch client.eject();
        return;
    }
    const path = payload[@sizeOf(u32)..][0..path_len];
    const content = payload[@sizeOf(u32) + path_len ..];
    var file = std.Io.Dir.cwd().createFile(session.spec.io, path, .{ .truncate = true }) catch {
        client.enqueue(.Ack, "") catch client.eject();
        return;
    };
    defer file.close(session.spec.io);
    _ = file.writeStreamingAll(session.spec.io, content) catch {};
    client.enqueue(.Ack, "") catch client.eject();
}

fn attachLoop(spec: session_windows.AttachSpec, connection: local_ipc.Connection) !void {
    var stop = std.atomic.Value(bool).init(false);
    const stdin_file = std.Io.File.stdin();
    var input = AttachInput{
        .io = spec.io,
        .alloc = spec.alloc,
        .connection = connection,
        .stdin_file = stdin_file,
        .stop = &stop,
    };
    const input_thread = try std.Thread.spawn(.{}, attachInputMain, .{&input});
    defer {
        stop.store(true, .release);
        _ = kernel32.CancelSynchronousIo(input_thread.getHandle());
        stdin_file.close(spec.io);
        input_thread.join();
    }

    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(spec.io, &output_buffer);
    while (!stop.load(.acquire)) {
        var frame = wire.readFrame(spec.alloc, connection) catch break;
        defer frame.deinit(spec.alloc);
        switch (frame.header.tag) {
            .Output => {
                try writer.interface.writeAll(frame.payload);
                try writer.interface.flush();
            },
            .TaskComplete => stop.store(true, .release),
            else => {},
        }
    }
}

const AttachInput = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
    stdin_file: std.Io.File,
    stop: *std.atomic.Value(bool),
};

fn attachInputMain(input: *AttachInput) void {
    var input_buffer: [4096]u8 = undefined;
    const stdin_handle = kernel32.GetStdHandle(std_input_handle);
    while (!input.stop.load(.acquire)) {
        var available: windows.DWORD = 0;
        if (@intFromEnum(kernel32.PeekNamedPipe(
            stdin_handle,
            null,
            0,
            null,
            &available,
            null,
        )) != 0 and available == 0) {
            kernel32.Sleep(10);
            continue;
        }
        var amount: windows.DWORD = 0;
        if (@intFromEnum(kernel32.ReadFile(
            stdin_handle,
            &input_buffer,
            @intCast(input_buffer.len),
            &amount,
            null,
        )) == 0 or amount == 0) break;
        wire.writeFrame(input.connection, .Input, input_buffer[0..amount]) catch break;
    }
}

test "Windows PTY session provider exposes the frozen provider shape" {
    const value = provider();
    try std.testing.expect(@intFromPtr(value.host_fn) != 0);
    try std.testing.expect(@intFromPtr(value.attach_fn) != 0);
}

test "Windows history serializers preserve plain VT and HTML formats" {
    const raw = "<&\n";
    const plain = try serializeHistory(std.testing.allocator, raw, 0);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(raw, plain);

    const vt = try serializeHistory(std.testing.allocator, raw, 1);
    defer std.testing.allocator.free(vt);
    try std.testing.expectEqualStrings(raw, vt);

    const html = try serializeHistory(std.testing.allocator, raw, 2);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<pre>&lt;&amp;\n</pre>\n", html);
    try std.testing.expectError(
        error.UnsupportedHistoryFormat,
        serializeHistory(std.testing.allocator, raw, 3),
    );
}
