// All diaguiinspect windows: the dockspace host, one file per view, and global
// hotkeys. diaguiinspect's key bindings mirror the original:
//
//   F1 run          F2 continue     F3 break
//   F5 stepi        F6 nexti        F7 step        F8 next        F9 finish

const std = @import("std");
const zgui = @import("zgui");
const app = @import("app.zig");
const console = @import("console.zig");
const window = @import("window.zig");

pub const session = @import("windows/session.zig");
pub const source = @import("windows/source.zig");
pub const disassembly = @import("windows/disassembly.zig");
pub const registers = @import("windows/registers.zig");
pub const stack = @import("windows/stack.zig");
pub const breakpoints = @import("windows/breakpoints.zig");
pub const memory = @import("windows/memory.zig");
pub const raw = @import("windows/raw.zig");
pub const perf = @import("windows/perf.zig");
pub const cachegrind = @import("windows/cachegrind.zig");

pub var about_open: bool = false;

/// The dockspace's node id, captured when the host renders it; the default
/// layout builder needs it in the same frame, before any window renders.
var dockspace_id: zgui.Ident = 0;

/// Whether this run has already considered the layout. The default panels
/// are built once per run: on a fresh start, or when the saved layout is
/// still the old floating one, or on an explicit reset.
var layout_built: bool = false;
var force_layout_reset: bool = false;

pub fn render_all() void {
    hotkeys();
    render_host();
    session.render();
    source.render();
    disassembly.render();
    registers.render();
    stack.render();
    breakpoints.render();
    memory.render();
    raw.render();
    perf.render();
    cachegrind.render();
    console.window();
    render_about();
}

/// Which windows make sense depends on the session's mode; offline profile
/// modes hide the debugger views and vice versa. Every analysis window is
/// set in both directions: a window left open in a mode whose layout never
/// docked it would float over the grid.
pub fn apply_mode_visibility() void {
    const offline = app.app.mode == .perf or app.app.mode == .cachegrind;

    session.open = !offline;
    source.open = !offline;
    disassembly.open = !offline;
    registers.open = !offline;
    stack.open = !offline;
    breakpoints.open = !offline;
    memory.open = !offline;
    raw.open = !offline;
    perf.open = app.app.mode == .perf;
    cachegrind.open = app.app.mode == .cachegrind;
}

/// diaguiinspect's key bindings, inactive while a text field has the keyboard.
fn hotkeys() void {
    if (zgui.io.getWantCaptureKeyboard()) return;

    if (zgui.isKeyPressed(.f1, false)) app.run();
    if (zgui.isKeyPressed(.f2, false)) app.continue_execution();
    if (zgui.isKeyPressed(.f3, false)) app.interrupt();
    if (zgui.isKeyPressed(.f5, false)) app.step_instruction();
    if (zgui.isKeyPressed(.f6, false)) app.next_instruction();
    if (zgui.isKeyPressed(.f7, false)) app.step_line();
    if (zgui.isKeyPressed(.f8, false)) app.next_line();
    if (zgui.isKeyPressed(.f9, false)) app.finish_execution();
}

/// The fullscreen host: a menu bar plus the dockspace every diaguiinspect window is
/// a stuck panel of. The host itself never docks or moves; it is chrome,
/// not content.
fn render_host() void {
    const viewport = zgui.getMainViewport();
    const work_pos = viewport.getWorkPos();
    const work_size = viewport.getWorkSize();

    // The host tracks the whole work area every frame, so resizing the
    // window resizes every panel with it.
    zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1], .cond = .always });
    zgui.setNextWindowSize(.{ .w = work_size[0], .h = work_size[1], .cond = .always });
    // window_padding is a two-float style var: both axes to zero.
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    defer zgui.popStyleVar(.{ .count = 1 });

    const flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_bring_to_front_on_focus = true,
        .no_docking = true,
        .menu_bar = true,
    };
    if (!zgui.begin("diaguiinspect host", .{ .flags = flags })) {
        zgui.end();
        return;
    }
    window.log_appearance("diaguiinspect host");

    render_menu_bar();

    // `.no_undocking` is what makes the panels stuck: they rearrange only
    // through the layout builder and resize only through the splitters.
    const host_flags = zgui.DockNodeFlags{ .no_undocking = true };
    dockspace_id = zgui.dockSpace(
        "diaguiinspect_dockspace",
        zgui.getContentRegionAvail(),
        host_flags,
    );
    maybe_build_default_layout();

    zgui.end();
}

