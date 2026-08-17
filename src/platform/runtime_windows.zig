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
extern "kernel32" fn CreateSymbolicLinkW(
    symlink_file_name: windows.LPCWSTR,
    target_file_name: windows.LPCWSTR,
    flags: windows.DWORD,
) callconv(.winapi) c_int;
extern "kernel32" fn GetFileAttributesW(
    file_name: windows.LPCWSTR,
) callconv(.winapi) windows.DWORD;
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
extern "advapi32" fn GetSecurityInfo(
    object: windows.HANDLE,
    object_type: windows.DWORD,
    security_information: windows.DWORD,
    owner: ?*?*anyopaque,
    group: ?*?*anyopaque,
    dacl: ?*?*anyopaque,
    sacl: ?*?*anyopaque,
    security_descriptor: ?*?*anyopaque,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn CreateFileW(
    file_name: windows.LPCWSTR,
    desired_access: windows.DWORD,
    share_mode: windows.DWORD,
    security_attributes: ?*windows.SECURITY_ATTRIBUTES,
    creation_disposition: windows.DWORD,
    flags_and_attributes: windows.DWORD,
    template_file: ?windows.HANDLE,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetFileInformationByHandle(
    file: windows.HANDLE,
    information: *ByHandleFileInformation,
) callconv(.winapi) c_int;
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
const invalid_file_attributes: windows.DWORD = 0xffff_ffff;
const file_attribute_reparse_point: windows.DWORD = 0x0000_0400;
const generic_read: windows.DWORD = 0x8000_0000;
const file_share_read: windows.DWORD = 0x0000_0001;
const file_share_write: windows.DWORD = 0x0000_0002;
const open_existing: windows.DWORD = 3;
const file_flag_backup_semantics: windows.DWORD = 0x0200_0000;
const file_flag_open_reparse_point: windows.DWORD = 0x0020_0000;
const file_object_type: windows.DWORD = 1;
const symbolic_link_flag_directory: windows.DWORD = 0x0000_0001;
const symbolic_link_flag_allow_unprivileged_create: windows.DWORD = 0x0000_0002;
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

const ByHandleFileInformation = extern struct {
    file_attributes: windows.DWORD,
    creation_time_low: windows.DWORD,
    creation_time_high: windows.DWORD,
    last_access_time_low: windows.DWORD,
    last_access_time_high: windows.DWORD,
    last_write_time_low: windows.DWORD,
    last_write_time_high: windows.DWORD,
    volume_serial_number: windows.DWORD,
    file_size_high: windows.DWORD,
    file_size_low: windows.DWORD,
    number_of_links: windows.DWORD,
    file_index_high: windows.DWORD,
    file_index_low: windows.DWORD,
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

fn rejectReparsePoint(alloc: std.mem.Allocator, path: []const u8) Error!void {
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);
    const attributes = GetFileAttributesW(path_w.ptr);
    if (attributes == invalid_file_attributes) return error.AccessDenied;
    if ((attributes & file_attribute_reparse_point) != 0) return error.AccessDenied;
}

const RootIdentity = struct {
    volume_serial_number: windows.DWORD,
    file_index_high: windows.DWORD,
    file_index_low: windows.DWORD,
};

const RootGuard = struct {
    handle: windows.HANDLE,
    identity: RootIdentity,
    path: []u8,
    allocator: std.mem.Allocator,

    fn close(self: *RootGuard) void {
        windows.CloseHandle(self.handle);
        self.allocator.free(self.path);
    }
};

fn rootIdentityFromHandle(
    alloc: std.mem.Allocator,
    handle: windows.HANDLE,
) Error!RootIdentity {
    var information: ByHandleFileInformation = undefined;
    if (GetFileInformationByHandle(handle, &information) == 0 or
        (information.file_attributes & file_attribute_reparse_point) != 0)
    {
        return error.AccessDenied;
    }

    var owner: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    if (GetSecurityInfo(
        handle,
        file_object_type,
        owner_security_information,
        &owner,
        null,
        null,
        null,
        &descriptor,
    ) != 0 or owner == null or descriptor == null) {
        return error.AccessDenied;
    }
    defer _ = LocalFree(descriptor);
    const owner_sid = try sidStringFromPointer(alloc, owner.?);
    defer alloc.free(owner_sid);
    const current_sid = try currentUserSid(alloc);
    defer alloc.free(current_sid);
    if (!std.mem.eql(u8, owner_sid, current_sid)) return error.AccessDenied;

    return .{
        .volume_serial_number = information.volume_serial_number,
        .file_index_high = information.file_index_high,
        .file_index_low = information.file_index_low,
    };
}

fn openRootGuard(alloc: std.mem.Allocator, path: []const u8) Error!RootGuard {
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);
    const handle = CreateFileW(
        path_w.ptr,
        generic_read,
        file_share_read | file_share_write,
        null,
        open_existing,
        file_flag_backup_semantics | file_flag_open_reparse_point,
        null,
    ) orelse return error.AccessDenied;
    errdefer windows.CloseHandle(handle);
    const path_copy = try alloc.dupe(u8, path);
    errdefer alloc.free(path_copy);
    return .{
        .handle = handle,
        .identity = try rootIdentityFromHandle(alloc, handle),
        .path = path_copy,
        .allocator = alloc,
    };
}

fn rootIdentityMatches(
    alloc: std.mem.Allocator,
    path: []const u8,
    expected: RootIdentity,
) Error!void {
    var guard = try openRootGuard(alloc, path);
    defer guard.close();
    if (!std.meta.eql(guard.identity, expected)) return error.AccessDenied;
}

fn openSecuredChildGuard(
    alloc: std.mem.Allocator,
    path: []const u8,
) Error!RootGuard {
    var guard = try openRootGuard(alloc, path);
    errdefer guard.close();
    try verifyFilesystemSecurity(alloc, path);
    return guard;
}

fn verifySecuredChildGuard(
    alloc: std.mem.Allocator,
    guard: RootGuard,
) Error!void {
    try rootIdentityMatches(alloc, guard.path, guard.identity);
    try verifyFilesystemSecurity(alloc, guard.path);
}

fn openIpcGuard(alloc: std.mem.Allocator) Error!RootGuard {
    const path = try rendezvousBase(alloc);
    defer alloc.free(path);
    return openSecuredChildGuard(alloc, path);
}

fn createSecuredChildBoundToRoot(
    alloc: std.mem.Allocator,
    root_guard: ?RootGuard,
    path: []const u8,
) Error!RootGuard {
    if (root_guard) |guard| try rootIdentityMatches(alloc, guard.path, guard.identity);
    try ensureSecureDirectory(alloc, path);
    var child_guard = try openSecuredChildGuard(alloc, path);
    errdefer child_guard.close();
    if (root_guard) |guard| try rootIdentityMatches(alloc, guard.path, guard.identity);
    try verifySecuredChildGuard(alloc, child_guard);
    return child_guard;
}

fn ensureConfiguredRoot(alloc: std.mem.Allocator, path: []const u8) Error!void {
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);
    var created = true;
    if (CreateDirectoryW(path_w.ptr, null) == 0) {
        if (windows.GetLastError() != .ALREADY_EXISTS) return error.AccessDenied;
        created = false;
    }
    if (created) {
        try setOwnerToCurrent(alloc, path);
    }
    // Check after CreateDirectoryW: an existing path, or a path replaced by a
    // reparse point during startup, must never be used for private children.
    var guard = try openRootGuard(alloc, path);
    guard.close();
}

