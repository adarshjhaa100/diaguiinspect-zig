// GDB/MI3 record and value parser.
//
// MI is gdb's machine-oriented protocol: every line is a record and every
// record carries a payload of tuples, lists and quoted strings. The grammar
// nests, but Tiger Style forbids recursion, so containers are parsed with an
// explicit frame stack of bounded depth. Every limit below is a hard bound:
// gdb is an external process and its output is untrusted input, so hitting a
// limit is an ordinary error that the caller reports to the console, never
// an assertion and never unbounded memory.
//
// Arena layout: elements accumulate in append-only scratch, chained per
// frame; when a container closes, its elements are copied into one
// contiguous run of the final arrays, in order. That is what makes the
// public `Value` slices flat and safe: a nested container's allocations can
// never collide with a sibling's, because the copy happens after the nested
// container is done with the scratch entirely.

const std = @import("std");

const assert = std.debug.assert;

pub const Value = union(enum) {
    /// A quoted MI string, unescaped into the arena.
    string: []const u8,
    /// `name=value` entries, from `{...}` or `[name=value,...]`.
    results: []const Entry,
    /// Bare values, from `[value,...]`.
    values: []const Value,
};

pub const Entry = struct {
    name: []const u8,
    value: Value,
};

pub const Error = error{
    InputEnded,
    UnexpectedChar,
    DepthLimit,
    EntriesLimit,
    ValuesLimit,
    StringLimit,
    MixedList,
};

pub const depth_max: u32 = 32;
pub const entries_max: u32 = 1024;
pub const values_max: u32 = 1024;
/// gdb prints vector registers as full `{v4_float = {...}}` aggregates, so
/// one register-values reply alone can carry tens of KiB of string data.
pub const strings_bytes_max: u32 = 64 * 1024;

/// Scratch slot for one `name=value` element, linked to the previously
/// reserved element of the same frame.
const ScratchEntry = struct {
    entry: Entry,
    next: ?u32,
};

/// Scratch memory for one parsed record. Values reference arena storage, so
/// an arena's contents are only valid until its next `reset`.
pub const Arena = struct {
    // Append-only scratch: never sliced, so ordering is irrelevant while
    // parsing; each frame chains its own elements for the final copy.
    scratch_entries: [entries_max]ScratchEntry = undefined,
    scratch_entries_len: u32 = 0,
    scratch_value_next: [values_max]?u32 = undefined,
    scratch_values: [values_max]Value = undefined,
    scratch_values_len: u32 = 0,

    // Final contiguous runs, allocated as containers close.
    entries: [entries_max]Entry = undefined,
    entries_len: u32 = 0,
    value_slots: [values_max]Value = undefined,
    values_len: u32 = 0,

    strings: [strings_bytes_max]u8 = undefined,
    strings_len: u32 = 0,

    pub fn reset(arena: *Arena) void {
        arena.scratch_entries_len = 0;
        arena.scratch_values_len = 0;
        arena.entries_len = 0;
        arena.values_len = 0;
        arena.strings_len = 0;
    }
};

/// The scratch slot for the element currently being parsed.
const Reservation = union(enum) {
    none,
    entry: u32,
    value: u32,
};

const Frame = struct {
    /// The character that closes this container: '}' for '{', ']' for '['.
    /// Zero for the root frame, which is closed by end of input instead.
    closing: u8 = 0,
    /// This frame's element chains (newest first) and counts, over scratch.
    entry_chain: ?u32 = null,
    entry_count: u32 = 0,
    value_chain: ?u32 = null,
    value_count: u32 = 0,
    reserved: Reservation = .none,
    is_root: bool = false,
};

const Parser = struct {
    arena: *Arena,
    line: []const u8,
    index: u32,
    frames: [depth_max]Frame = @splat(.{}),
    depth: u32 = 0,
};

