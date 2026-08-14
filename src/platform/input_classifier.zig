const std = @import("std");

/// Classifies the byte stream used by an attached terminal. Mouse reports are
/// safe to forward from a non-leader; keyboard input claims the leader role.
/// Incomplete escape sequences are held so leadership changes cannot duplicate
/// or tear a report.
pub const InputClassifier = struct {
    alloc: std.mem.Allocator,
    carry: std.ArrayList(u8) = .empty,
    carry_emitted: bool = false,
    carry_from_leader: bool = false,
    quarantined: bool = false,

    // A terminal escape sequence is normally a few dozen bytes. Kitty
    // keyboard reports can be larger, but they still must not make a client
    // retain or repeatedly rescan an unbounded suffix across frames.
    pub const max_carry_bytes: usize = 64 * 1024;

    pub const Result = struct {
        bytes: []u8,
        claims_leadership: bool,
    };

    pub fn init(alloc: std.mem.Allocator) InputClassifier {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *InputClassifier) void {
        self.carry.deinit(self.alloc);
    }

    pub fn observeLeader(self: *InputClassifier, payload: []const u8) ![]u8 {
        const result = try self.analyze(payload, true);
        return result.bytes;
    }

    pub fn filterNonLeader(self: *InputClassifier, payload: []const u8) !Result {
        return self.analyze(payload, false);
    }

    fn quarantine(self: *InputClassifier) void {
        self.carry.clearRetainingCapacity();
        self.carry_emitted = false;
        self.carry_from_leader = false;
        self.quarantined = true;
    }

    fn emptyResult(self: *InputClassifier) !Result {
        return .{
            .bytes = try self.alloc.dupe(u8, &.{}),
            .claims_leadership = false,
        };
    }

    fn appendCarry(
        self: *InputClassifier,
        bytes: []const u8,
        emitted: bool,
        from_leader: bool,
    ) bool {
        if (bytes.len > max_carry_bytes) {
            self.quarantine();
            return false;
        }
        self.carry.clearRetainingCapacity();
        self.carry.appendSlice(self.alloc, bytes) catch {
            self.quarantine();
            return false;
        };
        self.carry_emitted = emitted;
        self.carry_from_leader = from_leader;
        return true;
    }

    fn appendOutput(
        output: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        try output.appendSlice(alloc, bytes);
    }

    fn csiEventIsRelease(body: []const u8) bool {
        const semicolon = std.mem.indexOfScalar(u8, body, ';') orelse return false;
        const rest = body[semicolon + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
        return colon + 1 < rest.len and rest[colon + 1] == '3';
    }

    fn analyze(self: *InputClassifier, payload: []const u8, raw_owner: bool) !Result {
        if (self.quarantined) {
            self.quarantined = false;
            return self.emptyResult();
        }

        const lone_esc_already_emitted = raw_owner and
            self.carry_emitted and
            self.carry.items.len == 1 and
            self.carry.items[0] == 0x1b;
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.alloc);
        if (!lone_esc_already_emitted) {
            try combined.appendSlice(self.alloc, self.carry.items);
        }
        try combined.appendSlice(self.alloc, payload);
        const carried_len = self.carry.items.len;
        const carried_emitted = self.carry_emitted;
        const carried_from_leader = self.carry_from_leader;
        self.carry.clearRetainingCapacity();
        self.carry_emitted = false;
        self.carry_from_leader = false;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.alloc);
        var claims_leadership = false;
        var i: usize = 0;

        while (i < combined.items.len) {
            const byte = combined.items[i];
            const from_carry = i < carried_len;
            const emitted = from_carry and carried_emitted;
            const from_leader = from_carry and carried_from_leader;

            if (byte != 0x1b) {
                // All standalone bytes except ESC are intentional terminal
                // input, including C0 controls such as Ctrl+C/D/Z. Protocol
                // replies, focus events, and mouse reports are classified as
                // escape sequences below and remain filtered as appropriate.
                const is_keyboard = true;
                if (raw_owner or (is_keyboard and !emitted and !from_leader)) {
                    try appendOutput(&output, self.alloc, combined.items[i .. i + 1]);
                }
                if (is_keyboard and !emitted and !from_leader) claims_leadership = true;
                i += 1;
                continue;
            }

            if (i + 1 >= combined.items.len) {
                if (raw_owner) {
                    // A lone ESC is itself a key. Preserve its provenance so a
                    // later continuation cannot retake leadership.
                    try appendOutput(&output, self.alloc, combined.items[i .. i + 1]);
                    if (!self.appendCarry(combined.items[i..], true, true)) {
                        return .{
                            .bytes = try output.toOwnedSlice(self.alloc),
                            .claims_leadership = claims_leadership,
                        };
                    }
                } else {
                    if (!self.appendCarry(combined.items[i..], emitted, raw_owner or from_leader)) {
                        return .{
                            .bytes = try output.toOwnedSlice(self.alloc),
                            .claims_leadership = claims_leadership,
                        };
                    }
                }
                break;
            }

            const second = combined.items[i + 1];
            var end: usize = 0;
            var is_mouse = false;
            var is_keyboard = false;
            var incomplete = false;

            if (second == '[') {
                var final_index: ?usize = null;
                var cursor = i + 2;
                while (cursor < combined.items.len) : (cursor += 1) {
                    if (combined.items[cursor] >= 0x40 and combined.items[cursor] <= 0x7e) {
                        final_index = cursor;
                        break;
                    }
                }
                if (final_index == null) {
                    incomplete = true;
                } else {
                    const final = combined.items[final_index.?];
                    end = final_index.? + 1;
                    if (final == 'M' and final_index.? == i + 2) {
                        if (combined.items.len - end < 3) {
                            incomplete = true;
                        } else {
                            end += 3;
                            is_mouse = true;
                        }
                    } else if (final == 'M' or final == 'm') {
                        is_mouse = combined.items[i + 2] == '<';
                    } else if (final == 'A' or final == 'B' or
                        final == 'C' or final == 'D' or final == '~')
                    {
                        is_keyboard = true;
                    } else if (final == 'u') {
                        is_keyboard = !csiEventIsRelease(
                            combined.items[i + 2 .. final_index.?],
                        );
                    }
                }
            } else if (second == 'O') {
                if (i + 2 >= combined.items.len) {
                    incomplete = true;
                } else {
                    end = i + 3;
                    is_keyboard = true;
                }
            } else {
                end = i + 2;
                is_keyboard = true;
            }

            if (incomplete) {
                if (!self.appendCarry(combined.items[i..], emitted, raw_owner or from_leader)) {
                    return .{
                        .bytes = try output.toOwnedSlice(self.alloc),
                        .claims_leadership = claims_leadership,
                    };
                }
                if (raw_owner and i > 0) {
                    output.clearRetainingCapacity();
                    try appendOutput(&output, self.alloc, combined.items[0..i]);
                }
                break;
            }

            const allow = raw_owner or is_mouse or
                (is_keyboard and !emitted and !from_leader);
            if (allow) try appendOutput(&output, self.alloc, combined.items[i..end]);
            if (is_keyboard and !emitted and !from_leader) claims_leadership = true;
            i = end;
        }

        return .{
            .bytes = try output.toOwnedSlice(self.alloc),
            .claims_leadership = claims_leadership,
        };
    }
};

