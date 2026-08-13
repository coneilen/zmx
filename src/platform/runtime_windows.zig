const builtin = @import("builtin");
const std = @import("std");
const runtime = @import("runtime.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("runtime_windows requires a Windows target");
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;

extern "advapi32" fn GetUserNameW(
    buffer: [*]u16,
    size: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

const Error = runtime.PathError || error{
    AccessDenied,
    Unexpected,
} || std.mem.Allocator.Error;

/// Named pipes are not filesystem objects.  The namespace is nevertheless
/// scoped by the current Windows account and every server pipe is created with
/// an owner-only DACL (see `securityDescriptorSddl`).
pub const pipe_prefix = "\\\\.\\pipe\\zmx";
pub const max_pipe_name_utf16: usize = 256;
pub const securityDescriptorSddl = "D:P(A;;GA;;;OW)(A;;GA;;;SY)";

pub fn validateSessionName(name: []const u8) runtime.PathError!void {
    if (name.len == 0 or
        !std.unicode.utf8ValidateSlice(name) or
        std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOfScalar(u8, name, '\\') != null or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return error.InvalidSessionName;
    }
}

fn username(alloc: std.mem.Allocator) Error![]u8 {
    var utf16: [256]u16 = undefined;
    var len: windows.DWORD = utf16.len;
    if (GetUserNameW(&utf16, &len) == windows.FALSE) {
        return error.Unexpected;
    }
    // GetUserNameW includes the terminating NUL in the returned length.
    const used: usize = if (len > 0) @as(usize, len - 1) else 0;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, utf16[0..used]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    if (utf8.len == 0) {
        alloc.free(utf8);
        return error.Unexpected;
    }
    return utf8;
}

pub fn socketDir(alloc: std.mem.Allocator) Error![]u8 {
    const user = try username(alloc);
    defer alloc.free(user);
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ pipe_prefix, user });
}

pub fn logDir(alloc: std.mem.Allocator) Error![]u8 {
    if (std.process.getEnvVarOwned(alloc, "LOCALAPPDATA")) |base| {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "{s}\\zmx\\logs", .{base});
    } else |_| {
        return std.fmt.allocPrint(alloc, "{s}\\logs", .{pipe_prefix});
    }
}

pub fn endpointPath(
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    try validateSessionName(session_name);
    const dir = try socketDir(alloc);
    defer alloc.free(dir);
    return joinEndpointPath(alloc, dir, session_name, max_pipe_name_utf16);
}

/// Named pipes are kernel objects, not directory entries. Closing the last
/// server/client handle removes the endpoint, so stale-file cleanup is both
/// unnecessary and unsafe on Windows.
pub fn cleanupStaleEndpoint(_: []const u8) void {}

pub fn joinEndpointPath(
    alloc: std.mem.Allocator,
    directory: []const u8,
    session_name: []const u8,
    max_len_utf16: usize,
) Error![]u8 {
    try validateSessionName(session_name);
    if (!std.unicode.utf8ValidateSlice(directory)) return error.InvalidSessionName;
    return joinEndpointPathUnchecked(alloc, directory, session_name, max_len_utf16);
}

pub fn joinEndpointPathUnchecked(
    alloc: std.mem.Allocator,
    directory: []const u8,
    session_name: []const u8,
    max_len_utf16: usize,
) Error![]u8 {
    const result = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ directory, session_name });
    errdefer alloc.free(result);
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, result) catch |err| switch (err) {
        error.InvalidUtf8 => return error.InvalidSessionName,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(utf16);
    if (utf16.len >= max_len_utf16) {
        return error.NameTooLong;
    }
    return result;
}

pub fn maxSessionNameLen(directory: []const u8, max_len_utf16: usize) ?usize {
    if (!std.unicode.utf8ValidateSlice(directory)) return null;
    var units: usize = 0;
    var index: usize = 0;
    while (index < directory.len) {
        const len = std.unicode.utf8ByteSequenceLength(directory[index]) catch return null;
        const codepoint = std.unicode.utf8Decode(directory[index .. index + len]) catch return null;
        units += if (codepoint > 0xffff) 2 else 1;
        index += len;
    }
    if (units + 1 >= max_len_utf16) return null;
    return max_len_utf16 - units - 1;
}

test "Windows runtime rejects both separator styles and invalid UTF-8" {
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("a/b"));
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("a\\b"));
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("\xff"));
    try validateSessionName("session-\u{1F600}");
}

test "Windows runtime counts UTF-16 endpoint units" {
    const alloc = std.testing.allocator;
    const path = try joinEndpointPath(alloc, "\\\\.\\pipe\\zmx-user", "😀", 32);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\zmx-user\\😀", path);
    try std.testing.expectError(
        error.NameTooLong,
        joinEndpointPath(alloc, "\\\\.\\pipe\\zmx-user", "abcdef", 24),
    );
}