fn setOwnerToCurrent(alloc: std.mem.Allocator, path: []const u8) Error!void {
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const sddl = try std.fmt.allocPrint(alloc, "O:{s}G:SYD:", .{sid});
    defer alloc.free(sddl);
    const sddl_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl) catch return error.AccessDenied;
    defer alloc.free(sddl_w);
    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        security_descriptor_revision,
        &descriptor,
        null,
    ) == 0) return error.AccessDenied;
    defer _ = LocalFree(descriptor);
    const path_w = try utf16Path(alloc, path);
    defer alloc.free(path_w);
    if (SetFileSecurityW(path_w.ptr, owner_security_information, descriptor.?) == 0) {
        return error.AccessDenied;
    }
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
    try rejectReparsePoint(alloc, path);
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
    try rejectReparsePoint(alloc, path);
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
    const configured = try configuredZmxDir(lease_allocator);
    defer if (configured) |root| lease_allocator.free(root);
    if (configured) |root| {
        const logs = try std.fmt.allocPrint(lease_allocator, "{s}\\logs", .{root});
        defer lease_allocator.free(logs);
        if (std.mem.eql(u8, path, logs)) {
            try ensureConfiguredRoot(lease_allocator, root);
            var root_guard = try openRootGuard(lease_allocator, root);
            defer root_guard.close();
            var guard = try createSecuredChildBoundToRoot(
                lease_allocator,
                root_guard,
                path,
            );
            defer guard.close();
            try verifySecuredChildGuard(lease_allocator, guard);
            try rootIdentityMatches(lease_allocator, root, root_guard.identity);
            return;
        }
    }
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

