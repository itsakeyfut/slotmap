const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const slotmap_mod = b.addModule("slotmap", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example: examples/basic.zig — a small demo of the public API.
    const example = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "slotmap", .module = slotmap_mod },
            },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    if (b.args) |args| {
        run_example.addArgs(args);
    }
    const example_step = b.step("examples", "Build and run the basic example");
    example_step.dependOn(&run_example.step);
    run_example.step.dependOn(b.getInstallStep());

    // Test
    const mod_tests = b.addTest(.{
        .root_module = slotmap_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
