const builtin = @import("builtin");
const std = @import("std");

const implementation = if (builtin.os.tag == .windows)
    @import("main_windows.zig")
else
    @import("main_posix.zig");

pub const std_options: std.Options = implementation.std_options;

pub fn main(init: std.process.Init) !void {
    return implementation.main(init);
}
