const builtin = @import("builtin");
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
pub const sessionExists = selected.sessionExists;
pub const createSocket = selected.createSocket;
pub const getSocketPath = selected.getSocketPath;
pub const printSessionNameTooLong = selected.printSessionNameTooLong;
pub const maxSessionNameLen = selected.maxSessionNameLen;
