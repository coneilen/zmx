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
    read_fn: ?*const fn (Handle, []u8) anyerror!usize = null,
    write_fn: ?*const fn (Handle, []const u8) anyerror!usize = null,

    pub fn close(self: Connection) void {
        self.close_fn(self.handle);
    }

    /// Read bytes from the transport. The optional function pointers keep the
    /// frozen connection shape usable by adapters that only expose handles,
    /// while native transports can provide cancellation-aware I/O.
    pub fn read(self: Connection, buffer: []u8) !usize {
        const read_fn = self.read_fn orelse return error.Unsupported;
        return read_fn(self.handle, buffer);
    }

    pub fn write(self: Connection, bytes: []const u8) !usize {
        const write_fn = self.write_fn orelse return error.Unsupported;
        return write_fn(self.handle, bytes);
    }

    pub fn writeAll(self: Connection, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = try self.write(bytes[offset..]);
            if (amount == 0) return error.BrokenPipe;
            offset += amount;
        }
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
    /// Windows adapters translate this to an owner-only DACL. POSIX adapters
    /// apply the mode fields to the runtime directory/socket.
    directory_mode: u32 = 0o750,
    endpoint_mode: u32 = 0o600,
    owner_only: bool = true,
};

test "local IPC contract keeps framing out of transport" {
    const endpoint = Endpoint{ .name = "session" };
    try std.testing.expectEqualStrings("session", endpoint.name);
    try std.testing.expectEqual(@as(u32, 0o600), (AccessPolicy{}).endpoint_mode);
}

const BackpressureProbe = struct {
    total: usize = 0,
    checksum: u64 = 0,
};

fn probeWrite(handle: Handle, bytes: []const u8) anyerror!usize {
    const probe: *BackpressureProbe = @ptrFromInt(handle);
    const amount = @min(bytes.len, 64 * 1024);
    for (bytes[0..amount]) |byte| probe.checksum +%= byte;
    probe.total += amount;
    return amount;
}

fn probeClose(_: Handle) void {}

test "transport writeAll streams large payloads through bounded writes" {
    var probe = BackpressureProbe{};
    const connection = Connection{
        .handle = @intFromPtr(&probe),
        .close_fn = probeClose,
        .write_fn = probeWrite,
    };
    const payload = try std.testing.allocator.alloc(u8, 64 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    try connection.writeAll(payload);
    try std.testing.expectEqual(payload.len, probe.total);
    try std.testing.expectEqual(@as(u64, 0x5a) * payload.len, probe.checksum);
}
