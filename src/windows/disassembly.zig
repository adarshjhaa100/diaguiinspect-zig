// The Disassembly panel: instructions around $pc — optionally interleaved
// with the C source line each instruction implements (gdb's source-centric
// mixed mode). Both kinds of rows are breakpoint targets: instruction rows
// by address, source rows by file:line.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Disassembly", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("disassembly");

    render_header();
    render_rows();

    zgui.end();
}

fn render_header() void {
    if (app.app.disassembly_rows_count > 0) {
        render_mode_toggle();
        zgui.sameLine(.{});
        var line: [32]u8 = undefined;
        const text = window.format_address(&line, app.app.disassembly_pc);
        zgui.textDisabled("around $pc = {s}  ({d} rows)", .{
            text, app.app.disassembly_rows_count,
        });
        return;
    }

    // No rows: the most common cause is a program that ran to
    // completion without stopping. Say what to do, not just what is wrong.
    zgui.textUnformattedColored(window.muted_color, "no disassembly yet");
    switch (app.app.status) {
        .no_program => zgui.textUnformattedColored(window.muted_color, "load a program to debug"),
        .ready => render_how_to_stop(),
        .running => zgui.textUnformattedColored(
            window.muted_color,
            "the program is running — Break (F3) stops it here",
        ),
        .stopped => zgui.textUnformattedColored(
            window.muted_color,
            "the target is stopped but $pc could not be read",
        ),
        .exited => render_how_to_stop(),
        .dead => zgui.textUnformattedColored(window.muted_color, "gdb is gone — restart"),
    }
}

/// The C+asm toggle, always visible: it is the panel's mode, and switching
/// re-queries immediately.
fn render_mode_toggle() void {
    var mixed = app.app.disassembly_mixed;
    if (zgui.checkbox("C + asm", .{ .v = &mixed })) {
        app.set_disassembly_mixed(mixed);
    }
    if (zgui.isItemHovered(.{})) {
        zgui.setTooltip(
            "interleave the C source with the instructions\n(recompile with -g for C views)",
            .{},
        );
    }
}

/// The actionable hint for "never stopped": where breakpoints come from
/// and how to run to one.
fn render_how_to_stop() void {
    zgui.textUnformattedColored(window.muted_color, "the program ran to completion without stopping.");
    zgui.textUnformattedColored(window.muted_color, "add a breakpoint, then Run (F1):");
    zgui.bulletText("click a line's left margin in Source", .{});
    zgui.bulletText("click any instruction row here, once stopped", .{});
    zgui.bulletText("type a location in Breakpoints (e.g. main)", .{});
    zgui.bulletText("or relaunch: diaguiinspect-zig --break main ./prog", .{});
}

fn render_rows() void {
    if (!zgui.beginChild("disassembly_lines", .{
        .w = 0.0,
        .h = 0.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        return;
    }

    var index: u32 = 0;
    while (index < app.app.disassembly_rows_count) : (index += 1) {
        switch (app.app.disassembly_rows[index]) {
            .source => |source| render_source_row(source),
            .instruction => |instruction| render_instruction_row(instruction),
        }
    }
    zgui.endChild();
}

/// A C source line: clickable like the Source panel's margin — the same
/// breakpoint, one panel over. The current line highlights yellow.
fn render_source_row(source: app.SourceRow) void {
    const is_current = source.line == app.app.stop.line;
    const has_breakpoint = app.breakpoint_at_line(source.line -| 1);

    var line: [544]u8 = undefined;
    const row_label = window.label(&line, "{s}##dline{d}", .{
        source.text.view(), source.line,
    }) orelse return;

    zgui.pushStyleColor4f(.{ .idx = .text, .c = row_text_color(is_current, has_breakpoint) });
    defer zgui.popStyleColor(.{ .count = 1 });

    var numbered: [560]u8 = undefined;
    const row_text = window.label(&numbered, "{d: >4}  {s}", .{
        source.line, row_label,
    }) orelse return;
    if (zgui.selectable(row_text, .{ .selected = is_current })) {
        app.toggle_breakpoint_at_line(
            app.app.disassembly_mixed_file.view(),
            source.line,
        );
    }
    if (zgui.isItemHovered(.{})) {
        zgui.setTooltip("click: breakpoint at line {d}", .{source.line});
    }
    window.copy_item_pair(
        "Copy line",
        source.text.view(),
        "Copy location",
        compose_location(source.line),
    );
}

fn row_text_color(is_current: bool, has_breakpoint: bool) [4]f32 {
    if (is_current) return window.current_line_color;
    if (has_breakpoint) return window.breakpoint_color;
    return .{ 1.0, 1.0, 1.0, 1.0 };
}

fn compose_location(line: u32) []const u8 {
    // The location for "file.c:12" copies; bounded by the label buffer
    // sized for the longest path grr stores.
    const static = struct {
        var buffer: [512]u8 = undefined;
    };
    const text = std.fmt.bufPrint(&static.buffer, "{s}:{d}", .{
        app.app.disassembly_mixed_file.view(), line,
    }) catch "";
    return text;
}

/// One instruction: click toggles a breakpoint at its address; markers,
/// tooltips and copy follow the pure-mode behavior.
fn render_instruction_row(instruction: app.InstructionRow) void {
    const is_current = instruction.address == app.app.disassembly_pc;
    const breakpoint = app.breakpoint_at_address(instruction.address);

    var line: [192]u8 = undefined;
    const row_label = window.label(&line, "  0x{x}  {s}", .{
        instruction.address, instruction.text.view(),
    }) orelse return;

    if (zgui.selectable(row_label, .{ .selected = is_current })) {
        app.toggle_breakpoint_at_address(instruction.address);
    }
    if (zgui.isItemHovered(.{})) {
        if (breakpoint) |found| {
            zgui.setTooltip("breakpoint {d} here — click to remove", .{found.number});
        } else {
            zgui.setTooltip("click: breakpoint at 0x{x}", .{instruction.address});
        }
    }

    var address_text: [24]u8 = undefined;
    const address = window.format_address(&address_text, instruction.address);
    window.copy_item_pair(
        "Copy instruction",
        row_label,
        "Copy address",
        address,
    );

    if (breakpoint) |found| {
        zgui.sameLine(.{ .spacing = 6.0 });
        window.draw_marker(
            if (found.enabled) window.breakpoint_color else window.breakpoint_disabled_color,
        );
    }
}
