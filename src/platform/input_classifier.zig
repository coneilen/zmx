const std = @import("std");

/// Classifies the byte stream used by an attached terminal. Mouse reports are
/// safe to forward from a non-leader; keyboard input claims the leader role.
/// Incomplete escape sequences are held so leadership changes cannot duplicate
/// or tear a report.
pub const InputClassifier = struct {
    const CarryKind = enum {
        none,
        csi,
        ss3,
        string,
    };

    alloc: std.mem.Allocator,
    carry: std.ArrayList(u8) = .empty,
    carry_emitted: bool = false,
    carry_from_leader: bool = false,
    quarantined: bool = false,
    carry_kind: CarryKind = .none,
    carry_scan_offset: usize = 0,
    string_control: ?StringControl = null,
    csi_scan_work: usize = 0,

    // A terminal escape sequence is normally a few dozen bytes. Kitty
    // keyboard reports can be larger, but they still must not make a client
    // retain or repeatedly rescan an unbounded suffix across frames.
    pub const max_carry_bytes: usize = 64 * 1024;
    pub const lone_esc_timeout_ms: u64 = 50;

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

    pub fn csiScanWork(self: *const InputClassifier) usize {
        return self.csi_scan_work;
    }

    pub fn hasPendingLoneEsc(self: *const InputClassifier) bool {
        return !self.quarantined and
            !self.carry_emitted and
            !self.carry_from_leader and
            self.carry.items.len == 1 and
            self.carry.items[0] == 0x1b;
    }

    pub fn hasPendingEscape(self: *const InputClassifier) bool {
        if (self.hasPendingLoneEsc()) return true;
        return !self.quarantined and
            !self.carry_emitted and
            !self.carry_from_leader and
            self.carry.items.len == 2 and
            self.carry.items[0] == 0x1b and
            (isStringIntroducer(self.carry.items[1]) or
                self.carry.items[1] == '[' or
                self.carry.items[1] == 'O');
    }

    pub fn flushLoneEsc(self: *InputClassifier) !Result {
        if (!self.hasPendingLoneEsc()) return self.emptyResult();
        self.carry.clearRetainingCapacity();
        self.carry_emitted = false;
        self.carry_from_leader = false;
        self.carry_kind = .none;
        self.carry_scan_offset = 0;
        self.string_control = null;
        return .{
            .bytes = try self.alloc.dupe(u8, &.{0x1b}),
            .claims_leadership = true,
        };
    }

    pub fn flushPendingEscape(self: *InputClassifier) !Result {
        if (!self.hasPendingEscape()) return self.emptyResult();
        const bytes = try self.alloc.dupe(u8, self.carry.items);
        self.carry.clearRetainingCapacity();
        self.carry_emitted = false;
        self.carry_from_leader = false;
        self.carry_kind = .none;
        self.carry_scan_offset = 0;
        self.string_control = null;
        return .{
            .bytes = bytes,
            .claims_leadership = true,
        };
    }

    fn quarantine(self: *InputClassifier) void {
        self.carry.clearRetainingCapacity();
        self.carry_emitted = false;
        self.carry_from_leader = false;
        self.carry_kind = .none;
        self.carry_scan_offset = 0;
        self.string_control = null;
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
        const event = rest[colon + 1 ..];
        var end: usize = 0;
        while (end < event.len and std.ascii.isDigit(event[end])) : (end += 1) {}
        if (end == 0) return false;
        return (std.fmt.parseInt(u8, event[0..end], 10) catch 0) == 3;
    }

    fn isPrivateCsiU(body: []const u8) bool {
        return body.len == 0 or switch (body[0]) {
            '?', '>', '<', '=' => true,
            else => false,
        };
    }

    fn isKeyboardCsiU(body: []const u8) bool {
        if (isPrivateCsiU(body)) return false;
        if (body.len == 0 or !std.ascii.isDigit(body[0])) return false;
        const semicolon = std.mem.indexOfScalar(u8, body, ';') orelse return false;
        if (semicolon == 0 or semicolon + 1 >= body.len) return false;
        if (!std.ascii.isDigit(body[semicolon + 1])) return false;
        return !csiEventIsRelease(body);
    }

    const StringControl = enum {
        osc,
        dcs,
        apc,
        pm,
    };

    fn stringControlForEscape(byte: u8) ?StringControl {
        return switch (byte) {
            ']' => .osc,
            'P' => .dcs,
            '_' => .apc,
            '^' => .pm,
            else => null,
        };
    }

    fn stringControlForC1(byte: u8) ?StringControl {
        return switch (byte) {
            0x9d => .osc,
            0x90 => .dcs,
            0x9f => .apc,
            0x9e => .pm,
            else => null,
        };
    }

    fn isStringIntroducer(byte: u8) bool {
        return stringControlForEscape(byte) != null;
    }

    fn findStringEnd(
        bytes: []const u8,
        start: usize,
        control: StringControl,
    ) ?usize {
        var cursor = start;
        while (cursor < bytes.len) : (cursor += 1) {
            if (bytes[cursor] == 0x9c) return cursor + 1;
            if (bytes[cursor] == 0x1b and
                cursor + 1 < bytes.len and
                bytes[cursor + 1] == '\\')
            {
                return cursor + 2;
            }
            if (control == .osc and bytes[cursor] == 0x07) return cursor + 1;
        }
        return null;
    }

    fn nextStringScanOffset(bytes: []const u8) usize {
        if (bytes.len != 0 and bytes[bytes.len - 1] == 0x1b) return bytes.len - 1;
        return bytes.len;
    }

    fn findCsiFinal(self: *InputClassifier, bytes: []const u8, start: usize) ?usize {
        var cursor = start;
        while (cursor < bytes.len) : (cursor += 1) {
            self.csi_scan_work += 1;
            if (bytes[cursor] >= 0x40 and bytes[cursor] <= 0x7e) return cursor;
        }
        return null;
    }

    fn isKeyboardModifierBody(body: []const u8) bool {
        if (body.len < 3 or body[0] != '1' or body[1] != ';') return false;
        const modifier = std.fmt.parseInt(u8, body[2..], 10) catch return false;
        return modifier >= 2 and modifier <= 16;
    }

    fn isKeyboardCsi(body: []const u8, final: u8) bool {
        return switch (final) {
            'A', 'B', 'C', 'D', '~' => true,
            // Unmodified Home/End/Shift-Tab use CSI H/F/Z. Modified
            // variants use the standard CSI 1;<modifier> form.
            'H', 'F', 'Z' => body.len == 0 or isKeyboardModifierBody(body),
            // F1-F4 use SS3 P-S without modifiers and CSI 1;<modifier>
            // P-S when modifiers are present. Restricting these finals to
            // that shape avoids treating cursor-position reports as keys.
            'P', 'Q', 'R', 'S' => isKeyboardModifierBody(body),
            else => false,
        };
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
        const carried_kind = self.carry_kind;
        const carried_scan_offset = self.carry_scan_offset;
        self.carry.clearRetainingCapacity();
        self.carry_emitted = false;
        self.carry_from_leader = false;
        self.carry_kind = .none;
        self.carry_scan_offset = 0;
        self.string_control = null;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.alloc);
        var claims_leadership = false;
        var i: usize = 0;

        while (i < combined.items.len) {
            const byte = combined.items[i];
            const from_carry = i < carried_len;
            const emitted = from_carry and carried_emitted;
            const from_leader = from_carry and carried_from_leader;

            if (stringControlForC1(byte)) |control| {
                const scan_start = if (i == 0 and carried_kind == .string)
                    carried_scan_offset
                else
                    i + 1;
                const end = findStringEnd(combined.items, scan_start, control);
                if (end == null) {
                    if (!self.appendCarry(
                        combined.items[i..],
                        emitted,
                        raw_owner or from_leader,
                    )) {
                        return .{
                            .bytes = try output.toOwnedSlice(self.alloc),
                            .claims_leadership = claims_leadership,
                        };
                    }
                    self.carry_kind = .string;
                    self.carry_scan_offset = nextStringScanOffset(combined.items[i..]);
                    self.string_control = control;
                    break;
                }
                if (raw_owner and !(from_carry and !carried_from_leader)) {
                    try appendOutput(&output, self.alloc, combined.items[i..end.?]);
                }
                i = end.?;
                continue;
            }

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
            if (stringControlForEscape(second)) |control| {
                const scan_start = if (i == 0 and carried_kind == .string)
                    carried_scan_offset
                else
                    i + 2;
                const end = findStringEnd(combined.items, scan_start, control);
                if (end == null) {
                    if (!self.appendCarry(
                        combined.items[i..],
                        emitted,
                        raw_owner or from_leader,
                    )) {
                        return .{
                            .bytes = try output.toOwnedSlice(self.alloc),
                            .claims_leadership = claims_leadership,
                        };
                    }
                    self.carry_kind = .string;
                    self.carry_scan_offset = nextStringScanOffset(combined.items[i..]);
                    self.string_control = control;
                    if (raw_owner and i > 0) {
                        output.clearRetainingCapacity();
                        try appendOutput(&output, self.alloc, combined.items[0..i]);
                    }
                    break;
                }
                if (raw_owner and !(from_carry and !carried_from_leader)) {
                    try appendOutput(&output, self.alloc, combined.items[i..end.?]);
                }
                i = end.?;
                continue;
            }

            var end: usize = 0;
            var is_mouse = false;
            var is_keyboard = false;
            var incomplete = false;

            if (second == '[') {
                const scan_start = if (i == 0 and carried_kind == .csi)
                    carried_scan_offset
                else
                    i + 2;
                const final_index = self.findCsiFinal(combined.items, scan_start);
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
                    } else if (isKeyboardCsi(
                        combined.items[i + 2 .. final_index.?],
                        final,
                    )) {
                        is_keyboard = true;
                    } else if (final == 'u') {
                        is_keyboard = isKeyboardCsiU(
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
                if (second == '[') {
                    self.carry_kind = .csi;
                    self.carry_scan_offset = combined.items.len - i;
                } else if (second == 'O') {
                    self.carry_kind = .ss3;
                    self.carry_scan_offset = combined.items.len - i;
                }
                if (raw_owner and i > 0) {
                    output.clearRetainingCapacity();
                    try appendOutput(&output, self.alloc, combined.items[0..i]);
                }
                break;
            }

            const carried_nonleader_control = from_carry and
                !carried_from_leader and
                !is_mouse and
                !is_keyboard;
            const allow = (raw_owner and !carried_nonleader_control) or is_mouse or
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

test "Windows attach classifier bounds a non-leader lone escape" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const held = try classifier.filterNonLeader("\x1b");
    defer std.testing.allocator.free(held.bytes);
    try std.testing.expectEqual(@as(usize, 0), held.bytes.len);
    try std.testing.expect(!held.claims_leadership);
    try std.testing.expect(classifier.hasPendingLoneEsc());

    const flushed = try classifier.flushLoneEsc();
    defer std.testing.allocator.free(flushed.bytes);
    try std.testing.expectEqualSlices(u8, &.{0x1b}, flushed.bytes);
    try std.testing.expect(flushed.claims_leadership);
    try std.testing.expect(!classifier.hasPendingLoneEsc());
}

test "Windows attach classifier keeps continuation before lone escape timeout" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    const held = try classifier.filterNonLeader("\x1b");
    defer std.testing.allocator.free(held.bytes);
    const result = try classifier.filterNonLeader("[A");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("\x1b[A", result.bytes);
    try std.testing.expect(result.claims_leadership);
    try std.testing.expect(!classifier.hasPendingLoneEsc());
}

test "Windows attach classifier recognizes Home End Shift-Tab and modified function keys" {
    const keys = [_][]const u8{
        "\x1b[H",
        "\x1b[F",
        "\x1b[Z",
        "\x1b[1;2H",
        "\x1b[1;5F",
        "\x1b[1;2Z",
        "\x1b[1;5P",
        "\x1b[1;5Q",
        "\x1b[1;5R",
        "\x1b[1;5S",
        "\x1b[15;2~",
    };
    for (keys) |key| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const result = try classifier.filterNonLeader(key);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqualStrings(key, result.bytes);
        try std.testing.expect(result.claims_leadership);
    }
}

