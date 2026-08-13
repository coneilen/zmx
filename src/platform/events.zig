const std = @import("std");

/// Handles are deliberately opaque to the contract.  POSIX adapters store an
/// fd here; Windows adapters may store a HANDLE or an event object.
pub const Handle = usize;

pub const Interest = packed struct {
    read: bool = false,
    write: bool = false,
    err: bool = false,
    hangup: bool = false,
    _: u4 = 0,
};

pub const Ready = packed struct {
    read: bool = false,
    write: bool = false,
    err: bool = false,
    hangup: bool = false,
    _: u4 = 0,
};

pub const Watch = struct {
    handle: Handle,
    interest: Interest,
};

pub const Result = struct {
    index: usize,
    ready: Ready,
};

pub const Error = error{
    Timeout,
    Cancelled,
    InvalidHandle,
    SystemResources,
} || std.mem.Allocator.Error;

/// A wait backend is the only abstraction needed by the event loops.  It
/// allows poll/select, IOCP, or a named-pipe wait strategy to present the same
/// readiness and cancellation vocabulary.
pub const Waiter = struct {
    context: *anyopaque,
    wait_fn: *const fn (*anyopaque, []const Watch, ?u32) Error!Result,

    pub fn wait(self: Waiter, watches: []const Watch, timeout_ms: ?u32) Error!Result {
        return self.wait_fn(self.context, watches, timeout_ms);
    }
};

pub const Cancellation = struct {
    context: *anyopaque,
    is_cancelled_fn: *const fn (*anyopaque) bool,
    reset_fn: *const fn (*anyopaque) void,

    pub fn isCancelled(self: Cancellation) bool {
        return self.is_cancelled_fn(self.context);
    }

    pub fn reset(self: Cancellation) void {
        self.reset_fn(self.context);
    }
};

pub fn readyFromBits(read: bool, write: bool, err: bool, hangup: bool) Ready {
    return .{ .read = read, .write = write, .err = err, .hangup = hangup };
}

test "event contracts preserve independent readiness bits" {
    const ready = readyFromBits(true, false, true, false);
    try std.testing.expect(ready.read);
    try std.testing.expect(!ready.write);
    try std.testing.expect(ready.err);
    try std.testing.expect(!ready.hangup);
}
