// diaguiinspect application state and gdb orchestration.
//
// All state below is statically allocated at startup: fixed-capacity arrays
// with explicit counts, never heap allocations after init. The main loop calls
// `tick` at its own pace; gdb output is drained in bounded batches, so diaguiinspect's
// control flow is never hostage to the external process.

const std = @import("std");
const cachegrind = @import("cachegrind.zig");
const console = @import("console.zig");
const gdb = @import("gdb.zig");
const mi = @import("mi.zig");
const perf = @import("perf.zig");

const assert = std.debug.assert;
const Io = std.Io;

/// Which backend a diaguiinspect session drives. The GUI is identical for the three
/// gdb-backed modes; `perf` and `cachegrind` are offline analyses and never
/// spawn gdb at all.
pub const Mode = enum {
    gdb,
    rr,
    vgdb,
    perf,
    cachegrind,
};

/// Each mode keeps its own saved panel layout in its own ini file, so
/// running an offline profile never rewrites the debugger's arrangement.
pub fn ini_filename(mode: Mode) [*:0]const u8 {
    return switch (mode) {
        .gdb, .rr, .vgdb => "imgui-gdb.ini",
        .perf => "imgui-perf.ini",
        .cachegrind => "imgui-cachegrind.ini",
    };
}

pub const TargetStatus = enum {
    /// gdb is running but no program is loaded yet.
    no_program,
    /// Program symbols are loaded; nothing has run yet.
    ready,
    /// The inferior is running under gdb.
    running,
    /// The inferior is stopped; register/stack queries are valid.
    stopped,
    /// The inferior has run to completion.
    exited,
    /// gdb itself is gone; every command will be dropped.
    dead,
};

/// A fixed-capacity string field: one buffer plus its length. `set` returns
/// whether the value fit in full, so call sites can warn on truncation.
pub fn Text(comptime capacity: u32) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: u16 = 0,

        const Self = @This();
        const capacity_max = capacity;

        pub fn set(self: *Self, source: []const u8) bool {
            const fits = source.len <= capacity;
            const copy_len = @min(source.len, capacity);
            @memcpy(self.bytes[0..copy_len], source[0..copy_len]);
            self.len = @intCast(copy_len);
            return fits;
        }

        pub fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.view(), other);
        }

        pub fn empty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub const registers_max: u32 = 128;
pub const frames_max: u32 = 128;
pub const breakpoints_max: u32 = 128;
pub const threads_max: u32 = 16;
pub const memory_bytes_max: u32 = 256;
pub const source_bytes_max: u32 = 512 * 1024;
pub const source_lines_max: u32 = 16384;
pub const input_bytes_max: u32 = 160;
pub const program_args_max: u32 = 16;
pub const raw_line_bytes_max: u32 = 512;
pub const raw_lines_max: u32 = 512;
pub const history_max: u32 = 32;

pub const Register = struct {
    name: Text(16) = .{},
    value: Text(32) = .{},
    changed: bool = false,
};

pub const Frame = struct {
    level: u32 = 0,
    addr: u64 = 0,
    func: Text(96) = .{},
    file: Text(256) = .{},
    line: u32 = 0,
};

pub const Breakpoint = struct {
    number: u32 = 0,
    address: u64 = 0,
    enabled: bool = false,
    is_watchpoint: bool = false,
    func: Text(96) = .{},
    file: Text(256) = .{},
    location: Text(128) = .{},
    line: u32 = 0,
    hits: u32 = 0,
};

pub const Instruction = struct {
    address: u64 = 0,
    inst: Text(112) = .{},
};

/// One row of the Disassembly panel. In mixed C+asm mode the rows
/// interleave source lines with the instructions that implement them; pure
/// mode stores only instruction rows.
pub const DisasmRow = union(enum) {
    source: SourceRow,
    instruction: InstructionRow,
};

pub const SourceRow = struct {
    line: u32 = 0,
    text: Text(512) = .{},
};

pub const InstructionRow = struct {
    address: u64 = 0,
    text: Text(112) = .{},
};

/// Mixed mode reads the C file the selected frame is in, so its rows need
/// one file (not one per row): the same file for the whole window.
pub const disassembly_rows_max: u32 = 128;
/// Lines of source requested around the current line in mixed mode.
pub const mixed_source_lines: u32 = 20;

pub const Thread = struct {
    id: u32 = 0,
    current: bool = false,
    name: Text(64) = .{},
    state: Text(24) = .{},
};

pub const StopInfo = struct {
    valid: bool = false,
    pc: u64 = 0,
    reason: Text(48) = .{},
    func: Text(96) = .{},
    file: Text(256) = .{},
    line: u32 = 0,
    thread_id: u32 = 1,
    breakpoint_number: u32 = 0,
};

/// Bounded ring of raw gdb console lines. gdb emits stream records with
/// embedded newlines; `append` splits them so one stored line is one
/// displayed line.
pub const RawLog = struct {
    lines: [raw_lines_max][raw_line_bytes_max]u8 = @splat(@splat(0)),
    lens: [raw_lines_max]u16 = @splat(0),
    count: u32 = 0,

    pub fn append(log: *RawLog, text: []const u8) void {
        var line_start: u32 = 0;
        var index: u32 = 0;
        while (index <= text.len) : (index += 1) {
            const at_end = index == text.len;
            if (!at_end and text[index] != '\n') continue;
            if (index > line_start) append_one(log, text[line_start..index]);
            line_start = index + 1;
        }
    }

    fn append_one(log: *RawLog, line: []const u8) void {
        const copy_len: u16 = @intCast(@min(line.len, raw_line_bytes_max));
        const slot = log.count % raw_lines_max;
        @memcpy(log.lines[slot][0..copy_len], line[0..copy_len]);
        log.lens[slot] = copy_len;
        log.count +%= 1;
    }

    pub fn line_count(log: *const RawLog) u32 {
        return @min(log.count, raw_lines_max);
    }

    pub fn line_at(log: *const RawLog, index: u32) []const u8 {
        if (index >= log.line_count()) return "";
        const overall = log.count - log.line_count() + index;
        const slot = overall % raw_lines_max;
        return log.lines[slot][0..log.lens[slot]];
    }

    pub fn append_fmt(log: *RawLog, comptime fmt: []const u8, args: anytype) void {
        var scratch: [raw_line_bytes_max]u8 = undefined;
        const text = std.fmt.bufPrint(&scratch, fmt, args) catch {
            append_one(log, "<diaguiinspect: raw line too long>");
            return;
        };
        append(log, text);
    }
};

