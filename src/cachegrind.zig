// Incremental parser and aggregates for valgrind's cachegrind output.
//
// The file is a simple line-oriented text profile:
//
//     events: Ir I1mr I2mr Dr D1mr D2mr Dw D1mw D2mw
//     fl=(12) /path/to/file.c
//     fn=(8) main
//     16 27 0 0 9 0 0 5 0 0
//
// Cost lines carry the current file/function context. diaguiinspect parses it at its
// own pace: every frame consumes a bounded byte budget, so a large profile
// never stalls the GUI. All state is static and bounded; overflowing a
// bound truncates with a console warning instead of allocating.

const std = @import("std");
const console = @import("console.zig");

const Io = std.Io;
const assert = std.debug.assert;

// valgrind's full event set with cache and branch simulation reaches 13
// kinds (Ir I1mr ILmr Dr D1mr DLmr Dw D1mw DLmw Bc Bcm Bi Bim); 16 leaves
// room for the format to grow without silently dropping counters.
pub const events_max: u32 = 16;
pub const event_name_bytes: u32 = 12;
pub const functions_max: u32 = 2048;
pub const files_max: u32 = 512;
pub const lines_max: u32 = 8192;
pub const name_bytes: u32 = 96;
pub const file_bytes: u32 = 192;

/// Byte budget per frame: generous enough to finish a normal profile within
/// a second of frames, small enough to keep frames responsive.
pub const budget_bytes_per_tick: u32 = 256 * 1024;

pub const Function = struct {
    name: [name_bytes]u8 = @splat(0),
    name_len: u16 = 0,
    file_index: u16 = 0,
    totals: [events_max]u64 = @splat(0),
};

pub const FilePath = struct {
    bytes: [file_bytes]u8 = @splat(0),
    len: u16 = 0,
};

pub const Detail = struct {
    function_index: u16 = 0,
    line: u32 = 0,
    counts: [events_max]u64 = @splat(0),
    used: bool = false,
};

pub var events_count: u32 = 0;
pub var event_names: [events_max][event_name_bytes]u8 = @splat(@splat(0));
pub var event_name_lens: [events_max]u8 = @splat(0);

pub var files: [files_max]FilePath = @splat(.{});
pub var files_count: u32 = 0;
pub var functions: [functions_max]Function = @splat(.{});
pub var functions_count: u32 = 0;
/// Detail rows, open-addressed by (function_index, line) so merging a cost
/// line is a bounded probe, not a scan.
pub var details: [lines_max]Detail = @splat(.{});
pub var details_count: u32 = 0;

/// Our own accumulation over all cost lines, independent of the file's
/// summary line (which parsed files may or may not carry).
pub var totals: [events_max]u64 = @splat(0);
/// The profile's own "summary:" line, if present, kept for comparison.
pub var summary_totals: [events_max]u64 = @splat(0);

pub var parse_done: bool = false;
pub var parse_failed: bool = false;
pub var parse_bytes_done: u64 = 0;
pub var parse_bytes_total: u64 = 0;

var parse_file: ?Io.File = null;
var current_file_index: u16 = 0;
var current_function_index: u16 = 0;
var chunk: [64 * 1024]u8 = undefined;
var chunk_fill: u32 = 0;
var chunk_consumed: u32 = 0;

/// Open `path` and reset all aggregates. Fails loudly on the console: a
/// bad path is an operating error, not a crash.
pub fn start(io: Io, path: []const u8) void {
    reset();

    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        console.log(.err, "cachegrind: opening {s} failed: {s}", .{
            path, @errorName(err),
        });
        parse_failed = true;
        parse_done = true;
        return;
    };
    parse_file = file;

    const stat = file.stat(io) catch |err| {
        console.log(.err, "cachegrind: stat failed: {s}", .{@errorName(err)});
        parse_failed = true;
        parse_done = true;
        return;
    };
    parse_bytes_total = stat.size;
    console.log(.info, "cachegrind: parsing {s} ({d} bytes)", .{
        path, stat.size,
    });
}

fn reset() void {
    events_count = 0;
    files_count = 0;
    functions_count = 0;
    details_count = 0;
    totals = @splat(0);
    parse_done = false;
    parse_failed = false;
    parse_bytes_done = 0;
    parse_bytes_total = 0;
    chunk_fill = 0;
    chunk_consumed = 0;
    refill_exhausted = false;
    summary_totals = @splat(0);
    current_file_index = 0;
    current_function_index = 0;
}

