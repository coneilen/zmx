const cross = @import("../cross.zig");
const posix = @import("../posix.zig");
const pty = @import("pty.zig");
const resize = @import("resize.zig");
const std = @import("std");

pub const Info = struct {
    master_fd: posix.fd_t,
    pid: c_int,
};

pub fn forkPty(size: resize.Size) !Info {
    var ws: cross.c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };
    var master_fd: c_int = undefined;
    const pid = cross.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) return error.ForkPtyFailed;
    return .{ .master_fd = master_fd, .pid = pid };
}

pub fn getTerminalSize(fd: posix.fd_t) resize.Size {
    var ws: cross.c.struct_winsize = undefined;
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
    }
    inline for (.{ posix.STDOUT_FILENO, posix.STDIN_FILENO, posix.STDERR_FILENO }) |fallback_fd| {
        if (fallback_fd != fd) {
            if (cross.c.ioctl(fallback_fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
                return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
            }
        }
    }
    if (posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |tty_fd| {
        defer posix.close(tty_fd);
        if (cross.c.ioctl(tty_fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
        }
    } else |_| {}
    return resize.fallback();
}

pub fn resizeMaster(master_fd: posix.fd_t, size: resize.Size) void {
    var ws: cross.c.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };
    _ = cross.c.ioctl(master_fd, cross.c.TIOCSWINSZ, &ws);
}

pub fn toSpawned(info: Info) pty.Spawned {
    return .{
        .master = @intCast(info.master_fd),
        .process = @intCast(info.pid),
    };
}

pub fn fromSpawned(value: pty.Spawned) Info {
    return .{
        .master_fd = @intCast(value.master),
        .pid = @intCast(value.process),
    };
}

test "POSIX PTY adapter round-trips opaque handles" {
    var original = std.mem.zeroes(Info);
    original.pid = 34;
    const round_trip = fromSpawned(toSpawned(original));
    try @import("std").testing.expectEqual(original.master_fd, round_trip.master_fd);
    try @import("std").testing.expectEqual(original.pid, round_trip.pid);
}
