const std = @import("std");
const core = @import("core_types.zig");
const reg = @import("registry.zig");
const eligibility = @import("eligibility.zig");
const output_state = @import("output_state.zig");
const execution = @import("execution.zig");
const external = @import("external.zig");
const process_supervisor = @import("process_supervisor.zig");
const content_id = @import("../core/content_id.zig");

test "generated acyclic dependency graphs reach closure independent of registration order" {
    const variable_count: usize = 10;
    const operator_count: usize = variable_count - 1;
    const R = reg.Registry(variable_count, 0, operator_count);
    const S = reg.ContextState(variable_count, 0);

    var registry = R{};
    var state = S{};

    var i: usize = 0;
    while (i < variable_count) : (i += 1) {
        try registry.addVariable(.{ .variable = .{
            .id = @intCast(i + 1),
            .name = "generated",
            .kind = .integer,
        } });
    }

    var requires: [operator_count][1]core.VariableId = undefined;
    var provides: [operator_count][1]core.VariableId = undefined;
    var order: [operator_count]usize = undefined;

    var rng: u64 = 0x7a11_1e57_5eed;
    i = 0;
    while (i < operator_count) : (i += 1) {
        const output_index = i + 1;
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        const predecessor: usize = @intCast(rng % output_index);

        requires[i][0] = @intCast(predecessor + 1);
        provides[i][0] = @intCast(output_index + 1);
        order[i] = i;
    }

    i = operator_count;
    while (i > 1) {
        i -= 1;
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        const j: usize = @intCast(rng % (i + 1));
        const tmp = order[i];
        order[i] = order[j];
        order[j] = tmp;
    }

    for (order) |op_index| {
        try registry.addOperator(.{
            .manifest = .{
                .id = @intCast(100 + op_index),
                .name = "generated-op",
                .requires_variables = requires[op_index][0..],
                .provides_variables = provides[op_index][0..],
            },
        });
    }

    try state.setVariable(&registry, 1, .observed, .{ .integer = 1 }, 0);

    var resolved: usize = 1;
    var round: u32 = 1;
    while (resolved < variable_count and round < 64) : (round += 1) {
        var ids: [operator_count]core.OperatorId = undefined;
        const count = try eligibility.eligibleOperators(&registry, &state, round, &ids);

        var progressed = false;
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const index = registry.operatorIndex(ids[k]).?;
            const output_id = registry.operators[index].manifest.provides_variables[0];
            const output_index = registry.variableIndex(output_id).?;
            if (state.variables[output_index].status.isResolved()) continue;
            try state.setVariable(
                &registry,
                output_id,
                .derived,
                .{ .integer = @intCast(output_id) },
                round,
            );
            resolved += 1;
            progressed = true;
        }
        try std.testing.expect(progressed);
    }

    try std.testing.expectEqual(variable_count, resolved);
}

test "same seed and context replay to identical canonical claim sequence" {
    const R = execution.Runner(3, 0, 3, 16);

    const Ops = struct {
        fn first(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = obs.value(1).?.integer + 5 },
                .source_operator = 10,
            });
            return out;
        }

        fn second(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 3,
                .status = .derived,
                .value = .{ .integer = obs.value(2).?.integer * 3 },
                .source_operator = 11,
            });
            return out;
        }
    };

    var a = R.init(51, &.{3});
    var b = R.init(51, &.{3});

    try setupReplayRunner(R, &a, Ops.first, Ops.second);
    try setupReplayRunner(R, &b, Ops.first, Ops.second);

    const ar = try a.run(8);
    const br = try b.run(8);
    try std.testing.expectEqual(core.ResultOutcome.success, ar.summary.outcome);
    try std.testing.expectEqual(core.ResultOutcome.success, br.summary.outcome);
    try std.testing.expectEqual(a.claims.len, b.claims.len);

    var i: usize = 0;
    while (i < a.claims.len) : (i += 1) {
        try std.testing.expect(content_id.eql(a.claims.records[i].id, b.claims.records[i].id));
    }
}

fn setupReplayRunner(
    comptime R: type,
    runner: *R,
    first: R.ExecuteFn,
    second: R.ExecuteFn,
) !void {
    try runner.addVariable(.{ .variable = .{ .id = 1, .name = "input", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 2, .name = "middle", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 3, .name = "target", .kind = .integer } });
    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "first",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, null, first);
    try runner.addOperator(.{ .manifest = .{
        .id = 11,
        .name = "second",
        .requires_variables = &.{2},
        .provides_variables = &.{3},
    } }, null, second);
    _ = try runner.seedVariable(1, .observed, .{ .integer = 7 }, 1000);
}

test "malformed external outputs fail closed" {
    try std.testing.expectError(error.InvalidWireHeader, external.parseResponse("nope\n"));
    try std.testing.expectError(
        error.InvalidWireValue,
        external.parseResponse(
            "STARLINGS/1 RESPONSE\n" ++
            "claim=1,99,1000,7,i:1\n" ++
            "END\n",
        ),
    );
    try std.testing.expectError(
        error.MissingWireEnd,
        external.parseResponse(
            "STARLINGS/1 RESPONSE\n" ++
            "claim=1,3,1000,7,i:1\n",
        ),
    );
}

