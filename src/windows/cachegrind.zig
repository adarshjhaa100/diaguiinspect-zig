// The cachegrind window: totals per event kind, then the costliest
// functions with a per-line detail table for the selected one.
//
// The function table is sorted by the first event (Ir, instruction reads),
// which is the dominant metric for cachegrind output.
// window it ends with the console button.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const cachegrind = @import("../cachegrind.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

/// The selected function for the detail table, with its cached sorted rows.
var selected: u32 = 0;
var detail_rows: [cachegrind.lines_max]u32 = undefined;
var detail_count: u32 = 0;
var detail_selected: u32 = std.math.maxInt(u32);

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("cachegrind", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("cachegrind");

    if (!cachegrind.parse_done) {
        zgui.textUnformattedColored(window.muted_color, "parsing cachegrind output...");
        zgui.textDisabled("{d}%", .{cachegrind.percent_done()});
        zgui.end();
        return;
    }

    render_totals();
    zgui.separator();
    render_functions();
    zgui.separator();
    render_detail();

    zgui.end();
}

fn render_totals() void {
    if (cachegrind.parse_failed) {
        zgui.textUnformattedColored(window.error_color, "profile could not be parsed");
        return;
    }
    if (cachegrind.events_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "no events in profile");
        return;
    }

    var line: [512]u8 = undefined;
    var len: u32 = 0;
    var event: u32 = 0;
    while (event < cachegrind.events_count) : (event += 1) {
        if (event > 0) {
            line[len] = ' ';
            len += 1;
        }
        const name = cachegrind.event_names[event][0..cachegrind.event_name_lens[event]];
        const written = std.fmt.bufPrint(line[len..], "{s}={d}", .{
            name, cachegrind.totals[event],
        }) catch break;
        len += @intCast(written.len);
    }
    zgui.textUnformatted(line[0..len]);
}

/// Cached function order (by first event, descending), rebuilt only when
/// the registry grows or the parse finishes: insertion-sorting per frame
/// would cost millions of comparisons at 2048 functions.
var sorted_cache: [cachegrind.functions_max]u32 = undefined;
var sorted_cached_at: u32 = std.math.maxInt(u32);
var sorted_cached_done: bool = false;

fn render_functions() void {
    if (cachegrind.functions_count == 0) return;

    const column_count: i32 = @intCast(2 + cachegrind.events_count);
    if (!zgui.beginTable("cachegrind_functions", .{ .column = column_count })) return;
    defer zgui.endTable();

    zgui.tableSetupColumn("function", .{});
    zgui.tableSetupColumn("file", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 300.0 });
    var event: u32 = 0;
    while (event < cachegrind.events_count) : (event += 1) {
        var header: [16]u8 = undefined;
        const name = cachegrind.event_names[event][0..cachegrind.event_name_lens[event]];
        const label = window.label(&header, "{s}##ev{d}", .{ name, event }) orelse continue;
        zgui.tableSetupColumn(label, .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 90.0 });
    }
    zgui.tableHeadersRow();

    const sorted = sorted_functions();
    var index: u32 = 0;
    while (index < sorted) : (index += 1) {
        zgui.tableNextRow(.{});
        const function_index = sorted_cache[index];
        const function = &cachegrind.functions[function_index];

        _ = zgui.tableNextColumn();
        var row_id: [128]u8 = undefined;
        const row_label = window.label(&row_id, "{s}##fn{d}", .{
            function.name[0..function.name_len], function_index,
        }) orelse continue;
        if (zgui.selectable(row_label, .{ .selected = function_index == selected })) {
            selected = function_index;
            detail_selected = std.math.maxInt(u32);
        }

        _ = zgui.tableNextColumn();
        if (function.file_index < cachegrind.files_count) {
            const file = &cachegrind.files[function.file_index];
            zgui.textUnformattedColored(window.muted_color, file.bytes[0..file.len]);
        }

        var count_event: u32 = 0;
        while (count_event < cachegrind.events_count) : (count_event += 1) {
            _ = zgui.tableNextColumn();
            zgui.textDisabled("{d}", .{function.totals[count_event]});
        }
    }
}

/// Functions sorted by the first event (Ir): a bounded in-place index sort
/// over the registry, so the registry order stays untouched. Rebuilt only
/// when the registry grew since the last sort, or when totals stopped
/// moving because the parse finished.
fn sorted_functions() u32 {
    if (sorted_cached_done == cachegrind.parse_done and
        sorted_cached_at == cachegrind.functions_count)
    {
        return cachegrind.functions_count;
    }
    sorted_cached_done = cachegrind.parse_done;
    sorted_cached_at = cachegrind.functions_count;

    var count: u32 = 0;
    var function: u32 = 0;
    while (function < cachegrind.functions_count) : (function += 1) {
        const total = cachegrind.functions[function].totals[0];
        var index: u32 = count;
        sorted_cache[count] = function;
        count += 1;
        while (index > 0 and cachegrind.functions[sorted_cache[index - 1]].totals[0] < total) {
            std.mem.swap(u32, &sorted_cache[index], &sorted_cache[index - 1]);
            index -= 1;
        }
    }
    return count;
}

fn render_detail() void {
    if (selected >= cachegrind.functions_count) {
        zgui.textUnformattedColored(window.muted_color, "select a function for its per-line costs");
        return;
    }

    refresh_detail_rows();
    zgui.textDisabled("per-line costs ({d} rows)", .{detail_count});
    if (detail_count == 0) return;

    if (!zgui.beginChild("cachegrind_detail", .{
        .w = 0.0,
        .h = 0.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    })) {
        zgui.endChild();
        return;
    }

    var index: u32 = 0;
    while (index < detail_count) : (index += 1) {
        render_detail_row(cachegrind.details[detail_rows[index]]);
    }
    zgui.endChild();
}

/// Rebuild the selected function's row list only when the selection moved.
fn refresh_detail_rows() void {
    if (detail_selected == selected) return;
    detail_selected = selected;
    detail_count = 0;

    var slot: u32 = 0;
    while (slot < cachegrind.details.len) : (slot += 1) {
        const detail = &cachegrind.details[slot];
        if (!detail.used) continue;
        if (detail.function_index != selected) continue;

        // Insertion sort by line, bounded by the detail table size.
        var index: u32 = detail_count;
        detail_rows[detail_count] = slot;
        detail_count += 1;
        assert(detail_count <= detail_rows.len);
        while (index > 0 and cachegrind.details[detail_rows[index - 1]].line > detail.line) {
            std.mem.swap(u32, &detail_rows[index], &detail_rows[index - 1]);
            index -= 1;
        }
    }
}

fn render_detail_row(detail: cachegrind.Detail) void {
    var line: [512]u8 = undefined;
    var len: u32 = 0;

    const line_number = std.fmt.bufPrint(line[0..], "line {d: >5}", .{detail.line}) catch return;
    len = @intCast(line_number.len);

    var event: u32 = 0;
    while (event < cachegrind.events_count) : (event += 1) {
        const written = std.fmt.bufPrint(line[len..], "  {d: >12}", .{
            detail.counts[event],
        }) catch break;
        len += @intCast(written.len);
    }
    zgui.textUnformatted(line[0..len]);
}