test "Windows attach classifier forwards mouse without claiming leadership" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const result = try classifier.filterNonLeader("\x1b[<65;10;20M");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("\x1b[<65;10;20M", result.bytes);
    try std.testing.expect(!result.claims_leadership);
}

test "Windows attach classifier transfers leadership for keyboard input" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const result = try classifier.filterNonLeader("x");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("x", result.bytes);
    try std.testing.expect(result.claims_leadership);
}

test "Windows attach classifier transfers leadership for intentional C0 controls" {
    const controls = [_]u8{ 0x03, 0x04, 0x1a };
    for (controls) |control| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const result = try classifier.filterNonLeader(&.{control});
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqualSlices(u8, &.{control}, result.bytes);
        try std.testing.expect(result.claims_leadership);
    }
}

test "Windows attach classifier filters protocol events while accepting C0 input" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const result = try classifier.filterNonLeader("\x07\x1b[I\x1b[?1;2c");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualSlices(u8, &.{0x07}, result.bytes);
    try std.testing.expect(result.claims_leadership);
}

test "Windows attach classifier keeps split mouse atomic across takeover" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const held = try classifier.observeLeader("\x1b[<6");
    defer std.testing.allocator.free(held);
    try std.testing.expectEqualStrings("", held);
    const result = try classifier.filterNonLeader("5;90;20M");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("\x1b[<65;90;20M", result.bytes);
    try std.testing.expect(!result.claims_leadership);
}

test "Windows attach classifier suppresses former leader keyboard continuation" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const held = try classifier.observeLeader("\x1b[");
    defer std.testing.allocator.free(held);
    const result = try classifier.filterNonLeader("A");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("", result.bytes);
    try std.testing.expect(!result.claims_leadership);
}

test "Windows attach classifier quarantines oversized escape carry" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();

    const oversized = try std.testing.allocator.alloc(u8, InputClassifier.max_carry_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    oversized[0] = 0x1b;
    oversized[1] = '[';

    const first = try classifier.filterNonLeader(oversized);
    defer std.testing.allocator.free(first.bytes);
    try std.testing.expectEqual(@as(usize, 0), first.bytes.len);
    try std.testing.expect(!first.claims_leadership);

    const suffix = try classifier.filterNonLeader("x");
    defer std.testing.allocator.free(suffix.bytes);
    try std.testing.expectEqual(@as(usize, 0), suffix.bytes.len);
    try std.testing.expect(!suffix.claims_leadership);

    const recovered = try classifier.filterNonLeader("y");
    defer std.testing.allocator.free(recovered.bytes);
    try std.testing.expectEqualStrings("y", recovered.bytes);
    try std.testing.expect(recovered.claims_leadership);
}