test "external crashes and timeouts remain explicit transport failures" {
    const Crash = struct {
        fn invoke(
            _: ?*anyopaque,
            _: external.Invocation,
            _: []const u8,
            _: []u8,
        ) ![]const u8 {
            return error.OperatorCrashed;
        }
    };
    const Timeout = struct {
        fn invoke(
            _: ?*anyopaque,
            _: external.Invocation,
            _: []const u8,
            _: []u8,
        ) ![]const u8 {
            return error.OperatorTimeout;
        }
    };

    var request_buffer: [128]u8 = undefined;
    const request = try external.buildRequest(1, 0, &.{}, &request_buffer);
    var response_buffer: [128]u8 = undefined;

    const crashed = external.ExternalOperator{
        .invocation = .{ .subprocess = .{ .argv = &.{"fixture"} } },
        .transport = .{ .invoke_fn = Crash.invoke },
    };
    try std.testing.expectError(error.OperatorCrashed, crashed.invoke(request, &response_buffer));

    const timed_out = external.ExternalOperator{
        .invocation = .{ .python = .{ .target = "fixture.py", .timeout_ms = 1 } },
        .transport = .{ .invoke_fn = Timeout.invoke },
    };
    try std.testing.expectError(error.OperatorTimeout, timed_out.invoke(request, &response_buffer));
}

test "stale contextual variables stop satisfying eligibility" {
    const R = reg.Registry(2, 0, 1);
    const S = reg.ContextState(2, 0);
    var registry = R{};
    var state = S{};

    try registry.addVariable(.{
        .variable = .{ .id = 1, .name = "sensor", .kind = .integer },
        .freshness_rounds = 1,
    });
    try registry.addVariable(.{ .variable = .{ .id = 2, .name = "out", .kind = .integer } });
    try registry.addOperator(.{ .manifest = .{
        .id = 1,
        .name = "consumer",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } });

    try state.setVariable(&registry, 1, .observed, .{ .integer = 9 }, 3);
    try std.testing.expect(eligibility.operatorEligible(&registry, &state, 0, 4));
    try std.testing.expect(!eligibility.operatorEligible(&registry, &state, 0, 5));
}

test "conflicting evidence survives end to end and blocks unsupported resolution" {
    const R = execution.Runner(4, 0, 4, 16);
    var runner = R.init(3, &.{4});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "height",
        .kind = .float,
        .merge_policy = .retain_all_conflict,
    } });
    try runner.addVariable(.{ .variable = .{ .id = 2, .name = "a_done", .kind = .boolean } });
    try runner.addVariable(.{ .variable = .{ .id = 3, .name = "b_done", .kind = .boolean } });
    try runner.addVariable(.{ .variable = .{ .id = 4, .name = "resolved", .kind = .boolean } });

    const height_term = [_]reg.DependencyTerm{.{ .variable_resolved = 1 }};

    const Ops = struct {
        fn a(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .estimated,
                .value = .{ .float = 30.7 },
                .source_operator = 10,
            });
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .boolean = true },
                .source_operator = 10,
            });
            return out;
        }

        fn b(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .estimated,
                .value = .{ .float = 47.9 },
                .source_operator = 11,
            });
            try out.addClaim(.{
                .variable = 3,
                .status = .derived,
                .value = .{ .boolean = true },
                .source_operator = 11,
            });
            return out;
        }

        fn resolve(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            if (obs.status(1) == .conflicting) {
                try out.addClaim(.{
                    .variable = 4,
                    .status = .blocked,
                    .source_operator = 12,
                });
            } else {
                try out.addClaim(.{
                    .variable = 4,
                    .status = .derived,
                    .value = .{ .boolean = true },
                    .source_operator = 12,
                });
            }
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10, .name = "measure-a", .provides_variables = &.{ 1, 2 },
    } }, null, Ops.a);
    try runner.addOperator(.{ .manifest = .{
        .id = 11, .name = "measure-b", .provides_variables = &.{ 1, 3 },
    } }, null, Ops.b);
    try runner.addOperator(.{
        .manifest = .{
            .id = 12,
            .name = "resolve",
            .requires_variables = &.{ 2, 3 },
            .provides_variables = &.{4},
        },
        .eligibility = .{ .mode = .all, .terms = &height_term },
    }, null, Ops.resolve);

    const result = try runner.run(8);
    try std.testing.expectEqual(core.ResultOutcome.blocked, result.summary.outcome);
    try std.testing.expectEqual(core.EpistemicStatus.conflicting, result.status(1).?);
    try std.testing.expectEqual(core.EpistemicStatus.blocked, result.status(4).?);
    try std.testing.expectEqual(@as(usize, 1), result.explain(1).?.conflict_count);
}