fn socketDirForConfiguredRoot(
    alloc: std.mem.Allocator,
    sid: []const u8,
    root: []const u8,
) Error![]u8 {
    if (sid.len == 0 or std.mem.indexOfScalar(u8, sid, '\\') != null) {
        return error.InvalidSessionName;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(root);
    hasher.final(&digest);
    var identity: [16]u8 = undefined;
    const digits = "0123456789abcdef";
    for (0..8) |index| {
        const byte = digest[index];
        identity[index * 2] = digits[byte >> 4];
        identity[index * 2 + 1] = digits[byte & 0x0f];
    }
    return std.fmt.allocPrint(
        alloc,
        "{s}-{s}-r{s}",
        .{ pipe_prefix, sid, identity },
    );
}

pub fn socketDir(alloc: std.mem.Allocator) Error![]u8 {
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const configured = try configuredZmxDir(alloc);
    defer if (configured) |path| alloc.free(path);
    if (configured) |root| {
        return socketDirForConfiguredRoot(alloc, sid, root);
    }
    return socketDirForSid(alloc, sid);
}

pub fn logDir(alloc: std.mem.Allocator) Error![]u8 {
    const configured = try configuredZmxDir(alloc);
    defer if (configured) |path| alloc.free(path);
    return logDirFor(alloc, configured);
}

fn logDirFor(alloc: std.mem.Allocator, configured: ?[]const u8) Error![]u8 {
    if (configured) |path| return std.fmt.allocPrint(alloc, "{s}\\logs", .{path});
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

fn configuredZmxDir(alloc: std.mem.Allocator) Error!?[]u8 {
    const value = (std.process.Environ{ .block = .global }).getAlloc(
        alloc,
        "ZMX_DIR",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return error.OutOfMemory,
    };
    if (value.len == 0 or std.mem.startsWith(u8, value, pipe_prefix)) {
        alloc.free(value);
        return null;
    }
    return value;
}

fn openConfiguredRootGuard(
    alloc: std.mem.Allocator,
) Error!?RootGuard {
    const configured = try configuredZmxDir(alloc);
    defer if (configured) |path| alloc.free(path);
    if (configured) |path| {
        return @as(?RootGuard, try openRootGuard(alloc, path));
    }
    return null;
}

fn verifyConfiguredRootGuard(
    alloc: std.mem.Allocator,
    guard: ?RootGuard,
) Error!void {
    if (guard) |value| {
        try rootIdentityMatches(alloc, value.path, value.identity);
    }
}

fn rendezvousBase(alloc: std.mem.Allocator) Error![]u8 {
    const configured = try configuredZmxDir(alloc);
    defer if (configured) |path| alloc.free(path);
    return rendezvousBaseFor(alloc, configured);
}

fn rendezvousBaseFor(alloc: std.mem.Allocator, configured: ?[]const u8) Error![]u8 {
    if (configured) |path| return std.fmt.allocPrint(alloc, "{s}\\ipc", .{path});
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    return std.fmt.allocPrint(alloc, "{s}\\zmx\\ipc", .{base});
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
    const configured = try configuredZmxDir(alloc);
    defer if (configured) |path| alloc.free(path);
    return ensureRendezvousDirectoryFor(io, alloc, session_name, configured);
}

fn ensureRendezvousDirectoryFor(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    configured: ?[]const u8,
) Error!void {
    _ = io;
    try validateSessionName(session_name);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const root = if (configured) |path|
        try alloc.dupe(u8, path)
    else
        try filesystemBase(alloc);
    defer alloc.free(root);
    const base = if (configured) |path|
        try std.fmt.allocPrint(alloc, "{s}\\ipc", .{path})
    else
        try rendezvousBase(alloc);
    defer alloc.free(base);
    const zmx_dir = if (configured != null)
        try alloc.dupe(u8, root)
    else
        try std.fmt.allocPrint(alloc, "{s}\\zmx", .{root});
    defer alloc.free(zmx_dir);
    const user_dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, sid });
    defer alloc.free(user_dir);

    var root_guard: ?RootGuard = null;
    defer if (root_guard) |*guard| guard.close();
    if (configured != null) {
        // ZMX_DIR is an operator-owned root; do not rewrite or require its
        // ACL. It must not be a reparse point before private children are used.
        try ensureConfiguredRoot(alloc, zmx_dir);
        root_guard = try openRootGuard(alloc, zmx_dir);
    } else {
        try ensureSecureDirectory(alloc, zmx_dir);
    }
    var base_guard = try createSecuredChildBoundToRoot(alloc, root_guard, base);
    defer base_guard.close();
    if (root_guard) |guard| try rootIdentityMatches(alloc, root, guard.identity);
    var user_guard = try createSecuredChildBoundToRoot(alloc, root_guard, user_dir);
    defer user_guard.close();
    if (root_guard) |guard| try rootIdentityMatches(alloc, root, guard.identity);
    try verifySecuredChildGuard(alloc, base_guard);
    try verifySecuredChildGuard(alloc, user_guard);
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
        // Keep the lease file at a stable path. Windows releases the byte-range
        // lock with the handle, while deleting here would let a concurrent
        // reacquirer open the old identity as a replacement is created.
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
    var root_guard = openConfiguredRootGuard(lease_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AccessDenied,
    };
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = openIpcGuard(lease_allocator) catch return error.AccessDenied;
    defer ipc_guard.close();
    const child_path = rendezvousDirectory(lease_allocator, session_name) catch return error.AccessDenied;
    defer lease_allocator.free(child_path);
    var child_guard = openSecuredChildGuard(lease_allocator, child_path) catch return error.AccessDenied;
    defer child_guard.close();

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
    verifyConfiguredRootGuard(lease_allocator, root_guard) catch {
        file.close(io);
        return error.AccessDenied;
    };
    verifySecuredChildGuard(lease_allocator, ipc_guard) catch {
        file.close(io);
        return error.AccessDenied;
    };
    verifySecuredChildGuard(lease_allocator, child_guard) catch {
        file.close(io);
        return error.AccessDenied;
    };

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
    var root_guard = try openConfiguredRootGuard(alloc);
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = try openIpcGuard(alloc);
    defer ipc_guard.close();
    const child_path = try rendezvousDirectory(alloc, session_name);
    defer alloc.free(child_path);
    var child_guard = try openSecuredChildGuard(alloc, child_path);
    defer child_guard.close();
    var record = std.Io.Dir.createFileAbsolute(io, record_path, .{
        .read = true,
        .exclusive = true,
        .permissions = .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AccessDenied,
        else => return error.AccessDenied,
    };
    var keep_record = false;
    defer {
        record.close(io);
        if (!keep_record) std.Io.Dir.deleteFileAbsolute(io, record_path) catch {};
    }
    secureCreatedFile(alloc, record_path) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AccessDenied,
        };
    };
    record.writeStreamingAll(io, endpoint) catch return error.AccessDenied;
    try verifyConfiguredRootGuard(alloc, root_guard);
    try verifySecuredChildGuard(alloc, ipc_guard);
    try verifySecuredChildGuard(alloc, child_guard);
    keep_record = true;
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
    var root_guard = try openConfiguredRootGuard(alloc);
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = try openIpcGuard(alloc);
    defer ipc_guard.close();
    const child_path = try rendezvousDirectory(alloc, session_name);
    defer alloc.free(child_path);
    var child_guard = try openSecuredChildGuard(alloc, child_path);
    defer child_guard.close();
    std.Io.Dir.deleteFileAbsolute(io, record_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.AccessDenied,
    };
    try verifyConfiguredRootGuard(alloc, root_guard);
    try verifySecuredChildGuard(alloc, ipc_guard);
    try verifySecuredChildGuard(alloc, child_guard);
    return publishEndpoint(io, alloc, session_name, endpoint);
}

