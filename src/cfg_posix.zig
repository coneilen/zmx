/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
pub const Cfg = @This();

const std = @import("std");
const lib_posix = @import("posix.zig");
const cross = @import("cross.zig");
const runtime_posix = @import("platform/runtime_posix.zig");

socket_dir: []const u8,
log_dir: []const u8,
max_scrollback_lines: usize = 2_000, // same default as tmux
dir_mode: u32 = 0o750,
log_mode: u32 = 0o640,

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Cfg {
    const socket_dir = try socketDir(alloc);
    errdefer alloc.free(socket_dir);
    const log_dir = try logDir(alloc);
    errdefer alloc.free(log_dir);

    const dir_mode = if (lib_posix.getenv("ZMX_DIR_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch 0o750
    else
        0o750;

    const log_mode = if (lib_posix.getenv("ZMX_LOG_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch 0o640
    else
        0o640;

    var cfg = Cfg{
        .socket_dir = socket_dir,
        .log_dir = log_dir,
        .dir_mode = dir_mode,
        .log_mode = log_mode,
    };

    try cfg.mkdir(io);

    return cfg;
}

fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
    return runtime_posix.socketDir(alloc);
}

fn logDir(alloc: std.mem.Allocator) ![]const u8 {
    return runtime_posix.logDir(alloc);
}

pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
    if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
    if (self.log_dir.len > 0) alloc.free(self.log_dir);
}

pub fn mkdir(self: *Cfg, io: std.Io) !void {
    const sock_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.socket_dir, sock_perms);
    const log_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.log_dir, log_perms);
}

fn mkdirAll(io: std.Io, sub_dir_path: []const u8, permissions: std.Io.Dir.Permissions) !void {
    var it = std.fs.path.componentIterator(sub_dir_path);
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        std.Io.Dir.createDirAbsolute(io, component.path, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        };
        component = it.next() orelse return;
    }
}

test "Cfg.init uses default modes when env vars are not set" {
    const alloc = std.testing.allocator;

    // Ensure they are not set
    _ = cross.c.unsetenv("ZMX_DIR_MODE");
    _ = cross.c.unsetenv("ZMX_LOG_MODE");

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o750), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o640), cfg.log_mode);
}

test "Cfg.init uses custom modes from env vars" {
    const alloc = std.testing.allocator;

    // Set custom octal values
    _ = cross.c.setenv("ZMX_DIR_MODE", "770", 1);
    _ = cross.c.setenv("ZMX_LOG_MODE", "660", 1);
    defer {
        _ = cross.c.unsetenv("ZMX_DIR_MODE");
        _ = cross.c.unsetenv("ZMX_LOG_MODE");
    }

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o770), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o660), cfg.log_mode);
}
