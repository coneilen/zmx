const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

fn writePwd(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal) void {
    const pwd = term.getPwd() orelse return;
    if (pwd.len == 0) return;
    writer.print("\x1b]7;{s}\x1b\\", .{pwd}) catch {};
}

/// Serialize a terminal as replayable VT. The scrollback is emitted first so
/// that a newly attached terminal gets the same scrollback and visible screen,
/// rather than merely receiving the raw bytes that happened to fill it.
pub fn serialize(
    alloc: std.mem.Allocator,
    term: *ghostty_vt.Terminal,
) ?[]u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    const had_synchronized_output = term.modes.get(.synchronized_output);
    if (had_synchronized_output) term.modes.set(.synchronized_output, false);
    defer if (had_synchronized_output) term.modes.set(.synchronized_output, true);

    const pages = &term.screens.active.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    const has_scrollback = !screen_top.eql(active_top);

    if (has_scrollback) {
        if (active_top.up(1)) |scrollback_bottom_row| {
            var scrollback_bottom = scrollback_bottom_row;
            scrollback_bottom.x = @intCast(pages.cols - 1);

            var formatter = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
            formatter.content = .{
                .selection = ghostty_vt.Selection.init(
                    screen_top,
                    scrollback_bottom,
                    false,
                ),
            };
            formatter.extra = .none;
            formatter.format(&builder.writer) catch return null;
        }
        builder.writer.writeAll("\x1b[2J\x1b[H\x1b[0m") catch return null;
    }

    var formatter = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
    const active_tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const active_br = pages.pin(.{
        .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        },
    });
    if (active_tl != null and active_br != null) {
        formatter.content = .{
            .selection = ghostty_vt.Selection.init(
                active_tl.?,
                active_br.?,
                false,
            ),
        };
    }
    formatter.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false,
        .pwd = false,
        .keyboard = true,
        .screen = .all,
    };
    formatter.format(&builder.writer) catch return null;
    writePwd(&builder.writer, term);
    if (term.getTitle()) |title| {
        builder.writer.print("\x1b]2;{s}\x07", .{title}) catch return null;
    }

    const output = builder.writer.buffered();
    if (output.len == 0) return null;
    return alloc.dupe(u8, output) catch null;
}