pub fn cleanupRendezvous(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) void {
    const record_path = rendezvousRecordPath(alloc, session_name) catch return;
    defer alloc.free(record_path);
    var root_guard = openConfiguredRootGuard(alloc) catch return;
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = openIpcGuard(alloc) catch return;
    defer ipc_guard.close();
    const child_path = rendezvousDirectory(alloc, session_name) catch return;
    defer alloc.free(child_path);
    var child_guard = openSecuredChildGuard(alloc, child_path) catch return;
    defer child_guard.close();
    std.Io.Dir.deleteFileAbsolute(io, record_path) catch {};
    verifyConfiguredRootGuard(alloc, root_guard) catch {};
    verifySecuredChildGuard(alloc, ipc_guard) catch {};
    verifySecuredChildGuard(alloc, child_guard) catch {};
}

/// Remove a rendezvous record only when it still names the endpoint owned by
/// this server. The comparison prevents a late close from deleting a newer
/// replacement record.
pub fn cleanupRendezvousIfOwned(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
    endpoint: []const u8,
) void {
    const current = resolveEndpointPath(io, alloc, session_name) catch return;
    defer alloc.free(current);
    if (!std.mem.eql(u8, current, endpoint)) return;

    const record_path = rendezvousRecordPath(alloc, session_name) catch return;
    defer alloc.free(record_path);
    var root_guard = openConfiguredRootGuard(alloc) catch return;
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = openIpcGuard(alloc) catch return;
    defer ipc_guard.close();
    const child_path = rendezvousDirectory(alloc, session_name) catch return;
    defer alloc.free(child_path);
    var child_guard = openSecuredChildGuard(alloc, child_path) catch return;
    defer child_guard.close();
    std.Io.Dir.deleteFileAbsolute(io, record_path) catch {};
    verifyConfiguredRootGuard(alloc, root_guard) catch {};
    verifySecuredChildGuard(alloc, ipc_guard) catch {};
    verifySecuredChildGuard(alloc, child_guard) catch {};
}

