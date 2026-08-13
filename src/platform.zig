//! Platform contracts used by zmx's session engine.
//!
//! The contracts in this namespace deliberately do not contain wire-protocol
//! tags or session state.  They describe the operating-system work needed by
//! the existing engine so a future Windows implementation can replace the
//! adapters without forking CLI or IPC semantics.

pub const daemon = @import("platform/daemon.zig");
pub const events = @import("platform/events.zig");
pub const events_posix = @import("platform/events_posix.zig");
pub const ipc = @import("platform/local_ipc.zig");
pub const ipc_posix = @import("platform/local_ipc_posix.zig");
pub const pty = @import("platform/pty.zig");
pub const pty_posix = @import("platform/pty_posix.zig");
pub const pty_windows = @import("platform/pty_windows.zig");
pub const resize = @import("platform/resize.zig");
pub const runtime = @import("platform/runtime.zig");
pub const runtime_posix = @import("platform/runtime_posix.zig");
pub const shell = @import("platform/shell.zig");