pub const App = struct {
    io: Io = undefined,
    quit: bool = false,
    auto_run: bool = false,

    mode: Mode = .gdb,
    /// The rr trace being replayed, for the session window's status line.
    rr_trace: Text(192) = .{},
    /// The vgdb connection argument (pid) as given, for the status line.
    vgdb_pid: Text(32) = .{},

    status: TargetStatus = .no_program,
    program: Text(512) = .{},
    program_args: [program_args_max][]const u8 = @splat(&.{}),
    program_args_count: u32 = 0,
    inferior_pid: u32 = 0,

    stop: StopInfo = .{},
    selected_frame: u32 = 0,

    registers_count: u32 = 0,
    registers: [registers_max]Register = @splat(.{}),

    frames_count: u32 = 0,
    frames: [frames_max]Frame = @splat(.{}),

    breakpoints_count: u32 = 0,
    breakpoints: [breakpoints_max]Breakpoint = @splat(.{}),

    instructions_count: u32 = 0,
    disassembly_rows: [disassembly_rows_max]DisasmRow = @splat(.{ .instruction = .{} }),
    disassembly_rows_count: u32 = 0,
    /// Mixed C+asm mode; off when the binary carries no debug info.
    disassembly_mixed: bool = false,
    /// The one source file mixed rows refer to.
    disassembly_mixed_file: Text(256) = .{},

    threads_count: u32 = 0,
    threads: [threads_max]Thread = @splat(.{}),

    disassembly_pc: u64 = 0,

    memory_valid: bool = false,
    memory_addr: u64 = 0,
    memory_bytes: [memory_bytes_max]u8 = @splat(0),
    memory_input: [32:0]u8 = std.mem.zeroes([32:0]u8),

    source_valid: bool = false,
    source_path: Text(256) = .{},
    source_bytes_len: u32 = 0,
    source_bytes: [source_bytes_max]u8 = @splat(0),
    source_line_offsets: [source_lines_max]u32 = @splat(0),
    source_line_count: u32 = 0,
    source_current_line: u32 = 0,

    raw: RawLog = .{},
    raw_input: [input_bytes_max:0]u8 = std.mem.zeroes([input_bytes_max:0]u8),
    raw_history: [history_max]Text(input_bytes_max) = @splat(.{}),
    raw_history_count: u32 = 0,
    raw_history_cursor: u32 = 0,

    breakpoint_input: [input_bytes_max:0]u8 = std.mem.zeroes([input_bytes_max:0]u8),

    refresh_stop: bool = false,
    refresh_select: bool = false,
    refresh_breakpoints: bool = false,
};

pub var app: App = .{};

pub const StartOptions = struct {
    gdb_bin: [:0]const u8,
    mode: Mode = .gdb,
    core: ?[]const u8 = null,
    program: ?[]const u8 = null,
    program_args: []const []const u8 = &.{},
    run_at_start: bool = true,
    /// A breakpoint location to set before the program runs; the original
    /// The original grr reaches for this through `-d`; diaguiinspect
    /// spells it out.
    break_at: ?[]const u8 = null,
    /// Explicit rr trace directory; empty means "the latest recording".
    rr_trace: ?[]const u8 = null,
    /// vgdb pid argument; empty means "the only valgrind running".
    vgdb_pid: ?[]const u8 = null,
    /// An offline profile file: perf.data path (or its directory) or a
    /// cachegrind output file.
    profile_path: ?[]const u8 = null,
    /// $HOME, for finding ~/.local/share/rr; rr cannot run without it.
    home: ?[]const u8 = null,
};

/// Bring up the session. gdb-backed modes spawn gdb; the offline profile
/// modes (perf, cachegrind) parse their file instead, at a bounded pace.
pub fn start(io: Io, options: StartOptions) !void {
    assert(options.gdb_bin.len > 0);

    // The console's lock needs the Io before any reader thread can log.
    console.set_io(io);
    app.io = io;
    app.mode = options.mode;

    if (options.mode == .perf) {
        perf.start(io, options.profile_path orelse {
            console.log(.err, "diaguiinspect: --perf needs a perf.data path", .{});
            app.status = .dead;
            return;
        });
        return;
    }
    if (options.mode == .cachegrind) {
        cachegrind.start(io, options.profile_path orelse {
            console.log(.err, "diaguiinspect: --cachegrind needs an output file path", .{});
            app.status = .dead;
            return;
        });
        return;
    }

    try start_gdb_mode(io, options);
}

/// Start gdb and connect it per mode: plain, rr replay, or vgdb.
fn start_gdb_mode(io: Io, options: StartOptions) !void {
    app.auto_run = options.mode == .gdb and options.run_at_start and
        options.core == null;

    if (options.program) |path| {
        if (!app.program.set(path)) {
            console.log(.warn, "diaguiinspect: program path truncated", .{});
        }

        const arg_count = @min(options.program_args.len, program_args_max);
        if (options.program_args.len > program_args_max) {
            console.log(
                .warn,
                "diaguiinspect: passing first {d} program args only",
                .{program_args_max},
            );
        }
        for (options.program_args[0..arg_count], 0..) |argument, index| {
            app.program_args[index] = argument;
        }
        app.program_args_count = @intCast(arg_count);
    }

    gdb.start(io, options.gdb_bin, options.core) catch |err| {
        console.log(.err, "diaguiinspect: starting gdb failed: {s}", .{@errorName(err)});
        return err;
    };
    console.log(.info, "diaguiinspect: gdb session started", .{});

    // Asynchronous MI so `-exec-interrupt` can stop a running target; rr
    // also requires it for interrupting a replay. Older gdbs reject this;
    // the logged ^error is harmless.
    gdb.sendf(.none, "-gdb-set mi-async on", .{});

    switch (options.mode) {
        .gdb => start_plain_mode(options),
        .rr => start_rr_mode(options),
        .vgdb => start_vgdb_mode(options),
        .perf, .cachegrind => unreachable,
    }
}

fn start_plain_mode(options: StartOptions) void {
    if (options.program) |path| {
        send_program_load(path);
        send_program_arguments();
        if (options.break_at) |location| {
            // gdb executes commands in order, so the breakpoint is set
            // before the auto-run that follows the file load.
            insert_breakpoint(location);
        }
    } else {
        app.status = .no_program;
        console.log(
            .info,
            "diaguiinspect: no program given — load one from the raw gdb window",
            .{},
        );
    }
}

