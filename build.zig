const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "diaguiinspect-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const zglfw = b.dependency("zglfw", .{ .target = target });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.root_module.linkLibrary(zglfw.artifact("glfw"));

    const zopengl = b.dependency("zopengl", .{});
    exe.root_module.addImport("zopengl", zopengl.module("root"));

    const zgui = b.dependency("zgui", .{
        .target = target,
        .backend = .glfw_opengl3,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.root_module.linkLibrary(zgui.artifact("imgui"));

    // X11 development stubs, needed to link GLFW on Linux.
    if (target.result.os.tag == .linux) {
        if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
            exe.root_module.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
        }
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // `zig build run -- <args>` passes <args> through to diaguiinspect.
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run diaguiinspect-zig");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .name = "diaguiinspect-zig-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zgui", zgui.module("root"));
    tests.root_module.linkLibrary(zgui.artifact("imgui"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
