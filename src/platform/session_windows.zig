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
};

const ClientWorker = struct {
    state: *ServeState,
    connection: local_ipc.Connection,
    cancellation: Cancellation,
    thread: ?std.Thread = null,
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
    worker.connection.close();
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
        worker.thread = std.Thread.spawn(.{}, clientWorkerMain, .{worker}) catch |err| {
            state.mutex.lock();
            _ = state.workers.pop();
            state.mutex.unlock();
            worker.cancellation.deinit();
            alloc.destroy(worker);
            connection.close();
            accept_error = err;
            break;
        };
    }

    stopServing(&state);
    joinWorkers(&state);
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
