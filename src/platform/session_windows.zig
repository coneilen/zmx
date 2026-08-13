const builtin = @import("builtin");
const std = @import("std");
const local_ipc = @import("local_ipc.zig");
const local_ipc_windows = @import("local_ipc_windows.zig");
const runtime_windows = @import("runtime_windows.zig");
const wire = @import("session_wire.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("session_windows requires a Windows target");
}

pub const Error = error{
    ConPtyProviderUnavailable,
    InvalidSessionName,
    SessionNameRequired,
    UnsupportedCommand,
} || wire.Error || local_ipc_windows.Error;

pub const Connection = local_ipc.Connection;
pub const Server = local_ipc.Server;
pub const Deadline = @import("events_windows.zig").Deadline;
pub const Cancellation = @import("events_windows.zig").Cancellation;
pub const acceptWithDeadline = local_ipc_windows.acceptServerWithDeadline;
pub const readWithDeadline = local_ipc_windows.readWithDeadline;
pub const writeWithDeadline = local_ipc_windows.writeWithDeadline;
pub const writeAll = local_ipc_windows.writeAll;

pub const ServeOptions = struct {
    /// A deadline is cumulative for the lifetime of one client connection.
    /// Null keeps the long-lived session behavior used by terminal clients.
    client_deadline_ms: ?u64 = null,
    /// Cancels the accept loop and all active client reads.
    cancellation: ?*Cancellation = null,
};

pub const HostSpec = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    shell: []const u8,
    task_mode: bool = false,
    command: ?[]const []const u8 = null,
};

pub const AttachSpec = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
};

pub const DispatchResult = enum {
    continue_connection,
    close_connection,
    stop_session,
};

/// The frozen IPC dispatch contract consumed by the ConPTY/session provider.
/// The provider owns process and terminal state; this module owns transport,
/// frame boundaries, and complete tag coverage.
pub const Handler = struct {
    context: *anyopaque,
    handle_fn: *const fn (
        *anyopaque,
        wire.Tag,
        []const u8,
    ) anyerror!DispatchResult,

    pub fn handle(
        self: Handler,
        tag: wire.Tag,
        payload: []const u8,
    ) !DispatchResult {
        return self.handle_fn(self.context, tag, payload);
    }
};

pub const Provider = struct {
    context: *anyopaque,
    host_fn: *const fn (*anyopaque, HostSpec, local_ipc.Server) anyerror!void,
    attach_fn: *const fn (*anyopaque, AttachSpec, local_ipc.Connection) anyerror!void,

    pub fn host(
        self: Provider,
        spec: HostSpec,
        server: local_ipc.Server,
    ) !void {
        return self.host_fn(self.context, spec, server);
    }

    pub fn attach(
        self: Provider,
        spec: AttachSpec,
        connection: local_ipc.Connection,
    ) !void {
        return self.attach_fn(self.context, spec, connection);
    }
};

fn unavailableHost(
    _: *anyopaque,
    _: HostSpec,
    _: local_ipc.Server,
) Error!void {
    return error.ConPtyProviderUnavailable;
}

fn unavailableAttach(
    _: *anyopaque,
    _: AttachSpec,
    _: local_ipc.Connection,
) Error!void {
    return error.ConPtyProviderUnavailable;
}

/// Until the sibling ConPTY provider is linked, production commands fail
/// explicitly through this adapter rather than silently becoming send-only.
pub fn pendingProvider() Provider {
    return .{
        .context = undefined,
        .host_fn = unavailableHost,
        .attach_fn = unavailableAttach,
    };
}

pub fn dispatchConnection(
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
    handler: Handler,
) anyerror!DispatchResult {
    return dispatchConnectionWithDeadline(alloc, connection, handler, null, null);
}

fn readExactWithDeadline(
    connection: local_ipc.Connection,
    buffer: []u8,
    deadline: ?Deadline,
    cancellation: ?*Cancellation,
) anyerror!void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const amount = try local_ipc_windows.readWithDeadline(
            connection.handle,
            buffer[offset..],
            deadline,
            cancellation,
        );
        if (amount == 0) return error.BrokenPipe;
        offset += amount;
    }
}

pub fn readFrameWithDeadline(
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
    deadline: ?Deadline,
    cancellation: ?*Cancellation,
) anyerror!wire.Frame {
    var header: wire.Header = undefined;
    try readExactWithDeadline(connection, std.mem.asBytes(&header), deadline, cancellation);
    if (@as(usize, header.len) > wire.MAX_FRAME_LEN) return error.FrameTooLarge;
    const payload = try alloc.alloc(u8, header.len);
    errdefer alloc.free(payload);
    try readExactWithDeadline(connection, payload, deadline, cancellation);
    return .{ .header = header, .payload = payload };
}

