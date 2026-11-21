// App-level end-to-end: drive app.start and app.tick exactly as the GUI's
// frame loop does, until a real target stops and every view holds data.
//
// This is the "run it completely" test: the same code paths the windows
// rely on — session startup, a console command, the *stopped record, the
// stop refresh, registers, stack, disassembly, threads — executed in the
// same order the GUI executes them. gdb is a runtime dependency, so the
// test skips silently when gdb is not installed.

const std = @import("std");
const app = @import("app.zig");
const console = @import("console.zig");
const gdb = @import("gdb.zig");

const Io = std.Io;

test "app: a complete session, start to stop to teardown" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);

    // /bin/true loads without symbols; `starti` stops it at the program
    // entry, exercising the same path a breakpoint hit takes. No auto-run,
    // exactly like `diaguiinspect-zig --no-run ./some-program`.
    app.start(io, .{
        .gdb_bin = "gdb",
        .program = "/bin/true",
        .run_at_start = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return, // gdb not installed: skip.
        else => return err,
    };

    // The raw gdb window sends console commands through MI; drive the
    // identical path here.
    app.send_raw_console("starti");

    var attempts: u32 = 0;
    while (attempts < 800) : (attempts += 1) {
        app.tick();
        if (app.app.status == .stopped) break;
        gdb.wait_for_output(io);
    }
    try std.testing.expectEqual(app.TargetStatus.stopped, app.app.status);
    try std.testing.expect(app.app.stop.valid);
    try std.testing.expect(app.app.stop.pc > 0);

    // The stop triggered the app's refresh batch; wait until every view's
    // response has landed, as the windows would.
    attempts = 0;
    while (attempts < 800) : (attempts += 1) {
        app.tick();
        if (session_ready()) break;
        gdb.wait_for_output(io);
    }

    // Tear down while gdb is still attached: the polite -gdb-exit path.
    gdb.stop(io);

    if (!session_ready()) {
        dump_console_on_failure();
    }
    try std.testing.expect(session_ready());
}

/// Fail loudly with everything the console collected: a failed view means
/// gdb said something this test needs to know.
fn dump_console_on_failure() void {
    std.debug.print(
        "registers={d} frames={d} instructions={d} threads={d} pc=0x{x}\n",
        .{
            app.app.registers_count,    app.app.frames_count,
            app.app.instructions_count, app.app.threads_count,
            app.app.disassembly_pc,
        },
    );
    var entry: @import("console.zig").Entry = undefined;
    var index: u32 = 0;
    while (@import("console.zig").entry_at(index, &entry)) : (index += 1) {
        std.debug.print("console[{d}]: {s}\n", .{ index, entry.text[0..entry.text_len] });
    }
}

/// True once the stop's refresh batch has populated every view with real
/// data from the stopped target.
fn session_ready() bool {
    if (app.app.registers_count < 16) return false;
    if (app.app.frames_count == 0) return false;
    if (app.app.instructions_count == 0) return false;
    if (app.app.threads_count == 0) return false;
    if (app.app.disassembly_pc == 0) return false;
    return true;
}

// ---------------------------------------------------------------------------
// The complete debugging cycle, against a program the test builds itself:
// run to a breakpoint in main, step over, step into, finish, continue to
// exit. Requires cc; skips silently without it.
// ---------------------------------------------------------------------------

const app_test_source =
    "static int add(int a, int b) { return a + b; }\n" ++
    "int main(void) {\n" ++
    "    int x = 0;\n" ++
    "    x = add(1, 2);\n" ++
    "    x = x + 5;\n" ++
    "    return x;\n" ++
    "}\n";

