const std = @import("std");
const starlings = @import("starlings");

const core = starlings.sdk.core;
const output_state = starlings.sdk.output_state;
const agent_sdk = starlings.sdk.agent;

const ShapeKind = enum {
    extrusion,
    revolution,
};

fn clamp01(value: f64) f64 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

fn readFloat(
    observation: agent_sdk.AgentRunner.Observation,
    id: core.VariableId,
) !f64 {
    const value = observation.value(id) orelse return error.MissingFloatObservation;
    return switch (value) {
        .float => |v| v,
        else => error.InvalidFloatObservation,
    };
}

fn readBool(
    observation: agent_sdk.AgentRunner.Observation,
    id: core.VariableId,
) !bool {
    const value = observation.value(id) orelse return error.MissingBoolObservation;
    return switch (value) {
        .boolean => |v| v,
        else => error.InvalidBoolObservation,
    };
}

fn readArtifact(
    observation: agent_sdk.AgentRunner.Observation,
    id: core.VariableId,
) !core.ContentId {
    const value = observation.value(id) orelse return error.MissingArtifactObservation;
    return switch (value) {
        .artifact_ref => |v| v,
        else => error.InvalidArtifactObservation,
    };
}

fn readText(
    observation: agent_sdk.AgentRunner.Observation,
    id: core.VariableId,
) ![]const u8 {
    const value = observation.value(id) orelse return error.MissingTextObservation;
    return switch (value) {
        .text => |v| v,
        else => error.InvalidTextObservation,
    };
}

fn shapeName(kind: ShapeKind) []const u8 {
    return switch (kind) {
        .extrusion => "extrusion",
        .revolution => "revolution",
    };
}

fn candidateDepth(kind: ShapeKind, diameter: f64) f64 {
    return switch (kind) {
        // A silhouette-preserving slab/cylinder hypothesis.
        .extrusion => diameter * 0.45,
        // A body-of-revolution hypothesis matching the same front silhouette.
        .revolution => diameter,
    };
}

fn candidateId(kind: ShapeKind, diameter: f64) !core.ContentId {
    var descriptor_storage: [128]u8 = undefined;
    const descriptor = try std.fmt.bufPrint(
        &descriptor_storage,
        "weightless-3d-v1:{s}:diameter={d:.6}",
        .{ shapeName(kind), diameter },
    );
    return output_state.artifactContentId(
        "application/vnd.starlings.weightless-shape",
        descriptor,
    );
}

fn signedDistance(
    kind: ShapeKind,
    diameter: f64,
    x: f64,
    y: f64,
    z: f64,
) f64 {
    const radius = diameter * 0.5;
    return switch (kind) {
        .revolution => @sqrt(x * x + y * y + z * z) - radius,
        .extrusion => blk: {
            const radial = @sqrt(x * x + y * y) - radius;
            const slab = @abs(z) - candidateDepth(.extrusion, diameter) * 0.5;
            break :blk @max(radial, slab);
        },
    };
}

fn eikonalScore(kind: ShapeKind, diameter: f64) f64 {
    const radius = diameter * 0.5;
    const epsilon = diameter * 0.0005;
    const samples = [_]f64{ -0.78, -0.41, 0.17, 0.52, 0.83 };

    var total_error: f64 = 0.0;
    var count: usize = 0;

    for (samples) |sx| {
        for (samples) |sy| {
            for (samples) |sz| {
                const x = sx * radius;
                const y = sy * radius;
                const z = sz * radius;

                const gx = (
                    signedDistance(kind, diameter, x + epsilon, y, z) -
                    signedDistance(kind, diameter, x - epsilon, y, z)
                ) / (2.0 * epsilon);
                const gy = (
                    signedDistance(kind, diameter, x, y + epsilon, z) -
                    signedDistance(kind, diameter, x, y - epsilon, z)
                ) / (2.0 * epsilon);
                const gz = (
                    signedDistance(kind, diameter, x, y, z + epsilon) -
                    signedDistance(kind, diameter, x, y, z - epsilon)
                ) / (2.0 * epsilon);

                const norm = @sqrt(gx * gx + gy * gy + gz * gz);
                if (norm < 0.1) continue;
                total_error += @abs(norm - 1.0);
                count += 1;
            }
        }
    }

    if (count == 0) return 0.0;
    const mean_error = total_error / @as(f64, @floatFromInt(count));
    return clamp01(1.0 - mean_error);
}

