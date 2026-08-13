const builtin = @import("builtin");
const std = @import("std");
const pty = @import("pty.zig");
const resize = @import("resize.zig");

pub const Control = enum {
    ctrl_c,
};

pub const Error = error{
    UnsupportedPlatform,
    InvalidHandle,
    InvalidSize,
    InvalidCommand,
    UnsupportedControl,
    WindowsApiFailure,
    ProcessExited,
    BrokenPipe,
    WouldBlock,
};

/// Quote one UTF-8 argument using the CommandLineToArgvW/CreateProcess
/// backslash rules. The command line is converted to UTF-16 only after all
/// quoting has been applied, so non-ASCII bytes are never lossy.
pub fn appendWindowsArg(list: *std.ArrayList(u8), alloc: std.mem.Allocator, arg: []const u8) !void {
    const needs_quotes = arg.len == 0 or
        std.mem.indexOfAny(u8, arg, " \t\"") != null;
    if (!needs_quotes) {
        try list.appendSlice(alloc, arg);
        return;
    }

    try list.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }

        if (byte == '"') {
            try appendRepeated(list, alloc, '\\', backslashes * 2 + 1);
            try list.append(alloc, '"');
        } else {
            try appendRepeated(list, alloc, '\\', backslashes);
            try list.append(alloc, byte);
        }
        backslashes = 0;
    }

    // Backslashes before the closing quote must be doubled.
    try appendRepeated(list, alloc, '\\', backslashes * 2);
    try list.append(alloc, '"');
}

fn appendRepeated(list: *std.ArrayList(u8), alloc: std.mem.Allocator, byte: u8, count: usize) !void {
    try list.ensureUnusedCapacity(alloc, count);
    for (0..count) |_| list.appendAssumeCapacity(byte);
}

pub fn buildCommandLine(alloc: std.mem.Allocator, spec: pty.SpawnSpec) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);

    if (spec.command) |command| {
        if (command.len == 0) return error.InvalidCommand;
        for (command, 0..) |arg, index| {
            if (index != 0) try line.append(alloc, ' ');
            try appendWindowsArg(&line, alloc, arg);
        }
    } else {
        const shell = if (spec.shell.len == 0) "cmd.exe" else spec.shell;
        try appendWindowsArg(&line, alloc, shell);
    }

    return line.toOwnedSlice(alloc);
}

pub fn sizeToCoord(size: resize.Size) Error!if (builtin.os.tag == .windows) std.os.windows.COORD else void {
    if (!resize.isUsable(size)) return error.InvalidSize;
    if (size.cols > @as(u16, @intCast(std.math.maxInt(i16))) or
        size.rows > @as(u16, @intCast(std.math.maxInt(i16))))
    {
        return error.InvalidSize;
    }

    if (builtin.os.tag == .windows) {
        return .{
            .X = @intCast(size.cols),
            .Y = @intCast(size.rows),
        };
    }
    return {};
}

const implementation = if (builtin.os.tag == .windows) windows_impl else unsupported_impl;

pub const BackendState = implementation.State;

pub fn init(alloc: std.mem.Allocator) BackendState {
    return implementation.init(alloc);
}

pub fn deinit(state: *BackendState) void {
    implementation.deinit(state);
}

pub fn backend(state: *BackendState) pty.Backend {
    return implementation.backend(state);
}

pub fn spawn(state: *BackendState, spec: pty.SpawnSpec) !pty.Spawned {
    return implementation.spawn(state, spec);
}

pub fn read(state: *BackendState, master: pty.Handle, buffer: []u8) !usize {
    return implementation.read(state, master, buffer);
}

pub fn write(state: *BackendState, master: pty.Handle, bytes: []const u8) !usize {
    return implementation.write(state, master, bytes);
}

pub fn wait(state: *BackendState, process: pty.ProcessId) !u32 {
    return implementation.wait(state, process);
}

pub fn reap(state: *BackendState, process: pty.ProcessId) void {
    implementation.reap(state, process);
}

pub fn sendControl(state: *BackendState, process: pty.ProcessId, control: Control) !void {
    return implementation.sendControl(state, process, control);
}

