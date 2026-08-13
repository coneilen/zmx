const std = @import("std");
const runtime_windows = @import("platform/runtime_windows.zig");

pub const Cfg = @This();

socket_dir: []const u8,
log_dir: []const u8,
max_scrollback_lines: usize = 2_000,
dir_mode: u32 = 0o750,
log_mode: u32 = 0o640,

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Cfg {
    const socket_dir = try runtime_windows.socketDir(alloc);
    errdefer alloc.free(socket_dir);
    const log_dir = try runtime_windows.logDir(alloc);
    errdefer alloc.free(log_dir);

    var cfg = Cfg{
        .socket_dir = socket_dir,
        .log_dir = log_dir,
        .dir_mode = try envMode(alloc, "ZMX_DIR_MODE", 0o750),
        .log_mode = try envMode(alloc, "ZMX_LOG_MODE", 0o640),
    };
    try cfg.mkdir(io);
    return cfg;
}

fn envMode(alloc: std.mem.Allocator, name: []const u8, fallback: u32) !u32 {
    const value = (std.process.Environ{ .block = .global }).getAlloc(alloc, name) catch return fallback;
    defer alloc.free(value);
    return std.fmt.parseInt(u32, value, 8) catch fallback;
}

pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
    if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
    if (self.log_dir.len > 0) alloc.free(self.log_dir);
}

/// Named-pipe namespaces do not need a directory. Only the log directory is
/// materialized by the Windows configuration adapter.
pub fn mkdir(self: *Cfg, io: std.Io) !void {
    try mkdirAll(io, self.log_dir, .default_dir);
}

fn mkdirAll(io: std.Io, path: []const u8, permissions: std.Io.Dir.Permissions) !void {
    var it = std.fs.path.componentIterator(path);
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

test "Windows Cfg keeps named-pipe namespace out of filesystem setup" {
    const alloc = std.testing.allocator;
    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, cfg.socket_dir, runtime_windows.pipe_prefix));
}