test "Windows attach classifier rejects terminal replies and cursor commands" {
    const replies = [_][]const u8{
        "\x1b[2;1H",
        "\x1b[12;34R",
        "\x1b[?25l",
        "\x1b[1;2c",
        "\x1b[6n",
        "\x1b[1;2t",
    };
    for (replies) |reply| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const result = try classifier.filterNonLeader(reply);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
        try std.testing.expect(!result.claims_leadership);
    }
}

test "Windows attach classifier filters CSI-u replies and release events" {
    const replies = [_][]const u8{
        "\x1b[?1u",
        "\x1b[>1;2u",
        "\x1b[97;1:3u",
        "\x1b[97;1:3;97u",
    };
    for (replies) |reply| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const result = try classifier.filterNonLeader(reply);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
        try std.testing.expect(!result.claims_leadership);
    }

    const keys = [_][]const u8{
        "\x1b[97;1u",
        "\x1b[97;1:2u",
    };
    for (keys) |key| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const result = try classifier.filterNonLeader(key);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqualStrings(key, result.bytes);
        try std.testing.expect(result.claims_leadership);
    }
}

test "Windows attach classifier filters split CSI-u private and release replies" {
    const splits = [_][2][]const u8{
        .{ "\x1b[?1;", "2u" },
        .{ "\x1b[97;1:", "3u" },
    };
    for (splits) |split| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const first = try classifier.filterNonLeader(split[0]);
        defer std.testing.allocator.free(first.bytes);
        try std.testing.expectEqual(@as(usize, 0), first.bytes.len);
        try std.testing.expect(!first.claims_leadership);
        const second = try classifier.filterNonLeader(split[1]);
        defer std.testing.allocator.free(second.bytes);
        try std.testing.expectEqual(@as(usize, 0), second.bytes.len);
        try std.testing.expect(!second.claims_leadership);
    }
}

