const std = @import("std");

/// The lifecycle states shared by POSIX double-fork and future Windows
/// daemon implementations.  The state machine is intentionally independent
/// of the session wire protocol.
pub const State = enum {
    creating,
    running,
    stopping,
    stopped,
};

pub const StopReason = enum {
    requested,
    child_exited,
    signal,
    startup_failed,
};

pub const Lifetime = struct {
    state: State = .creating,
    reason: ?StopReason = null,

    pub fn started(self: *Lifetime) void {
        self.state = .running;
        self.reason = null;
    }

    pub fn stop(self: *Lifetime, reason: StopReason) void {
        if (self.state == .stopped) return;
        self.state = .stopping;
        self.reason = reason;
    }

    pub fn stopped(self: *Lifetime) void {
        self.state = .stopped;
    }

    pub fn isRunning(self: Lifetime) bool {
        return self.state == .running;
    }
};

pub const ProcessRole = enum {
    client,
    daemon,
};

pub const StartResult = struct {
    role: ProcessRole,
};

/// A backend owns process detachment, shutdown signalling, and reaping.  A
/// backend must not own session names, wire tags, or client leadership.
pub const Backend = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque) anyerror!StartResult,
    stop_fn: *const fn (*anyopaque, StopReason) void,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn start(self: Backend) !StartResult {
        return self.start_fn(self.context);
    }

    pub fn stop(self: Backend, reason: StopReason) void {
        self.stop_fn(self.context, reason);
    }

    pub fn deinit(self: Backend) void {
        self.deinit_fn(self.context);
    }
};

test "lifetime records the daemon stop reason" {
    var lifetime = Lifetime{};
    try std.testing.expectEqual(State.creating, lifetime.state);
    lifetime.started();
    try std.testing.expect(lifetime.isRunning());
    lifetime.stop(.child_exited);
    try std.testing.expectEqual(State.stopping, lifetime.state);
    try std.testing.expectEqual(StopReason.child_exited, lifetime.reason.?);
    lifetime.stopped();
    try std.testing.expectEqual(State.stopped, lifetime.state);
}