/// Connect gdb to rr's gdbserver for the given (or latest) recording.
fn start_rr_mode(options: StartOptions) void {
    var trace_path: [512]u8 = undefined;
    const trace = resolve_rr_trace(options, &trace_path) orelse {
        app.status = .dead;
        console.log(.err, "diaguiinspect: no rr recording found under ~/.local/share/rr", .{});
        return;
    };

    if (!app.rr_trace.set(trace)) console.log(.warn, "diaguiinspect: rr trace path truncated", .{});
    console.log(.info, "diaguiinspect: replaying {s}", .{trace});

    // The pipe and its arguments are MI words; `rr serve` stops at the
    // recording's first event, so the target is stopped on connect.
    gdb.sendf(.none, "-target-select remote | rr serve {s}", .{trace});
}

/// vgdb: connect to a valgrind running with --vgdb-error=0.
fn start_vgdb_mode(options: StartOptions) void {
    if (options.program) |path| {
        // The program is not run from here; loading it gives gdb the
        // symbols to resolve frames against the valgrind target.
        send_program_load(path);
    }
    if (options.vgdb_pid) |pid| {
        if (!app.vgdb_pid.set(pid)) console.log(.warn, "diaguiinspect: vgdb pid truncated", .{});
        gdb.sendf(.none, "-target-select remote | vgdb --pid={s}", .{pid});
    } else {
        gdb.sendf(.none, "-target-select remote | vgdb", .{});
    }
    console.log(.info, "diaguiinspect: connecting to valgrind's gdbserver via vgdb", .{});
}

/// The explicit trace if given, else the newest directory under
/// $HOME/.local/share/rr. rr names recordings after the program and pid,
/// so "latest" means newest mtime, as in the original grr.
fn resolve_rr_trace(options: StartOptions, out: []u8) ?[]const u8 {
    if (options.rr_trace) |trace| {
        const len = @min(trace.len, out.len);
        @memcpy(out[0..len], trace[0..len]);
        return out[0..len];
    }

    const home = options.home orelse return null;
    var root_path: [512]u8 = undefined;
    const root = std.fmt.bufPrint(&root_path, "{s}/.local/share/rr", .{home}) catch {
        return null;
    };
    var dir = Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true }) catch {
        return null;
    };
    // The iterator reads from a copy of the handle; close ours after.
    var iterator = dir.iterate();
    defer dir.close(app.io);

    var best_name: [256]u8 = undefined;
    var best_name_len: u32 = 0;
    var best_mtime: i128 = 0;
    while (iterator.next(app.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > best_name.len) continue;

        var entry_path: [512]u8 = undefined;
        const joined = std.fmt.bufPrint(&entry_path, "{s}/{s}", .{
            root, entry.name,
        }) catch continue;
        const stat = Io.Dir.cwd().statFile(app.io, joined, .{}) catch continue;

        if (best_name_len == 0 or stat.mtime.nanoseconds > best_mtime) {
            @memcpy(best_name[0..entry.name.len], entry.name);
            best_name_len = @intCast(entry.name.len);
            best_mtime = stat.mtime.nanoseconds;
        }
    }

    if (best_name_len == 0) return null;
    const joined = std.fmt.bufPrint(out, "{s}/{s}", .{
        root, best_name[0..best_name_len],
    }) catch return null;
    return joined;
}

/// Per-frame tick. gdb-backed modes drain a bounded batch of gdb output and
/// run pending refreshes; the offline profile modes consume a bounded parse
/// budget instead. Either way, diaguiinspect decides when to look at the world.
pub fn tick() void {
    switch (app.mode) {
        .perf => {
            perf.tick_budget(app.io);
            return;
        },
        .cachegrind => {
            cachegrind.tick_budget(app.io);
            return;
        },
        .gdb, .rr, .vgdb => {},
    }

    _ = gdb.drain(handle_record);

    if (gdb.output_closed() and app.status != .dead) {
        app.status = .dead;
        app.stop.valid = false;
        console.log(.err, "diaguiinspect: gdb output closed — session is dead", .{});
    }

    if (app.refresh_stop) {
        app.refresh_stop = false;
        app.selected_frame = 0;
        refresh_state();
    }
    if (app.refresh_select) {
        app.refresh_select = false;
        refresh_state();
    }
    if (app.refresh_breakpoints) {
        app.refresh_breakpoints = false;
        gdb.sendf(.break_list, "-break-list", .{});
    }
}

/// Everything diaguiinspect wants to know about a stopped target, queried in one
/// bounded batch per state change.
fn refresh_state() void {
    gdb.sendf(.list_register_names, "-data-list-register-names", .{});
    gdb.sendf(.list_register_values, "-data-list-register-values x", .{});
    gdb.sendf(.stack_list_frames, "-stack-list-frames", .{});
    gdb.sendf(.threads_info, "-thread-info", .{});
    gdb.sendf(.evaluate_pc, "-data-evaluate-expression $pc", .{});
    gdb.sendf(.break_list, "-break-list", .{});
}

fn send_program_load(path: []const u8) void {
    // The program must exist relative to diaguiinspect's own working directory;
    // catching it here turns gdb's generic "no such file" into something
    // actionable before the session even starts.
    const stat = Io.Dir.cwd().statFile(app.io, path, .{}) catch {
        console.log(.err, "diaguiinspect: program not found: {s}", .{path});
        app.status = .no_program;
        return;
    };
    if (stat.kind == .directory) {
        console.log(.err, "diaguiinspect: program is a directory: {s}", .{path});
        app.status = .no_program;
        return;
    }

    var quoted: [1025]u8 = undefined;
    const text = mi_quote(&quoted, path) orelse {
        console.log(.err, "diaguiinspect: program path too long to quote", .{});
        return;
    };
    gdb.sendf(.file_symbols, "-file-exec-and-symbols {s}", .{text});
}

fn send_program_arguments() void {
    if (app.program_args_count == 0) return;

    var arguments: [1024]u8 = undefined;
    var len: u32 = 0;
    var index: u32 = 0;
    while (index < app.program_args_count) : (index += 1) {
        if (len > 0) {
            arguments[len] = ' ';
            len += 1;
        }
        const argument = app.program_args[index];
        if (len + argument.len > arguments.len) {
            console.log(.warn, "diaguiinspect: program arguments too long, truncated", .{});
            break;
        }
        @memcpy(arguments[len..][0..argument.len], argument);
        len += @intCast(argument.len);
    }
    gdb.sendf(.none, "-exec-arguments {s}", .{arguments[0..len]});
}