test "Windows attach classifier filters complete string controls" {
    const controls = [_][]const u8{
        "\x1b]0;title\x07",
        "\x1b]0;title\x1b\\",
        "\x1bP1$r0\x1b\\",
        "\x1b_kitty\x1b\\",
        "\x1b^private\x1b\\",
        "\x9d0;title\x07",
    };
    for (controls) |control| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const result = try classifier.filterNonLeader(control);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
        try std.testing.expect(!result.claims_leadership);
    }
}

test "Windows attach classifier filters split string controls" {
    const splits = [_][2][]const u8{
        .{ "\x1b]0;title", "\x07" },
        .{ "\x1bP1$r0\x1b", "\\" },
        .{ "\x1b_kitty", "\x1b\\" },
        .{ "\x1b^private", "\x1b\\" },
    };
    for (splits) |split| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const first = try classifier.filterNonLeader(split[0]);
        defer std.testing.allocator.free(first.bytes);
        try std.testing.expectEqual(@as(usize, 0), first.bytes.len);
        try std.testing.expect(!first.claims_leadership);
        const second = try classifier.filterNonLeader(split[1]);
        defer std.testing.allocator.free(second.bytes);
        try std.testing.expectEqual(@as(usize, 0), second.bytes.len);
        try std.testing.expect(!second.claims_leadership);
    }
}

