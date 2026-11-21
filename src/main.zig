// diaguiinspect-zig — a gdb GUI in Zig, in the spirit of dzaima's grr.
//
// main() first: read the command line, bring up the gdb session, then the
// GLFW window with the zgui (Dear ImGui) OpenGL3 backend, then run the frame
// loop until the user quits. diaguiinspect keeps control of its own pace: every frame
// drains a bounded batch of gdb output and renders every window, each of
// which carries a console button for checking that the GUI is healthy.

const std = @import("std");
const app = @import("app.zig");
const console = @import("console.zig");
const gdb = @import("gdb.zig");
const windows = @import("windows.zig");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");

const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    const options = parse_args(&arguments) catch {
        print_usage(io);
        return;
    };
    if (options.help) {
        print_usage(io);
        return;
    }

    // rr finds its recordings under $HOME, which only the runtime hands
    // over in a form the app can read later.
    const home = init.environ_map.get("HOME");

    // gdb startup failure is an operating condition: the console holds the
    // specifics, and without a GUI there is nowhere else to show them.
    app.start(io, options.to_start_options(home)) catch {
        report_console_to_stderr(io);
        return;
    };

    // The GUI must come up before any gdb error can be shown in a window,
    // so failures here are reported on stderr straight from the console.
    if (!gui_init(io)) {
        report_console_to_stderr(io);
        shutdown(io);
        return;
    }
    defer gui_deinit();

    windows.apply_mode_visibility();
    console.log(.info, "diaguiinspect: GUI ready", .{});
    run_frame_loop();

    shutdown(io);
}

/// Session teardown: gdb gets its polite `-gdb-exit` in the gdb-backed
/// modes; offline profile files close in every mode.
fn shutdown(io: std.Io) void {
    app.close_offline_profiles();
    switch (app.app.mode) {
        .gdb, .rr, .vgdb => gdb.stop(io),
        .perf, .cachegrind => {},
    }
}

// ---------------------------------------------------------------------------
// Command line.
// ---------------------------------------------------------------------------

const program_args_max: u32 = 16;

const Options = struct {
    help: bool = false,
    gdb_bin: [:0]const u8 = "gdb",
    mode: app.Mode = .gdb,
    core: ?[]const u8 = null,
    program: ?[]const u8 = null,
    program_args: [program_args_max][]const u8 = @splat(&.{}),
    program_args_count: u32 = 0,
    run_at_start: bool = true,
    break_at: ?[]const u8 = null,
    rr_trace: ?[]const u8 = null,
    vgdb_pid: ?[]const u8 = null,
    profile_path: ?[]const u8 = null,

    fn to_start_options(options: *const Options, home: ?[]const u8) app.StartOptions {
        return .{
            .gdb_bin = options.gdb_bin,
            .mode = options.mode,
            .core = options.core,
            .program = options.program,
            .program_args = options.program_args[0..options.program_args_count],
            .run_at_start = options.run_at_start,
            .break_at = options.break_at,
            .rr_trace = options.rr_trace,
            .vgdb_pid = options.vgdb_pid,
            .profile_path = options.profile_path,
            .home = home,
        };
    }
};

/// diaguiinspect-zig some-program [args..]
/// diaguiinspect-zig --no-run some-program
/// diaguiinspect-zig --core path/to/core path/to/program
/// diaguiinspect-zig --rr [trace-dir]
/// diaguiinspect-zig --vgdb [pid] [path/to/program]
/// diaguiinspect-zig --perf path/to/perf.data (or its directory)
/// diaguiinspect-zig --cachegrind cachegrind-out [path/to/program]
/// diaguiinspect-zig --gdb-bin path/to/gdb some-program
/// diaguiinspect-zig --help
fn parse_args(arguments: *std.process.Args.Iterator) !Options {
    var options = Options{};
    var program_given = false;
    var program_args_started = false;

    // An argument consumed for an optional value that turned out to be a
    // flag goes back through here, since the args iterator cannot peek.
    var pending: ?[]const u8 = null;

    // Skip argv[0].
    _ = arguments.next();

    while (true) {
        const argument = pending orelse (arguments.next() orelse break);
        pending = null;

        if (program_args_started) {
            try push_program_arg(&options, argument);
        } else if (std.mem.eql(u8, argument, "--")) {
            program_args_started = true;
        } else if (std.mem.eql(u8, argument, "--help")) {
            options.help = true;
            return options;
        } else if (std.mem.eql(u8, argument, "--no-run")) {
            options.run_at_start = false;
        } else if (std.mem.eql(u8, argument, "--break")) {
            options.break_at = arguments.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, argument, "--core")) {
            options.core = arguments.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, argument, "--gdb-bin")) {
            const binary = arguments.next() orelse return error.Usage;
            options.gdb_bin = binary;
        } else if (std.mem.eql(u8, argument, "--rr")) {
            options.mode = .rr;
            if (arguments.next()) |value| {
                if (std.mem.startsWith(u8, value, "--")) {
                    pending = value;
                } else {
                    options.rr_trace = value;
                }
            }
        } else if (std.mem.eql(u8, argument, "--vgdb")) {
            options.mode = .vgdb;
            if (arguments.next()) |value| {
                if (std.mem.startsWith(u8, value, "--")) {
                    pending = value;
                } else {
                    options.vgdb_pid = value;
                }
            }
        } else if (std.mem.eql(u8, argument, "--perf")) {
            options.mode = .perf;
            options.profile_path = arguments.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, argument, "--cachegrind")) {
            options.mode = .cachegrind;
            options.profile_path = arguments.next() orelse return error.Usage;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.Usage;
        } else if (!program_given) {
            options.program = argument;
            program_given = true;
        } else {
            // A bare argument after the program belongs to the program.
            program_args_started = true;
            try push_program_arg(&options, argument);
        }
    }
    return options;
}

