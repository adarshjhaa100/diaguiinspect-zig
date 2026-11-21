// Diagnostic console shared by every window.
//
// diaguiinspect is a frontend for an external process (gdb) whose behavior we do not
// control, so the GUI needs one place where every subsystem reports outputs
// and errors. The host's menu bar carries the single console button: a click
// opens this window and logs an entry, proving the menu's input handling and
// the render loop are alive.

const std = @import("std");
const zgui = @import("zgui");
const ui_chrome = @import("window.zig");

const assert = std.debug.assert;

pub const Level = enum {
    info,
    warn,
    err,
};

/// One console line. Text is stored inline: console entries are produced at a
/// human pace, not a data-plane pace, so a fixed size per entry keeps the ring
/// a single flat array with no fragmentation.
pub const Entry = struct {
    level: Level = .info,
    text_len: u32 = 0,
    text: [text_max]u8 = undefined,
};

pub const text_max: u32 = 192;
pub const entries_max: u32 = 512;

/// Ring buffer of entries. `count` grows monotonically; the entry for a
/// given overall index lives at `entries[index % entries_max]`. The ring
/// overwrites the oldest entry once full, which bounds memory forever.
var entries: [entries_max]Entry = @splat(.{});
var count: u32 = 0;

/// Totals for the console button health badge in `console_footer`.
var err_total: u32 = 0;
var unseen_err_count: u32 = 0;

/// Reader threads log gdb stderr concurrently with the main thread, so all
/// ring mutations take this lock. Contention is irrelevant at log rates. The
/// lock API needs an Io, which diaguiinspect hands over once at startup.
var mutex: std.Io.Mutex = .init;
var console_io: std.Io = undefined;

/// Must be called once before any `log` from any thread.
pub fn set_io(io: std.Io) void {
    console_io = io;
}

pub var window_open: bool = true;

pub const Filter = enum {
    all,
    warnings,
    errors,
};
pub var filter: Filter = .all;
pub var auto_scroll: bool = true;

/// Append one entry, formatting the text in place. A message longer than
/// `text_max` is truncated to fit, because dropping it outright would hide
/// exactly the oversized gdb output we most want to see.
pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    assert(fmt.len > 0);

    var scratch: [text_max + 8]u8 = undefined;
    const full = std.fmt.bufPrint(&scratch, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => scratch[0..text_max],
    };
    assert(full.len <= scratch.len);

    const text_len: u32 = @min(@as(u32, @intCast(full.len)), text_max);

    mutex.lockUncancelable(console_io);
    defer mutex.unlock(console_io);

    const slot = &entries[count % entries_max];
    slot.level = level;
    slot.text_len = text_len;
    @memcpy(slot.text[0..text_len], full[0..text_len]);
    count +%= 1;

    if (level == .err) {
        err_total += 1;
        unseen_err_count += 1;
    }
}

/// How many entries the ring currently holds (bounded by `entries_max`).
pub fn entry_count() u32 {
    return @min(count, entries_max);
}

/// Copy the entry at ring position `index` (0-based, oldest first) into `out`.
/// Returns false if `index` is past the end, so callers can loop without
/// trusting any cached count.
pub fn entry_at(index: u32, out: *Entry) bool {
    if (index >= entry_count()) return false;

    mutex.lockUncancelable(console_io);
    defer mutex.unlock(console_io);

    const overall = count - entry_count() + index;
    out.* = entries[overall % entries_max];
    return true;
}

pub fn error_totals() struct { total: u32, unseen: u32 } {
    mutex.lockUncancelable(console_io);
    defer mutex.unlock(console_io);
    return .{ .total = err_total, .unseen = unseen_err_count };
}

/// Errors are "seen" once the console window renders; reset under the lock
/// because reader threads may be logging concurrently.
fn mark_errors_seen() void {
    mutex.lockUncancelable(console_io);
    defer mutex.unlock(console_io);
    unseen_err_count = 0;
}

