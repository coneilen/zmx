const std = @import("std");
const local_ipc = @import("local_ipc.zig");
const resize = @import("resize.zig");

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    Switch = 11,
    Write = 12,
    TaskComplete = 13,
    LabelGet = 14,
    LabelSet = 15,
    LabelClear = 16,
    LabelData = 17,
    Send = 18,
    _,
};

pub const Header = packed struct {
    tag: Tag,
    len: u32,
};

pub const Resize = resize.Size;

pub const MAX_FRAME_LEN: usize = 256 * 1024 * 1024;

pub const Info = extern struct {
    clients_len: u64,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [256]u8,
    cwd: [256]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
};

pub const Error = error{
    BrokenPipe,
    ConnectionResetByPeer,
    FrameTooLarge,
    Unexpected,
} || std.mem.Allocator.Error;

pub const Frame = struct {
    header: Header,
    payload: []u8,

    pub fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};

pub fn writeFrame(
    connection: local_ipc.Connection,
    tag: Tag,
    payload: []const u8,
) anyerror!void {
    if (payload.len > MAX_FRAME_LEN or payload.len > std.math.maxInt(u32)) {
        return error.FrameTooLarge;
    }
    const header = Header{
        .tag = tag,
        .len = @intCast(payload.len),
    };
    try connection.writeAll(std.mem.asBytes(&header));
    try connection.writeAll(payload);
}

pub fn readExact(
    connection: local_ipc.Connection,
    buffer: []u8,
) anyerror!void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const amount = connection.read(buffer[offset..]) catch |err| switch (err) {
            error.BrokenPipe => return error.BrokenPipe,
            error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        };
        if (amount == 0) return error.BrokenPipe;
        offset += amount;
    }
}

pub fn readFrame(
    alloc: std.mem.Allocator,
    connection: local_ipc.Connection,
) anyerror!Frame {
    var header: Header = undefined;
    try readExact(connection, std.mem.asBytes(&header));
    if (@as(usize, header.len) > MAX_FRAME_LEN) return error.FrameTooLarge;
    const payload = try alloc.alloc(u8, header.len);
    errdefer alloc.free(payload);
    try readExact(connection, payload);
    return .{ .header = header, .payload = payload };
}

comptime {
    if (@sizeOf(Header) != 8) @compileError("Windows session header must stay eight bytes");
    if (@sizeOf(Info) != 552) @compileError("Windows session Info layout changed");
    if (@intFromEnum(Tag.Output) != 1 or @intFromEnum(Tag.Send) != 18) {
        @compileError("Windows session tags must match src/ipc.zig");
    }
}

test "Windows session wire preserves all frozen tags and shapes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 552), @sizeOf(Info));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Tag.Input));
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(Tag.Send));
}