/// Parse one MI value from the whole of `line`. The root of the parse is
/// itself an implicit results container: MI result payloads are sequences of
/// `name=value` pairs, while a single bare value (a stream record's string
/// or tuple) completes the parse immediately.
pub fn parse_value(arena: *Arena, line: []const u8, out: *Value) Error!void {
    arena.reset();

    var parser: Parser = .{ .arena = arena, .line = line, .index = 0 };
    parser.frames[0] = .{ .is_root = true };
    parser.depth = 1;

    while (parser.depth > 0) {
        try parse_step(&parser, out);
    }

    // Anything left over means the payload was not one whole MI value.
    skip_space(&parser);
    if (parser.index < line.len) return Error.UnexpectedChar;
}

/// Work the top frame for one element. A container value pushes a frame and
/// is finished by a later step; a leaf value fills its reserved slot at once.
fn parse_step(parser: *Parser, out: *Value) Error!void {
    const frame = &parser.frames[parser.depth - 1];

    skip_space(parser);
    if (frame.is_root and parser.index >= parser.line.len) {
        // End of input closes a root holding named results. A root with
        // nothing consumed is an empty payload, which MI never sends.
        if (frame.entry_count == 0) return Error.InputEnded;
        parser.depth = 0;
        out.* = try build_container_value(parser, frame);
        return;
    }

    // Elements are separated by commas; after an element completes, the
    // loop re-enters here, so consuming the separator keeps `parse_one`
    // unexposed to it.
    const separator = peek(parser) orelse return Error.InputEnded;
    if (separator == ',') {
        parser.index += 1;
        skip_space(parser);
    }

    if (!frame.is_root) {
        const closing = peek(parser) orelse return Error.InputEnded;
        if (closing == frame.closing) {
            try close_frame(parser, frame, out);
            return;
        }
    }

    try reserve_element_slot(parser, frame);
    const depth_before = parser.depth;
    const value = try parse_one(parser);

    if (parser.depth > depth_before) {
        // A container was pushed; its close will fill the reserved slot.
        return;
    }
    try fill_element_slot(parser, frame, value, out);
}

/// Reserve a scratch slot for the next element: a `name=` prefix reserves
/// from the entry scratch, anything else (a bare element) reserves from the
/// value scratch. The root reserves nothing for bare elements, which
/// complete the whole parse instead.
fn reserve_element_slot(parser: *Parser, frame: *Frame) Error!void {
    assert(frame.reserved == .none);

    skip_space(parser);
    const start = parser.index;
    while (parser.index < parser.line.len and is_name_char(parser.line[parser.index])) {
        parser.index += 1;
    }

    const is_name = parser.index > start and parser.index < parser.line.len and
        parser.line[parser.index] == '=';
    if (is_name) {
        parser.index += 1;
        if (parser.arena.scratch_entries_len >= entries_max) return Error.EntriesLimit;

        const index = parser.arena.scratch_entries_len;
        parser.arena.scratch_entries_len += 1;
        parser.arena.scratch_entries[index] = .{
            .entry = .{
                .name = parser.line[start .. parser.index - 1],
                .value = .{ .string = "" },
            },
            .next = frame.entry_chain,
        };
        frame.entry_chain = index;
        frame.entry_count += 1;
        frame.reserved = .{ .entry = index };
        return;
    }

    // Not a name: rewind so `parse_one` sees the element as-is.
    parser.index = start;
    if (frame.is_root) return;

    if (parser.arena.scratch_values_len >= values_max) return Error.ValuesLimit;
    const index = parser.arena.scratch_values_len;
    parser.arena.scratch_values_len += 1;
    parser.arena.scratch_values[index] = .{ .string = "" };
    parser.arena.scratch_value_next[index] = frame.value_chain;
    frame.value_chain = index;
    frame.value_count += 1;
    frame.reserved = .{ .value = index };
}

