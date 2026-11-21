// Incremental parser for Linux perf.data (file format v2) with bounded
// hotspot aggregation and ELF symbolization.
//
// diaguiinspect parses the file at its own pace: every frame consumes a bounded byte
// budget from the data section, so recording-sized files never stall the
// GUI. Sample records are aggregated into a fixed hash table keyed by the
// sample's leaf IP; on completion the hottest addresses are resolved
// against their mapping's ELF symbol table (see elf.zig), one module per
// frame. Everything is static; every bound warns instead of allocating.
//
// Supported sample layout: IP, TID, TIME, ADDR, CALLCHAIN, ID, CPU,
// PERIOD, STREAM_ID (the layouts `perf record` and `perf record -g`
// produce). Anything else is reported and the samples are skipped, while
// mappings still parse.

const std = @import("std");
const console = @import("console.zig");
const elf = @import("elf.zig");

const Io = std.Io;
const assert = std.debug.assert;

pub const mappings_max: u32 = 128;
pub const hot_slots: u32 = 4096;
pub const top_max: u32 = 64;
pub const path_bytes: u32 = 192;
pub const symbol_bytes: u32 = 96;

/// Byte budget per frame for the data section.
pub const budget_bytes_per_tick: u32 = 1024 * 1024;

/// PERF_RECORD_* constants (linux/perf_event.h, stable ABI).
const record_mmap: u32 = 1;
const record_sample: u32 = 9;
const record_mmap2: u32 = 10;

/// PERF_SAMPLE_* bits, in the order the sample payload lays them out.
const sample_ip: u64 = 1 << 0;
const sample_tid: u64 = 1 << 1;
const sample_time: u64 = 1 << 2;
const sample_addr: u64 = 1 << 3;
const sample_callchain: u64 = 1 << 5;
const sample_id: u64 = 1 << 6;
const sample_cpu: u64 = 1 << 7;
const sample_period: u64 = 1 << 8;
const sample_stream_id: u64 = 1 << 9;
const supported_sample_mask: u64 =
    sample_ip | sample_tid | sample_time | sample_addr |
    sample_callchain | sample_id | sample_cpu | sample_period | sample_stream_id;

/// Callchain entries at or above this marker are perf's context tags
/// (PERF_CONTEXT_USER and friends), not addresses.
const context_marker: u64 = 0xffff_fff8;

pub const Mapping = struct {
    addr: u64 = 0,
    len: u64 = 0,
    pgoff: u64 = 0,
    path: [path_bytes]u8 = @splat(0),
    path_len: u16 = 0,
    used: bool = false,
};

pub const Hotspot = struct {
    addr: u64 = 0,
    count: u32 = 0,
    used: bool = false,
};

pub const Top = struct {
    addr: u64 = 0,
    count: u32 = 0,
    has_mapping: bool = false,
    mapping_index: u16 = 0,
    /// Symbol text: the function name when ELF symbols resolved it, and
    /// the caller renders the module path and offset regardless.
    symbol: [symbol_bytes]u8 = @splat(0),
    symbol_len: u16 = 0,
    symbolized: bool = false,
};

pub var mappings: [mappings_max]Mapping = @splat(.{});
pub var mappings_count: u32 = 0;
pub var hotspots: [hot_slots]Hotspot = @splat(.{});

pub var top: [top_max]Top = @splat(.{});
pub var top_count: u32 = 0;

pub var samples_user: u64 = 0;
pub var samples_kernel: u64 = 0;
pub var samples_unsupported: u64 = 0;
pub var records_seen: u64 = 0;

pub var parse_done: bool = false;
pub var parse_failed: bool = false;
pub var parse_bytes_done: u64 = 0;
pub var parse_bytes_total: u64 = 0;

/// Symbolization runs after the parse, one module per frame.
pub var symbol_done: bool = false;

var parse_file: ?Io.File = null;
var parse_io: Io = undefined;
var data_end: u64 = 0;
var sample_type: u64 = 0;
var samples_supported: bool = true;
var symbol_module_cursor: u32 = 0;
var symbol_modules: [top_max]u16 = @splat(0);
var symbol_modules_count: u32 = 0;

/// The ELF table for whichever module symbolization is resolving now.
var elf_symbols: [elf.symbols_max]elf.Symbol = undefined;
var elf_table: elf.Table = .{ .symbols = elf_symbols[0..] };

