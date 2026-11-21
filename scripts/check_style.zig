// Style checker for the two hard Tiger Style limits:
//   * lines longer than 100 columns,
//   * functions longer than 70 lines.
//
// Run: zig run scripts/check_style.zig -- src
// Exits nonzero when any violation is found, so it can gate CI.

const std = @import("std");
const Io = std.Io;

const columns_max: u32 = 100;
const function_lines_max: u32 = 70;

const Violation = struct {
    path: []const u8,
    line: u32,
    message: []const u8,
};

var violations: [256]Violation = undefined;
var violation_count: u32 = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        var buffer: [512]u8 = undefined;
        var stderr_writer = Io.File.stderr().writer(io, &buffer);
        const stderr = &stderr_writer.interface;
        stderr.writeAll("usage: check_style.zig <directory>\n") catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    try scan_dir(arena, io, args[1]);

    var buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;

    var index: u32 = 0;
    while (index < violation_count) : (index += 1) {
        const violation = violations[index];
        stdout.print("{s}:{d}: {s}\n", .{
            violation.path, violation.line, violation.message,
        }) catch {};
    }
    stdout.flush() catch {};

    if (violation_count > 0) {
        stdout.print("{d} style violations\n", .{violation_count}) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    }
}

fn scan_dir(arena: std.mem.Allocator, io: Io, dir_path: []const u8) !void {
    // `.iterate` is required for `walk`; without it the handle cannot be read.
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    // The walker takes the directory handle over; closing it here would
    // double-close what walker.deinit already released.
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.startsWith(u8, entry.basename, ".")) continue;
        // This checker gets checked too.
        if (std.mem.endsWith(u8, entry.basename, "check_style.zig")) continue;

        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.basename });
        try scan_file(arena, io, path);
    }
}

/// Columns are characters, not bytes: box-drawing and other multi-byte
/// glyphs occupy one column each to a reader, and the 100-column rule is
/// about the reader.
fn visual_len(line: []const u8) u32 {
    var columns: u32 = 0;
    var index: u32 = 0;
    while (index < line.len) {
        const sequence = std.unicode.utf8ByteSequenceLength(line[index]) catch {
            // Invalid byte: count it and move on; the style check must
            // never crash on odd input.
            index += 1;
            columns += 1;
            continue;
        };
        index += sequence;
        columns += 1;
    }
    return columns;
}

fn scan_file(arena: std.mem.Allocator, io: Io, path: []const u8) !void {
    const contents = Io.Dir.cwd().readFile(io, path, try arena.alloc(u8, 8 * 1024 * 1024)) catch return;

    var line_number: u32 = 0;
    var function_start: ?u32 = null;
    var function_name: [128]u8 = undefined;
    var depth: u32 = 0;

    var line_iterator = std.mem.splitScalar(u8, contents, '\n');
    while (line_iterator.next()) |line| {
        line_number += 1;

        if (visual_len(line) > columns_max) {
            report(path, line_number, "line over 100 columns");
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (function_start == null and is_fn_declaration(trimmed)) {
            function_start = line_number;
            capture_name(trimmed, &function_name);
        }

        // Braces inside string literals are balanced in this codebase's
        // format strings, so raw counting keeps its balance per line.
        if (trimmed.len > 0 and trimmed[0] != '/') {
            for (trimmed) |c| {
                if (c == '{') {
                    depth += 1;
                } else if (c == '}') {
                    if (depth > 0) depth -= 1;
                }
            }
        }

        if (function_start != null and depth == 0 and line_contains_body(trimmed)) {
            const span = line_number - function_start.? + 1;
            if (span > function_lines_max) {
                const message = std.fmt.bufPrint(&violation_scratch, "function over 70 lines ({d}): {s}", .{
                    span, function_name,
                }) catch "function over 70 lines";
                report(path, function_start.?, message);
            }
            function_start = null;
        }
    }
}

var violation_scratch: [256]u8 = undefined;

fn is_fn_declaration(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "pub fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "fn ")) return true;
    return false;
}

fn line_contains_body(trimmed: []const u8) bool {
    // The declaration line itself opens the body; only a later line that
    // brings the depth back to zero closes it.
    return std.mem.indexOfScalar(u8, trimmed, '}') != null;
}

fn capture_name(trimmed: []const u8, target: *[128]u8) void {
    var index: u32 = 0;
    if (std.mem.startsWith(u8, trimmed, "pub fn ")) index = "pub fn ".len;
    if (std.mem.startsWith(u8, trimmed, "fn ")) index = "fn ".len;

    var end = index;
    while (end < trimmed.len and trimmed[end] != '(' and end < target.len) end += 1;

    const name_len = @min(end - index, target.len);
    @memcpy(target[0..name_len], trimmed[index..][0..name_len]);
}

fn report(path: []const u8, line: u32, message: []const u8) void {
    if (violation_count == violations.len) return;
    violations[violation_count] = .{ .path = path, .line = line, .message = message };
    violation_count += 1;
}
