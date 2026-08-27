const std = @import("std");
const provenance = @import("provenance.zig");

pub const ValidationResult = struct {
    append_records: usize,
    dag_nodes: usize,
    deduplicated_records: usize,
    append_replay: u64,
    dag_replay: u64,
    causal_ancestors: usize,
    reconciliation_missing: usize,
};

pub fn run() !ValidationResult {
    var log = provenance.AppendLog(32){};
    var dag = provenance.MerkleDag(32){};

    const observe_a: provenance.Event = .{ .kind = .observe, .payload = 0b00001 };
    const observe_b: provenance.Event = .{ .kind = .observe, .payload = 0b00010 };

    _ = try log.append(observe_a);
    _ = try log.append(observe_a);
    _ = try log.append(observe_b);

    const a = try dag.insert(observe_a);
    _ = try dag.insert(observe_a);
    const b = try dag.insert(observe_b);

    const claim: provenance.Event = .{
        .kind = .claim,
        .payload = 0b00100,
        .parents = .{ a.id, b.id },
        .parent_count = 2,
    };

    _ = try log.append(claim);
    _ = try log.append(claim);

    const claim_node = try dag.insert(claim);
    _ = try dag.insert(claim);

    const decision: provenance.Event = .{
        .kind = .decision,
        .payload = 0b01000,
        .parents = .{ claim_node.id, provenance.zero_id },
        .parent_count = 1,
    };

    _ = try log.append(decision);
    const decision_node = try dag.insert(decision);

    var partial = provenance.MerkleDag(32){};
    _ = try partial.insert(observe_a);
    _ = try partial.insert(observe_b);

    return .{
        .append_records = log.len,
        .dag_nodes = dag.len,
        .deduplicated_records = log.len - dag.len,
        .append_replay = log.replayUnion(),
        .dag_replay = dag.replayUnion(),
        .causal_ancestors = try dag.ancestorCount(decision_node.id),
        .reconciliation_missing = dag.missingCount(&partial),
    };
}

test "merkle validation demonstrates deduplication without replay divergence" {
    const result = try run();
    try std.testing.expectEqual(@as(usize, 6), result.append_records);
    try std.testing.expectEqual(@as(usize, 4), result.dag_nodes);
    try std.testing.expectEqual(@as(usize, 2), result.deduplicated_records);
    try std.testing.expectEqual(result.append_replay, result.dag_replay);
}

test "merkle validation reconstructs causal closure" {
    const result = try run();
    try std.testing.expectEqual(@as(usize, 4), result.causal_ancestors);
}

test "merkle validation isolates reconciliation delta" {
    const result = try run();
    try std.testing.expectEqual(@as(usize, 2), result.reconciliation_missing);
}