fn push_program_arg(options: *Options, argument: []const u8) !void {
    if (options.program_args_count == program_args_max) return error.Usage;
    options.program_args[options.program_args_count] = argument;
    options.program_args_count += 1;
}

fn print_usage(io: std.Io) void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;

    const usage =
        \\diaguiinspect-zig — a gdb GUI in Zig
        \\
        \\usage:
        \\  diaguiinspect-zig [options] path/to/program [program args..]
        \\
        \\modes:
        \\  (default)        run the program under gdb
        \\  --rr [trace-dir] replay an rr recording (default: latest);
        \\                   reverse execution buttons appear in the Session window
        \\  --vgdb [pid]     connect to a valgrind gdbserver via vgdb; start
        \\                   valgrind with: valgrind --vgdb-error=0 ./program
        \\  --perf FILE      view a perf.data recording (a directory means
        \\                   <dir>/perf.data); hottest samples get symbolized
        \\  --cachegrind FILE
        \\                   view a cachegrind output profile
        \\
        \\options:
        \\  --help            show this help
        \\  --no-run          do not start the program automatically
        \\  --break LOCATION  set a breakpoint before the program runs
        \\  --core FILE       load a core dump (with path/to/program)
        \\  --gdb-bin PATH    gdb binary to use (default: gdb)
        \\
        \\examples:
        \\  diaguiinspect-zig ./some-program
        \\  diaguiinspect-zig --break main ./some-program
        \\  diaguiinspect-zig --no-run ./some-program
        \\  diaguiinspect-zig --rr                          # replay the latest recording
        \\  diaguiinspect-zig --rr ~/.local/share/rr/foo-123
        \\  diaguiinspect-zig --vgdb 4242 ./some-program
        \\  diaguiinspect-zig --perf .
        \\  diaguiinspect-zig --cachegrind cachegrind.out.12345 ./some-program
        \\
    ;
    stdout.writeAll(usage) catch return;
    stdout.flush() catch return;
}

/// Console entries as plain stderr text, for failures before the GUI is up.
fn report_console_to_stderr(io: std.Io) void {
    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;

    var entry: console.Entry = undefined;
    var index: u32 = 0;
    while (console.entry_at(index, &entry)) : (index += 1) {
        const level = switch (entry.level) {
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
        stderr.print("{s}: {s}\n", .{ level, entry.text[0..entry.text_len] }) catch return;
    }
    stderr.flush() catch return;
}

// ---------------------------------------------------------------------------
// GUI setup and the frame loop.
// ---------------------------------------------------------------------------

var glfw_window: ?*zglfw.Window = null;

fn gui_init(io: std.Io) bool {
    _ = io;
    zglfw.init() catch {
        console.log(.err, "diaguiinspect: GLFW init failed — no display?", .{});
        return false;
    };

    const gl_major = 4;
    const gl_minor = 0;
    zglfw.windowHint(.context_version_major, gl_major);
    zglfw.windowHint(.context_version_minor, gl_minor);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.doublebuffer, true);

    const opened = zglfw.createWindow(1600, 900, "diaguiinspect-zig — gdb GUI", null, null) catch {
        console.log(.err, "diaguiinspect: creating the GLFW window failed", .{});
        return false;
    };
    glfw_window = opened;
    zglfw.makeContextCurrent(opened);
    zglfw.swapInterval(1);

    zopengl.loadCoreProfile(zglfw.getProcAddress, gl_major, gl_minor) catch {
        console.log(.err, "diaguiinspect: loading OpenGL 4.0 failed", .{});
        return false;
    };

    // imgui allocates internally per frame; diaguiinspect's own state is fully static
    // (see app.zig), so this allocator exists for the widget library only.
    zgui.init(std.heap.smp_allocator);
    // One saved layout per mode: an offline profile run must never
    // rewrite the debugger's panel arrangement.
    zgui.io.setIniFilename(app.ini_filename(app.app.mode));
    zgui.io.setConfigFlags(.{
        .dock_enable = true,
        .nav_enable_keyboard = true,
    });
    _ = zgui.io.addFontDefault(null);
    zgui.backend.init(opened);

    return true;
}

fn gui_deinit() void {
    zgui.backend.deinit();
    zgui.deinit();
    if (glfw_window) |opened| zglfw.destroyWindow(opened);
    zglfw.terminate();
}

fn run_frame_loop() void {
    const gl = zopengl.bindings;
    const clear_color = [_]f32{ 0.08, 0.09, 0.10, 1.0 };

    while (!glfw_window.?.shouldClose() and !app.app.quit) {
        zglfw.pollEvents();
        gl.clearBufferfv(gl.COLOR, 0, &clear_color);

        // diaguiinspect's own beat: drain gdb at a bounded rate, then render.
        app.tick();

        const fb_size = glfw_window.?.getFramebufferSize();
        assert(fb_size[0] >= 0);
        assert(fb_size[1] >= 0);
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        windows.render_all();

        zgui.backend.draw();
        glfw_window.?.swapBuffers();
    }
}
