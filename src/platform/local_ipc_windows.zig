const builtin = @import("builtin");
const std = @import("std");
const local_ipc = @import("local_ipc.zig");
const events_windows = @import("events_windows.zig");
const runtime_windows = @import("runtime_windows.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("local_ipc_windows requires a Windows target");
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;
const OVERLAPPED = extern struct {
    internal: usize,
    internal_high: usize,
    offset: windows.DWORD,
    offset_high: windows.DWORD,
    hEvent: windows.HANDLE,
};

const create_event_manual_reset: windows.DWORD = 1;
const event_modify_state: windows.DWORD = 2;
const synchronize: windows.DWORD = 0x0010_0000;
const pipe_access_duplex: windows.DWORD = 3;
const file_flag_overlapped: windows.DWORD = 0x4000_0000;
const pipe_type_byte: windows.DWORD = 0;
const pipe_readmode_byte: windows.DWORD = 0;
const pipe_wait: windows.DWORD = 0;
const generic_read: windows.DWORD = 0x8000_0000;
const generic_write: windows.DWORD = 0x4000_0000;
const open_existing: windows.DWORD = 3;
const infinite: windows.DWORD = 0xffff_ffff;

fn winBool(comptime T: type, value: bool) T {
    return switch (@typeInfo(T)) {
        .@"enum" => @enumFromInt(@intFromBool(value)),
        else => @intFromBool(value),
    };
}

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    string_security_descriptor: windows.LPCWSTR,
    string_sd_revision: windows.DWORD,
    security_descriptor: *?*anyopaque,
    security_descriptor_size: ?*windows.DWORD,
) callconv(.winapi) c_int;

extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ConnectNamedPipe(
    pipe: windows.HANDLE,
    overlapped: ?*OVERLAPPED,
) callconv(.winapi) c_int;
extern "kernel32" fn CreateEventExW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    name: ?windows.LPCWSTR,
    flags: windows.DWORD,
    desired_access: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CreateNamedPipeW(
    name: windows.LPCWSTR,
    open_mode: windows.DWORD,
    pipe_mode: windows.DWORD,
    max_instances: windows.DWORD,
    out_buffer_size: windows.DWORD,
    in_buffer_size: windows.DWORD,
    default_timeout: windows.DWORD,
    attributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CreateFileW(
    name: windows.LPCWSTR,
    desired_access: windows.DWORD,
    share_mode: windows.DWORD,
    security_attributes: ?*windows.SECURITY_ATTRIBUTES,
    creation_disposition: windows.DWORD,
    flags_and_attributes: windows.DWORD,
    template_file: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CancelIoEx(
    file: windows.HANDLE,
    overlapped: ?*OVERLAPPED,
) callconv(.winapi) c_int;
extern "kernel32" fn GetOverlappedResult(
    file: windows.HANDLE,
    overlapped: *OVERLAPPED,
    transferred: *windows.DWORD,
    wait: c_int,
) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    buffer: [*]u8,
    bytes_to_read: windows.DWORD,
    bytes_read: *windows.DWORD,
    overlapped: ?*OVERLAPPED,
) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: windows.DWORD,
    bytes_written: *windows.DWORD,
    overlapped: ?*OVERLAPPED,
) callconv(.winapi) c_int;
extern "kernel32" fn DisconnectNamedPipe(pipe: windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn WaitNamedPipeW(
    name: windows.LPCWSTR,
    timeout_ms: windows.DWORD,
) callconv(.winapi) c_int;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(
    handle: windows.HANDLE,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForMultipleObjectsEx(
    count: windows.DWORD,
    handles: [*]const windows.HANDLE,
    wait_all: c_int,
    milliseconds: windows.DWORD,
    alertable: c_int,
) callconv(.winapi) windows.DWORD;

pub const Error = error{
    AccessDenied,
    AlreadyClosed,
    BrokenPipe,
    Cancelled,
    ConnectionRefused,
    ConnectionResetByPeer,
    InvalidEndpoint,
    NameTooLong,
    NotConnected,
    SystemResources,
    Timeout,
    Unexpected,
} || std.mem.Allocator.Error;

pub const default_timeout_ms: u32 = 1000;
pub const io_buffer_size: usize = 64 * 1024;
const first_pipe_instance: windows.DWORD = 0x0008_0000;
const reject_remote_clients: windows.DWORD = 0x0000_0008;

fn handleValue(handle: windows.HANDLE) local_ipc.Handle {
    return @intFromPtr(handle);
}

fn handleFromValue(value: local_ipc.Handle) windows.HANDLE {
    return @ptrFromInt(value);
}

fn mapLastError(err: windows.Win32Error) Error {
    return switch (err) {
        .ACCESS_DENIED => error.AccessDenied,
        .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
        .FILE_NOT_FOUND, .PIPE_BUSY, .PIPE_NOT_CONNECTED => error.ConnectionRefused,
        .INVALID_HANDLE => error.AlreadyClosed,
        .INVALID_NAME, .BAD_PATHNAME => error.InvalidEndpoint,
        .OPERATION_ABORTED => error.Cancelled,
        .PIPE_CONNECTED => error.ConnectionResetByPeer,
        else => error.Unexpected,
    };
}

fn completionEvent() Error!windows.HANDLE {
    return CreateEventExW(
        null,
        null,
        create_event_manual_reset,
        event_modify_state | synchronize,
    ) orelse error.SystemResources;
}

fn utf16Endpoint(alloc: std.mem.Allocator, endpoint: []const u8) Error![:0]u16 {
    if (!std.unicode.utf8ValidateSlice(endpoint)) return error.InvalidEndpoint;
    const path = if (std.mem.startsWith(u8, endpoint, "\\\\.\\pipe\\"))
        try alloc.dupe(u8, endpoint)
    else
        runtime_windows.endpointPath(alloc, endpoint) catch |err| switch (err) {
            error.InvalidSessionName => return error.InvalidEndpoint,
            error.NameTooLong => return error.NameTooLong,
            error.AccessDenied => return error.AccessDenied,
            error.InvalidRecord => return error.InvalidEndpoint,
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => return error.Unexpected,
        };
    defer alloc.free(path);

    const result = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidEndpoint,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (result.len >= runtime_windows.max_pipe_name_utf16) {
        alloc.free(result);
        return error.NameTooLong;
    }
    return result;
}

fn securitySddl(policy: local_ipc.AccessPolicy) []const u8 {
    return if (policy.owner_only)
        runtime_windows.securityDescriptorSddl
    else
        "D:P(A;;GA;;;WD)(A;;GA;;;SY)";
}

fn createPipe(
    alloc: std.mem.Allocator,
    name: [:0]const u16,
    policy: local_ipc.AccessPolicy,
    first: bool,
) Error!windows.HANDLE {
    const sddl_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, securitySddl(policy)) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidEndpoint,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(sddl_w);

    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        1,
        &descriptor,
        null,
    ) == 0) {
        return error.AccessDenied;
    }
    defer _ = LocalFree(descriptor);

    var attributes = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = descriptor,
        .bInheritHandle = winBool(
            @TypeOf(@as(windows.SECURITY_ATTRIBUTES, undefined).bInheritHandle),
            false,
        ),
    };
    var open_mode: windows.DWORD = pipe_access_duplex | file_flag_overlapped;
    if (first) open_mode |= first_pipe_instance;
    const pipe = CreateNamedPipeW(
        name.ptr,
        open_mode,
        pipe_type_byte |
            pipe_readmode_byte |
            pipe_wait |
            reject_remote_clients,
        255,
        io_buffer_size,
        io_buffer_size,
        0,
        &attributes,
    );
    if (pipe == windows.INVALID_HANDLE_VALUE) {
        return mapLastError(windows.GetLastError());
    }
    return pipe;
}

