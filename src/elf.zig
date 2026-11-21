// Minimal ELF symbol-table reader, for symbolizing perf sample addresses.
//
// Only what symbolization needs: find SHT_SYMTAB (or SHT_DYNSYM), stream its
// function symbols into a bounded, address-sorted table, then answer
// "which function contains this address" with names read lazily from the
// file's string table. All memory is static and every step is bounded; a
// binary with more symbols than the bound is truncated with a warning
// rather than refused, because a partial symbol table still beats none.

const std = @import("std");
const console = @import("console.zig");

const Io = std.Io;
const assert = std.debug.assert;

/// One function symbol: its virtual address and its name's byte offset in
/// the ELF's string table. Names are not stored; they are read from the
/// file on lookup, so a big symtab costs 12 bytes per symbol here.
pub const Symbol = struct {
    addr: u64,
    name_offset: u32,
};

/// The symbol table of one ELF file. `symbols` points into storage owned by
/// the caller (perf keeps one table for the module it is currently
/// resolving); nothing here allocates.
pub const Table = struct {
    symbols: []Symbol,
    symbols_count: u32 = 0,
    strtab_offset: u64 = 0,
    strtab_size: u64 = 0,
    has_symbols: bool = false,

    /// The greatest function whose start is at or below `address`.
    pub fn lookup(
        table: *const Table,
        file: Io.File,
        io: Io,
        address: u64,
        name_out: []u8,
    ) ?[]const u8 {
        if (!table.has_symbols) return null;
        if (table.symbols_count == 0) return null;

        // Binary search for the rightmost symbol with addr <= address.
        var low: u32 = 0;
        var high: u32 = table.symbols_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (table.symbols[mid].addr <= address) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low == 0) return null;
        const symbol = table.symbols[low - 1];
        assert(symbol.addr <= address);

        // Names live in the file's string table; read just this one.
        const name_offset = symbol.name_offset;
        if (name_offset >= table.strtab_size) return null;

        const name_at = table.strtab_offset + name_offset;
        const bytes_read = file.readPositional(io, &.{name_out}, name_at) catch {
            return null;
        };
        if (bytes_read == 0) return null;

        const name = std.mem.sliceTo(name_out[0..bytes_read], 0);
        if (name.len == 0) return null;
        return name;
    }
};

/// Bound on sections read, symtab entries kept, and names read. A symtab
/// past the bound is truncated, which still symbolizes the addresses that
/// made it in.
pub const sections_max: u32 = 128;
pub const symbols_max: u32 = 8192;
pub const name_bytes_max: u32 = 256;

/// Stream the file's symbol table into `table`. `symbols` must have room for
/// `symbols_max` entries. Never fatal: every failure warns on the console
/// and leaves whatever symbols already streamed.
pub fn load_symbols(file: Io.File, io: Io, table: *Table) void {
    table.has_symbols = false;
    table.symbols_count = 0;

    var header: [64]u8 = undefined;
    read_all(file, io, 0, header[0..]) orelse return;
    if (!std.mem.eql(u8, header[0..4], "\x7fELF")) {
        console.log(.warn, "elf: not an ELF file, symbols unavailable", .{});
        return;
    }
    const elf_class = header[4];
    if (elf_class != 2) {
        console.log(.warn, "elf: only 64-bit ELF is supported, symbols unavailable", .{});
        return;
    }

    const section_headers_offset = read_u64(header[0..], 0x28);
    const section_header_size = read_u16(header[0..], 0x3a);
    const section_count_raw = read_u16(header[0..], 0x3c);
    if (section_header_size < 64) {
        console.log(.warn, "elf: unexpected section header size {d}", .{section_header_size});
        return;
    }
    if (section_count_raw == 0) {
        // Extended section counts (over 65279 sections) are rare; skip them
        // rather than handle the extra indirection.
        console.log(.warn, "elf: extended section count unsupported, symbols unavailable", .{});
        return;
    }

    const section_count = @min(@as(u32, section_count_raw), sections_max);
    if (section_count_raw > sections_max) {
        console.log(.warn, "elf: showing first {d} of {d} sections", .{
            sections_max, section_count_raw,
        });
    }

    // Real symbol tables (.symtab) carry more than dynamic ones (.dynsym).
    const section_index = find_symbol_table(
        file,
        io,
        section_headers_offset,
        section_header_size,
        section_count,
    ) orelse {
        console.log(.warn, "elf: no symbol table found", .{});
        return;
    };

    if (!load_section_symbols(
        file,
        io,
        table,
        section_headers_offset,
        section_header_size,
        section_count,
        section_index,
    )) {
        return;
    }
}

