// GDB/MI3 session: child process, pipe reader threads and the command queue.
//
// gdb is an external process that produces output at its own pace. Per Tiger
// Style, diaguiinspect never reacts to gdb directly: reader threads only assemble lines
// into a bounded queue, and the main loop drains a fixed number of lines per
// frame at diaguiinspect's own pace. Every buffer below is statically allocated.

const std = @import("std");
const app = @import("app.zig");
const console = @import("console.zig");
const mi = @import("mi.zig");

const assert = std.debug.assert;
const Io = std.Io;

/// What diaguiinspect expects a command's response to update. Purely informational for
/// commands like `-exec-next` (the `*stopped` record carries the real news).
pub const CommandKind = enum {
    none,
    file_symbols,
    exec_run,
    exec_continue,
    exec_step,
    exec_next,
    exec_step_instruction,
    exec_next_instruction,
    exec_finish,
    exec_interrupt,
    exec_abort,
    stack_select_frame,
    thread_select,
    break_insert,
    break_set_enabled,
    break_delete,
    break_list,
    list_register_names,
    list_register_values,
    stack_list_frames,
    threads_info,
    evaluate_pc,
    disassemble,
    read_memory,
};

/// One MI line, copied out of the queue under its lock. gdb's
/// `-data-list-register-values` reply for x86-64 reaches ~60 KiB (every
/// vector register prints a full aggregate), so the bound must be generous.
pub const line_bytes_max: u32 = 64 * 1024;
/// Fewer, bigger slots: 8 lines of 64 KiB per stream backpressure gdb just
/// as hard as 32 small ones would, at half the static memory.
pub const queue_slots_max: u32 = 8;
pub const pending_max: u32 = 64;
pub const lines_per_drain_max: u32 = 64;
pub const command_bytes_max: u32 = 256;

const Line = struct {
    bytes: [line_bytes_max]u8 = undefined,
    len: u32 = 0,
};

/// Bounded multi-producer single-consumer queue of lines. The reader threads
/// block while it is full, which backpressures gdb at the pipe level: a
/// flooding gdb can never exhaust diaguiinspect's memory.
const LineQueue = struct {
    mutex: Io.Mutex = .init,
    space_available: Io.Condition = .init,
    data_available: Io.Condition = .init,
    slots: [queue_slots_max]Line = @splat(.{}),
    head: u32 = 0,
    count: u32 = 0,
    closed: bool = false,

    fn push(queue: *LineQueue, io: Io, line: []const u8) void {
        assert(line.len <= line_bytes_max);

        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);

        // The main thread drains every frame, so the wait below is bounded
        // by one frame length in practice. Cancelation never reaches diaguiinspect's
        // reader threads; the catch simply re-checks the condition.
        while (queue.count == queue_slots_max) {
            queue.space_available.wait(io, &queue.mutex) catch {};
        }

        const slot = &queue.slots[(queue.head + queue.count) % queue_slots_max];
        @memcpy(slot.bytes[0..line.len], line);
        slot.len = @intCast(line.len);
        queue.count += 1;
        assert(queue.count <= queue_slots_max);

        queue.data_available.signal(io);
    }

    fn pop(queue: *LineQueue, io: Io, out: *Line) bool {
        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);

        if (queue.count == 0) return false;

        // Copy only the line's bytes, never the whole 64 KiB slot.
        const slot = &queue.slots[queue.head];
        @memcpy(out.bytes[0..slot.len], slot.bytes[0..slot.len]);
        out.len = slot.len;
        queue.head = (queue.head + 1) % queue_slots_max;
        queue.count -= 1;
        queue.space_available.signal(io);
        return true;
    }

    fn close(queue: *LineQueue, io: Io) void {
        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);
        queue.closed = true;
    }
};

pub const Session = struct {
    /// The Io given at start; queues and locks need it on every use.
    io: Io = undefined,
    process: ?std.process.Child = null,
    stdout_queue: LineQueue = .{},
    stderr_queue: LineQueue = .{},
    /// Reused per drained line; records are consumed before the next parse.
    arena: mi.Arena = .{},
    pending_tokens: [pending_max]u32 = @splat(0),
    pending_kinds: [pending_max]CommandKind = @splat(.none),
    pending_count: u32 = 0,
    token_next: u32 = 1,
    alive: bool = false,
    readers: [2]?std.Thread = .{ null, null },
};

pub var session: Session = .{};

/// Scratch for composing commands, used only on the main thread. The size
/// fits ten token digits, the longest command diaguiinspect sends, and a newline.
var send_scratch: [command_bytes_max + 24]u8 = undefined;

