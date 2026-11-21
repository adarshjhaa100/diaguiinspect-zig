# diaguiinspect-zig — Usage

A gdb GUI in Zig, in the spirit of dzaima's grr. This is the user manual;
`README.md` covers the design and Tiger Style notes.

Build and run:

~~~sh
zig build                      # once
zig build run -- ./some-program
zig build run -- --break main ./some-program
~~~

`diaguiinspect-zig` (the binary in `zig-out/bin/`) needs `gdb` on PATH.
Everything below assumes the bare `diaguiinspect-zig` name.

---

## Command line

~~~sh
diaguiinspect-zig [options] path/to/program [program args..]
~~~

| option             | effect                                                       |
| ------------------ | ------------------------------------------------------------ |
| (no options)       | load the program, run it, show the debugger                   |
| `--break LOCATION` | set a breakpoint before the program runs (e.g. `main`)       |
| `--no-run`         | load the program but wait (press F1 in the GUI)                |
| `--core FILE`      | load a core dump (pass the program too, for symbols)          |
| `--gdb-bin PATH`   | use a specific gdb binary                                     |
| `--rr [trace-dir]` | replay an rr recording (default: the latest under `~/.local/share/rr`) |
| `--vgdb [pid]`     | attach to a running valgrind via vgdb                        |
| `--perf FILE`      | view a perf.data recording (a directory means `<dir>/perf.data`) |
| `--cachegrind FILE` | view a cachegrind output profile                             |
| `--help`           | show the summary                                              |

Program arguments after the program path (or after `--`) go to the program,
not to diaguiinspect-zig. Examples:

~~~sh
diaguiinspect-zig ./my-app serve --port 8080      # runs "./my-app serve --port 8080"
diaguiinspect-zig --no-run ./my-app               # set breakpoints first, then F1
diaguiinspect-zig --break main ./my-app           # stops in main on startup
diaguiinspect-zig --core ./core ./my-app          # post-mortem debugging
diaguiinspect-zig --rr                            # replay the latest rr recording
diaguiinspect-zig --rr ~/.local/share/rr/my-app-123
diaguiinspect-zig --vgdb 4242 ./my-app            # attach to valgrind pid 4242
diaguiinspect-zig --perf .                        # view ./perf.data
diaguiinspect-zig --cachegrind cachegrind.out.12345
~~~

---

## The windows

diaguiinspect-zig opens as one window with **stuck panels**: every view is docked into a
fixed arrangement and cannot be dragged around or floated out. Grab a
**splitter** between panels to resize them — that is the only layout
control, and it is remembered. Resizing the diaguiinspect-zig window resizes the whole
panel grid with it.

~~~text
┌────────────────┬───────────────────┐
│ Source         │ Session            │
├────────────────┼───────────────────┤
│ Disassembly    │ Registers | Stack │
├────────────────┴───────────────────┤
│ Breakpoints | Memory    Raw | Console│
└────────────────────────────────────┘
~~~

`--perf` and `--cachegrind` swap the grid for the analysis window
with the console along the bottom. Each mode keeps its own saved layout
(`imgui-gdb.ini`, `imgui-perf.ini`, `imgui-cachegrind.ini` next to wherever
you launch from). **View → Reset layout** rebuilds the default grid at any
time; **View → (window)** reopens a panel you closed. Tabs (Registers ⇄
Stack, Breakpoints ⇄ Memory) reflow as the panel resizes, and every view
with long lines (source rows, the hexdump, MI output) gains a horizontal
scrollbar instead of clipping.

| window       | what it shows / does                                            |
| ------------ | --------------------------------------------------------------- |
| Session      | status, run/step buttons, threads; reverse buttons (rr only) |
| Source       | the current frame's file, the current line highlighted           |
| Disassembly  | instructions around $pc; **C + asm** toggle interleaves the C lines (needs a `-g` build); both kinds of rows are breakpoint targets |
| Registers    | every register; values changed since the last stop are marked   |
| Stack        | the backtrace; click a frame to select it                        |
| Breakpoints  | gdb's breakpoint and watchpoint table                            |
| Memory       | a hexdump of any address (or of $pc)                             |
| Raw gdb      | gdb's own console, with command history                         |
| perf         | (only with `--perf`) hottest samples, symbolized                 |
| cachegrind   | (only with `--cachegrind`) per-event totals and per-line costs   |
| Console      | diaguiinspect-zig's own diagnostics: outputs and errors           |

Interactions worth knowing:

