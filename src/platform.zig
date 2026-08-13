//! Platform contracts used by zmx's session engine.
//!
//! The contracts in this namespace deliberately do not contain wire-protocol
//! tags or session state.  They describe the operating-system work needed by
//! the existing engine so a future Windows implementation can replace the
//! adapters without forking CLI or IPC semantics.

const builtin = @import("builtin");

pub const daemon = @import("platform/daemon.zig");
pub const daemon_native = if (builtin.os.tag == .windows)
    @import("platform/daemon_windows.zig")
else
    @import("platform/daemon.zig");
pub const events = @import("platform/events.zig");
pub const events_posix = if (builtin.os.tag == .windows)
    @import("platform/events.zig")
else
    @import("platform/events_posix.zig");
pub const events_native = if (builtin.os.tag == .windows)
    @import("platform/events_windows.zig")
else
    @import("platform/events_posix.zig");
pub const ipc = @import("platform/local_ipc.zig");
pub const ipc_posix = if (builtin.os.tag == .windows)
    @import("platform/local_ipc.zig")
else
    @import("platform/local_ipc_posix.zig");
pub const ipc_native = if (builtin.os.tag == .windows)
    @import("platform/local_ipc_windows.zig")
else
    @import("platform/local_ipc_posix.zig");
pub const pty = @import("platform/pty.zig");
pub const pty_posix = if (builtin.os.tag == .windows)
    @import("platform/pty.zig")
else
    @import("platform/pty_posix.zig");
pub const resize = @import("platform/resize.zig");
pub const runtime = @import("platform/runtime.zig");
pub const runtime_posix = if (builtin.os.tag == .windows)
    @import("platform/runtime.zig")
else
    @import("platform/runtime_posix.zig");
pub const runtime_native = if (builtin.os.tag == .windows)
    @import("platform/runtime_windows.zig")
else
    @import("platform/runtime_posix.zig");
pub const shell = @import("platform/shell.zig");
pub const session_wire = @import("platform/session_wire.zig");
pub const session_native = if (builtin.os.tag == .windows)
    @import("platform/session_windows.zig")
else
    @import("platform/session_wire.zig");
