// The source window: the current frame's file with breakpoint markers.
//
// Clicking a line's margin toggles a breakpoint there; the current line is
// highlighted and the view follows it. Large files are clipped with
// ImGui's ListClipper so rendering stays bounded per frame.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

/// The line followed the last time this window scrolled, so the view only
/// jumps when the target actually moved.
var followed_line: u32 = 0;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Source", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("source");

    render_header();

    if (!zgui.beginChild("source_lines", .{
        .w = 0.0,
        .h = 0.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        zgui.end();
        return;
    }
    render_lines();
    follow_current_line();
    zgui.endChild();

    zgui.end();
}

fn render_header() void {
    if (app.app.source_valid) {
        zgui.textDisabled("{s}  ({d} lines)", .{
            app.app.source_path.view(), app.app.source_line_count,
        });
        return;
    }

    // No file loaded: usually the target never stopped (a program that
    // runs to completion), or the frame has no debug info. Say which.
    zgui.textUnformattedColored(window.muted_color, "no source loaded");
    switch (app.app.status) {
        .no_program => zgui.textUnformattedColored(window.muted_color, "load a program to debug"),
        .ready, .exited => {
            zgui.textUnformattedColored(
                window.muted_color,
                "the program ran without stopping at any file.",
            );
            zgui.textUnformattedColored(
                window.muted_color,
                "add a breakpoint (click a margin below once source shows, or",
            );
            zgui.textUnformattedColored(
                window.muted_color,
                "type a location in Breakpoints), then Run (F1).",
            );
        },
        .running => zgui.textUnformattedColored(
            window.muted_color,
            "the program is running — Break (F3) stops it",
        ),
        .stopped => zgui.textUnformattedColored(
            window.muted_color,
            "the stopped frame has no source — try the Disassembly panel",
        ),
        .dead => zgui.textUnformattedColored(window.muted_color, "gdb is gone — restart"),
    }
}

fn render_lines() void {
    if (!app.app.source_valid) return;

    var clipper: zgui.ListClipper = zgui.ListClipper.init();
    clipper.begin(@intCast(app.app.source_line_count), zgui.getTextLineHeightWithSpacing());

    while (clipper.step()) {
        var line_index: i32 = clipper.DisplayStart;
        while (line_index < clipper.DisplayEnd) : (line_index += 1) {
            assert(line_index >= 0);
            render_line(@intCast(line_index));
        }
    }
    clipper.end();
}

fn render_line(line_index: u32) void {
    const text = app.source_line_text(line_index);
    const is_current = line_index + 1 == app.app.source_current_line;
    const has_breakpoint = app.breakpoint_at_line(line_index);

    // The marker is an invisible clickable strip with the dot drawn as
    // geometry on top; the default font has no dot glyph.
    var marker: [32]u8 = undefined;
    const marker_label = window.label(&marker, "##bp{d}", .{line_index}) orelse return;

    if (zgui.selectable(marker_label, .{ .selected = is_current, .w = 16.0 })) {
        app.toggle_breakpoint_at_line(app.app.source_path.view(), line_index + 1);
    }
    // The strip is narrow and by design; a tooltip is what makes it a
    // discoverable breakpoint target instead of a dead margin.
    if (zgui.isItemHovered(.{})) {
        if (has_breakpoint) {
            zgui.setTooltip("breakpoint at line {d} — click to remove", .{line_index + 1});
        } else {
            zgui.setTooltip("click: breakpoint at line {d}", .{line_index + 1});
        }
    }
    // Right-click copies the line, or its location for other panels.
    var location: [512]u8 = undefined;
    const location_text = std.fmt.bufPrint(&location, "{s}:{d}", .{
        app.app.source_path.view(), line_index + 1,
    }) catch "";
    window.copy_item_pair(
        "Copy line",
        text,
        "Copy location",
        location_text,
    );
    if (has_breakpoint) {
        zgui.sameLine(.{ .offset_from_start_x = 2.0, .spacing = 0.0 });
        window.draw_marker(window.breakpoint_color);
    }

    zgui.sameLine(.{ .offset_from_start_x = 20.0, .spacing = 0.0 });
    var line: [512]u8 = undefined;
    const composed = std.fmt.bufPrint(&line, "{d: >4}  {s}", .{ line_index + 1, text }) catch return;

    if (is_current) {
        zgui.textUnformattedColored(window.current_line_color, composed);
    } else if (has_breakpoint) {
        zgui.textUnformattedColored(window.breakpoint_color, composed);
    } else {
        zgui.textUnformatted(composed);
    }
}

/// Scroll the current line into view when it changed since the last frame,
/// leaving the user free to scroll away afterwards.
fn follow_current_line() void {
    if (!app.app.source_valid) return;
    if (app.app.source_current_line == followed_line) return;

    followed_line = app.app.source_current_line;
    if (app.app.source_current_line == 0) return;
    if (app.app.source_current_line > app.app.source_line_count) return;

    const line_height = zgui.getTextLineHeightWithSpacing();
    const wanted_line: f32 = @floatFromInt(app.app.source_current_line);
    zgui.setScrollY(@max(wanted_line - 10.0, 0.0) * line_height);
}
