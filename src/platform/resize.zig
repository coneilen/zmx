const std = @import("std");

/// The dimensions carried by the existing Init/Resize wire messages.  Keep
/// this layout frozen; `src/ipc.zig` aliases it rather than defining a second
/// protocol type.
pub const Size = packed struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const ControlEvent = union(enum) {
    resize: Size,
    hangup: void,
    terminate: void,
};

pub fn isUsable(size: Size) bool {
    return size.rows > 0 and size.cols > 0;
}

pub fn fallback() Size {
    return .{ .rows = 24, .cols = 120 };
}

pub const SpecError = error{InvalidSize};

/// Parses a `<cols>x<rows>` geometry spec such as `120x40`.  This is the CLI
/// surface for callers that cannot measure a terminal (a pipe child has no
/// console or tty to probe).
pub fn parseSpec(text: []const u8) SpecError!Size {
    const separator = std.mem.indexOfAny(u8, text, "xX") orelse return error.InvalidSize;
    const cols_text = text[0..separator];
    const rows_text = text[separator + 1 ..];
    if (cols_text.len == 0 or rows_text.len == 0) return error.InvalidSize;
    const size = Size{
        .cols = std.fmt.parseInt(u16, cols_text, 10) catch return error.InvalidSize,
        .rows = std.fmt.parseInt(u16, rows_text, 10) catch return error.InvalidSize,
    };
    if (!isUsable(size)) return error.InvalidSize;
    return size;
}

/// Parses geometry supplied as two separate arguments (`<cols> <rows>`).
pub fn parsePair(cols_text: []const u8, rows_text: []const u8) SpecError!Size {
    const size = Size{
        .cols = std.fmt.parseInt(u16, cols_text, 10) catch return error.InvalidSize,
        .rows = std.fmt.parseInt(u16, rows_text, 10) catch return error.InvalidSize,
    };
    if (!isUsable(size)) return error.InvalidSize;
    return size;
}

/// Decodes a geometry wire payload.  Returns null for any frame that is not
/// exactly the frozen eight-byte shape or that carries an unusable dimension,
/// so a malformed frame can never resize a session.
pub fn fromPayload(payload: []const u8) ?Size {
    if (payload.len != @sizeOf(Size)) return null;
    const size = std.mem.bytesToValue(Size, payload[0..@sizeOf(Size)]);
    if (!isUsable(size)) return null;
    return size;
}

test "geometry spec parsing accepts cols x rows and rejects degenerate specs" {
    try std.testing.expectEqual(Size{ .cols = 120, .rows = 40 }, try parseSpec("120x40"));
    try std.testing.expectEqual(Size{ .cols = 1, .rows = 1 }, try parseSpec("1X1"));
    try std.testing.expectError(error.InvalidSize, parseSpec("120"));
    try std.testing.expectError(error.InvalidSize, parseSpec("120x"));
    try std.testing.expectError(error.InvalidSize, parseSpec("x40"));
    try std.testing.expectError(error.InvalidSize, parseSpec("0x40"));
    try std.testing.expectError(error.InvalidSize, parseSpec("120x0"));
    try std.testing.expectError(error.InvalidSize, parseSpec("-1x40"));
    try std.testing.expectError(error.InvalidSize, parseSpec("65536x40"));
    try std.testing.expectError(error.InvalidSize, parseSpec("120x40x2"));
    try std.testing.expectError(error.InvalidSize, parseSpec(""));
}

test "geometry pair parsing matches spec parsing" {
    try std.testing.expectEqual(Size{ .cols = 120, .rows = 40 }, try parsePair("120", "40"));
    try std.testing.expectError(error.InvalidSize, parsePair("120", "0"));
    try std.testing.expectError(error.InvalidSize, parsePair("", "40"));
    try std.testing.expectError(error.InvalidSize, parsePair("120", "40x2"));
}

test "geometry payload decoding rejects short, long, and unusable frames" {
    const size = Size{ .cols = 100, .rows = 30 };
    try std.testing.expectEqual(size, fromPayload(std.mem.asBytes(&size)).?);
    try std.testing.expectEqual(@as(?Size, null), fromPayload(""));
    try std.testing.expectEqual(@as(?Size, null), fromPayload(std.mem.asBytes(&size)[0..7]));
    try std.testing.expectEqual(@as(?Size, null), fromPayload(std.mem.asBytes(&size) ++ "\x00"));
    const degenerate = Size{ .cols = 0, .rows = 30 };
    try std.testing.expectEqual(@as(?Size, null), fromPayload(std.mem.asBytes(&degenerate)));
}

test "resize contract remains the eight-byte wire shape" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Size));
    try std.testing.expect(isUsable(.{ .rows = 24, .cols = 120 }));
    try std.testing.expect(!isUsable(.{ .rows = 0, .cols = 120 }));
}
