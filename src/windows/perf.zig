// The perf window: progress of the perf.data parse, then the hottest
// sample addresses with their modules and symbols.
//
// Everything it shows comes from perf.zig's bounded static state.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const perf = @import("../perf.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("perf", .{ .popen = &open, .flags = .{ .no_move = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("perf");

    if (!perf.parse_done) {
        zgui.textUnformattedColored(window.muted_color, "parsing perf.data...");
        zgui.textDisabled("{d}% ({d} records, {d} samples)", .{
            perf.percent_done(), perf.records_seen, perf.samples_user,
        });
        zgui.end();
        return;
    }

    render_summary();
    zgui.separator();
    render_top();

    zgui.end();
}

fn render_summary() void {
    if (perf.parse_failed) {
        zgui.textUnformattedColored(window.error_color, "perf.data could not be parsed");
        return;
    }

    const total = perf.samples_user + perf.samples_kernel;
    zgui.textDisabled(
        "{d} samples ({d} user, {d} kernel, {d} skipped), {d} mappings",
        .{
            total,               perf.samples_user,
            perf.samples_kernel, perf.samples_unsupported,
            perf.mappings_count,
        },
    );

    if (!perf.symbol_done) {
        zgui.sameLine(.{});
        zgui.textUnformattedColored(window.muted_color, "  symbolizing...");
    }
}

fn render_top() void {
    if (perf.top_count == 0) {
        zgui.textUnformattedColored(window.muted_color, "no hotspots recorded");
        return;
    }

    if (!zgui.beginTable("perf_top", .{ .column = 4 })) return;
    defer zgui.endTable();

    zgui.tableSetupColumn("rank", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 48.0 });
    zgui.tableSetupColumn("samples", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 90.0 });
    zgui.tableSetupColumn("function", .{});
    zgui.tableSetupColumn("module", .{ .flags = .{ .width_fixed = true }, .init_width_or_height = 320.0 });
    zgui.tableHeadersRow();

    var index: u32 = 0;
    while (index < perf.top_count) : (index += 1) {
        zgui.tableNextRow(.{});
        render_row(index);
    }
}

fn render_row(index: u32) void {
    const entry = &perf.top[index];
    const total = perf.samples_user;
    assert(entry.count > 0);

    _ = zgui.tableNextColumn();
    zgui.textDisabled("{d}", .{index + 1});

    _ = zgui.tableNextColumn();
    const percent = if (total > 0) entry.count * 1000 / total else 0;
    zgui.text("{d} ({d}.{d}%)", .{ entry.count, percent / 10, percent % 10 });

    _ = zgui.tableNextColumn();
    if (entry.symbol_len > 0) {
        zgui.textUnformatted(entry.symbol[0..entry.symbol_len]);
    } else {
        zgui.textUnformattedColored(window.muted_color, "(no symbols)");
    }

    _ = zgui.tableNextColumn();
    if (!entry.has_mapping) {
        zgui.textUnformattedColored(window.muted_color, "unknown");
        return;
    }
    const mapping = &perf.mappings[entry.mapping_index];
    zgui.textDisabled("{s}+0x{x}", .{
        mapping.path[0..mapping.path_len], entry.addr - mapping.addr,
    });
}