fn render_menu_bar() void {
    if (!zgui.beginMenuBar()) return;
    defer zgui.endMenuBar();

    if (zgui.beginMenu("Session", true)) {
        defer zgui.endMenu();
        if (zgui.menuItem("Exit", .{})) app.app.quit = true;
    }

    if (zgui.beginMenu("View", true)) {
        defer zgui.endMenu();
        render_view_menu();
    }

    if (zgui.beginMenu("Help", true)) {
        defer zgui.endMenu();
        if (zgui.menuItem("About diaguiinspect-zig", .{})) about_open = true;
    }

    // The host carries the console button too: one click from anywhere in
    // the chrome opens the diagnostics console.
    zgui.textUnformatted("  ");
    zgui.sameLine(.{});
    console.console_footer("diaguiinspect host");
}

fn render_view_menu() void {
    if (zgui.menuItem("Session", .{ .selected = session.open })) session.open = !session.open;
    if (zgui.menuItem("Source", .{ .selected = source.open })) source.open = !source.open;
    if (zgui.menuItem("Disassembly", .{ .selected = disassembly.open })) {
        disassembly.open = !disassembly.open;
    }
    if (zgui.menuItem("Registers", .{ .selected = registers.open })) {
        registers.open = !registers.open;
    }
    if (zgui.menuItem("Stack", .{ .selected = stack.open })) stack.open = !stack.open;
    if (zgui.menuItem("Breakpoints", .{ .selected = breakpoints.open })) {
        breakpoints.open = !breakpoints.open;
    }
    if (zgui.menuItem("Memory", .{ .selected = memory.open })) memory.open = !memory.open;
    if (zgui.menuItem("Raw gdb", .{ .selected = raw.open })) raw.open = !raw.open;

    zgui.separator();
    if (zgui.menuItem("Console", .{ .selected = console.window_open })) {
        console.window_open = !console.window_open;
    }
    if (zgui.menuItem("Reset layout", .{})) {
        force_layout_reset = true;
    }
}

// ---------------------------------------------------------------------------
// The stuck, responsive default layout.
//
// Panels are docked once — on a fresh start, when the saved layout is still
// the old floating one, or via View → Reset layout — with imgui's
// DockBuilder; after that the saved arrangement wins. `no_undocking` keeps
// every panel inside the dockspace, and the host tracks the viewport, so
// resizing the window redistributes the panels rather than floating them.
// ---------------------------------------------------------------------------

/// Build the default layout this run? Once per run, unless reset.
fn maybe_build_default_layout() void {
    if (force_layout_reset) {
        force_layout_reset = false;
    } else {
        if (layout_built) return;
        if (saved_layout_has_docking()) {
            // The user has a docked arrangement of their own; keep it.
            layout_built = true;
            return;
        }
    }
    layout_built = true;
    build_default_layout();
    console.log(.info, "diaguiinspect: default panel layout applied", .{});
}

/// True when the mode's ini holds docked-panel data for THIS set of
/// window names, i.e. a layout this build already arranged. A missing file,
/// the old floating layout, or a tree saved under previous window names all
/// mean the defaults should take over.
fn saved_layout_has_docking() bool {
    const path = std.mem.sliceTo(app.ini_filename(app.app.mode), 0);
    var buffer: [8192]u8 = undefined;
    const contents = std.Io.Dir.cwd().readFile(app.app.io, path, buffer[0..]) catch {
        return false;
    };
    if (std.mem.indexOf(u8, contents, "[Docking][Data]") == null) return false;

    // The definitive panel of each mode: its presence proves the saved
    // tree matches the current window names.
    const marker: []const u8 = switch (app.app.mode) {
        .gdb, .rr, .vgdb => "[Window][Session]",
        .perf => "[Window][perf]",
        .cachegrind => "[Window][cachegrind]",
    };
    return std.mem.indexOf(u8, contents, marker) != null;
}