/// Fill the scratch slot reserved for the just-completed element.
fn fill_element_slot(parser: *Parser, frame: *Frame, value: Value, out: *Value) Error!void {
    switch (frame.reserved) {
        .none => {
            // A bare root value completes the parse — but only when nothing
            // was attached before it: a mix would mean two payloads.
            assert(frame.is_root);
            if (frame.entry_count > 0) return Error.UnexpectedChar;
            parser.depth = 0;
            out.* = value;
        },
        .entry => |index| {
            parser.arena.scratch_entries[index].entry.value = value;
            frame.reserved = .none;
        },
        .value => |index| {
            parser.arena.scratch_values[index] = value;
            frame.reserved = .none;
        },
    }
}

/// Close the top container: build its value and fill its parent's reserved
/// slot, completing the root when the parent is an unnamed root.
fn close_frame(parser: *Parser, frame: *Frame, out: *Value) Error!void {
    parser.index += 1;
    parser.depth -= 1;
    const container = try build_container_value(parser, frame);
    const parent = &parser.frames[parser.depth - 1];

    switch (parent.reserved) {
        .none => {
            // A container pushed by an unnamed root is the whole payload.
            assert(parent.is_root);
            parser.depth = 0;
            out.* = container;
        },
        .entry => |index| {
            parser.arena.scratch_entries[index].entry.value = container;
            parent.reserved = .none;
        },
        .value => |index| {
            parser.arena.scratch_values[index] = container;
            parent.reserved = .none;
        },
    }
}

/// Build a container's value by copying its chained scratch elements into
/// one contiguous final run, restoring element order.
fn build_container_value(parser: *Parser, frame: *Frame) Error!Value {
    const arena = parser.arena;
    assert(frame.reserved == .none);

    if (frame.entry_count > 0 and frame.value_count > 0) return Error.MixedList;

    if (frame.entry_count > 0) {
        if (arena.entries_len + frame.entry_count > entries_max) {
            return Error.EntriesLimit;
        }
        const start = arena.entries_len;
        arena.entries_len += frame.entry_count;

        var remaining = frame.entry_count;
        var link = frame.entry_chain;
        while (link) |index| : (link = arena.scratch_entries[index].next) {
            remaining -= 1;
            assert(remaining < frame.entry_count);
            arena.entries[start + remaining] = arena.scratch_entries[index].entry;
        }
        assert(remaining == 0);
        return Value{ .results = arena.entries[start..][0..frame.entry_count] };
    }

    if (frame.value_count > 0) {
        if (arena.values_len + frame.value_count > values_max) {
            return Error.ValuesLimit;
        }
        const start = arena.values_len;
        arena.values_len += frame.value_count;

        var remaining = frame.value_count;
        var link = frame.value_chain;
        while (link) |index| : (link = arena.scratch_value_next[index]) {
            remaining -= 1;
            assert(remaining < frame.value_count);
            arena.value_slots[start + remaining] = arena.scratch_values[index];
        }
        assert(remaining == 0);
        return Value{ .values = arena.value_slots[start..][0..frame.value_count] };
    }

    // An empty container has no elements to copy; represent it as an empty
    // value list, which is how every consumer treats it.
    return Value{ .values = arena.value_slots[arena.values_len..][0..0] };
}

/// Parse one leaf value, or push a frame for a container value.
fn parse_one(parser: *Parser) Error!Value {
    skip_space(parser);
    const c = peek(parser) orelse return Error.InputEnded;

    if (c == '"') {
        parser.index += 1;
        return Value{ .string = try parse_string(parser) };
    }
    if (c == '{' or c == '[') {
        parser.index += 1;
        try push_frame(parser, c);
        return Value{ .string = "" };
    }
    return Error.UnexpectedChar;
}

fn push_frame(parser: *Parser, opening: u8) Error!void {
    if (parser.depth >= depth_max) return Error.DepthLimit;

    parser.depth += 1;
    parser.frames[parser.depth - 1] = .{
        .closing = if (opening == '{') '}' else ']',
    };
    assert(parser.depth <= depth_max);
}

fn is_name_char(c: u8) bool {
    if (c >= 'a' and c <= 'z') return true;
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= '0' and c <= '9') return true;
    if (c == '-' or c == '_') return true;
    return false;
}

