const builtin = @import("builtin");
const std = @import("std");
const selected = if (builtin.os.tag == .windows)
    @import("socket_windows.zig")
else
    @import("socket_posix.zig");

pub const getSeshPrefix = selected.getSeshPrefix;
pub const getSeshNameFromEnv = selected.getSeshNameFromEnv;
pub const getSeshName = selected.getSeshName;
pub const resolveSessionOrEnv = selected.resolveSessionOrEnv;
pub const SessionMatch = selected.SessionMatch;
pub const parseSessionArg = selected.parseSessionArg;
pub const sessionConnect = selected.sessionConnect;
pub const cleanupStaleSocket = selected.cleanupStaleSocket;
pub const cleanupStaleSocketWithIo = if (@hasDecl(selected, "cleanupStaleSocketWithIo"))
    selected.cleanupStaleSocketWithIo
else
    struct {
        fn cleanupStaleSocketWithIo(_: std.Io, _: std.mem.Allocator, _: []const u8) void {}
    }.cleanupStaleSocketWithIo;
pub const sessionExists = selected.sessionExists;
pub const createSocket = selected.createSocket;
pub const createSessionSocket = if (@hasDecl(selected, "createSessionSocket"))
    selected.createSessionSocket
else
    struct {
        fn createSessionSocket(
            _: std.Io,
            _: std.mem.Allocator,
            _: []const u8,
        ) !@TypeOf(selected.createSocket("")) {
            return error.Unsupported;
        }
    }.createSessionSocket;
pub const getSocketPath = selected.getSocketPath;
pub const getSocketPathWithIo = if (@hasDecl(selected, "getSocketPathWithIo"))
    selected.getSocketPathWithIo
else
    struct {
        fn getSocketPathWithIo(
            _: std.Io,
            alloc: std.mem.Allocator,
            socket_dir: []const u8,
            session_name: []const u8,
        ) ![]const u8 {
            return selected.getSocketPath(alloc, socket_dir, session_name);
        }
    }.getSocketPathWithIo;
pub const printSessionNameTooLong = selected.printSessionNameTooLong;
pub const maxSessionNameLen = selected.maxSessionNameLen;
