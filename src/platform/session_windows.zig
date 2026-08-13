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
    while (true) {
        var frame = wire.readFrame(alloc, connection) catch |err| switch (err) {
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

pub fn serveConnections(
    alloc: std.mem.Allocator,
    server: local_ipc.Server,
    handler: Handler,
) anyerror!void {
    while (true) {
        var connection = server.accept() catch |err| switch (err) {
            error.AlreadyClosed => return,
            else => return err,
        };
        defer connection.close();
        const result = try dispatchConnection(alloc, connection, handler);
        if (result == .stop_session) return;
    }
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
