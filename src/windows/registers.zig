// The registers window: one bounded table of register names and values.
//
// Values that changed since the previous stop are highlighted, so a single
// glance shows what an instruction actually did.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Registers", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("registers");

    if (zgui.button("Refresh", .{})) app.refresh_registers();
    zgui.sameLine(.{});
    if (zgui.button("Copy all", .{})) copy_all_registers();
    zgui.sameLine(.{});
    zgui.textDisabled("{d} registers — click a value to copy it", .{
        app.app.registers_count,
    });

    render_table();

    zgui.end();
}

/// The whole register set as "name value" lines, for pasting anywhere.
fn copy_all_registers() void {
    var len: u32 = 0;
    var index: u32 = 0;
    while (index < app.app.registers_count) : (index += 1) {
        const register = &app.app.registers[index];
        if (register.name.empty()) continue;

        var row: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&row, "{s} {s}\n", .{
            register.name.view(), register.value.view(),
        }) catch break;
        const copy_len = @min(text.len, window.clipboard_scratch.len - len);
        if (copy_len == 0) break;
        @memcpy(window.clipboard_scratch[len..][0..copy_len], text[0..copy_len]);
        len += @intCast(copy_len);
    }
    if (len > 0) {
        window.clipboard_scratch[len] = 0;
        zgui.setClipboardText(window.clipboard_scratch[0..len :0]);
    }
}

fn render_table() void {
    if (app.app.registers_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "no register data — stop the target first");
        return;
    }

    if (!zgui.beginTable("registers_table", .{ .column = 3 })) return;
    defer zgui.endTable();

    zgui.tableSetupColumn("name", .{});
    zgui.tableSetupColumn("value", .{});
    zgui.tableSetupColumn("state", .{});
    zgui.tableHeadersRow();

    var index: u32 = 0;
    while (index < app.app.registers_count) : (index += 1) {
        // gdb pads its register numbering with empty names; they are not
        // rows anyone can read.
        if (app.app.registers[index].name.empty()) continue;

        zgui.tableNextRow(.{});
        render_row(&app.app.registers[index], index);
    }
}

fn render_row(register: *const app.Register, index: u32) void {
    _ = zgui.tableNextColumn();
    zgui.textUnformatted(register.name.view());

    // The value is a click-to-copy selectable: register values are the
    // things users move to other tools most, and a click is faster than
    // any menu. The hover frame makes the affordance visible.
    _ = zgui.tableNextColumn();
    const value_color = if (register.changed) window.changed_color else .{ 1.0, 1.0, 1.0, 1.0 };
    zgui.pushStyleColor4f(.{ .idx = .text, .c = value_color });
    var label_buf: [64]u8 = undefined;
    const value_label = window.label(&label_buf, "{s}##reg{d}", .{
        register.value.view(), index,
    }) orelse {
        zgui.popStyleColor(.{ .count = 1 });
        return;
    };
    if (zgui.selectable(value_label, .{})) {
        window.copy_to_clipboard(register.value.view());
    }
    zgui.popStyleColor(.{ .count = 1 });
    if (zgui.isItemHovered(.{})) {
        zgui.setTooltip("click copies the value", .{});
    }

    _ = zgui.tableNextColumn();
    if (register.changed) {
        zgui.textUnformattedColored(window.changed_color, "changed");
    }
}
