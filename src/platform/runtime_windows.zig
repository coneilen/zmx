const builtin = @import("builtin");
const std = @import("std");
const runtime = @import("runtime.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("runtime_windows requires a Windows target");
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;

fn winBool(comptime T: type, value: bool) T {
    return switch (@typeInfo(T)) {
        .@"enum" => @enumFromInt(@intFromBool(value)),
        else => @intFromBool(value),
    };
}

extern "advapi32" fn OpenProcessToken(
    process: windows.HANDLE,
    desired_access: windows.DWORD,
    token: *windows.HANDLE,
) callconv(.winapi) c_int;
extern "advapi32" fn GetTokenInformation(
    token: windows.HANDLE,
    information_class: windows.DWORD,
    information: ?*anyopaque,
    information_length: windows.DWORD,
    return_length: *windows.DWORD,
) callconv(.winapi) c_int;
extern "advapi32" fn ConvertSidToStringSidW(
    sid: *anyopaque,
    string_sid: *?[*:0]u16,
) callconv(.winapi) c_int;
extern "advapi32" fn SystemFunction036(
    buffer: *anyopaque,
    length: windows.ULONG,
) callconv(.winapi) c_int;
extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetNamedPipeServerProcessId(
    pipe: windows.HANDLE,
    process_id: *windows.DWORD,
) callconv(.winapi) c_int;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const Error = runtime.PathError || error{
    AccessDenied,
    InvalidRecord,
    Unexpected,
} || std.mem.Allocator.Error;

const token_query: windows.DWORD = 0x0008;
const token_user_information: windows.DWORD = 1;
const process_query_limited_information: windows.DWORD = 0x1000;

const SidAndAttributes = extern struct {
    sid: *anyopaque,
    attributes: windows.DWORD,
};

const TokenUser = extern struct {
    user: SidAndAttributes,
};

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

fn sidForToken(alloc: std.mem.Allocator, token: windows.HANDLE) Error![]u8 {
    var needed: windows.DWORD = 0;
    _ = GetTokenInformation(token, token_user_information, null, 0, &needed);
    if (needed == 0) return error.AccessDenied;

    const storage = try alloc.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(@alignOf(TokenUser)),
        needed,
    );
    defer alloc.free(storage);
    if (GetTokenInformation(
        token,
        token_user_information,
        storage.ptr,
        needed,
        &needed,
    ) == 0) {
        return error.AccessDenied;
    }

    const token_user: *const TokenUser = @ptrCast(@alignCast(storage.ptr));
    var sid_string: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(token_user.user.sid, &sid_string) == 0) {
        return error.AccessDenied;
    }
    defer _ = LocalFree(sid_string);

    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(sid_string.?)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unexpected,
    };
}

pub fn currentUserSid(alloc: std.mem.Allocator) Error![]u8 {
    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), token_query, &token) == 0) {
        return error.AccessDenied;
    }
    defer windows.CloseHandle(token);
    return sidForToken(alloc, token);
}

pub fn socketDirForSid(alloc: std.mem.Allocator, sid: []const u8) Error![]u8 {
    if (sid.len == 0 or std.mem.indexOfScalar(u8, sid, '\\') != null) {
        return error.InvalidSessionName;
    }
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ pipe_prefix, sid });
}

pub fn socketDir(alloc: std.mem.Allocator) Error![]u8 {
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    return socketDirForSid(alloc, sid);
}

pub fn logDir(alloc: std.mem.Allocator) Error![]u8 {
    if ((std.process.Environ{ .block = .global }).getAlloc(alloc, "LOCALAPPDATA")) |base| {
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

fn hexEncode(alloc: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const digits = "0123456789abcdef";
    const result = try alloc.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        result[index * 2] = digits[byte >> 4];
        result[index * 2 + 1] = digits[byte & 0x0f];
    }
    return result;
}

fn rendezvousBase(alloc: std.mem.Allocator) Error![]u8 {
    if ((std.process.Environ{ .block = .global }).getAlloc(alloc, "LOCALAPPDATA")) |base| {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "{s}\\zmx\\ipc", .{base}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    } else |_| {}
    if ((std.process.Environ{ .block = .global }).getAlloc(alloc, "TEMP")) |base| {
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "{s}\\zmx-ipc", .{base}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    } else |_| {}
    return alloc.dupe(u8, "C:\\Windows\\Temp\\zmx-ipc");
}

fn rendezvousDirectory(
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    try validateSessionName(session_name);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const base = try rendezvousBase(alloc);
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, sid });
}

fn rendezvousRecordPath(
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    const directory = try rendezvousDirectory(alloc, session_name);
    defer alloc.free(directory);
    const encoded = try hexEncode(alloc, session_name);
    defer alloc.free(encoded);
    return std.fmt.allocPrint(alloc, "{s}\\{s}.endpoint", .{ directory, encoded });
}

fn mkdirAll(io: std.Io, path_name: []const u8) !void {
    var it = std.fs.path.componentIterator(path_name);
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        std.Io.Dir.createDirAbsolute(io, component.path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                component = it.previous() orelse return err;
                continue;
            },
            else => return err,
        };
        component = it.next() orelse return;
    }
}

