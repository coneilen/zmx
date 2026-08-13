const std = @import("std");
const posix = @import("../posix.zig");
const runtime = @import("runtime.zig");

/// POSIX session names are Unix-socket filename components. Backslashes are
/// ordinary filename bytes on POSIX and remain compatible with existing CLI
/// and environment-based session selection.
pub fn validateSessionName(name: []const u8) runtime.PathError!void {
    if (name.len == 0 or
        std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return error.InvalidSessionName;
    }
}

pub fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
    const tmpdir = std.mem.trimEnd(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
    const uid = posix.getuid();

    return if (posix.getenv("ZMX_DIR")) |zmxdir|
        alloc.dupe(u8, zmxdir)
    else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
        std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
    else
        std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
}

pub fn logDir(alloc: std.mem.Allocator) ![]const u8 {
    return if (posix.getenv("ZMX_DIR")) |zmxdir|
        std.fmt.allocPrint(alloc, "{s}/logs", .{zmxdir})
    else if (posix.getenv("XDG_STATE_HOME")) |xdg_state_home|
        std.fmt.allocPrint(alloc, "{s}/zmx/logs", .{xdg_state_home})
    else if (posix.getenv("HOME")) |home_dir|
        std.fmt.allocPrint(alloc, "{s}/.local/state/zmx/logs", .{home_dir})
    else fallback: {
        const tmpdir = std.mem.trimEnd(u8, posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = posix.getuid();
        break :fallback std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
    };
}

test "POSIX runtime adapter keeps explicit fallback directory names" {
    const alloc = std.testing.allocator;
    const old = posix.getenv("ZMX_DIR");
    _ = old;
    // Environment-dependent path selection is characterized by cfg.zig; this
    // test only ensures the adapter is callable and allocator-safe.
    const path = try socketDir(alloc);
    alloc.free(path);
}

test "POSIX runtime accepts backslashes in session names" {
    try validateSessionName("legacy\\session");
    try std.testing.expectError(error.InvalidSessionName, validateSessionName("../escape"));
}