- **Copying anything**: right-click any row — source lines, instructions,
  register values, stack frames, breakpoints, memory rows, console and raw
  log entries — for a Copy menu; register values are also click-to-copy;
  the Console, Raw gdb, Registers and Memory panels have **Copy all**
  buttons; and the Session panel has a **copy $pc** button. Everything on
  the clipboard pastes into the inputs (Ctrl+V): the Breakpoints location
  field takes what you copied, and Memory's address field accepts hex with
  or without the `0x` prefix.
- **Source**: click a line's left margin to toggle a breakpoint there. The
  current line is yellow; breakpoint markers are red dots.
- **Disassembly**: the **C + asm** checkbox interleaves each C source line
  with the instructions that implement it (gdb's source-centric mixed
  view). Source rows toggle `file:line` breakpoints, instruction rows
  toggle `*address` breakpoints. Mixed mode needs debug info in the binary —
  compile with `-g -O0` to get it; without it, gdb has no C code to show
  and the panel stays on pure assembly.
- **Disassembly**: click any instruction row to toggle a breakpoint at that
  address; `=>` marks $pc.
- **Stack**: click a frame; every window (registers, disassembly, source)
  re-queries against that frame.
- **Breakpoints**: type a location (`main`, `file.c:12`, `*0x40126d`) and
  press Insert; toggle a row's checkbox to enable/disable, `delete` to
  remove. The same table lists watchpoints.
- **Memory**: type a hex address and press Read, or press `From $pc`.
- **Raw gdb**: Enter sends the command (through MI, so it cannot
  desynchronize diaguiinspect); Up/Down walk the history while the field is focused.
  `-`-prefixed MI commands are sent as-is.

### The console button

The **menu bar carries the single Console button** — one click opens the
shared Console and logs an entry proving the menu's input handling and the
render loop are alive. Next to the button sits the health badge:

- `GUI OK — no errors logged` (green): nothing has failed since startup.
- `N errors (M unseen)` (red): the console holds errors; M counts those
  logged since the console was last open.

Only GUI failures count toward the badge: gdb `^error`s, MI parse
failures, dropped overlong lines, truncated responses, session death.
**The debugged program's own stderr is program output, not an error**: gdb
relays it alongside its own diagnostics, and diaguiinspect-zig shows it in
the Raw gdb window next to the program's stdout. A program that prints
`failure: No such file or directory` and exits nonzero is telling you
something about itself, not about the GUI.

Use the All/Warnings/Errors filters to narrow the Console, Clear to
reset, and Auto-scroll to follow the newest entries.

### Key bindings

Same as the original grr (inactive while a text field has focus):

| key | action                    | key | action                     |
| --- | ------------------------- | --- | -------------------------- |
| F1  | run                       | F6  | next instruction           |
| F2  | continue                  | F7  | step one line              |
| F3  | break (interrupt)         | F8  | next line                  |
| F5  | step one instruction      | F9  | run function to completion |

---

## Debugging with gdb (default mode)

`diaguiinspect-zig ./prog` loads the symbols and runs; the program's own stdio stays in
gdb's console (see the Raw gdb window). Use `--no-run` to inspect first,
`--break main` to stop at a fixed point, `--core` for post-mortems.

