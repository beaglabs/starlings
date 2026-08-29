const std = @import("std");

pub const worker_count: usize = 5;
pub const fact_count: usize = 5;
pub const collector_index: usize = 0;
pub const full_mask: u8 = (1 << fact_count) - 1;

pub const ActionKind = enum {
    claim,
    query_evidence,
};

pub const Action = struct {
    kind: ActionKind,
    facts: u8,
};

pub const RoundMetrics = struct {
    semantic_violations: usize = 0,
    network_messages: usize = 0,
    useful_fact_deliveries: usize = 0,
    duplicate_fact_transmissions: usize = 0,

    pub fn add(self: *RoundMetrics, other: RoundMetrics) void {
        self.semantic_violations += other.semantic_violations;
        self.network_messages += other.network_messages;
        self.useful_fact_deliveries += other.useful_fact_deliveries;
        self.duplicate_fact_transmissions += other.duplicate_fact_transmissions;
    }
};

pub fn initialKnowledge(seed: u64) [worker_count]u8 {
    const offset: usize = @intCast(seed % fact_count);
    var result = [_]u8{0} ** worker_count;

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const first = (i + offset) % fact_count;
        const second = (i + 1 + offset) % fact_count;
        result[i] = factBit(first) | factBit(second);
    }
    return result;
}

pub fn generationSeed(sampling_seed: u64, round: u32, worker: u8) u32 {
    const mixed = sampling_seed *% 1_000_003 +%
        @as(u64, round) *% 101 +%
        @as(u64, worker);
    return @intCast(mixed & 0x7fff_ffff);
}

pub fn collectorSolved(knowledge: [worker_count]u8) bool {
    return knowledge[collector_index] == full_mask;
}

pub fn parseAction(text: []const u8) !Action {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAction;

    var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const first = tokens.next() orelse return error.InvalidAction;

    if (std.mem.eql(u8, first, "CLAIM")) {
        const facts_text = tokens.next() orelse return error.InvalidAction;
        if (tokens.next() != null) return error.InvalidAction;
        return .{ .kind = .claim, .facts = try parseFactList(facts_text) };
    }

    if (std.mem.eql(u8, first, "QUERY")) {
        const second = tokens.next() orelse return error.InvalidAction;
        if (!std.mem.eql(u8, second, "EVIDENCE")) return error.InvalidAction;
        const fact_text = tokens.next() orelse return error.InvalidAction;
        if (tokens.next() != null) return error.InvalidAction;
        return .{ .kind = .query_evidence, .facts = try parseSingleFact(fact_text) };
    }

    return error.InvalidAction;
}

pub fn applyRound(
    knowledge: *[worker_count]u8,
    actions: [worker_count]?Action,
) RoundMetrics {
    const snapshot = knowledge.*;
    var next = snapshot;
    var metrics = RoundMetrics{};

    var sender: usize = 0;
    while (sender < worker_count) : (sender += 1) {
        const action = actions[sender] orelse continue;

        switch (action.kind) {
            .claim => {
                if (action.facts == 0 or (action.facts & ~snapshot[sender]) != 0) {
                    metrics.semantic_violations += 1;
                    continue;
                }

                const neighbors = ringNeighbors(sender);
                for (neighbors) |recipient| {
                    metrics.network_messages += 1;
                    const unseen = action.facts & ~next[recipient];
                    const duplicate = action.facts & next[recipient];
                    metrics.useful_fact_deliveries += @as(usize, @intCast(@popCount(unseen)));
                    metrics.duplicate_fact_transmissions += @as(usize, @intCast(@popCount(duplicate)));
                    next[recipient] |= action.facts;
                }
            },
            .query_evidence => {
                const neighbors = ringNeighbors(sender);
                for (neighbors) |recipient| {
                    metrics.network_messages += 1; // QUERY
                    if ((snapshot[recipient] & action.facts) == 0) continue;

                    metrics.network_messages += 1; // EVIDENCE
                    if ((next[sender] & action.facts) == 0) {
                        metrics.useful_fact_deliveries += 1;
                    } else {
                        metrics.duplicate_fact_transmissions += 1;
                    }
                    next[sender] |= action.facts;
                }
            },
        }
    }

    knowledge.* = next;
    return metrics;
}

pub fn ringNeighbors(worker_index: usize) [2]usize {
    std.debug.assert(worker_index < worker_count);
    return .{
        (worker_index + worker_count - 1) % worker_count,
        (worker_index + 1) % worker_count,
    };
}

fn parseFactList(text: []const u8) !u8 {
    var result: u8 = 0;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ',');

    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidFact;
        result |= try parseSingleFact(part);
        count += 1;
    }

    if (count == 0 or result == 0) return error.InvalidFact;
    return result;
}