var chunk: [64 * 1024]u8 = undefined;
var chunk_fill: u32 = 0;
var chunk_consumed: u32 = 0;
var chunk_position: u64 = 0;

/// Open `path` (a directory means `<dir>/perf.data`) and start parsing.
pub fn start(io: Io, path: []const u8) void {
    reset();
    parse_io = io;

    var file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        console.log(.err, "perf: opening {s} failed: {s}", .{ path, @errorName(err) });
        return fail();
    };
    const stat = file.stat(io) catch |err| {
        console.log(.err, "perf: stat {s} failed: {s}", .{ path, @errorName(err) });
        file.close(io);
        return fail();
    };
    if (stat.kind == .directory) {
        file.close(io);
        var joined: [path_bytes]u8 = undefined;
        const joined_path = std.fmt.bufPrint(&joined, "{s}/perf.data", .{path}) catch {
            console.log(.err, "perf: path too long: {s}", .{path});
            return fail();
        };
        file = Io.Dir.cwd().openFile(io, joined_path, .{}) catch |err| {
            console.log(.err, "perf: opening {s} failed: {s}", .{
                joined_path, @errorName(err),
            });
            return fail();
        };
        console.log(.info, "perf: reading {s}", .{joined_path});
    } else {
        console.log(.info, "perf: reading {s}", .{path});
    }

    parse_file = file;
    if (!read_header(io, file)) return;

    chunk_position = data_offset;
    parse_bytes_done = data_offset;
    if (data_offset >= data_end) {
        parse_done = true;
        console.log(.warn, "perf: data section is empty", .{});
    }
}

var data_offset: u64 = 0;

fn fail() void {
    parse_failed = true;
    parse_done = true;
    symbol_done = true;
}

fn reset() void {
    mappings_count = 0;
    top_count = 0;
    samples_user = 0;
    samples_kernel = 0;
    samples_unsupported = 0;
    records_seen = 0;
    parse_done = false;
    parse_failed = false;
    parse_bytes_done = 0;
    parse_bytes_total = 0;
    symbol_done = false;
    samples_supported = true;
    symbol_module_cursor = 0;
    symbol_modules_count = 0;
    hotspot_full_warned = false;
    chunk_fill = 0;
    chunk_consumed = 0;
    for (&hotspots) |*hotspot| hotspot.* = .{};
}

/// The fixed file header: magic, then offsets and sizes of the attr and
/// data sections.
fn read_header(io: Io, file: Io.File) bool {
    var header: [104]u8 = undefined;
    const read_ok = file.readPositional(io, &.{header[0..]}, 0) catch {
        return header_fail("perf: unreadable header");
    };
    if (read_ok < header.len) return header_fail("perf: short header");

    if (!std.mem.eql(u8, header[0..8], "PERFILE2")) {
        return header_fail("perf: not a perf.data v2 file");
    }

    data_offset = read_u64(header[0..], 40);
    const data_size = read_u64(header[0..], 48);
    const attrs_offset = read_u64(header[0..], 24);
    data_end = data_offset + data_size;
    parse_bytes_total = data_end;

    // The sample layout comes from the first attribute; all attrs of one
    // recording share it in practice.
    if (attrs_offset == 0) return header_fail("perf: no attributes recorded");
    var attr: [80]u8 = undefined;
    const attr_read = file.readPositional(io, &.{attr[0..]}, attrs_offset) catch {
        return header_fail("perf: unreadable attribute");
    };
    if (attr_read < attr.len) return header_fail("perf: short attribute");

    sample_type = read_u64(attr[0..], 24);
    if (sample_type & ~supported_sample_mask != 0) {
        samples_supported = false;
        console.log(.warn, "perf: unsupported sample layout (0x{x}); " ++
            "counting mappings only", .{sample_type});
    }
    return true;
}

fn header_fail(message: []const u8) bool {
    console.log(.err, "{s}", .{message});
    fail();
    return false;
}

/// One frame of parsing. Bounded by `budget_bytes_per_tick`.
pub fn tick_budget(io: Io) void {
    if (!parse_done) {
        var consumed: u64 = 0;
        while (consumed < budget_bytes_per_tick) {
            if (!ensure(8, io)) {
                finish_parse();
                break;
            }
            const record_size = parse_record(io);
            if (record_size == 0) break;
            consumed += record_size;
        }
        return;
    }
    if (!symbol_done) tick_symbolize(io);
}