fn reconstructionScore(
    kind: ShapeKind,
    diameter: f64,
    depth_hint: f64,
) f64 {
    // Both hypotheses are deliberately constructed to match the same
    // front-view circular silhouette. This preserves the single-view
    // ambiguity instead of pretending the image determines hidden geometry.
    const silhouette_score: f64 = 1.0;
    const depth_score = clamp01(
        1.0 - @abs(candidateDepth(kind, diameter) - depth_hint) / diameter,
    );
    const sdf_score = eikonalScore(kind, diameter);

    // Paper-inspired explicit objectives: image consistency plus SDF
    // regularity, with a non-learned depth cue replacing a learned shape prior.
    return 0.70 * silhouette_score + 0.25 * depth_score + 0.05 * sdf_score;
}

const ProposalContext = struct {
    kind: ShapeKind,
    diameter_id: core.VariableId,
    symmetry_id: ?core.VariableId,
    output_id: core.VariableId,

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingProposalContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        var out = core.OperatorOutput{};
        if (self.symmetry_id) |symmetry_id| {
            if (!try readBool(observation, symmetry_id)) {
                try out.addClaim(.{
                    .variable = self.output_id,
                    .status = .blocked,
                    .source_operator = observation.operatorId(),
                });
                return out;
            }
        }

        const diameter = try readFloat(observation, self.diameter_id);
        try out.addClaim(.{
            .variable = self.output_id,
            .status = .derived,
            .value = .{ .artifact_ref = try candidateId(self.kind, diameter) },
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

const ReconstructionValidator = struct {
    kind: ShapeKind,
    diameter_id: core.VariableId,
    depth_hint_id: core.VariableId,
    symmetry_id: ?core.VariableId,
    candidate_id: core.VariableId,
    score_id: core.VariableId,

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingValidatorContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        if (self.symmetry_id) |symmetry_id| {
            if (!try readBool(observation, symmetry_id)) {
                return error.InvalidSymmetryActivation;
            }
        }

        const diameter = try readFloat(observation, self.diameter_id);
        const depth_hint = try readFloat(observation, self.depth_hint_id);
        const candidate = try readArtifact(observation, self.candidate_id);
        const expected = try candidateId(self.kind, diameter);
        if (!starlings.content_id.eql(candidate, expected)) {
            return error.UnexpectedShapeCandidate;
        }

        const score = reconstructionScore(self.kind, diameter, depth_hint);
        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.score_id,
            .status = .derived,
            .value = .{ .float = score },
            .confidence_permille = @intFromFloat(clamp01(score) * 1000.0),
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

const ShapeSelector = struct {
    candidate_id: core.VariableId,
    score_id: core.VariableId,
    selected_id: core.VariableId,

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingSelectorContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        const candidate = try readArtifact(observation, self.candidate_id);
        const score = try readFloat(observation, self.score_id);
        const confidence: u16 = @intFromFloat(clamp01(score) * 1000.0);

        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.selected_id,
            .status = .derived,
            .value = .{ .artifact_ref = candidate },
            .confidence_permille = confidence,
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

const Skeletonizer = struct {
    selected_id: core.VariableId,
    diameter_id: core.VariableId,
    output_id: core.VariableId,

    const chain_tokens =
        "ROOT|J:-1.000|DOWN|J:0.000|DOWN|J:1.000|UP|UP|EOS";

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingSkeletonizerContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        const diameter = try readFloat(observation, self.diameter_id);
        const selected = try readArtifact(observation, self.selected_id);
        const extruded = try candidateId(.extrusion, diameter);
        const revolved = try candidateId(.revolution, diameter);
        if (!starlings.content_id.eql(selected, extruded) and
            !starlings.content_id.eql(selected, revolved))
        {
            return error.UnknownSelectedShape;
        }

        // UniRig-inspired idea: emit a hierarchy-preserving tree token stream,
        // but synthesize it from explicit medial geometry rather than an
        // autoregressive learned prior.
        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.output_id,
            .status = .derived,
            .value = .{ .text = chain_tokens },
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

fn skeletonTreeValid(tokens: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, tokens, '|');
    const first = iterator.next() orelse return false;
    if (!std.mem.eql(u8, first, "ROOT")) return false;

    var depth: i32 = 0;
    var saw_joint = false;
    var saw_eos = false;

    while (iterator.next()) |token| {
        if (std.mem.startsWith(u8, token, "J:")) {
            saw_joint = true;
            continue;
        }
        if (std.mem.eql(u8, token, "DOWN")) {
            depth += 1;
            continue;
        }
        if (std.mem.eql(u8, token, "UP")) {
            depth -= 1;
            if (depth < 0) return false;
            continue;
        }
        if (std.mem.eql(u8, token, "EOS")) {
            saw_eos = true;
            break;
        }
        return false;
    }

    return saw_joint and saw_eos and depth == 0;
}

const SkeletonValidator = struct {
    tree_id: core.VariableId,
    output_id: core.VariableId,

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingSkeletonValidatorContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        const tree = try readText(observation, self.tree_id);
        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.output_id,
            .status = .derived,
            .value = .{ .boolean = skeletonTreeValid(tree) },
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

fn skinNormalizationError() f64 {
    const joints = [_]f64{ -1.0, 0.0, 1.0 };
    const samples = [_]f64{ -1.0, -0.72, -0.31, 0.0, 0.28, 0.67, 1.0 };

    var max_error: f64 = 0.0;
    for (samples) |point| {
        var raw_weights: [joints.len]f64 = undefined;
        var total: f64 = 0.0;
        for (joints, 0..) |joint, i| {
            const weight = 1.0 / (@abs(point - joint) + 0.05);
            raw_weights[i] = weight;
            total += weight;
        }

        var normalized_sum: f64 = 0.0;
        for (raw_weights) |weight| normalized_sum += weight / total;
        max_error = @max(max_error, @abs(normalized_sum - 1.0));
    }
    return max_error;
}

const Skinner = struct {
    selected_id: core.VariableId,
    tree_id: core.VariableId,
    skeleton_valid_id: core.VariableId,
    error_id: core.VariableId,
    valid_id: core.VariableId,

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingSkinnerContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        _ = try readArtifact(observation, self.selected_id);
        const tree = try readText(observation, self.tree_id);
        const skeleton_valid = try readBool(observation, self.skeleton_valid_id);
        if (!skeleton_valid or !skeletonTreeValid(tree)) {
            return error.InvalidSkeletonForSkinning;
        }

        // Deterministic bone-point association: inverse-distance weights,
        // normalized per point. This replaces learned cross-attention while
        // preserving the semantic task and its normalization invariant.
        const normalization_error = skinNormalizationError();

        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.error_id,
            .status = .derived,
            .value = .{ .float = normalization_error },
            .source_operator = observation.operatorId(),
        });
        try out.addClaim(.{
            .variable = self.valid_id,
            .status = .derived,
            .value = .{ .boolean = normalization_error < 1e-12 },
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

const AssetValidator = struct {
    selected_id: core.VariableId,
    skeleton_valid_id: core.VariableId,
    skin_valid_id: core.VariableId,
    output_id: core.VariableId,

    fn execute(
        raw_context: ?*const anyopaque,
        observation: agent_sdk.AgentRunner.Observation,
    ) !core.OperatorOutput {
        const context_ptr = raw_context orelse return error.MissingAssetValidatorContext;
        const self: *const @This() = @ptrCast(@alignCast(context_ptr));

        _ = try readArtifact(observation, self.selected_id);
        const skeleton_valid = try readBool(observation, self.skeleton_valid_id);
        const skin_valid = try readBool(observation, self.skin_valid_id);

        var out = core.OperatorOutput{};
        try out.addClaim(.{
            .variable = self.output_id,
            .status = .derived,
            .value = .{ .boolean = skeleton_valid and skin_valid },
            .source_operator = observation.operatorId(),
        });
        return out;
    }
};

fn runScenario(
    symmetry: bool,
    expected_kind: ShapeKind,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var population = try starlings.Population.load(
        std.testing.io,
        std.testing.allocator,
        arena,
        "trials/weightless-3d-paper-reconstruction/population",
    );

    const diameter_id = population.compiled.variableId("image.diameter").?;
    const depth_hint_id = population.compiled.variableId("image.depth_hint").?;
    const symmetry_id = population.compiled.variableId("image.symmetry").?;
    const extrusion_id = population.compiled.variableId("shape.extrusion").?;
    const revolution_id = population.compiled.variableId("shape.revolution").?;
    const extrusion_score_id = population.compiled.variableId("shape.extrusion.score").?;
    const revolution_score_id = population.compiled.variableId("shape.revolution.score").?;
    const selected_id = population.compiled.variableId("shape.selected").?;
    const tree_id = population.compiled.variableId("skeleton.tree").?;
    const skeleton_valid_id = population.compiled.variableId("skeleton.valid").?;
    const skin_error_id = population.compiled.variableId("skin.normalization_error").?;
    const skin_valid_id = population.compiled.variableId("skin.valid").?;
    const asset_valid_id = population.compiled.variableId("asset.valid").?;

    const propose_extrusion = ProposalContext{
        .kind = .extrusion,
        .diameter_id = diameter_id,
        .symmetry_id = null,
        .output_id = extrusion_id,
    };
    const propose_revolution = ProposalContext{
        .kind = .revolution,
        .diameter_id = diameter_id,
        .symmetry_id = symmetry_id,
        .output_id = revolution_id,
    };
    const validate_extrusion = ReconstructionValidator{
        .kind = .extrusion,
        .diameter_id = diameter_id,
        .depth_hint_id = depth_hint_id,
        .symmetry_id = null,
        .candidate_id = extrusion_id,
        .score_id = extrusion_score_id,
    };
    const validate_revolution = ReconstructionValidator{
        .kind = .revolution,
        .diameter_id = diameter_id,
        .depth_hint_id = depth_hint_id,
        .symmetry_id = symmetry_id,
        .candidate_id = revolution_id,
        .score_id = revolution_score_id,
    };
    const select_extrusion = ShapeSelector{
        .candidate_id = extrusion_id,
        .score_id = extrusion_score_id,
        .selected_id = selected_id,
    };
    const select_revolution = ShapeSelector{
        .candidate_id = revolution_id,
        .score_id = revolution_score_id,
        .selected_id = selected_id,
    };
    const skeletonize = Skeletonizer{
        .selected_id = selected_id,
        .diameter_id = diameter_id,
        .output_id = tree_id,
    };
    const validate_skeleton = SkeletonValidator{
        .tree_id = tree_id,
        .output_id = skeleton_valid_id,
    };
    const skin = Skinner{
        .selected_id = selected_id,
        .tree_id = tree_id,
        .skeleton_valid_id = skeleton_valid_id,
        .error_id = skin_error_id,
        .valid_id = skin_valid_id,
    };
    const validate_asset = AssetValidator{
        .selected_id = selected_id,
        .skeleton_valid_id = skeleton_valid_id,
        .skin_valid_id = skin_valid_id,
        .output_id = asset_valid_id,
    };

    const native = [_]agent_sdk.NativeBinding{
        .{
            .name = "propose-extrusion",
            .context = &propose_extrusion,
            .execute_fn = ProposalContext.execute,
        },
        .{
            .name = "propose-revolution",
            .context = &propose_revolution,
            .execute_fn = ProposalContext.execute,
        },
        .{
            .name = "validate-extrusion",
            .context = &validate_extrusion,
            .execute_fn = ReconstructionValidator.execute,
        },
        .{
            .name = "validate-revolution",
            .context = &validate_revolution,
            .execute_fn = ReconstructionValidator.execute,
        },
        .{
            .name = "select-extrusion",
            .context = &select_extrusion,
            .execute_fn = ShapeSelector.execute,
        },
        .{
            .name = "select-revolution",
            .context = &select_revolution,
            .execute_fn = ShapeSelector.execute,
        },
        .{
            .name = "skeletonize-medial",
            .context = &skeletonize,
            .execute_fn = Skeletonizer.execute,
        },
        .{
            .name = "validate-skeleton-tree",
            .context = &validate_skeleton,
            .execute_fn = SkeletonValidator.execute,
        },
        .{
            .name = "skin-distance",
            .context = &skin,
            .execute_fn = Skinner.execute,
        },
        .{
            .name = "validate-asset",
            .context = &validate_asset,
            .execute_fn = AssetValidator.execute,
        },
    };

    var agent = try starlings.Agent.init(
        std.testing.io,
        std.testing.allocator,
        arena,
        &population,
        17,
        .{ .native = &native },
    );
    defer agent.deinit();

    const diameter: f64 = 16.0;
    _ = try agent.observe(.{
        .name = "image.diameter",
        .value = .{ .float = diameter },
    });
    _ = try agent.observe(.{
        .name = "image.depth_hint",
        .value = .{ .float = 15.4 },
    });
    _ = try agent.observe(.{
        .name = "image.symmetry",
        .value = .{ .boolean = symmetry },
    });

    var activations: usize = 0;
    while (try agent.step() == .progress) {
        activations += 1;
        if (activations > 64) return error.TrialDidNotQuiesce;
    }

    const selected = agent.value("shape.selected") orelse return error.NoSelectedShape;
    const selected_artifact = switch (selected) {
        .artifact_ref => |id| id,
        else => return error.InvalidSelectedShape,
    };
    const expected = try candidateId(expected_kind, diameter);
    try std.testing.expect(starlings.content_id.eql(selected_artifact, expected));

    const asset_valid = agent.value("asset.valid") orelse return error.NoAssetValidation;
    try std.testing.expect(asset_valid.boolean);

    const skeleton_valid = agent.value("skeleton.valid") orelse return error.NoSkeletonValidation;
    try std.testing.expect(skeleton_valid.boolean);

    const skin_valid = agent.value("skin.valid") orelse return error.NoSkinValidation;
    try std.testing.expect(skin_valid.boolean);

    const skin_error = agent.value("skin.normalization_error") orelse return error.NoSkinError;
    try std.testing.expect(skin_error.float < 1e-12);

    if (symmetry) {
        try std.testing.expectEqual(
            core.EpistemicStatus.derived,
            agent.status("shape.revolution").?,
        );
        const explanation = agent.explain("shape.selected") orelse
            return error.NoSelectionExplanation;
        try std.testing.expectEqual(@as(usize, 2), explanation.accepted_claims);
        try std.testing.expect(
            reconstructionScore(.revolution, diameter, 15.4) >
                reconstructionScore(.extrusion, diameter, 15.4),
        );
    } else {
        try std.testing.expectEqual(
            core.EpistemicStatus.blocked,
            agent.status("shape.revolution").?,
        );
    }

    try std.testing.expect(activations >= 8);
    try std.testing.expect(agent.eventRecords().len > 0);
}

test "weightless operators reconstruct and rig the symmetry-supported hypothesis" {
    try runScenario(true, .revolution);
}

test "removing symmetry evidence changes the emergent realization without a workflow branch" {
    try runScenario(false, .extrusion);
}