fn parseSingleFact(text: []const u8) !u8 {
    if (text.len != 1) return error.InvalidFact;
    return switch (text[0]) {
        'A' => factBit(0),
        'B' => factBit(1),
        'C' => factBit(2),
        'D' => factBit(3),
        'E' => factBit(4),
        else => error.InvalidFact,
    };
}

fn factBit(index: usize) u8 {
    return @as(u8, 1) << @intCast(index);
}

test "seed rotations preserve overlapping ring facts and global truth" {
    var seed: u64 = 0;
    while (seed < 5) : (seed += 1) {
        const knowledge = initialKnowledge(seed);
        var fact_union: u8 = 0;
        for (knowledge) |facts| {
            try std.testing.expectEqual(@as(usize, 2), @as(usize, @intCast(@popCount(facts))));
            fact_union |= facts;
        }
        try std.testing.expectEqual(full_mask, fact_union);
    }

    try std.testing.expectEqualDeep(
        [_]u8{ 0b00011, 0b00110, 0b01100, 0b11000, 0b10001 },
        initialKnowledge(0),
    );
}

test "action parser accepts factual interactions and rejects prose" {
    const claim = try parseAction("CLAIM A,C,E");
    try std.testing.expectEqual(ActionKind.claim, claim.kind);
    try std.testing.expectEqual(@as(u8, 0b10101), claim.facts);

    const query = try parseAction("QUERY EVIDENCE D");
    try std.testing.expectEqual(ActionKind.query_evidence, query.kind);
    try std.testing.expectEqual(@as(u8, 0b01000), query.facts);

    try std.testing.expectError(error.InvalidAction, parseAction("I think CLAIM A"));
    try std.testing.expectError(error.InvalidAction, parseAction("QUERY D"));
    try std.testing.expectError(error.InvalidFact, parseAction("CLAIM Z"));
}

test "claims propagate only known facts to ring neighbors" {
    var knowledge = initialKnowledge(0);
    var actions = [_]?Action{null} ** worker_count;
    actions[1] = try parseAction("CLAIM C");

    const metrics = applyRound(&knowledge, actions);
    try std.testing.expectEqual(@as(usize, 2), metrics.network_messages);
    try std.testing.expect((knowledge[0] & 0b00100) != 0);
    try std.testing.expect((knowledge[2] & 0b00100) != 0);

    actions = [_]?Action{null} ** worker_count;
    actions[0] = try parseAction("CLAIM E");
    const invalid = applyRound(&knowledge, actions);
    try std.testing.expectEqual(@as(usize, 1), invalid.semantic_violations);
}

test "query evidence pulls a fact only from ring neighbors that know it" {
    var knowledge = initialKnowledge(0);
    var actions = [_]?Action{null} ** worker_count;
    actions[0] = try parseAction("QUERY EVIDENCE C");

    const metrics = applyRound(&knowledge, actions);
    try std.testing.expectEqual(@as(usize, 3), metrics.network_messages);
    try std.testing.expectEqual(@as(usize, 1), metrics.useful_fact_deliveries);
    try std.testing.expect((knowledge[0] & 0b00100) != 0);
}

test "different autonomous trajectories can converge the collector" {
    var claim_path = initialKnowledge(0);
    const round_one = [_]?Action{
        try parseAction("CLAIM A,B"),
        try parseAction("CLAIM B,C"),
        try parseAction("CLAIM C,D"),
        try parseAction("CLAIM D,E"),
        try parseAction("CLAIM A,E"),
    };
    _ = applyRound(&claim_path, round_one);
    try std.testing.expect(!collectorSolved(claim_path));

    var round_two = [_]?Action{null} ** worker_count;
    round_two[1] = try parseAction("CLAIM D");
    _ = applyRound(&claim_path, round_two);
    try std.testing.expect(collectorSolved(claim_path));

    var query_path = initialKnowledge(0);
    _ = applyRound(&query_path, round_one);
    round_two = [_]?Action{null} ** worker_count;
    round_two[0] = try parseAction("QUERY EVIDENCE D");
    _ = applyRound(&query_path, round_two);
    try std.testing.expect(collectorSolved(query_path));
}

test "per-turn generation seed depends on sampling seed, not environment" {
    try std.testing.expectEqual(@as(u32, 102), generationSeed(0, 1, 1));
    try std.testing.expectEqual(
        generationSeed(42, 7, 3),
        generationSeed(42, 7, 3),
    );
    try std.testing.expect(generationSeed(42, 7, 3) != generationSeed(43, 7, 3));
}