fn parse_string(parser: *Parser) Error![]const u8 {
    const start = parser.arena.strings_len;
    while (true) {
        const c = peek(parser) orelse return Error.InputEnded;
        parser.index += 1;
        if (c == '"') break;

        if (c == '\\') {
            const escape = peek(parser) orelse return Error.InputEnded;
            parser.index += 1;
            try append_escape(parser, escape);
        } else {
            try append_byte(parser, c);
        }
    }
    return parser.arena.strings[start..parser.arena.strings_len];
}

/// MI string escapes: the standard set plus three-digit octal (`\nnn`),
/// which gdb uses for non-ASCII bytes.
fn append_escape(parser: *Parser, escape: u8) Error!void {
    switch (escape) {
        'n' => try append_byte(parser, '\n'),
        't' => try append_byte(parser, '\t'),
        'r' => try append_byte(parser, '\r'),
        'f' => try append_byte(parser, 0x0c),
        'b' => try append_byte(parser, 0x08),
        '"', '\\', '/' => try append_byte(parser, escape),
        else => {
            if (escape < '0' or escape > '7') return Error.UnexpectedChar;
            var value: u32 = escape - '0';
            var digit_index: u32 = 0;
            while (digit_index < 2) : (digit_index += 1) {
                const digit = peek(parser) orelse return Error.InputEnded;
                if (digit < '0' or digit > '7') return Error.UnexpectedChar;
                parser.index += 1;
                value = value * 8 + (digit - '0');
            }
            assert(value <= 0o777);
            try append_byte(parser, @truncate(value));
        },
    }
}

fn append_byte(parser: *Parser, byte: u8) Error!void {
    if (parser.arena.strings_len >= strings_bytes_max) return Error.StringLimit;
    parser.arena.strings[parser.arena.strings_len] = byte;
    parser.arena.strings_len += 1;
}

fn skip_space(parser: *Parser) void {
    while (parser.index < parser.line.len) {
        const c = parser.line[parser.index];
        if (c != ' ' and c != '\t') break;
        parser.index += 1;
    }
}

fn peek(parser: *Parser) ?u8 {
    if (parser.index >= parser.line.len) return null;
    return parser.line[parser.index];
}

pub const RecordKind = enum {
    /// The `(gdb)` prompt: gdb is ready for the next command.
    prompt,
    /// Console stream output: `~"text"`.
    console_stream,
    /// Target program output: `@"text"`.
    target_stream,
    /// gdb log output: `&"text"`.
    log_stream,
    /// A command response: `[token]^class[,results]`.
    result,
    /// An execution state change: `*stopped[,results]`.
    exec_async,
    /// A status change: `=class[,params]`.
    notify_async,
    /// Anything else: reported to the console, never fatal.
    unknown,
};

pub const Record = struct {
    kind: RecordKind,
    token: ?u32,
    /// The result class (`done`, `error`, `stopped`, ...) or the async class
    /// (`breakpoint-modified`, `thread-group-added`, ...).
    class: []const u8,
    /// The parsed payload of result/exec/notify records.
    results: ?Value,
    /// The unescaped payload of stream records.
    text: []const u8,
};

/// Classify and parse one MI line. `line` must outlive the returned record's
/// arena-backed payloads, which holds for gdb lines kept in the drain queue.
pub fn parse_record(arena: *Arena, line: []const u8, out: *Record) Error!void {
    arena.reset();
    out.* = .{ .kind = .unknown, .token = null, .class = "", .results = null, .text = "" };

    // gdb emits its prompt with a trailing space: "(gdb) ".
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.eql(u8, trimmed, "(gdb)")) {
        out.kind = .prompt;
        return;
    }
    if (line.len == 0) return;

    switch (line[0]) {
        '~' => return parse_stream_record(arena, line, out, .console_stream),
        '@' => return parse_stream_record(arena, line, out, .target_stream),
        '&' => return parse_stream_record(arena, line, out, .log_stream),
        '*' => try parse_async_record(arena, line[1..], out, .exec_async),
        '=' => try parse_async_record(arena, line[1..], out, .notify_async),
        '^' => try parse_result_record(arena, line[1..], null, out),
        '0'...'9' => {
            const token_end = scan_while(line, 0, is_digit);
            const token = std.fmt.parseInt(u32, line[0..token_end], 10) catch {
                out.kind = .unknown;
                return;
            };
            if (token_end >= line.len or line[token_end] != '^') {
                out.kind = .unknown;
                return;
            }
            try parse_result_record(arena, line[token_end + 1 ..], token, out);
        },
        else => {},
    }
}

