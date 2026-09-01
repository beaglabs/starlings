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

    const harbor_bridge_module = b.createModule(.{
        .root_source_file = b.path("integrations/harbor/zig/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    harbor_bridge_module.addImport("starlings", mod);
    const harbor_bridge = b.addExecutable(.{
        .name = "starlings-harbor-bridge",
        .root_module = harbor_bridge_module,
    });
    b.installArtifact(harbor_bridge);

    const test_step = b.step("test", "Run Starlings SDK and population tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_pack_tests.step);
    test_step.dependOn(&harbor_bridge.step);

}
