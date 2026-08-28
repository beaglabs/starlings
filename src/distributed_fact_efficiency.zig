const std = @import("std");

pub const worker_count: usize = 5;
pub const fact_count: usize = 10;
pub const collector_index: usize = 0;
pub const default_worker_budget: u16 = 16;
pub const full_mask: u16 = (1 << fact_count) - 1;

pub const ActionKind = enum {
    claim,
    query_evidence,
};

pub const Action = struct {
    kind: ActionKind,
    facts: u16,
};

pub const RoundMetrics = struct {
    semantic_violations: usize = 0,
    budget_rejections: usize = 0,
    network_messages: usize = 0,
    communication_units: usize = 0,
    useful_fact_deliveries: usize = 0,
    duplicate_fact_transmissions: usize = 0,
};

pub fn initialKnowledge(environment_seed: u64) [worker_count]u16 {
    const offset: usize = @intCast(environment_seed % fact_count);
    var result = [_]u16{0} ** worker_count;

    var worker: usize = 0;
    while (worker < worker_count) : (worker += 1) {
        const start = (worker * 2 + offset) % fact_count;
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            result[worker] |= factBit((start + j) % fact_count);
        }
    }
    return result;
}

pub fn initialBudgets(worker_budget: u16) [worker_count]u16 {
    return [_]u16{worker_budget} ** worker_count;
}

pub fn generationSeed(sampling_seed: u64, round: u32, worker: u8) u32 {
    const mixed = sampling_seed *% 1_000_003 +%
        @as(u64, round) *% 101 +%
        @as(u64, worker);
    return @intCast(mixed & 0x7fff_ffff);
}

