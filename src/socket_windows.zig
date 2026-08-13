const std = @import("std");
const local_ipc = @import("platform/local_ipc.zig");
const local_ipc_windows = @import("platform/local_ipc_windows.zig");
const runtime_windows = @import("platform/runtime_windows.zig");

pub const Handle = local_ipc.Handle;
pub const Server = local_ipc.Server;
pub const Connection = local_ipc.Connection;

pub fn getSeshPrefix() []const u8 {
    return "";
}

pub fn getSeshNameFromEnv() []const u8 {
    return "";
}

pub fn getSeshName(alloc: std.mem.Allocator, sesh: []const u8) ![]const u8 {
    if (sesh.len == 0) return error.SessionNameRequired;
    try runtime_windows.validateSessionName(sesh);
    return alloc.dupe(u8, sesh);
}

pub fn resolveSessionOrEnv(
    alloc: std.mem.Allocator,
    _: std.Io,
    session_name: ?[]const u8,
) ![]const u8 {
    const name = session_name orelse getSeshNameFromEnv();
    return getSeshName(alloc, name);
}

pub const SessionMatch = struct {
    name: []const u8,
    is_prefix: bool,

    pub fn matches(self: SessionMatch, session_name: []const u8) bool {
        if (self.is_prefix) return std.mem.startsWith(u8, session_name, self.name);
        return std.mem.eql(u8, session_name, self.name);
    }
};

pub fn parseSessionArg(alloc: std.mem.Allocator, raw: []const u8) !SessionMatch {
    if (raw.len > 0 and raw[raw.len - 1] == '*') {
        return .{ .name = try getSeshName(alloc, raw[0 .. raw.len - 1]), .is_prefix = true };
    }
    return .{ .name = try getSeshName(alloc, raw), .is_prefix = false };
}

pub fn sessionConnect(endpoint: []const u8) !Handle {
    const connection = try local_ipc_windows.connect(
        std.heap.c_allocator,
        .{ .name = endpoint },
    );
    return connection.handle;
}

pub fn createSocket(endpoint: []const u8) !Server {
    return local_ipc_windows.listen(
        std.heap.c_allocator,
        .{ .name = endpoint },
        .{},
    );
}

pub fn cleanupStaleSocket(_: []const u8) void {}

pub fn sessionExists(_: std.Io, _: std.Io.Dir, _: []const u8) !bool {
    return false;
}

pub fn getSocketPath(
    alloc: std.mem.Allocator,
    _: []const u8,
    session_name: []const u8,
) ![]const u8 {
    return runtime_windows.endpointPath(alloc, session_name);
}

pub fn printSessionNameTooLong(
    io: std.Io,
    session_name: []const u8,
    socket_dir: []const u8,
) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    writer.interface.print(
        "error: Windows pipe session name is too long: {s} (namespace {s})\n",
        .{ session_name, socket_dir },
    ) catch {};
    writer.interface.flush() catch {};
}

pub fn maxSessionNameLen(_: []const u8) ?usize {
    return runtime_windows.max_pipe_name_utf16 - runtime_windows.pipe_prefix.len - 2;
}
