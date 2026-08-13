const builtin = @import("builtin");
const selected = if (builtin.os.tag == .windows)
    @import("cfg_windows.zig")
else
    @import("cfg_posix.zig");

pub const Cfg = selected.Cfg;
pub const init = selected.init;