pub fn hasRendezvous(
    io: std.Io,
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error!bool {
    try ensureRendezvousDirectory(io, alloc, session_name);
    var root_guard = try openConfiguredRootGuard(alloc);
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = try openIpcGuard(alloc);
    defer ipc_guard.close();
    const child_path = try rendezvousDirectory(alloc, session_name);
    defer alloc.free(child_path);
    var child_guard = try openSecuredChildGuard(alloc, child_path);
    defer child_guard.close();
    const record_path = try rendezvousRecordPath(alloc, session_name);
    defer alloc.free(record_path);
    var record = std.Io.Dir.openFileAbsolute(io, record_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.AccessDenied,
    };
    record.close(io);
    try verifyFilesystemSecurity(alloc, record_path);
    try verifyConfiguredRootGuard(alloc, root_guard);
    try verifySecuredChildGuard(alloc, ipc_guard);
    try verifySecuredChildGuard(alloc, child_guard);
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
    var root_guard = try openConfiguredRootGuard(alloc);
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = try openIpcGuard(alloc);
    defer ipc_guard.close();
    const child_path = try rendezvousDirectory(alloc, "list");
    defer alloc.free(child_path);
    var child_guard = try openSecuredChildGuard(alloc, child_path);
    defer child_guard.close();
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
    try verifyConfiguredRootGuard(alloc, root_guard);
    try verifySecuredChildGuard(alloc, ipc_guard);
    try verifySecuredChildGuard(alloc, child_guard);
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
    var root_guard = try openConfiguredRootGuard(alloc);
    defer if (root_guard) |*guard| guard.close();
    var ipc_guard = try openIpcGuard(alloc);
    defer ipc_guard.close();
    const child_path = try rendezvousDirectory(alloc, session_name);
    defer alloc.free(child_path);
    var child_guard = try openSecuredChildGuard(alloc, child_path);
    defer child_guard.close();
    const record_path = rendezvousRecordPath(alloc, session_name) catch {
        try verifyConfiguredRootGuard(alloc, root_guard);
        return endpointPath(alloc, session_name);
    };
    defer alloc.free(record_path);
    var record = std.Io.Dir.openFileAbsolute(io, record_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            try verifyConfiguredRootGuard(alloc, root_guard);
            return endpointPath(alloc, session_name);
        },
        else => {
            try verifyConfiguredRootGuard(alloc, root_guard);
            return endpointPath(alloc, session_name);
        },
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
    try verifyConfiguredRootGuard(alloc, root_guard);
    try verifySecuredChildGuard(alloc, ipc_guard);
    try verifySecuredChildGuard(alloc, child_guard);
    return alloc.dupe(u8, endpoint);
}

pub fn nonceEndpointPath(
    alloc: std.mem.Allocator,
    session_name: []const u8,
) Error![]u8 {
    try validateSessionName(session_name);
    const directory = try socketDir(alloc);
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

test "Windows isolated roots use distinct endpoint namespaces without rendezvous" {
    const alloc = std.testing.allocator;
    const first = try socketDirForConfiguredRoot(
        alloc,
        "S-1-5-21-100",
        "C:\\zmx-quickchat-a",
    );
    defer alloc.free(first);
    const second = try socketDirForConfiguredRoot(
        alloc,
        "S-1-5-21-100",
        "C:\\zmx-quickchat-b",
    );
    defer alloc.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));

    const first_endpoint = try joinEndpointPath(alloc, first, "same", max_pipe_name_utf16);
    defer alloc.free(first_endpoint);
    const second_endpoint = try joinEndpointPath(alloc, second, "same", max_pipe_name_utf16);
    defer alloc.free(second_endpoint);
    try std.testing.expect(!std.mem.eql(u8, first_endpoint, second_endpoint));
}

