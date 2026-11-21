// End-to-end gdb session smoke tests.
//
// Each test spawns a real gdb in MI3 mode and drives it through the same
// path the GUI uses: process pipes, reader threads, line queues, MI parsing
// and token matching. gdb itself is a runtime dependency of diaguiinspect, so the
// tests skip silently when gdb is not installed.

const std = @import("std");
const console = @import("console.zig");
const gdb = @import("gdb.zig");
const mi = @import("mi.zig");

const Io = std.Io;

/// What the tests have observed so far; handlers run on the main thread
/// while draining, so plain globals are safe.
var saw_file_loaded = false;
var saw_breakpoint_table = false;
var saw_stopped_frame = false;
var saw_register_values = false;
var saw_gdb_error = false;

fn handle_record(kind: gdb.CommandKind, record: *const mi.Record) void {
    if (record.kind == .exec_async) {
        if (std.mem.eql(u8, record.class, "stopped")) {
            const results = record.results orelse return;
            const frame = mi.find(results, "frame") orelse return;
            saw_stopped_frame = mi.find_int(frame, "addr") != null;
        }
        return;
    }
    if (record.kind != .result) return;

    if (std.mem.eql(u8, record.class, "error")) {
        saw_gdb_error = true;
        return;
    }
    if (!std.mem.eql(u8, record.class, "done")) return;

    switch (kind) {
        .file_symbols => saw_file_loaded = true,
        .list_register_values => {
            const results = record.results orelse return;
            const values = mi.find(results, "register-values") orelse return;
            if (values != .values) return;
            // Enough registers to prove the full ~40 KiB line arrived whole
            // and was parsed, not dropped by the reader's line bound.
            if (values.values.len >= 16) saw_register_values = true;
        },
        .break_list => {
            const results = record.results orelse return;
            if (mi.find(results, "BreakpointTable") != null) saw_breakpoint_table = true;
        },
        else => {},
    }
}

fn reset_observations() void {
    saw_file_loaded = false;
    saw_breakpoint_table = false;
    saw_stopped_frame = false;
    saw_register_values = false;
    saw_gdb_error = false;
}

test "gdb session: spawn, load, query, exit" {
    // The Io references its Threaded instance by pointer, so the instance
    // must outlive every use: it lives in this test's frame.
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);
    reset_observations();

    gdb.start(io, "gdb", null) catch |err| switch (err) {
        // Without gdb installed there is nothing to smoke test.
        error.FileNotFound => return,
        else => return err,
    };

    gdb.sendf(.file_symbols, "-file-exec-and-symbols /bin/true", .{});
    gdb.sendf(.break_list, "-break-list", .{});

    // Drain until both responses arrive, with a generous but bounded wait.
    var attempts: u32 = 0;
    while (attempts < 500) : (attempts += 1) {
        _ = gdb.drain(handle_record);
        if (saw_file_loaded and saw_breakpoint_table) break;
        gdb.wait_for_output(io);
    }

    gdb.stop(io);

    try std.testing.expect(saw_file_loaded);
    try std.testing.expect(saw_breakpoint_table);
    if (saw_gdb_error) {
        return error.TestUnexpectedResult;
    }
}

test "gdb session: stop the target and read its registers" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);
    reset_observations();

    gdb.start(io, "gdb", null) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    // `starti` stops at the program entry without needing symbols, so
    // /bin/true is a valid target: this also exercises the same
    // `-interpreter-exec console` path the raw gdb window uses.
    gdb.sendf(.file_symbols, "-file-exec-and-symbols /bin/true", .{});
    gdb.sendf(.none, "-interpreter-exec console \"starti\"", .{});

    var attempts: u32 = 0;
    while (attempts < 500) : (attempts += 1) {
        _ = gdb.drain(handle_record);
        if (saw_stopped_frame) break;
        gdb.wait_for_output(io);
    }

    // Only with the target stopped do register values mean anything, exactly
    // like diaguiinspect's own refresh after a stop.
    try std.testing.expect(saw_stopped_frame);
    saw_gdb_error = false;

    gdb.sendf(.list_register_values, "-data-list-register-values x", .{});
    attempts = 0;
    while (attempts < 500) : (attempts += 1) {
        _ = gdb.drain(handle_record);
        if (saw_register_values) break;
        gdb.wait_for_output(io);
    }

    gdb.stop(io);

    try std.testing.expect(saw_register_values);
    if (saw_gdb_error) {
        return error.TestUnexpectedResult;
    }
}
