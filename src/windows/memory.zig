// The memory window: one bounded hexdump around a requested address.

const std = @import("std");
const zgui = @import("zgui");
const app = @import("../app.zig");
const console = @import("../console.zig");
const window = @import("../window.zig");

const assert = std.debug.assert;

pub var open: bool = true;

/// Bytes shown per hexdump row.
const row_bytes: u32 = 16;

pub fn render() void {
    if (!open) return;
    if (!zgui.begin("Memory", .{ .popen = &open, .flags = .{ .no_move = true, .horizontal_scrollbar = true } })) {
        zgui.end();
        return;
    }
    window.log_appearance("memory");

    render_address_row();
    render_dump();

    zgui.end();
}

fn render_address_row() void {
    // No character filter: a pasted "0x5555…" must survive, and the parser
    // below accepts both bare hex and the 0x-prefixed form that the copy
    // actions elsewhere in the UI produce.
    zgui.setNextItemWidth(-220.0);
    _ = zgui.inputText("##memory_address", .{
        .buf = &app.app.memory_input,
        .flags = .{ .enter_returns_true = true },
    });
    if (zgui.isItemHovered(.{})) {
        zgui.setTooltip("hex address, with or without 0x — paste-friendly", .{});
    }

    zgui.sameLine(.{});
    if (zgui.button("Read", .{})) read_input_address();

    zgui.sameLine(.{});
    if (zgui.button("From $pc", .{})) {
        var line: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{x}", .{app.app.disassembly_pc}) catch return;
        copy_to_input(text);
        app.read_memory(app.app.disassembly_pc);
    }

    zgui.sameLine(.{});
    if (zgui.button("Copy dump", .{})) copy_dump();
}

fn read_input_address() void {
    const text = std.mem.sliceTo(&app.app.memory_input, 0);
    const hex = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        text[2..]
    else
        text;
    const address = std.fmt.parseInt(u64, hex, 16) catch {
        console.log(.warn, "memory: not a hex address: {s}", .{text});
        return;
    };
    app.read_memory(address);
}

fn copy_to_input(text: []const u8) void {
    assert(text.len < app.app.memory_input.len);
    @memset(app.app.memory_input[0..], 0);
    @memcpy(app.app.memory_input[0..text.len], text);
}

fn render_dump() void {
    if (!app.app.memory_valid) {
        zgui.textUnformattedColored(window.muted_color, "no memory read yet");
        return;
    }

    var offset: u32 = 0;
    while (offset < app.memory_bytes_max) : (offset += row_bytes) {
        render_row(offset);
    }
}

/// The visible dump as text, newest read only, for pasting anywhere.
fn copy_dump() void {
    var len: u32 = 0;
    var offset: u32 = 0;
    while (offset < app.memory_bytes_max) : (offset += row_bytes) {
        var line: [200]u8 = undefined;
        const text = compose_row(&line, offset) orelse break;
        const copy_len = @min(text.len, window.clipboard_scratch.len - len);
        if (copy_len == 0) break;
        @memcpy(window.clipboard_scratch[len..][0..copy_len], text[0..copy_len]);
        window.clipboard_scratch[len + copy_len] = '\n';
        len += @as(u32, @intCast(copy_len)) + 1;
        if (len >= window.clipboard_scratch.len) break;
    }
    if (len > 0) {
        len -= 1; // Drop the trailing newline.
        window.clipboard_scratch[len] = 0;
        zgui.setClipboardText(window.clipboard_scratch[0..len :0]);
    }
}

fn render_row(offset: u32) void {
    var line: [200]u8 = undefined;
    const composed = compose_row(&line, offset) orelse return;

    // A row is plain text otherwise: wrap it in a selectable so right-click
    // can copy it, and give every row a unique hidden id.
    var label_buf: [216]u8 = undefined;
    const row_label = window.label(&label_buf, "{s}##mem{d}", .{
        composed, offset,
    }) orelse return;
    _ = zgui.selectable(row_label, .{});

    var address_text: [24]u8 = undefined;
    const address = window.format_address(&address_text, app.app.memory_addr + offset);
    window.copy_item_pair(
        "Copy row",
        composed,
        "Copy address",
        address,
    );
}

/// One hexdump row: address, hex column, ascii column. Shared by the
/// renderer and the clipboard copier so both agree byte for byte.
fn compose_row(out: []u8, offset: u32) ?[]const u8 {
    var buffer_index: u32 = 0;
    var hex_index: u32 = 0;
    var ascii_index: u32 = 0;

    // Address column: bufPrint returns a slice; its length is a byte count
    // far below u32 for any buffer we use here.
    const address_text = std.fmt.bufPrint(out[buffer_index..], "0x{x:0>8}  ", .{
        app.app.memory_addr + offset,
    }) catch return null;
    buffer_index += @intCast(address_text.len);

    // Hex column, two digits per byte.
    while (hex_index < row_bytes) : (hex_index += 1) {
        const byte = app.app.memory_bytes[offset + hex_index];
        const written = std.fmt.bufPrint(out[buffer_index..], "{x:0>2} ", .{byte}) catch return null;
        buffer_index += @intCast(written.len);
    }
    out[buffer_index] = ' ';
    buffer_index += 1;

    // ASCII column: printable bytes shown, the rest as dots.
    while (ascii_index < row_bytes) : (ascii_index += 1) {
        const byte = app.app.memory_bytes[offset + ascii_index];
        const printable = byte >= 0x20 and byte < 0x7f;
        out[buffer_index] = if (printable) byte else '.';
        buffer_index += 1;
    }
    return out[0..buffer_index];
}