const ServerState = struct {
    allocator: std.mem.Allocator,
    name: [:0]u16,
    policy: local_ipc.AccessPolicy,
    pipe: ?windows.HANDLE,
    closing_pipe: ?windows.HANDLE = null,
    close_event: windows.HANDLE,
    rendezvous_lease: ?*runtime_windows.SessionLease = null,
    rendezvous_io: ?std.Io = null,
    rendezvous_session: ?[]u8 = null,
    rendezvous_endpoint: ?[]u8 = null,
    mutex: std.atomic.Value(u8) = .init(0),
    accepts_in_flight: usize = 0,
    closed: bool = false,

    fn lock(self: *ServerState) void {
        while (self.mutex.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *ServerState) void {
        self.mutex.store(0, .release);
    }
};

/// A copied `local_ipc.Server` value cannot participate in reference
/// counting. Keep the small control record as a tombstone after close so a
/// late accept through such a copy observes `AlreadyClosed` instead of
/// dereferencing freed memory. All kernel handles are still released by
/// `closeServerThunk`; only this process-lifetime control record remains.
const server_state_allocator = std.heap.page_allocator;

pub const Factory = struct {
    allocator: std.mem.Allocator,

    pub fn listener(self: *Factory) local_ipc.Listener {
        return .{
            .context = self,
            .listen_fn = listenThunk,
        };
    }

    pub fn client(self: *Factory) local_ipc.Client {
        return .{
            .context = self,
            .connect_fn = connectThunk,
        };
    }
};

pub const Adapter = Factory;

pub fn listen(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
    policy: local_ipc.AccessPolicy,
) Error!local_ipc.Server {
    _ = alloc;
    const name = try utf16Endpoint(server_state_allocator, endpoint.name);
    errdefer server_state_allocator.free(name);
    const pipe = try createPipe(server_state_allocator, name, policy, true);
    errdefer windows.CloseHandle(pipe);
    const close_event = try completionEvent();
    errdefer windows.CloseHandle(close_event);

    const state = try server_state_allocator.create(ServerState);
    errdefer server_state_allocator.destroy(state);
    state.* = .{
        .allocator = server_state_allocator,
        .name = name,
        .policy = policy,
        .pipe = pipe,
        .close_event = close_event,
    };
    return .{
        .handle = @intFromPtr(state),
        .accept_fn = acceptThunk,
        .close_fn = closeServerThunk,
    };
}

/// Start a session listener on a fresh nonce endpoint and publish its
/// owner-created rendezvous record. A pre-created deterministic pipe can no
/// longer permanently deny service, and clients can resolve the published
/// endpoint through `socket.getSocketPathWithIo`.
pub fn listenSession(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    policy: local_ipc.AccessPolicy,
) Error!local_ipc.Server {
    const lease: *runtime_windows.SessionLease = runtime_windows.acquireSessionLease(io, session_name) catch |err| switch (err) {
        error.InvalidSessionName => return error.InvalidEndpoint,
        error.NameTooLong => return error.NameTooLong,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AccessDenied,
    };
    var lease_attached = false;
    defer if (!lease_attached) lease.release();

    if (runtime_windows.hasRendezvous(io, alloc, session_name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSessionName => return error.InvalidEndpoint,
        else => return error.AccessDenied,
    }) {
        const existing = runtime_windows.resolveEndpointPath(io, alloc, session_name) catch |err| switch (err) {
            error.InvalidRecord => blk: {
                runtime_windows.cleanupRendezvous(io, alloc, session_name);
                break :blk null;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.AccessDenied,
        };
        if (existing) |endpoint| {
            defer alloc.free(endpoint);
            if (try endpointIsLive(alloc, endpoint)) return error.AccessDenied;
            runtime_windows.cleanupRendezvous(io, alloc, session_name);
        }
    }

    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        const endpoint = runtime_windows.nonceEndpointPath(alloc, session_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSessionName => return error.InvalidEndpoint,
            error.NameTooLong => return error.NameTooLong,
            else => return error.Unexpected,
        };
        defer alloc.free(endpoint);

        var server = listen(alloc, .{ .name = endpoint }, policy) catch |err| {
            if (err == error.AccessDenied or err == error.SystemResources) continue;
            return err;
        };
        runtime_windows.replaceEndpoint(io, alloc, session_name, endpoint) catch |err| {
            runtime_windows.cleanupRendezvousIfOwned(
                io,
                server_state_allocator,
                session_name,
                endpoint,
            );
            server.close();
            if (err == error.AccessDenied) continue;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unexpected,
            };
        };
        const published = runtime_windows.resolveEndpointPath(io, alloc, session_name) catch |err| {
            runtime_windows.cleanupRendezvousIfOwned(
                io,
                server_state_allocator,
                session_name,
                endpoint,
            );
            server.close();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unexpected,
            };
        };
        defer alloc.free(published);
        if (!std.mem.eql(u8, published, endpoint)) {
            runtime_windows.cleanupRendezvousIfOwned(
                io,
                server_state_allocator,
                session_name,
                endpoint,
            );
            server.close();
            return error.Unexpected;
        }

        const state: *ServerState = @ptrFromInt(server.handle);
        const session_copy = server_state_allocator.dupe(u8, session_name) catch {
            runtime_windows.cleanupRendezvousIfOwned(
                io,
                server_state_allocator,
                session_name,
                endpoint,
            );
            server.close();
            return error.OutOfMemory;
        };
        const endpoint_copy = server_state_allocator.dupe(u8, endpoint) catch {
            server_state_allocator.free(session_copy);
            runtime_windows.cleanupRendezvousIfOwned(
                io,
                server_state_allocator,
                session_name,
                endpoint,
            );
            server.close();
            return error.OutOfMemory;
        };
        state.lock();
        state.rendezvous_lease = lease;
        state.rendezvous_io = io;
        state.rendezvous_session = session_copy;
        state.rendezvous_endpoint = endpoint_copy;
        state.unlock();
        lease_attached = true;
        return server;
    }

    return error.AccessDenied;
}

