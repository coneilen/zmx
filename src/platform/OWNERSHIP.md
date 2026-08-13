# Platform module ownership

The platform namespace describes operating-system responsibilities without
duplicating zmx's CLI, session, or IPC wire semantics.

| Module | Owns | Future implementation |
| --- | --- | --- |
| `platform/pty.zig` | PTY/process spawn, write, resize, signal, reap contracts | `win-zmx-conpty` |
| `platform/pty_posix.zig` | POSIX fd/PTY handle adaptation and resize ioctl | Existing `forkpty` adapter |
| `platform/local_ipc.zig` | Local byte-stream client/listener and access policy contracts | `win-zmx-ipc` named-pipe adapter |
| `platform/local_ipc_posix.zig` | POSIX fd adaptation for local IPC | Existing Unix-domain socket adapter |
| `platform/events.zig` | Wait readiness and cancellation vocabulary | `poll`/self-pipe and IOCP adapters |
| `platform/resize.zig` | Window dimensions and control-event vocabulary | ConPTY resize/control adapter |
| `platform/runtime.zig` | Session-component validation, endpoint path safety, permissions | Windows runtime-directory policy |
| `platform/daemon.zig` | Daemon lifetime state and process-role outcomes | POSIX double-fork and Windows lifetime adapter |
| `platform/shell.zig` | Interactive/task shell selection and task marker shape | ConPTY task-shell adapter |

`src/ipc.zig` remains the sole owner of zmx wire framing and tags. The
platform local-IPC contract transports bytes but must never introduce a second
protocol. `src/loop.zig` remains the owner of session leadership, mouse/input
classification, terminal replay, and task completion state.
