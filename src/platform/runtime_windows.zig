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
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    string_security_descriptor: windows.LPCWSTR,
    string_sd_revision: windows.DWORD,
    security_descriptor: *?*anyopaque,
    security_descriptor_size: ?*windows.DWORD,
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
extern "kernel32" fn GetTempPathW(
    buffer_length: windows.DWORD,
    buffer: [*]u16,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn CreateDirectoryW(
    path_name: windows.LPCWSTR,
    security_attributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) c_int;
extern "advapi32" fn SetFileSecurityW(
    file_name: windows.LPCWSTR,
    security_information: windows.DWORD,
    security_descriptor: *anyopaque,
) callconv(.winapi) c_int;
extern "advapi32" fn GetNamedSecurityInfoW(
    object_name: windows.LPCWSTR,
    object_type: windows.DWORD,
    security_information: windows.DWORD,
    owner: ?*?*anyopaque,
    group: ?*?*anyopaque,
    dacl: ?*?*anyopaque,
    sacl: ?*?*anyopaque,
    security_descriptor: ?*?*anyopaque,
) callconv(.winapi) windows.DWORD;
extern "advapi32" fn GetSecurityDescriptorOwner(
    security_descriptor: *anyopaque,
    owner: *?*anyopaque,
    owner_defaulted: *c_int,
) callconv(.winapi) c_int;
extern "advapi32" fn GetSecurityDescriptorDacl(
    security_descriptor: *anyopaque,
    dacl_present: *c_int,
    dacl: *?*anyopaque,
    dacl_defaulted: *c_int,
) callconv(.winapi) c_int;
extern "advapi32" fn GetSecurityDescriptorControl(
    security_descriptor: *anyopaque,
    control: *windows.WORD,
    revision: *windows.DWORD,
) callconv(.winapi) c_int;
extern "advapi32" fn GetAclInformation(
    acl: *anyopaque,
    information: *AclSizeInformation,
    information_length: windows.DWORD,
    information_class: windows.DWORD,
) callconv(.winapi) c_int;
extern "advapi32" fn GetAce(
    acl: *anyopaque,
    ace_index: windows.DWORD,
    ace: *?*anyopaque,
) callconv(.winapi) c_int;

pub const Error = runtime.PathError || error{
    AccessDenied,
    InvalidRecord,
    Unexpected,
} || std.mem.Allocator.Error;

const lease_allocator = std.heap.page_allocator;

const token_query: windows.DWORD = 0x0008;
const token_user_information: windows.DWORD = 1;
const process_query_limited_information: windows.DWORD = 0x1000;
const security_descriptor_revision: windows.DWORD = 1;
const se_file_object: windows.DWORD = 1;
const owner_security_information: windows.DWORD = 0x0000_0001;
const dacl_security_information: windows.DWORD = 0x0000_0004;
const protected_dacl_security_information: windows.DWORD = 0x8000_0000;
const security_descriptor_dacl_protected: windows.WORD = 0x1000;
const acl_information_basic: windows.DWORD = 2;
const access_allowed_ace_type: u8 = 0;
const file_all_access: windows.DWORD = 0x001f_01ff;
const system_sid = "S-1-5-18";
/// Rendezvous records store the UTF-8 spelling of a pipe name. A valid
/// endpoint is limited by UTF-16 units, and U+0800 is the worst-case BMP
/// encoding (three bytes per unit). Keep enough room to distinguish a full
/// record from a truncated one.
pub const max_rendezvous_record_bytes: usize = max_pipe_name_utf16 * 3;

const AclSizeInformation = extern struct {
    ace_count: windows.DWORD,
    acl_bytes_in_use: windows.DWORD,
    acl_bytes_free: windows.DWORD,
};

const AceHeader = extern struct {
    ace_type: u8,
    ace_flags: u8,
    ace_size: windows.WORD,
};

const AccessAllowedAce = extern struct {
    header: AceHeader,
    mask: windows.DWORD,
    sid_start: windows.DWORD,
};

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

fn utf16Path(alloc: std.mem.Allocator, path: []const u8) Error![:0]u16 {
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidRecord;
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidRecord,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn filesystemSddl(alloc: std.mem.Allocator) Error![:0]u16 {
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const sddl = std.fmt.allocPrint(
        alloc,
        "O:{s}G:SYD:P(A;;FA;;;{s})(A;;FA;;;SY)",
        .{ sid, sid },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(sddl);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl) catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidRecord,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn applyFilesystemSecurity(
    alloc: std.mem.Allocator,
    path: []const u8,
) Error!void {
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);
    const sddl_w = try filesystemSddl(alloc);
    defer alloc.free(sddl_w);

    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        security_descriptor_revision,
        &descriptor,
        null,
    ) == 0) {
        return error.AccessDenied;
    }
    defer _ = LocalFree(descriptor);

    if (SetFileSecurityW(
        path_w.ptr,
        owner_security_information |
            dacl_security_information |
            protected_dacl_security_information,
        descriptor.?,
    ) == 0) {
        return error.AccessDenied;
    }
}