fn endpointIsLive(alloc: std.mem.Allocator, endpoint: []const u8) Error!bool {
    const name = try utf16Endpoint(alloc, endpoint);
    defer alloc.free(name);
    if (WaitNamedPipeW(name.ptr, 0) != 0) return true;
    const err = windows.GetLastError();
    if (waitErrorMeansLive(err)) return true;
    return switch (err) {
        .FILE_NOT_FOUND => false,
        else => error.AccessDenied,
    };
}

fn waitErrorMeansLive(err: windows.Win32Error) bool {
    return err == .SEM_TIMEOUT or err == .PIPE_BUSY;
}

test "Windows semaphore timeout is treated as a live pipe" {
    try std.testing.expect(waitErrorMeansLive(.SEM_TIMEOUT));
    try std.testing.expect(waitErrorMeansLive(.PIPE_BUSY));
    try std.testing.expect(!waitErrorMeansLive(.FILE_NOT_FOUND));
}

const AcceptCloseRace = struct {
    server: local_ipc.Server,
    result: ?Error = null,
};

const CancelCloseRace = struct {
    server: local_ipc.Server,
    cancellation: *events_windows.Cancellation,
    result: ?Error = null,
};

fn acceptCloseRaceThread(race: *AcceptCloseRace) void {
    var connection = acceptServerWithDeadline(
        race.server,
        events_windows.Deadline.afterMs(1000),
        null,
    ) catch |err| {
        race.result = err;
        return;
    };
    connection.close();
    race.result = error.Unexpected;
}

fn acceptCancelCloseRaceThread(race: *CancelCloseRace) void {
    _ = acceptServerWithDeadline(
        race.server,
        events_windows.Deadline.afterMs(1000),
        race.cancellation,
    ) catch |err| {
        race.result = err;
        return;
    };
    race.result = error.Unexpected;
}

const SessionOwnerRace = struct {
    server: ?local_ipc.Server = null,
    result: ?Error = null,
};

fn sessionOwnerRaceThread(race: *SessionOwnerRace) void {
    race.server = listenSession(
        std.testing.io,
        std.heap.page_allocator,
        "zmx-concurrent-owner",
        .{},
    ) catch |err| {
        race.result = err;
        return;
    };
}

fn listenThunk(
    context: *anyopaque,
    endpoint: local_ipc.Endpoint,
    policy: local_ipc.AccessPolicy,
) anyerror!local_ipc.Server {
    const factory: *Factory = @ptrCast(@alignCast(context));
    return listen(factory.allocator, endpoint, policy);
}

fn connectThunk(context: *anyopaque, endpoint: local_ipc.Endpoint) anyerror!local_ipc.Connection {
    const factory: *Factory = @ptrCast(@alignCast(context));
    return connect(factory.allocator, endpoint);
}

pub fn connect(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
) Error!local_ipc.Connection {
    return connectWithDeadline(
        alloc,
        endpoint,
        events_windows.Deadline.afterMs(default_timeout_ms),
        null,
    );
}

pub fn reconnect(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
    deadline: events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    return connectWithDeadline(alloc, endpoint, deadline, cancellation);
}

/// A named-pipe endpoint has no directory entry to unlink. The kernel removes
/// it once the server's last handle is closed.
pub fn cleanupStaleEndpoint(_: []const u8) void {}