fn parse_stream_record(arena: *Arena, line: []const u8, out: *Record, kind: RecordKind) Error!void {
    // The tail after the leading '~'/'@'/'&' is exactly one MI string.
    var value: Value = undefined;
    try parse_value(arena, line[1..], &value);
    if (value != .string) return Error.UnexpectedChar;

    out.kind = kind;
    out.text = value.string;
    assert(out.text.len <= strings_bytes_max);
}

fn parse_async_record(arena: *Arena, tail: []const u8, out: *Record, kind: RecordKind) Error!void {
    out.kind = kind;
    out.class = scan_word(tail, 0);
    if (out.class.len == tail.len) return;

    if (tail[out.class.len] != ',') return Error.UnexpectedChar;
    var value: Value = undefined;
    try parse_value(arena, tail[out.class.len + 1 ..], &value);
    out.results = value;
}

fn parse_result_record(arena: *Arena, tail: []const u8, token: ?u32, out: *Record) Error!void {
    out.kind = .result;
    out.token = token;
    out.class = scan_word(tail, 0);
    if (out.class.len == tail.len) return;

    if (tail[out.class.len] != ',') return Error.UnexpectedChar;
    var value: Value = undefined;
    try parse_value(arena, tail[out.class.len + 1 ..], &value);
    out.results = value;
}

fn is_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn scan_while(line: []const u8, from: u32, match: *const fn (u8) bool) u32 {
    var index = from;
    while (index < line.len and match(line[index])) index += 1;
    return index;
}

fn scan_word(line: []const u8, from: u32) []const u8 {
    var index = from;
    while (index < line.len and is_name_char(line[index])) index += 1;
    return line[from..index];
}

/// Find an entry by name in a results value. Returns null for any other kind
/// of value, which keeps call sites free of union-checking ceremony.
pub fn find(value: Value, name: []const u8) ?Value {
    if (value != .results) return null;

    for (value.results) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

pub fn find_string(value: Value, name: []const u8) ?[]const u8 {
    const found = find(value, name) orelse return null;
    if (found != .string) return null;
    return found.string;
}

pub fn find_int(value: Value, name: []const u8) ?u64 {
    const found = find_string(value, name) orelse return null;
    return parse_int(found);
}

/// Parse an MI integer literal, which gdb emits in either decimal or
/// `0x`-prefixed hexadecimal. Anything else (empty, negative, oversized) is
/// not an MI integer as far as diaguiinspect is concerned.
pub fn parse_int(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    if (text[0] == '-') return null;

    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(u64, text[2..], 16) catch null;
    }
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Test helpers: assert an optional string/int in one short line.
fn expect_string(found: ?[]const u8, expected: []const u8) !void {
    const text = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, text);
}

fn expect_int(found: ?u64, expected: u64) !void {
    const value = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, value);
}

test "parse nested tuples and lists" {
    var arena: Arena = .{};
    var value: Value = undefined;
    try parse_value(&arena, "{a=\"1\",b=[{c=\"x\"},{d=\"y\",e=\"z\"}]}", &value);

    const a = find_string(value, "a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", a);
    const b = find(value, "b") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b == .values);
    try std.testing.expectEqual(@as(u32, 2), b.values.len);

    const second = b.values[1];
    try expect_string(find_string(second, "d"), "y");
    try expect_string(find_string(second, "e"), "z");
    try std.testing.expect(find_string(second, "missing") == null);
}

