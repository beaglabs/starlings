const std = @import("std");
const starlings = @import("starlings");

const core = starlings.sdk.core;
const agent_sdk = starlings.sdk.agent;

fn artifactId(tag: u8) core.ContentId {
    var id = starlings.content_id.zero;
    id[31] = tag;
    return id;
}

const Fake3D = struct {
    calls: usize = 0,

    fn infer(
        raw: ?*anyopaque,
        request: agent_sdk.ModelRequest,
    ) !core.OperatorOutput {
        const state_ptr = raw orelse return error.MissingTrialModelState;
        const self: *@This() = @ptrCast(@alignCast(state_ptr));
        self.calls += 1;

        const profile = request.profile orelse return error.MissingTrialProfile;
        var out = core.OperatorOutput{};

        if (std.mem.eql(u8, profile, "triposr")) {
            if (request.provides_variables.len != 2) return error.InvalidTrialContract;
            try out.addClaim(.{
                .variable = request.provides_variables[0],
                .status = .derived,
                .value = .{ .artifact_ref = artifactId(1) },
                .confidence_permille = 720,
                .source_operator = request.operator_id,
            });
            try out.addClaim(.{
                .variable = request.provides_variables[1],
                .status = .derived,
                .value = .{ .float = 0.72 },
                .confidence_permille = 720,
                .source_operator = request.operator_id,
            });
            return out;
        }

        if (std.mem.eql(u8, profile, "triposg")) {
            if (request.provides_variables.len != 2) return error.InvalidTrialContract;

            var gpu_available = false;
            var saw_gpu = false;
            for (request.observations) |observation| {
                if (observation.value) |value| {
                    switch (value) {
                        .boolean => |flag| {
                            gpu_available = flag;
                            saw_gpu = true;
                        },
                        else => {},
                    }
                }
            }
            if (!saw_gpu) return error.MissingGpuObservation;

            if (!gpu_available) {
                try out.addClaim(.{
                    .variable = request.provides_variables[0],
                    .status = .blocked,
                    .source_operator = request.operator_id,
                });
                try out.addClaim(.{
                    .variable = request.provides_variables[1],
                    .status = .blocked,
                    .source_operator = request.operator_id,
                });
                return out;
            }

            try out.addClaim(.{
                .variable = request.provides_variables[0],
                .status = .derived,
                .value = .{ .artifact_ref = artifactId(2) },
                .confidence_permille = 940,
                .source_operator = request.operator_id,
            });
            try out.addClaim(.{
                .variable = request.provides_variables[1],
                .status = .derived,
                .value = .{ .float = 0.94 },
                .confidence_permille = 940,
                .source_operator = request.operator_id,
            });
            return out;
        }

        if (std.mem.eql(u8, profile, "unirig-fast") or
            std.mem.eql(u8, profile, "unirig-fidelity"))
        {
            if (request.provides_variables.len != 1) return error.InvalidTrialContract;
            if (request.observations.len != 1) return error.InvalidTrialContract;

            const mesh = request.observations[0].value orelse
                return error.MissingMeshObservation;
            const mesh_id = switch (mesh) {
                .artifact_ref => |id| id,
                else => return error.InvalidMeshObservation,
            };
            const rig_tag: u8 = if (starlings.content_id.eql(mesh_id, artifactId(1)))
                11
            else if (starlings.content_id.eql(mesh_id, artifactId(2)))
                12
            else
                return error.UnknownMeshCandidate;

            try out.addClaim(.{
                .variable = request.provides_variables[0],
                .status = .derived,
                .value = .{ .artifact_ref = artifactId(rig_tag) },
                .confidence_permille = if (rig_tag == 11) 720 else 940,
                .source_operator = request.operator_id,
            });
            return out;
        }

        return error.UnknownTrialProfile;
    }
};

const Validator = struct {
    rig_id: core.VariableId,
    output_id: core.VariableId,

    fn execute(
        raw: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw orelse return error.MissingValidatorContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));
        _ = observation.value(self.rig_id) orelse return error.MissingRig;

        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.output_id,
            .status = .derived,
            .value = .{ .boolean = true },
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

