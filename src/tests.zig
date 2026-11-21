// Test umbrella: every module's unit tests, plus the end-to-end session
// tests that drive a real gdb (spawned, run, stopped, torn down) without
// any GUI.

test {
    _ = @import("mi.zig");
    _ = @import("console.zig");
    _ = @import("app.zig");
    _ = @import("elf.zig");
    _ = @import("perf.zig");
    _ = @import("cachegrind.zig");
    _ = @import("gdb_session_test.zig");
    _ = @import("app_session_test.zig");
}
