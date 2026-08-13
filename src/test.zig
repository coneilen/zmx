const builtin = @import("builtin");

comptime {
    if (builtin.os.tag == .windows) {
        _ = @import("main.zig");
        _ = @import("main_windows.zig");
        _ = @import("platform/daemon_windows.zig");
        _ = @import("platform/events_windows.zig");
        _ = @import("platform/local_ipc_windows.zig");
        _ = @import("platform/runtime_windows.zig");
        _ = @import("platform/pty_windows.zig");
        _ = @import("platform/pty_runtime.zig");
        _ = @import("platform/pty_session_windows.zig");
        _ = @import("platform/session_wire.zig");
        _ = @import("platform/session_windows.zig");
    } else {
        _ = @import("main.zig");
        _ = @import("main_posix.zig");
        _ = @import("util.zig");
        _ = @import("socket.zig");
        _ = @import("socket_posix.zig");
        _ = @import("ipc.zig");
        _ = @import("label.zig");
        _ = @import("signal.zig");
        _ = @import("loop.zig");
        _ = @import("cfg.zig");
        _ = @import("cfg_posix.zig");
        _ = @import("daemonize.zig");
        _ = @import("platform.zig");
        _ = @import("platform/daemon.zig");
        _ = @import("platform/events.zig");
        _ = @import("platform/events_posix.zig");
        _ = @import("platform/local_ipc.zig");
        _ = @import("platform/local_ipc_posix.zig");
        _ = @import("platform/pty.zig");
        _ = @import("platform/pty_posix.zig");
        _ = @import("platform/resize.zig");
        _ = @import("platform/runtime.zig");
        _ = @import("platform/runtime_posix.zig");
        _ = @import("platform/shell.zig");
        _ = @import("platform/pty_windows.zig");
        _ = @import("platform/pty_runtime.zig");
    }
}