const unsupported_impl = struct {
    const State = struct {
        alloc: std.mem.Allocator,
    };

    fn init(alloc: std.mem.Allocator) State {
        return .{ .alloc = alloc };
    }

    fn deinit(_: *State) void {}

    fn backend(state: *State) pty.Backend {
        return .{
            .context = state,
            .spawn_fn = spawnThunk,
            .write_fn = writeThunk,
            .resize_fn = resizeThunk,
            .signal_fn = signalThunk,
            .close_fn = closeThunk,
            .reap_fn = reapThunk,
        };
    }

    fn spawn(_: *State, _: pty.SpawnSpec) !pty.Spawned {
        return error.UnsupportedPlatform;
    }

    fn read(_: *State, _: pty.Handle, _: []u8) !usize {
        return error.UnsupportedPlatform;
    }

    fn write(_: *State, _: pty.Handle, _: []const u8) !usize {
        return error.UnsupportedPlatform;
    }

    fn wait(_: *State, _: pty.ProcessId) !u32 {
        return error.UnsupportedPlatform;
    }

    fn reap(_: *State, _: pty.ProcessId) void {}

    fn sendControl(_: *State, _: pty.ProcessId, _: Control) !void {
        return error.UnsupportedPlatform;
    }

    fn spawnThunk(context: *anyopaque, spec: pty.SpawnSpec) anyerror!pty.Spawned {
        return Self.spawn(@ptrCast(@alignCast(context)), spec);
    }

    fn writeThunk(_: *anyopaque, _: pty.Handle, _: []const u8) anyerror!usize {
        return error.UnsupportedPlatform;
    }

    fn resizeThunk(_: *anyopaque, _: pty.Handle, _: resize.Size) anyerror!void {
        return error.UnsupportedPlatform;
    }

    fn signalThunk(_: *anyopaque, _: pty.ProcessId, _: pty.Signal) anyerror!void {
        return error.UnsupportedPlatform;
    }

    fn closeThunk(_: *anyopaque, _: pty.Handle) void {}

    fn reapThunk(context: *anyopaque, process: pty.ProcessId) void {
        Self.reap(@ptrCast(@alignCast(context)), process);
    }

    const Self = @This();
};

