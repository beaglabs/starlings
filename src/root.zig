const std = @import("std");

pub const content_id = @import("core/content_id.zig");
pub const message = @import("core/message.zig");
pub const operator = @import("core/operator.zig");
pub const runtime = @import("core/runtime.zig");
pub const rng = @import("core/rng.zig");
pub const benchmark = @import("core/benchmark.zig");
pub const provenance = @import("provenance/provenance.zig");
pub const provenance_validation = @import("provenance/provenance_validation.zig");
pub const provenance_stress = @import("provenance/provenance_stress.zig");
pub const protocol_workflow = @import("protocol/protocol_workflow.zig");
pub const protocol_trace = @import("protocol/protocol_trace.zig");
pub const protocol_cfg = @import("protocol/protocol_cfg.zig");
pub const protocol_cfg_stress = @import("protocol/protocol_cfg_stress.zig");
pub const protocol_model_eval = @import("protocol/protocol_model_eval.zig");
pub const protocol_model_record = @import("protocol/protocol_model_record.zig");
pub const protocol_model_summary = @import("protocol/protocol_model_summary.zig");
pub const stage3e1_summary = @import("experiments/stage3/stage3e1_summary.zig");
pub const distributed_fact_convergence = @import("experiments/stage3/distributed_fact_convergence.zig");
pub const stage3f0_summary = @import("experiments/stage3/stage3f0_summary.zig");
pub const distributed_fact_efficiency = @import("experiments/stage3/distributed_fact_efficiency.zig");
pub const stage3f1_summary = @import("experiments/stage3/stage3f1_summary.zig");
pub const formal_population = @import("core/formal_population.zig");
pub const stage4_population_experiment = @import("experiments/stage4/stage4_population_experiment.zig");
pub const stage4_cli = @import("experiments/stage4/stage4_cli.zig");
pub const stage5a_scaling = @import("experiments/stage5/stage5a_scaling.zig");
pub const stage5a_cli = @import("experiments/stage5/stage5a_cli.zig");
pub const stage5a_summary = @import("experiments/stage5/stage5a_summary.zig");
pub const stage5b_predictive = @import("experiments/stage5/stage5b_predictive.zig");
pub const stage5b_cli = @import("experiments/stage5/stage5b_cli.zig");
pub const stage5c_regimes = @import("experiments/stage5/stage5c_regimes.zig");
pub const stage5c_summary = @import("experiments/stage5/stage5c_summary.zig");
pub const stage5c_cli = @import("experiments/stage5/stage5c_cli.zig");
pub const stage6_perturbation = @import("experiments/stage6/stage6_perturbation.zig");
pub const stage6_summary = @import("experiments/stage6/stage6_summary.zig");
pub const stage6_cli = @import("experiments/stage6/stage6_cli.zig");
pub const stage6_1_robustness_law = @import("experiments/stage6/stage6_1_robustness_law.zig");
pub const stage6_1_cli = @import("experiments/stage6/stage6_1_cli.zig");
pub const stage7a_policy = @import("experiments/stage7/stage7a_policy.zig");
pub const stage7a_cli = @import("experiments/stage7/stage7a_cli.zig");
pub const stage7b_search = @import("experiments/stage7/stage7b_search.zig");
pub const stage7b_cli = @import("experiments/stage7/stage7b_cli.zig");
pub const transport = @import("transport/transport.zig");


test {
    _ = content_id;
    _ = benchmark;
    _ = provenance;
    _ = provenance_validation;
    _ = provenance_stress;
    _ = protocol_workflow;
    _ = protocol_trace;
    _ = protocol_cfg;
    _ = protocol_cfg_stress;
    _ = protocol_model_eval;
    _ = protocol_model_record;
    _ = protocol_model_summary;
    _ = stage3e1_summary;
    _ = distributed_fact_convergence;
    _ = stage3f0_summary;
    _ = distributed_fact_efficiency;
    _ = stage3f1_summary;
    _ = formal_population;
    _ = stage4_population_experiment;
    _ = stage4_cli;
    _ = stage5a_scaling;
    _ = stage5a_cli;
    _ = stage5a_summary;
    _ = stage5b_predictive;
    _ = stage5b_cli;
    _ = stage5c_regimes;
    _ = stage5c_summary;
    _ = stage5c_cli;
    _ = stage6_perturbation;
    _ = stage6_summary;
    _ = stage6_cli;
    _ = stage6_1_robustness_law;
    _ = stage6_1_cli;
    _ = stage7a_policy;
    _ = stage7a_cli;
    _ = stage7b_search;
    _ = stage7b_cli;
    _ = transport;
}

test "messages route deterministically and update operator state" {
    const TestRuntime = runtime.Runtime(8, 32, 32);
    var rt = TestRuntime.init(42);

    try rt.addOperator(.{ .id = 1, .transition = operator.echo });
    try rt.addOperator(.{ .id = 2, .transition = operator.accumulator });

    var causal = content_id.zero;
    causal[0] = 99;

    try rt.enqueue(.{
        .sender = 2,
        .recipient = 1,
        .kind = .query,
        .payload = 7,
        .causal_ref = causal,
    });
    try rt.run();

    try std.testing.expectEqual(@as(u64, 1), rt.operators[0].state);
    try std.testing.expectEqual(@as(u64, 7), rt.operators[1].state);
    try std.testing.expectEqual(@as(usize, 2), rt.trace_len);
    try std.testing.expectEqual(@as(u64, 1), rt.trace[0].sequence);
    try std.testing.expectEqual(@as(u64, 2), rt.trace[1].sequence);
    try std.testing.expectEqual(message.Kind.evidence, rt.trace[1].message.kind);
    try std.testing.expect(rt.trace[1].message.causal_ref != null);
    try std.testing.expect(content_id.eql(causal, rt.trace[1].message.causal_ref.?));
}

test "same seed produces the same experimental entropy" {
    const TestRuntime = runtime.Runtime(1, 1, 1);
    var a = TestRuntime.init(0x5eed);
    var b = TestRuntime.init(0x5eed);

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(a.randomIndex(17), b.randomIndex(17));
    }
}

test "different seeds diverge" {
    const TestRuntime = runtime.Runtime(1, 1, 1);
    var a = TestRuntime.init(1);
    var b = TestRuntime.init(2);

    var different = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (a.randomIndex(1024) != b.randomIndex(1024)) different = true;
    }
    try std.testing.expect(different);
}

test "duplicate operators are rejected" {
    const TestRuntime = runtime.Runtime(2, 1, 1);
    var rt = TestRuntime.init(0);
    const op: operator.Operator = .{ .id = 7, .transition = operator.accumulator };
    try rt.addOperator(op);
    try std.testing.expectError(error.DuplicateOperator, rt.addOperator(op));
}

test "unknown recipients fail explicitly" {
    const TestRuntime = runtime.Runtime(1, 2, 2);
    var rt = TestRuntime.init(0);
    try rt.enqueue(.{ .sender = 1, .recipient = 999, .kind = .claim });
    try std.testing.expectError(error.UnknownRecipient, rt.step());
}
