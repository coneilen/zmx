const builtin = @import("builtin");
const std = @import("std");

const implementation = if (builtin.os.tag == .windows)
    @import("main_windows.zig")
else
    @import("main_posix.zig");

pub fn main(init: std.process.Init) !void {
    return implementation.main(init);
}
