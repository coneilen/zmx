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

test "resize contract remains the eight-byte wire shape" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Size));
    try std.testing.expect(isUsable(.{ .rows = 24, .cols = 120 }));
    try std.testing.expect(!isUsable(.{ .rows = 0, .cols = 120 }));
}