test "app: run to a breakpoint, step around, continue to exit" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);

    // Write the target's source, then build it; no zig means this project
    // cannot build either, so the skip is theoretical.
    {
        const file = try Io.Dir.cwd().createFile(io, "/tmp/opencode/diaguiinspect-app-test.c", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, app_test_source);
    }
    // `zig cc` rather than `cc`: the test spawns without an environment,
    // and plain gcc needs one to find its cc1, while zig is self-contained.
    var child = std.process.spawn(io, .{
        .argv = &.{
            "zig",
            "cc",
            "-g",
            "-O0",
            "/tmp/opencode/diaguiinspect-app-test.c",
            "-o",
            "/tmp/opencode/diaguiinspect-app-test",
        },
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const term = try child.wait(io);
    try std.testing.expect(term.success());

    try app.start(io, .{
        .gdb_bin = "gdb",
        .program = "/tmp/opencode/diaguiinspect-app-test",
        .run_at_start = true,
        .break_at = "main",
    });

    // Run stops at the breakpoint in main (line 2 of the source).
    try wait_for_stop(io);
    try std.testing.expectEqual(app.TargetStatus.stopped, app.app.status);
    try std.testing.expectEqual(@as(u32, 1), app.app.stop.breakpoint_number);
    try std.testing.expectEqualStrings("main", app.app.stop.func.view());
    try std.testing.expectEqual(@as(u32, 2), app.app.stop.line);

    // The source window follows the stop: the file is loaded and centered
    // on main's line, and the breakpoint table lists it.
    try std.testing.expect(app.app.source_valid);
    try std.testing.expectEqual(@as(u32, 2), app.app.source_current_line);
    try std.testing.expectEqual(@as(u32, 1), app.app.breakpoints_count);
    try std.testing.expectEqual(@as(u32, 1), app.app.breakpoints[0].number);
    try std.testing.expect(app.app.breakpoints[0].enabled);
    try std.testing.expectEqualStrings("main", app.app.breakpoints[0].func.view());

    // Mixed C+asm mode: the disassembly panel interleaves the C lines with
    // the instructions that implement them, anchored at the stop's line.
    app.set_disassembly_mixed(true);
    var mixed_attempts: u32 = 0;
    while (mixed_attempts < 400) : (mixed_attempts += 1) {
        app.tick();
        if (app.app.disassembly_rows_count > 0) break;
        gdb.wait_for_output(io);
    }
    try expect_mixed_rows();

    // Step over: main's line 3, then line 4.
    app.next_line();
    try wait_for_stop(io);
    try std.testing.expectEqual(@as(u32, 3), app.app.stop.line);

    // After a second stop, a moved program counter must show as changed.
    try expect_rip_changed(io);

    app.next_line();
    try wait_for_stop(io);
    try std.testing.expectEqual(@as(u32, 4), app.app.stop.line);

    // Step into the call at line 4: inside add, line 1.
    app.step_line();
    try wait_for_stop(io);
    try std.testing.expectEqualStrings("add", app.app.stop.func.view());
    try std.testing.expectEqual(@as(u32, 1), app.app.stop.line);

    // Finish returns to the caller's line.
    app.finish_execution();
    try wait_for_stop(io);
    try std.testing.expectEqualStrings("main", app.app.stop.func.view());
    try std.testing.expectEqual(@as(u32, 4), app.app.stop.line);

    // Continue: the program runs to completion.
    app.continue_execution();
    var attempts: u32 = 0;
    while (attempts < 400) : (attempts += 1) {
        app.tick();
        if (app.app.status == .exited) break;
        gdb.wait_for_output(io);
    }
    try std.testing.expectEqual(app.TargetStatus.exited, app.app.status);

    gdb.stop(io);
}

fn wait_for_stop(io: Io) !void {
    var attempts: u32 = 0;
    while (attempts < 400) : (attempts += 1) {
        app.tick();
        if (app.app.status == .stopped and app.app.stop.valid) return;
        if (app.app.status == .exited) return error.TestUnexpectedResult;
        gdb.wait_for_output(io);
    }
    return error.TestUnexpectedResult;
}

/// After a stop, the instruction pointer register must be marked changed —
/// it is the one register that always moves. The values refresh lands a
/// few records after the stop itself, so this waits for it.
fn expect_rip_changed(io: Io) !void {
    const rip_index = find_rip_index() orelse return; // non-x86: skip.

    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        app.tick();
        if (app.app.registers[rip_index].changed) return;
        gdb.wait_for_output(io);
    }
    return error.TestUnexpectedResult;
}