pub fn connectWithDeadline(
    alloc: std.mem.Allocator,
    endpoint: local_ipc.Endpoint,
    deadline: events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    const name = try utf16Endpoint(alloc, endpoint.name);
    defer alloc.free(name);

    while (true) {
        if (cancellation) |cancel| {
            if (cancel.isCancelled()) return error.Cancelled;
        }
        if (deadline.remainingMs() == 0) return error.Timeout;
        const pipe = CreateFileW(
            name.ptr,
            generic_read | generic_write,
            0,
            null,
            open_existing,
            file_flag_overlapped,
            null,
        );
        if (pipe != windows.INVALID_HANDLE_VALUE) {
            runtime_windows.verifyPipeServerIdentity(alloc, pipe) catch |err| {
                windows.CloseHandle(pipe);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.AccessDenied => error.AccessDenied,
                    else => error.Unexpected,
                };
            };
            return .{
                .handle = handleValue(pipe),
                .close_fn = closeHandle,
                .read_fn = readHandle,
                .write_fn = writeHandle,
            };
        }

        switch (windows.GetLastError()) {
            .PIPE_BUSY => {
                const remaining = deadline.remainingMs() orelse 0;
                if (remaining == 0) return error.Timeout;
                if (cancellation) |cancel| {
                    if (cancel.isCancelled()) return error.Cancelled;
                }
                const slice = @min(remaining, @as(u32, 50));
                if (WaitNamedPipeW(name.ptr, slice) == 0) {
                    switch (windows.GetLastError()) {
                        .SEM_TIMEOUT => {
                            if (deadline.remainingMs() == 0) return error.Timeout;
                            continue;
                        },
                        .FILE_NOT_FOUND => return error.ConnectionRefused,
                        else => |err| return mapLastError(err),
                    }
                }
            },
            .FILE_NOT_FOUND => return error.ConnectionRefused,
            else => |err| return mapLastError(err),
        }
    }
}

fn acceptThunk(value: local_ipc.Handle) anyerror!local_ipc.Connection {
    const state: *ServerState = @ptrFromInt(value);
    return acceptWithDeadline(state, null, null);
}

fn acceptWithDeadline(
    state: *ServerState,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    const event = try completionEvent();
    defer windows.CloseHandle(event);
    var overlapped = std.mem.zeroes(OVERLAPPED);
    overlapped.hEvent = event;

    state.lock();
    if (state.closed) {
        state.unlock();
        return error.AlreadyClosed;
    }
    const pipe = state.pipe orelse {
        state.unlock();
        return error.AlreadyClosed;
    };
    state.accepts_in_flight += 1;
    // Shutdown is serialized with posting the overlapped operation. Once
    // close observes accepts_in_flight, ConnectNamedPipe has already been
    // issued and CancelIoEx can reliably cancel it.
    const connected = ConnectNamedPipe(pipe, &overlapped);
    state.unlock();
    defer finishAccept(state);

    if (connected == 0) {
        switch (windows.GetLastError()) {
            .PIPE_CONNECTED => {},
            .IO_PENDING => awaitCompletion(pipe, &overlapped, event, deadline, cancellation) catch |err| {
                resetPipe(state, pipe);
                return err;
            },
            else => |err| {
                resetPipe(state, pipe);
                return mapLastError(err);
            },
        }
    }

    state.lock();
    if (state.closed) {
        const close_owns_pipe = state.closing_pipe == pipe;
        state.unlock();
        if (!close_owns_pipe) {
            _ = DisconnectNamedPipe(pipe);
            windows.CloseHandle(pipe);
        }
        return error.AlreadyClosed;
    }
    state.pipe = null;
    state.unlock();
    const next_pipe = createPipe(state.allocator, state.name, state.policy, false) catch |err| {
        windows.CloseHandle(pipe);
        return err;
    };
    state.lock();
    if (state.closed) {
        const close_owns_pipe = state.closing_pipe == pipe;
        state.unlock();
        windows.CloseHandle(next_pipe);
        if (!close_owns_pipe) {
            _ = DisconnectNamedPipe(pipe);
            windows.CloseHandle(pipe);
        }
        return error.AlreadyClosed;
    }
    state.pipe = next_pipe;
    state.unlock();
    return .{
        .handle = handleValue(pipe),
        .close_fn = closeHandle,
        .read_fn = readHandle,
        .write_fn = writeHandle,
    };
}

fn finishAccept(state: *ServerState) void {
    state.lock();
    state.accepts_in_flight -= 1;
    if (state.closed and state.accepts_in_flight == 0) {
        _ = SetEvent(state.close_event);
    }
    state.unlock();
}

fn resetPipe(state: *ServerState, pipe: windows.HANDLE) void {
    state.lock();
    const replace = !state.closed and state.pipe == pipe;
    // Once shutdown has claimed this handle, the close path is its sole
    // owner. In particular, a cancelled accept must not close a handle that
    // closeServerThunk will close after the in-flight barrier.
    const close_owns_pipe = state.closed and state.closing_pipe == pipe;
    if (replace) state.pipe = null;
    state.unlock();
    if (close_owns_pipe) return;
    _ = DisconnectNamedPipe(pipe);
    windows.CloseHandle(pipe);
    if (!replace) return;
    const replacement = createPipe(state.allocator, state.name, state.policy, false) catch null;
    if (replacement) |new_pipe| {
        state.lock();
        if (state.closed or state.pipe != null) {
            state.unlock();
            windows.CloseHandle(new_pipe);
        } else {
            state.pipe = new_pipe;
            state.unlock();
        }
    }
}

