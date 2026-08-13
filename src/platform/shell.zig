const std = @import("std");

pub const Spec = struct {
    default_shell: []const u8,
    task_mode: bool,
    command: ?[]const []const u8,
};

pub const Cmd = struct {
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
};

pub const Mode = enum {
    interactive,
    task,
};

pub fn mode(spec: Spec) Mode {
    return if (spec.task_mode) .task else .interactive;
}

/// Task mode intentionally keeps bash semantics from the existing POSIX
/// implementation.  A future Windows shell adapter can choose its executable
/// without changing task/session wire messages.
pub fn executable(spec: Spec) []const u8 {
    return if (spec.task_mode) "bash" else spec.default_shell;
}

pub fn argv0(spec: Spec, buffer: []u8) ![]const u8 {
    const shell = executable(spec);
    const base = std.fs.path.basename(shell);
    if (buffer.len < base.len + 1) return error.NoSpaceLeft;
    buffer[0] = '-';
    @memcpy(buffer[1 .. base.len + 1], base);
    return buffer[0 .. base.len + 1];
}

pub fn taskMarker(buffer: []u8, task_id: [4]u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "ZMX_TASK_COMPLETED:{s}:", .{task_id});
}

/// Build the argv shape used by both POSIX fork/exec and a future native
/// process adapter.  The caller intentionally owns this only until exec.
pub fn createCmdZ(
    def_shell: []const u8,
    task_mode: bool,
    command: ?[]const []const u8,
) !Cmd {
    const gpa = std.heap.c_allocator;

    if (command) |cmd_args| {
        const argv = try gpa.allocSentinel(?[*:0]const u8, cmd_args.len, null);
        for (cmd_args, 0..) |arg, i| {
            argv[i] = try gpa.dupeZ(u8, arg);
        }
        return .{
            .file = argv[0].?,
            .argv_ptr = argv.ptr,
        };
    }

    const z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{executable(.{
        .default_shell = def_shell,
        .task_mode = task_mode,
        .command = null,
    })}, 0);
    const login_shell = try std.fmt.allocPrintSentinel(
        gpa,
        "-{s}",
        .{std.fs.path.basename(z)},
        0,
    );
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = login_shell.ptr;

    return .{
        .file = z,
        .argv_ptr = argv.ptr,
    };
}

test "shell contract preserves interactive login argv0 and task bash" {
    const interactive = Spec{
        .default_shell = "/bin/zsh",
        .task_mode = false,
        .command = null,
    };
    try std.testing.expectEqual(Mode.interactive, mode(interactive));
    try std.testing.expectEqualStrings("/bin/zsh", executable(interactive));
    var argv_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-zsh", try argv0(interactive, &argv_buf));

    const task = Spec{
        .default_shell = "/bin/zsh",
        .task_mode = true,
        .command = null,
    };
    try std.testing.expectEqual(Mode.task, mode(task));
    try std.testing.expectEqualStrings("bash", executable(task));
}

test "task marker is stable and does not alter wire framing" {
    var buffer: [64]u8 = undefined;
    const marker = try taskMarker(&buffer, .{ '0', '1', '0', '2' });
    try std.testing.expectEqualStrings("ZMX_TASK_COMPLETED:0102:", marker);
}