/// Quote a string as an MI string literal. Returns null when the quoted form
/// does not fit, which callers report: never truncate a quoted string, since
/// the loss of its closing quote would corrupt the whole command line.
fn mi_quote(target: []u8, source: []const u8) ?[]const u8 {
    var len: u32 = 0;
    target[len] = '"';
    len += 1;

    for (source) |byte| {
        if (byte != '"' and byte != '\\') {
            if (len + 2 > target.len) return null;
        } else {
            if (len + 3 > target.len) return null;
            target[len] = '\\';
            len += 1;
        }
        target[len] = byte;
        len += 1;
    }

    target[len] = '"';
    len += 1;
    return target[0..len];
}

// ---------------------------------------------------------------------------
// Execution control.
// ---------------------------------------------------------------------------

pub fn run() void {
    gdb.sendf(.exec_run, "-exec-run", .{});
}

pub fn continue_execution() void {
    gdb.sendf(.exec_continue, "-exec-continue", .{});
}

pub fn interrupt() void {
    gdb.sendf(.exec_interrupt, "-exec-interrupt", .{});
}

pub fn step_line() void {
    gdb.sendf(.exec_step, "-exec-step", .{});
}

pub fn next_line() void {
    gdb.sendf(.exec_next, "-exec-next", .{});
}

pub fn step_instruction() void {
    gdb.sendf(.exec_step_instruction, "-exec-step-instruction", .{});
}

pub fn next_instruction() void {
    gdb.sendf(.exec_next_instruction, "-exec-next-instruction", .{});
}

pub fn finish_execution() void {
    gdb.sendf(.exec_finish, "-exec-finish", .{});
}

/// rr reverse execution: the recording can run backwards, so the session
/// window offers these wherever the forward ones appear.
pub fn reverse_continue() void {
    gdb.sendf(.exec_continue, "-exec-continue --reverse", .{});
}

pub fn reverse_step_line() void {
    gdb.sendf(.exec_step, "-exec-step --reverse", .{});
}

pub fn reverse_next_line() void {
    gdb.sendf(.exec_next, "-exec-next --reverse", .{});
}

pub fn reverse_step_instruction() void {
    gdb.sendf(.exec_step_instruction, "-exec-step-instruction --reverse", .{});
}

pub fn reverse_finish_execution() void {
    gdb.sendf(.exec_finish, "-exec-finish --reverse", .{});
}

/// Close offline profile files at shutdown.
pub fn close_offline_profiles() void {
    perf.close_all(app.io);
    cachegrind.close_all(app.io);
}

pub fn kill_inferior() void {
    gdb.sendf(.exec_abort, "-exec-abort", .{});
}

pub fn select_frame(level: u32) void {
    if (level >= app.frames_count) return;
    app.selected_frame = level;
    gdb.sendf(.stack_select_frame, "-stack-select-frame {d}", .{level});
}

pub fn select_thread(thread_id: u32) void {
    gdb.sendf(.thread_select, "-thread-select {d}", .{thread_id});
}

/// The inferior's stderr (and gdb's own diagnostics) arrive here; diaguiinspect
/// shows them in the raw gdb console like any other program output. The
/// health badge on the menu-bar console button must stay a measure of
/// GUI failures, not of the debugged program's complaints.
pub fn append_stderr_line(line: []const u8) void {
    app.raw.append(line);
}

/// Manual refresh for the registers window's button.
pub fn refresh_registers() void {
    gdb.sendf(.list_register_names, "-data-list-register-names", .{});
    gdb.sendf(.list_register_values, "-data-list-register-values x", .{});
}

// ---------------------------------------------------------------------------
// Breakpoints and memory.
// ---------------------------------------------------------------------------

pub fn insert_breakpoint(location: []const u8) void {
    if (location.len == 0) {
        console.log(.warn, "diaguiinspect: breakpoint location is empty", .{});
        return;
    }

    var escaped: [input_bytes_max * 2 + 4]u8 = undefined;
    const text = mi_quote(&escaped, location) orelse {
        console.log(.err, "diaguiinspect: breakpoint location too long", .{});
        return;
    };
    gdb.sendf(.break_insert, "-break-insert {s}", .{text});
}

pub fn delete_breakpoint(number: u32) void {
    gdb.sendf(.break_delete, "-break-delete {d}", .{number});
}

/// Enable or disable a breakpoint by gdb number, from the table's checkbox.
pub fn set_breakpoint_enabled(breakpoint: *Breakpoint, enabled: bool) void {
    if (enabled) {
        gdb.sendf(.break_set_enabled, "-break-enable {d}", .{breakpoint.number});
    } else {
        gdb.sendf(.break_set_enabled, "-break-disable {d}", .{breakpoint.number});
    }
}

/// Toggle a breakpoint on a source line: delete an existing one, else insert.
pub fn toggle_breakpoint_at_line(file: []const u8, line: u32) void {
    for (app.breakpoints[0..app.breakpoints_count]) |*breakpoint| {
        if (breakpoint.is_watchpoint) continue;
        if (breakpoint.line != line) continue;
        if (!breakpoint.file.eql(file)) continue;

        delete_breakpoint(breakpoint.number);
        return;
    }

    var location: [384]u8 = undefined;
    const text = std.fmt.bufPrint(&location, "{s}:{d}", .{ file, line }) catch return;
    insert_breakpoint(text);
}

/// Toggle a breakpoint at an instruction address: delete an existing one,
/// else insert at `*address`.
pub fn toggle_breakpoint_at_address(address: u64) void {
    for (app.breakpoints[0..app.breakpoints_count]) |*breakpoint| {
        if (breakpoint.is_watchpoint) continue;
        if (breakpoint.address != address) continue;

        delete_breakpoint(breakpoint.number);
        return;
    }
    gdb.sendf(.break_insert, "-break-insert *0x{x}", .{address});
}

pub fn read_memory(address: u64) void {
    gdb.sendf(.read_memory, "-data-read-memory-bytes 0x{x} {d}", .{
        address, memory_bytes_max,
    });
}

/// Run a console command through MI so it cannot desynchronize the parser.
pub fn send_raw_console(command: []const u8) void {
    if (command.len == 0) return;

    var escaped: [input_bytes_max * 2 + 4]u8 = undefined;
    const text = mi_quote(&escaped, command) orelse {
        console.log(.err, "diaguiinspect: command too long", .{});
        return;
    };
    gdb.sendf(.none, "-interpreter-exec console {s}", .{text});
    app.raw.append_fmt("> {s}", .{command});
}

