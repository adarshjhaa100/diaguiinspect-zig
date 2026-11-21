// The Session window: target status, execution control and threads.
//
// This is the cockpit: it mirrors diaguiinspect's own view of the gdb session (which
// may disagree with reality — the console window exists precisely to make
// such disagreements visible) and drives the standard execution commands.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Session", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("Session");

    render_status();
    zgui.separator();
    render_controls();
    zgui.separator();
    render_threads();

    zgui.end();
}

/// One display row of the status line: label plus color.
const StatusDisplay = struct {
    text: []const u8,
    color: [4]f32,
};

fn render_status() void {
    if (app.app.mode != .gdb) {
        zgui.textColored(window.ok_color, "mode: {s}", .{@tagName(app.app.mode)});
        if (app.app.mode == .rr) {
            zgui.textDisabled("trace: {s}", .{app.app.rr_trace.view()});
        }
        if (app.app.mode == .vgdb and !app.app.vgdb_pid.empty()) {
            zgui.textDisabled("pid: {s}", .{app.app.vgdb_pid.view()});
        }
    }

    const status: StatusDisplay = switch (app.app.status) {
        .no_program => .{ .text = "no program", .color = window.muted_color },
        .ready => .{ .text = "ready", .color = window.ok_color },
        .running => .{ .text = "running", .color = .{ 0.45, 0.70, 1.0, 1.0 } },
        .stopped => .{ .text = "stopped", .color = window.current_line_color },
        .exited => .{ .text = "exited", .color = window.muted_color },
        .dead => .{ .text = "gdb gone", .color = window.error_color },
    };
    zgui.textColored(status.color, "status: {s}", .{status.text});

    zgui.textDisabled("program: {s}", .{app.app.program.view()});
    if (app.app.inferior_pid > 0) {
        zgui.sameLine(.{});
        zgui.textDisabled("pid {d}", .{app.app.inferior_pid});
    }

    if (app.app.status == .stopped) render_stop_info();

    // A ready program with nothing to stop at runs to completion in a
    // blink and every panel looks broken; head that off.
    if ((app.app.status == .ready or app.app.status == .exited) and
        app.app.breakpoints_count == 0 and app.app.mode == .gdb)
    {
        zgui.textColored(
            window.changed_color,
            "no breakpoints set — the program will run straight to exit.",
            .{},
        );
        zgui.textUnformattedColored(
            window.muted_color,
            "Breakpoints: type a location in that panel, click a source",
        );
        zgui.textUnformattedColored(
            window.muted_color,
            "margin or an instruction row, or relaunch with --break main.",
        );
    }
}

fn render_stop_info() void {
    const stop = &app.app.stop;
    if (!stop.valid) return;

    zgui.textColored(window.current_line_color, "at {s}", .{stop.func.view()});
    if (stop.line > 0) {
        zgui.sameLine(.{});
        zgui.textColored(window.current_line_color, "{s}:{d}", .{
            stop.file.view(), stop.line,
        });
    }
    // The one address every other panel wants: copy $pc to paste into
    // the memory panel's address field.
    zgui.sameLine(.{});
    var pc_text: [24]u8 = undefined;
    const pc = window.format_address(&pc_text, stop.pc);
    if (zgui.smallButton("copy $pc")) window.copy_to_clipboard(pc);
    if (zgui.isItemHovered(.{})) {
        zgui.setTooltip("copies {s} — paste it into Memory's address field", .{pc});
    }

    var line: [96]u8 = undefined;
    if (stop.breakpoint_number > 0) {
        const text = std.fmt.bufPrint(&line, "breakpoint {d} hit", .{
            stop.breakpoint_number,
        }) catch return;
        zgui.textUnformattedColored(window.breakpoint_color, text);
    }
    if (stop.reason.view().len > 0) {
        zgui.textUnformattedColored(window.muted_color, stop.reason.view());
    }
}

fn render_controls() void {
    render_run_controls();
    zgui.separator();
    render_step_controls();
    render_reverse_controls();
}