fn finish_parse() void {
    parse_done = true;
    select_top();
    console.log(.info, "perf: {d} records, {d} user samples, {d} kernel, " ++
        "{d} hotspots, {d} mappings", .{
        records_seen,   samples_user, samples_kernel, count_hotspots(),
        mappings_count,
    });
    if (samples_unsupported > 0) {
        console.log(.warn, "perf: skipped {d} samples with unsupported layout", .{
            samples_unsupported,
        });
    }
}

fn count_hotspots() u32 {
    var total: u32 = 0;
    for (hotspots) |hotspot| {
        if (hotspot.used) total += 1;
    }
    return total;
}

/// The top list: the `top_max` hottest addresses, count-descending.
fn select_top() void {
    top_count = 0;
    for (&hotspots) |*hotspot| {
        if (!hotspot.used) continue;
        insert_top(hotspot);
    }

    // Resolve each top address's mapping once, while we are at it.
    var index: u32 = 0;
    while (index < top_count) : (index += 1) {
        const entry = &top[index];
        const mapping = find_mapping(entry.addr) orelse continue;
        entry.has_mapping = true;
        entry.mapping_index = mapping.index;
    }
    collect_symbol_modules();
}

fn insert_top(hotspot: *const Hotspot) void {
    if (top_count < top_max) {
        // Append then bubble down into place: bounded, in-place, stable.
        top[top_count] = .{ .addr = hotspot.addr, .count = hotspot.count };
        var index: u32 = top_count;
        top_count += 1;
        while (index > 0 and top[index].count > top[index - 1].count) {
            std.mem.swap(Top, &top[index], &top[index - 1]);
            index -= 1;
        }
        return;
    }

    // Full: replace only if this beats the weakest entry kept.
    if (hotspot.count <= top[top_max - 1].count) return;
    top[top_max - 1] = .{ .addr = hotspot.addr, .count = hotspot.count };
    var index: u32 = top_max - 1;
    while (index > 0 and top[index].count > top[index - 1].count) {
        std.mem.swap(Top, &top[index], &top[index - 1]);
        index -= 1;
    }
}

fn collect_symbol_modules() void {
    symbol_modules_count = 0;
    var index: u32 = 0;
    while (index < top_count) : (index += 1) {
        const entry = &top[index];
        if (!entry.has_mapping) continue;

        var known: u32 = 0;
        while (known < symbol_modules_count) : (known += 1) {
            if (symbol_modules[known] == entry.mapping_index) break;
        }
        if (known < symbol_modules_count) continue;

        symbol_modules[symbol_modules_count] = entry.mapping_index;
        symbol_modules_count += 1;
        assert(symbol_modules_count <= top_max);
    }
}

/// One symbolization step: load the next module's ELF table and resolve
/// every top entry inside it.
fn tick_symbolize(io: Io) void {
    if (symbol_module_cursor >= symbol_modules_count) {
        symbol_done = true;
        console.log(.info, "perf: symbolization finished", .{});
        return;
    }

    const mapping_index = symbol_modules[symbol_module_cursor];
    symbol_module_cursor += 1;
    const mapping = &mappings[mapping_index];
    if (mapping.path_len == 0) return;

    const file = Io.Dir.cwd().openFile(io, mapping.path[0..mapping.path_len], .{}) catch {
        // Module files move around; unsymbolized is a normal outcome.
        return;
    };
    defer file.close(io);

    elf.load_symbols(file, io, &elf_table);
    if (!elf_table.has_symbols) return;

    const load_bias = mapping.addr -| mapping.pgoff;
    var index: u32 = 0;
    while (index < top_count) : (index += 1) {
        const entry = &top[index];
        if (!entry.has_mapping) continue;
        if (entry.mapping_index != mapping_index) continue;

        // PIE and shared objects both resolve as: vaddr = ip - load bias.
        const virtual_address = entry.addr -| load_bias;
        const name = elf_table.lookup(file, io, virtual_address, entry.symbol[0..]) orelse {
            entry.symbol_len = 0;
            entry.symbolized = false;
            continue;
        };
        const copy_len = @min(name.len, symbol_bytes);
        @memcpy(entry.symbol[0..copy_len], name[0..copy_len]);
        entry.symbol_len = @intCast(copy_len);
        entry.symbolized = true;
    }
}

/// Close the data file; called at shutdown or from tests.
pub fn close_all(io: Io) void {
    if (parse_file) |file| {
        file.close(io);
        parse_file = null;
    }
}