test "Windows default root retains the legacy deterministic endpoint namespace" {
    const alloc = std.testing.allocator;
    const directory = try socketDirForSid(alloc, "S-1-5-21-100");
    defer alloc.free(directory);
    const endpoint = try joinEndpointPath(alloc, directory, "same", max_pipe_name_utf16);
    defer alloc.free(endpoint);
    try std.testing.expectEqualStrings(
        "\\\\.\\pipe\\zmx-S-1-5-21-100\\same",
        endpoint,
    );
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

test "Windows rendezvous cleanup preserves a replacement endpoint" {
    const alloc = std.testing.allocator;
    const session_name = "rendezvous-cleanup-owner";
    defer cleanupRendezvous(std.testing.io, alloc, session_name);

    const owned = "\\\\.\\pipe\\zmx\\owned";
    const replacement = "\\\\.\\pipe\\zmx\\replacement";
    try publishEndpoint(std.testing.io, alloc, session_name, owned);
    cleanupRendezvousIfOwned(
        std.testing.io,
        alloc,
        session_name,
        replacement,
    );
    const still_published = try resolveEndpointPath(
        std.testing.io,
        alloc,
        session_name,
    );
    defer alloc.free(still_published);
    try std.testing.expectEqualStrings(owned, still_published);

    cleanupRendezvousIfOwned(
        std.testing.io,
        alloc,
        session_name,
        owned,
    );
    try std.testing.expect(!(try hasRendezvous(
        std.testing.io,
        alloc,
        session_name,
    )));
}

test "Windows fallback log paths are filesystem paths" {
    const alloc = std.testing.allocator;
    const path = try logDir(alloc);
    defer alloc.free(path);
    try std.testing.expect(!std.mem.startsWith(u8, path, pipe_prefix));
    try std.testing.expect(std.mem.indexOf(u8, path, "\\logs") != null);
}

test "Windows explicit ZMX_DIR isolates rendezvous and log roots" {
    const alloc = std.testing.allocator;
    const configured = "C:\\zmx-quickchat-isolated";
    const rendezvous = try rendezvousBaseFor(alloc, configured);
    defer alloc.free(rendezvous);
    try std.testing.expectEqualStrings(
        "C:\\zmx-quickchat-isolated\\ipc",
        rendezvous,
    );

    const logs = try logDirFor(alloc, configured);
    defer alloc.free(logs);
    try std.testing.expectEqualStrings(
        "C:\\zmx-quickchat-isolated\\logs",
        logs,
    );
}

test "Windows configured root may use inherited ACLs while children are secured" {
    const alloc = std.testing.allocator;
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    const root = try std.fmt.allocPrint(alloc, "{s}\\zmx-inherited-root", .{base});
    defer alloc.free(root);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const user_dir = try std.fmt.allocPrint(alloc, "{s}\\ipc\\{s}", .{ root, sid });
    defer alloc.free(user_dir);
    const ipc_dir = try std.fmt.allocPrint(alloc, "{s}\\ipc", .{root});
    defer alloc.free(ipc_dir);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, user_dir) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_dir) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
    try setOwnerToCurrent(alloc, root);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, user_dir) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_dir) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};

    try ensureRendezvousDirectoryFor(
        std.testing.io,
        alloc,
        "inherited-acl",
        root,
    );
}