fn sidStringFromPointer(alloc: std.mem.Allocator, sid: *anyopaque) Error![]u8 {
    var sid_string: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(sid, &sid_string) == 0) return error.AccessDenied;
    defer _ = LocalFree(sid_string);
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(sid_string.?)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AccessDenied,
    };
}

fn verifyFilesystemSecurity(
    alloc: std.mem.Allocator,
    path: []const u8,
) Error!void {
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);

    var owner: ?*anyopaque = null;
    var dacl: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    const result = GetNamedSecurityInfoW(
        path_w.ptr,
        se_file_object,
        owner_security_information | dacl_security_information,
        &owner,
        null,
        &dacl,
        null,
        &descriptor,
    );
    if (result != 0 or descriptor == null or owner == null or dacl == null) {
        return error.AccessDenied;
    }
    defer _ = LocalFree(descriptor);

    const current_sid = try currentUserSid(alloc);
    defer alloc.free(current_sid);
    const owner_sid = try sidStringFromPointer(alloc, owner.?);
    defer alloc.free(owner_sid);
    if (!std.mem.eql(u8, owner_sid, current_sid)) return error.AccessDenied;

    var control: windows.WORD = 0;
    var revision: windows.DWORD = 0;
    if (GetSecurityDescriptorControl(descriptor.?, &control, &revision) == 0 or
        (control & security_descriptor_dacl_protected) == 0)
    {
        return error.AccessDenied;
    }

    var dacl_present: c_int = 0;
    var dacl_defaulted: c_int = 0;
    var verified_dacl: ?*anyopaque = null;
    if (GetSecurityDescriptorDacl(
        descriptor.?,
        &dacl_present,
        &verified_dacl,
        &dacl_defaulted,
    ) == 0 or dacl_present == 0 or verified_dacl == null) {
        return error.AccessDenied;
    }

    var acl_info: AclSizeInformation = undefined;
    if (GetAclInformation(
        verified_dacl.?,
        &acl_info,
        @sizeOf(AclSizeInformation),
        acl_information_basic,
    ) == 0 or acl_info.ace_count != 2) {
        return error.AccessDenied;
    }

    var saw_user = false;
    var saw_system = false;
    var index: windows.DWORD = 0;
    while (index < acl_info.ace_count) : (index += 1) {
        var ace: ?*anyopaque = null;
        if (GetAce(verified_dacl.?, index, &ace) == 0 or ace == null) {
            return error.AccessDenied;
        }
        const allowed: *const AccessAllowedAce = @ptrCast(@alignCast(ace.?));
        if (allowed.header.ace_type != access_allowed_ace_type or
            allowed.header.ace_flags != 0 or
            allowed.mask != file_all_access)
        {
            return error.AccessDenied;
        }
        const ace_sid: *anyopaque = @ptrCast(@constCast(&allowed.sid_start));
        const ace_sid_string = try sidStringFromPointer(alloc, ace_sid);
        defer alloc.free(ace_sid_string);
        if (std.mem.eql(u8, ace_sid_string, current_sid)) {
            if (saw_user) return error.AccessDenied;
            saw_user = true;
        } else if (std.mem.eql(u8, ace_sid_string, system_sid)) {
            if (saw_system) return error.AccessDenied;
            saw_system = true;
        } else {
            return error.AccessDenied;
        }
    }
    if (!saw_user or !saw_system) return error.AccessDenied;
}