/// Percent of the data section parsed, for the window's progress display.
pub fn percent_done() u32 {
    if (parse_bytes_total == 0) return 100;
    if (parse_bytes_done == 0) return 0;
    const percent = parse_bytes_done * 100 / parse_bytes_total;
    return @intCast(@min(percent, 100));
}

// ---------------------------------------------------------------------------
// Bounded cursor over the data section.
// ---------------------------------------------------------------------------

/// Invariant: `chunk_position` is the absolute file offset just past the
/// buffered data, so `chunk[0 .. chunk_fill]` holds the bytes ending at
/// `chunk_position`, of which `chunk[chunk_consumed..]` is unparsed.
fn ensure(need: u32, io: Io) bool {
    if (chunk_fill - chunk_consumed >= need) return true;

    // Compact the unparsed tail to the front; the invariant survives
    // because the tail still ends at chunk_position.
    if (chunk_consumed > 0) {
        const remaining = chunk_fill - chunk_consumed;
        std.mem.copyForwards(u8, chunk[0..remaining], chunk[chunk_consumed..chunk_fill]);
        chunk_fill = remaining;
        chunk_consumed = 0;
    }
    if (chunk_fill == chunk.len) return true;
    if (chunk_position >= data_end) {
        return chunk_fill - chunk_consumed >= need;
    }

    const file = parse_file orelse return false;
    const want = @min(
        chunk.len - chunk_fill,
        @as(u32, @intCast(data_end - chunk_position)),
    );
    const bytes_read = file.readPositional(
        io,
        &.{chunk[chunk_fill..][0..want]},
        chunk_position,
    ) catch |err| {
        console.log(.err, "perf: reading data failed: {s}", .{@errorName(err)});
        fail();
        return false;
    };
    chunk_fill += @intCast(bytes_read);
    chunk_position += bytes_read;
    return chunk_fill - chunk_consumed >= need;
}

/// Parse one record from the chunk. Returns the record's total size, or 0
/// when nothing more can be parsed this tick.
fn parse_record(io: Io) u64 {
    // The header was ensured by the caller; after the (possibly compacting)
    // ensure below, the record's bytes always begin at chunk_consumed.
    var record_offset = chunk_consumed;
    const record_type = read_u32(chunk[record_offset..][0..4]);
    const misc = read_u16(chunk[record_offset..], 4);
    const size = read_u16(chunk[record_offset..], 6);
    if (size < 8) {
        console.log(.warn, "perf: corrupt record size {d} at offset {d}", .{
            size, absolute_offset(record_offset),
        });
        fail();
        return 0;
    }
    if (!ensure(size, io)) {
        if (chunk_fill - chunk_consumed < size) return 0;
    }

    // Compaction may have moved the record; recompute from chunk_consumed.
    record_offset = chunk_consumed;
    records_seen += 1;
    const payload = chunk[record_offset + 8 .. record_offset + size];

    switch (record_type) {
        record_mmap2 => parse_mmap2(payload),
        record_sample => parse_sample(payload, misc),
        else => {},
    }

    chunk_consumed += size;
    update_progress();
    return size;
}

fn update_progress() void {
    parse_bytes_done = chunk_position - (chunk_fill - chunk_consumed);
}

fn absolute_offset(buffer_index: u32) u64 {
    return chunk_position - (chunk_fill - buffer_index);
}

/// PERF_RECORD_MMAP2: the address space of one mapped file.
fn parse_mmap2(payload: []const u8) void {
    if (payload.len < 65) return; // 64 fixed bytes plus at least a NUL.

    const mapping = Mapping{
        .addr = read_u64(payload, 8),
        .len = read_u64(payload, 16),
        .pgoff = read_u64(payload, 24),
    };

    // The file name is NUL-terminated inside the record.
    const name_bytes = payload[64..];
    const name_end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse {
        return;
    };
    if (name_end == 0) return; // Anonymous mapping, nothing to symbolize.

    // perf repeats mappings across processes and fork events; reuse.
    var index: u32 = 0;
    while (index < mappings_count) : (index += 1) {
        const existing = &mappings[index];
        if (existing.addr != mapping.addr or existing.len != mapping.len) continue;
        if (existing.pgoff != mapping.pgoff) continue;
        if (!std.mem.eql(u8, existing.path[0..existing.path_len], name_bytes[0..name_end])) {
            continue;
        }
        return;
    }
    if (mappings_count == mappings_max) {
        console.log(.warn, "perf: showing first {d} mappings", .{mappings_max});
        return;
    }

    const slot = &mappings[mappings_count];
    slot.* = mapping;
    const copy_len = @min(name_end, path_bytes);
    @memcpy(slot.path[0..copy_len], name_bytes[0..copy_len]);
    slot.path_len = @intCast(copy_len);
    slot.used = true;
    mappings_count += 1;
}

