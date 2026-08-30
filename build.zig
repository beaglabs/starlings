const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("starlings", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const pack_test_module = b.createModule(.{
        .root_source_file = b.path("src/pack_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pack_tests = b.addTest(.{
        .root_module = pack_test_module,
    });
    const run_pack_tests = b.addRunArtifact(pack_tests);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli = b.addExecutable(.{
        .name = "starlings",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    const validate_example = b.addRunArtifact(cli);
    validate_example.addArgs(&.{
        "pack",
        "validate",
        "examples/packs/coding-local",
    });

    const validate_phase3_example = b.addRunArtifact(cli);
    validate_phase3_example.addArgs(&.{
        "pack",
        "validate",
        "examples/packs/phase3-run",
    });

    const test_step = b.step("test", "Run protocol-core and Emergence Pack tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_pack_tests.step);
    test_step.dependOn(&validate_example.step);
    test_step.dependOn(&validate_phase3_example.step);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const run_step = b.step("run", "Run the Starlings CLI");
    run_step.dependOn(&run_cli.step);
}