diaguiinspect-zig talks to gdb through MI3 (`--interpreter=mi3`) and processes output
in bounded batches per frame, so a chatty gdb never stalls the UI; a
chatty gdb also never exhausts memory: everything diaguiinspect-zig stores is bounded
(see [Limits](#limits)).

## Replaying rr recordings

Record once, replay and study forever — including backwards.

~~~sh
rr record ./my-app          # record a trace
diaguiinspect-zig --rr                    # replay the latest trace
diaguiinspect-zig --rr ~/.local/share/rr/my-app-123
~~~

diaguiinspect connects gdb to `rr serve` for the trace. The Session window shows the
trace path and a **reverse execution row** (◀ Run/Step/Next/Stepi/Finish),
which runs the recording backwards — the counterpart of holding shift in
the original grr. Breakpoints, stepping, registers, memory and the raw gdb
window all work as with a live target. In the Raw gdb window, rr console
commands are available too, e.g. `when-ticks` or `run backwards`.

**Recording needs `kernel.perf_event_paranoid ≤ 1`** — rr itself prints the
same instruction:

~~~sh
sudo sysctl kernel.perf_event_paranoid=1
~~~

## Attaching to valgrind (vgdb)

Run your program under valgrind with the gdbserver enabled, then connect:

~~~sh
valgrind --vgdb-error=0 ./my-app          # stops at entry, waits for gdb
diaguiinspect-zig --vgdb ./my-app                        # connect to the only valgrind
# or, with several running:
diaguiinspect-zig --vgdb 4242 ./my-app                   # connect by pid
~~~

Passing the program path gives gdb the symbols to resolve frames against
the valgrind target (the program is not run by diaguiinspect-zig). Set breakpoints and
step as usual; valgrind reports each memory error as a stop.

## Viewing perf profiles

Record call-chain samples and view where the time went:

~~~sh
perf record -g ./my-app     # writes perf.data
diaguiinspect-zig --perf .                # views ./perf.data
~~~

diaguiinspect parses the file **incrementally** — a bounded byte budget per frame, so
even recording-sized files never freeze the UI; the perf window shows the
progress until the parse completes. Then it shows the hottest sample
addresses (the call-chain leaves), each with its count, share, and
`module+offset`; addresses in modules with ELF symbols also show the
**function name**. User-space and kernel samples are counted separately.

The parser reads the layouts `perf record` and `perf record -g` produce
(IP/TID/TIME/CALLCHAIN/CPU/PERIOD/ID/STREAM_ID); anything fancier is
reported and the file is skipped. Like rr, **recording** needs
`perf_event_paranoid ≤ 1`.

## Viewing cachegrind profiles

~~~sh
valgrind --tool=cachegrind --cache-sim=yes --branch-sim=yes \
    --cachegrind-out-file=cg.out ./my-app
diaguiinspect-zig --cachegrind cg.out
~~~

The cachegrind window parses at a bounded pace (progress shown while it
runs), then lists the totals per event kind (the full cache+branch set —
Ir, I1mr, ILmr, Dr, D1mr, DLmr, Dw, D1mw, DLmw, Bc, Bcm, Bi, Bim — up to 16
kinds), the costliest functions sorted by instruction reads, and, for the
function you select, a per-line cost table.

---

## Limits

Everything diaguiinspect-zig stores is statically allocated with an explicit bound.
When a bound is hit, diaguiinspect-zig warns in the Console and keeps going with partial
data instead of allocating:

| what                  | bound                            |
| --------------------- | -------------------------------- |
| MI lines (from gdb)  | 64 KiB each; queue of 8 per stream |
| gdb output per frame  | 64 lines                         |
| MI parse nodes        | 1024 entries, depth 32           |
| registers / frames / breakpoints | 128 each            |
| disassembly window    | 64 instructions                  |
| threads               | 16                               |
| source file           | 512 KiB, 16384 lines             |
| console entries       | 512 (oldest overwritten)         |
| raw gdb console       | 512 lines                        |
| perf mappings         | 128; hotspots 4096; top list 64; ELF symbols 8192 |
| cachegrind functions  | 2048; files 512; cost lines 8192; event kinds 16 |

## Troubleshooting

- **`diaguiinspect: program not found: ...`** — the path does not exist relative to
  where you launched diaguiinspect-zig. Use an absolute path if in doubt.
- **No C code anywhere, only assembly** — the binary was compiled without
  debug info. Recompile with `-g -O0` (`cc -g -O0 prog.c -o prog`) and the
  Source panel, line stepping (F7/F8) and the C + asm view all light up.
  Without `-g` there is no C in the binary to recover; reconstructing C
  from nothing is a decompiler's job (see Ghidra), not a debugger's.
- **The Raw gdb window shows `failure: No such file or directory` right
  after the program starts** — that is **your program's own stderr**, not
  a diaguiinspect or gdb failure: gdb relays inferior stderr, and the raw
  window is where program output belongs. If your program prints
  `failure: ...` and exits 255, gdb loaded it fine — check what the program
  itself tried to open. The health badge stays green.
- **`diaguiinspect: starting gdb failed: FileNotFound`** — install gdb or pass
  `--gdb-bin /path/to/gdb`.
- **rr/perf recording fails with permission errors** — set
  `kernel.perf_event_paranoid=1` (see above). Viewing existing data needs
  no privileges.
- **A panel arrangement went wrong** — View → Reset layout rebuilds the
  default grid; deleting the mode's `imgui-*.ini` does the same on the
  next start.
- **The Session window says `gdb gone`** — gdb exited or crashed. The Console
  holds the last errors; restart diaguiinspect-zig.
- **A reply never arrived / a view stayed empty** — the Console will say if
  a line was dropped for exceeding the 64 KiB bound; the next stop
  re-queries everything anyway.
- **GUI health** — click the menu bar's Console button: if the entry appears
  in the Console window, that window's input and the render loop are fine.