/// PERF_RECORD_SAMPLE, laid out by the sample_type bit order.
fn parse_sample(payload: []const u8, misc: u16) void {
    if (!samples_supported) {
        samples_unsupported += 1;
        return;
    }
    if (sample_type & sample_ip == 0) {
        samples_unsupported += 1;
        return;
    }
    if (payload.len < 8) {
        samples_unsupported += 1;
        return;
    }

    // Leaf IP: the callchain's first entry, else the IP field itself.
    var offset: u32 = 8;
    var leaf: u64 = read_u64(payload, 0);

    if (sample_type & sample_tid != 0) offset += 8;
    if (sample_type & sample_time != 0) offset += 8;
    if (sample_type & sample_addr != 0) offset += 8;

    if (sample_type & sample_callchain != 0) {
        if (offset + 8 > payload.len) return;
        const depth = read_u64(payload, offset);
        if (depth > 0 and offset + 16 <= payload.len) {
            // callchain[0] is the leaf itself; skip perf's context markers.
            // Depths deeper than one need no walking: the record's size
            // bounds the payload, and only the leaf aggregates.
            const first = read_u64(payload, offset + 8);
            if (first < context_marker) leaf = first;
        }
    }

    // misc's low two bits are the CPU mode: 1 is kernel, 2 is user.
    const mode = misc & 3;
    if (mode == 1) {
        samples_kernel += 1;
        return;
    }
    if (mode != 2) return;

    samples_user += 1;
    add_hotspot(leaf);
}

fn add_hotspot(addr: u64) void {
    if (addr >= context_marker) return;

    var probe = hash_addr(addr) % hot_slots;
    var attempts: u32 = 0;
    while (attempts < hot_slots) : (attempts += 1) {
        const hotspot = &hotspots[probe];
        if (!hotspot.used) {
            hotspot.* = .{ .addr = addr, .count = 1, .used = true };
            return;
        }
        if (hotspot.addr == addr) {
            if (hotspot.count < std.math.maxInt(u32)) hotspot.count += 1;
            return;
        }
        probe = (probe + 1) % hot_slots;
    }
    // The table is full: warn once, then drop further samples silently.
    if (!hotspot_full_warned) {
        hotspot_full_warned = true;
        console.log(.warn, "perf: hotspot table full, further samples dropped", .{});
    }
}

var hotspot_full_warned: bool = false;

const FoundMapping = struct { index: u16 };

fn find_mapping(addr: u64) ?FoundMapping {
    var index: u32 = 0;
    while (index < mappings_count) : (index += 1) {
        const mapping = &mappings[index];
        if (!mapping.used) continue;
        if (addr < mapping.addr) continue;
        if (addr >= mapping.addr + mapping.len) continue;
        return .{ .index = @intCast(index) };
    }
    return null;
}

fn hash_addr(addr: u64) u32 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&addr));
    return @truncate(hasher.final());
}

fn read_u32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn read_u16(bytes: []const u8, offset: u32) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn read_u64(bytes: []const u8, offset: u32) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