pub fn dispatchConnectionWithDeadline(
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
    handler: Handler,
    deadline: ?Deadline,
    cancellation: ?*Cancellation,
) anyerror!DispatchResult {
    while (true) {
        var frame = readFrameWithDeadline(alloc, connection, deadline, cancellation) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => return .close_connection,
            else => return err,
        };
        defer frame.deinit(alloc);
        const result = handler.handle(frame.header.tag, frame.payload) catch |err| {
            return switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => .close_connection,
                else => err,
            };
        };
        switch (result) {
            .continue_connection => {},
            .close_connection, .stop_session => return result,
        }
    }
}

const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

const ServeState = struct {
    alloc: std.mem.Allocator,
    server: local_ipc.Server,
    handler: Handler,
    options: ServeOptions,
    mutex: SpinMutex = .{},
    stopping: bool = false,
    workers: std.ArrayList(*ClientWorker) = .empty,
    reaper_stop: std.atomic.Value(bool) = .init(false),
    reaper_event: Cancellation = undefined,
    reaper_thread: ?std.Thread = null,
};

const ClientWorker = struct {
    state: *ServeState,
    connection: local_ipc.Connection,
    cancellation: Cancellation,
    thread: ?std.Thread = null,
    started: std.atomic.Value(bool) = .init(false),
    completed: std.atomic.Value(bool) = .init(false),
};

fn stopServing(state: *ServeState) void {
    state.mutex.lock();
    const was_stopping = state.stopping;
    state.stopping = true;
    for (state.workers.items) |worker| {
        worker.cancellation.cancel() catch {};
    }
    state.mutex.unlock();
    if (!was_stopping) state.server.close();
}

fn clientWorkerMain(worker: *ClientWorker) void {
    defer {
        worker.connection.close();
        worker.state.mutex.lock();
        worker.completed.store(true, .release);
        worker.state.reaper_event.cancel() catch {};
        worker.state.mutex.unlock();
    }
    const deadline = if (worker.state.options.client_deadline_ms) |ms|
        Deadline.afterMs(ms)
    else
        null;
    const result = dispatchConnectionWithDeadline(
        worker.state.alloc,
        worker.connection,
        worker.state.handler,
        deadline,
        &worker.cancellation,
    ) catch null;
    if (result) |value| {
        if (value == .stop_session) stopServing(worker.state);
    }
}

fn reapCompleted(state: *ServeState) bool {
    var reaped = false;
    while (true) {
        var completed: ?*ClientWorker = null;
        state.mutex.lock();
        for (state.workers.items, 0..) |worker, index| {
            if (worker.started.load(.acquire) and worker.completed.load(.acquire)) {
                completed = worker;
                _ = state.workers.swapRemove(index);
                break;
            }
        }
        state.mutex.unlock();

        const worker = completed orelse return reaped;
        reaped = true;
        if (worker.thread) |thread| thread.join();
        worker.cancellation.deinit();
        state.alloc.destroy(worker);
    }
}

fn removeWorkerLocked(state: *ServeState, target: *ClientWorker) bool {
    for (state.workers.items, 0..) |worker, index| {
        if (worker == target) {
            _ = state.workers.swapRemove(index);
            return true;
        }
    }
    return false;
}

fn reaperMain(state: *ServeState) void {
    while (true) {
        if (reapCompleted(state)) continue;

        state.mutex.lock();
        const stopping = state.reaper_stop.load(.acquire);
        if (!stopping) {
            state.reaper_event.reset() catch {};
            var ready = false;
            for (state.workers.items) |worker| {
                if (worker.started.load(.acquire) and worker.completed.load(.acquire)) {
                    ready = true;
                    break;
                }
            }
            if (ready) {
                state.mutex.unlock();
                continue;
            }
        }
        state.mutex.unlock();

        if (stopping) {
            _ = reapCompleted(state);
            return;
        }
        state.reaper_event.wait();
    }
}

fn joinWorkers(state: *ServeState) void {
    for (state.workers.items) |worker| {
        if (worker.thread) |thread| thread.join();
        worker.cancellation.deinit();
        state.alloc.destroy(worker);
    }
    state.workers.deinit(state.alloc);
}