test "Windows attach classifier bounds string controls and preserves short Alt keys" {
    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();

    const alt = try classifier.filterNonLeader("\x1bq");
    defer std.testing.allocator.free(alt.bytes);
    try std.testing.expectEqualStrings("\x1bq", alt.bytes);
    try std.testing.expect(alt.claims_leadership);

    const prefix = try classifier.filterNonLeader("\x1b]");
    defer std.testing.allocator.free(prefix.bytes);
    try std.testing.expectEqual(@as(usize, 0), prefix.bytes.len);
    try std.testing.expect(!prefix.claims_leadership);
    try std.testing.expect(classifier.hasPendingEscape());
    const flushed = try classifier.flushPendingEscape();
    defer std.testing.allocator.free(flushed.bytes);
    try std.testing.expectEqualStrings("\x1b]", flushed.bytes);
    try std.testing.expect(flushed.claims_leadership);

    const oversized = try std.testing.allocator.alloc(u8, InputClassifier.max_carry_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    const frame = try std.testing.allocator.alloc(u8, InputClassifier.max_carry_bytes + 2);
    defer std.testing.allocator.free(frame);
    frame[0] = 0x1b;
    frame[1] = ']';
    @memcpy(frame[2..], oversized[0..InputClassifier.max_carry_bytes]);
    const first = try classifier.filterNonLeader(frame);
    defer std.testing.allocator.free(first.bytes);
    try std.testing.expectEqual(@as(usize, 0), first.bytes.len);
    const recovered = try classifier.filterNonLeader("y");
    defer std.testing.allocator.free(recovered.bytes);
    try std.testing.expectEqual(@as(usize, 0), recovered.bytes.len);
    try std.testing.expect(!recovered.claims_leadership);
    const next = try classifier.filterNonLeader("z");
    defer std.testing.allocator.free(next.bytes);
    try std.testing.expectEqualStrings("z", next.bytes);
    try std.testing.expect(next.claims_leadership);
}

test "Windows attach classifier preserves non-leader origin for carried controls" {
    const controls = [_][2][]const u8{
        .{ "\x1b[?1;", "2u" },
        .{ "\x1b[97;1:", "3u" },
        .{ "\x1b]0;title", "\x07" },
        .{ "\x1bP1$r0", "\x1b\\" },
        .{ "\x1b_kitty", "\x1b\\" },
        .{ "\x1b^private", "\x1b\\" },
    };
    for (controls) |control| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const first = try classifier.filterNonLeader(control[0]);
        defer std.testing.allocator.free(first.bytes);
        try std.testing.expectEqual(@as(usize, 0), first.bytes.len);
        const completed = try classifier.observeLeader(control[1]);
        defer std.testing.allocator.free(completed);
        try std.testing.expectEqual(@as(usize, 0), completed.len);
    }

    var keyboard = InputClassifier.init(std.testing.allocator);
    defer keyboard.deinit();
    const prefix = try keyboard.filterNonLeader("\x1b[");
    defer std.testing.allocator.free(prefix.bytes);
    const completed = try keyboard.observeLeader("A");
    defer std.testing.allocator.free(completed);
    try std.testing.expectEqualStrings("\x1b[A", completed);
}