test "perf: parse a synthetic perf.data" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);

    const path = "/tmp/opencode/diaguiinspect-perf-test.data";
    var records_written: u64 = 0;
    var samples_written: u64 = 0;
    {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        // The attribute section comes first: one attr with
        // sample_type = IP | TID | CALLCHAIN, plus its single id.
        var buffer: [256]u8 = @splat(0);
        @memcpy(buffer[0..8], "PERFILE2");
        write_u64(&buffer, 8, 104); // header size
        write_u64(&buffer, 16, 80); // attr stride
        write_u64(&buffer, 24, 104); // attrs offset
        write_u64(&buffer, 32, 96); // attrs size
        write_u32(&buffer, 104 + 0, 0);
        write_u32(&buffer, 104 + 4, 80);
        write_u64(&buffer, 104 + 24, sample_ip | sample_tid | sample_callchain);
        write_u64(&buffer, 104 + 80, 1); // one id
        write_u64(&buffer, 104 + 88, 1); // the id itself
        write_u64(&buffer, 40, 200); // data offset (final size patched below)
        try file.writeStreamingAll(io, buffer[0..200]);

        // One mapping covering both sample addresses.
        var mapping: [128]u8 = @splat(0);
        write_u32(&mapping, 0, record_mmap2);
        write_u16(&mapping, 4, 2); // user-space mapping
        write_u16(&mapping, 6, 82);
        write_u32(&mapping, 8, 100); // pid
        write_u32(&mapping, 12, 100); // tid
        write_u64(&mapping, 16, 0x1000); // addr
        write_u64(&mapping, 24, 0x2000); // len
        @memcpy(mapping[72..][0..10], "/bin/true\x00");
        try file.writeStreamingAll(io, mapping[0..82]);
        records_written += 1;

        // Enough samples to cross the parser's 64 KiB chunk several times:
        // the compaction and refill paths only run with real volume.
        var sample_index: u32 = 0;
        while (sample_index < 2000) : (sample_index += 1) {
            const ip: u64 = if (sample_index % 4 == 0) 0x1300 else 0x1234;
            var row: [64]u8 = undefined;
            const size = fill_sample(&row, ip, 2, &.{ ip, 0x1000 });
            try file.writeStreamingAll(io, row[0..size]);
            records_written += 1;
            samples_written += 1;
        }

        // A kernel-mode sample: counted, never aggregated.
        var row: [64]u8 = undefined;
        const kernel_size = fill_sample(&row, 0x9999, 1, &.{0x9999});
        try file.writeStreamingAll(io, row[0..kernel_size]);
        records_written += 1;

        // Patch the header's data size now that it is known.
        const stat = try file.stat(io);
        write_u64(&buffer, 48, stat.size - 200);
        try file.writePositionalAll(io, buffer[0..104], 0);
    }

    start(io, path);
    var ticks: u32 = 0;
    while (ticks < 400) : (ticks += 1) {
        tick_budget(io);
        if (parse_done and symbol_done) break;
    }
    close_all(io);

    try std.testing.expect(parse_done);
    try std.testing.expect(!parse_failed);
    try std.testing.expect(symbol_done);
    try std.testing.expectEqual(records_written, records_seen);
    try std.testing.expectEqual(samples_written, samples_user);
    try std.testing.expectEqual(@as(u64, 1), samples_kernel);
    try std.testing.expectEqual(@as(u32, 1), mappings_count);
    try std.testing.expectEqualStrings(
        "/bin/true",
        mappings[0].path[0..mappings[0].path_len],
    );

    // Three quarters of the samples land on 0x1234, the rest on 0x1300.
    try std.testing.expectEqual(@as(u32, 2), top_count);
    try std.testing.expectEqual(@as(u64, 0x1234), top[0].addr);
    try std.testing.expectEqual(@as(u32, 1500), top[0].count);
    try std.testing.expectEqual(@as(u64, 0x1300), top[1].addr);
    try std.testing.expectEqual(@as(u32, 500), top[1].count);
    try std.testing.expect(top[0].has_mapping);
    try std.testing.expectEqual(@as(u32, 100), percent_done());
}

/// Fill one SAMPLE record into `buffer`, returning its total size.
fn fill_sample(buffer: []u8, ip: u64, misc: u16, chain: []const u64) u32 {
    const payload_size: u32 = 24 + @as(u32, @intCast(chain.len * 8));
    const record_size: u32 = 8 + payload_size;

    write_u32(buffer, 0, record_sample);
    write_u16(buffer, 4, misc);
    write_u16(buffer, 6, @intCast(record_size));
    write_u64(buffer, 8, ip);
    write_u32(buffer, 16, 100);
    write_u32(buffer, 20, 100);
    write_u64(buffer, 24, chain.len);
    var index: u32 = 0;
    while (index < chain.len) : (index += 1) {
        write_u64(buffer, 32 + index * 8, chain[index]);
    }
    return record_size;
}

fn write_u16(buffer: []u8, offset: u32, value: u16) void {
    std.mem.writeInt(u16, buffer[offset..][0..2], value, .little);
}

fn write_u32(buffer: []u8, offset: u32, value: u32) void {
    std.mem.writeInt(u32, buffer[offset..][0..4], value, .little);
}

fn write_u64(buffer: []u8, offset: u32, value: u64) void {
    std.mem.writeInt(u64, buffer[offset..][0..8], value, .little);
}