pub fn acceptServerWithDeadline(
    server: local_ipc.Server,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!local_ipc.Connection {
    const state: *ServerState = @ptrFromInt(server.handle);
    return acceptWithDeadline(state, deadline, cancellation);
}

fn awaitCompletion(
    pipe: windows.HANDLE,
    overlapped: *OVERLAPPED,
    event: windows.HANDLE,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!void {
    const timeout = if (deadline) |value| value.remainingMs() orelse 0 else infinite;
    if (timeout == 0 and deadline != null) {
        _ = CancelIoEx(pipe, overlapped);
        _ = WaitForSingleObject(event, infinite);
        return error.Timeout;
    }

    var handles: [2]windows.HANDLE = undefined;
    handles[0] = event;
    var count: usize = 1;
    if (cancellation) |cancel| {
        handles[1] = cancel.handle;
        count = 2;
    }
    const result = WaitForMultipleObjectsEx(
        @intCast(count),
        &handles,
        0,
        timeout,
        0,
    );
    if (result == 0x102) {
        _ = CancelIoEx(pipe, overlapped);
        _ = WaitForSingleObject(event, infinite);
        return error.Timeout;
    }
    if (result == 0x80) {
        _ = CancelIoEx(pipe, overlapped);
        _ = WaitForSingleObject(event, infinite);
        return error.Cancelled;
    }
    if (result == 1 and count == 2) {
        _ = CancelIoEx(pipe, overlapped);
        _ = WaitForSingleObject(event, infinite);
        return error.Cancelled;
    }

    var transferred: windows.DWORD = 0;
    if (GetOverlappedResult(pipe, overlapped, &transferred, 0) == 0) {
        return mapLastError(windows.GetLastError());
    }
}

pub fn read(
    connection: local_ipc.Connection,
    buffer: []u8,
) Error!usize {
    return readWithDeadline(connection.handle, buffer, null, null);
}

pub fn readWithDeadline(
    value: local_ipc.Handle,
    buffer: []u8,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!usize {
    if (buffer.len == 0) return 0;
    try checkDeadline(deadline, cancellation);
    const pipe = handleFromValue(value);
    const event = try completionEvent();
    defer windows.CloseHandle(event);
    var overlapped = std.mem.zeroes(OVERLAPPED);
    overlapped.hEvent = event;
    var transferred: windows.DWORD = 0;
    const amount: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
    if (ReadFile(pipe, buffer.ptr, amount, &transferred, &overlapped) == 0) {
        switch (windows.GetLastError()) {
            .IO_PENDING => try awaitCompletion(pipe, &overlapped, event, deadline, cancellation),
            else => |err| return mapLastError(err),
        }
        if (GetOverlappedResult(pipe, &overlapped, &transferred, 0) == 0) {
            return mapLastError(windows.GetLastError());
        }
    }
    return transferred;
}

pub fn write(
    connection: local_ipc.Connection,
    bytes: []const u8,
) Error!usize {
    return writeWithDeadline(connection.handle, bytes, null, null);
}

pub fn writeWithDeadline(
    value: local_ipc.Handle,
    bytes: []const u8,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!usize {
    if (bytes.len == 0) return 0;
    try checkDeadline(deadline, cancellation);
    const pipe = handleFromValue(value);
    const event = try completionEvent();
    defer windows.CloseHandle(event);
    var overlapped = std.mem.zeroes(OVERLAPPED);
    overlapped.hEvent = event;
    var transferred: windows.DWORD = 0;
    const amount: windows.DWORD = @intCast(@min(bytes.len, std.math.maxInt(windows.DWORD)));
    if (WriteFile(pipe, bytes.ptr, amount, &transferred, &overlapped) == 0) {
        switch (windows.GetLastError()) {
            .IO_PENDING => try awaitCompletion(pipe, &overlapped, event, deadline, cancellation),
            else => |err| return mapLastError(err),
        }
        if (GetOverlappedResult(pipe, &overlapped, &transferred, 0) == 0) {
            return mapLastError(windows.GetLastError());
        }
    }
    return transferred;
}

fn checkDeadline(
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!void {
    if (cancellation) |cancel| {
        if (cancel.isCancelled()) return error.Cancelled;
    }
    if (deadline) |value| {
        if (value.remainingMs() == 0) return error.Timeout;
    }
}

pub fn writeAll(
    connection: local_ipc.Connection,
    bytes: []const u8,
    deadline: ?events_windows.Deadline,
    cancellation: ?*events_windows.Cancellation,
) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try writeWithDeadline(
            connection.handle,
            bytes[offset..],
            deadline,
            cancellation,
        );
        if (count == 0) return error.BrokenPipe;
        offset += count;
    }
}

fn closeHandle(value: local_ipc.Handle) void {
    const handle = handleFromValue(value);
    _ = CancelIoEx(handle, null);
    windows.CloseHandle(handle);
}

fn readHandle(value: local_ipc.Handle, buffer: []u8) anyerror!usize {
    return readWithDeadline(value, buffer, null, null);
}

fn writeHandle(value: local_ipc.Handle, bytes: []const u8) anyerror!usize {
    return writeWithDeadline(value, bytes, null, null);
}

fn closeServerThunk(value: local_ipc.Handle) void {
    const state: *ServerState = @ptrFromInt(value);
    state.lock();
    if (state.closed) {
        state.unlock();
        return;
    }
    state.closed = true;
    const pipe = state.pipe;
    state.closing_pipe = pipe;
    state.pipe = null;
    const accepts_in_flight = state.accepts_in_flight;
    state.unlock();

    if (pipe) |handle| {
        _ = CancelIoEx(handle, null);
    }
    if (accepts_in_flight != 0) {
        _ = WaitForSingleObject(state.close_event, infinite);
    }
    if (pipe) |handle| {
        windows.CloseHandle(handle);
    }
    windows.CloseHandle(state.close_event);
    if (state.rendezvous_io) |io| {
        if (state.rendezvous_session) |session_name| {
            if (state.rendezvous_endpoint) |endpoint| {
                runtime_windows.cleanupRendezvousIfOwned(
                    io,
                    server_state_allocator,
                    session_name,
                    endpoint,
                );
                server_state_allocator.free(endpoint);
            }
            server_state_allocator.free(session_name);
        }
    }
    state.rendezvous_endpoint = null;
    state.rendezvous_session = null;
    state.rendezvous_io = null;
    if (state.rendezvous_lease) |lease| {
        state.rendezvous_lease = null;
        lease.release();
    }
}

test "Windows IPC keeps endpoint validation separate from wire framing" {
    const endpoint = local_ipc.Endpoint{ .name = "session-\u{1F600}" };
    try runtime_windows.validateSessionName(endpoint.name);
    try std.testing.expect(endpoint.name.len > 0);
}

test "Windows named pipes support multiple clients and partial writes" {
    const alloc = std.testing.allocator;
    var server = try listen(alloc, .{ .name = "zmx-ipc-test-\u{1F600}" }, .{});
    defer server.close();

    var client_one = try connect(alloc, .{ .name = "zmx-ipc-test-\u{1F600}" });
    defer client_one.close();
    var accepted_one = try server.accept();
    defer accepted_one.close();

    const first = "partial frame";
    try std.testing.expectEqual(@as(usize, 7), try write(client_one, first[0..7]));
    try std.testing.expectEqual(@as(usize, first.len - 7), try write(client_one, first[7..]));
    var first_read: [32]u8 = undefined;
    try std.testing.expectEqual(first.len, try read(accepted_one, first_read[0..first.len]));
    try std.testing.expectEqualStrings(first, first_read[0..first.len]);

    var client_two = try connect(alloc, .{ .name = "zmx-ipc-test-\u{1F600}" });
    defer client_two.close();
    var accepted_two = try server.accept();
    defer accepted_two.close();
    try writeAll(client_two, "second", null, null);
    var second_read: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try read(accepted_two, &second_read));
    try std.testing.expectEqualStrings("second", &second_read);
}

test "Windows named pipe accept is cancellable before a client connects" {
    const alloc = std.testing.allocator;
    var server = try listen(alloc, .{ .name = "zmx-ipc-cancel-\u{1F600}" }, .{});
    defer server.close();
    var cancellation = try events_windows.Cancellation.init();
    defer cancellation.deinit();
    try cancellation.cancel();
    try std.testing.expectError(
        error.Cancelled,
        acceptServerWithDeadline(server, events_windows.Deadline.afterMs(1000), &cancellation),
    );
    try cancellation.reset();
    var client = try connect(alloc, .{ .name = "zmx-ipc-cancel-\u{1F600}" });
    defer client.close();
    var accepted = try server.accept();
    defer accepted.close();
}

test "Windows named pipe late accept after close observes closed state" {
    const alloc = std.testing.allocator;
    var server = try listen(alloc, .{ .name = "zmx-ipc-late-close-\u{1F600}" }, .{});
    const stale_copy = server;
    server.close();
    try std.testing.expectError(error.AlreadyClosed, stale_copy.accept());
}

test "Windows accept close races serialize operation posting" {
    const alloc = std.testing.allocator;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var server = try listen(
            alloc,
            .{ .name = "zmx-ipc-accept-close-race" },
            .{},
        );
        var race = AcceptCloseRace{ .server = server };
        var thread = try std.Thread.spawn(.{}, acceptCloseRaceThread, .{&race});
        server.close();
        thread.join();
        try std.testing.expect(race.result != null);
        try std.testing.expect(race.result.? != error.Unexpected);
    }
}

test "Windows cancelled accept never closes shutdown-owned pipe" {
    const alloc = std.testing.allocator;
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        var server = try listen(
            alloc,
            .{ .name = "zmx-ipc-cancel-close-owner" },
            .{},
        );
        var cancellation = try events_windows.Cancellation.init();
        var race = CancelCloseRace{
            .server = server,
            .cancellation = &cancellation,
        };
        var thread = try std.Thread.spawn(.{}, acceptCancelCloseRaceThread, .{&race});
        try cancellation.cancel();
        server.close();
        thread.join();
        cancellation.deinit();
        try std.testing.expect(race.result != null);
        try std.testing.expect(race.result.? != error.Unexpected);
    }
}