/// The Disassembly panel's query: pure mode takes an address window
/// around `pc`; mixed C+asm mode takes the selected frame's file and line
/// and asks for source-centric rows instead.
pub fn request_disassembly(pc: u64) void {
    if (app.disassembly_mixed) {
        if (request_mixed_disassembly()) return;

        // No frame with file/line info: the binary has no debug info, and
        // the honest fallback is the address window.
        console.log(
            .warn,
            "diaguiinspect: no debug info for mixed view — showing pure asm",
            .{},
        );
        app.disassembly_mixed = false;
    }

    const range_start = pc -| 16;
    const range_end = pc +| 240;
    gdb.sendf(.disassemble, "-data-disassemble -s 0x{x} -e 0x{x} 0", .{ range_start, range_end });
}

/// True when the mixed query was sent; false when the frame has no source
/// location to anchor it.
fn request_mixed_disassembly() bool {
    const frame = current_frame() orelse return false;
    if (frame.file.empty()) return false;
    if (frame.line == 0) return false;

    _ = app.disassembly_mixed_file.set(frame.file.view());
    var quoted: [576]u8 = undefined;
    const file_text = mi_quote(&quoted, frame.file.view()) orelse {
        console.log(.err, "diaguiinspect: source path too long to quote", .{});
        return false;
    };
    gdb.sendf(
        .disassemble,
        "-data-disassemble -f {s} -l {d} -n {d} 2",
        .{ file_text, frame.line, mixed_source_lines },
    );
    return true;
}

/// The frame the views follow: the selected one, or the top of the stack.
fn current_frame() ?*Frame {
    if (app.frames_count == 0) return null;
    const level = @min(app.selected_frame, app.frames_count - 1);
    return &app.frames[level];
}

/// The panel's mode toggle: re-queries immediately so the switch is
/// visible without waiting for the next stop.
pub fn set_disassembly_mixed(enabled: bool) void {
    if (app.disassembly_mixed == enabled) return;
    app.disassembly_mixed = enabled;
    request_disassembly(app.disassembly_pc);
}

// ---------------------------------------------------------------------------
// Record handling.
// ---------------------------------------------------------------------------

fn handle_record(kind: gdb.CommandKind, record: *const mi.Record) void {
    switch (record.kind) {
        .prompt => {},
        .console_stream => app.raw.append(record.text),
        .target_stream => app.raw.append(record.text),
        .log_stream => app.raw.append(record.text),
        .result => handle_result(kind, record),
        .exec_async => handle_exec_async(record),
        .notify_async => handle_notify_async(record),
        // gdb.zig logs and drops unclassified lines before reaching here.
        .unknown => {},
    }
}

fn handle_result(kind: gdb.CommandKind, record: *const mi.Record) void {
    if (std.mem.eql(u8, record.class, "error")) {
        handle_error(kind, record.results);
        return;
    }
    if (std.mem.eql(u8, record.class, "exit")) {
        app.status = .dead;
        console.log(.info, "diaguiinspect: gdb exited", .{});
        return;
    }
    if (std.mem.eql(u8, record.class, "connected")) {
        // rr and vgdb attach with the target stopped at the recording's
        // first event / valgrind's break, so every view is already valid.
        app.status = .stopped;
        app.stop.valid = true;
        app.refresh_stop = true;
        console.log(.info, "diaguiinspect: target connected", .{});
        return;
    }
    if (std.mem.eql(u8, record.class, "running")) {
        app.status = .running;
        app.stop.valid = false;
        return;
    }
    if (std.mem.eql(u8, record.class, "done")) {
        handle_done(kind, record.results);
        return;
    }
    // Nothing else is interesting to the user yet.
}

fn handle_error(kind: gdb.CommandKind, results: ?mi.Value) void {
    const name = command_name(kind);
    const message = if (results) |payload| mi.find_string(payload, "msg") orelse "" else "";

    if (message.len > 0) {
        console.log(.err, "gdb {s}: {s}", .{ name, message });
        app.raw.append_fmt("> error: {s}", .{message});
    } else {
        console.log(.err, "gdb {s} failed", .{name});
    }
}

fn command_name(kind: gdb.CommandKind) []const u8 {
    return switch (kind) {
        .none => "response",
        .file_symbols => "-file-exec-and-symbols",
        .exec_run => "-exec-run",
        .exec_continue => "-exec-continue",
        .exec_step => "-exec-step",
        .exec_next => "-exec-next",
        .exec_step_instruction => "-exec-step-instruction",
        .exec_next_instruction => "-exec-next-instruction",
        .exec_finish => "-exec-finish",
        .exec_interrupt => "-exec-interrupt",
        .exec_abort => "-exec-abort",
        .stack_select_frame => "-stack-select-frame",
        .thread_select => "-thread-select",
        .break_insert => "-break-insert",
        .break_set_enabled => "-break-enable/-break-disable",
        .break_delete => "-break-delete",
        .break_list => "-break-list",
        .list_register_names => "-data-list-register-names",
        .list_register_values => "-data-list-register-values",
        .stack_list_frames => "-stack-list-frames",
        .threads_info => "-thread-info",
        .evaluate_pc => "-data-evaluate-expression",
        .disassemble => "-data-disassemble",
        .read_memory => "-data-read-memory-bytes",
    };
}

fn handle_done(kind: gdb.CommandKind, results: ?mi.Value) void {
    switch (kind) {
        .none => {},
        .file_symbols => on_program_loaded(),
        .stack_select_frame, .thread_select => app.refresh_select = true,
        .break_insert, .break_set_enabled, .break_delete => app.refresh_breakpoints = true,
        .exec_run,
        .exec_continue,
        .exec_step,
        .exec_next,
        .exec_step_instruction,
        .exec_next_instruction,
        .exec_finish,
        .exec_interrupt,
        .exec_abort,
        => {},
        .list_register_names => if (results) |payload| update_register_names(payload),
        .list_register_values => if (results) |payload| update_register_values(payload),
        .stack_list_frames => if (results) |payload| update_frames(payload),
        .threads_info => if (results) |payload| update_threads(payload),
        .evaluate_pc => if (results) |payload| update_pc(payload),
        .disassemble => if (results) |payload| update_disassembly(payload),
        .read_memory => if (results) |payload| update_memory(payload),
        .break_list => if (results) |payload| update_breakpoints(payload),
    }
}