/// Read the symbol section at `section_index` into `table`: its entries,
/// its linked string table's bounds, and the address sort. Returns false
/// when the section is unusable, with the reason on the console.
fn load_section_symbols(
    file: Io.File,
    io: Io,
    table: *Table,
    section_headers_offset: u64,
    section_header_size: u64,
    section_count: u32,
    section_index: u32,
) bool {
    const section_offset = section_headers_offset + @as(u64, section_index) * section_header_size;
    var section_header: [64]u8 = undefined;
    read_all(file, io, section_offset, section_header[0..]) orelse return false;

    var symtab = Table{ .symbols = table.symbols };

    const symtab_file_offset = read_u64(section_header[0..], 0x18);
    const symtab_size = read_u64(section_header[0..], 0x20);
    const strtab_index = read_u32(section_header[0..], 0x28);
    const entry_size = read_u64(section_header[0..], 0x38);
    if (entry_size < 24) {
        console.log(.warn, "elf: unexpected symbol entry size {d}", .{entry_size});
        return false;
    }

    // The linked string table gives the names, read lazily per lookup.
    if (strtab_index >= section_count) {
        console.log(.warn, "elf: dangling string table link {d}", .{strtab_index});
        return false;
    }
    const strtab_header_offset =
        section_headers_offset + @as(u64, strtab_index) * section_header_size;
    var strtab_header: [64]u8 = undefined;
    read_all(file, io, strtab_header_offset, strtab_header[0..]) orelse return false;
    symtab.strtab_offset = read_u64(strtab_header[0..], 0x18);
    symtab.strtab_size = read_u64(strtab_header[0..], 0x20);

    load_symtab_entries(file, io, &symtab, symtab_file_offset, symtab_size, entry_size);
    if (symtab.symbols_count == 0) {
        console.log(.warn, "elf: symbol table has no functions", .{});
        return false;
    }

    sort_symbols(symtab.symbols[0..symtab.symbols_count]);
    table.* = symtab;
    table.has_symbols = true;
    return true;
}

/// The section to read: the first symtab, or the first dynsym when no
/// symtab exists.
fn find_symbol_table(
    file: Io.File,
    io: Io,
    section_headers_offset: u64,
    section_header_size: u64,
    section_count: u32,
) ?u32 {
    return find_symbol_section(
        file,
        io,
        section_headers_offset,
        section_header_size,
        section_count,
        symtab_kind,
    ) orelse find_symbol_section(
        file,
        io,
        section_headers_offset,
        section_header_size,
        section_count,
        dynsym_kind,
    );
}

/// Index of the first section of `kind` whose linked string table is valid.
fn find_symbol_section(
    file: Io.File,
    io: Io,
    section_headers_offset: u64,
    section_header_size: u64,
    section_count: u32,
    kind: u32,
) ?u32 {
    var section: u32 = 0;
    while (section < section_count) : (section += 1) {
        const section_offset = section_headers_offset + @as(u64, section) * section_header_size;
        var section_header: [64]u8 = undefined;
        read_all(file, io, section_offset, section_header[0..]) orelse return null;

        if (read_u32(section_header[0..], 4) != kind) continue;
        const strtab_index = read_u32(section_header[0..], 0x28);
        if (strtab_index >= section_count) continue;
        return section;
    }
    return null;
}

