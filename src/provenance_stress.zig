const std = @import("std");
const provenance = @import("provenance.zig");

pub const StressResult = struct {
    append_records: usize,
    dag_nodes: usize,
    duplicate_savings: usize,
    replay_equal: bool,
    causal_nodes: usize,
    reconciliation_missing: usize,
    tamper_detected: bool,
};

pub fn runDuplicateHeavy() !StressResult {
    var log = provenance.AppendLog(256){};
    var dag = provenance.MerkleDag(256){};

    const root_event: provenance.Event = .{ .kind = .observe, .payload = 1 };
    const root = try dag.insert(root_event);
    _ = try log.append(root_event);

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const repeated: provenance.Event = .{
            .kind = .claim,
            .payload = 2,
            .parents = .{ root.id, 0 },
            .parent_count = 1,
        };
        _ = try log.append(repeated);
        _ = try dag.insert(repeated);
    }

    return .{
        .append_records = log.len,
        .dag_nodes = dag.len,
        .duplicate_savings = log.len - dag.len,
        .replay_equal = log.replayUnion() == dag.replayUnion(),
        .causal_nodes = try dag.ancestorCount(provenance.contentId(.{
            .kind = .claim,
            .payload = 2,
            .parents = .{ root.id, 0 },
            .parent_count = 1,
        })),
        .reconciliation_missing = 0,
        .tamper_detected = false,
    };
}

pub fn runForkMerge() !StressResult {
    var log = provenance.AppendLog(256){};
    var dag = provenance.MerkleDag(256){};

    const root_event: provenance.Event = .{ .kind = .observe, .payload = 1 };
    const root = try dag.insert(root_event);
    _ = try log.append(root_event);

    const left_event: provenance.Event = .{ .kind = .claim, .payload = 2, .parents = .{ root.id, 0 }, .parent_count = 1 };
    const right_event: provenance.Event = .{ .kind = .claim, .payload = 4, .parents = .{ root.id, 0 }, .parent_count = 1 };
    const left = try dag.insert(left_event);
    const right = try dag.insert(right_event);
    _ = try log.append(left_event);
    _ = try log.append(right_event);

    const merge_event: provenance.Event = .{ .kind = .decision, .payload = 8, .parents = .{ left.id, right.id }, .parent_count = 2 };
    const merged = try dag.insert(merge_event);
    _ = try log.append(merge_event);

    return .{
        .append_records = log.len,
        .dag_nodes = dag.len,
        .duplicate_savings = log.len - dag.len,
        .replay_equal = log.replayUnion() == dag.replayUnion(),
        .causal_nodes = try dag.ancestorCount(merged.id),
        .reconciliation_missing = 0,
        .tamper_detected = false,
    };
}

pub fn runReplicaDivergence() !StressResult {
    var remote = provenance.MerkleDag(256){};
    var local = provenance.MerkleDag(256){};

    const root_event: provenance.Event = .{ .kind = .observe, .payload = 1 };
    const remote_root = try remote.insert(root_event);
    const local_root = try local.insert(root_event);
    try std.testing.expectEqual(remote_root.id, local_root.id);

    const shared_event: provenance.Event = .{ .kind = .claim, .payload = 2, .parents = .{ remote_root.id, 0 }, .parent_count = 1 };
    _ = try remote.insert(shared_event);
    _ = try local.insert(shared_event);

    const remote_only_a: provenance.Event = .{ .kind = .claim, .payload = 4, .parents = .{ remote_root.id, 0 }, .parent_count = 1 };
    const remote_only_b: provenance.Event = .{ .kind = .evidence, .payload = 8, .parents = .{ remote_root.id, 0 }, .parent_count = 1 };
    _ = try remote.insert(remote_only_a);
    _ = try remote.insert(remote_only_b);

    return .{
        .append_records = remote.len,
        .dag_nodes = local.len,
        .duplicate_savings = 0,
        .replay_equal = false,
        .causal_nodes = 0,
        .reconciliation_missing = remote.missingCount(&local),
        .tamper_detected = false,
    };
}

pub fn runTamperCheck() !StressResult {
    var dag = provenance.MerkleDag(16){};
    const original: provenance.Event = .{ .kind = .observe, .payload = 1 };
    const inserted = try dag.insert(original);

    const tampered: provenance.Event = .{ .kind = .observe, .payload = 3 };
    const tampered_id = provenance.contentId(tampered);

    return .{
        .append_records = 1,
        .dag_nodes = dag.len,
        .duplicate_savings = 0,
        .replay_equal = true,
        .causal_nodes = 1,
        .reconciliation_missing = 0,
        .tamper_detected = inserted.id != tampered_id,
    };
}

test "duplicate-heavy history strongly favors content-addressed storage" {
    const result = try runDuplicateHeavy();
    try std.testing.expect(result.replay_equal);
    try std.testing.expectEqual(@as(usize, 65), result.append_records);
    try std.testing.expectEqual(@as(usize, 2), result.dag_nodes);
    try std.testing.expectEqual(@as(usize, 63), result.duplicate_savings);
    try std.testing.expectEqual(@as(usize, 2), result.causal_nodes);
}

test "fork and merge causal graph reconstructs full closure" {
    const result = try runForkMerge();
    try std.testing.expect(result.replay_equal);
    try std.testing.expectEqual(@as(usize, 4), result.causal_nodes);
}

test "divergent replicas expose exact missing content count" {
    const result = try runReplicaDivergence();
    try std.testing.expectEqual(@as(usize, 2), result.reconciliation_missing);
}

test "content identity changes when payload is tampered" {
    const result = try runTamperCheck();
    try std.testing.expect(result.tamper_detected);
}
