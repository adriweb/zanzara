const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zanzara",
        .root_source_file = b.path("example.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    // Zig tests
    {
        const test_exe = b.addTest(.{
            .root_source_file = b.path("src/zanzara.zig"),
            .filters = b.option(
                []const []const u8,
                "test-filter",
                "Skip tests that do not match any filter",
            ) orelse &.{},
        });

        const run_test = b.addRunArtifact(test_exe);

        const test_step = b.step("test", "Run the tests");
        test_step.dependOn(&run_test.step);
    }
}