test "heterogeneous native external deterministic operators compose through one state model" {
    const R = execution.Runner(4, 0, 4, 24);
    var runner = R.init(99, &.{4});

    try runner.addVariable(.{ .variable = .{ .id = 1, .name = "raw", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 2, .name = "normalized", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 3, .name = "external", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 4, .name = "target", .kind = .integer } });

    const Fixture = struct {
        fn native(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = obs.value(1).?.integer * 2 },
                .source_operator = 10,
            });
            return out;
        }

        fn transport(
            _: ?*anyopaque,
            _: external.Invocation,
            request: []const u8,
            response_buffer: []u8,
        ) ![]const u8 {
            try std.testing.expect(std.mem.indexOf(u8, request, "var=2,3,i:20") != null);
            const response =
                "STARLINGS/1 RESPONSE\n" ++
                "operator=20\n" ++
                "claim=3,3,1000,20,i:30\n" ++
                "END\n";
            @memcpy(response_buffer[0..response.len], response);
            return response_buffer[0..response.len];
        }

        fn externalRun(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            const observations = [_]external.WireObservation{
                .{ .variable = 2, .status = obs.status(2).?, .value = obs.value(2) },
            };
            var request_buffer: [256]u8 = undefined;
            const request = try external.buildRequest(20, obs.round(), &observations, &request_buffer);
            var response_buffer: [256]u8 = undefined;
            const adapter = external.ExternalOperator{
                .invocation = .{ .python = .{ .target = "fixture.py" } },
                .transport = .{ .invoke_fn = transport },
            };
            return adapter.invoke(request, &response_buffer);
        }

        fn solver(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 4,
                .status = .derived,
                .value = .{ .integer = obs.value(3).?.integer * 2 },
                .source_operator = 30,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10, .name = "native-normalizer",
        .requires_variables = &.{1}, .provides_variables = &.{2},
    } }, null, Fixture.native);
    try runner.addOperator(.{ .manifest = .{
        .id = 20, .name = "python-boundary",
        .requires_variables = &.{2}, .provides_variables = &.{3},
    } }, null, Fixture.externalRun);
    try runner.addOperator(.{ .manifest = .{
        .id = 30, .name = "deterministic-solver",
        .requires_variables = &.{3}, .provides_variables = &.{4},
    } }, null, Fixture.solver);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 10 }, 1000);
    const result = try runner.run(12);
    try std.testing.expectEqual(core.ResultOutcome.success, result.summary.outcome);
    try std.testing.expect(core.Value.eql(result.value(4).?, .{ .integer = 60 }));
}

test "native and external adapters produce identical canonical claim identities" {
    const native: core.Claim = .{
        .variable = 7,
        .status = .derived,
        .value = .{ .integer = 42 },
        .confidence_permille = 950,
        .source_operator = 9,
    };
    const parsed = try external.parseResponse(
        "STARLINGS/1 RESPONSE\n" ++
        "operator=9\n" ++
        "claim=7,3,950,9,i:42\n" ++
        "END\n",
    );
    const external_claim = parsed.variable_claims[0];

    try std.testing.expect(content_id.eql(
        output_state.claimContentId(native),
        output_state.claimContentId(external_claim),
    ));
}


test "runner executes a real supervised subprocess operator" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const R = execution.Runner(2, 0, 1, 16);
    const Buffered = external.BufferedExternalOperator(1024, 1024);

    var supervisor = process_supervisor.Supervisor{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    defer supervisor.deinit();

    const Context = struct {
        buffered: Buffered,

        fn execute(
            raw_context: ?*const anyopaque,
            obs: R.Observation,
        ) !core.OperatorOutput {
            const opaque_context = raw_context orelse return error.MissingExternalOperatorContext;
            const self: *@This() = @constCast(@ptrCast(@alignCast(opaque_context)));
            const observations = [_]external.WireObservation{
                .{
                    .variable = 1,
                    .status = obs.status(1).?,
                    .value = obs.value(1),
                },
            };
            return self.buffered.invoke(obs.round(), &observations);
        }
    };

    var context = Context{
        .buffered = .{
            .operator_id = 20,
            .external = .{
                .invocation = .{ .subprocess = .{
                    .argv = &.{
                        "/bin/sh",
                        "-c",
                        "cat >/dev/null; printf '%s\\n' 'STARLINGS/1 RESPONSE' 'operator=20' 'claim=2,3,1000,20,i:42' 'action=publish-result,1,case-7' 'END'",
                    },
                    .timeout_ms = 1000,
                } },
                .transport = supervisor.transport(),
            },
        },
    };

    var runner = R.init(91, &.{2});
    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
    } });
    try runner.addVariable(.{ .variable = .{
        .id = 2,
        .name = "external-result",
        .kind = .integer,
    } });
    try runner.addOperator(.{ .manifest = .{
        .id = 20,
        .name = "supervised-subprocess",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, &context, Context.execute);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 7 }, 1000);
    const result = try runner.runUntilQuiescent(4);

    try std.testing.expectEqual(core.ResultOutcome.success, result.summary.outcome);
    try std.testing.expect(core.Value.eql(result.value(2).?, .{ .integer = 42 }));
    try std.testing.expectEqual(@as(usize, 1), runner.actionProposalCount());
    try std.testing.expectEqual(@as(usize, 1), runner.pendingApprovalCount());
}