/// Accept continuously and dispatch every client on its own worker. Closing
/// the listener wakes the accept loop, which then cancels and joins all
/// active client reads before returning.
pub fn serveConnectionsWithOptions(
    alloc: std.mem.Allocator,
    server: local_ipc.Server,
    handler: Handler,
    options: ServeOptions,
) anyerror!void {
    var state = ServeState{
        .alloc = alloc,
        .server = server,
        .handler = handler,
        .options = options,
    };
    state.reaper_event = Cancellation.init() catch |err| {
        server.close();
        return err;
    };
    state.reaper_thread = std.Thread.spawn(.{}, reaperMain, .{&state}) catch |err| {
        state.reaper_event.deinit();
        server.close();
        return err;
    };
    var accept_error: ?anyerror = null;
    while (true) {
        state.mutex.lock();
        const stopping = state.stopping;
        state.mutex.unlock();
        if (stopping) break;

        const connection = acceptWithDeadline(
            server,
            null,
            options.cancellation,
        ) catch |err| {
            if (err == error.Timeout or
                err == error.BrokenPipe or
                err == error.ConnectionResetByPeer)
            {
                continue;
            }
            if (err != error.AlreadyClosed and err != error.Cancelled) accept_error = err;
            break;
        };
        const worker = alloc.create(ClientWorker) catch |err| {
            connection.close();
            accept_error = err;
            break;
        };
        const cancellation = Cancellation.init() catch |err| {
            alloc.destroy(worker);
            connection.close();
            accept_error = err;
            break;
        };
        worker.* = .{
            .state = &state,
            .connection = connection,
            .cancellation = cancellation,
        };
        state.mutex.lock();
        state.workers.append(alloc, worker) catch |err| {
            state.mutex.unlock();
            worker.cancellation.deinit();
            alloc.destroy(worker);
            connection.close();
            accept_error = err;
            break;
        };
        state.mutex.unlock();
        const thread = std.Thread.spawn(.{}, clientWorkerMain, .{worker}) catch |err| {
            state.mutex.lock();
            _ = removeWorkerLocked(&state, worker);
            state.mutex.unlock();
            worker.cancellation.deinit();
            alloc.destroy(worker);
            connection.close();
            accept_error = err;
            break;
        };
        state.mutex.lock();
        worker.thread = thread;
        worker.started.store(true, .release);
        if (worker.completed.load(.acquire)) {
            state.reaper_event.cancel() catch {};
        }
        state.mutex.unlock();
    }

    stopServing(&state);
    state.reaper_stop.store(true, .release);
    state.reaper_event.cancel() catch {};
    if (state.reaper_thread) |thread| thread.join();
    joinWorkers(&state);
    state.reaper_event.deinit();
    if (accept_error) |err| return err;
}

pub fn serveConnections(
    alloc: std.mem.Allocator,
    server: local_ipc.Server,
    handler: Handler,
) anyerror!void {
    return serveConnectionsWithOptions(alloc, server, handler, .{});
}

pub fn host(
    spec: HostSpec,
    provider: Provider,
) anyerror!void {
    try runtime_windows.validateSessionName(spec.session_name);
    var server = try local_ipc_windows.listenSession(
        spec.io,
        spec.alloc,
        spec.session_name,
        .{},
    );
    defer server.close();
    return provider.host(spec, server);
}

pub fn attach(
    spec: AttachSpec,
    provider: Provider,
) anyerror!void {
    try runtime_windows.validateSessionName(spec.session_name);
    const endpoint = try runtime_windows.resolveEndpointPath(
        spec.io,
        spec.alloc,
        spec.session_name,
    );
    defer spec.alloc.free(endpoint);
    var connection = try local_ipc_windows.connect(
        spec.alloc,
        .{ .name = endpoint },
    );
    defer connection.close();
    return provider.attach(spec, connection);
}

test "Windows session provider exposes a non-send-only host and attach path" {
    const provider = pendingProvider();
    try std.testing.expectError(
        error.ConPtyProviderUnavailable,
        provider.host(
            .{
                .io = std.testing.io,
                .alloc = std.testing.allocator,
                .session_name = "pending-provider",
                .shell = "cmd.exe",
            },
            .{
                .handle = 0,
                .accept_fn = undefined,
                .close_fn = undefined,
            },
        ),
    );
}

const ConcurrentServeProbe = struct {
    server: local_ipc.Server,
    done: *Cancellation,
    seen: std.atomic.Value(usize) = .init(0),
    completed: bool = false,
};

fn concurrentServeHandler(
    context: *anyopaque,
    tag: wire.Tag,
    payload: []const u8,
) anyerror!DispatchResult {
    const probe: *ConcurrentServeProbe = @ptrCast(@alignCast(context));
    if (tag == .Output and std.mem.eql(u8, payload, "second")) {
        _ = probe.seen.fetchAdd(1, .acq_rel);
        try probe.done.cancel();
    }
    return .close_connection;
}

fn concurrentServeThread(probe: *ConcurrentServeProbe) void {
    const handler = Handler{
        .context = probe,
        .handle_fn = concurrentServeHandler,
    };
    serveConnectionsWithOptions(
        std.testing.allocator,
        probe.server,
        handler,
        .{ .client_deadline_ms = 5000 },
    ) catch {};
    probe.completed = true;
}