fn render_run_controls() void {
    const status = app.app.status;
    const width = button_width();

    zgui.beginDisabled(.{ .disabled = !(status == .ready or status == .exited) });
    if (zgui.button("Run\tF1", .{ .w = width })) app.run();
    zgui.endDisabled();

    zgui.sameLine(.{});
    zgui.beginDisabled(.{ .disabled = status != .stopped });
    if (zgui.button("Continue\tF2", .{ .w = width })) app.continue_execution();
    zgui.endDisabled();

    zgui.sameLine(.{});
    zgui.beginDisabled(.{ .disabled = status != .running });
    if (zgui.button("Break\tF3", .{ .w = width })) app.interrupt();
    zgui.endDisabled();

    zgui.sameLine(.{});
    zgui.beginDisabled(.{ .disabled = !(status == .running or status == .stopped) });
    if (zgui.button("Kill", .{ .w = width })) app.kill_inferior();
    zgui.endDisabled();
}

fn render_step_controls() void {
    const stopped = app.app.status == .stopped;
    const width = button_width();

    zgui.beginDisabled(.{ .disabled = !stopped });
    if (zgui.button("Step\tF7", .{ .w = width })) app.step_line();
    zgui.sameLine(.{});
    if (zgui.button("Next\tF8", .{ .w = width })) app.next_line();
    zgui.sameLine(.{});
    if (zgui.button("Stepi\tF5", .{ .w = width })) app.step_instruction();
    zgui.sameLine(.{});
    if (zgui.button("Nexti\tF6", .{ .w = width })) app.next_instruction();
    zgui.sameLine(.{});
    if (zgui.button("Finish\tF9", .{ .w = width })) app.finish_execution();
    zgui.endDisabled();
}

fn render_reverse_controls() void {
    // rr recordings run in both directions; the original grr binds this to
    // shift-modified keys, diaguiinspect keeps it visible instead so the capability
    // is discoverable. Outside rr the row sits disabled.
    const reverse = app.app.mode == .rr;
    const width = button_width();

    zgui.beginDisabled(.{ .disabled = !reverse });
    if (zgui.button("◀ Run", .{ .w = width })) app.reverse_continue();
    zgui.sameLine(.{});
    if (zgui.button("◀ Step", .{ .w = width })) app.reverse_step_line();
    zgui.sameLine(.{});
    if (zgui.button("◀ Next", .{ .w = width })) app.reverse_next_line();
    zgui.sameLine(.{});
    if (zgui.button("◀ Stepi", .{ .w = width })) app.reverse_step_instruction();
    zgui.sameLine(.{});
    if (zgui.button("◀ Finish", .{ .w = width })) app.reverse_finish_execution();
    zgui.endDisabled();
}

/// Control buttons share the panel's width: wide panels get comfortable
/// buttons, cramped ones shrink to a floor instead of overflowing the row.
fn button_width() f32 {
    const available = zgui.getContentRegionAvail()[0];
    return @min(@max(available / 5.5, 72.0), 110.0);
}

fn render_threads() void {
    zgui.textDisabled("threads", .{});
    if (app.app.threads_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "none reported");
        return;
    }

    var index: u32 = 0;
    while (index < app.app.threads_count) : (index += 1) {
        const thread = &app.app.threads[index];
        // A remote target (rr, vgdb) reports whatever it reports; a thread
        // without an id is a row nobody can select, so skip it.
        if (thread.id == 0) continue;

        var line: [96]u8 = undefined;
        const row_label = window.label(&line, "{s}#{d}  {s}  {s}", .{
            if (thread.current) "*" else " ",
            thread.id,
            thread.name.view(),
            thread.state.view(),
        }) orelse break;

        if (thread.current) {
            zgui.textUnformattedColored(window.current_line_color, row_label);
        } else {
            if (zgui.selectable(row_label, .{})) app.select_thread(thread.id);
        }
    }
}