fn ensureSecureDirectory(
    alloc: std.mem.Allocator,
    path: []const u8,
) Error!void {
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);
    const sddl_w = try filesystemSddl(alloc);
    defer alloc.free(sddl_w);

    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        security_descriptor_revision,
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
    if (CreateDirectoryW(path_w.ptr, &attributes) == 0) {
        if (windows.GetLastError() != .ALREADY_EXISTS) return error.AccessDenied;
    }
    return verifyFilesystemSecurity(alloc, path);
}

fn secureCreatedFile(
    alloc: std.mem.Allocator,
    path: []const u8,
) Error!void {
    try applyFilesystemSecurity(alloc, path);
    try verifyFilesystemSecurity(alloc, path);
}

pub fn ensureSecureDirectoryPath(
    io: std.Io,
    path: []const u8,
) Error!void {
    _ = io;
    const parent = std.fs.path.dirname(path) orelse return error.AccessDenied;
    try ensureSecureDirectory(lease_allocator, parent);
    try ensureSecureDirectory(lease_allocator, path);
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
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}\\zmx\\logs", .{base});
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

fn hexDecode(alloc: std.mem.Allocator, text: []const u8) Error![]u8 {
    if (text.len == 0 or text.len % 2 != 0) return error.InvalidRecord;
    const result = try alloc.alloc(u8, text.len / 2);
    errdefer alloc.free(result);
    for (0..result.len) |index| {
        const high = std.fmt.charToDigit(text[index * 2], 16) catch return error.InvalidRecord;
        const low = std.fmt.charToDigit(text[index * 2 + 1], 16) catch return error.InvalidRecord;
        result[index] = (@as(u8, high) << 4) | @as(u8, low);
    }
    return result;
}

fn filesystemBase(alloc: std.mem.Allocator) Error![]u8 {
    inline for (.{ "LOCALAPPDATA", "USERPROFILE", "TEMP", "TMP" }) |name| {
        if ((std.process.Environ{ .block = .global }).getAlloc(alloc, name)) |base| {
            if (base.len > 0 and !std.mem.startsWith(u8, base, "\\\\.\\pipe\\")) return base;
            alloc.free(base);
        } else |_| {}
    }

    var utf16: [32768]u16 = undefined;
    const length = GetTempPathW(@intCast(utf16.len), &utf16);
    if (length == 0 or length >= utf16.len) return error.AccessDenied;
    const base = std.unicode.utf16LeToUtf8Alloc(alloc, utf16[0..length]) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unexpected,
        };
    if (std.mem.startsWith(u8, base, "\\\\.\\pipe\\")) {
        alloc.free(base);
        return error.AccessDenied;
    }
    return base;
}

fn rendezvousBase(alloc: std.mem.Allocator) Error![]u8 {
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}\\zmx\\ipc", .{base}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
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

fn ensureRendezvousDirectory(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error!void {
    _ = io;
    try validateSessionName(session_name);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const root = try filesystemBase(alloc);
    defer alloc.free(root);
    const base = try rendezvousBase(alloc);
    defer alloc.free(base);
    const zmx_dir = try std.fmt.allocPrint(alloc, "{s}\\zmx", .{root});
    defer alloc.free(zmx_dir);
    const user_dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, sid });
    defer alloc.free(user_dir);

    try ensureSecureDirectory(alloc, zmx_dir);
    try ensureSecureDirectory(alloc, base);
    try ensureSecureDirectory(alloc, user_dir);
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

fn rendezvousLeasePath(alloc: std.mem.Allocator, session_name: []const u8) Error![]u8 {
    const record_path = try rendezvousRecordPath(alloc, session_name);
    defer alloc.free(record_path);
    return std.fmt.allocPrint(alloc, "{s}.lease", .{record_path});
}

