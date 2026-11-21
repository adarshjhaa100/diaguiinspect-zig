// The stack window: backtrace frames, one bounded list.
//
// Selecting a frame re-queries the stopped state through gdb, so the
// registers, disassembly and source windows all follow the selection.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

pub var open: bool = true;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Stack", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("stack");

    render_list();

    zgui.end();
}

fn render_list() void {
    if (app.app.frames_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "no stack — stop the target first");
        return;
    }

    zgui.textDisabled("{d} frames", .{app.app.frames_count});

    if (!zgui.beginChild("stack_frames", .{
        .w = 0.0,
        .h = 0.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        return;
    }

    var index: u32 = 0;
    while (index < app.app.frames_count) : (index += 1) {
        render_frame_row(&app.app.frames[index]);
    }
    zgui.endChild();
}

fn render_frame_row(frame: *const app.Frame) void {
    var line: [448]u8 = undefined;
    const row_label = window.label(&line, "#{d}  0x{x}  {s}", .{
        frame.level, frame.addr, frame.func.view(),
    }) orelse return;

    const selected = frame.level == app.app.selected_frame;
    if (zgui.selectable(row_label, .{ .selected = selected })) {
        app.select_frame(frame.level);
    }

    // Right-click copies the frame line, or the bare address.
    var address_text: [24]u8 = undefined;
    const address = window.format_address(&address_text, frame.addr);
    window.copy_item_pair(
        "Copy frame",
        row_label,
        "Copy address",
        address,
    );

    if (frame.line > 0 and frame.file.len > 0) {
        zgui.sameLine(.{});
        zgui.textDisabled("{s}:{d}", .{ frame.file.view(), frame.line });
    }
}
