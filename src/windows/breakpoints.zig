// The breakpoints window: gdb's breakpoint table plus insertion and
// enable/disable/delete controls.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

pub var open: bool = true;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Breakpoints", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("breakpoints");

    render_insert_row();
    zgui.separator();
    render_table();

    zgui.end();
}

fn render_insert_row() void {
    // The field is the primary way to say where to stop; spell the syntax
    // out so it needs no manual.
    zgui.textUnformattedColored(window.muted_color, "new breakpoint (Enter or Insert):");
    zgui.setNextItemWidth(-70.0);
    const submitted = zgui.inputText("##breakpoint_input", .{
        .buf = &app.app.breakpoint_input,
        .flags = .{ .enter_returns_true = true },
    });
    if (submitted) {
        zgui.setKeyboardFocusHere(-1);
    }

    zgui.sameLine(.{});
    if (zgui.button("Insert", .{}) or submitted) {
        app.insert_breakpoint(std.mem.sliceTo(&app.app.breakpoint_input, 0));
        @memset(app.app.breakpoint_input[0..app.input_bytes_max], 0);
        app.app.breakpoint_input[app.input_bytes_max] = 0;
    }
    zgui.textDisabled("location: main · file.c:12 · *0x401126", .{});
}

fn render_table() void {
    if (app.app.breakpoints_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "no breakpoints");
        return;
    }

    if (!zgui.beginTable("breakpoints_table", .{ .column = 5 })) return;
    defer zgui.endTable();

    zgui.tableSetupColumn("num", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 42.0 });
    zgui.tableSetupColumn("on", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 40.0 });
    zgui.tableSetupColumn("address", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 110.0 });
    zgui.tableSetupColumn("where", .{});
    zgui.tableSetupColumn("actions", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 110.0 });
    zgui.tableHeadersRow();

    var index: u32 = 0;
    while (index < app.app.breakpoints_count) : (index += 1) {
        zgui.tableNextRow(.{});
        render_row(&app.app.breakpoints[index]);
    }
}

fn render_row(breakpoint: *app.Breakpoint) void {
    var line: [256]u8 = undefined;

    _ = zgui.tableNextColumn();
    const number = std.fmt.bufPrint(&line, "{d} ({s})", .{
        breakpoint.number,
        if (breakpoint.is_watchpoint) "watch" else "break",
    }) catch return;
    zgui.textUnformatted(number);

    _ = zgui.tableNextColumn();
    var id: [40]u8 = undefined;
    const enabled_id = window.label(&id, "##enabled{d}", .{breakpoint.number}) orelse return;
    if (zgui.checkbox(enabled_id, .{ .v = &breakpoint.enabled })) {
        // The checkbox already flipped the local state; tell gdb to match it.
        app.set_breakpoint_enabled(breakpoint, breakpoint.enabled);
    }
    // The row's one always-present widget: right-click copies the row.
    var row_text: [256]u8 = undefined;
    const row = std.fmt.bufPrint(&row_text, "{d} {s} {s}", .{
        breakpoint.number,
        if (breakpoint.enabled) "enabled" else "disabled",
        breakpoint.location.view(),
    }) catch "";
    window.copy_item("Copy breakpoint", row);

    _ = zgui.tableNextColumn();
    if (breakpoint.address > 0) {
        const address = window.format_address(&line, breakpoint.address);
        zgui.textUnformatted(address);
    } else {
        zgui.textUnformattedColored(window.muted_color, "pending");
    }

    _ = zgui.tableNextColumn();
    render_where(breakpoint, &line);

    _ = zgui.tableNextColumn();
    var delete_id: [40]u8 = undefined;
    const delete_label = window.label(&delete_id, "delete##{d}", .{breakpoint.number}) orelse return;
    if (zgui.smallButton(delete_label)) app.delete_breakpoint(breakpoint.number);
}

fn render_where(breakpoint: *const app.Breakpoint, line: []u8) void {
    if (breakpoint.is_watchpoint) {
        zgui.textUnformatted(breakpoint.location.view());
        return;
    }

    if (breakpoint.line > 0 and !breakpoint.file.empty()) {
        const text = std.fmt.bufPrint(line, "{s}:{d}", .{
            breakpoint.file.view(), breakpoint.line,
        }) catch return;
        zgui.textUnformatted(text);
        return;
    }

    if (!breakpoint.func.empty()) {
        zgui.textUnformatted(breakpoint.func.view());
        return;
    }
    zgui.textUnformattedColored(window.muted_color, breakpoint.location.view());
}