fn on_program_loaded() void {
    app.status = .ready;
    app.refresh_breakpoints = true;
    console.log(.info, "diaguiinspect: {s} loaded", .{app.program.view()});

    if (app.auto_run) {
        app.auto_run = false;
        run();
    }
}

fn handle_exec_async(record: *const mi.Record) void {
    if (!std.mem.eql(u8, record.class, "stopped")) return;

    const results = record.results orelse {
        // A bare *stopped still means "the target stopped": refresh.
        app.status = .stopped;
        app.refresh_stop = true;
        return;
    };

    const reason = mi.find_string(results, "reason") orelse "";
    if (std.mem.startsWith(u8, reason, "exited")) {
        on_exited(results, reason);
        return;
    }

    app.status = .stopped;
    app.stop.valid = true;
    _ = app.stop.reason.set(reason);
    app.stop.breakpoint_number = @intCast(mi.find_int(results, "bkptno") orelse 0);
    if (mi.find_int(results, "thread-id")) |thread_id| {
        app.stop.thread_id = @intCast(thread_id);
    }
    if (mi.find(results, "frame")) |frame| update_stop_frame(frame);

    console.log(.info, "diaguiinspect: stopped — {s}", .{
        if (reason.len > 0) reason else app.stop.func.view(),
    });
    app.refresh_stop = true;
}

fn update_stop_frame(frame: mi.Value) void {
    app.stop.pc = mi.find_int(frame, "addr") orelse app.stop.pc;
    app.disassembly_pc = app.stop.pc;
    _ = app.stop.func.set(mi.find_string(frame, "func") orelse "??");

    const file = mi.find_string(frame, "fullname") orelse mi.find_string(frame, "file") orelse "";
    _ = app.stop.file.set(file);
    app.stop.line = @intCast(mi.find_int(frame, "line") orelse 0);

    if (file.len > 0) load_source(file, app.stop.line);
}

fn on_exited(results: mi.Value, reason: []const u8) void {
    app.status = .exited;
    app.stop.valid = false;

    // Views of the departed inferior would only mislead.
    app.registers_count = 0;
    app.frames_count = 0;
    app.disassembly_rows_count = 0;
    app.instructions_count = 0;
    app.threads_count = 0;

    if (mi.find_int(results, "exit-code")) |exit_code| {
        console.log(.info, "diaguiinspect: program {s} with code {d}", .{ reason, exit_code });
    } else {
        console.log(.info, "diaguiinspect: program {s}", .{reason});
    }
}

fn handle_notify_async(record: *const mi.Record) void {
    // Breakpoint state can change behind our back (a `break` typed into the
    // raw window), so any breakpoint notification triggers a refresh.
    if (std.mem.startsWith(u8, record.class, "breakpoint-")) {
        app.refresh_breakpoints = true;
    }
    if (std.mem.eql(u8, record.class, "thread-group-started")) {
        if (record.results) |payload| {
            app.inferior_pid = @intCast(mi.find_int(payload, "pid") orelse 0);
        }
    }
}

// ---------------------------------------------------------------------------
// View data updates. Each takes one parsed MI payload and copies it into the
// bounded app state; oversized responses are truncated with a warning rather
// than dropped, because partial data still beats no data.
// ---------------------------------------------------------------------------

fn update_register_names(results: mi.Value) void {
    const list = mi.find(results, "register-names") orelse return;
    if (list != .values) return;

    const count = @min(list.values.len, registers_max);
    if (list.values.len > registers_max) {
        console.log(.warn, "diaguiinspect: showing first {d} of {d} registers", .{
            registers_max, list.values.len,
        });
    }

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (list.values[index] != .string) continue;
        if (!app.registers[index].name.set(list.values[index].string)) {
            console.log(
                .warn,
                "diaguiinspect: register name truncated: {s}",
                .{list.values[index].string},
            );
        }
    }
    if (app.registers_count < count) app.registers_count = @intCast(count);
}

fn update_register_values(results: mi.Value) void {
    const list = mi.find(results, "register-values") orelse return;
    if (list != .values) return;

    for (list.values) |element| {
        const number = mi.find_int(element, "number") orelse continue;
        const value = mi.find_string(element, "value") orelse continue;
        if (number >= registers_max) continue;

        const register = &app.registers[number];
        // The first fetch has nothing to compare against; mark nothing
        // changed so the first stop does not paint every value orange.
        register.changed = !register.value.empty() and !register.value.eql(value);
        _ = register.value.set(value);
    }
}

/// gdb reports `fullname` when debug info knows it, else the bare `file`.
fn find_file_path(info: mi.Value) []const u8 {
    return mi.find_string(info, "fullname") orelse mi.find_string(info, "file") orelse "";
}

fn update_frames(results: mi.Value) void {
    const stack = mi.find(results, "stack") orelse return;
    // gdb wraps each frame as `frame={...}`, so the list arrives as named
    // results; tolerate bare frame tuples from other gdb versions.
    const count = switch (stack) {
        .results => @min(stack.results.len, frames_max),
        .values => @min(stack.values.len, frames_max),
        .string => return,
    };
    switch (stack) {
        .results => warn_frames(stack.results.len),
        .values => warn_frames(stack.values.len),
        .string => return,
    }

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const info = switch (stack) {
            // In the results form, the entry's value IS the frame tuple.
            .results => stack.results[index].value,
            // In the bare form, each element may still wrap in "frame=".
            .values => mi.find(stack.values[index], "frame") orelse stack.values[index],
            .string => return,
        };
        const frame = &app.frames[index];

        frame.level = @intCast(mi.find_int(info, "level") orelse index);
        frame.addr = mi.find_int(info, "addr") orelse 0;
        _ = frame.func.set(mi.find_string(info, "func") orelse "??");
        _ = frame.file.set(find_file_path(info));
        frame.line = @intCast(mi.find_int(info, "line") orelse 0);
    }
    app.frames_count = @intCast(count);

    if (count > 0) follow_source();
}

fn warn_frames(total: usize) void {
    if (total <= frames_max) return;
    console.log(.warn, "diaguiinspect: showing first {d} of {d} frames", .{ frames_max, total });
}

/// The source window follows the selected frame's file and line.
fn follow_source() void {
    if (app.selected_frame >= app.frames_count) return;

    const frame = &app.frames[app.selected_frame];
    if (frame.file.empty()) return;
    load_source(frame.file.view(), frame.line);
}