test "Windows session listener publishes a recoverable endpoint" {
    const alloc = std.testing.allocator;
    const session_name = "zmx-rendezvous-\u{1F600}";
    defer runtime_windows.cleanupRendezvous(std.testing.io, alloc, session_name);
    var server = try listenSession(std.testing.io, alloc, session_name, .{});
    defer server.close();

    const endpoint = try runtime_windows.resolveEndpointPath(
        std.testing.io,
        alloc,
        session_name,
    );
    defer alloc.free(endpoint);
    try std.testing.expectError(
        error.AccessDenied,
        listenSession(std.testing.io, alloc, session_name, .{}),
    );
    var client = try connect(alloc, .{ .name = endpoint });
    defer client.close();
    var accepted = try server.accept();
    defer accepted.close();
    try writeAll(client, "published", null, null);
    var received: [9]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 9), try read(accepted, &received));
    try std.testing.expectEqualStrings("published", &received);

    server.close();
    try std.testing.expect(!(try runtime_windows.hasRendezvous(
        std.testing.io,
        alloc,
        session_name,
    )));
}

test "Windows malformed rendezvous recovers while holding the session lease" {
    const alloc = std.testing.allocator;
    const session_name = "zmx-malformed-rendezvous";
    defer runtime_windows.cleanupRendezvous(std.testing.io, alloc, session_name);
    try runtime_windows.publishEndpoint(
        std.testing.io,
        alloc,
        session_name,
        "malformed-record",
    );

    var server = try listenSession(std.testing.io, alloc, session_name, .{});
    defer server.close();
    const endpoint = try runtime_windows.resolveEndpointPath(
        std.testing.io,
        alloc,
        session_name,
    );
    defer alloc.free(endpoint);
    try std.testing.expect(std.mem.startsWith(u8, endpoint, runtime_windows.pipe_prefix));
}

test "Windows session lease serializes concurrent owners" {
    const session_name = "zmx-concurrent-owner";
    defer runtime_windows.cleanupRendezvous(std.testing.io, std.heap.page_allocator, session_name);

    var first = SessionOwnerRace{};
    var second = SessionOwnerRace{};
    var first_thread = try std.Thread.spawn(.{}, sessionOwnerRaceThread, .{&first});
    var second_thread = try std.Thread.spawn(.{}, sessionOwnerRaceThread, .{&second});
    first_thread.join();
    second_thread.join();

    const owners = @as(usize, @intFromBool(first.server != null)) +
        @as(usize, @intFromBool(second.server != null));
    try std.testing.expectEqual(@as(usize, 1), owners);
    if (first.server) |server| server.close();
    if (second.server) |server| server.close();
    if (first.server == null) try std.testing.expectEqual(error.AccessDenied, first.result.?);
    if (second.server == null) try std.testing.expectEqual(error.AccessDenied, second.result.?);
}