pub const SessionLease = struct {
    file: std.Io.File,
    path: []u8,
    io: std.Io,

    pub fn release(self: *SessionLease) void {
        self.file.close(self.io);
        std.Io.Dir.deleteFileAbsolute(self.io, self.path) catch {};
        lease_allocator.free(self.path);
        lease_allocator.destroy(self);
    }
};

/// Acquire a cross-process, per-session lease. The lock is held for the
/// lifetime of the server, while the file itself is reusable after a crashed
/// owner because Windows releases the lock when its handle disappears.
pub fn acquireSessionLease(
    io: std.Io,
    session_name: []const u8,
) Error!*SessionLease {
    try validateSessionName(session_name);
    const path = try rendezvousLeasePath(lease_allocator, session_name);
    errdefer lease_allocator.free(path);
    ensureRendezvousDirectory(io, lease_allocator, session_name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AccessDenied,
    };

    var created = true;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .default_file,
    }) catch |create_err| switch (create_err) {
        error.PathAlreadyExists => blk: {
            created = false;
            break :blk std.Io.Dir.openFileAbsolute(io, path, .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |open_err| switch (open_err) {
                error.WouldBlock => return error.AccessDenied,
                else => return error.AccessDenied,
            };
        },
        else => return error.AccessDenied,
    };
    if (created) {
        secureCreatedFile(lease_allocator, path) catch |err| {
            file.close(io);
            std.Io.Dir.deleteFileAbsolute(io, path) catch {};
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.AccessDenied,
            };
        };
    } else {
        verifyFilesystemSecurity(lease_allocator, path) catch |err| {
            file.close(io);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.AccessDenied,
            };
        };
    }

    const lease = lease_allocator.create(SessionLease) catch {
        file.close(io);
        return error.OutOfMemory;
    };
    lease.* = .{
        .file = file,
        .path = path,
        .io = io,
    };
    return lease;
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
    try ensureRendezvousDirectory(io, alloc, session_name);
    var record = std.Io.Dir.createFileAbsolute(io, record_path, .{
        .read = true,
        .exclusive = true,
        .permissions = .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AccessDenied,
        else => return error.AccessDenied,
    };
    defer record.close(io);
    secureCreatedFile(alloc, record_path) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, record_path) catch {};
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AccessDenied,
        };
    };
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
    try ensureRendezvousDirectory(io, alloc, session_name);
    const record_path = try rendezvousRecordPath(alloc, session_name);
    defer alloc.free(record_path);
    var record = std.Io.Dir.openFileAbsolute(io, record_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.AccessDenied,
    };
    record.close(io);
    try verifyFilesystemSecurity(alloc, record_path);
    return true;
}

/// Enumerate owner-published session names without requiring a session
/// argument. Files are only accepted from the SID-scoped, ACL-verified
/// rendezvous directory and are decoded from their hex filenames.
pub fn listSessionNames(
    io: std.Io,
    alloc: std.mem.Allocator,
) Error!std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |name| alloc.free(name);
        result.deinit(alloc);
    }

    try ensureRendezvousDirectory(io, alloc, "list");
    const directory = try rendezvousDirectory(alloc, "list");
    defer alloc.free(directory);
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return error.AccessDenied,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        error.SystemResources, error.Canceled => return error.Unexpected,
        else => return error.Unexpected,
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".endpoint")) continue;
        const encoded = entry.name[0 .. entry.name.len - ".endpoint".len];
        const name = hexDecode(alloc, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        validateSessionName(name) catch {
            alloc.free(name);
            continue;
        };
        result.append(alloc, name) catch |err| {
            alloc.free(name);
            return err;
        };
    }
    return result;
}

