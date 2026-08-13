const resize_contract = @import("resize.zig");
const shell = @import("shell.zig");

pub const Handle = usize;
pub const ProcessId = i64;

pub const SpawnSpec = struct {
    session_name: []const u8,
    shell: []const u8,
    task_mode: bool,
    command: ?[]const []const u8,
    size: resize_contract.Size,
};

pub const Spawned = struct {
    master: Handle,
    process: ProcessId,
};

pub const Signal = enum {
    hangup,
    terminate,
    kill,
    resize,
};

/// PTY implementations own the terminal/process primitive only.  Shell
/// command construction is kept in `platform/shell.zig`.
pub const Backend = struct {
    context: *anyopaque,
    spawn_fn: *const fn (*anyopaque, SpawnSpec) anyerror!Spawned,
    write_fn: *const fn (*anyopaque, Handle, []const u8) anyerror!usize,
    resize_fn: *const fn (*anyopaque, Handle, resize_contract.Size) anyerror!void,
    signal_fn: *const fn (*anyopaque, ProcessId, Signal) anyerror!void,
    close_fn: *const fn (*anyopaque, Handle) void,
    reap_fn: *const fn (*anyopaque, ProcessId) void,

    pub fn spawn(self: Backend, spec: SpawnSpec) !Spawned {
        return self.spawn_fn(self.context, spec);
    }

    pub fn write(self: Backend, handle: Handle, bytes: []const u8) !usize {
        return self.write_fn(self.context, handle, bytes);
    }

    pub fn resize(self: Backend, handle: Handle, size: resize_contract.Size) !void {
        return self.resize_fn(self.context, handle, size);
    }

    pub fn signal(self: Backend, process: ProcessId, value: Signal) !void {
        return self.signal_fn(self.context, process, value);
    }

    pub fn close(self: Backend, handle: Handle) void {
        self.close_fn(self.context, handle);
    }

    pub fn reap(self: Backend, process: ProcessId) void {
        self.reap_fn(self.context, process);
    }
};

pub fn commandSpec(spec: SpawnSpec) shell.Spec {
    return .{
        .default_shell = spec.shell,
        .task_mode = spec.task_mode,
        .command = spec.command,
    };
}
