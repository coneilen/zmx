# Platform module ownership

The platform namespace describes operating-system responsibilities without
duplicating zmx's CLI, session, or IPC wire semantics.

| Module | Owns | Future implementation |
| --- | --- | --- |
| `platform/pty.zig` | PTY/process spawn, write, resize, signal, reap contracts | `win-zmx-conpty` |
| `platform/pty_posix.zig` | POSIX fd/PTY handle adaptation and resize ioctl | Existing `forkpty` adapter |
| `platform/local_ipc.zig` | Local byte-stream client/listener and access policy contracts | `local_ipc_windows.zig` named-pipe adapter |
| `platform/local_ipc_posix.zig` | POSIX fd adaptation for local IPC | Existing Unix-domain socket adapter |
| `platform/events.zig` | Wait readiness and cancellation vocabulary | `events_posix.zig` and `events_windows.zig` adapters |
| `platform/resize.zig` | Window dimensions and control-event vocabulary | ConPTY resize/control adapter |
| `platform/runtime.zig` | Strict endpoint-name validation, endpoint path safety, permissions | `runtime_windows.zig` Windows runtime policy |
| `platform/runtime_posix.zig` | POSIX runtime directories and Unix-socket-compatible name validation | Existing POSIX runtime adapter |
| `platform/daemon.zig` | Daemon lifetime state and process-role outcomes | `daemon_windows.zig` single-session lifetime adapter |
| `platform/shell.zig` | Interactive/task shell selection and task marker shape | ConPTY task-shell adapter |

`src/ipc.zig` remains the sole owner of zmx wire framing and tags. The
platform local-IPC contract transports bytes but must never introduce a second
protocol. `src/loop.zig` remains the owner of session leadership, mouse/input
classification, terminal replay, and task completion state.

## Windows IPC policy

`local_ipc_windows.zig` uses byte-mode overlapped named pipes. The first
server instance is created with `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a second
daemon cannot replace a live session. Each pipe uses an owner-only DACL
(`D:P(A;;GA;;;OW)(A;;GA;;;SY)`) and rejects remote clients; the pipe name is
also scoped below the current Windows account name. Pipe objects disappear
when their last handle closes, so stale endpoint files do not need deletion.
`events_windows.zig` waits on overlapped completion events plus a manual-reset
cancellation event and applies one cumulative deadline to an operation.
