const builtin = @import("builtin");
const std = @import("std");

pub const c = switch (builtin.os.tag) {
    .windows => struct {
        pub const termios = void;
        pub const struct_winsize = extern struct {
            ws_row: u16,
            ws_col: u16,
            ws_xpixel: u16,
            ws_ypixel: u16,
        };
        pub const SEEK_END: c_int = 2;
        pub const TCSAFLUSH: c_int = 2;
        pub const TCSANOW: c_int = 0;
        pub const VLNEXT: usize = 0;
        pub const VQUIT: usize = 0;
        pub const VMIN: usize = 0;
        pub const VTIME: usize = 0;
        pub const _POSIX_VDISABLE: u8 = 0;

        pub fn getenv(name: [*:0]const u8) ?[*:0]u8 {
            return std.c.getenv(name);
        }

        pub fn putenv(_: [*:0]u8) c_int {
            return 0;
        }

        pub fn setenv(_: [*:0]const u8, _: [*:0]const u8, _: c_int) c_int {
            return 0;
        }

        pub fn unsetenv(_: [*:0]const u8) c_int {
            return 0;
        }

        pub fn lseek(fd: anytype, offset: anytype, whence: anytype) @TypeOf(offset) {
            return std.c.lseek(fd, offset, whence);
        }

        pub fn tcgetattr(_: anytype, _: anytype) c_int {
            return -1;
        }

        pub fn tcsetattr(_: anytype, _: anytype, _: anytype) c_int {
            return -1;
        }

        pub fn cfmakeraw(_: anytype) void {}

        pub fn ioctl(_: anytype, _: anytype, _: anytype) c_int {
            return -1;
        }
    },
    .macos => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("termios.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    .freebsd => @cImport({
        @cInclude("termios.h"); // ioctl and constants
        @cInclude("libutil.h"); // openpty()
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
    else => @cImport({
        @cInclude("sys/ioctl.h"); // ioctl and constants
        @cInclude("pty.h");
        @cInclude("stdlib.h");
        @cInclude("unistd.h");
    }),
};

// Manually declare forkpty for macOS since util.h is not available during cross-compilation
pub const forkpty = if (builtin.os.tag == .macos)
    struct {
        extern "c" fn forkpty(master_fd: *c_int, name: ?[*:0]u8, termp: ?*const c.struct_termios, winp: ?*const c.struct_winsize) c_int;
    }.forkpty
else if (builtin.os.tag == .windows)
    struct {
        fn unsupported(_: *c_int, _: ?[*:0]u8, _: ?*const c.termios, _: ?*const c.struct_winsize) c_int {
            return -1;
        }
    }.unsupported
else
    c.forkpty;