pub fn clear() void {
    mutex.lockUncancelable(console_io);
    defer mutex.unlock(console_io);
    count = 0;
    err_total = 0;
    unseen_err_count = 0;
}

/// The console window. Rendered every frame when open; rendering resets the
/// unseen-error count because an open console is precisely where errors are
/// seen. The console window carries the same console button as every other
/// window so that this window's own health is also verifiable.
pub fn window() void {
    if (!zgui.begin("Console", .{ .popen = &window_open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    assert(zgui.getCurrentContext() != null);

    mark_errors_seen();

    if (zgui.button("All", .{})) filter = .all;
    zgui.sameLine(.{});
    if (zgui.button("Warnings", .{})) filter = .warnings;
    zgui.sameLine(.{});
    if (zgui.button("Errors", .{})) filter = .errors;
    zgui.sameLine(.{});
    if (zgui.button("Clear", .{})) clear();
    zgui.sameLine(.{});
    if (zgui.button("Copy all", .{})) copy_all_to_clipboard();
    zgui.sameLine(.{});
    _ = zgui.checkbox("Auto-scroll", .{ .v = &auto_scroll });

    // One entry per (re)appearance proves the frame loop reached this
    // window; logging every frame would bury real messages in seconds.
    if (zgui.isWindowAppearing()) {
        log(.info, "console: window rendered — frame loop is alive", .{});
    }

    const was_at_bottom = zgui.getScrollY() >= zgui.getScrollMaxY() - 1.0;
    if (!zgui.beginChild("console_log", .{
        .w = 0.0,
        .h = 0.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        zgui.end();
        return;
    }

    var entry: Entry = undefined;
    var index: u32 = 0;
    while (entry_at(index, &entry)) : (index += 1) {
        assert(index < entries_max);
        if (passes_filter(entry.level)) render_entry(&entry, index);
    }
    assert(index <= entries_max);

    if (auto_scroll and was_at_bottom) zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
    zgui.endChild();

    zgui.end();
}

/// One console entry: a selectable in its level color so right-click can
/// copy exactly that message.
fn render_entry(entry: *const Entry, index: u32) void {
    const text = entry.text[0..entry.text_len];

    zgui.pushStyleColor4f(.{ .idx = .text, .c = level_color(entry.level) });
    var label_buf: [text_max + 16]u8 = undefined;
    const label = zgui_label(&label_buf, text, index);
    if (label) |row| {
        _ = zgui.selectable(row, .{});
        zgui.popStyleColor(.{ .count = 1 });
        ui_chrome.copy_item("Copy entry", text);
    } else {
        zgui.popStyleColor(.{ .count = 1 });
    }
}

/// "<text>##c<index>" — the entry is the visible label, the index keeps
/// the id unique when two entries read the same.
fn zgui_label(target: []u8, text: []const u8, index: u32) ?[:0]const u8 {
    // text + "##c" + 10 digits + NUL must fit.
    if (text.len + 16 > target.len) return null;
    @memcpy(target[0..text.len], text);
    const suffix = std.fmt.bufPrint(target[text.len..], "##c{d}", .{index}) catch return null;
    target[text.len + suffix.len] = 0;
    return target[0 .. text.len + suffix.len :0];
}

/// The whole filtered view to the clipboard, bounded by the scratch.
fn copy_all_to_clipboard() void {
    var len: u32 = 0;
    var entry: Entry = undefined;
    var index: u32 = 0;
    while (entry_at(index, &entry)) : (index += 1) {
        if (!passes_filter(entry.level)) continue;

        const text = entry.text[0..entry.text_len];
        const copy_len = @min(text.len, ui_chrome.clipboard_scratch.len - len);
        if (copy_len == 0) break;
        @memcpy(ui_chrome.clipboard_scratch[len..][0..copy_len], text[0..copy_len]);
        len += @intCast(copy_len);
        if (len == ui_chrome.clipboard_scratch.len) break;

        ui_chrome.clipboard_scratch[len] = '\n';
        len += 1;
    }
    if (len > 0) {
        len -= 1; // Drop the trailing newline.
        ui_chrome.clipboard_scratch[len] = 0;
        zgui.setClipboardText(ui_chrome.clipboard_scratch[0..len :0]);
    }
}

fn passes_filter(level: Level) bool {
    if (filter == .all) return true;
    if (filter == .warnings) return level == .warn;
    if (filter == .errors) return level == .err;
    return false;
}

fn level_color(level: Level) [4]f32 {
    switch (level) {
        .info => return .{ 0.78, 0.78, 0.78, 1.0 },
        .warn => return .{ 1.0, 0.80, 0.40, 1.0 },
        .err => return .{ 1.0, 0.42, 0.42, 1.0 },
    }
}

/// The console button carried by the host's menu bar, per the project brief:
/// clicking it must make console outputs/errors visible so that the user can
/// check whether this window's GUI is working properly.
pub fn console_footer(window_name: []const u8) void {
    zgui.separator();

    if (zgui.button("Console", .{})) {
        window_open = true;
        log(.info, "{s}: console button clicked — input and render are alive", .{window_name});
        zgui.setWindowFocus("Console");
    }

    // `sameLine` with only spacing places the badge after the button; an
    // `offset_from_start_x` here would be absolute window-space and draw
    // the text on top of the button.
    zgui.sameLine(.{ .spacing = 8.0 });
    const totals = error_totals();
    if (totals.total == 0) {
        zgui.textColored(.{ 0.45, 0.85, 0.45, 1.0 }, "GUI OK — no errors logged", .{});
    } else {
        if (totals.unseen > 0) {
            zgui.textColored(.{ 1.0, 0.42, 0.42, 1.0 }, "{d} errors ({d} unseen)", .{
                totals.total, totals.unseen,
            });
        } else {
            zgui.textColored(.{ 0.90, 0.70, 0.40, 1.0 }, "{d} errors (seen)", .{totals.total});
        }
    }
}

test "log appends and reads back in order" {
    clear();
    log(.info, "first {d}", .{1});
    log(.warn, "second", .{});

    var entry: Entry = undefined;
    try std.testing.expect(entry_at(0, &entry));
    try std.testing.expectEqualStrings("first 1", entry.text[0..entry.text_len]);
    try std.testing.expectEqual(Level.info, entry.level);

    try std.testing.expect(entry_at(1, &entry));
    try std.testing.expectEqualStrings("second", entry.text[0..entry.text_len]);
    try std.testing.expectEqual(Level.warn, entry.level);

    try std.testing.expect(!entry_at(2, &entry));
    try std.testing.expectEqual(@as(u32, 2), entry_count());
}

test "ring overwrites the oldest entry when full" {
    clear();
    var index: u32 = 0;
    while (index < entries_max + 10) : (index += 1) {
        log(.info, "entry {d}", .{index});
    }
    assert(index == entries_max + 10);

    var entry: Entry = undefined;
    try std.testing.expect(entry_at(0, &entry));
    // The oldest surviving entry is number 10: entries 0..9 were overwritten.
    try std.testing.expectEqualStrings("entry 10", entry.text[0..entry.text_len]);
    try std.testing.expectEqual(entries_max, entry_count());

    try std.testing.expect(entry_at(entry_count() - 1, &entry));
    // The newest entry is number 521 (entries_max + 10 - 1, the last written).
    try std.testing.expectEqualStrings("entry 521", entry.text[0..entry.text_len]);
}

test "overlong messages are truncated, not dropped" {
    clear();
    const long: [400]u8 = @splat('x');
    log(.err, "{s}", .{long});
    var entry: Entry = undefined;
    try std.testing.expect(entry_at(0, &entry));
    try std.testing.expectEqual(text_max, entry.text_len);
    const totals = error_totals();
    try std.testing.expectEqual(@as(u32, 1), totals.total);
    clear();
}
