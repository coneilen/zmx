const std = @import("std");

pub const SecurityPolicy = struct {
    directory_mode: u32 = 0o750,
    log_mode: u32 = 0o640,
    endpoint_mode: u32 = 0o600,
};

pub const Paths = struct {
    socket_dir: []const u8,
    log_dir: []const u8,
    security: SecurityPolicy = .{},
};

pub const Provider = struct {
    context: *anyopaque,
    paths_fn: *const fn (*anyopaque) anyerror!Paths,

    pub fn paths(self: Provider) !Paths {
        return self.paths_fn(self.context);
    }
};

pub const PathError = error{
    InvalidSessionName,
    NameTooLong,
};

/// Strict session-name validation for endpoint implementations whose naming
/// rules treat both slash styles as separators, including Windows named pipes.
/// POSIX Unix-socket callers use `runtime_posix.validateSessionName` so legacy
/// backslash-containing session names remain compatible.
pub fn validateSessionName(name: []const u8) PathError!void {
    if (name.len == 0 or
        std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOfScalar(u8, name, '\\') != null or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return error.InvalidSessionName;
    }
}

pub fn joinEndpointPath(
    alloc: std.mem.Allocator,
    directory: []const u8,
    session_name: []const u8,
    max_len: usize,
) (PathError || std.mem.Allocator.Error)![]const u8 {
    try validateSessionName(session_name);
    return joinEndpointPathUnchecked(alloc, directory, session_name, max_len);
}

pub fn joinEndpointPathUnchecked(
    alloc: std.mem.Allocator,
    directory: []const u8,
    session_name: []const u8,
    max_len: usize,
) (error{NameTooLong} || std.mem.Allocator.Error)![]const u8 {
    if (directory.len + 1 + session_name.len > max_len) return error.NameTooLong;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ directory, session_name });
}

pub fn maxSessionNameLen(directory: []const u8, max_len: usize) ?usize {
    if (directory.len + 1 >= max_len) return null;
    return max_len - directory.len - 1;
}

test "runtime path policy rejects traversal and both separator styles" {
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("../escape"));
    try std.testing.expectError(error.InvalidSessionName, validateSessionName(".."));
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("a\\b"));
    try validateSessionName("session-1");
}

test "runtime endpoint joining enforces the adapter supplied limit" {
    const alloc = std.testing.allocator;
    const path = try joinEndpointPath(alloc, "/run/zmx", "dev", 64);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/run/zmx/dev", path);
    try std.testing.expectError(
        error.NameTooLong,
        joinEndpointPath(alloc, "/run/zmx", "dev", 10),
    );
}
