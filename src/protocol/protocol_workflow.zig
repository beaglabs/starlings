const std = @import("std");
const message = @import("../core/message.zig");
const operator = @import("../core/operator.zig");
const provenance = @import("../provenance/provenance.zig");
const runtime = @import("../core/runtime.zig");

pub const Workflow = enum {
    observe_claim,
    query_evidence,
    proposal_accept,
    proposal_reject,
    challenge_retract,
    delegation,
};

pub const max_trace_events: usize = 16;
pub const TraceEvent = runtime.TraceEvent;

pub const Result = struct {
    workflow: Workflow,
    seed: u64,
    success: bool,
    trace: [max_trace_events]?TraceEvent,
    trace_len: usize,
};

const WorkflowRuntime = runtime.Runtime(3, 16, max_trace_events);
const coordinator_id: message.OperatorId = 1;
const worker_id: message.OperatorId = 2;
const specialist_id: message.OperatorId = 3;
const knowledge_mask: u64 = 0b1_1111;

pub fn run(workflow: Workflow, seed: u64) !Result {
    return switch (workflow) {
        .observe_claim => runObserveClaim(seed),
        .query_evidence => runQueryEvidence(seed),
        .proposal_accept => runProposal(seed, true),
        .proposal_reject => runProposal(seed, false),
        .challenge_retract => runChallenge(seed),
        .delegation => runDelegation(seed),
    };
}

fn runObserveClaim(seed: u64) !Result {
    var rt = WorkflowRuntime.init(seed);
    try rt.addOperator(.{ .id = coordinator_id, .transition = claimCollector });
    try rt.addOperator(.{ .id = worker_id, .transition = observationAnalyst });

    const payload = selectedBit(seed);
    try rt.enqueue(.{
        .sender = coordinator_id,
        .recipient = worker_id,
        .kind = .observe,
        .payload = payload,
        .causal_ref = workflowRoot(.observe_claim, seed),
    });
    try rt.run();

    const coordinator = rt.findOperator(coordinator_id).?;
    return snapshot(.observe_claim, seed, rt.operators[coordinator].state == payload, &rt);
}

fn runQueryEvidence(seed: u64) !Result {
    var rt = WorkflowRuntime.init(seed);
    try rt.addOperator(.{ .id = coordinator_id, .transition = evidenceCollector });
    try rt.addOperator(.{ .id = worker_id, .state = knowledge_mask, .transition = knowledgeResponder });

    const payload = selectedBit(seed);
    try rt.enqueue(.{
        .sender = coordinator_id,
        .recipient = worker_id,
        .kind = .query,
        .payload = payload,
        .causal_ref = workflowRoot(.query_evidence, seed),
    });
    try rt.run();

    const coordinator = rt.findOperator(coordinator_id).?;
    return snapshot(.query_evidence, seed, rt.operators[coordinator].state == payload, &rt);
}

fn runProposal(seed: u64, should_accept: bool) !Result {
    var rt = WorkflowRuntime.init(seed);
    try rt.addOperator(.{ .id = coordinator_id, .transition = decisionCollector });
    try rt.addOperator(.{ .id = worker_id, .state = knowledge_mask, .transition = proposalEvaluator });

    const payload = if (should_accept) selectedBit(seed) else (@as(u64, 1) << 8) | selectedBit(seed);
    const workflow: Workflow = if (should_accept) .proposal_accept else .proposal_reject;

    try rt.enqueue(.{
        .sender = coordinator_id,
        .recipient = worker_id,
        .kind = .propose,
        .payload = payload,
        .causal_ref = workflowRoot(workflow, seed),
    });
    try rt.run();

    const coordinator = rt.findOperator(coordinator_id).?;
    const expected_state: u64 = if (should_accept) 1 else 2;
    return snapshot(workflow, seed, rt.operators[coordinator].state == expected_state, &rt);
}

fn runChallenge(seed: u64) !Result {
    var rt = WorkflowRuntime.init(seed);
    try rt.addOperator(.{ .id = coordinator_id, .transition = retractionCollector });
    try rt.addOperator(.{ .id = worker_id, .state = knowledge_mask, .transition = challengedClaimant });

    const challenged = selectedBit(seed);
    try rt.enqueue(.{
        .sender = coordinator_id,
        .recipient = worker_id,
        .kind = .challenge,
        .payload = challenged,
        .causal_ref = workflowRoot(.challenge_retract, seed),
    });
    try rt.run();

    const coordinator = rt.findOperator(coordinator_id).?;
    const worker = rt.findOperator(worker_id).?;
    const expected_remaining = knowledge_mask & ~challenged;
    const success = rt.operators[coordinator].state == challenged and
        rt.operators[worker].state == expected_remaining;
    return snapshot(.challenge_retract, seed, success, &rt);
}

fn runDelegation(seed: u64) !Result {
    var rt = WorkflowRuntime.init(seed);
    try rt.addOperator(.{ .id = coordinator_id, .transition = evidenceCollector });
    try rt.addOperator(.{ .id = worker_id, .transition = delegatingWorker });
    try rt.addOperator(.{ .id = specialist_id, .state = knowledge_mask, .transition = knowledgeResponder });

    const payload = selectedBit(seed);
    try rt.enqueue(.{
        .sender = coordinator_id,
        .recipient = worker_id,
        .kind = .delegate,
        .payload = payload,
        .causal_ref = workflowRoot(.delegation, seed),
    });
    try rt.run();

    const coordinator = rt.findOperator(coordinator_id).?;
    return snapshot(.delegation, seed, rt.operators[coordinator].state == payload, &rt);
}