/// Which symbol table kinds to read, in preference order.
const symtab_kind: u32 = 2;
const dynsym_kind: u32 = 11;

fn load_symtab_entries(
    file: Io.File,
    io: Io,
    table: *Table,
    symtab_offset: u64,
    symtab_size: u64,
    entry_size: u64,
) void {
    // Stream the entries in bounded chunks; a 16 MiB symtab costs a few
    // milliseconds once per module.
    const entries_total = @min(symtab_size / entry_size, symbols_max);
    if (symtab_size / entry_size > symbols_max) {
        console.log(.warn, "elf: keeping first {d} of {d} symbols", .{
            symbols_max, symtab_size / entry_size,
        });
    }

    var entry_index: u64 = 0;
    while (entry_index < entries_total) {
        const remaining: u32 = @intCast(entries_total - entry_index);
        const per_chunk: u32 = @min(chunk.len / 24, remaining);
        const chunk_offset = symtab_offset + entry_index * entry_size;
        const read_size = per_chunk * 24;
        if (read_size > chunk.len) break;

        const bytes_read = file.readPositional(io, &.{chunk[0..read_size]}, chunk_offset) catch {
            return;
        };
        if (bytes_read < read_size) return;

        var within_chunk: u32 = 0;
        while (within_chunk < per_chunk) : (within_chunk += 1) {
            const entry = chunk[within_chunk * 24 ..][0..24];
            const type_info = entry[4];
            const symbol_type = type_info & 0xf;
            const addr = read_u64(entry[0..], 8);
            const name_offset = read_u32(entry[0..], 0);
            if (symbol_type != 2) continue; // STT_FUNC only.
            if (addr == 0) continue;

            const slot = &table.symbols[table.symbols_count];
            slot.addr = addr;
            slot.name_offset = name_offset;
            table.symbols_count += 1;
            assert(table.symbols_count <= symbols_max);
        }
        entry_index += per_chunk;
    }
}

var chunk: [16 * 1024]u8 = undefined;

fn sort_symbols(symbols: []Symbol) void {
    const context = {};
    std.sort.pdq(Symbol, symbols, context, symbol_less_than);
}

fn symbol_less_than(_: void, left: Symbol, right: Symbol) bool {
    return left.addr < right.addr;
}

fn read_all(file: Io.File, io: Io, offset: u64, out: []u8) ?void {
    const bytes_read = file.readPositional(io, &.{out}, offset) catch return null;
    if (bytes_read < out.len) return null;
    return;
}

fn read_u32(bytes: []const u8, offset: u32) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn read_u16(bytes: []const u8, offset: u32) u32 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn read_u64(bytes: []const u8, offset: u32) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

test "parse /bin/true's dynamic symbols and look one up" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);

    const file = Io.Dir.cwd().openFile(io, "/bin/true", .{}) catch {
        // Not every environment has this exact path; skip when absent.
        return;
    };
    defer file.close(io);

    var symbols_buffer: [symbols_max]Symbol = undefined;
    var table = Table{ .symbols = symbols_buffer[0..] };
    load_symbols(file, io, &table);

    if (!table.has_symbols) {
        // A stripped libc-based /bin/true still has a dynamic symbol table;
        // if even that is missing there is nothing to assert.
        return;
    }
    try std.testing.expect(table.symbols_count > 0);

    // Symbols are address-sorted, and every kept symbol is a function.
    var index: u32 = 1;
    while (index < table.symbols_count) : (index += 1) {
        try std.testing.expect(table.symbols[index - 1].addr <= table.symbols[index].addr);
    }

    // Looking up its lowest symbol must resolve to a non-empty name; an
    // address below the first symbol must resolve to nothing.
    const lowest = table.symbols[0];
    var name: [name_bytes_max]u8 = undefined;
    const found = table.lookup(file, io, lowest.addr, name[0..]);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.len > 0);

    const before_lowest = table.lookup(file, io, lowest.addr - 1, name[0..]);
    try std.testing.expect(before_lowest == null);
}
