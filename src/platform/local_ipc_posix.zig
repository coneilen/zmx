const posix = @import("../posix.zig");
const local_ipc = @import("local_ipc.zig");

/// POSIX's fd is adapted to the opaque local IPC handle.  No wire framing is
/// implemented here; callers continue to use `src/ipc.zig`.
pub fn handle(value: posix.fd_t) local_ipc.Handle {
    return @intCast(value);
}

pub fn fd(value: local_ipc.Handle) posix.fd_t {
    return @intCast(value);
}

pub fn connection(fd_value: posix.fd_t) local_ipc.Connection {
    return .{
        .handle = handle(fd_value),
        .close_fn = closeHandle,
    };
}

pub fn connectUnix(path: []const u8) !posix.socket_t {
    var address = try posix.initUnix(path);
    const socket_fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(socket_fd);
    try posix.connect(socket_fd, &address.any, address.getOsSockLen());
    return socket_fd;
}

pub fn listenUnix(path: []const u8) !posix.socket_t {
    const socket_fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(socket_fd);

    var address = try posix.initUnix(path);
    try posix.bind(socket_fd, &address.any, address.getOsSockLen());
    try posix.listen(socket_fd, 128);
    return socket_fd;
}

fn closeHandle(value: local_ipc.Handle) void {
    posix.close(fd(value));
}

pub const Adapter = struct {
    pub fn close(connection_value: local_ipc.Connection) void {
        connection_value.close();
    }
};