fn update_threads(results: mi.Value) void {
    const list = mi.find(results, "threads") orelse return;
    if (list != .values) return;

    const count = @min(list.values.len, threads_max);
    if (list.values.len > threads_max) {
        console.log(.warn, "diaguiinspect: showing first {d} of {d} threads", .{
            threads_max, list.values.len,
        });
    }

    // gdb 15 reports the current thread at the top level; older versions
    // mark it inside the entry. Support both, top level first.
    const current_id = mi.find_int(results, "current-thread-id");

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const element = list.values[index];
        const thread = &app.threads[index];

        thread.id = @intCast(mi.find_int(element, "id") orelse index + 1);
        thread.current = false;
        if (current_id) |id| {
            thread.current = thread.id == id;
        }
        if (mi.find_string(element, "current-thread-id") != null) {
            thread.current = true;
        }
        const thread_name = mi.find_string(element, "name") orelse
            mi.find_string(element, "target-id") orelse "";
        _ = thread.name.set(thread_name);
        _ = thread.state.set(mi.find_string(element, "state") orelse "");
    }
    app.threads_count = @intCast(count);
}

fn update_pc(results: mi.Value) void {
    const value = mi.find_string(results, "value") orelse return;
    // gdb prints $pc with a "<symbol>" suffix when symbols are known; the
    // address is the part before the first space.
    const space = std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
    const pc = mi.parse_int(value[0..space]) orelse return;

    app.disassembly_pc = pc;
    request_disassembly(pc);
}

fn update_disassembly(results: mi.Value) void {
    const asm_insns = mi.find(results, "asm_insns") orelse return;
    if (asm_insns != .values) return;

    app.disassembly_rows_count = 0;
    app.instructions_count = 0;
    for (asm_insns.values) |element| {
        // Mode 0 lists instructions directly; mode 2 wraps them per source
        // line in `src_and_asm_line` entries with an `insts` list.
        if (mi.find(element, "insts")) |wrapped| {
            add_source_row(element);
            if (wrapped != .values) continue;
            for (wrapped.values) |instruction| {
                if (!add_instruction_row(instruction)) break;
            }
        } else {
            _ = add_instruction_row(element);
        }
        if (app.disassembly_rows_count == disassembly_rows_max) {
            console.log(
                .warn,
                "diaguiinspect: showing first {d} rows",
                .{disassembly_rows_max},
            );
            break;
        }
    }
    if (app.disassembly_rows_count == 0) {
        console.log(.warn, "diaguiinspect: no disassembly returned for the requested range", .{});
    }
}

/// One source line of the mixed view: stored before its instructions so
/// the panel reads top-down like the file itself.
fn add_source_row(element: mi.Value) void {
    if (app.disassembly_rows_count == disassembly_rows_max) return;

    const line = mi.find_int(element, "line") orelse return;
    const contents = mi.find_string(element, "line_contents") orelse "";
    _ = app.disassembly_mixed_file.set(mi.find_string(element, "file") orelse
        app.disassembly_mixed_file.view());

    const slot = &app.disassembly_rows[app.disassembly_rows_count];
    slot.* = .{ .source = .{ .line = @intCast(line) } };
    if (!slot.source.text.set(contents)) {
        console.log(.warn, "diaguiinspect: source line truncated", .{});
    }
    app.disassembly_rows_count += 1;
}

/// One instruction row (both modes). Returns false when the table is
/// full, so callers can stop feeding it without overflowing.
fn add_instruction_row(instruction: mi.Value) bool {
    if (app.disassembly_rows_count == disassembly_rows_max) return false;

    const address = mi.find_int(instruction, "address") orelse return true;
    const text = mi.find_string(instruction, "inst") orelse return true;
    if (text.len == 0) return true;

    const slot = &app.disassembly_rows[app.disassembly_rows_count];
    slot.* = .{ .instruction = .{ .address = address } };
    if (!slot.instruction.text.set(text)) {
        console.log(.warn, "diaguiinspect: instruction text truncated", .{});
    }
    app.disassembly_rows_count += 1;
    app.instructions_count += 1;
    assert(app.disassembly_rows_count <= disassembly_rows_max);
    return true;
}

fn update_memory(results: mi.Value) void {
    const memory = mi.find(results, "memory") orelse return;
    if (memory != .values) return;
    if (memory.values.len == 0) return;

    // diaguiinspect requests exactly one contiguous range.
    const range = memory.values[0];
    app.memory_addr = mi.find_int(range, "begin") orelse app.memory_addr;
    const contents = mi.find_string(range, "contents") orelse return;

    var decoded: u32 = 0;
    var index: u32 = 0;
    while (index + 1 < contents.len) : (index += 2) {
        if (decoded == memory_bytes_max) {
            console.log(
                .warn,
                "diaguiinspect: memory view truncated at {d} bytes",
                .{memory_bytes_max},
            );
            break;
        }
        const high = hex_value(contents[index]) orelse break;
        const low = hex_value(contents[index + 1]) orelse break;
        app.memory_bytes[decoded] = high * 16 + low;
        decoded += 1;
    }
    app.memory_valid = decoded > 0;
}

fn hex_value(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn update_breakpoints(results: mi.Value) void {
    const table = mi.find(results, "BreakpointTable") orelse return;
    const body = mi.find(table, "body") orelse return;
    // gdb names every body row after its kind (`bkpt`, `wpt`, ...), so the
    // rows arrive as results, not a bare value list.
    if (body != .results) return;

    const count = @min(body.results.len, breakpoints_max);
    if (body.results.len > breakpoints_max) {
        console.log(.warn, "diaguiinspect: showing first {d} of {d} breakpoints", .{
            breakpoints_max, body.results.len,
        });
    }

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const breakpoint = &app.breakpoints[index];
        if (!store_breakpoint(breakpoint, body.results[index].value)) continue;
    }
    app.breakpoints_count = @intCast(count);
}

