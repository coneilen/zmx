const builtin = @import("builtin");
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const pty = @import("pty.zig");
const pty_runtime = @import("pty_runtime.zig");
const resize = @import("resize.zig");
const local_ipc = @import("local_ipc.zig");
const local_ipc_windows = @import("local_ipc_windows.zig");
const runtime_windows = @import("runtime_windows.zig");
const session_windows = @import("session_windows.zig");
const wire = @import("session_wire.zig");
const input_classifier = @import("input_classifier.zig");
const terminal_state = @import("terminal_state.zig");
const windows = std.os.windows;

const kernel32 = struct {
    extern "kernel32" fn CancelSynchronousIo(thread: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateEventW(
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        manual_reset: windows.BOOL,
        initial_state: windows.BOOL,
        name: ?[*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) windows.UINT;
    extern "kernel32" fn GetConsoleMode(
        console: windows.HANDLE,
        mode: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        console: windows.HANDLE,
        info: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) windows.BOOL;
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
    extern "kernel32" fn SetConsoleCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleMode(
        console: windows.HANDLE,
        mode: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetConsoleOutputCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
    extern "kernel32" fn WaitForSingleObject(
        handle: windows.HANDLE,
        milliseconds: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;
};

const std_input_handle: windows.DWORD = @bitCast(@as(i32, -10));
const std_output_handle: windows.DWORD = @bitCast(@as(i32, -11));
const enableProcessedInput: windows.DWORD = 0x0001;
const enableLineInput: windows.DWORD = 0x0002;
const enableEchoInput: windows.DWORD = 0x0004;
const cp_utf8: windows.UINT = 65001;
const history_chunk_bytes: usize = 64 * 1024 - @sizeOf(wire.Header);
const foreground_init = "zmx-foreground-history";

const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

const TerminalStream = @TypeOf((@as(*ghostty_vt.Terminal, undefined)).vtStream());

pub fn currentConsoleSize() ?resize.Size {
    const output = kernel32.GetStdHandle(std_output_handle);
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (@intFromEnum(kernel32.GetConsoleScreenBufferInfo(output, &info)) == 0) return null;
    const cols: i32 = @as(i32, @intCast(info.srWindow.Right)) -
        @as(i32, @intCast(info.srWindow.Left)) + 1;
    const rows: i32 = @as(i32, @intCast(info.srWindow.Bottom)) -
        @as(i32, @intCast(info.srWindow.Top)) + 1;
    if (cols <= 0 or rows <= 0) return null;
    return .{
        .cols = @intCast(@min(cols, std.math.maxInt(u16))),
        .rows = @intCast(@min(rows, std.math.maxInt(u16))),
    };
}

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
    terminal: ghostty_vt.Terminal,
    vt_stream: TerminalStream,
    alive: std.atomic.Value(bool) = .init(true),
    task_complete: std.atomic.Value(bool) = .init(false),
    active_clients: std.atomic.Value(u64) = .init(0),
    lock_word: std.atomic.Value(u8) = .init(0),
    terminal_lock_word: std.atomic.Value(u8) = .init(0),
    pty_lock_word: std.atomic.Value(u8) = .init(0),
    leader: ?*Client = null,
    clients: std.ArrayList(*Client) = .empty,
    reader_thread: ?std.Thread = null,
    labels: std.StringHashMapUnmanaged([]const u8) = .empty,
    history: std.ArrayList(u8) = .empty,
    history_start: u64 = 0,
    created_at: u64 = 0,
    cwd: []u8 = &.{},
    task_ended_at: u64 = 0,
    task_exit_code: u8 = 0,

    // Four history chunks plus the terminating empty frame must fit in one
    // client queue even before its writer gets a chance to drain it.
    const max_history_bytes = Client.max_output_bytes - 5 * @sizeOf(wire.Header);

    fn lock(self: *Session) void {
        while (self.lock_word.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Session) void {
        self.lock_word.store(0, .release);
    }

    fn lockTerminal(self: *Session) void {
        while (self.terminal_lock_word.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockTerminal(self: *Session) void {
        self.terminal_lock_word.store(0, .release);
    }

    fn lockPty(self: *Session) void {
        while (self.pty_lock_word.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockPty(self: *Session) void {
        self.pty_lock_word.store(0, .release);
    }
};

const Client = struct {
    session: *Session,
    connection: local_ipc.Connection,
    closed: std.atomic.Value(bool) = .init(false),
    connection_closed: std.atomic.Value(bool) = .init(false),
    foreground: std.atomic.Value(bool) = .init(false),
    foreground_history_pending: std.atomic.Value(bool) = .init(false),
    foreground_history_ready: std.atomic.Value(bool) = .init(false),
    task_complete_sent: std.atomic.Value(bool) = .init(false),
    request_seen: std.atomic.Value(bool) = .init(false),
    history_cursor: u64 = 0,
    thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    data_event: ?windows.HANDLE = null,
    space_event: ?windows.HANDLE = null,
    broadcast_refs: std.atomic.Value(usize) = .init(0),
    output_lock: std.atomic.Value(u8) = .init(0),
    output: std.ArrayList(u8) = .empty,
    output_closed: bool = false,
    cwd_input: std.ArrayList(u8) = .empty,
    input: input_classifier.InputClassifier = undefined,

    const max_output_bytes = 256 * 1024;
    const max_cwd_input_bytes = 4096;
    const output_wait_ms: windows.DWORD = 1000;

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
        if (self.data_event) |event| _ = kernel32.SetEvent(event);
        if (self.space_event) |event| _ = kernel32.SetEvent(event);
    }

    fn eject(self: *Client) void {
        self.closed.store(true, .release);
        self.lockOutput();
        self.output.clearRetainingCapacity();
        self.output_closed = true;
        self.unlockOutput();
        if (self.data_event) |event| _ = kernel32.SetEvent(event);
        if (self.space_event) |event| _ = kernel32.SetEvent(event);
        self.closeConnection();
    }

    fn closeConnection(self: *Client) void {
        if (self.connection_closed.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
            self.connection.close();
        }
    }

    fn enqueue(self: *Client, tag: wire.Tag, payload: []const u8) !void {
        const frame_len = @sizeOf(wire.Header) + payload.len;
        if (payload.len > max_output_bytes - @sizeOf(wire.Header)) {
            return error.FrameTooLarge;
        }

        self.lockOutput();
        defer self.unlockOutput();
        if (self.output_closed or frame_len > max_output_bytes - self.output.items.len) {
            return error.WouldBlock;
        }
        try self.output.ensureUnusedCapacity(self.session.alloc, frame_len);
        const header = wire.Header{ .tag = tag, .len = @intCast(payload.len) };
        self.output.appendSliceAssumeCapacity(std.mem.asBytes(&header));
        self.output.appendSliceAssumeCapacity(payload);
        if (self.data_event) |event| _ = kernel32.SetEvent(event);
    }

    fn enqueueBlocking(self: *Client, tag: wire.Tag, payload: []const u8) !void {
        const frame_len = @sizeOf(wire.Header) + payload.len;
        if (payload.len > max_output_bytes - @sizeOf(wire.Header)) {
            return error.FrameTooLarge;
        }
        while (true) {
            self.lockOutput();
            if (self.output_closed) {
                self.unlockOutput();
                return error.BrokenPipe;
            }
            if (frame_len <= max_output_bytes - self.output.items.len) {
                self.output.ensureUnusedCapacity(self.session.alloc, frame_len) catch |err| {
                    self.unlockOutput();
                    return err;
                };
                const header = wire.Header{ .tag = tag, .len = @intCast(payload.len) };
                self.output.appendSliceAssumeCapacity(std.mem.asBytes(&header));
                self.output.appendSliceAssumeCapacity(payload);
                self.unlockOutput();
                if (self.data_event) |event| _ = kernel32.SetEvent(event);
                return;
            }
            self.unlockOutput();
            if (self.space_event) |event| {
                if (kernel32.WaitForSingleObject(event, output_wait_ms) == 0x00000102) {
                    return error.WouldBlock;
                }
            } else {
                return error.WouldBlock;
            }
        }
    }

    fn enqueueTaskComplete(self: *Client, payload: []const u8) !void {
        return self.enqueue(.TaskComplete, payload);
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

pub fn attachForeground(
    spec: session_windows.AttachSpec,
    connection: local_ipc.Connection,
) !u8 {
    try wire.writeFrame(connection, .Init, foreground_init);
    return (try attachLoopResult(spec, connection)) orelse error.SessionEnded;
}

pub fn tail(
    spec: session_windows.AttachSpec,
    connection: local_ipc.Connection,
) !u8 {
    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(spec.io, &output_buffer);
    var output_lock = std.atomic.Value(u8).init(0);
    return tailToWriter(spec, connection, &writer.interface, &output_lock);
}

pub fn tailToWriter(
    spec: session_windows.AttachSpec,
    connection: local_ipc.Connection,
    writer: *std.Io.Writer,
    output_lock: *std.atomic.Value(u8),
) !u8 {
    try wire.writeFrame(connection, .History, &.{});
    var task_exit_code: ?u8 = null;
    var history_received = false;
    while (true) {
        var frame = wire.readFrame(spec.alloc, connection) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => return task_exit_code orelse 0,
            else => return err,
        };
        defer frame.deinit(spec.alloc);
        switch (frame.header.tag) {
            .Output => {
                lockOutput(output_lock);
                defer unlockOutput(output_lock);
                try writer.writeAll(frame.payload);
                try writer.flush();
            },
            .History => {
                if (frame.payload.len != 0) {
                    lockOutput(output_lock);
                    defer unlockOutput(output_lock);
                    try writer.writeAll(frame.payload);
                    try writer.flush();
                } else {
                    history_received = true;
                }
                if (task_exit_code) |exit_code| return exit_code;
            },
            .TaskComplete => {
                task_exit_code = if (frame.payload.len == 0) 0 else frame.payload[0];
                if (history_received) return task_exit_code.?;
            },
            else => {},
        }
    }
}

fn lockOutput(lock: *std.atomic.Value(u8)) void {
    while (lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockOutput(lock: *std.atomic.Value(u8)) void {
    lock.store(0, .release);
}

fn createSession(spec: session_windows.HostSpec, server: local_ipc.Server) !*Session {
    const session = try spec.alloc.create(Session);
    errdefer spec.alloc.destroy(session);
    var runtime = pty_runtime.Runtime.init(spec.alloc);
    errdefer runtime.deinit();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(spec.io, &cwd_buffer) catch 0;
    const cwd = try spec.alloc.dupe(u8, cwd_buffer[0..cwd_len]);
    errdefer spec.alloc.free(cwd);
    const initial_size = spec.initial_size orelse
        currentConsoleSize() orelse resize.Size{ .rows = 24, .cols = 80 };
    const spawned = try runtime.spawn(.{
        .session_name = spec.session_name,
        .shell = spec.shell,
        .task_mode = spec.task_mode,
        .command = spec.command,
        .size = initial_size,
    });
    var terminal = try ghostty_vt.Terminal.init(spec.io, spec.alloc, .{
        .cols = initial_size.cols,
        .rows = initial_size.rows,
        .max_scrollback_lines = 2_000,
    });
    errdefer terminal.deinit(spec.alloc);
    session.* = .{
        .alloc = spec.alloc,
        .spec = spec,
        .server = server,
        .runtime = runtime,
        .master = spawned.master,
        .process = spawned.process,
        .terminal = terminal,
        .vt_stream = undefined,
        .created_at = @intCast(std.Io.Timestamp.now(spec.io, .real).toSeconds()),
        .cwd = cwd,
    };
    session.vt_stream = session.terminal.vtStream();
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
        client.* = .{
            .session = session,
            .connection = connection,
            .input = input_classifier.InputClassifier.init(session.alloc),
        };
        client.data_event = kernel32.CreateEventW(
            null,
            @enumFromInt(0),
            @enumFromInt(0),
            null,
        ) orelse {
            connection.close();
            client.input.deinit();
            session.alloc.destroy(client);
            continue;
        };
        client.space_event = kernel32.CreateEventW(
            null,
            @enumFromInt(0),
            @enumFromInt(0),
            null,
        ) orelse {
            connection.close();
            _ = kernel32.CloseHandle(client.data_event.?);
            client.input.deinit();
            session.alloc.destroy(client);
            continue;
        };
        session.lock();
        session.clients.append(session.alloc, client) catch {
            session.unlock();
            connection.close();
            _ = kernel32.CloseHandle(client.data_event.?);
            _ = kernel32.CloseHandle(client.space_event.?);
            client.input.deinit();
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
            if (client.broadcast_refs.load(.acquire) != 0) continue;
            found = client;
            _ = session.clients.swapRemove(index);
            break;
        }
        session.unlock();

        const client = found orelse return;
        if (client.thread) |thread| thread.join();
        if (client.writer_thread) |thread| thread.join();
        if (client.space_event) |event| {
            _ = kernel32.CloseHandle(event);
            client.space_event = null;
        }
        if (client.data_event) |event| {
            _ = kernel32.CloseHandle(event);
            client.data_event = null;
        }
        client.output.deinit(session.alloc);
        client.cwd_input.deinit(session.alloc);
        client.input.deinit();
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
        if (client.space_event) |event| {
            _ = kernel32.CloseHandle(event);
            client.space_event = null;
        }
        if (client.data_event) |event| {
            _ = kernel32.CloseHandle(event);
            client.data_event = null;
        }
        client.output.deinit(session.alloc);
        client.input.deinit();
        session.alloc.destroy(client);
    }
    session.clients.deinit(session.alloc);
    session.history.deinit(session.alloc);
    session.vt_stream.deinit();
    session.terminal.deinit(session.alloc);
    session.alloc.free(session.cwd);
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
                session.runtime.waitReadable(session.master) catch break;
                continue;
            },
            else => break,
        };
        if (amount == 0) break;
        session.lock();
        session.lockTerminal();
        session.vt_stream.nextSlice(buffer[0..amount]);
        recordHistoryLocked(session, buffer[0..amount]);
        session.unlockTerminal();
        session.unlock();
        broadcast(session, .Output, buffer[0..amount]);
    }

    if (session.spec.task_mode and session.alive.load(.acquire)) {
        const exit_code = session.runtime.wait(session.process) catch 1;
        session.lock();
        session.task_exit_code = @intCast(@min(exit_code, @as(u32, std.math.maxInt(u8))));
        session.task_ended_at = @intCast(std.Io.Timestamp.now(session.spec.io, .real).toSeconds());
        session.task_complete.store(true, .release);
        session.unlock();
        broadcastTaskComplete(session);
        return;
    }

    session.alive.store(false, .release);
    session.server.close();
}

fn recordHistoryLocked(session: *Session, payload: []const u8) void {
    if (payload.len >= Session.max_history_bytes) {
        session.history_start += session.history.items.len + payload.len - Session.max_history_bytes;
        session.history.clearRetainingCapacity();
        session.history.appendSlice(session.alloc, payload[payload.len - Session.max_history_bytes ..]) catch {};
        return;
    }
    const overflow = session.history.items.len + payload.len -| Session.max_history_bytes;
    if (overflow > 0) {
        session.history_start += overflow;
        const remaining = session.history.items.len - overflow;
        std.mem.copyForwards(u8, session.history.items[0..remaining], session.history.items[overflow..]);
        session.history.shrinkRetainingCapacity(remaining);
    }
    session.history.appendSlice(session.alloc, payload) catch {};
}

fn broadcast(session: *Session, tag: wire.Tag, payload: []const u8) void {
    var clients: std.ArrayList(*Client) = .empty;
    session.lock();
    for (session.clients.items) |client| {
        if (client.closed.load(.acquire)) continue;
        if (tag == .Output and
            (!client.foreground.load(.acquire) or
                client.foreground_history_pending.load(.acquire)))
        {
            continue;
        }
        _ = client.broadcast_refs.fetchAdd(1, .acq_rel);
        clients.append(session.alloc, client) catch {
            _ = client.broadcast_refs.fetchSub(1, .acq_rel);
            for (clients.items) |held| {
                _ = held.broadcast_refs.fetchSub(1, .acq_rel);
            }
            clients.deinit(session.alloc);
            session.unlock();
            return;
        };
    }
    session.unlock();
    defer {
        for (clients.items) |client| {
            _ = client.broadcast_refs.fetchSub(1, .acq_rel);
        }
        clients.deinit(session.alloc);
    }
    const max_payload = Client.max_output_bytes - @sizeOf(wire.Header);
    var offset: usize = 0;
    while (offset < payload.len or (payload.len == 0 and offset == 0)) {
        const amount = @min(payload.len -| offset, max_payload);
        const chunk = payload[offset .. offset + amount];
        for (clients.items) |client| {
            if (client.closed.load(.acquire)) continue;
            switch (tag) {
                .Output => {
                    // PTY output must never wait behind a slow reader.  The
                    // bounded enqueue either succeeds immediately or ejects
                    // the client before the next reader chunk is processed.
                    client.enqueue(.Output, chunk) catch client.eject();
                },
                .TaskComplete => client.enqueueTaskComplete(chunk) catch client.eject(),
                else => client.enqueue(tag, chunk) catch client.eject(),
            }
        }
        if (payload.len == 0) break;
        offset += amount;
    }
}

fn broadcastTaskComplete(session: *Session) void {
    var clients: std.ArrayList(*Client) = .empty;
    session.lock();
    for (session.clients.items) |client| {
        if (client.closed.load(.acquire)) continue;
        _ = client.broadcast_refs.fetchAdd(1, .acq_rel);
        clients.append(session.alloc, client) catch {
            _ = client.broadcast_refs.fetchSub(1, .acq_rel);
            for (clients.items) |held| {
                _ = held.broadcast_refs.fetchSub(1, .acq_rel);
            }
            clients.deinit(session.alloc);
            session.unlock();
            return;
        };
    }
    session.unlock();
    defer {
        for (clients.items) |client| {
            _ = client.broadcast_refs.fetchSub(1, .acq_rel);
        }
        clients.deinit(session.alloc);
    }

    for (clients.items) |client| {
        if (client.closed.load(.acquire)) continue;
        if (!client.request_seen.load(.acquire)) continue;
        if (client.foreground.load(.acquire) and
            !client.foreground_history_ready.load(.acquire))
        {
            sendForegroundHistory(client, false);
            if (client.closed.load(.acquire)) continue;
            if (!client.foreground_history_ready.load(.acquire)) continue;
        }
        sendTaskComplete(client);
    }
}

fn enqueueHistoryFrames(client: *Client, payload: []const u8, blocking: bool) bool {
    var offset: usize = 0;
    while (offset < payload.len) {
        const amount = @min(payload.len - offset, history_chunk_bytes);
        const chunk = payload[offset .. offset + amount];
        const result = if (blocking)
            client.enqueueBlocking(.History, chunk)
        else
            client.enqueue(.History, chunk);
        result catch {
            client.eject();
            return false;
        };
        offset += amount;
    }
    const result = if (blocking)
        client.enqueueBlocking(.History, &.{})
    else
        client.enqueue(.History, &.{});
    result catch {
        client.eject();
        return false;
    };
    return true;
}

fn enqueueTerminalState(client: *Client, payload: []const u8, blocking: bool) bool {
    var offset: usize = 0;
    while (offset < payload.len) {
        const amount = @min(payload.len - offset, history_chunk_bytes);
        const result = if (blocking)
            client.enqueueBlocking(.Output, payload[offset .. offset + amount])
        else
            client.enqueue(.Output, payload[offset .. offset + amount]);
        result catch {
            client.eject();
            return false;
        };
        offset += amount;
    }
    return true;
}

fn sendForegroundHistory(client: *Client, blocking: bool) void {
    const session = client.session;
    session.lock();
    if (client.foreground_history_ready.load(.acquire) or
        client.foreground_history_pending.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null)
    {
        session.unlock();
        return;
    }
    client.foreground.store(true, .release);
    client.history_cursor = session.history_start + session.history.items.len;
    session.lockTerminal();
    const state = terminal_state.serialize(session.alloc, &session.terminal);
    session.unlockTerminal();
    session.unlock();

    if (state) |snapshot| {
        defer session.alloc.free(snapshot);
        if (!enqueueTerminalState(client, snapshot, blocking)) return;
    }

    while (!client.closed.load(.acquire)) {
        session.lock();
        const current_start = session.history_start;
        const current_end = current_start + session.history.items.len;
        if (client.history_cursor < current_start) {
            client.history_cursor = current_start;
        }
        if (client.history_cursor >= current_end) {
            client.foreground_history_pending.store(false, .release);
            client.foreground_history_ready.store(true, .release);
            session.unlock();
            return;
        }
        const delta_start: usize = @intCast(client.history_cursor - current_start);
        const delta = session.alloc.dupe(u8, session.history.items[delta_start..]) catch {
            session.unlock();
            client.eject();
            return;
        };
        client.history_cursor = current_end;
        session.unlock();
        defer session.alloc.free(delta);
        const result = if (blocking)
            client.enqueueBlocking(.Output, delta)
        else
            client.enqueue(.Output, delta);
        result catch {
            client.eject();
            return;
        };
    }
}

fn writePty(session: *Session, bytes: []const u8) void {
    session.lockPty();
    defer session.unlockPty();
    var offset: usize = 0;
    while (offset < bytes.len and session.alive.load(.acquire)) {
        const amount = session.runtime.write(session.master, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => {
                session.runtime.waitWritable(session.master) catch return;
                continue;
            },
            else => return,
        };
        if (amount == 0) return;
        offset += amount;
    }
}

fn resizePty(session: *Session, size: resize.Size) void {
    session.lockPty();
    session.runtime.resize(session.master, size) catch {};
    session.lockTerminal();
    session.terminal.resize(session.alloc, .{
        .cols = size.cols,
        .rows = size.rows,
    }) catch {};
    session.unlockTerminal();
    session.unlockPty();
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (value[0..prefix.len], prefix) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn updateSessionCwdLine(session: *Session, bytes: []const u8) void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        var value: ?[]const u8 = null;
        if (asciiStartsWithIgnoreCase(line, "cd") and
            (line.len == 2 or
                std.ascii.isWhitespace(line[2]) or
                line[2] == '.'))
        {
            value = std.mem.trim(u8, line[2..], " \t");
            if (value.?.len >= 2 and asciiStartsWithIgnoreCase(value.?, "/d") and
                (value.?.len == 2 or std.ascii.isWhitespace(value.?[2])))
            {
                value = std.mem.trim(u8, value.?[2..], " \t");
            }
        } else if (asciiStartsWithIgnoreCase(line, "chdir") and
            (line.len == 5 or std.ascii.isWhitespace(line[5])))
        {
            value = std.mem.trim(u8, line[5..], " \t");
        } else if (asciiStartsWithIgnoreCase(line, "pushd") and
            (line.len == 5 or std.ascii.isWhitespace(line[5])))
        {
            value = std.mem.trim(u8, line[5..], " \t");
        }
        const raw_value = value orelse continue;
        if (raw_value.len == 0) continue;
        const path_value = if (raw_value.len >= 2 and
            raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"')
            raw_value[1 .. raw_value.len - 1]
        else
            raw_value;
        var candidate: []u8 = undefined;
        if (std.fs.path.isAbsolute(path_value)) {
            candidate = std.fs.path.resolve(session.alloc, &.{path_value}) catch continue;
        } else {
            session.lock();
            const current = session.cwd;
            candidate = std.fs.path.resolve(session.alloc, &.{ current, path_value }) catch {
                session.unlock();
                continue;
            };
            session.unlock();
        }
        var directory = std.Io.Dir.openDirAbsolute(session.spec.io, candidate, .{}) catch {
            session.alloc.free(candidate);
            continue;
        };
        directory.close(session.spec.io);
        session.lock();
        const previous = session.cwd;
        session.cwd = candidate;
        session.unlock();
        session.alloc.free(previous);
    }
}

fn updateSessionCwd(client: *Client, bytes: []const u8, flush: bool) void {
    const session = client.session;
    for (bytes) |byte| {
        switch (byte) {
            '\r', '\n' => {
                if (client.cwd_input.items.len > 0) {
                    updateSessionCwdLine(session, client.cwd_input.items);
                    client.cwd_input.clearRetainingCapacity();
                }
            },
            0x08, 0x7f => {
                if (client.cwd_input.items.len > 0) {
                    _ = client.cwd_input.pop();
                }
            },
            else => {
                if (client.cwd_input.items.len >= Client.max_cwd_input_bytes) {
                    client.cwd_input.clearRetainingCapacity();
                }
                client.cwd_input.append(session.alloc, byte) catch {
                    client.cwd_input.clearRetainingCapacity();
                };
            },
        }
    }
    if (flush and client.cwd_input.items.len > 0) {
        updateSessionCwdLine(session, client.cwd_input.items);
        client.cwd_input.clearRetainingCapacity();
    }
}

fn isLeader(session: *Session, client: *Client) bool {
    session.lock();
    const result = session.leader == client;
    session.unlock();
    return result;
}

fn claimLeaderIfVacant(session: *Session, client: *Client) void {
    session.lock();
    if (session.leader == null) session.leader = client;
    session.unlock();
}

fn claimLeader(session: *Session, client: *Client) void {
    var changed = false;
    session.lock();
    if (session.leader != client) {
        session.leader = client;
        changed = true;
    }
    session.unlock();
    if (changed) client.enqueue(.Resize, &.{}) catch client.eject();
}

fn releaseLeader(session: *Session, client: *Client) void {
    var replacement: ?*Client = null;
    session.lock();
    if (session.leader == client) {
        session.leader = null;
        for (session.clients.items) |other| {
            if (other != client and !other.closed.load(.acquire)) {
                replacement = other;
                break;
            }
        }
        session.leader = replacement;
    }
    session.unlock();
    if (replacement) |next| {
        next.enqueue(.Resize, &.{}) catch next.eject();
    }
}

fn clientMain(client: *Client) void {
    const session = client.session;
    defer {
        releaseLeader(session, client);
        client.closed.store(true, .release);
        client.closeOutput();
        client.closeConnection();
        _ = session.active_clients.fetchSub(1, .acq_rel);
    }
    while (!client.closed.load(.acquire) and session.alive.load(.acquire)) {
        var frame = wire.readFrame(session.alloc, client.connection) catch break;
        defer frame.deinit(session.alloc);
        client.request_seen.store(true, .release);
        switch (frame.header.tag) {
            .Input => {
                if (isLeader(session, client)) {
                    const bytes = client.input.observeLeader(frame.payload) catch break;
                    defer session.alloc.free(bytes);
                    updateSessionCwd(client, bytes, false);
                    writePty(session, bytes);
                } else {
                    const result = client.input.filterNonLeader(frame.payload) catch break;
                    defer session.alloc.free(result.bytes);
                    if (result.claims_leadership) claimLeader(session, client);
                    updateSessionCwd(client, result.bytes, false);
                    writePty(session, result.bytes);
                }
            },
            .Send => {
                updateSessionCwd(client, frame.payload, true);
                writePty(session, frame.payload);
            },
            .Output => {
                session.lock();
                session.lockTerminal();
                session.vt_stream.nextSlice(frame.payload);
                recordHistoryLocked(session, frame.payload);
                session.unlockTerminal();
                session.unlock();
                broadcast(session, .Output, frame.payload);
            },
            .Resize => {
                if (frame.payload.len == @sizeOf(wire.Resize)) {
                    const size = std.mem.bytesToValue(wire.Resize, frame.payload);
                    if (isLeader(session, client)) resizePty(session, size);
                }
            },
            .Init => {
                if (std.mem.eql(u8, frame.payload, foreground_init)) {
                    claimLeaderIfVacant(session, client);
                    sendForegroundHistory(client, true);
                    if (session.task_complete.load(.acquire)) {
                        if (!client.closed.load(.acquire)) sendTaskComplete(client);
                    }
                } else if (frame.payload.len == @sizeOf(wire.Resize)) {
                    const size = std.mem.bytesToValue(wire.Resize, frame.payload);
                    if (isLeader(session, client)) resizePty(session, size);
                }
            },
            .Kill => {
                session.lockPty();
                session.runtime.signal(session.process, .kill) catch {};
                session.unlockPty();
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
            .History => {
                sendHistory(client, frame.payload, true);
                if (session.task_complete.load(.acquire) and
                    !client.closed.load(.acquire))
                {
                    sendTaskComplete(client);
                }
            },
            .Write => writeFile(client, frame.payload) catch break,
            else => {},
        }
    }
}

fn detachAll(session: *Session) void {
    var clients: std.ArrayList(*Client) = .empty;
    session.lock();
    for (session.clients.items) |other| {
        other.closed.store(true, .release);
        _ = other.broadcast_refs.fetchAdd(1, .acq_rel);
        clients.append(session.alloc, other) catch {
            _ = other.broadcast_refs.fetchSub(1, .acq_rel);
        };
    }
    session.unlock();
    for (clients.items) |other| {
        other.closeOutput();
        other.closeConnection();
        _ = other.broadcast_refs.fetchSub(1, .acq_rel);
    }
    clients.deinit(session.alloc);
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
            if (client.data_event) |event| {
                _ = kernel32.WaitForSingleObject(event, std.math.maxInt(windows.DWORD));
            } else {
                return;
            }
            continue;
        }
        var pending = std.ArrayList(u8).empty;
        std.mem.swap(std.ArrayList(u8), &client.output, &pending);
        client.unlockOutput();
        if (client.space_event) |event| _ = kernel32.SetEvent(event);
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
    info.created_at = client.session.created_at;
    info.cwd_len = @intCast(@min(client.session.cwd.len, info.cwd.len));
    @memcpy(info.cwd[0..info.cwd_len], client.session.cwd[0..info.cwd_len]);
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
    if (client.task_complete_sent.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return;
    const session = client.session;
    session.lock();
    const exit_code = session.task_exit_code;
    session.unlock();
    const payload = [_]u8{exit_code};
    client.enqueue(.TaskComplete, &payload) catch client.eject();
}

fn sendHistory(client: *Client, request: []const u8, blocking: bool) void {
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
    const max_payload = @min(
        Client.max_output_bytes - @sizeOf(wire.Header),
        history_chunk_bytes,
    );
    const enqueue_history = struct {
        fn enqueue(target: *Client, payload: []const u8, should_block: bool) !void {
            if (should_block) return target.enqueueBlocking(.History, payload);
            return target.enqueue(.History, payload);
        }
    }.enqueue;
    switch (format) {
        0, 1 => {
            var offset: usize = 0;
            while (offset < history.len) {
                const amount = @min(history.len - offset, max_payload);
                enqueue_history(client, history[offset .. offset + amount], blocking) catch {
                    client.eject();
                    return;
                };
                offset += amount;
            }
        },
        2 => {
            var chunk: std.ArrayList(u8) = .empty;
            defer chunk.deinit(session.alloc);
            const appendEscaped = struct {
                fn append(
                    list: *std.ArrayList(u8),
                    alloc: std.mem.Allocator,
                    byte: u8,
                ) !void {
                    const escaped: []const u8 = switch (byte) {
                        '&' => "&amp;",
                        '<' => "&lt;",
                        '>' => "&gt;",
                        '"' => "&quot;",
                        else => return list.append(alloc, byte),
                    };
                    try list.appendSlice(alloc, escaped);
                }
            }.append;
            chunk.appendSlice(session.alloc, "<pre>") catch {
                client.eject();
                return;
            };
            for (history) |byte| {
                const before = chunk.items.len;
                appendEscaped(&chunk, session.alloc, byte) catch {
                    client.eject();
                    return;
                };
                if (chunk.items.len > max_payload) {
                    const amount = before;
                    enqueue_history(client, chunk.items[0..amount], blocking) catch {
                        client.eject();
                        return;
                    };
                    chunk.clearRetainingCapacity();
                    appendEscaped(&chunk, session.alloc, byte) catch {
                        client.eject();
                        return;
                    };
                }
            }
            for ("</pre>\n") |byte| {
                const before = chunk.items.len;
                chunk.append(session.alloc, byte) catch {
                    client.eject();
                    return;
                };
                if (chunk.items.len > max_payload) {
                    enqueue_history(client, chunk.items[0..before], blocking) catch {
                        client.eject();
                        return;
                    };
                    chunk.clearRetainingCapacity();
                    chunk.append(session.alloc, byte) catch {
                        client.eject();
                        return;
                    };
                }
            }
            if (chunk.items.len > 0) {
                enqueue_history(client, chunk.items, blocking) catch {
                    client.eject();
                    return;
                };
            }
        },
        else => {
            client.eject();
            return;
        },
    }
    enqueue_history(client, &.{}, blocking) catch client.eject();
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
        if (value.len == 0) {
            if (session.labels.fetchRemove(key)) |old| {
                session.alloc.free(old.key);
                session.alloc.free(old.value);
            }
            continue;
        }
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

fn writeFile(client: *Client, payload: []const u8) !void {
    const session = client.session;
    if (payload.len < @sizeOf(u32)) {
        return error.InvalidWritePayload;
    }
    const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
    if (payload.len < @sizeOf(u32) + path_len) {
        return error.InvalidWritePayload;
    }
    const path = payload[@sizeOf(u32)..][0..path_len];
    const content = payload[@sizeOf(u32) + path_len ..];
    const target = if (std.fs.path.isAbsolute(path))
        try session.alloc.dupe(u8, path)
    else blk: {
        session.lock();
        const joined = std.fs.path.join(session.alloc, &.{ session.cwd, path }) catch |err| {
            session.unlock();
            return err;
        };
        session.unlock();
        break :blk joined;
    };
    defer session.alloc.free(target);
    var file = try std.Io.Dir.cwd().createFile(session.spec.io, target, .{ .truncate = true });
    defer file.close(session.spec.io);
    try file.writeStreamingAll(session.spec.io, content);
    client.enqueue(.Ack, "") catch client.eject();
}

fn attachLoop(spec: session_windows.AttachSpec, connection: local_ipc.Connection) !void {
    try wire.writeFrame(connection, .Init, foreground_init);
    _ = try attachLoopResult(spec, connection);
}

fn lockWire(lock: *std.atomic.Value(u8)) void {
    while (lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockWire(lock: *std.atomic.Value(u8)) void {
    lock.store(0, .release);
}

fn writeWireFrame(
    lock: *std.atomic.Value(u8),
    connection: local_ipc.Connection,
    tag: wire.Tag,
    payload: []const u8,
) !void {
    lockWire(lock);
    defer unlockWire(lock);
    return wire.writeFrame(connection, tag, payload);
}

fn attachLoopResult(spec: session_windows.AttachSpec, connection: local_ipc.Connection) !?u8 {
    var stop = std.atomic.Value(bool).init(false);
    var wire_lock = std.atomic.Value(u8).init(0);
    const stdin_file = std.Io.File.stdin();
    const stdin_handle = kernel32.GetStdHandle(std_input_handle);
    const stdout_handle = kernel32.GetStdHandle(std_output_handle);
    var original_console_mode: ?windows.DWORD = null;
    var original_input_cp: ?windows.UINT = null;
    var original_output_cp: ?windows.UINT = null;
    var console_input = false;
    var mode: windows.DWORD = 0;
    if (@intFromEnum(kernel32.GetConsoleMode(stdin_handle, &mode)) != 0) {
        console_input = true;
        const raw_mode = mode & ~enableProcessedInput & ~enableLineInput & ~enableEchoInput;
        if (@intFromEnum(kernel32.SetConsoleMode(stdin_handle, raw_mode)) != 0) {
            original_console_mode = mode;
        }
    }
    if (console_input) {
        const input_cp = kernel32.GetConsoleCP();
        if (input_cp != 0 and @intFromEnum(kernel32.SetConsoleCP(cp_utf8)) != 0) {
            original_input_cp = input_cp;
        }
    }
    var output_mode: windows.DWORD = 0;
    const console_output = @intFromEnum(
        kernel32.GetConsoleMode(stdout_handle, &output_mode),
    ) != 0;
    if (console_output) {
        const output_cp = kernel32.GetConsoleOutputCP();
        if (output_cp != 0 and @intFromEnum(kernel32.SetConsoleOutputCP(cp_utf8)) != 0) {
            original_output_cp = output_cp;
        }
    }
    defer if (original_console_mode) |restore_mode| {
        _ = kernel32.SetConsoleMode(stdin_handle, restore_mode);
        original_console_mode = null;
    };
    defer if (original_input_cp) |restore_cp| {
        _ = kernel32.SetConsoleCP(restore_cp);
        original_input_cp = null;
    };
    defer if (original_output_cp) |restore_cp| {
        _ = kernel32.SetConsoleOutputCP(restore_cp);
        original_output_cp = null;
    };
    if (currentConsoleSize()) |size| {
        try writeWireFrame(&wire_lock, connection, .Resize, std.mem.asBytes(&size));
    }
    var input = AttachInput{
        .io = spec.io,
        .alloc = spec.alloc,
        .connection = connection,
        .stdin_file = stdin_file,
        .stop = &stop,
        .console_input = console_input,
        .wire_lock = &wire_lock,
    };
    const input_thread = try std.Thread.spawn(.{}, attachInputMain, .{&input});
    var resize_monitor = ResizeMonitor{
        .connection = connection,
        .stop = &stop,
        .wire_lock = &wire_lock,
        .enabled = console_output,
    };
    const resize_thread = if (console_output)
        std.Thread.spawn(.{}, resizeMonitorMain, .{&resize_monitor}) catch null
    else
        null;
    defer {
        stop.store(true, .release);
        _ = kernel32.CancelSynchronousIo(input_thread.getHandle());
        input_thread.join();
        if (resize_thread) |thread| thread.join();
        if (original_console_mode) |restore_mode| {
            _ = kernel32.SetConsoleMode(stdin_handle, restore_mode);
            original_console_mode = null;
        }
        if (original_input_cp) |restore_cp| {
            _ = kernel32.SetConsoleCP(restore_cp);
            original_input_cp = null;
        }
        if (original_output_cp) |restore_cp| {
            _ = kernel32.SetConsoleOutputCP(restore_cp);
            original_output_cp = null;
        }
        stdin_file.close(spec.io);
    }

    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(spec.io, &output_buffer);
    var task_exit_code: ?u8 = null;
    var saw_output = false;
    var saw_history = false;
    var history_requested = false;
    while (!stop.load(.acquire)) {
        var frame = wire.readFrame(spec.alloc, connection) catch break;
        defer frame.deinit(spec.alloc);
        switch (frame.header.tag) {
            .Output => {
                saw_output = true;
                try writer.interface.writeAll(frame.payload);
                try writer.interface.flush();
            },
            .Resize => {
                if (frame.payload.len == 0) {
                    if (currentConsoleSize()) |size| {
                        try writeWireFrame(&wire_lock, connection, .Resize, std.mem.asBytes(&size));
                    }
                }
            },
            .History => {
                saw_history = true;
                // A completed foreground task sends its buffered history
                // before TaskComplete.  Render fragments in arrival order;
                // the empty frame is the history terminator.
                if (frame.payload.len > 0) {
                    try writer.interface.writeAll(frame.payload);
                    try writer.interface.flush();
                }
            },
            .TaskComplete => {
                task_exit_code = if (frame.payload.len == 0) 0 else frame.payload[0];
                if (saw_output or saw_history or history_requested) {
                    stop.store(true, .release);
                } else {
                    // The task may have completed before the attach
                    // worker's Init was processed.  Ask once for the
                    // buffered history so fast commands are not silent.
                    try writeWireFrame(&wire_lock, connection, .Init, foreground_init);
                    history_requested = true;
                }
            },
            else => {},
        }
    }
    return task_exit_code;
}

const AttachInput = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
    stdin_file: std.Io.File,
    stop: *std.atomic.Value(bool),
    console_input: bool,
    wire_lock: *std.atomic.Value(u8),
};

const ResizeMonitor = struct {
    connection: local_ipc.Connection,
    stop: *std.atomic.Value(bool),
    wire_lock: *std.atomic.Value(u8),
    enabled: bool,
};

fn attachInputMain(input: *AttachInput) void {
    var input_buffer: [4096]u8 = undefined;
    const stdin_handle = kernel32.GetStdHandle(std_input_handle);
    while (!input.stop.load(.acquire)) {
        if (!input.console_input) {
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
        }
        var amount: windows.DWORD = 0;
        if (@intFromEnum(kernel32.ReadFile(
            stdin_handle,
            &input_buffer,
            @intCast(input_buffer.len),
            &amount,
            null,
        )) == 0) break;
        if (amount == 0) {
            writeWireFrame(input.wire_lock, input.connection, .Detach, "") catch {};
            break;
        }
        if (input_buffer[0] == 0x1c) {
            writeWireFrame(input.wire_lock, input.connection, .Detach, "") catch {};
            break;
        }
        writeWireFrame(
            input.wire_lock,
            input.connection,
            .Input,
            input_buffer[0..amount],
        ) catch break;
    }
}

fn resizeMonitorMain(monitor: *ResizeMonitor) void {
    var previous: ?resize.Size = currentConsoleSize();
    while (!monitor.stop.load(.acquire)) {
        if (monitor.enabled) {
            if (currentConsoleSize()) |size| {
                const changed = if (previous) |old|
                    old.cols != size.cols or old.rows != size.rows
                else
                    true;
                if (changed) {
                    writeWireFrame(
                        monitor.wire_lock,
                        monitor.connection,
                        .Resize,
                        std.mem.asBytes(&size),
                    ) catch return;
                    previous = size;
                }
            }
        }
        kernel32.Sleep(100);
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

test "Windows retained history reserves framing overhead" {
    const chunks = (Session.max_history_bytes + history_chunk_bytes - 1) / history_chunk_bytes;
    try std.testing.expect(
        chunks * @sizeOf(wire.Header) + @sizeOf(wire.Header) <= Client.max_output_bytes,
    );
}

test "Windows foreground history cursor precedes later live output" {
    var session: Session = undefined;
    session.alloc = std.testing.allocator;
    session.lock_word = .init(0);
    session.terminal_lock_word = .init(0);
    session.terminal = try ghostty_vt.Terminal.init(std.testing.io, std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_lines = 2_000,
    });
    session.vt_stream = session.terminal.vtStream();
    defer session.vt_stream.deinit();
    defer session.terminal.deinit(std.testing.allocator);
    session.vt_stream.nextSlice("old");
    session.history = .empty;
    session.history_start = 0;
    session.clients = .empty;
    defer session.history.deinit(std.testing.allocator);
    defer session.clients.deinit(std.testing.allocator);
    try session.history.appendSlice(std.testing.allocator, "old");

    var client: Client = undefined;
    client.session = &session;
    client.closed = .init(false);
    client.foreground = .init(false);
    client.foreground_history_pending = .init(false);
    client.foreground_history_ready = .init(false);
    client.task_complete_sent = .init(false);
    client.request_seen = .init(true);
    client.broadcast_refs = .init(0);
    client.output_lock = .init(0);
    client.output = .empty;
    client.output_closed = false;
    client.data_event = null;
    client.space_event = null;
    defer client.output.deinit(std.testing.allocator);
    try session.clients.append(std.testing.allocator, &client);

    sendForegroundHistory(&client, false);
    try std.testing.expect(client.foreground_history_ready.load(.acquire));
    broadcast(&session, .Output, "new");

    var offset: usize = 0;
    var frame_count: usize = 0;
    var last_payload: []const u8 = &.{};
    while (offset < client.output.items.len) {
        const header = std.mem.bytesToValue(
            wire.Header,
            client.output.items[offset .. offset + @sizeOf(wire.Header)],
        );
        try std.testing.expectEqual(wire.Tag.Output, header.tag);
        const start = offset + @sizeOf(wire.Header);
        last_payload = client.output.items[start .. start + header.len];
        offset = start + header.len;
        frame_count += 1;
    }
    try std.testing.expect(frame_count >= 2);
    try std.testing.expectEqualStrings("new", last_payload);
}

test "Windows fragmented input updates session cwd at line termination" {
    var session: Session = undefined;
    session.alloc = std.testing.allocator;
    session.spec = .{
        .io = std.testing.io,
        .alloc = std.testing.allocator,
        .session_name = "cwd-test",
        .shell = "cmd.exe",
    };
    session.lock_word = .init(0);
    session.cwd = try std.testing.allocator.dupe(u8, "C:\\");
    defer std.testing.allocator.free(session.cwd);

    var client: Client = undefined;
    client.session = &session;
    client.cwd_input = .empty;
    defer client.cwd_input.deinit(std.testing.allocator);

    const command = "cd C:\\Windows";
    for (command) |byte| {
        updateSessionCwd(&client, &.{byte}, false);
    }
    try std.testing.expectEqualStrings("C:\\", client.session.cwd);
    updateSessionCwd(&client, "\r", false);
    try std.testing.expectEqualStrings("C:\\Windows", client.session.cwd);

    for ("cd..") |byte| {
        updateSessionCwd(&client, &.{byte}, false);
    }
    updateSessionCwd(&client, "\r", false);
    try std.testing.expectEqualStrings("C:\\", client.session.cwd);
}