/// Resolve the current owner-published endpoint. A missing record falls back
/// to the deterministic SID-scoped name for compatibility with older
/// daemons. Once a record exists, malformed or truncated contents are an
/// error rather than a silent fallback.
pub fn resolveEndpointPath(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    try ensureRendezvousDirectory(io, alloc, session_name);
    const record_path = rendezvousRecordPath(alloc, session_name) catch return endpointPath(alloc, session_name);
    defer alloc.free(record_path);
    var record = std.Io.Dir.openFileAbsolute(io, record_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return endpointPath(alloc, session_name),
        else => return endpointPath(alloc, session_name),
    };
    defer record.close(io);
    verifyFilesystemSecurity(alloc, record_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AccessDenied,
    };

    const stat = record.stat(io) catch return error.InvalidRecord;
    if (stat.size == 0 or stat.size > max_rendezvous_record_bytes) {
        return error.InvalidRecord;
    }
    var bytes: [max_rendezvous_record_bytes]u8 = undefined;
    const len = record.readPositionalAll(io, &bytes, 0) catch return error.InvalidRecord;
    if (len != stat.size) return error.InvalidRecord;
    const endpoint = std.mem.trim(u8, bytes[0..len], " \t\r\n");
    if (!std.mem.startsWith(u8, endpoint, pipe_prefix) or
        !std.unicode.utf8ValidateSlice(endpoint))
    {
        return error.InvalidRecord;
    }
    const endpoint_w = utf16Path(alloc, endpoint) catch return error.InvalidRecord;
    defer alloc.free(endpoint_w);
    if (endpoint_w.len >= max_pipe_name_utf16) return error.InvalidRecord;
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

test "Windows rendezvous records preserve sixty U+0800 endpoint characters" {
    const alloc = std.testing.allocator;
    const session_name = "rendezvous-utf8-record";
    defer cleanupRendezvous(std.testing.io, alloc, session_name);

    var endpoint: std.ArrayList(u8) = .empty;
    defer endpoint.deinit(alloc);
    try endpoint.appendSlice(alloc, "\\\\.\\pipe\\zmx\\");
    var index: usize = 0;
    while (index < 60) : (index += 1) {
        try endpoint.appendSlice(alloc, "\u{0800}");
    }
    try publishEndpoint(std.testing.io, alloc, session_name, endpoint.items);
    const resolved = try resolveEndpointPath(std.testing.io, alloc, session_name);
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings(endpoint.items, resolved);
}

test "Windows rendezvous rejects oversized endpoint records" {
    const alloc = std.testing.allocator;
    const session_name = "rendezvous-truncated-record";
    defer cleanupRendezvous(std.testing.io, alloc, session_name);

    var endpoint: std.ArrayList(u8) = .empty;
    defer endpoint.deinit(alloc);
    try endpoint.appendSlice(alloc, pipe_prefix);
    try endpoint.appendNTimes(alloc, 'x', max_rendezvous_record_bytes);
    try publishEndpoint(std.testing.io, alloc, session_name, endpoint.items);
    try std.testing.expectError(
        error.InvalidRecord,
        resolveEndpointPath(std.testing.io, alloc, session_name),
    );
}

test "Windows fallback log paths are filesystem paths" {
    const alloc = std.testing.allocator;
    const path = try logDir(alloc);
    defer alloc.free(path);
    try std.testing.expect(!std.mem.startsWith(u8, path, pipe_prefix));
    try std.testing.expect(std.mem.indexOf(u8, path, "\\logs") != null);
}

test "Windows session lease excludes a second owner" {
    const first = try acquireSessionLease(std.testing.io, "lease-exclusion");
    defer first.release();
    try std.testing.expectError(
        error.AccessDenied,
        acquireSessionLease(std.testing.io, "lease-exclusion"),
    );
}

test "Windows runtime rejects insecure preexisting filesystem objects" {
    const alloc = std.testing.allocator;
    const root = try filesystemBase(alloc);
    defer alloc.free(root);
    const path = try std.fmt.allocPrint(alloc, "{s}\\zmx-insecure-acl-check", .{root});
    defer alloc.free(path);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, path) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, path, .default_dir);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, path) catch {};
    try std.testing.expectError(error.AccessDenied, ensureSecureDirectory(alloc, path));
}