test "Windows missing configured root is created with inherited ACLs" {
    const alloc = std.testing.allocator;
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    const parent = try std.fmt.allocPrint(alloc, "{s}\\zmx-missing-parent", .{base});
    defer alloc.free(parent);
    const root = try std.fmt.allocPrint(alloc, "{s}\\child", .{parent});
    defer alloc.free(root);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const user_dir = try std.fmt.allocPrint(alloc, "{s}\\ipc\\{s}", .{ root, sid });
    defer alloc.free(user_dir);
    const ipc_dir = try std.fmt.allocPrint(alloc, "{s}\\ipc", .{root});
    defer alloc.free(ipc_dir);

    std.Io.Dir.deleteDirAbsolute(std.testing.io, user_dir) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_dir) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, parent, .default_dir);
    try setOwnerToCurrent(alloc, parent);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, user_dir) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_dir) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, parent) catch {};

    try ensureRendezvousDirectoryFor(
        std.testing.io,
        alloc,
        "missing-root",
        root,
    );
}

test "Windows configured reparse root is rejected" {
    const alloc = std.testing.allocator;
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    const target = try std.fmt.allocPrint(alloc, "{s}\\zmx-reparse-target", .{base});
    defer alloc.free(target);
    const link = try std.fmt.allocPrint(alloc, "{s}\\zmx-reparse-link", .{base});
    defer alloc.free(link);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, link) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, target) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, target, .default_dir);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, link) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, target) catch {};

    const link_w = try utf16Path(alloc, link);
    defer alloc.free(link_w);
    const target_w = try utf16Path(alloc, target);
    defer alloc.free(target_w);
    if (CreateSymbolicLinkW(
        link_w.ptr,
        target_w.ptr,
        symbolic_link_flag_directory | symbolic_link_flag_allow_unprivileged_create,
    ) == 0) return;
    try std.testing.expectError(error.AccessDenied, ensureConfiguredRoot(alloc, link));
}

test "Windows cross-root ipc junction never writes into the other root" {
    const alloc = std.testing.allocator;
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    const root_a = try std.fmt.allocPrint(alloc, "{s}\\zmx-race-root-a", .{base});
    defer alloc.free(root_a);
    const root_b = try std.fmt.allocPrint(alloc, "{s}\\zmx-race-root-b", .{base});
    defer alloc.free(root_b);
    const ipc_a = try std.fmt.allocPrint(alloc, "{s}\\ipc", .{root_a});
    defer alloc.free(ipc_a);
    const ipc_b = try std.fmt.allocPrint(alloc, "{s}\\ipc", .{root_b});
    defer alloc.free(ipc_b);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const user_b = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ ipc_b, sid });
    defer alloc.free(user_b);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, user_b) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_b) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_a) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root_a) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root_b) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, root_a, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, root_b, .default_dir);
    try setOwnerToCurrent(alloc, root_a);
    try setOwnerToCurrent(alloc, root_b);
    try ensureRendezvousDirectoryFor(std.testing.io, alloc, "cross-root", root_b);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root_a) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, user_b) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc_b) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root_b) catch {};

    const ipc_a_w = try utf16Path(alloc, ipc_a);
    defer alloc.free(ipc_a_w);
    const ipc_b_w = try utf16Path(alloc, ipc_b);
    defer alloc.free(ipc_b_w);
    if (CreateSymbolicLinkW(
        ipc_a_w.ptr,
        ipc_b_w.ptr,
        symbolic_link_flag_directory | symbolic_link_flag_allow_unprivileged_create,
    ) != 0) {
        try std.testing.expectError(
            error.AccessDenied,
            ensureRendezvousDirectoryFor(
                std.testing.io,
                alloc,
                "cross-root",
                root_a,
            ),
        );
        var b_guard = try openSecuredChildGuard(alloc, user_b);
        b_guard.close();
    }
}