test "parse named entries inside square lists" {
    var arena: Arena = .{};
    var value: Value = undefined;
    try parse_value(&arena, "[frame={level=\"0\",func=\"main\"},frame={level=\"1\"}]", &value);

    // All elements are named, so the list parses as results — exactly how
    // `-stack-list-frames` and `body=[bkpt={...}]` arrive.
    try std.testing.expect(value == .results);
    try std.testing.expectEqual(@as(u32, 2), value.results.len);
    const frame = value.results[0].value;
    try expect_string(find_string(frame, "func"), "main");
}

test "parse bare and named elements in one record" {
    // The root payload of a -break-list response: named entries whose values
    // are lists whose elements are themselves named tuples, nested deeply
    // enough to exercise the scratch/copy discipline.
    var arena: Arena = .{};
    var value: Value = undefined;
    try parse_value(
        &arena,
        "{table={body=[bkpt={number=\"1\",addr=\"0x100\"}," ++
            "bkpt={number=\"2\",addr=\"0x200\"}],hdr=[{width=\"7\"}]}" ++
            ",count=\"2\"}",
        &value,
    );

    const table = find(value, "table") orelse return error.TestUnexpectedResult;
    const body = find(table, "body") orelse return error.TestUnexpectedResult;
    try std.testing.expect(body == .results);
    try std.testing.expectEqual(@as(u32, 2), body.results.len);

    const second = body.results[1].value;
    try expect_int(find_int(second, "addr"), 0x200);

    // The sibling `count` entry must survive the nested copies intact.
    try expect_string(find_string(value, "count"), "2");
}

test "parse empty containers" {
    var arena: Arena = .{};
    var value: Value = undefined;
    try parse_value(&arena, "{}", &value);
    try std.testing.expect(value == .values);
    try std.testing.expectEqual(@as(u32, 0), value.values.len);

    try parse_value(&arena, "[]", &value);
    try std.testing.expect(value == .values);
    try std.testing.expectEqual(@as(u32, 0), value.values.len);
}

test "parse string escapes including octal" {
    var arena: Arena = .{};
    var value: Value = undefined;
    try parse_value(&arena, "\"a\\nb\\t\\\"q\\\"\\\\c\\101\\377\"", &value);
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("a\nb\t\"q\"\\cA\xff", value.string);
}

test "reject malformed input" {
    var arena: Arena = .{};
    var value: Value = undefined;
    try std.testing.expectError(Error.InputEnded, parse_value(&arena, "\"unterminated", &value));
    try std.testing.expectError(Error.UnexpectedChar, parse_value(&arena, "bare", &value));
    try std.testing.expectError(Error.InputEnded, parse_value(&arena, "{a=\"1\"", &value));
    try std.testing.expectError(Error.UnexpectedChar, parse_value(&arena, "\"a\" \"b\"", &value));
    try std.testing.expectError(Error.MixedList, parse_value(&arena, "[a=\"1\",\"b\"]", &value));

    // A string beyond the arena's bound is an ordinary error, not a crash:
    // gdb's output is untrusted, so the parser degrades instead of blowing up.
    var oversized: [strings_bytes_max + 8]u8 = @splat('y');
    oversized[0] = '"';
    oversized[oversized.len - 1] = '"';
    try std.testing.expectError(Error.StringLimit, parse_value(&arena, oversized[0..], &value));
}

test "reject nesting beyond the depth bound" {
    var arena: Arena = .{};
    var value: Value = undefined;

    // One nesting level per '['; deeper than depth_max must be refused.
    var deep: [depth_max + 8]u8 = @splat('[');
    try std.testing.expectError(Error.DepthLimit, parse_value(&arena, deep[0..], &value));
}

