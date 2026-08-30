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

    const test_step = b.step("test", "Run Starlings SDK and population tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_pack_tests.step);

    const trial_3d_module = b.createModule(.{
        .root_source_file = b.path("trials/3d-emergent-asset/trial.zig"),
        .target = target,
        .optimize = optimize,
    });
    trial_3d_module.addImport("starlings", mod);
    const trial_3d_tests = b.addTest(.{
        .root_module = trial_3d_module,
    });
    const run_trial_3d_tests = b.addRunArtifact(trial_3d_tests);

    const trial_3d_step = b.step(
        "trial-3d",
        "Run the emergent 3D asset population trial",
    );
    trial_3d_step.dependOn(&run_trial_3d_tests.step);
}
