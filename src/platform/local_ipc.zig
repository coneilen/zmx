const std = @import("std");

/// Local IPC is a byte stream.  Framing remains in `src/ipc.zig`; this module
/// only describes how a client and listener obtain a bidirectional stream.
pub const Handle = usize;

pub const Endpoint = struct {
    name: []const u8,
};

pub const Connection = struct {
    handle: Handle,
    close_fn: *const fn (Handle) void,

    pub fn close(self: Connection) void {
        self.close_fn(self.handle);
    }
};

pub const Server = struct {
    handle: Handle,
    accept_fn: *const fn (Handle) anyerror!Connection,
    close_fn: *const fn (Handle) void,

    pub fn accept(self: Server) !Connection {
        return self.accept_fn(self.handle);
    }

    pub fn close(self: Server) void {
        self.close_fn(self.handle);
    }
};

pub const Listener = struct {
    context: *anyopaque,
    listen_fn: *const fn (*anyopaque, Endpoint, AccessPolicy) anyerror!Server,

    pub fn listen(self: Listener, endpoint: Endpoint, policy: AccessPolicy) !Server {
        return self.listen_fn(self.context, endpoint, policy);
    }
};

pub const Client = struct {
    context: *anyopaque,
    connect_fn: *const fn (*anyopaque, Endpoint) anyerror!Connection,

    pub fn connect(self: Client, endpoint: Endpoint) !Connection {
        return self.connect_fn(self.context, endpoint);
    }
};

pub const AccessPolicy = struct {
    directory_mode: u32 = 0o750,
    endpoint_mode: u32 = 0o600,
    owner_only: bool = true,
};

test "local IPC contract keeps framing out of transport" {
    const endpoint = Endpoint{ .name = "session" };
    try std.testing.expectEqualStrings("session", endpoint.name);
    try std.testing.expectEqual(@as(u32, 0o600), (AccessPolicy{}).endpoint_mode);
}
