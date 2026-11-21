// Shared window chrome: default geometry and appearance logging.
//
// Every diaguiinspect window follows the same shape so that they stay consistent:
// default geometry first, then `zgui.begin`, then content, then the console
// footer (the health-check button the project brief requires in every
// window), then `zgui.end`.

const std = @import("std");
const zgui = @import("zgui");
const console = @import("console.zig");

const assert = std.debug.assert;

/// Log a window's first appearance after being (re)opened: one console entry
/// per appearance proves the window's render path ran, without spamming the
/// console every frame.
pub fn log_appearance(window_name: []const u8) void {
    if (!zgui.isWindowAppearing()) return;
    console.log(.info, "{s}: window rendered", .{window_name});
}

/// Format a u64 address as `0x`-prefixed hex into `target`. Callers pass
/// buffers of at least 18 bytes, so formatting cannot fail.
pub fn format_address(target: []u8, address: u64) []const u8 {
    assert(target.len >= 18);
    const text = std.fmt.bufPrint(target, "0x{x}", .{address}) catch {
        // Unreachable: the assert above bounds the format's worst case.
        return target[0..0];
    };
    return text;
}

/// Format a zgui label (which must be 0-terminated) into a fixed buffer.
/// Returns null when it does not fit; callers drop the widget rather than
/// corrupt the label.
pub fn label(target: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    // Reserve one byte for the terminator.
    const text = std.fmt.bufPrint(target[0 .. target.len - 1], fmt, args) catch return null;
    assert(text.len < target.len);
    target[text.len] = 0;
    return target[0..text.len :0];
}

/// Scratch for building one clipboard payload: large enough for the whole
/// console ring, and the cap for "copy all" of larger rings.
pub var clipboard_scratch: [128 * 1024]u8 = undefined;

/// Copy `text` to the clipboard, bounded by the scratch; anything longer
/// is truncated, which every caller can live with.
pub fn copy_to_clipboard(text: []const u8) void {
    const copy_len = @min(text.len, clipboard_scratch.len);
    @memcpy(clipboard_scratch[0..copy_len], text[0..copy_len]);
    clipboard_scratch[copy_len] = 0;
    zgui.setClipboardText(clipboard_scratch[0..copy_len :0]);
}

/// Right-click context menu on the last rendered item: one copy action.
/// ImGui has no text selection, so per-item menus are the idiom; this keeps
/// the affordance identical in every panel.
pub fn copy_item(menu_label: [:0]const u8, text: []const u8) void {
    if (!zgui.beginPopupContextItem()) return;

    if (zgui.menuItem(menu_label, .{})) {
        copy_to_clipboard(text);
    }
    zgui.endPopup();
}

/// Two copy actions on the last item, for rows with a natural pair such as
/// an instruction's text and its address.
pub fn copy_item_pair(
    first_label: [:0]const u8,
    first_text: []const u8,
    second_label: [:0]const u8,
    second_text: []const u8,
) void {
    if (!zgui.beginPopupContextItem()) return;

    if (zgui.menuItem(first_label, .{})) copy_to_clipboard(first_text);
    if (zgui.menuItem(second_label, .{})) copy_to_clipboard(second_text);
    zgui.endPopup();
}

/// The color of the current-pc highlight, shared by the source and
/// disassembly windows.
pub const current_line_color: [4]f32 = .{ 0.95, 0.85, 0.30, 1.0 };

/// The color of an enabled breakpoint marker.
pub const breakpoint_color: [4]f32 = .{ 1.0, 0.35, 0.35, 1.0 };

/// The color of a disabled breakpoint marker.
pub const breakpoint_disabled_color: [4]f32 = .{ 0.55, 0.55, 0.55, 1.0 };

/// The color used for register values changed since the previous stop.
pub const changed_color: [4]f32 = .{ 1.0, 0.55, 0.30, 1.0 };

pub const ok_color: [4]f32 = .{ 0.45, 0.85, 0.45, 1.0 };
pub const error_color: [4]f32 = .{ 1.0, 0.42, 0.42, 1.0 };
pub const muted_color: [4]f32 = .{ 0.60, 0.60, 0.60, 1.0 };

/// Pack a float color the way imgui's IM_COL32 does: ABGR.
pub fn color_u32(color: [4]f32) u32 {
    const r: u32 = @intFromFloat(@min(color[0] * 255.0 + 0.5, 255.0));
    const g: u32 = @intFromFloat(@min(color[1] * 255.0 + 0.5, 255.0));
    const b: u32 = @intFromFloat(@min(color[2] * 255.0 + 0.5, 255.0));
    const a: u32 = @intFromFloat(@min(color[3] * 255.0 + 0.5, 255.0));
    return a << 24 | b << 16 | g << 8 | r;
}

/// Draw a solid dot at the current cursor position: the breakpoint marker.
/// Drawn as geometry rather than a font glyph — imgui's default font has no
/// dot glyph, and geometry stays crisp at any font size.
pub fn draw_marker(color: [4]f32) void {
    const draw_list = zgui.getWindowDrawList();
    const pos = zgui.getCursorScreenPos();
    const font_size = zgui.getFontSize();

    draw_list.addCircleFilled(.{
        .p = .{ pos[0] + font_size * 0.4, pos[1] + font_size * 0.55 },
        .r = font_size * 0.3,
        .col = color_u32(color),
    });
}