pub fn collectorSolved(knowledge: [worker_count]u16) bool {
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
    knowledge: *[worker_count]u16,
    remaining_budget: *[worker_count]u16,
    actions: [worker_count]?Action,
) RoundMetrics {
    const snapshot = knowledge.*;
    var next = snapshot;
    var metrics = RoundMetrics{};

    var sender: usize = 0;
    while (sender < worker_count) : (sender += 1) {
        const action = actions[sender] orelse continue;
        const neighbors = ringNeighbors(sender);

        switch (action.kind) {
            .claim => {
                if (action.facts == 0 or (action.facts & ~snapshot[sender]) != 0) {
                    metrics.semantic_violations += 1;
                    continue;
                }

                const fact_count_sent: u16 = @intCast(@popCount(action.facts));
                const cost: u16 = fact_count_sent * 2;
                if (cost > remaining_budget[sender]) {
                    metrics.budget_rejections += 1;
                    continue;
                }
                remaining_budget[sender] -= cost;
                metrics.communication_units += cost;
                metrics.network_messages += 2;

                for (neighbors) |recipient| {
                    const unseen = action.facts & ~next[recipient];
                    const duplicate = action.facts & next[recipient];
                    metrics.useful_fact_deliveries += @as(usize, @intCast(@popCount(unseen)));
                    metrics.duplicate_fact_transmissions += @as(usize, @intCast(@popCount(duplicate)));
                    next[recipient] |= action.facts;
                }
            },
            .query_evidence => {
                var responders: u16 = 0;
                for (neighbors) |recipient| {
                    if ((snapshot[recipient] & action.facts) != 0) responders += 1;
                }

                const cost: u16 = 2 + responders;
                if (cost > remaining_budget[sender]) {
                    metrics.budget_rejections += 1;
                    continue;
                }
                remaining_budget[sender] -= cost;
                metrics.communication_units += cost;
                metrics.network_messages += cost;

                for (neighbors) |recipient| {
                    if ((snapshot[recipient] & action.facts) == 0) continue;

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

pub fn spentBudget(
    remaining_budget: [worker_count]u16,
    worker_budget: u16,
) usize {
    var spent: usize = 0;
    for (remaining_budget) |remaining| {
        spent += @as(usize, worker_budget - remaining);
    }
    return spent;
}

fn parseFactList(text: []const u8) !u16 {
    var result: u16 = 0;
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

fn parseSingleFact(text: []const u8) !u16 {
    if (text.len != 1) return error.InvalidFact;
    return switch (text[0]) {
        'A'...'J' => factBit(text[0] - 'A'),
        else => error.InvalidFact,
    };
}

fn factBit(index: usize) u16 {
    return @as(u16, 1) << @intCast(index);
}

test "ten-fact placement gives four facts per worker and two copies per fact" {
    const knowledge = initialKnowledge(0);
    try std.testing.expectEqualDeep(
        [_]u16{
            0b0000001111,
            0b0000111100,
            0b0011110000,
            0b1111000000,
            0b1100000011,
        },
        knowledge,
    );

    var counts = [_]usize{0} ** fact_count;
    for (knowledge) |facts| {
        try std.testing.expectEqual(
            @as(usize, 4),
            @as(usize, @intCast(@popCount(facts))),
        );
        var i: usize = 0;
        while (i < fact_count) : (i += 1) {
            if ((facts & factBit(i)) != 0) counts[i] += 1;
        }
    }
    for (counts) |count| try std.testing.expectEqual(@as(usize, 2), count);
}

test "action parser accepts A through J and rejects prose" {
    const claim = try parseAction("CLAIM A,E,J");
    try std.testing.expectEqual(ActionKind.claim, claim.kind);
    try std.testing.expectEqual(factBit(0) | factBit(4) | factBit(9), claim.facts);

    const query = try parseAction("QUERY EVIDENCE H");
    try std.testing.expectEqual(ActionKind.query_evidence, query.kind);
    try std.testing.expectEqual(factBit(7), query.facts);

    try std.testing.expectError(error.InvalidAction, parseAction("I think CLAIM A"));
    try std.testing.expectError(error.InvalidFact, parseAction("CLAIM K"));
}

test "selective two-round relay solves within worker budgets" {
    var knowledge = initialKnowledge(0);
    var budgets = initialBudgets(default_worker_budget);

    var round_one = [_]?Action{null} ** worker_count;
    round_one[1] = try parseAction("CLAIM E,F");
    round_one[2] = try parseAction("CLAIM G,H");
    round_one[4] = try parseAction("CLAIM I,J");
    const first = applyRound(&knowledge, &budgets, round_one);
    try std.testing.expectEqual(@as(usize, 12), first.communication_units);
    try std.testing.expect(!collectorSolved(knowledge));

    var round_two = [_]?Action{null} ** worker_count;
    round_two[1] = try parseAction("CLAIM G,H");
    const second = applyRound(&knowledge, &budgets, round_two);
    try std.testing.expectEqual(@as(usize, 4), second.communication_units);
    try std.testing.expect(collectorSolved(knowledge));
    try std.testing.expectEqual(@as(u16, 8), budgets[1]);
    try std.testing.expectEqual(@as(usize, 16), spentBudget(budgets, default_worker_budget));
}

test "broad repeated claims exhaust budget and are rejected" {
    var knowledge = initialKnowledge(0);
    var budgets = initialBudgets(default_worker_budget);

    var first_actions: [worker_count]?Action = undefined;
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        first_actions[i] = .{ .kind = .claim, .facts = knowledge[i] };
    }
    const first = applyRound(&knowledge, &budgets, first_actions);
    try std.testing.expectEqual(@as(usize, 40), first.communication_units);

    var second_actions: [worker_count]?Action = undefined;
    i = 0;
    while (i < worker_count) : (i += 1) {
        second_actions[i] = .{ .kind = .claim, .facts = knowledge[i] };
    }
    const second = applyRound(&knowledge, &budgets, second_actions);
    try std.testing.expect(second.budget_rejections > 0);
}

test "query evidence spends control plus responder units" {
    var knowledge = initialKnowledge(0);
    var budgets = initialBudgets(default_worker_budget);
    var actions = [_]?Action{null} ** worker_count;
    actions[0] = try parseAction("QUERY EVIDENCE E");

    const metrics = applyRound(&knowledge, &budgets, actions);
    try std.testing.expectEqual(@as(usize, 3), metrics.communication_units);
    try std.testing.expectEqual(@as(usize, 3), metrics.network_messages);
    try std.testing.expect((knowledge[0] & factBit(4)) != 0);
    try std.testing.expectEqual(@as(u16, default_worker_budget - 3), budgets[0]);
}

test "sampling seed remains independent of environment seed" {
    try std.testing.expectEqual(@as(u32, 102), generationSeed(0, 1, 1));
    try std.testing.expect(generationSeed(7, 1, 1) != generationSeed(8, 1, 1));
}
