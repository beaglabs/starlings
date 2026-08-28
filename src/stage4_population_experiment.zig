const std = @import("std");
const formal = @import("formal_population.zig");

pub const worker_count: usize = 5;
pub const fact_count: usize = 5;
pub const full_mask: u8 = (1 << fact_count) - 1;
pub const collector_index: usize = 0;

pub const State = u8;

pub const Observation = struct {
    operator_index: usize,
    round: u32,
    knowledge: u8,
    degree: usize,
};

pub const Action = struct {
    facts: u8,
};

pub const Context = struct {
    collector: usize = collector_index,
    target_mask: u8 = full_mask,
};

const SpecState = State;
const SpecObservation = Observation;
const SpecAction = Action;
const SpecContext = Context;

pub const PolicyMode = enum {
    rotating_claim,
    silent,
};

pub const Spec = struct {
    pub const State = SpecState;
    pub const Observation = SpecObservation;
    pub const Action = SpecAction;
    pub const Context = SpecContext;

    pub fn observe(
        _: *const SpecContext,
        snapshot: *const [worker_count]SpecState,
        topology: *const formal.Topology(worker_count),
        operator_count: usize,
        operator_index: usize,
        round: u32,
    ) SpecObservation {
        return .{
            .operator_index = operator_index,
            .round = round,
            .knowledge = snapshot[operator_index],
            .degree = topology.degree(operator_index, operator_count),
        };
    }

    pub fn apply(
        _: *const SpecContext,
        snapshot: *const [worker_count]SpecState,
        topology: *const formal.Topology(worker_count),
        operator_count: usize,
        active: [worker_count]bool,
        actions: [worker_count]?SpecAction,
        states: *[worker_count]SpecState,
    ) formal.RoundEffect {
        var effect = formal.RoundEffect{};

        var i: usize = 0;
        while (i < operator_count) : (i += 1) {
            states[i] = snapshot[i];
        }

        var sender: usize = 0;
        while (sender < operator_count) : (sender += 1) {
            if (!active[sender]) continue;
            const action = actions[sender] orelse continue;

            if (action.facts == 0 or (action.facts & ~snapshot[sender]) != 0) {
                effect.rejected_actions += 1;
                effect.cost.violations +%= 1;
                continue;
            }

            var recipient: usize = 0;
            while (recipient < operator_count) : (recipient += 1) {
                if (!active[recipient]) continue;
                if (!topology.isNeighbor(sender, recipient)) continue;

                states[recipient] |= action.facts;
                effect.cost.communication +%= 1;
            }
        }

        return effect;
    }

    pub fn evaluate(
        context: *const SpecContext,
        states: *const [worker_count]State,
        operator_count: usize,
        _: u32,
    ) formal.Outcome {
        if (context.collector >= operator_count) return .failure;
        if (states[context.collector] == context.target_mask) return .success;
        return .running;
    }
};

pub const Simulator = formal.Simulator(Spec, worker_count);
pub const Policy = formal.Policy(Observation, Action);

pub const ExperimentResult = struct {
    environment_seed: u64,
    mode: PolicyMode,
    simulation: formal.SimulationResult,
    final_states: [worker_count]State,
};

pub fn initialKnowledge(environment_seed: u64) [worker_count]State {
    const offset: usize = @intCast(environment_seed % fact_count);
    var result = [_]State{0} ** worker_count;

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const first = (i + offset) % fact_count;
        const second = (i + 1 + offset) % fact_count;
        result[i] = factBit(first) | factBit(second);
    }
    return result;
}

pub fn runEnvironment(
    environment_seed: u64,
    mode: PolicyMode,
    max_rounds: u32,
) !ExperimentResult {
    var simulator = Simulator.init(.{});
    const initial = initialKnowledge(environment_seed);
    const policy = policyFor(mode);

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        _ = try simulator.addOperator(@intCast(i + 1), initial[i], policy);
    }

    simulator.setTopology(try formal.Topology(worker_count).ring(worker_count));
    const simulation = simulator.run(max_rounds);

    return .{
        .environment_seed = environment_seed,
        .mode = mode,
        .simulation = simulation,
        .final_states = simulator.population.states,
    };
}