const Selector = struct {
    rig_id: core.VariableId,
    valid_id: core.VariableId,
    quality_id: core.VariableId,
    output_id: core.VariableId,
    confidence_permille: u16,

    fn execute(
        raw: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw orelse return error.MissingSelectorContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        const rig = observation.value(self.rig_id) orelse return error.MissingRig;
        const valid = observation.value(self.valid_id) orelse return error.MissingValidation;
        const quality = observation.value(self.quality_id) orelse return error.MissingQuality;

        if (!valid.boolean) return error.InvalidRigCandidate;
        _ = quality.float;

        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.output_id,
            .status = .derived,
            .value = rig,
            .confidence_permille = self.confidence_permille,
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

fn runScenario(gpu_available: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var population = try starlings.Population.load(
        std.testing.io,
        std.testing.allocator,
        arena,
        "trials/3d-emergent-asset/population",
    );

    var fake = Fake3D{};
    const providers = [_]agent_sdk.ModelProvider{.{
        .name = "fake-3d",
        .context = &fake,
        .infer_fn = Fake3D.infer,
    }};

    const validate_fast = Validator{
        .rig_id = population.compiled.variableId("rig.fast").?,
        .output_id = population.compiled.variableId("rig.fast.valid").?,
    };
    const validate_fidelity = Validator{
        .rig_id = population.compiled.variableId("rig.fidelity").?,
        .output_id = population.compiled.variableId("rig.fidelity.valid").?,
    };
    const select_fast = Selector{
        .rig_id = population.compiled.variableId("rig.fast").?,
        .valid_id = population.compiled.variableId("rig.fast.valid").?,
        .quality_id = population.compiled.variableId("mesh.fast.quality").?,
        .output_id = population.compiled.variableId("asset.selected").?,
        .confidence_permille = 720,
    };
    const select_fidelity = Selector{
        .rig_id = population.compiled.variableId("rig.fidelity").?,
        .valid_id = population.compiled.variableId("rig.fidelity.valid").?,
        .quality_id = population.compiled.variableId("mesh.fidelity.quality").?,
        .output_id = population.compiled.variableId("asset.selected").?,
        .confidence_permille = 940,
    };

    const native = [_]agent_sdk.NativeBinding{
        .{
            .name = "validate-fast",
            .context = &validate_fast,
            .execute_fn = Validator.execute,
        },
        .{
            .name = "validate-fidelity",
            .context = &validate_fidelity,
            .execute_fn = Validator.execute,
        },
        .{
            .name = "select-fast",
            .context = &select_fast,
            .execute_fn = Selector.execute,
        },
        .{
            .name = "select-fidelity",
            .context = &select_fidelity,
            .execute_fn = Selector.execute,
        },
    };

    var agent = try starlings.Agent.init(
        std.testing.io,
        std.testing.allocator,
        arena,
        &population,
        42,
        .{
            .models = &providers,
            .native = &native,
        },
    );
    defer agent.deinit();

    _ = try agent.observe(.{
        .name = "source.image",
        .value = .{ .text = "fixture://single-image.png" },
    });
    _ = try agent.observe(.{
        .name = "resource.memory_mb",
        .value = .{ .integer = 8192 },
    });
    _ = try agent.observe(.{
        .name = "resource.gpu",
        .value = .{ .boolean = gpu_available },
    });

    var activations: usize = 0;
    while (try agent.step() == .progress) {
        activations += 1;
        if (activations > 32) return error.TrialDidNotQuiesce;
    }

    const selected = agent.value("asset.selected") orelse return error.NoSelectedAsset;
    const selected_id = switch (selected) {
        .artifact_ref => |id| id,
        else => return error.InvalidSelectedAsset,
    };

    if (gpu_available) {
        try std.testing.expect(starlings.content_id.eql(selected_id, artifactId(12)));
        try std.testing.expectEqual(
            core.EpistemicStatus.derived,
            agent.status("mesh.fidelity").?,
        );
        try std.testing.expectEqual(@as(usize, 4), fake.calls);
    } else {
        try std.testing.expect(starlings.content_id.eql(selected_id, artifactId(11)));
        try std.testing.expectEqual(
            core.EpistemicStatus.blocked,
            agent.status("mesh.fidelity").?,
        );
        try std.testing.expectEqual(@as(usize, 3), fake.calls);
    }

    try std.testing.expect(activations >= 5);
    try std.testing.expect(agent.eventRecords().len > 0);
}

test "CPU-only resources converge on the fast reconstruction and rigging candidate" {
    try runScenario(false);
}

test "GPU resources permit a higher-confidence fidelity candidate to emerge" {
    try runScenario(true);
}
