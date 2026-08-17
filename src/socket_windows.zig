const std = @import("std");
const local_ipc = @import("platform/local_ipc.zig");
const local_ipc_windows = @import("platform/local_ipc_windows.zig");
const runtime_windows = @import("platform/runtime_windows.zig");

pub const Handle = local_ipc.Handle;
pub const Server = local_ipc.Server;
pub const Connection = local_ipc.Connection;

threadlocal var prefix_buffer: [4096]u8 = undefined;
threadlocal var session_buffer: [4096]u8 = undefined;

pub fn getSeshPrefix() []const u8 {
    const key = comptime std.unicode.wtf8ToWtf16LeStringLiteral("ZMX_SESSION_PREFIX");
    const value = (std.process.Environ{ .block = .global }).getWindows(key) orelse return "";
    const len = std.unicode.utf16LeToUtf8(&prefix_buffer, value) catch return "";
    return prefix_buffer[0..len];
}

pub fn getSeshPrefixAlloc(alloc: std.mem.Allocator) ![]u8 {
    return (std.process.Environ{ .block = .global }).getAlloc(
        alloc,
        "ZMX_SESSION_PREFIX",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => alloc.dupe(u8, ""),
        else => return err,
    };
}

pub fn getSeshNameFromEnv() []const u8 {
    const key = comptime std.unicode.wtf8ToWtf16LeStringLiteral("ZMX_SESSION");
    const value = (std.process.Environ{ .block = .global }).getWindows(key) orelse return "";
    const len = std.unicode.utf16LeToUtf8(&session_buffer, value) catch return "";
    return session_buffer[0..len];
}

pub fn getSeshNameFromEnvAlloc(alloc: std.mem.Allocator) !?[]u8 {
    const value = (std.process.Environ{ .block = .global }).getAlloc(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    if (value.len == 0) {
        alloc.free(value);
        return null;
    }
    return value;
}

pub fn getSeshName(alloc: std.mem.Allocator, sesh: []const u8) ![]const u8 {
    const prefix = try getSeshPrefixAlloc(alloc);
    defer alloc.free(prefix);
    if (sesh.len == 0 and prefix.len == 0) return error.SessionNameRequired;
    const full = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, sesh });
    errdefer alloc.free(full);
    try runtime_windows.validateSessionName(full);
    return full;
}

pub fn resolveSessionOrEnv(
    alloc: std.mem.Allocator,
    io: std.Io,
    session_name: ?[]const u8,
) ![]const u8 {
    const env_name = try getSeshNameFromEnvAlloc(alloc);
    defer if (env_name) |name| alloc.free(name);
    if (session_name == null or std.mem.eql(u8, session_name.?, ".")) {
        if (env_name) |current| {
            try runtime_windows.validateSessionName(current);
            return alloc.dupe(u8, current);
        }
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.print(
            "error: \".\" requires ZMX_SESSION (are you inside a zmx session?)\n",
            .{},
        ) catch {};
        writer.interface.flush() catch {};
        return error.SessionNameRequired;
    }
    return getSeshName(alloc, session_name.?);
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

pub fn createSessionSocket(io: std.Io, alloc: std.mem.Allocator, session_name: []const u8) !Server {
    return local_ipc_windows.listenSession(io, alloc, session_name, .{});
}

pub fn cleanupStaleSocket(_: []const u8) void {}

pub fn cleanupStaleSocketWithIo(io: std.Io, alloc: std.mem.Allocator, session_name: []const u8) void {
    runtime_windows.cleanupRendezvous(io, alloc, session_name);
}

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

/// Resolve the owner-published nonce endpoint when a newer daemon has
/// recovered from a pre-created deterministic pipe. The io-aware form is
/// additive so the existing frozen path API remains usable by old callers.
pub fn getSocketPathWithIo(
    io: std.Io,
    alloc: std.mem.Allocator,
    _: []const u8,
    session_name: []const u8,
) ![]const u8 {
    return runtime_windows.resolveEndpointPath(io, alloc, session_name);
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

pub fn maxSessionNameLen(socket_dir: []const u8) ?usize {
    return runtime_windows.maxSessionNameLen(
        socket_dir,
        runtime_windows.max_pipe_name_utf16,
    );
}
