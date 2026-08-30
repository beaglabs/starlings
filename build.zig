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

    const weightless_3d_module = b.createModule(.{
        .root_source_file = b.path("trials/weightless-3d-paper-reconstruction/trial.zig"),
        .target = target,
        .optimize = optimize,
    });
    weightless_3d_module.addImport("starlings", mod);
    const weightless_3d_tests = b.addTest(.{
        .root_module = weightless_3d_module,
    });
    const run_weightless_3d_tests = b.addRunArtifact(weightless_3d_tests);

    const weightless_3d_step = b.step(
        "trial-weightless-3d",
        "Run the weightless 3D paper reconstruction trial",
    );
    weightless_3d_step.dependOn(&run_weightless_3d_tests.step);
}