test "Windows attach classifier bounds ambiguous CSI and SS3 prefixes" {
    const prefixes = [_][]const u8{ "\x1b[", "\x1bO" };
    for (prefixes) |prefix| {
        var classifier = InputClassifier.init(std.testing.allocator);
        defer classifier.deinit();
        const held = try classifier.filterNonLeader(prefix);
        defer std.testing.allocator.free(held.bytes);
        try std.testing.expectEqual(@as(usize, 0), held.bytes.len);
        try std.testing.expect(classifier.hasPendingEscape());
        const flushed = try classifier.flushPendingEscape();
        defer std.testing.allocator.free(flushed.bytes);
        try std.testing.expectEqualStrings(prefix, flushed.bytes);
        try std.testing.expect(flushed.claims_leadership);
    }

    var continuation = InputClassifier.init(std.testing.allocator);
    defer continuation.deinit();
    const held = try continuation.filterNonLeader("\x1b[");
    defer std.testing.allocator.free(held.bytes);
    const arrow = try continuation.filterNonLeader("A");
    defer std.testing.allocator.free(arrow.bytes);
    try std.testing.expectEqualStrings("\x1b[A", arrow.bytes);
    try std.testing.expect(arrow.claims_leadership);

    var ss3 = InputClassifier.init(std.testing.allocator);
    defer ss3.deinit();
    const ss3_prefix = try ss3.filterNonLeader("\x1bO");
    defer std.testing.allocator.free(ss3_prefix.bytes);
    const function_key = try ss3.filterNonLeader("P");
    defer std.testing.allocator.free(function_key.bytes);
    try std.testing.expectEqualStrings("\x1bOP", function_key.bytes);
    try std.testing.expect(function_key.claims_leadership);
}

test "Windows attach classifier scans split CSI incrementally up to carry limit" {
    const stream = try std.testing.allocator.alloc(u8, InputClassifier.max_carry_bytes);
    defer std.testing.allocator.free(stream);
    stream[0] = 0x1b;
    stream[1] = '[';
    @memset(stream[2..], '1');
    stream[stream.len - 1] = 'A';

    var classifier = InputClassifier.init(std.testing.allocator);
    defer classifier.deinit();
    var offset: usize = 0;
    var final_len: usize = 0;
    var final_claims = false;
    while (offset < stream.len) {
        const end = @min(offset + 64, stream.len);
        const result = try classifier.filterNonLeader(stream[offset..end]);
        defer std.testing.allocator.free(result.bytes);
        if (result.bytes.len != 0) {
            final_len = result.bytes.len;
            final_claims = result.claims_leadership;
        }
        offset = end;
    }
    try std.testing.expectEqual(stream.len, final_len);
    try std.testing.expect(final_claims);
    try std.testing.expect(classifier.csiScanWork() < InputClassifier.max_carry_bytes * 2);
}