/// Spawn gdb in MI3 mode with piped stdio and start the reader threads.
/// `core` is passed to gdb as a command line argument; the debugged program
/// itself is loaded later via `-file-exec-and-symbols`.
pub fn start(io: Io, gdb_bin: []const u8, core: ?[]const u8) !void {
    assert(!session.alive);

    // A fresh session must not inherit the previous one's state: a queue
    // left `closed` would report the new session dead on the first tick,
    // and stale pending tokens would misroute responses.
    session.stdout_queue = .{};
    session.stderr_queue = .{};
    session.pending_count = 0;
    session.token_next = 1;

    var argv: [8][]const u8 = undefined;
    var argv_count: u32 = 0;

    argv[argv_count] = gdb_bin;
    argv_count += 1;
    argv[argv_count] = "--interpreter=mi3";
    argv_count += 1;
    argv[argv_count] = "--quiet";
    argv_count += 1;
    if (core) |core_path| {
        argv[argv_count] = "--core";
        argv_count += 1;
        argv[argv_count] = core_path;
        argv_count += 1;
    }

    session.io = io;
    session.process = try std.process.spawn(io, .{
        .argv = argv[0..argv_count],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const child = &session.process.?;
    assert(child.stdin != null);
    assert(child.stdout != null);
    assert(child.stderr != null);

    session.alive = true;

    session.readers[0] = try std.Thread.spawn(
        .{},
        reader_main,
        .{ &session.stdout_queue, io, child.stdout.?.handle },
    );

    session.readers[1] = std.Thread.spawn(
        .{},
        reader_main,
        .{ &session.stderr_queue, io, child.stderr.?.handle },
    ) catch |err| {
        // Unwind the half-started session so nothing is left running.
        session.alive = false;
        session.readers[0].?.join();
        session.readers[0] = null;
        child.kill(io);
        _ = child.wait(io) catch {};
        session.process = null;
        return err;
    };
}

/// True once gdb has closed its output: it exited or crashed.
pub fn output_closed() bool {
    session.stdout_queue.mutex.lockUncancelable(session.io);
    defer session.stdout_queue.mutex.unlock(session.io);
    return session.stdout_queue.closed;
}

/// Wait up to ~10 ms for gdb to produce more output. The GUI loop polls at
/// its own frame rate and never calls this; it exists for tests and for any
/// future consumer that wants to block rather than poll.
pub fn wait_for_output(io: Io) void {
    const queue = &session.stdout_queue;

    queue.mutex.lockUncancelable(io);
    defer queue.mutex.unlock(io);

    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
        .clock = .awake,
    } };
    queue.data_available.waitTimeout(io, &queue.mutex, timeout) catch {};
}

/// Assemble pipe bytes into lines and push them into the queue. Overlong
/// lines are dropped (with one warning each) rather than split, because MI
/// is line-oriented: half a record would poison the parser for no gain.
fn reader_main(queue: *LineQueue, io: Io, read_fd: std.posix.fd_t) void {
    var line: Line = .{};
    var dropped: bool = false;

    read: while (true) {
        var chunk: [4096]u8 = undefined;
        const received = std.posix.read(read_fd, &chunk) catch |err| {
            console.log(.err, "diaguiinspect: reading gdb output failed: {s}", .{@errorName(err)});
            break :read;
        };
        if (received == 0) break :read;

        var index: u32 = 0;
        while (index < received) : (index += 1) {
            const byte = chunk[index];
            if (byte == '\n') {
                if (dropped) {
                    dropped = false;
                    console.log(
                        .warn,
                        "diaguiinspect: dropped an MI line over {d} bytes",
                        .{line_bytes_max},
                    );
                } else {
                    var len = line.len;
                    if (len > 0 and line.bytes[len - 1] == '\r') len -= 1;
                    queue.push(io, line.bytes[0..len]);
                }
                line.len = 0;
            } else {
                if (line.len < line_bytes_max) {
                    line.bytes[line.len] = byte;
                    line.len += 1;
                } else {
                    dropped = true;
                }
            }
        }
    }
    queue.close(io);
}