/// Consume one frame's byte budget. Safe to call every frame; after the
/// file ends it does nothing.
pub fn tick_budget(io: Io) void {
    if (parse_done) return;
    const file = parse_file orelse {
        parse_done = true;
        return;
    };

    var consumed_total: u64 = 0;
    while (consumed_total < budget_bytes_per_tick and !parse_done) {
        _ = refill(io, file);
        const consumed = parse_complete_lines();
        consumed_total += consumed;
        if (consumed > 0) continue;

        if (chunk_fill == chunk.len and chunk_consumed == 0) {
            // One line larger than the whole chunk would wedge the parse
            // forever; drop it wholesale.
            drop_overlong_line();
            continue;
        }

        if (refill_exhausted) {
            // A trailing unterminated line still counts as a line.
            if (chunk_consumed < chunk_fill) {
                parse_line(chunk[chunk_consumed..chunk_fill]);
            }
            finish();
            return;
        }

        // No complete line yet but the file has more: the next round's
        // refill reads further into the file, so this cannot spin.
    }
}

fn drop_overlong_line() void {
    console.log(.warn, "cachegrind: dropped a line over {d} bytes", .{chunk.len});
    // The refill position already points past the dropped bytes.
    chunk_fill = 0;
    chunk_consumed = 0;
}

var refill_exhausted: bool = false;

fn refill(io: Io, file: Io.File) bool {
    if (chunk_consumed == chunk_fill) {
        chunk_fill = 0;
        chunk_consumed = 0;
    } else if (chunk_consumed > 0) {
        // Move the unparsed tail to the front so a line split across reads
        // still parses once complete.
        const remaining = chunk_fill - chunk_consumed;
        std.mem.copyForwards(u8, chunk[0..remaining], chunk[chunk_consumed..chunk_fill]);
        chunk_fill = remaining;
        chunk_consumed = 0;
    }

    if (refill_exhausted) return false;
    const want: u32 = @as(u32, @intCast(chunk.len)) - chunk_fill;
    if (want == 0) return false;

    const bytes_read = file.readPositional(
        io,
        &.{chunk[chunk_fill..]},
        parse_bytes_done,
    ) catch |err| {
        console.log(.err, "cachegrind: reading failed: {s}", .{@errorName(err)});
        parse_failed = true;
        finish();
        return false;
    };
    chunk_fill += @intCast(bytes_read);
    parse_bytes_done += bytes_read;
    if (bytes_read < want) refill_exhausted = true;
    if (bytes_read == 0) refill_exhausted = true;

    return chunk_fill > chunk_consumed;
}

fn finish() void {
    parse_done = true;
    // The file handle is closed by `close_all`, which has the io.
    if (!parse_failed and functions_count == 0) {
        console.log(.warn, "cachegrind: no functions found in the profile", .{});
    }
    if (!parse_failed) {
        console.log(.info, "cachegrind: {d} functions, {d} cost lines", .{
            functions_count, details_count,
        });
    }
}

/// Close the profile file, called once the parse is over or at shutdown.
pub fn close_all(io: Io) void {
    if (parse_file) |file| {
        file.close(io);
        parse_file = null;
    }
}

/// Parse every complete line currently in the chunk. Returns bytes consumed.
fn parse_complete_lines() u64 {
    var line_start: u32 = chunk_consumed;
    var index: u32 = chunk_consumed;

    while (index < chunk_fill) {
        if (chunk[index] != '\n') {
            index += 1;
            continue;
        }
        parse_line(chunk[line_start..index]);
        index += 1;
        line_start = index;
    }

    const consumed = line_start - chunk_consumed;
    chunk_consumed = line_start;
    return consumed;
}

/// Parse one content line (without its newline).
fn parse_line(line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    if (std.mem.startsWith(u8, trimmed, "events:")) {
        parse_event_names(trimmed["events:".len..]);
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "fl=")) {
        current_file_index = register_file(trimmed["fl=".len..]);
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "fn=")) {
        current_function_index = register_function(trimmed["fn=".len..]);
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "summary:")) {
        parse_summary(trimmed["summary:".len..]);
        return;
    }
    if (std.mem.startsWith(u8, trimmed, "cfn=") or
        std.mem.startsWith(u8, trimmed, "calls=") or
        std.mem.startsWith(u8, trimmed, "jumps=") or
        std.mem.startsWith(u8, trimmed, "desc:") or
        std.mem.startsWith(u8, trimmed, "cmd:") or
        std.mem.startsWith(u8, trimmed, "time_unit:") or
        std.mem.startsWith(u8, trimmed, "totals:"))
    {
        // Context or metadata diaguiinspect does not aggregate; skip whole.
        return;
    }

    // Anything else that parses as a line number plus counts is a cost
    // line; anything else is not understood and counted, not fatal.
    parse_cost_line(trimmed);
}