test "Windows private child replacement fails without decoy writes" {
    const alloc = std.testing.allocator;
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    const root = try std.fmt.allocPrint(alloc, "{s}\\zmx-child-race", .{base});
    defer alloc.free(root);
    const decoy = try std.fmt.allocPrint(alloc, "{s}\\zmx-child-decoy", .{base});
    defer alloc.free(decoy);
    const ipc = try std.fmt.allocPrint(alloc, "{s}\\ipc", .{root});
    defer alloc.free(ipc);
    const sid = try currentUserSid(alloc);
    defer alloc.free(sid);
    const user = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ ipc, sid });
    defer alloc.free(user);
    const logs = try std.fmt.allocPrint(alloc, "{s}\\logs", .{root});
    defer alloc.free(logs);
    const decoy_user = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ decoy, sid });
    defer alloc.free(decoy_user);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, user) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, logs) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, decoy) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
    try setOwnerToCurrent(alloc, root);
    try std.Io.Dir.createDirAbsolute(std.testing.io, decoy, .default_dir);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, decoy) catch {};

    try ensureRendezvousDirectoryFor(std.testing.io, alloc, "child-race", root);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, user) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, ipc) catch {};
    const ipc_w = try utf16Path(alloc, ipc);
    defer alloc.free(ipc_w);
    const decoy_w = try utf16Path(alloc, decoy);
    defer alloc.free(decoy_w);
    if (CreateSymbolicLinkW(
        ipc_w.ptr,
        decoy_w.ptr,
        symbolic_link_flag_directory | symbolic_link_flag_allow_unprivileged_create,
    ) != 0) {
        try std.testing.expectError(
            error.AccessDenied,
            ensureRendezvousDirectoryFor(std.testing.io, alloc, "child-race", root),
        );
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.openDirAbsolute(std.testing.io, decoy_user, .{}),
        );
    }
}

test "Windows logs replacement race never writes into a valid decoy" {
    const alloc = std.testing.allocator;
    const base = try filesystemBase(alloc);
    defer alloc.free(base);
    const root_a = try std.fmt.allocPrint(alloc, "{s}\\zmx-logs-race-a", .{base});
    defer alloc.free(root_a);
    const root_b = try std.fmt.allocPrint(alloc, "{s}\\zmx-logs-race-b", .{base});
    defer alloc.free(root_b);
    const logs_a = try std.fmt.allocPrint(alloc, "{s}\\logs", .{root_a});
    defer alloc.free(logs_a);
    const logs_b = try std.fmt.allocPrint(alloc, "{s}\\logs", .{root_b});
    defer alloc.free(logs_b);
    std.Io.Dir.deleteDirAbsolute(std.testing.io, logs_a) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, logs_b) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root_a) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root_b) catch {};
    try std.Io.Dir.createDirAbsolute(std.testing.io, root_a, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, root_b, .default_dir);
    try setOwnerToCurrent(alloc, root_a);
    try setOwnerToCurrent(alloc, root_b);
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, logs_a) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, logs_b) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root_a) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root_b) catch {};

    var root_b_guard = try openRootGuard(alloc, root_b);
    defer root_b_guard.close();
    var logs_b_guard = try createSecuredChildBoundToRoot(alloc, root_b_guard, logs_b);
    defer logs_b_guard.close();
    var root_a_guard = try openRootGuard(alloc, root_a);
    defer root_a_guard.close();

    const logs_a_w = try utf16Path(alloc, logs_a);
    defer alloc.free(logs_a_w);
    const logs_b_w = try utf16Path(alloc, logs_b);
    defer alloc.free(logs_b_w);
    if (CreateSymbolicLinkW(
        logs_a_w.ptr,
        logs_b_w.ptr,
        symbolic_link_flag_directory | symbolic_link_flag_allow_unprivileged_create,
    ) != 0) {
        try std.testing.expectError(
            error.AccessDenied,
            createSecuredChildBoundToRoot(alloc, root_a_guard, logs_a),
        );
        try verifySecuredChildGuard(alloc, logs_b_guard);
    }
}

test "Windows session lease excludes a second owner" {
    const first = try acquireSessionLease(std.testing.io, "lease-exclusion");
    defer first.release();
    try std.testing.expectError(
        error.AccessDenied,
        acquireSessionLease(std.testing.io, "lease-exclusion"),
    );
}

test "Windows session lease reuses one stable lock file after release" {
    const alloc = std.testing.allocator;
    const session_name = "lease-reusable";
    const path = try rendezvousLeasePath(alloc, session_name);
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    const first = try acquireSessionLease(std.testing.io, session_name);
    first.release();

    var existing = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        path,
        .{ .mode = .read_only },
    );
    existing.close(std.testing.io);

    const second = try acquireSessionLease(std.testing.io, session_name);
    second.release();
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