fn find_rip_index() ?u32 {
    var index: u32 = 0;
    while (index < app.app.registers_count) : (index += 1) {
        if (std.mem.eql(u8, app.app.registers[index].name.view(), "rip")) {
            return index;
        }
    }
    return null;
}

test "app: a missing program path fails clearly, not inside gdb" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);
    console.clear();

    app.start(io, .{
        .gdb_bin = "gdb",
        .program = "/tmp/opencode/diaguiinspect-no-such-program",
        .run_at_start = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        app.tick();
        gdb.wait_for_output(io);
    }
    gdb.stop(io);

    // The pre-check reports the missing file before gdb ever tries to
    // load it, and the session stays unarmed instead of running garbage.
    try std.testing.expectEqual(app.TargetStatus.no_program, app.app.status);

    var entry: @import("console.zig").Entry = undefined;
    var index: u32 = 0;
    var found_message = false;
    while (@import("console.zig").entry_at(index, &entry)) : (index += 1) {
        const text = entry.text[0..entry.text_len];
        if (std.mem.indexOf(u8, text, "program not found") != null) {
            found_message = true;
        }
    }
    try std.testing.expect(found_message);
}

test "app: inferior stderr lands in the raw window, not as a GUI error" {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    console.set_io(io);
    console.clear();

    // A program that prints to stderr and exits nonzero: exactly the shape
    // of "the console shows an error that is really the program's own
    // complaint" from the field report.
    const source =
        "#include <stdio.h>\n" ++
        "int main(void) {\n" ++
        "    fprintf(stderr, \"failure: No such file or directory\\n\");\n" ++
        "    return 7;\n" ++
        "}\n";
    {
        const stderr_source = "/tmp/opencode/diaguiinspect-stderr-test.c";
        const file = try Io.Dir.cwd().createFile(io, stderr_source, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, source);
    }
    var child = std.process.spawn(io, .{
        .argv = &.{
            "zig",
            "cc",
            "-g",
            "-O0",
            "/tmp/opencode/diaguiinspect-stderr-test.c",
            "-o",
            "/tmp/opencode/diaguiinspect-stderr-test",
        },
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const term = try child.wait(io);
    try std.testing.expect(term.success());

    try app.start(io, .{
        .gdb_bin = "gdb",
        .program = "/tmp/opencode/diaguiinspect-stderr-test",
        .run_at_start = true,
    });

    var attempts: u32 = 0;
    while (attempts < 800) : (attempts += 1) {
        app.tick();
        if (app.app.status == .exited) break;
        gdb.wait_for_output(io);
    }
    gdb.stop(io);

    try std.testing.expectEqual(app.TargetStatus.exited, app.app.status);

    // The health badge must stay clean: the inferior's stderr is program
    // output, shown in the raw gdb window, never a GUI error.
    const totals = console.error_totals();
    try std.testing.expectEqual(@as(u32, 0), totals.total);

    var found_stderr = false;
    var index: u32 = 0;
    while (index < app.app.raw.line_count()) : (index += 1) {
        if (std.mem.indexOf(u8, app.app.raw.line_at(index), "failure: No such") != null) {
            found_stderr = true;
        }
    }
    try std.testing.expect(found_stderr);
}

/// The mixed-mode contract: the panel must hold at least one C source row
/// (a line that exists in the file) with instructions under it, and the
/// row's line must match the stop, so clicking it targets the right line.
fn expect_mixed_rows() !void {
    try std.testing.expect(app.app.disassembly_mixed);
    try std.testing.expect(app.app.disassembly_rows_count > 0);
    try std.testing.expect(app.app.instructions_count > 0);

    var found_source = false;
    var index: u32 = 0;
    while (index < app.app.disassembly_rows_count) : (index += 1) {
        switch (app.app.disassembly_rows[index]) {
            .source => |source| {
                if (source.line != app.app.stop.line) continue;
                found_source = true;
                try std.testing.expect(source.text.len > 0);
            },
            .instruction => {},
        }
    }
    try std.testing.expect(found_source);
}