/// Copy one `bkpt`/`wpt` tuple into its window slot. Returns false for rows
/// without a number, which gdb never emits but diaguiinspect tolerates.
fn store_breakpoint(breakpoint: *Breakpoint, info: mi.Value) bool {
    breakpoint.number = @intCast(mi.find_int(info, "number") orelse 0);
    if (breakpoint.number == 0) return false;

    breakpoint.enabled = std.mem.eql(u8, mi.find_string(info, "enabled") orelse "", "y");
    const kind = mi.find_string(info, "type") orelse "";
    breakpoint.is_watchpoint = std.mem.indexOf(u8, kind, "watchpoint") != null;
    breakpoint.address = mi.find_int(info, "addr") orelse 0;
    _ = breakpoint.func.set(mi.find_string(info, "func") orelse "");
    _ = breakpoint.file.set(find_file_path(info));
    breakpoint.line = @intCast(mi.find_int(info, "line") orelse 0);
    const location = mi.find_string(info, "what") orelse
        mi.find_string(info, "original-location") orelse "";
    _ = breakpoint.location.set(location);
    breakpoint.hits = @intCast(mi.find_int(info, "times") orelse 0);
    return true;
}

/// Breakpoint table rows are keyed by breakpoint kind: `bkpt` for
/// breakpoints, `wpt`/`hw-*pt` for watchpoints.
// ---------------------------------------------------------------------------
// Source view.
// ---------------------------------------------------------------------------

/// Load `path` as the current source file and center the view on `line`.
/// Reloading happens only when the path changes; switching frames within one
/// file is a cheap cursor update.
pub fn load_source(path: []const u8, current_line: u32) void {
    app.source_current_line = current_line;
    if (app.source_valid and app.source_path.eql(path)) return;

    app.source_valid = false;
    _ = app.source_path.set(path);
    app.source_bytes_len = 0;
    app.source_line_count = 0;

    const bytes = Io.Dir.cwd().readFile(app.io, path, &app.source_bytes) catch |err| {
        console.log(.warn, "diaguiinspect: reading {s} failed: {s}", .{ path, @errorName(err) });
        return;
    };
    if (bytes.len == source_bytes_max) {
        console.log(
            .warn,
            "diaguiinspect: {s} truncated at {d} bytes",
            .{ path, source_bytes_max },
        );
    }

    app.source_bytes_len = @intCast(bytes.len);
    index_source_lines();
    app.source_valid = true;
}

fn index_source_lines() void {
    assert(app.source_line_count == 0);
    app.source_line_offsets[0] = 0;
    app.source_line_count = 1;

    const bytes = app.source_bytes[0..app.source_bytes_len];
    var index: u32 = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != '\n') continue;
        if (app.source_line_count == source_lines_max) {
            console.log(.warn, "diaguiinspect: {s} truncated at {d} lines", .{
                app.source_path.view(), source_lines_max,
            });
            return;
        }
        app.source_line_offsets[app.source_line_count] = index + 1;
        app.source_line_count += 1;
    }
}

/// Text of source line `line_index` (0-based), without its line terminator.
pub fn source_line_text(line_index: u32) []const u8 {
    if (line_index >= app.source_line_count) return "";

    const line_start = app.source_line_offsets[line_index];
    const line_end = if (line_index + 1 < app.source_line_count)
        app.source_line_offsets[line_index + 1]
    else
        app.source_bytes_len;
    if (line_start > line_end) return "";

    var text = app.source_bytes[line_start..line_end];
    if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
    return text;
}

/// True when a breakpoint sits on `line_index` (0-based) of the shown file,
/// for the source window's margin markers.
pub fn breakpoint_at_line(line_index: u32) bool {
    const line = line_index + 1;

    for (app.breakpoints[0..app.breakpoints_count]) |*breakpoint| {
        if (breakpoint.is_watchpoint) continue;
        if (breakpoint.line != line) continue;
        if (!breakpoint.file.eql(app.source_path.view())) continue;
        return true;
    }
    return false;
}

/// The breakpoint at an instruction address, for the disassembly window's
/// markers; watchpoints have no single address and never match.
pub fn breakpoint_at_address(address: u64) ?*Breakpoint {
    for (app.breakpoints[0..app.breakpoints_count]) |*breakpoint| {
        if (breakpoint.is_watchpoint) continue;
        if (breakpoint.address != address) continue;
        return breakpoint;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Raw gdb window history.
// ---------------------------------------------------------------------------

pub fn raw_history_append(command: []const u8) void {
    if (command.len == 0) return;
    _ = app.raw_history[app.raw_history_count % history_max].set(command);
    app.raw_history_count +%= 1;
    app.raw_history_cursor = app.raw_history_count;
}

/// Walk history with Up/Down: -1 for older, +1 for newer. Returns null when
/// the walk has run out of entries, leaving the cursor untouched.
pub fn raw_history_walk(direction: i32) ?[]const u8 {
    if (app.raw_history_count == 0) return null;

    if (direction < 0) {
        if (app.raw_history_cursor == 0) return null;
        app.raw_history_cursor -= 1;
    } else {
        if (app.raw_history_cursor >= app.raw_history_count) return null;
        app.raw_history_cursor += 1;
        if (app.raw_history_cursor == app.raw_history_count) return null;
    }

    const entry = &app.raw_history[app.raw_history_cursor % history_max];
    return entry.view();
}

test "raw log splits embedded newlines and wraps" {
    var log: RawLog = .{};
    log.append("one\ntwo\nthree");
    try std.testing.expectEqual(@as(u32, 3), log.line_count());
    try std.testing.expectEqualStrings("one", log.line_at(0));
    try std.testing.expectEqualStrings("three", log.line_at(2));

    var index: u32 = 0;
    while (index < raw_lines_max + 5) : (index += 1) {
        log.append_fmt("line {d}", .{index});
    }
    // 3 + (raw_lines_max + 5) lines were appended; the ring keeps the newest
    // raw_lines_max of them, so the oldest survivor is "line 5" and the
    // newest is "line 516".
    try std.testing.expectEqual(raw_lines_max, log.line_count());
    try std.testing.expectEqualStrings("line 5", log.line_at(0));
    try std.testing.expectEqualStrings("line 516", log.line_at(raw_lines_max - 1));
}

test "source line indexing and lookup" {
    app.source_bytes_len = 0;
    app.source_line_count = 0;
    const contents = "alpha\nbeta\n";
    @memcpy(app.source_bytes[0..contents.len], contents);
    app.source_bytes_len = @intCast(contents.len);
    index_source_lines();

    try std.testing.expectEqual(@as(u32, 3), app.source_line_count);
    try std.testing.expectEqualStrings("alpha", source_line_text(0));
    try std.testing.expectEqualStrings("beta", source_line_text(1));
    try std.testing.expectEqualStrings("", source_line_text(2));
    try std.testing.expectEqualStrings("", source_line_text(3));
}
