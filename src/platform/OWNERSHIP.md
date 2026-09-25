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
| `platform/session_wire.zig` | Target-neutral frozen Windows session frame/tag contract | Shared with the ConPTY provider |
| `platform/session_windows.zig` | Windows host/attach lifecycle, complete tag dispatch, and transport I/O exports | Sibling ConPTY/session provider |

`src/ipc.zig` remains the sole owner of zmx wire framing and tags. The
platform local-IPC contract transports bytes but must never introduce a second
protocol. `src/loop.zig` remains the owner of session leadership, mouse/input
classification, terminal replay, and task completion state.

## Windows IPC policy

`local_ipc_windows.zig` uses byte-mode overlapped named pipes. The first
server instance is created with `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a second
daemon cannot replace a live session. Each pipe uses an owner-only DACL
(`D:P(A;;GA;;;OW)(A;;GA;;;SY)`) and rejects remote clients; the pipe name is
also scoped below the current token's user SID. Clients compare the connected
server process token SID with their own before accepting a connection. Server
close serializes with posting each `ConnectNamedPipe`, cancels posted
overlapped accepts, and waits for all in-flight accept state before releasing
the pipe/listener state. The small copied-server control tombstone is retained
after close so a late copied handle cannot become a use-after-free; all kernel
handles are released. New session listeners hold an exclusive per-session
filesystem lease across rendezvous check, nonce listener creation, publish,
and recheck, so concurrent processes produce one daemon. The lease is a
Windows file lock and is reusable after a crashed owner. Session endpoints use
a random nonce published in an owner-profile rendezvous record, allowing
recovery when a predictable legacy pipe name was pre-created. Clients verify
the connected server token SID before using a published endpoint. Pipe objects
disappear when their last handle closes; a server removes its owned endpoint
record before releasing the session lease, while replacement records are
preserved by an ownership comparison. Lease files remain at one stable path
and only their exclusive byte-range lock is released, preventing a
release/reacquire race from splitting ownership across file identities.
Readiness clients may connect and close before ConPTY starts accepting.
`ERROR_NO_DATA`/`ERROR_BROKEN_PIPE` from that accept is a transient peer
disconnect, not a reason to destroy the session. Once the operation settles,
the listener disconnects and rearms the same pipe instance. Timeout/cancellation
recovery creates the next instance before closing the previous one, preserving
connect-before-accept behavior without briefly removing the endpoint. Shutdown
remains serialized with recovery, and recovery failures propagate to the
caller. An idle retry blocks in the next overlapped accept.
`ERROR_SEM_TIMEOUT` and `ERROR_PIPE_BUSY` from a named-pipe probe mean that
the endpoint is live or busy and must never trigger stale-record deletion.
`events_windows.zig` waits on overlapped completion events plus a manual-reset
cancellation event and applies one cumulative deadline to an operation.
`local_ipc.Connection.writeAll` is the bounded backpressure primitive for
ConPTY/session adapters; it loops on partial transport writes and never
truncates a large frame to a fixed queue size.
`session_windows.serveConnectionsWithOptions` accepts continuously and
dispatches each client on an independent worker. A client deadline is
cumulative across its frames, and listener shutdown cancels and joins all
active reads so a stalled peer cannot block another client or retain a
handle. Worker publication sets the thread handle before marking a worker
reapable, and completion signals a blocking reaper event rather than polling
or yielding on an idle CPU.
`session_windows.zig` exposes the same connection/server handles, deadline and
cancellation types, bounded read/write functions, host/attach lifecycle, and
all frozen wire-tag dispatch to the sibling ConPTY provider. Until that
provider is linked, Windows `run` and `attach` take this production path and
return an explicit `ConPtyProviderUnavailable` error rather than silently
falling back to a send-only implementation.
Filesystem rendezvous directories and lease/record files are created with a
protected DACL containing only the current token SID and SYSTEM. Existing
objects are verified for owner, protected DACL, ACE type/mask, and exact
current-user/SYSTEM membership; insecure preexisting objects are rejected.
Rendezvous records are UTF-8 bounded by the maximum valid UTF-16 pipe path and
oversized, truncated, or malformed records are rejected. Windows `list`
enumerates only verified SID-scoped records without requiring a session; the
`get`, `history`, and `info` commands perform bounded response round trips.
When `LOCALAPPDATA` is unavailable, runtime logs and rendezvous metadata fall
back to `USERPROFILE`, `TEMP`/`TMP`, or `GetTempPathW`; they never use the
named-pipe namespace as a filesystem path.
Bare Windows invocation follows POSIX behavior by listing sessions. Session
targeting accepts `.` and resolves it, or an omitted response-command target,
from `ZMX_SESSION` where the CLI contract permits a current session.