/// Send one MI command with a token so the response can be matched to its
/// command kind. Formatting failures are reported, never fatal.
pub fn sendf(kind: CommandKind, comptime fmt: []const u8, args: anytype) void {
    if (!session.alive) {
        console.log(.warn, "diaguiinspect: dropping command, gdb is gone: {s}", .{fmt});
        return;
    }

    const token = session.token_next;
    session.token_next +%= 1;

    if (session.pending_count == pending_max) {
        // A response never arrived — most likely its line exceeded the
        // reader's bound and was dropped. Retiring the oldest pending
        // keeps every bound in place; the refresh on the next stop
        // re-queries whatever it lost.
        console.log(.warn, "diaguiinspect: retiring the oldest unanswered gdb command", .{});
        session.pending_count -= 1;
        session.pending_tokens[0] = session.pending_tokens[session.pending_count];
        session.pending_kinds[0] = session.pending_kinds[session.pending_count];
    }
    session.pending_tokens[session.pending_count] = token;
    session.pending_kinds[session.pending_count] = kind;
    session.pending_count += 1;
    assert(session.pending_count <= pending_max);

    // Token, command, newline — the token glues directly to the command with
    // no space, per MI's grammar (a space would make the command undefined).
    // The scratch fits ten token digits plus the longest command diaguiinspect
    // composes, so a NoSpaceLeft here is a bug in some call site's format
    // string, reported rather than tripped over.
    const line = std.fmt.bufPrint(
        &send_scratch,
        "{d}" ++ fmt ++ "\n",
        .{token} ++ args,
    ) catch {
        console.log(.err, "diaguiinspect: command too long: {s}", .{fmt});
        return;
    };
    assert(line.len <= send_scratch.len);

    write_all(line);
}

/// Look up and retire the pending kind for a response token. Unknown tokens
/// happen for late responses to commands issued by gdb itself; not an error.
fn take_kind(token: u32) CommandKind {
    var index: u32 = 0;
    while (index < session.pending_count) : (index += 1) {
        if (session.pending_tokens[index] != token) continue;

        const kind = session.pending_kinds[index];
        session.pending_count -= 1;
        session.pending_tokens[index] = session.pending_tokens[session.pending_count];
        session.pending_kinds[index] = session.pending_kinds[session.pending_count];
        return kind;
    }
    return .none;
}

fn write_all(bytes: []const u8) void {
    assert(session.alive);
    assert(session.process != null);

    // A broken pipe means gdb is gone; that is an operating condition, so
    // report it to the console and mark the session dead.
    session.process.?.stdin.?.writeStreamingAll(session.io, bytes) catch |err| {
        session.alive = false;
        console.log(.err, "diaguiinspect: writing to gdb failed: {s}", .{@errorName(err)});
        return;
    };
}

pub const RecordHandler = *const fn (kind: CommandKind, record: *const mi.Record) void;

/// Drain a bounded batch of gdb output and hand each record to `handler`.
/// stderr lines are plain diagnostics and never parse as MI.
pub fn drain(handler: RecordHandler) u32 {
    var handled: u32 = 0;
    var line: Line = undefined;

    while (handled < lines_per_drain_max) {
        if (!session.stdout_queue.pop(session.io, &line)) break;
        handled += 1;
        handle_line(line.bytes[0..line.len], handler);
    }

    var errors_handled: u32 = 0;
    while (errors_handled < lines_per_drain_max) {
        if (!session.stderr_queue.pop(session.io, &line)) break;
        errors_handled += 1;
        log_stderr_line(line.bytes[0..line.len]);
    }

    return handled;
}

fn handle_line(line_bytes: []const u8, handler: RecordHandler) void {
    var record: mi.Record = undefined;
    mi.parse_record(&session.arena, line_bytes, &record) catch |err| {
        console.log(.warn, "mi: unparseable line ({s}): {s}", .{
            @errorName(err), truncate_for_log(line_bytes),
        });
        return;
    };

    if (record.kind == .unknown) {
        console.log(.warn, "mi: unclassified line: {s}", .{truncate_for_log(line_bytes)});
        return;
    }

    if (record.kind == .result) {
        handler(take_kind(record.token orelse 0), &record);
    } else {
        handler(.none, &record);
    }
}

fn log_stderr_line(line_bytes: []const u8) void {
    if (line_bytes.len == 0) return;

    // gdb relays the inferior's stderr on this pipe, so it carries program
    // output at least as often as gdb's own diagnostics: it belongs in the
    // raw gdb console next to the program's stdout, NOT counted among the
    // GUI's errors.
    app.append_stderr_line(line_bytes);
}

fn truncate_for_log(line_bytes: []const u8) []const u8 {
    return line_bytes[0..@min(line_bytes.len, 120)];
}

/// Shut the session down: ask gdb to exit, wait for it, then join the reader
/// threads so nothing touches the queues after diaguiinspect returns.
pub fn stop(io: Io) void {
    if (session.alive) {
        // `-gdb-exit` needs no token: diaguiinspect is going away and will not match
        // any response for it.
        write_all("-gdb-exit\n");

        // Drain what gdb printed while exiting so it cannot block on a full
        // pipe. The records are not interesting anymore.
        _ = drain(ignore_record);

        if (session.process) |*child| {
            _ = child.wait(io) catch {
                child.kill(io);
                _ = child.wait(io) catch {};
            };
        }
    }
    session.alive = false;

    for (session.readers) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }
    session.readers = .{ null, null };
}

fn ignore_record(kind: CommandKind, record: *const mi.Record) void {
    _ = kind;
    _ = record;
}
