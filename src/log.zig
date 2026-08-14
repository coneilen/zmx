const builtin = @import("builtin");
const std = @import("std");
const cross = if (builtin.os.tag == .windows) struct {} else @import("cross.zig");

pub var log_system = LogSystem{};

const default_log_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    @enumFromInt(0)
else
    std.Io.File.Permissions.fromMode(0o640);

pub fn zmxLogFn(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    log_system.log(level, scope, format, args) catch {};
}

pub const LogSystem = struct {
    file: ?std.Io.File = null,
    mutex: std.Io.Mutex = .init,
    current_size: u64 = 0,
    max_size: u64 = 2 * 1024 * 1024, // 2MB
    path: []const u8 = "",
    io: std.Io = undefined,
    mode: std.Io.File.Permissions = default_log_permissions,

    pub fn init(self: *LogSystem, io: std.Io, path: []const u8, mode: std.Io.File.Permissions) !void {
        self.io = io;
        self.path = path;
        self.mode = mode;

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.createFileAbsolute(
                self.io,
                path,
                .{ .read = true, .permissions = self.mode },
            ),
            else => return err,
        };
        errdefer std.Io.File.close(file, self.io);

        // Use lseek(SEEK_END) instead of length() + seekTo() to avoid a
        // TOCTOU race: after fork() the parent may still write to the log
        // between our length() check and seekTo(), causing us to overwrite
        // recent parent entries. lseek(fd, 0, SEEK_END) is atomic — it
        // always positions at the true end of file at seek time.
        if (builtin.os.tag == .windows) {
            self.current_size = (try file.stat(self.io)).size;
            var seek_buf: [1]u8 = undefined;
            var writer = file.writerStreaming(self.io, &seek_buf);
            try writer.seekTo(self.current_size);
        } else {
            const new_pos = cross.c.lseek(file.handle, 0, cross.c.SEEK_END);
            if (new_pos == -1) {
                return error.SeekFailed;
            }
            self.current_size = @as(u64, @intCast(new_pos));
        }
        self.file = file;
    }

    pub fn deinit(self: *LogSystem) void {
        if (self.file) |f| std.Io.File.close(f, self.io);
    }

    pub fn log(
        self: *LogSystem,
        comptime level: std.log.Level,
        comptime scope: anytype,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.file == null) {
            std.log.defaultLog(level, scope, format, args);
            return;
        }

        if (self.current_size >= self.max_size) {
            self.wipe() catch |err| {
                std.debug.print("Log wipe failed: {s}\n", .{@errorName(err)});
            };
        }

        const now: std.Io.Timestamp = .now(self.io, .real);
        const prefix = "[{d}] [{s}] ({s}): ";
        const scope_name = @tagName(scope);
        const level_name = level.asText();

        const prefix_args = .{
            now.toSeconds(),
            level_name,
            scope_name,
        };

        if (self.file) |f| {
            const prefix_len = std.fmt.count(prefix, prefix_args);
            const msg_len = std.fmt.count(format, args);
            const newline_len = 1;
            const total_len = prefix_len + msg_len + newline_len;
            self.current_size += total_len;

            var buf: [4096]u8 = undefined;
            var w = f.writerStreaming(self.io, &buf);
            std.Io.Writer.print(&w.interface, prefix ++ format ++ "\n", prefix_args ++ args) catch {};
            w.interface.flush() catch {};
        }
    }

    fn wipe(self: *LogSystem) !void {
        if (self.file) |f| {
            std.Io.File.close(f, self.io);
            self.file = null;
        }

        self.file = try std.Io.Dir.createFileAbsolute(
            self.io,
            self.path,
            .{
                .truncate = true,
                .read = true,
                .permissions = self.mode,
            },
        );
        self.current_size = 0;
    }
};

test "Windows logs append to existing files after initialization" {
    if (builtin.os.tag != .windows) return;

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ cwd_buffer[0..cwd_len], "zmx-log-eof-test.log" },
    );
    defer std.testing.allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    var existing = try std.Io.Dir.createFileAbsolute(
        std.testing.io,
        path,
        .{ .read = true },
    );
    const old_bytes = [_]u8{'x'} ** 5000;
    try existing.writeStreamingAll(std.testing.io, &old_bytes);
    existing.close(std.testing.io);

    var system = LogSystem{};
    try system.init(
        std.testing.io,
        path,
        if (builtin.os.tag == .windows) @enumFromInt(0) else default_log_permissions,
    );
    try std.testing.expectEqual(@as(u64, old_bytes.len), system.current_size);
    try system.log(.info, .scope_test, "suffix", .{});
    system.deinit();

    const after = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        path,
        .{ .mode = .read_only },
    );
    defer after.close(std.testing.io);
    try std.testing.expect((try after.stat(std.testing.io)).size > old_bytes.len);
}