/// Publish an owner-created rendezvous record. The directory is under the
/// current user's profile and inherits the user's ACL; the record is created
/// exclusively so a pre-created file cannot be silently replaced.
pub fn publishEndpoint(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    endpoint: []const u8,
) Error!void {
    try validateSessionName(session_name);
    const record_path = try rendezvousRecordPath(alloc, session_name);
    defer alloc.free(record_path);
    mkdirAll(io, std.fs.path.dirname(record_path) orelse return error.Unexpected) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.AccessDenied,
    };
    var record = std.Io.Dir.createFileAbsolute(io, record_path, .{
        .read = true,
        .exclusive = true,
        .permissions = .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AccessDenied,
        else => return error.AccessDenied,
    };
    defer record.close(io);
    record.writeStreamingAll(io, endpoint) catch return error.AccessDenied;
}

/// Replace a stale rendezvous record after a server has selected a fresh
/// random pipe name. This is used only after the server successfully owns the
/// new pipe, so a deterministic endpoint collision cannot deny service.
pub fn replaceEndpoint(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    endpoint: []const u8,
) Error!void {
    const record_path = try rendezvousRecordPath(alloc, session_name);
    defer alloc.free(record_path);
    std.Io.Dir.deleteFileAbsolute(io, record_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.AccessDenied,
    };
    return publishEndpoint(io, alloc, session_name, endpoint);
}

pub fn cleanupRendezvous(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) void {
    const record_path = rendezvousRecordPath(alloc, session_name) catch return;
    defer alloc.free(record_path);
    std.Io.Dir.deleteFileAbsolute(io, record_path) catch {};
}

pub fn hasRendezvous(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error!bool {
    const record_path = try rendezvousRecordPath(alloc, session_name);
    defer alloc.free(record_path);
    var record = std.Io.Dir.openFileAbsolute(io, record_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.AccessDenied,
    };
    record.close(io);
    return true;
}

/// Resolve the current owner-published endpoint. A missing or malformed
/// record falls back to the deterministic SID-scoped name for compatibility
/// with older daemons.
pub fn resolveEndpointPath(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    const record_path = rendezvousRecordPath(alloc, session_name) catch return endpointPath(alloc, session_name);
    defer alloc.free(record_path);
    var record = std.Io.Dir.openFileAbsolute(io, record_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return endpointPath(alloc, session_name),
        else => return endpointPath(alloc, session_name),
    };
    defer record.close(io);

    var bytes: [max_pipe_name_utf16]u8 = undefined;
    const len = record.readPositionalAll(io, &bytes, 0) catch return endpointPath(alloc, session_name);
    const endpoint = std.mem.trim(u8, bytes[0..len], " \t\r\n");
    if (!std.mem.startsWith(u8, endpoint, pipe_prefix) or
        !std.unicode.utf8ValidateSlice(endpoint))
    {
        return endpointPath(alloc, session_name);
    }
    return alloc.dupe(u8, endpoint);
}

pub fn nonceEndpointPath(
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    try validateSessionName(session_name);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const directory = try socketDirForSid(alloc, sid);
    defer alloc.free(directory);
    var nonce: [16]u8 = undefined;
    if (SystemFunction036(&nonce, @intCast(nonce.len)) == 0) {
        return error.Unexpected;
    }
    const encoded = try hexEncode(alloc, &nonce);
    defer alloc.free(encoded);
    const nonce_name = try std.fmt.allocPrint(alloc, "{s}-{s}", .{
        session_name,
        encoded,
    });
    defer alloc.free(nonce_name);
    return joinEndpointPath(alloc, directory, nonce_name, max_pipe_name_utf16);
}

pub fn verifyPipeServerIdentity(
    alloc: std.mem.Allocator,
    pipe: windows.HANDLE,
) Error!void {
    var process_id: windows.DWORD = 0;
    if (GetNamedPipeServerProcessId(pipe, &process_id) == 0) {
        return error.AccessDenied;
    }
    const process = OpenProcess(
        process_query_limited_information,
        winBool(windows.BOOL, false),
        process_id,
    ) orelse
        return error.AccessDenied;
    defer windows.CloseHandle(process);

    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(process, token_query, &token) == 0) {
        return error.AccessDenied;
    }
    defer windows.CloseHandle(token);

    const server_sid = try sidForToken(alloc, token);
    defer alloc.free(server_sid);
    const current_sid = try currentUserSid(alloc);
    defer alloc.free(current_sid);
    if (!std.mem.eql(u8, server_sid, current_sid)) return error.AccessDenied;
}

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

test "Windows pipe namespaces distinguish users with the same username" {
    const alloc = std.testing.allocator;
    const first = try socketDirForSid(alloc, "S-1-5-21-100");
    defer alloc.free(first);
    const second = try socketDirForSid(alloc, "S-1-5-21-200");
    defer alloc.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "Windows session endpoints recover with a fresh nonce" {
    const alloc = std.testing.allocator;
    const first = try nonceEndpointPath(alloc, "nonce-recovery");
    defer alloc.free(first);
    const second = try nonceEndpointPath(alloc, "nonce-recovery");
    defer alloc.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, pipe_prefix));
    try std.testing.expect(std.mem.startsWith(u8, second, pipe_prefix));
}