pub fn validateRotations(max_rounds: u32) !ValidationSummary {
    var summary = ValidationSummary{};

    var environment_seed: u64 = 0;
    while (environment_seed < @as(u64, fact_count)) : (environment_seed += 1) {
        const result = try runEnvironment(
            environment_seed,
            .rotating_claim,
            max_rounds,
        );
        summary.runs += 1;
        if (result.simulation.outcome == .success) summary.successes += 1;
        summary.total_rounds += @as(usize, @intCast(result.simulation.rounds));
        summary.total_communication +%= result.simulation.cost.communication;
        summary.total_computation +%= result.simulation.cost.computation;
        summary.total_violations +%= result.simulation.cost.violations;
    }

    return summary;
}

pub const ValidationSummary = struct {
    runs: usize = 0,
    successes: usize = 0,
    total_rounds: usize = 0,
    total_communication: u64 = 0,
    total_computation: u64 = 0,
    total_violations: u64 = 0,

    pub fn successRatePermille(self: ValidationSummary) usize {
        if (self.runs == 0) return 0;
        return (self.successes * 1000) / self.runs;
    }
};

fn policyFor(mode: PolicyMode) Policy {
    return switch (mode) {
        .rotating_claim => .{ .decide_fn = rotatingClaimPolicy },
        .silent => .{ .decide_fn = silentPolicy },
    };
}

fn rotatingClaimPolicy(
    _: ?*const anyopaque,
    observation: Observation,
) ?Action {
    if (observation.knowledge == 0 or observation.degree == 0) return null;

    const known_count: usize = @intCast(@popCount(observation.knowledge));
    const offset: usize = @intCast(
        (@as(u64, observation.round - 1) +
            @as(u64, @intCast(observation.operator_index))) %
            @as(u64, @intCast(known_count)),
    );

    return .{ .facts = nthSetBit(observation.knowledge, offset) };
}

fn silentPolicy(
    _: ?*const anyopaque,
    _: Observation,
) ?Action {
    return null;
}

fn nthSetBit(mask: u8, target: usize) u8 {
    var seen: usize = 0;
    var bit_index: usize = 0;

    while (bit_index < fact_count) : (bit_index += 1) {
        const bit = factBit(bit_index);
        if ((mask & bit) == 0) continue;

        if (seen == target) return bit;
        seen += 1;
    }

    return 0;
}

fn factBit(index: usize) u8 {
    return @as(u8, 1) << @intCast(index);
}

test "formal substrate converges every rotated fact environment without an LLM" {
    var environment_seed: u64 = 0;
    while (environment_seed < fact_count) : (environment_seed += 1) {
        const result = try runEnvironment(
            environment_seed,
            .rotating_claim,
            8,
        );

        try std.testing.expectEqual(formal.Outcome.success, result.simulation.outcome);
        try std.testing.expectEqual(full_mask, result.final_states[collector_index]);
        try std.testing.expect(result.simulation.rounds <= 5);
        try std.testing.expect(result.simulation.cost.communication > 0);
        try std.testing.expectEqual(@as(u64, 0), result.simulation.cost.violations);
    }
}

test "silent local policy does not converge" {
    const result = try runEnvironment(0, .silent, 8);

    try std.testing.expectEqual(formal.Outcome.exhausted, result.simulation.outcome);
    try std.testing.expect(result.final_states[collector_index] != full_mask);
    try std.testing.expectEqual(@as(u64, 0), result.simulation.cost.communication);
    try std.testing.expectEqual(@as(usize, 0), result.simulation.actions_proposed);
}

test "validation summary is deterministic" {
    const a = try validateRotations(8);
    const b = try validateRotations(8);

    try std.testing.expectEqualDeep(a, b);
    try std.testing.expectEqual(@as(usize, 5), a.runs);
    try std.testing.expectEqual(@as(usize, 5), a.successes);
    try std.testing.expectEqual(@as(usize, 1000), a.successRatePermille());
}

test "policy decisions depend only on local observation" {
    const observation = Observation{
        .operator_index = 2,
        .round = 3,
        .knowledge = 0b10110,
        .degree = 2,
    };

    const first = rotatingClaimPolicy(null, observation).?;
    const second = rotatingClaimPolicy(null, observation).?;

    try std.testing.expectEqualDeep(first, second);
    try std.testing.expect((first.facts & ~observation.knowledge) == 0);
    try std.testing.expectEqual(
        @as(usize, 1),
        @as(usize, @intCast(@popCount(first.facts))),
    );
}