test "Windows session dispatch accepts a second client while the first stalls" {
    const alloc = std.testing.allocator;
    var server = try local_ipc_windows.listen(
        alloc,
        .{ .name = "zmx-session-concurrent-dispatch" },
        .{},
    );
    defer server.close();
    var done = try Cancellation.init();
    defer done.deinit();

    var probe = ConcurrentServeProbe{
        .server = server,
        .done = &done,
    };
    var thread = try std.Thread.spawn(.{}, concurrentServeThread, .{&probe});

    var stalled = try local_ipc_windows.connect(
        alloc,
        .{ .name = "zmx-session-concurrent-dispatch" },
    );
    defer stalled.close();
    var second = try local_ipc_windows.connect(
        alloc,
        .{ .name = "zmx-session-concurrent-dispatch" },
    );
    defer second.close();
    try wire.writeFrame(second, .Output, "second");

    const deadline = Deadline.afterMs(5000);
    while (!done.isCancelled()) {
        if ((deadline.remainingMs() orelse 0) == 0) {
            server.close();
            thread.join();
            return error.Timeout;
        }
        std.atomic.spinLoopHint();
    }
    server.close();
    thread.join();
    try std.testing.expect(probe.completed);
    try std.testing.expectEqual(@as(usize, 1), probe.seen.load(.acquire));
}

const SequentialServeProbe = struct {
    server: local_ipc.Server,
    seen: std.atomic.Value(usize) = .init(0),
    completed: bool = false,
};

fn sequentialServeHandler(
    context: *anyopaque,
    _: wire.Tag,
    _: []const u8,
) anyerror!DispatchResult {
    const probe: *SequentialServeProbe = @ptrCast(@alignCast(context));
    _ = probe.seen.fetchAdd(1, .acq_rel);
    return .continue_connection;
}

fn sequentialServeThread(probe: *SequentialServeProbe) void {
    const handler = Handler{
        .context = probe,
        .handle_fn = sequentialServeHandler,
    };
    serveConnectionsWithOptions(
        std.testing.allocator,
        probe.server,
        handler,
        .{},
    ) catch {};
    probe.completed = true;
}

fn connectSequentialStressClient(
    alloc: std.mem.Allocator,
) !local_ipc.Connection {
    const deadline = Deadline.afterMs(1000);
    while (true) {
        return local_ipc_windows.connect(
            alloc,
            .{ .name = "zmx-session-worker-reap-stress" },
        ) catch |err| switch (err) {
            error.ConnectionRefused => {
                if ((deadline.remainingMs() orelse 0) == 0) return err;
                std.atomic.spinLoopHint();
                continue;
            },
            else => return err,
        };
    }
}

test "Windows session dispatch reaps many sequential client workers" {
    const alloc = std.testing.allocator;
    var server = try local_ipc_windows.listen(
        alloc,
        .{ .name = "zmx-session-worker-reap-stress" },
        .{},
    );
    defer server.close();
    var probe = SequentialServeProbe{ .server = server };
    var thread = try std.Thread.spawn(.{}, sequentialServeThread, .{&probe});
    const deadline = Deadline.afterMs(30_000);

    var index: usize = 0;
    while (index < 128) : (index += 1) {
        var client = try connectSequentialStressClient(alloc);
        wire.writeFrame(client, .Output, "x") catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => {},
            else => return err,
        };
        client.close();

        while (probe.seen.load(.acquire) < index + 1) {
            if ((deadline.remainingMs() orelse 0) == 0) {
                server.close();
                thread.join();
                return error.Timeout;
            }
            std.atomic.spinLoopHint();
        }
    }

    while (probe.seen.load(.acquire) < 128) {
        if ((deadline.remainingMs() orelse 0) == 0) {
            server.close();
            thread.join();
            return error.Timeout;
        }
        std.atomic.spinLoopHint();
    }
    server.close();
    thread.join();
    try std.testing.expect(probe.completed);
    try std.testing.expectEqual(@as(usize, 128), probe.seen.load(.acquire));
}

test "Windows failed worker spawn removes the exact worker under the mutex" {
    var state = ServeState{
        .alloc = std.testing.allocator,
        .server = undefined,
        .handler = undefined,
        .options = .{},
    };
    var first = ClientWorker{
        .state = &state,
        .connection = undefined,
        .cancellation = undefined,
    };
    var second = ClientWorker{
        .state = &state,
        .connection = undefined,
        .cancellation = undefined,
    };
    try state.workers.append(std.testing.allocator, &first);
    try state.workers.append(std.testing.allocator, &second);
    state.mutex.lock();
    const removed = removeWorkerLocked(&state, &first);
    state.mutex.unlock();
    defer state.workers.deinit(std.testing.allocator);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 1), state.workers.items.len);
    try std.testing.expectEqual(&second, state.workers.items[0]);
    try std.testing.expect(!removeWorkerLocked(&state, &first));
}
