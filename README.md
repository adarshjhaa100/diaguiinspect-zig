# diaguiinspect-zig

A gdb GUI in Zig, in the spirit of [dzaima/grr](https://github.com/dzaima/grr),
rendered with [Dear ImGui](https://github.com/ocornut/imgui) through
[zgui](https://github.com/zig-gamedev/zgui) (GLFW + OpenGL 3 windowing), and
written to follow [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

~~~
diaguiinspect-zig ./some-program          # run program in gdb
diaguiinspect-zig --no-run ./some-program # load, but wait for F1
diaguiinspect-zig --core ./core ./some-program
diaguiinspect-zig --gdb-bin /path/to/gdb ./some-program

diaguiinspect-zig --rr            # replay the latest rr recording
diaguiinspect-zig --rr ~/.local/share/rr/foo-123
diaguiinspect-zig --vgdb [pid] ./some-program # attach via vgdb
diaguiinspect-zig --perf .        # view ./perf.data (a dir means <dir>/perf.data)
diaguiinspect-zig --cachegrind cachegrind.out.12345
~~~

Requires `zig` ≥ 0.17.0. Build with `zig build`, run with
`zig build run -- [args]`, test with `zig build test` (two tests spawn a real
gdb and one drives the app from session start to teardown; all skip silently
when gdb is missing). **The full user manual lives in [USAGE.md](USAGE.md).**

**Recording note.** `rr record` and `perf record` need
`kernel.perf_event_paranoid ≤ 1` (rr prints the same instruction):
`sudo sysctl kernel.perf_event_paranoid=1`. diaguiinspect only *reads* the
resulting data. valgrind (vgdb, cachegrind) needs no privileges.

## Windows

| window        | what it shows / does                                              |
| ------------- | ----------------------------------------------------------------- |
| Session       | target status, run/step control, threads; reverse controls (rr) |
| Source        | current frame's file; click a line margin to toggle a breakpoint  |
| Disassembly   | instructions around $pc; click a row to toggle a breakpoint        |
| Registers     | all registers per stop; values changed since the last stop marked |
| Stack         | backtrace; selecting a frame refreshs every view                  |
| Breakpoints   | gdb's breakpoint/watchpoint table, insert/enable/delete           |
| Memory        | bounded hexdump of any address, or of $pc                        |
| Raw gdb       | gdb console mirror; commands go through `-interpreter-exec`      |
| perf          | perf.data parse progress, hottest samples with symbols+modules    |
| cachegrind    | per-event totals, costliest functions, per-line detail table     |
| Console       | diaguiinspect's diagnostics: outputs and errors                    |

The debugger panels are stuck into one docked grid (drag a splitter to
resize, resize the window and the grid follows; offline profile modes swap
in their analysis window). Key bindings mirror the original grr: F1 run,
F2 continue, F3 break, F5 stepi, F6 nexti, F7 step, F8 next, F9 finish.

## The integrated backends

- **rr** (`--rr`): connects gdb to `rr serve <latest-or-given trace>` via
  `-target-select remote`. The session window grows a reverse-execution row
  (◀ Run/Step/Next/Stepi/Finish → `-exec-* --reverse`); the Session window also
  shows the trace path. Everything else (breakpoints, stepping, registers,
  memory) works as with a live target.
- **valgrind/vgdb** (`--vgdb [pid]`): connects through
  `-target-select remote | vgdb [--pid=N]`. Load the program's symbols by
  passing its path, as the original grr does. Start valgrind with
  `valgrind --vgdb-error=0 ./program`.
- **perf** (`--perf FILE`): parses perf.data (format v2) incrementally — a
  bounded byte budget per frame, so recording-sized files never stall the
  GUI — aggregating sample leaf IPs into a bounded hash table. The hottest
  64 addresses are resolved against their mapping's ELF symbol table
  (a minimal bounded symtab reader, `src/elf.zig`) one module per frame,
  then shown with module+offset. Mappings come from PERF_RECORD_MMAP2;
  user/kernel samples are counted separately.
- **cachegrind** (`--cachegrind FILE`): parses valgrind's cachegrind output
  incrementally (same bounded-per-frame discipline), aggregates per-function
  totals for all event kinds (the full 13-kind cache+branch set) and keeps
  per-(function, line) costs for the selected function's detail table.

## The console button

The host's **menu bar carries the single Console button**. Clicking it:

1. opens the shared Console window, and
2. logs an entry (`diaguiinspect host: console button clicked — input and
   render are alive`), which is only possible if the menu's input handling
   *and* the render loop are both alive.

Next to it sits the health badge: `GUI OK — no errors logged` in green, or
the error count in red (with an unseen count). Only GUI failures count
there — MI parse failures, gdb `^error`s, dropped overlong lines, truncated
responses, session death. **The debugged program's own stderr is program
output**: it goes to the Raw gdb window next to the program's stdout and
never darkens the health badge.

## Tiger Style

How this codebase applies the style:

- **Static memory.** All diaguiinspect state is one statically allocated `App`
  (fixed-capacity arrays with explicit counts), one `Session`, one console
  ring. Nothing in diaguiinspect's own code allocates after init: every buffer has a
  named bound (`registers_max`, `source_bytes_max`, ...), and overflowing a
  bound truncates with a visible console warning instead of allocating.
- **A limit on everything.** Reader queues (8 lines of 64 KiB each — gdb's
  register-values reply alone reaches 40 KiB), drain batches (64
  lines/frame), MI parse nodes (1024), parse depth (32), console entries
  (512), raw log (512), breakpoints (128), frames (128), registers (128),
  instructions (64), threads (16), source (512 KiB / 16384 lines), perf
  mappings (128) / hotspots (4096) / top list (64) / ELF symbols (8192),
  cachegrind functions (2048) / files (512) / cost lines (8192), and a
  fixed parse budget per frame for both offline profiles. A flooding gdb or
  a recording-sized perf.data backpressures at a pipe or a budget, never at
  diaguiinspect's heap — there is no heap.
- **No recursion.** The MI grammar nests, but the parser
  (`src/mi.zig`) works an explicit frame stack with a hard depth bound.
- **diaguiinspect runs at its own pace.** gdb output is only consumed by the frame
  loop's bounded `drain`; reader threads merely fill a bounded queue.
- **Assertions, paired.** Internal invariants are asserted (index < count
  after check, ring arithmetic, stack unwinding); *external* data — gdb's
  output — is validated and degraded (warn + truncate), never asserted,
  because gdb misbehaving is an operating condition, not a bug in diaguiinspect.
- **Errors handled.** Every `catch` either reports to the console or
  propagates to `main`, which prints the console to stderr when the GUI
  could not start at all.
- **Style by the numbers.** `zig fmt` clean, 100-column hard limit, 70-line
  functions (enforced by review, see `scripts/check_style.zig`), snake_case
  everywhere, explicitly sized integers (`u32`/`u64`), positive invariants
  (`if (index < count)`), options structs over positional booleans.

Honest deviations, and why:

- **Dependencies.** TigerBeetle has a zero-dependency policy; this brief
  explicitly requires zgui, and a GUI cannot be written against raw
  framebuffer writes in any reasonable scope. The set is the minimum for
  the brief: zgui (imgui), zglfw (GLFW), zopengl (GL loader), system_sdk
  (X11 link stubs). zglfw/zopengl/system_sdk are pinned by hash in
  `build.zig.zon`.
- **zgui is vendored** at `deps/zgui` (commit 1260767, "Support Zig
  0.17"), because Zig 0.17.1 renamed `std.fmt.bufPrintZ` and upstream has
  no fix at that revision yet. The diff is exactly two call sites,
  `bufPrintZ(...)` → `bufPrintSentinel(..., 0)` in `src/gui.zig` and
  `src/te.zig`; everything else is upstream, unmodified.
- **imgui allocates.** Dear ImGui allocates internally (draw data, font
  atlas). diaguiinspect hands it `std.heap.smp_allocator` and keeps every byte of its
  own state static.
- **Two reader threads.** Blocking pipe reads need a thread each (stdout,
  stderr). Their only job is to fill a bounded queue; all decisions happen
  on the main thread.

## Scope

The core gdb/MI debugger (the original's heart) is complete, and this
revision adds the four classic grr-family backend integrations — rr replay with
reverse execution, valgrind via vgdb, offline perf.data profiles with ELF
symbolization, and cachegrind output — each as a bounded, static, testable
module. What remains from the original: rr's timeline/flamegraph view
(the replay itself works today), valgrind's shadow-register coloring, and
JVM `PrintAssembly` support. The MI layer (`src/gdb.zig`, `src/mi.zig`) is
the seam where deeper backends would attach.

## Layout

~~~
src/main.zig              entry: CLI (five modes), GUI setup, frame loop
src/app.zig               application state + session orchestration (static)
src/gdb.zig               gdb session: process, readers, token queue
src/mi.zig                MI3 record/value parser (iterative, bounded)
src/elf.zig               minimal bounded ELF symbol table, for perf
src/perf.zig              incremental perf.data parser + hotspots
src/cachegrind.zig        incremental cachegrind output parser
src/console.zig           diagnostics console ring + console window
src/window.zig            shared window chrome (geometry, footer, colors)
src/windows.zig           host dockspace, menus, hotkeys, mode visibility
src/windows/*.zig         one file per diaguiinspect window
src/tests.zig             test umbrella
~~~

## Testing

`zig build test` runs 23 tests: the MI parser battery (valid, malformed,
depth/size limits, realistic gdb payloads), the console ring, the source
indexer, synthetic perf.data and cachegrind profiles built byte-by-byte,
ELF symbol lookup over a real /bin/true, two real-gdb session smoke tests,
and one full app-level session — `app.start` through `starti`, the stop,
the refresh batch (registers, stack, disassembly, threads), and teardown —
driving exactly the code paths the GUI drives. The cachegrind parser's
aggregation is additionally cross-checked against valgrind's own summary
(159,421 Ir over a real profile, matching to the instruction).