fn parse_event_names(rest: []const u8) void {
    var iterator = std.mem.tokenizeScalar(u8, rest, ' ');
    while (iterator.next()) |name| {
        if (events_count == events_max) {
            console.log(.warn, "cachegrind: showing first {d} event kinds", .{events_max});
            return;
        }
        const copy_len = @min(name.len, event_name_bytes);
        @memcpy(event_names[events_count][0..copy_len], name[0..copy_len]);
        event_name_lens[events_count] = @intCast(copy_len);
        events_count += 1;
    }
}

fn register_file(rest: []const u8) u16 {
    const name = strip_definition_id(rest);

    // Files repeat through the profile; reuse the registry entry.
    var index: u32 = 0;
    while (index < files_count) : (index += 1) {
        const file = &files[index];
        const registered = file.bytes[0..file.len];
        if (std.mem.eql(u8, registered, name)) return @intCast(index);
    }

    if (files_count == files_max) {
        console.log(.warn, "cachegrind: showing first {d} files", .{files_max});
        return current_file_index;
    }

    const file = &files[files_count];
    const copy_len = @min(name.len, file_bytes);
    @memcpy(file.bytes[0..copy_len], name[0..copy_len]);
    file.len = @intCast(copy_len);
    files_count += 1;
    return @intCast(files_count - 1);
}

fn register_function(rest: []const u8) u16 {
    const name = strip_definition_id(rest);

    var index: u32 = 0;
    while (index < functions_count) : (index += 1) {
        const function = &functions[index];
        const registered = function.name[0..function.name_len];
        if (std.mem.eql(u8, registered, name)) return @intCast(index);
    }

    if (functions_count == functions_max) {
        console.log(.warn, "cachegrind: showing first {d} functions", .{functions_max});
        return current_function_index;
    }

    const function = &functions[functions_count];
    const copy_len = @min(name.len, name_bytes);
    @memcpy(function.name[0..copy_len], name[0..copy_len]);
    function.name_len = @intCast(copy_len);
    function.file_index = current_file_index;
    functions_count += 1;
    return @intCast(functions_count - 1);
}

/// "fl=(12) /path" and "fl=/path" both name the file; the "(id) " prefix
/// (or a bare "(id)") is cachegrind's definition syntax, not part of it.
fn strip_definition_id(rest: []const u8) []const u8 {
    if (rest.len == 0 or rest[0] != '(') return rest;

    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return rest;
    const after = rest[close + 1 ..];
    if (after.len > 0 and after[0] == ' ') return after[1..];
    return after;
}

/// One cost line: a line number (or `*`) followed by one count per event.
fn parse_cost_line(trimmed: []const u8) void {
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return;
    const line_number_text = trimmed[0..space];
    const counts_text = trimmed[space + 1 ..];

    var line_number: u32 = 0;
    if (!std.mem.eql(u8, line_number_text, "*")) {
        line_number = std.fmt.parseInt(u32, line_number_text, 10) catch return;
    }
    if (events_count == 0) return;

    parse_counts(counts_text, current_function_index, line_number);
}

/// Parse "<c> [<c>...]" into per-event totals, optionally merged into a
/// detail row and function totals.
/// The file's own summary line: parse into `summary_totals` only, so it
/// never double-counts into our own accumulation.
fn parse_summary(rest: []const u8) void {
    var event_index: u32 = 0;
    var iterator = std.mem.tokenizeScalar(u8, rest, ' ');
    while (iterator.next()) |count_text| {
        if (event_index == events_max) break;
        summary_totals[event_index] = std.fmt.parseInt(u64, count_text, 10) catch {
            return;
        };
        event_index += 1;
    }
}

fn parse_counts(rest: []const u8, function_index_opt: ?u16, line_number: u32) void {
    var parsed: [events_max]u64 = @splat(0);
    var parsed_count: u32 = 0;

    var iterator = std.mem.tokenizeScalar(u8, rest, ' ');
    while (iterator.next()) |count_text| {
        if (parsed_count == events_max) break;
        parsed[parsed_count] = std.fmt.parseInt(u64, count_text, 10) catch {
            // A malformed count poisons only this line.
            return;
        };
        parsed_count += 1;
    }
    if (parsed_count == 0) return;

    var event_index: u32 = 0;
    while (event_index < parsed_count) : (event_index += 1) {
        totals[event_index] += parsed[event_index];
    }

    const function_index = function_index_opt orelse return;
    if (function_index >= functions_count) return;

    const function = &functions[function_index];
    event_index = 0;
    while (event_index < parsed_count) : (event_index += 1) {
        function.totals[event_index] += parsed[event_index];
    }
    merge_detail(function_index, line_number, parsed[0..parsed_count]);
}