test "parse result records with and without tokens" {
    var arena: Arena = .{};
    var record: Record = undefined;

    try parse_record(&arena, "(gdb)", &record);
    try std.testing.expectEqual(RecordKind.prompt, record.kind);

    try parse_record(&arena, "42^done,stack=[frame={level=\"0\"}]", &record);
    try std.testing.expectEqual(RecordKind.result, record.kind);
    try std.testing.expectEqual(@as(?u32, 42), record.token);
    try std.testing.expectEqualStrings("done", record.class);
    const results = record.results orelse return error.TestUnexpectedResult;
    try std.testing.expect(find_int(results, "stack") == null);

    try parse_record(&arena, "^error,msg=\"No symbol table is loaded.\"", &record);
    try std.testing.expectEqual(RecordKind.result, record.kind);
    try std.testing.expect(record.token == null);
    try std.testing.expectEqualStrings("error", record.class);
    const msg = find_string(record.results orelse return error.TestUnexpectedResult, "msg");
    try expect_string(msg, "No symbol table is loaded.");

    try parse_record(&arena, "99999999999999999999^done", &record);
    // An oversized token is not a crash, just an unclassified line.
    try std.testing.expectEqual(RecordKind.unknown, record.kind);
}

test "parse async and stream records" {
    var arena: Arena = .{};
    var record: Record = undefined;

    try parse_record(
        &arena,
        "*stopped,reason=\"breakpoint-hit\",bkptno=\"1\",frame={addr=\"0x401126\",func=\"main\"}",
        &record,
    );
    try std.testing.expectEqual(RecordKind.exec_async, record.kind);
    try std.testing.expectEqualStrings("stopped", record.class);
    const results = record.results orelse return error.TestUnexpectedResult;
    try expect_string(find_string(results, "reason"), "breakpoint-hit");
    const frame = find(results, "frame") orelse return error.TestUnexpectedResult;
    try expect_int(find_int(frame, "addr"), 0x401126);

    try parse_record(&arena, "=thread-group-added,id=\"i1\"", &record);
    try std.testing.expectEqual(RecordKind.notify_async, record.kind);
    try std.testing.expectEqualStrings("thread-group-added", record.class);

    try parse_record(&arena, "~\"GNU gdb (GDB) 15.1\\n\"", &record);
    try std.testing.expectEqual(RecordKind.console_stream, record.kind);
    try std.testing.expectEqualStrings("GNU gdb (GDB) 15.1\n", record.text);

    try parse_record(&arena, "definitely not MI", &record);
    try std.testing.expectEqual(RecordKind.unknown, record.kind);
}

test "parse integers in both MI bases" {
    try std.testing.expectEqual(@as(u64, 4096), parse_int("4096").?);
    try std.testing.expectEqual(@as(u64, 0x401126), parse_int("0x401126").?);
    try std.testing.expectEqual(@as(u64, 0), parse_int("0").?);
    try std.testing.expect(parse_int("") == null);
    try std.testing.expect(parse_int("-1") == null);
    try std.testing.expect(parse_int("0xZZ") == null);
}

test "parse a realistic gdb breakpoint table" {
    var arena: Arena = .{};
    var record: Record = undefined;

    try parse_record(
        &arena,
        "8^done,BreakpointTable={nr_rows=\"1\",nr_cols=\"6\"," ++
            "hdr=[{width=\"7\",col_name=\"num\"}]," ++
            "body=[bkpt={number=\"1\",type=\"breakpoint\",disp=\"keep\"," ++
            "enabled=\"y\",addr=\"0x0000000000401136\",func=\"main\"," ++
            "file=\"a.c\",fullname=\"/home/u/a.c\",line=\"3\",times=\"0\"," ++
            "original-location=\"a.c:3\"}]}",
        &record,
    );
    const results = record.results orelse return error.TestUnexpectedResult;
    const table = find(results, "BreakpointTable") orelse return error.TestUnexpectedResult;
    const body = find(table, "body") orelse return error.TestUnexpectedResult;
    try std.testing.expect(body == .results);
    try std.testing.expectEqual(@as(u32, 1), body.results.len);

    const bkpt = body.results[0].value;
    try std.testing.expectEqual(@as(u64, 0x401136), find_int(bkpt, "addr").?);
    try std.testing.expectEqualStrings("y", find_string(bkpt, "enabled").?);
    try std.testing.expectEqualStrings("a.c:3", find_string(bkpt, "original-location").?);
}