fn observationAnalyst(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .observe) return .{ .state = state };
    return .{
        .state = state | input.payload,
        .emission = .{
            .sender = input.recipient,
            .recipient = input.sender,
            .kind = .claim,
            .payload = input.payload,
            .causal_ref = input.causal_ref,
        },
    };
}

fn claimCollector(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .claim) return .{ .state = state };
    return .{ .state = state | input.payload };
}

fn knowledgeResponder(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .query) return .{ .state = state };
    return .{
        .state = state,
        .emission = .{
            .sender = input.recipient,
            .recipient = input.sender,
            .kind = .evidence,
            .payload = state & input.payload,
            .causal_ref = input.causal_ref,
        },
    };
}

fn evidenceCollector(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .evidence) return .{ .state = state };
    return .{ .state = state | input.payload };
}

fn proposalEvaluator(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .propose) return .{ .state = state };
    const accepted = (input.payload & ~state) == 0;
    return .{
        .state = state,
        .emission = .{
            .sender = input.recipient,
            .recipient = input.sender,
            .kind = if (accepted) .accept else .reject,
            .payload = input.payload,
            .causal_ref = input.causal_ref,
        },
    };
}

fn decisionCollector(state: u64, input: message.Message) operator.Transition {
    return switch (input.kind) {
        .accept => .{ .state = 1 },
        .reject => .{ .state = 2 },
        else => .{ .state = state },
    };
}

fn challengedClaimant(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .challenge) return .{ .state = state };
    const challenged = state & input.payload;
    if (challenged == 0) return .{ .state = state };
    return .{
        .state = state & ~challenged,
        .emission = .{
            .sender = input.recipient,
            .recipient = input.sender,
            .kind = .retract,
            .payload = challenged,
            .causal_ref = input.causal_ref,
        },
    };
}

fn retractionCollector(state: u64, input: message.Message) operator.Transition {
    if (input.kind != .retract) return .{ .state = state };
    return .{ .state = state | input.payload };
}

fn delegatingWorker(state: u64, input: message.Message) operator.Transition {
    return switch (input.kind) {
        .delegate => .{
            .state = state,
            .emission = .{
                .sender = worker_id,
                .recipient = specialist_id,
                .kind = .query,
                .payload = input.payload,
                .causal_ref = input.causal_ref,
            },
        },
        .evidence => .{
            .state = state | input.payload,
            .emission = .{
                .sender = worker_id,
                .recipient = coordinator_id,
                .kind = .evidence,
                .payload = input.payload,
                .causal_ref = input.causal_ref,
            },
        },
        else => .{ .state = state },
    };
}

fn selectedBit(seed: u64) u64 {
    const shift: u6 = @intCast(seed % 5);
    return @as(u64, 1) << shift;
}

fn workflowRoot(workflow: Workflow, seed: u64) message.ContentId {
    const tag = @as(u64, @intFromEnum(workflow)) << 56;
    return provenance.contentId(.{
        .kind = .observe,
        .payload = seed ^ tag,
    });
}

fn snapshot(workflow: Workflow, seed: u64, success: bool, rt: *const WorkflowRuntime) Result {
    var trace = [_]?TraceEvent{null} ** max_trace_events;
    var i: usize = 0;
    while (i < rt.trace_len) : (i += 1) {
        trace[i] = rt.trace[i];
    }
    return .{
        .workflow = workflow,
        .seed = seed,
        .success = success,
        .trace = trace,
        .trace_len = rt.trace_len,
    };
}

fn expectKinds(result: Result, expected: []const message.Kind) !void {
    try std.testing.expectEqual(expected.len, result.trace_len);
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        try std.testing.expectEqual(expected[i], result.trace[i].?.message.kind);
    }
}

test "deterministic workflows exercise natural protocol sequences" {
    const observe = try run(.observe_claim, 1);
    try std.testing.expect(observe.success);
    try expectKinds(observe, &.{ .observe, .claim });

    const query = try run(.query_evidence, 2);
    try std.testing.expect(query.success);
    try expectKinds(query, &.{ .query, .evidence });

    const accept = try run(.proposal_accept, 3);
    try std.testing.expect(accept.success);
    try expectKinds(accept, &.{ .propose, .accept });

    const reject = try run(.proposal_reject, 4);
    try std.testing.expect(reject.success);
    try expectKinds(reject, &.{ .propose, .reject });

    const challenge = try run(.challenge_retract, 5);
    try std.testing.expect(challenge.success);
    try expectKinds(challenge, &.{ .challenge, .retract });

    const delegation = try run(.delegation, 6);
    try std.testing.expect(delegation.success);
    try expectKinds(delegation, &.{ .delegate, .query, .evidence, .evidence });
}

test "workflow suite covers the complete typed message vocabulary" {
    const kind_count: usize = @typeInfo(message.Kind).@"enum".fields.len;
    var seen = [_]bool{false} ** kind_count;

    inline for (.{
        Workflow.observe_claim,
        Workflow.query_evidence,
        Workflow.proposal_accept,
        Workflow.proposal_reject,
        Workflow.challenge_retract,
        Workflow.delegation,
    }) |workflow| {
        const result = try run(workflow, 11);
        try std.testing.expect(result.success);
        var i: usize = 0;
        while (i < result.trace_len) : (i += 1) {
            seen[@intFromEnum(result.trace[i].?.message.kind)] = true;
        }
    }

    for (seen) |present| {
        try std.testing.expect(present);
    }
}

test "workflow traces are reproducible and seed-sensitive" {
    const a = try run(.query_evidence, 1);
    const b = try run(.query_evidence, 1);
    const c = try run(.query_evidence, 2);
    try std.testing.expectEqualDeep(a, b);
    try std.testing.expect(a.trace[0].?.message.payload != c.trace[0].?.message.payload);
}
