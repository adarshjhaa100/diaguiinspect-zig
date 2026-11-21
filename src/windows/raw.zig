// The raw gdb window: a console mirror plus a command line.
//
// Typing here goes through `-interpreter-exec console` so that arbitrary gdb
// commands cannot desynchronize diaguiinspect's MI parser — the same lesson the
// original grr learned the hard way. Up/Down walks command history while the
// input is focused.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

/// Refocus the input after a submitted command so that many commands in a
/// row do not require re-clicking the field.
var refocus_input: bool = false;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Raw gdb", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("raw gdb");

    render_log();
    render_input();

    zgui.end();
}

fn render_log() void {
    // The log is mostly what users want to copy out of the whole GUI; a
    // per-line right-click plus one bulk button covers both cases.
    if (zgui.button("Copy all", .{})) copy_all_to_clipboard();

    if (!zgui.beginChild("raw_log", .{
        .w = 0.0,
        .h = -32.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        return;
    }

    const line_count = app.app.raw.line_count();
    if (line_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "gdb console output will appear here");
    }

    var index: u32 = 0;
    while (index < line_count) : (index += 1) {
        render_line(index);
    }

    if (zgui.getScrollY() >= zgui.getScrollMaxY() - 1.0) {
        zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
    }
    zgui.endChild();
}

fn render_line(index: u32) void {
    const text = app.app.raw.line_at(index);

    // Wrap the line in a selectable so it can be right-click-copied; the
    // index keeps ids unique for repeated lines.
    var label_buf: [app.raw_line_bytes_max + 16]u8 = undefined;
    const row = window.label(&label_buf, "{s}##raw{d}", .{ text, index }) orelse {
        zgui.textUnformatted(text);
        return;
    };
    _ = zgui.selectable(row, .{});
    window.copy_item("Copy line", text);
}

/// The newest lines that fit the clipboard scratch, oldest dropped.
fn copy_all_to_clipboard() void {
    const line_count = app.app.raw.line_count();
    var len: u32 = 0;
    var index: u32 = 0;
    while (index < line_count) : (index += 1) {
        const text = app.app.raw.line_at(index);
        const copy_len = @min(text.len, window.clipboard_scratch.len - len);
        if (copy_len == 0) break;
        @memcpy(window.clipboard_scratch[len..][0..copy_len], text[0..copy_len]);
        len += @intCast(copy_len);
        if (len == window.clipboard_scratch.len) break;

        window.clipboard_scratch[len] = '\n';
        len += 1;
    }
    if (len > 0) {
        len -= 1; // Drop the trailing newline.
        window.clipboard_scratch[len] = 0;
        zgui.setClipboardText(window.clipboard_scratch[0..len :0]);
    }
}

fn render_input() void {
    if (refocus_input) {
        refocus_input = false;
        zgui.setKeyboardFocusHere(0);
    }

    const submitted = zgui.inputText("##raw_input", .{
        .buf = &app.app.raw_input,
        .flags = .{ .enter_returns_true = true },
    });

    render_history_keys();

    if (!submitted) return;

    const command = std.mem.sliceTo(&app.app.raw_input, 0);
    app.send_raw_console(command);
    app.raw_history_append(command);
    @memset(app.app.raw_input[0..app.input_bytes_max], 0);
    app.app.raw_input[app.input_bytes_max] = 0;
    refocus_input = true;
}

/// Walk the command history with Up/Down while the input holds focus.
fn render_history_keys() void {
    if (!zgui.isItemActive()) return;

    if (zgui.isKeyPressed(.up_arrow, false)) {
        apply_history(-1);
    }
    if (zgui.isKeyPressed(.down_arrow, false)) {
        apply_history(1);
    }
}

fn apply_history(direction: i32) void {
    const entry = app.raw_history_walk(direction) orelse return;
    assert(entry.len < app.input_bytes_max);

    @memset(app.app.raw_input[0..app.input_bytes_max], 0);
    @memcpy(app.app.raw_input[0..entry.len], entry);
    app.app.raw_input[entry.len] = 0;
}