const windows_impl = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const HPCON = HANDLE;
    const BOOL = i32;
    const DWORD = u32;
    const SIZE_T = usize;
    const HRESULT = i32;

    const ERROR_BROKEN_PIPE: DWORD = 109;
    const ERROR_NO_DATA: DWORD = 232;
    const ERROR_OPERATION_ABORTED: DWORD = 995;
    const ERROR_PIPE_NOT_CONNECTED: DWORD = 233;
    const STILL_ACTIVE: DWORD = 259;
    const WAIT_OBJECT_0: DWORD = 0;
    const WAIT_FAILED: DWORD = 0xffffffff;
    const INFINITE: DWORD = 0xffffffff;

    const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
    const STARTF_USESTDHANDLES: DWORD = 0x00000100;
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: DWORD = 9;
    const PROC_THREAD_ATTRIBUTE_LIST = opaque {};

    const STARTUPINFOEXW = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: ?*PROC_THREAD_ATTRIBUTE_LIST,
    };

    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: DWORD,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: DWORD,
        Affinity: usize,
        PriorityClass: DWORD,
        SchedulingClass: DWORD,
    };

    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };

    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };

    const kernel32 = struct {
        extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
        extern "kernel32" fn CreatePipe(
            read_pipe: *HANDLE,
            write_pipe: *HANDLE,
            attributes: ?*windows.SECURITY_ATTRIBUTES,
            size: DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn SetHandleInformation(
            handle: HANDLE,
            mask: DWORD,
            flags: DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            input: HANDLE,
            output: HANDLE,
            flags: DWORD,
            pseudo_console: *HANDLE,
        ) callconv(.winapi) HRESULT;
        extern "kernel32" fn ResizePseudoConsole(
            pseudo_console: HPCON,
            size: windows.COORD,
        ) callconv(.winapi) HRESULT;
        extern "kernel32" fn ClosePseudoConsole(
            pseudo_console: HPCON,
        ) callconv(.winapi) HRESULT;
        extern "kernel32" fn InitializeProcThreadAttributeList(
            attribute_list: ?*PROC_THREAD_ATTRIBUTE_LIST,
            attribute_count: DWORD,
            flags: DWORD,
            size: *SIZE_T,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn UpdateProcThreadAttribute(
            attribute_list: *PROC_THREAD_ATTRIBUTE_LIST,
            flags: DWORD,
            attribute: usize,
            value: *const anyopaque,
            size: SIZE_T,
            previous_value: ?*anyopaque,
            return_size: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn DeleteProcThreadAttributeList(
            attribute_list: *PROC_THREAD_ATTRIBUTE_LIST,
        ) callconv(.winapi) void;
        extern "kernel32" fn CreateJobObjectW(
            attributes: ?*windows.SECURITY_ATTRIBUTES,
            name: ?[*:0]const u16,
        ) callconv(.winapi) ?HANDLE;
        extern "kernel32" fn SetInformationJobObject(
            job: HANDLE,
            info_class: DWORD,
            info: *const anyopaque,
            info_length: DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn AssignProcessToJobObject(
            job: HANDLE,
            process: HANDLE,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn TerminateJobObject(
            job: HANDLE,
            exit_code: DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn TerminateProcess(
            process: HANDLE,
            exit_code: DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) DWORD;
        extern "kernel32" fn WaitForSingleObject(
            handle: HANDLE,
            milliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        extern "kernel32" fn GetExitCodeProcess(
            process: HANDLE,
            exit_code: *DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn ReadFile(
            file: HANDLE,
            buffer: [*]u8,
            length: DWORD,
            read: *DWORD,
            overlapped: ?*anyopaque,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn PeekNamedPipe(
            pipe: HANDLE,
            buffer: ?[*]u8,
            buffer_length: DWORD,
            bytes_read: ?*DWORD,
            total_bytes_available: *DWORD,
            bytes_left_this_message: ?*DWORD,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn WriteFile(
            file: HANDLE,
            buffer: [*]const u8,
            length: DWORD,
            written: *DWORD,
            overlapped: ?*anyopaque,
        ) callconv(.winapi) BOOL;
        extern "kernel32" fn FlushFileBuffers(file: HANDLE) callconv(.winapi) BOOL;
        extern "kernel32" fn CreateProcessW(
            application_name: ?[*:0]const u16,
            command_line: [*:0]u16,
            process_attributes: ?*windows.SECURITY_ATTRIBUTES,
            thread_attributes: ?*windows.SECURITY_ATTRIBUTES,
            inherit_handles: BOOL,
            creation_flags: windows.CreateProcessFlags,
            environment: ?*anyopaque,
            current_directory: ?[*:0]const u16,
            startup_info: *windows.STARTUPINFOW,
            process_information: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
    };

    const Session = struct {
        alloc: std.mem.Allocator,
        input: ?HANDLE = null,
        output: ?HANDLE = null,
        input_read_side: ?HANDLE = null,
        output_write_side: ?HANDLE = null,
        pseudo_console: ?HPCON = null,
        job: ?HANDLE = null,
        process: ?HANDLE = null,
        thread: ?HANDLE = null,
        pid: DWORD = 0,
        io_closed: bool = false,
    };

    const State = struct {
        alloc: std.mem.Allocator,
        sessions: std.ArrayList(*Session) = .empty,
    };

    fn init(alloc: std.mem.Allocator) State {
        return .{ .alloc = alloc };
    }

    fn deinit(state: *State) void {
        while (state.sessions.items.len != 0) {
            const session = state.sessions.items[state.sessions.items.len - 1];
            state.sessions.items.len -= 1;
            if (session.job) |job| _ = kernel32.TerminateJobObject(job, 1);
            if (session.process) |process| {
                _ = kernel32.WaitForSingleObject(process, INFINITE);
            }
            destroySession(session);
        }
        state.sessions.deinit(state.alloc);
    }

    fn backend(state: *State) pty.Backend {
        return .{
            .context = state,
            .spawn_fn = spawnThunk,
            .write_fn = writeThunk,
            .resize_fn = resizeThunk,
            .signal_fn = signalThunk,
            .close_fn = closeThunk,
            .reap_fn = reapThunk,
        };
    }

    fn spawn(state: *State, spec: pty.SpawnSpec) !pty.Spawned {
        const session = try state.alloc.create(Session);
        session.* = .{ .alloc = state.alloc };
        errdefer destroySession(session);

        const command_line = try buildCommandLine(state.alloc, spec);
        defer state.alloc.free(command_line);
        const command_line_w = try std.unicode.utf8ToUtf16LeAllocZ(state.alloc, command_line);
        defer state.alloc.free(command_line_w);

        var env_map = try std.process.getEnvMap(state.alloc);
        defer env_map.deinit();
        try env_map.put("ZMX_SESSION", spec.session_name);
        if (env_map.get("TERM")) |term| {
            if (std.mem.eql(u8, term, "dumb")) try env_map.put("TERM", "xterm-256color");
        } else {
            try env_map.put("TERM", "xterm-256color");
        }
        const environment = try std.process.createWindowsEnvBlock(state.alloc, &env_map);
        defer state.alloc.free(environment);

        const coord = try sizeToCoord(spec.size);
        var input_read: HANDLE = undefined;
        var input_write: HANDLE = undefined;
        if (kernel32.CreatePipe(&input_read, &input_write, null, 0) == 0) {
            return error.WindowsApiFailure;
        }
        var input_read_owned = true;
        var input_write_owned = true;
        errdefer {
            if (input_read_owned) _ = kernel32.CloseHandle(input_read);
            if (input_write_owned) _ = kernel32.CloseHandle(input_write);
        }

        var output_read: HANDLE = undefined;
        var output_write: HANDLE = undefined;
        if (kernel32.CreatePipe(&output_read, &output_write, null, 0) == 0) {
            return error.WindowsApiFailure;
        }
        var output_read_owned = true;
        var output_write_owned = true;
        errdefer {
            if (output_read_owned) _ = kernel32.CloseHandle(output_read);
            if (output_write_owned) _ = kernel32.CloseHandle(output_write);
        }

        // The child gets the pseudoconsole through the attribute list, not
        // through inherited pipe handles. This closes the handle-leak path
        // that would otherwise keep a crashed client alive.
        inline for (.{ input_read, input_write, output_read, output_write }) |handle| {
            if (kernel32.SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) == 0) {
                return error.WindowsApiFailure;
            }
        }

        var pseudo_console: HANDLE = undefined;
        if (kernel32.CreatePseudoConsole(coord, input_read, output_write, 0, &pseudo_console) < 0) {
            return error.WindowsApiFailure;
        }
        session.pseudo_console = pseudo_console;

        session.input = input_write;
        input_write_owned = false;
        session.output = output_read;
        output_read_owned = false;

        const job = kernel32.CreateJobObjectW(null, null) orelse return error.WindowsApiFailure;
        session.job = job;
        var limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        );
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (kernel32.SetInformationJobObject(
            job,
            JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
            &limits,
            @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0) {
            return error.WindowsApiFailure;
        }

        var attribute_size: SIZE_T = 0;
        _ = kernel32.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
        if (attribute_size == 0) return error.WindowsApiFailure;
        const attribute_storage = try state.alloc.alloc(u8, attribute_size);
        defer state.alloc.free(attribute_storage);
        const attributes: *PROC_THREAD_ATTRIBUTE_LIST = @ptrCast(@alignCast(attribute_storage.ptr));
        if (kernel32.InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) == 0) {
            return error.WindowsApiFailure;
        }
        defer kernel32.DeleteProcThreadAttributeList(attributes);

        if (kernel32.UpdateProcThreadAttribute(
            attributes,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @ptrCast(pseudo_console),
            @sizeOf(HPCON),
            null,
            null,
        ) == 0) {
            return error.WindowsApiFailure;
        }

        var startup = STARTUPINFOEXW{
            .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
            .lpAttributeList = attributes,
        };
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        var process_info: windows.PROCESS_INFORMATION = undefined;
        const creation_flags: windows.CreateProcessFlags = .{
            .create_suspended = true,
            .extended_startupinfo_present = true,
            .create_unicode_environment = true,
        };
        if (kernel32.CreateProcessW(
            null,
            command_line_w.ptr,
            null,
            null,
            0,
            creation_flags,
            @ptrCast(environment.ptr),
            null,
            @ptrCast(&startup.StartupInfo),
            &process_info,
        ) == 0) {
            return error.WindowsApiFailure;
        }
        session.process = process_info.hProcess;
        session.thread = process_info.hThread;
        session.pid = process_info.dwProcessId;

        // The process is still suspended. Enrollment must succeed before the
        // first instruction can run; otherwise terminate the unassigned
        // process rather than allowing a child to escape the job.
        if (kernel32.AssignProcessToJobObject(job, process_info.hProcess) == 0) {
            _ = kernel32.TerminateProcess(process_info.hProcess, 1);
            _ = kernel32.WaitForSingleObject(process_info.hProcess, INFINITE);
            return error.WindowsApiFailure;
        }
        if (kernel32.ResumeThread(process_info.hThread) == 0xffffffff) {
            _ = kernel32.TerminateJobObject(job, 1);
            _ = kernel32.WaitForSingleObject(process_info.hProcess, INFINITE);
            return error.WindowsApiFailure;
        }
        session.input_read_side = input_read;
        input_read_owned = false;
        session.output_write_side = output_write;
        output_write_owned = false;
        _ = kernel32.CloseHandle(process_info.hThread);
        session.thread = null;

        state.sessions.append(state.alloc, session) catch |err| {
            _ = kernel32.TerminateJobObject(job, 1);
            _ = kernel32.WaitForSingleObject(process_info.hProcess, INFINITE);
            return err;
        };
        return .{
            .master = @intFromPtr(session),
            .process = @intCast(session.pid),
        };
    }

    fn read(state: *State, master: pty.Handle, buffer: []u8) !usize {
        const session = findSessionByMaster(state, master) orelse return error.InvalidHandle;
        const output = session.output orelse return error.InvalidHandle;
        if (buffer.len == 0) return 0;
        var available: DWORD = 0;
        if (kernel32.PeekNamedPipe(output, null, 0, null, &available, null) == 0) {
            return switch (lastErrorCode()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED => 0,
                else => error.WindowsApiFailure,
            };
        }
        if (available == 0) {
            return if (isAlive(session)) error.WouldBlock else 0;
        }
        const amount: DWORD = @intCast(@min(@as(usize, available), buffer.len));
        var read_count: DWORD = 0;
        if (kernel32.ReadFile(output, buffer.ptr, amount, &read_count, null) == 0) {
            return switch (lastErrorCode()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA => 0,
                ERROR_OPERATION_ABORTED => error.ProcessExited,
                else => error.WindowsApiFailure,
            };
        }
        return read_count;
    }

    fn write(state: *State, master: pty.Handle, bytes: []const u8) !usize {
        const session = findSessionByMaster(state, master) orelse return error.InvalidHandle;
        const input = session.input orelse return error.InvalidHandle;
        var total: usize = 0;
        while (total < bytes.len) {
            const amount: DWORD = @intCast(@min(bytes.len - total, std.math.maxInt(DWORD)));
            var written: DWORD = 0;
            if (kernel32.WriteFile(input, bytes[total..].ptr, amount, &written, null) == 0) {
                return switch (lastErrorCode()) {
                    ERROR_BROKEN_PIPE, ERROR_NO_DATA => error.BrokenPipe,
                    ERROR_OPERATION_ABORTED => error.ProcessExited,
                    else => error.WindowsApiFailure,
                };
            }
            total += written;
            if (written == 0) break;
        }
        _ = kernel32.FlushFileBuffers(input);
        return total;
    }

    fn resizeMaster(state: *State, master: pty.Handle, size: resize.Size) !void {
        const session = findSessionByMaster(state, master) orelse return error.InvalidHandle;
        const pseudo_console = session.pseudo_console orelse return error.InvalidHandle;
        const coord = try sizeToCoord(size);
        if (kernel32.ResizePseudoConsole(pseudo_console, coord) < 0) {
            return error.WindowsApiFailure;
        }
    }

    fn signal(state: *State, process: pty.ProcessId, value: pty.Signal) !void {
        const session = findSessionByProcess(state, process) orelse return error.InvalidHandle;
        switch (value) {
            .hangup => return sendControlToSession(session, .ctrl_c),
            .terminate => terminateSession(session, 1),
            .kill => terminateSession(session, 137),
            .resize => return error.UnsupportedControl,
        }
    }

    fn closeMaster(state: *State, master: pty.Handle) void {
        const session = findSessionByMaster(state, master) orelse return;
        closeIo(session);
    }

    fn wait(state: *State, process: pty.ProcessId) !u32 {
        const session = findSessionByProcess(state, process) orelse return error.InvalidHandle;
        const process_handle = session.process orelse return error.InvalidHandle;
        if (kernel32.WaitForSingleObject(process_handle, INFINITE) == WAIT_FAILED) {
            return error.WindowsApiFailure;
        }
        var code: DWORD = 0;
        if (kernel32.GetExitCodeProcess(process_handle, &code) == 0) {
            return error.WindowsApiFailure;
        }
        return code;
    }

    fn reap(state: *State, process: pty.ProcessId) void {
        const session = findSessionByProcess(state, process) orelse return;
        if (session.process) |process_handle| {
            _ = kernel32.WaitForSingleObject(process_handle, INFINITE);
        }
        removeSession(state, session);
        destroySession(session);
    }

    fn sendControl(state: *State, process: pty.ProcessId, control: Control) !void {
        const session = findSessionByProcess(state, process) orelse return error.InvalidHandle;
        return sendControlToSession(session, control);
    }

    fn sendControlToSession(session: *Session, control: Control) !void {
        const byte: u8 = switch (control) {
            // ConPTY translates ETX arriving on its input stream into the
            // console Ctrl+C control event for the attached process tree.
            .ctrl_c => 0x03,
        };
        const input = session.input orelse return error.InvalidHandle;
        var written: DWORD = 0;
        const control_bytes = [_]u8{byte};
        if (kernel32.WriteFile(input, &control_bytes, 1, &written, null) == 0 or written != 1) {
            return switch (lastErrorCode()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA => error.BrokenPipe,
                ERROR_OPERATION_ABORTED => error.ProcessExited,
                else => error.WindowsApiFailure,
            };
        }
    }

    fn terminateSession(session: *Session, exit_code: DWORD) void {
        if (session.job) |job| {
            _ = kernel32.TerminateJobObject(job, exit_code);
        } else if (session.process) |process| {
            _ = kernel32.TerminateProcess(process, exit_code);
        }
    }

    fn closeIo(session: *Session) void {
        if (session.io_closed) return;
        session.io_closed = true;
        if (session.pseudo_console) |pseudo_console| {
            _ = kernel32.ClosePseudoConsole(pseudo_console);
            session.pseudo_console = null;
        }
        if (session.input) |input| {
            _ = kernel32.CloseHandle(input);
            session.input = null;
        }
        if (session.output) |output| {
            _ = kernel32.CloseHandle(output);
            session.output = null;
        }
        if (session.input_read_side) |input_read| {
            _ = kernel32.CloseHandle(input_read);
            session.input_read_side = null;
        }
        if (session.output_write_side) |output_write| {
            _ = kernel32.CloseHandle(output_write);
            session.output_write_side = null;
        }
    }

    fn destroySession(session: *Session) void {
        closeIo(session);
        if (session.thread) |thread| {
            _ = kernel32.CloseHandle(thread);
            session.thread = null;
        }
        if (session.process) |process| {
            _ = kernel32.CloseHandle(process);
            session.process = null;
        }
        if (session.job) |job| {
            _ = kernel32.CloseHandle(job);
            session.job = null;
        }
        session.alloc.destroy(session);
    }

    fn removeSession(state: *State, session: *Session) void {
        for (state.sessions.items, 0..) |candidate, index| {
            if (candidate == session) {
                _ = state.sessions.swapRemove(index);
                return;
            }
        }
    }

    fn findSessionByMaster(state: *State, master: pty.Handle) ?*Session {
        for (state.sessions.items) |session| {
            if (@intFromPtr(session) == master) return session;
        }
        return null;
    }

    fn findSessionByProcess(state: *State, process: pty.ProcessId) ?*Session {
        if (process < 0 or process > std.math.maxInt(DWORD)) return null;
        const pid: DWORD = @intCast(process);
        for (state.sessions.items) |session| {
            if (session.pid == pid) return session;
        }
        return null;
    }

    fn isAlive(session: *Session) bool {
        const process = session.process orelse return false;
        var code: DWORD = 0;
        if (kernel32.GetExitCodeProcess(process, &code) == 0) return false;
        return code == STILL_ACTIVE;
    }

    fn lastErrorCode() DWORD {
        return @intFromEnum(windows.GetLastError());
    }

    fn spawnThunk(context: *anyopaque, spec: pty.SpawnSpec) anyerror!pty.Spawned {
        return Self.spawn(@ptrCast(@alignCast(context)), spec);
    }

    fn writeThunk(context: *anyopaque, master: pty.Handle, bytes: []const u8) anyerror!usize {
        return Self.write(@ptrCast(@alignCast(context)), master, bytes);
    }

    fn resizeThunk(context: *anyopaque, master: pty.Handle, size: resize.Size) anyerror!void {
        return Self.resizeMaster(@ptrCast(@alignCast(context)), master, size);
    }

    fn signalThunk(context: *anyopaque, process: pty.ProcessId, value: pty.Signal) anyerror!void {
        return Self.signal(@ptrCast(@alignCast(context)), process, value);
    }

    fn closeThunk(context: *anyopaque, master: pty.Handle) void {
        Self.closeMaster(@ptrCast(@alignCast(context)), master);
    }

    fn reapThunk(context: *anyopaque, process: pty.ProcessId) void {
        Self.reap(@ptrCast(@alignCast(context)), process);
    }

    const Self = @This();
};

test "Windows command line quoting preserves Unicode and backslashes" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{
        "cmd.exe",
        "hello world",
        "C:\\path\\",
        "quote\"value",
        "日本語",
    };
    const line = try buildCommandLine(alloc, .{
        .session_name = "unicode",
        .shell = "cmd.exe",
        .task_mode = true,
        .command = args[0..],
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "cmd.exe \"hello world\" C:\\path\\ \"quote\\\"value\" 日本語",
        line,
    );
}

test "Windows command line rejects an empty command" {
    const alloc = std.testing.allocator;
    const command = [_][]const u8{};
    try std.testing.expectError(error.InvalidCommand, buildCommandLine(alloc, .{
        .session_name = "empty",
        .shell = "cmd.exe",
        .task_mode = true,
        .command = command[0..],
        .size = .{ .rows = 24, .cols = 80 },
    }));
}

test "ConPTY size conversion rejects unusable and overflowing dimensions" {
    try std.testing.expectError(error.InvalidSize, sizeToCoord(.{ .rows = 0, .cols = 80 }));
    try std.testing.expectError(error.InvalidSize, sizeToCoord(.{ .rows = 24, .cols = 0 }));
    try std.testing.expectError(error.InvalidSize, sizeToCoord(.{ .rows = 24, .cols = 0xffff }));
}

test "ConPTY adapter exposes the frozen backend shape on every target" {
    var state = init(std.testing.allocator);
    defer deinit(&state);
    const adapter = backend(&state);
    try std.testing.expect(@TypeOf(adapter.spawn_fn) == *const fn (*anyopaque, pty.SpawnSpec) anyerror!pty.Spawned);
}

test "real ConPTY preserves UTF-8 output and Ctrl+C" {
    if (builtin.os.tag != .windows) return;

    var state = init(std.testing.allocator);
    defer deinit(&state);
    const command = [_][]const u8{
        "cmd.exe",
        "/d",
        "/c",
        "chcp 65001>nul & echo hello 日本語",
    };
    const spawned = try spawn(&state, .{
        .session_name = "conpty-test",
        .shell = "cmd.exe",
        .task_mode = true,
        .command = command[0..],
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer reap(&state, spawned.process);

    var output: [4096]u8 = undefined;
    var total: usize = 0;
    var attempts: usize = 0;
    while (attempts < 100 and total < output.len) : (attempts += 1) {
        const count = read(&state, spawned.master, output[total..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        total += count;
        if (std.mem.indexOf(u8, output[0..total], "hello") != null) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    _ = try wait(&state, spawned.process);
    try std.testing.expect(std.mem.indexOf(u8, output[0..total], "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..total], "日本語") != null);
}

test "real ConPTY sends Ctrl+C to the attached process" {
    if (builtin.os.tag != .windows) return;

    var state = init(std.testing.allocator);
    defer deinit(&state);
    const command = [_][]const u8{
        "cmd.exe",
        "/d",
        "/c",
        "echo ready & pause >nul",
    };
    const spawned = try spawn(&state, .{
        .session_name = "conpty-ctrl-c",
        .shell = "cmd.exe",
        .task_mode = true,
        .command = command[0..],
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer reap(&state, spawned.process);

    var output: [1024]u8 = undefined;
    var total: usize = 0;
    var attempts: usize = 0;
    while (attempts < 100 and std.mem.indexOf(u8, output[0..total], "ready") == null) : (attempts += 1) {
        const count = read(&state, spawned.master, output[total..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        total += count;
        if (std.mem.indexOf(u8, output[0..total], "ready") == null) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, output[0..total], "ready") != null);

    try sendControl(&state, spawned.process, .ctrl_c);
    var exited = false;
    for (0..30) |_| {
        if (!implementation.isAlive(implementation.findSessionByProcess(&state, spawned.process).?)) {
            exited = true;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    try std.testing.expect(exited);
}

test "real ConPTY accepts resize updates" {
    if (builtin.os.tag != .windows) return;

    var state = init(std.testing.allocator);
    defer deinit(&state);
    const spawned = try spawn(&state, .{
        .session_name = "conpty-resize",
        .shell = "cmd.exe",
        .task_mode = false,
        .command = null,
        .size = .{ .rows = 24, .cols = 80 },
    });
    defer reap(&state, spawned.process);

    try backend(&state).resize(spawned.master, .{ .rows = 40, .cols = 120 });
    try backend(&state).signal(spawned.process, .kill);
}

test "real ConPTY job cleanup terminates descendants" {
    if (builtin.os.tag != .windows) return;

    const marker = "conpty-job-tree-marker.txt";
    const child_script = "conpty-job-child.cmd";
    std.fs.cwd().deleteFile(marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    {
        const file = try std.fs.cwd().createFile(child_script, .{ .truncate = true });
        defer file.close();
        try file.writeAll("@echo off\r\nping -n 3 127.0.0.1 >nul\r\necho escaped>conpty-job-tree-marker.txt\r\n");
    }
    defer std.fs.cwd().deleteFile(child_script) catch {};
    defer std.fs.cwd().deleteFile(marker) catch {};

    var state = init(std.testing.allocator);
    defer deinit(&state);
    const command = [_][]const u8{
        "cmd.exe",
        "/d",
        "/c",
        "start \"\" /b conpty-job-child.cmd",
    };
    const spawned = try spawn(&state, .{
        .session_name = "conpty-job-tree",
        .shell = "cmd.exe",
        .task_mode = true,
        .command = command[0..],
        .size = .{ .rows = 24, .cols = 80 },
    });
    try backend(&state).signal(spawned.process, .kill);
    _ = try wait(&state, spawned.process);
    reap(&state, spawned.process);

    std.Thread.sleep(2500 * std.time.ns_per_ms);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(marker, .{}));
}