fn build_default_layout() void {
    const root = dockspace_id;
    zgui.dockBuilderRemoveNode(root);
    _ = zgui.dockBuilderAddNode(root, .{ .dock_space = true });

    const viewport = zgui.getMainViewport();
    zgui.dockBuilderSetNodeSize(root, viewport.getWorkSize());

    switch (app.app.mode) {
        .gdb, .rr, .vgdb => build_debug_layout(root),
        .perf, .cachegrind => build_profile_layout(root),
    }
    zgui.dockBuilderFinish(root);
}

const SplitResult = struct { at_dir: zgui.Ident, rest: zgui.Ident };

fn split(node: zgui.Ident, direction: zgui.Direction, ratio: f32) SplitResult {
    var result: SplitResult = .{ .at_dir = 0, .rest = 0 };
    _ = zgui.dockBuilderSplitNode(node, direction, ratio, &result.at_dir, &result.rest);
    return result;
}

/// The debugging layout:
///
///   ┌────────────────┬───────────────────┐
///   │ Source         │ Session            │
///   ├────────────────┼───────────────────┤
///   │ Disassembly    │ Registers | Stack │
///   ├────────────────┴───────────────────┤
///   │ Breakpoints | Memory    Raw | Console│
///   └────────────────────────────────────┘
fn build_debug_layout(root: zgui.Ident) void {
    const strip = split(root, .down, 0.25);
    const raw_pane = split(strip.at_dir, .left, 0.6);
    zgui.dockBuilderDockWindow("Raw gdb", raw_pane.at_dir);
    zgui.dockBuilderDockWindow("Console", raw_pane.rest);

    const columns = split(strip.rest, .left, 0.55);
    const left = split(columns.at_dir, .up, 0.55);
    zgui.dockBuilderDockWindow("Source", left.at_dir);
    zgui.dockBuilderDockWindow("Disassembly", left.rest);

    const right = split(columns.rest, .up, 0.24);
    zgui.dockBuilderDockWindow("Session", right.at_dir);

    // Two stacked tab groups keep the right column responsive without
    // nesting splitters: tabs reflow, splitters do not.
    const panels = split(right.rest, .up, 0.5);
    zgui.dockBuilderDockWindow("Registers", panels.at_dir);
    zgui.dockBuilderDockWindow("Stack", panels.at_dir);
    zgui.dockBuilderDockWindow("Breakpoints", panels.rest);
    zgui.dockBuilderDockWindow("Memory", panels.rest);
}

/// The offline profile layout: the analysis front and center, the console
/// along the bottom.
fn build_profile_layout(root: zgui.Ident) void {
    const strip = split(root, .down, 0.25);
    zgui.dockBuilderDockWindow("Console", strip.at_dir);
    if (app.app.mode == .perf) {
        zgui.dockBuilderDockWindow("perf", strip.rest);
    } else {
        zgui.dockBuilderDockWindow("cachegrind", strip.rest);
    }
}

/// The About dialog; its content is a fixed paragraph.
fn render_about() void {
    if (!about_open) return;

    zgui.setNextWindowPos(.{ .x = 560, .y = 300, .cond = .appearing });
    zgui.setNextWindowSize(.{ .w = 480, .h = 200, .cond = .appearing });

    const about_flags = zgui.WindowFlags{ .no_move = true };
    if (!zgui.begin("About diaguiinspect-zig", .{ .popen = &about_open, .flags = about_flags })) {
        zgui.end();
        return;
    }
    window.log_appearance("about");

    zgui.textUnformatted("diaguiinspect-zig — a gdb GUI in Zig, in the spirit of dzaima's grr.");
    zgui.textUnformattedColored(
        window.muted_color,
        "Rendered with Dear ImGui (zgui), following Tiger Style.",
    );
    zgui.textUnformattedColored(
        window.muted_color,
        "The console button in every window opens the diagnostics console.",
    );

    // A dialog does not need its own console button: the host's menu bar
    // carries the single one.
    zgui.end();
}