fn merge_detail(function_index: u16, line_number: u32, counts: []const u64) void {
    const slot = find_detail_slot(function_index, line_number) orelse {
        console.log(.warn, "cachegrind: showing first {d} cost lines", .{lines_max});
        return;
    };
    if (!slot.used) {
        slot.* = .{
            .function_index = function_index,
            .line = line_number,
            .used = true,
        };
        details_count += 1;
    }
    assert(details_count <= lines_max);

    var event_index: u32 = 0;
    while (event_index < counts.len) : (event_index += 1) {
        slot.counts[event_index] += counts[event_index];
    }
}

fn find_detail_slot(function_index: u16, line_number: u32) ?*Detail {
    var probe = hash_details(function_index, line_number) % lines_max;
    var attempts: u32 = 0;
    while (attempts < lines_max) : (attempts += 1) {
        const slot = &details[probe];
        if (!slot.used) return slot;
        if (slot.function_index == function_index and slot.line == line_number) {
            return slot;
        }
        probe = (probe + 1) % lines_max;
    }
    return null;
}

fn hash_details(function_index: u16, line_number: u32) u32 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&function_index));
    hasher.update(std.mem.asBytes(&line_number));
    return @truncate(hasher.final());
}

/// Percent parsed, for the window's progress display.
pub fn percent_done() u32 {
    if (parse_bytes_total == 0) return 100;
    if (parse_bytes_done == 0) return 0;
    const percent = parse_bytes_done * 100 / parse_bytes_total;
    return @intCast(@min(percent, 100));
}

test "cachegrind: parse a synthetic profile" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);

    const path = "/tmp/opencode/diaguiinspect-cachegrind-test.out";
    var expected_ir: u64 = 0;
    {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(
            io,
            "desc: I1 cache: \n" ++
                "events: Ir Dr\n" ++
                "fl=(1) /tmp/project/a.c\n" ++
                "fn=(1) main\n",
        );

        // Enough cost lines to span several chunk refills, which is what
        // real valgrind output looks like in size.
        var line_number: u32 = 0;
        while (line_number < 3000) : (line_number += 1) {
            var row: [64]u8 = undefined;
            const row_text = try std.fmt.bufPrint(&row, "{d} {d} 1\n", .{
                line_number + 1, line_number + 7,
            });
            try file.writeStreamingAll(io, row_text);
            expected_ir += line_number + 7;
        }

        // One line over the 64 KiB chunk: the parser must drop it and
        // continue, not wedge.
        var overlong: [70 * 1024]u8 = @splat('x');
        try file.writeStreamingAll(io, "99999 ");
        try file.writeStreamingAll(io, overlong[0..]);
        try file.writeStreamingAll(io, "\n");

        // The per-function body ends; a second function in another file.
        try file.writeStreamingAll(
            io,
            "fl=(2) /tmp/project/b.c\n" ++
                "fn=(2) helper\n" ++
                "3 3 1\n" ++
                "summary: 18 3\n",
        );
        // expected_ir stays main's own total; helper adds 3 to the globals.
    }

    start(io, path);
    var ticks: u32 = 0;
    while (!parse_done and ticks < 200) : (ticks += 1) {
        tick_budget(io);
    }
    close_all(io);

    try std.testing.expect(parse_done);
    try std.testing.expect(!parse_failed);
    try std.testing.expectEqual(@as(u32, 2), events_count);
    try std.testing.expectEqual(@as(u32, 2), files_count);
    try std.testing.expectEqual(@as(u32, 2), functions_count);
    try std.testing.expectEqual(@as(u32, 3001), details_count);

    // main: Ir 15, Dr 2; helper: Ir 3, Dr 1; totals over all cost lines.
    try std.testing.expectEqual(expected_ir, functions[0].totals[0]);
    try std.testing.expectEqual(expected_ir + 3, totals[0]);
    try std.testing.expectEqual(@as(u64, 3001), totals[1]);

    // The function table is registry-ordered; the window sorts by Ir.
    try std.testing.expectEqualStrings("main", functions[0].name[0..functions[0].name_len]);
    try std.testing.expectEqualStrings(
        "/tmp/project/b.c",
        files[functions[1].file_index].bytes[0..files[functions[1].file_index].len],
    );
}
