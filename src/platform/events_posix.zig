const posix = @import("../posix.zig");
const events = @import("events.zig");
const std = @import("std");

pub const Poller = struct {
    pub fn waiter(self: *Poller) events.Waiter {
        return .{
            .context = self,
            .wait_fn = waitThunk,
        };
    }
};

/// Compatibility adapter for existing loops that need all poll revents in one
/// pass. The contract-level `Poller` above is the future Windows-facing API;
/// this helper keeps the POSIX engine's current behavior byte-for-byte.
pub fn poll(fds: []posix.pollfd, timeout_ms: i32) !usize {
    return posix.poll(fds, timeout_ms);
}

fn waitThunk(_: *anyopaque, watches: []const events.Watch, timeout_ms: ?u32) events.Error!events.Result {
    if (watches.len == 0) return error.InvalidHandle;

    var poll_fds: [64]posix.pollfd = undefined;
    if (watches.len > poll_fds.len) return error.SystemResources;

    for (watches, 0..) |watch, i| {
        poll_fds[i] = .{
            .fd = @intCast(watch.handle),
            .events = interestToPoll(watch.interest),
            .revents = 0,
        };
    }

    const timeout: i32 = if (timeout_ms) |value|
        @intCast(@min(value, std.math.maxInt(i32)))
    else
        -1;
    const count = posix.poll(poll_fds[0..watches.len], timeout) catch return error.SystemResources;
    if (count == 0) return error.Timeout;

    for (poll_fds[0..watches.len], 0..) |poll_fd, i| {
        const ready = readyFromPoll(poll_fd.revents);
        if (ready.read or ready.write or ready.err or ready.hangup) {
            return .{ .index = i, .ready = ready };
        }
    }
    return error.Timeout;
}

fn interestToPoll(interest: events.Interest) i16 {
    var result: i16 = 0;
    if (interest.read) result |= posix.POLL.IN;
    if (interest.write) result |= posix.POLL.OUT;
    return result;
}

fn readyFromPoll(revents: i16) events.Ready {
    return events.readyFromBits(
        revents & posix.POLL.IN != 0,
        revents & posix.POLL.OUT != 0,
        revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0,
        revents & posix.POLL.HUP != 0,
    );
}

pub fn openCancellationPipe() ![2]posix.fd_t {
    return posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainCancellationPipe(fds: [2]posix.fd_t) void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = posix.read(fds[0], &b) catch return;
        if (n == 0) return;
    }
}

pub fn wakeCancellationPipe(fds: [2]posix.fd_t) void {
    _ = posix.write(fds[1], "x") catch {};
}

test "POSIX cancellation adapter can represent an unopened pipe" {
    const unopened: [2]posix.fd_t = std.mem.zeroes([2]posix.fd_t);
    _ = unopened;
}
