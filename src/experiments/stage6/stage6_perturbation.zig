const std = @import("std");
const scaling = @import("../stage5/stage5a_scaling.zig");
const stage5c = @import("../stage5/stage5c_regimes.zig");

pub const horizon: u32 = 4096;
pub const population: usize = 128;
pub const redundancy: usize = 2;

pub const PerturbationKind = enum {
    operator_omission,
    message_drop,
    edge_removal,

    pub fn name(self: PerturbationKind) []const u8 {
        return switch (self) {
            .operator_omission => "operator_omission",
            .message_drop => "message_drop",
            .edge_removal => "edge_removal",
        };
    }
};

pub const Perturbation = struct {
    kind: PerturbationKind,
    severity_permille: u16,
    seed: u64,

    pub fn validate(self: Perturbation) !void {
        if (self.severity_permille > 1000) return error.InvalidSeverity;
    }
};

pub const SparseAnchor = struct {
    id: []const u8,
    topology: scaling.TopologyKind,
    policy: scaling.PolicyKind,
    bandwidth: usize,
    facts: usize,

    pub fn lambdaX1e6(self: SparseAnchor) u64 {
        return scaledRatio(
            @as(u64, @intCast(self.facts)),
            @as(u64, @intCast(self.bandwidth)) *
                @as(u64, @intCast(horizon)),
            1_000_000,
        );
    }
};

pub const sparse_anchors = [_]SparseAnchor{
    .{
        .id = "ring_round_robin_edge",
        .topology = .ring,
        .policy = .round_robin,
        .bandwidth = 2,
        .facts = 384,
    },
    .{
        .id = "ring_seeded_edge",
        .topology = .ring,
        .policy = .seeded,
        .bandwidth = 2,
        .facts = 128,
    },
    .{
        .id = "ring_novel_first_high",
        .topology = .ring,
        .policy = .novel_first,
        .bandwidth = 1,
        .facts = 2048,
    },
    .{
        .id = "grid_round_robin_edge",
        .topology = .grid,
        .policy = .round_robin,
        .bandwidth = 1,
        .facts = 1280,
    },
    .{
        .id = "grid_seeded_edge",
        .topology = .grid,
        .policy = .seeded,
        .bandwidth = 2,
        .facts = 896,
    },
    .{
        .id = "grid_novel_first_high",
        .topology = .grid,
        .policy = .novel_first,
        .bandwidth = 1,
        .facts = 2048,
    },
};

pub const perturbation_kinds = [_]PerturbationKind{
    .operator_omission,
    .message_drop,
    .edge_removal,
};

pub const sparse_severities_permille = [_]u16{
    0, 10, 25, 50, 100, 150, 200, 300, 400, 500,
};

pub const trial_seeds = [_]u64{ 0, 1, 2 };

pub const coverage_populations = [_]usize{ 64, 128, 256 };
pub const coverage_ratios_permille = [_]usize{ 1000, 2000, 4000 };
pub const coverage_redundancies = [_]usize{ 1, 4, 8 };
pub const coverage_policies = [_]scaling.PolicyKind{ .round_robin, .seeded };
pub const coverage_kinds = [_]PerturbationKind{ .operator_omission, .message_drop };
pub const coverage_severities_permille = [_]u16{
    0, 25, 50, 100, 200, 300, 400, 500,
};

pub const Result = struct {
    base: scaling.Config,
    perturbation: Perturbation,
    success: bool,
    rounds: u32,
    diameter: usize,
    edges: usize,
    collector_initial_facts: usize,
    collector_final_facts: usize,

    policy_slots: u64,
    policy_calls: u64,
    operator_omissions: u64,
    actions_proposed: u64,
    rejected_actions: u64,

    attempted_messages: u64,
    delivered_messages: u64,
    suppressed_messages: u64,
    attempted_units: u64,
    delivered_units: u64,
    suppressed_units: u64,

    useful_deliveries: u64,
    duplicate_deliveries: u64,
    violations: u64,

    removed_edges: usize,
    collector_component_size: usize,
    collector_component_fact_coverage: usize,

    pub fn structurallyReachable(self: Result) bool {
        return self.collector_component_fact_coverage == self.base.fact_count;
    }

    pub fn deliveryRatioPermille(self: Result) u64 {
        if (self.attempted_units == 0) return 0;
        return (self.delivered_units * 1000) / self.attempted_units;
    }
};

pub const CoverageResult = struct {
    success: bool,
    collector_initial_facts: usize,
    collector_final_facts: usize,
    active_senders: usize,
    attempted_senders: usize,
    delivered_senders: usize,
    selected_fact_units: u64,
    suppressed_fact_units: u64,
    violations: u64,
};

pub const CoverageThreshold = struct {
    population_size: usize,
    facts: usize,
    facts_per_operator_x1000: u64,
    redundancy_count: usize,
    policy: scaling.PolicyKind,
    trial_seed: u64,
    perturbation: Perturbation,

    baseline_bandwidth: usize,
    perturbed_bandwidth: usize,
    reachable: bool,
    inflation_x1000: u64,

    collector_initial: usize,
    collector_final_at_threshold: usize,
    active_senders_at_threshold: usize,
    delivered_senders_at_threshold: usize,
    selected_fact_units_at_threshold: u64,
    suppressed_fact_units_at_threshold: u64,
    max_coverage_at_full_bandwidth: usize,
    violations: u64,
};

const ComponentInfo = struct {
    size: usize,
    fact_coverage: usize,
};

pub fn sparsePlanCount() usize {
    return sparse_anchors.len *
        perturbation_kinds.len *
        sparse_severities_permille.len *
        trial_seeds.len;
}

pub fn coveragePlanCount() usize {
    return coverage_populations.len *
        coverage_ratios_permille.len *
        coverage_redundancies.len *
        coverage_policies.len *
        coverage_kinds.len *
        coverage_severities_permille.len *
        trial_seeds.len;
}

pub fn perturbationSeed(trial_seed: u64) u64 {
    return trial_seed ^ 0x535441524c494e47;
}

pub fn runSparseAnchor(
    anchor: SparseAnchor,
    kind: PerturbationKind,
    severity_permille: u16,
    trial_seed: u64,
) !Result {
    return run(.{
        .population_size = population,
        .fact_count = anchor.facts,
        .topology = anchor.topology,
        .redundancy = redundancy,
        .bandwidth = anchor.bandwidth,
        .policy = anchor.policy,
        .seed = trial_seed,
        .max_rounds = horizon,
    }, .{
        .kind = kind,
        .severity_permille = severity_permille,
        .seed = perturbationSeed(trial_seed),
    });
}

pub fn run(config: scaling.Config, perturbation: Perturbation) !Result {
    try config.validate();
    try perturbation.validate();

    var states = [_]scaling.State{.{}} ** scaling.max_operators;
    scaling.initializeStates(&states, config);

    const component = if (perturbation.kind == .edge_removal)
        collectorComponent(&states, config, perturbation)
    else
        ComponentInfo{
            .size = config.population_size,
            .fact_coverage = config.fact_count,
        };

    const initial_facts =
        states[scaling.collector_index].knowledge.count(config.fact_count);

    var result = Result{
        .base = config,
        .perturbation = perturbation,
        .success = initial_facts == config.fact_count,
        .rounds = 0,
        .diameter = scaling.topologyDiameter(config.topology, config.population_size),
        .edges = scaling.topologyEdges(config.topology, config.population_size),
        .collector_initial_facts = initial_facts,
        .collector_final_facts = initial_facts,
        .policy_slots = 0,
        .policy_calls = 0,
        .operator_omissions = 0,
        .actions_proposed = 0,
        .rejected_actions = 0,
        .attempted_messages = 0,
        .delivered_messages = 0,
        .suppressed_messages = 0,
        .attempted_units = 0,
        .delivered_units = 0,
        .suppressed_units = 0,
        .useful_deliveries = 0,
        .duplicate_deliveries = 0,
        .violations = 0,
        .removed_edges = if (perturbation.kind == .edge_removal)
            countRemovedEdges(config, perturbation)
        else
            0,
        .collector_component_size = component.size,
        .collector_component_fact_coverage = component.fact_coverage,
    };

    if (result.success) return result;

    // Static topology damage can make convergence impossible regardless of
    // bandwidth or horizon. Do not spend 4,096 rounds simulating a collector
    // component that does not contain every fact.
    if (perturbation.kind == .edge_removal and
        component.fact_coverage < config.fact_count)
    {
        return result;
    }

    var round: u32 = 1;
    while (round <= config.max_rounds) : (round += 1) {
        var actions = [_]?scaling.Action{null} ** scaling.max_operators;
        var received = [_]scaling.BitSet{.{}} ** scaling.max_operators;

        var operator_index: usize = 0;
        while (operator_index < config.population_size) : (operator_index += 1) {
            result.policy_slots +%= 1;

            if (perturbation.kind == .operator_omission and
                eventOccurs(
                    perturbation,
                    0x4f50455241544f52,
                    round,
                    operator_index,
                    0,
                    false,
                ))
            {
                result.operator_omissions +%= 1;
                continue;
            }

            result.policy_calls +%= 1;
            if (scaling.decideLocal(
                config.policy,
                states[operator_index],
                operator_index,
                round,
                config,
            )) |action| {
                actions[operator_index] = action;
                result.actions_proposed +%= 1;
            }
        }

        var sender: usize = 0;
        while (sender < config.population_size) : (sender += 1) {
            const action = actions[sender] orelse continue;

            if (!scaling.validateLocalAction(action, states[sender], config)) {
                result.rejected_actions +%= 1;
                result.violations +%= 1;
                continue;
            }

            if (action.reset_sent) states[sender].sent.clear();
            states[sender].sent.unionWithFacts(action.facts, config.fact_count);
            states[sender].cursor = action.next_cursor;

            switch (config.topology) {
                .ring => {
                    const left =
                        (sender + config.population_size - 1) %
                        config.population_size;
                    const right = (sender + 1) % config.population_size;
                    attemptDelivery(
                        sender,
                        left,
                        round,
                        action,
                        states[left].knowledge,
                        &received[left],
                        &result,
                    );
                    if (right != left) {
                        attemptDelivery(
                            sender,
                            right,
                            round,
                            action,
                            states[right].knowledge,
                            &received[right],
                            &result,
                        );
                    }
                },
                .grid => {
                    const width = scaling.gridWidth(config.population_size);
                    const row = sender / width;
                    const col = sender % width;

                    if (col > 0) {
                        const recipient = sender - 1;
                        attemptDelivery(
                            sender,
                            recipient,
                            round,
                            action,
                            states[recipient].knowledge,
                            &received[recipient],
                            &result,
                        );
                    }
                    if (col + 1 < width and sender + 1 < config.population_size) {
                        const recipient = sender + 1;
                        if (recipient / width == row) {
                            attemptDelivery(
                                sender,
                                recipient,
                                round,
                                action,
                                states[recipient].knowledge,
                                &received[recipient],
                                &result,
                            );
                        }
                    }
                    if (sender >= width) {
                        const recipient = sender - width;
                        attemptDelivery(
                            sender,
                            recipient,
                            round,
                            action,
                            states[recipient].knowledge,
                            &received[recipient],
                            &result,
                        );
                    }
                    if (sender + width < config.population_size) {
                        const recipient = sender + width;
                        attemptDelivery(
                            sender,
                            recipient,
                            round,
                            action,
                            states[recipient].knowledge,
                            &received[recipient],
                            &result,
                        );
                    }
                },
                .complete => {
                    var recipient: usize = 0;
                    while (recipient < config.population_size) : (recipient += 1) {
                        if (recipient == sender) continue;
                        attemptDelivery(
                            sender,
                            recipient,
                            round,
                            action,
                            states[recipient].knowledge,
                            &received[recipient],
                            &result,
                        );
                    }
                },
            }
        }

        operator_index = 0;
        while (operator_index < config.population_size) : (operator_index += 1) {
            states[operator_index].knowledge.unionWithFacts(
                received[operator_index],
                config.fact_count,
            );
        }

        result.rounds = round;
        result.collector_final_facts =
            states[scaling.collector_index].knowledge.count(config.fact_count);

        if (states[scaling.collector_index].knowledge.containsAll(config.fact_count)) {
            result.success = true;
            break;
        }
    }

    std.debug.assert(
        result.attempted_units ==
            result.delivered_units + result.suppressed_units,
    );
    std.debug.assert(
        result.delivered_units ==
            result.useful_deliveries + result.duplicate_deliveries,
    );

    return result;
}

fn attemptDelivery(
    sender: usize,
    recipient: usize,
    round: u32,
    action: scaling.Action,
    snapshot_knowledge: scaling.BitSet,
    received: *scaling.BitSet,
    result: *Result,
) void {
    result.attempted_messages +%= 1;
    result.attempted_units +%= @as(u64, @intCast(action.selected));

    const suppressed = switch (result.perturbation.kind) {
        .operator_omission => false,
        .message_drop => eventOccurs(
            result.perturbation,
            0x4d45535341474544,
            round,
            sender,
            recipient,
            false,
        ),
        .edge_removal => edgeRemoved(
            result.perturbation,
            sender,
            recipient,
        ),
    };

    if (suppressed) {
        result.suppressed_messages +%= 1;
        result.suppressed_units +%= @as(u64, @intCast(action.selected));
        return;
    }

    result.delivered_messages +%= 1;
    result.delivered_units +%= @as(u64, @intCast(action.selected));

    const words = (result.base.fact_count + 63) / 64;
    const remainder = result.base.fact_count % 64;
    const tail_mask = if (remainder == 0)
        ~@as(u64, 0)
    else
        (@as(u64, 1) << @intCast(remainder)) - 1;

    var word_index: usize = 0;
    while (word_index < words) : (word_index += 1) {
        var action_word = action.facts.words[word_index];
        if (word_index + 1 == words) action_word &= tail_mask;
        if (action_word == 0) continue;

        const already_known =
            snapshot_knowledge.words[word_index] |
            received.words[word_index];
        const useful_bits = action_word & ~already_known;
        const duplicate_bits = action_word & already_known;

        result.useful_deliveries +%=
            @as(u64, @intCast(@popCount(useful_bits)));
        result.duplicate_deliveries +%=
            @as(u64, @intCast(@popCount(duplicate_bits)));
        received.words[word_index] |= action_word;
    }
}

pub fn completeOneRoundCoverage(
    config: scaling.Config,
    perturbation: Perturbation,
) !CoverageResult {
    try config.validate();
    try perturbation.validate();
    if (config.topology != .complete) return error.RequiresCompleteTopology;

    var states = [_]scaling.State{.{}} ** scaling.max_operators;
    scaling.initializeStates(&states, config);

    var collector = states[scaling.collector_index].knowledge;
    const initial = collector.count(config.fact_count);

    var result = CoverageResult{
        .success = initial == config.fact_count,
        .collector_initial_facts = initial,
        .collector_final_facts = initial,
        .active_senders = 0,
        .attempted_senders = 0,
        .delivered_senders = 0,
        .selected_fact_units = 0,
        .suppressed_fact_units = 0,
        .violations = 0,
    };
    if (result.success) return result;

    var sender: usize = 0;
    while (sender < config.population_size) : (sender += 1) {
        if (perturbation.kind == .operator_omission and
            eventOccurs(
                perturbation,
                0x4f50455241544f52,
                1,
                sender,
                0,
                false,
            ))
        {
            continue;
        }

        result.active_senders += 1;
        const action = scaling.decideLocal(
            config.policy,
            states[sender],
            sender,
            1,
            config,
        ) orelse continue;

        if (!scaling.validateLocalAction(action, states[sender], config)) {
            result.violations +%= 1;
            continue;
        }

        result.attempted_senders += 1;
        result.selected_fact_units +%= @as(u64, @intCast(action.selected));

        if (sender != scaling.collector_index) {
            const suppressed = switch (perturbation.kind) {
                .operator_omission => false,
                .message_drop => eventOccurs(
                    perturbation,
                    0x4d45535341474544,
                    1,
                    sender,
                    scaling.collector_index,
                    false,
                ),
                .edge_removal => edgeRemoved(
                    perturbation,
                    sender,
                    scaling.collector_index,
                ),
            };
            if (suppressed) {
                result.suppressed_fact_units +%=
                    @as(u64, @intCast(action.selected));
                continue;
            }
            result.delivered_senders += 1;
        }

        collector.unionWithFacts(action.facts, config.fact_count);
    }

    result.collector_final_facts = collector.count(config.fact_count);
    result.success = collector.containsAll(config.fact_count);
    return result;
}

pub fn findCoverageThreshold(
    population_size: usize,
    facts: usize,
    redundancy_count: usize,
    policy: scaling.PolicyKind,
    trial_seed: u64,
    perturbation: Perturbation,
) !CoverageThreshold {
    const baseline = try stage5c.findSaturationThreshold(
        population_size,
        facts,
        redundancy_count,
        policy,
        trial_seed,
    );

    var full_config = scaling.Config{
        .population_size = population_size,
        .fact_count = facts,
        .topology = .complete,
        .redundancy = redundancy_count,
        .bandwidth = facts,
        .policy = policy,
        .seed = trial_seed,
        .max_rounds = 1,
    };
    const full = try completeOneRoundCoverage(full_config, perturbation);

    if (!full.success) {
        return .{
            .population_size = population_size,
            .facts = facts,
            .facts_per_operator_x1000 = scaledRatio(
                @as(u64, @intCast(facts)),
                @as(u64, @intCast(population_size)),
                1000,
            ),
            .redundancy_count = redundancy_count,
            .policy = policy,
            .trial_seed = trial_seed,
            .perturbation = perturbation,
            .baseline_bandwidth = baseline.min_bandwidth,
            .perturbed_bandwidth = 0,
            .reachable = false,
            .inflation_x1000 = 0,
            .collector_initial = full.collector_initial_facts,
            .collector_final_at_threshold = full.collector_final_facts,
            .active_senders_at_threshold = full.active_senders,
            .delivered_senders_at_threshold = full.delivered_senders,
            .selected_fact_units_at_threshold = full.selected_fact_units,
            .suppressed_fact_units_at_threshold = full.suppressed_fact_units,
            .max_coverage_at_full_bandwidth = full.collector_final_facts,
            .violations = full.violations,
        };
    }

    var low: usize = 1;
    var high: usize = facts;
    while (low < high) {
        const mid = low + (high - low) / 2;
        full_config.bandwidth = mid;
        const coverage = try completeOneRoundCoverage(full_config, perturbation);
        if (coverage.success) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }

    full_config.bandwidth = low;
    const threshold = try completeOneRoundCoverage(full_config, perturbation);

    if (low > 1) {
        full_config.bandwidth = low - 1;
        const below = try completeOneRoundCoverage(full_config, perturbation);
        if (below.success) return error.NonMinimalThreshold;
        full_config.bandwidth = low;
    }

    return .{
        .population_size = population_size,
        .facts = facts,
        .facts_per_operator_x1000 = scaledRatio(
            @as(u64, @intCast(facts)),
            @as(u64, @intCast(population_size)),
            1000,
        ),
        .redundancy_count = redundancy_count,
        .policy = policy,
        .trial_seed = trial_seed,
        .perturbation = perturbation,
        .baseline_bandwidth = baseline.min_bandwidth,
        .perturbed_bandwidth = low,
        .reachable = true,
        .inflation_x1000 = scaledRatio(
            @as(u64, @intCast(low)),
            @as(u64, @intCast(baseline.min_bandwidth)),
            1000,
        ),
        .collector_initial = threshold.collector_initial_facts,
        .collector_final_at_threshold = threshold.collector_final_facts,
        .active_senders_at_threshold = threshold.active_senders,
        .delivered_senders_at_threshold = threshold.delivered_senders,
        .selected_fact_units_at_threshold = threshold.selected_fact_units,
        .suppressed_fact_units_at_threshold = threshold.suppressed_fact_units,
        .max_coverage_at_full_bandwidth = full.collector_final_facts,
        .violations = threshold.violations,
    };
}

pub fn eventOccurs(
    perturbation: Perturbation,
    domain: u64,
    round: u32,
    a: usize,
    b: usize,
    symmetric: bool,
) bool {
    if (perturbation.severity_permille == 0) return false;
    if (perturbation.severity_permille >= 1000) return true;

    var left = a;
    var right = b;
    if (symmetric and right < left) {
        const tmp = left;
        left = right;
        right = tmp;
    }

    const input =
        perturbation.seed ^
        domain ^
        (@as(u64, round) *% 0x9e3779b97f4a7c15) ^
        (@as(u64, @intCast(left)) *% 0xbf58476d1ce4e5b9) ^
        (@as(u64, @intCast(right)) *% 0x94d049bb133111eb);

    return (mix64(input) % 1000) <
        @as(u64, @intCast(perturbation.severity_permille));
}

fn edgeRemoved(
    perturbation: Perturbation,
    a: usize,
    b: usize,
) bool {
    return eventOccurs(
        perturbation,
        0x4544474552454d4f,
        0,
        a,
        b,
        true,
    );
}

fn countRemovedEdges(
    config: scaling.Config,
    perturbation: Perturbation,
) usize {
    var count: usize = 0;
    switch (config.topology) {
        .ring => {
            if (config.population_size == 2) {
                if (edgeRemoved(perturbation, 0, 1)) count += 1;
            } else {
                var i: usize = 0;
                while (i < config.population_size) : (i += 1) {
                    const j = (i + 1) % config.population_size;
                    if (edgeRemoved(perturbation, i, j)) count += 1;
                }
            }
        },
        .grid => {
            const width = scaling.gridWidth(config.population_size);
            var i: usize = 0;
            while (i < config.population_size) : (i += 1) {
                const row = i / width;
                const col = i % width;
                if (col + 1 < width and
                    i + 1 < config.population_size and
                    (i + 1) / width == row and
                    edgeRemoved(perturbation, i, i + 1))
                {
                    count += 1;
                }
                if (i + width < config.population_size and
                    edgeRemoved(perturbation, i, i + width))
                {
                    count += 1;
                }
            }
        },
        .complete => {
            var i: usize = 0;
            while (i < config.population_size) : (i += 1) {
                var j = i + 1;
                while (j < config.population_size) : (j += 1) {
                    if (edgeRemoved(perturbation, i, j)) count += 1;
                }
            }
        },
    }
    return count;
}

fn collectorComponent(
    states: *const [scaling.max_operators]scaling.State,
    config: scaling.Config,
    perturbation: Perturbation,
) ComponentInfo {
    var visited = [_]bool{false} ** scaling.max_operators;
    var queue = [_]usize{0} ** scaling.max_operators;
    var head: usize = 0;
    var tail: usize = 1;
    queue[0] = scaling.collector_index;
    visited[scaling.collector_index] = true;

    var coverage = scaling.BitSet{};

    while (head < tail) : (head += 1) {
        const current = queue[head];
        coverage.unionWithFacts(
            states[current].knowledge,
            config.fact_count,
        );

        switch (config.topology) {
            .ring => {
                const left =
                    (current + config.population_size - 1) %
                    config.population_size;
                const right = (current + 1) % config.population_size;
                enqueueNeighbor(
                    current,
                    left,
                    perturbation,
                    &visited,
                    &queue,
                    &tail,
                );
                if (right != left) {
                    enqueueNeighbor(
                        current,
                        right,
                        perturbation,
                        &visited,
                        &queue,
                        &tail,
                    );
                }
            },
            .grid => {
                const width = scaling.gridWidth(config.population_size);
                const row = current / width;
                const col = current % width;
                if (col > 0) {
                    enqueueNeighbor(
                        current,
                        current - 1,
                        perturbation,
                        &visited,
                        &queue,
                        &tail,
                    );
                }
                if (col + 1 < width and current + 1 < config.population_size) {
                    const neighbor = current + 1;
                    if (neighbor / width == row) {
                        enqueueNeighbor(
                            current,
                            neighbor,
                            perturbation,
                            &visited,
                            &queue,
                            &tail,
                        );
                    }
                }
                if (current >= width) {
                    enqueueNeighbor(
                        current,
                        current - width,
                        perturbation,
                        &visited,
                        &queue,
                        &tail,
                    );
                }
                if (current + width < config.population_size) {
                    enqueueNeighbor(
                        current,
                        current + width,
                        perturbation,
                        &visited,
                        &queue,
                        &tail,
                    );
                }
            },
            .complete => {
                var neighbor: usize = 0;
                while (neighbor < config.population_size) : (neighbor += 1) {
                    if (neighbor == current) continue;
                    enqueueNeighbor(
                        current,
                        neighbor,
                        perturbation,
                        &visited,
                        &queue,
                        &tail,
                    );
                }
            },
        }
    }

    return .{
        .size = tail,
        .fact_coverage = coverage.count(config.fact_count),
    };
}

fn enqueueNeighbor(
    current: usize,
    neighbor: usize,
    perturbation: Perturbation,
    visited: *[scaling.max_operators]bool,
    queue: *[scaling.max_operators]usize,
    tail: *usize,
) void {
    if (visited[neighbor]) return;
    if (edgeRemoved(perturbation, current, neighbor)) return;
    visited[neighbor] = true;
    queue[tail.*] = neighbor;
    tail.* += 1;
}

fn scaledRatio(numerator: u64, denominator: u64, scale: u64) u64 {
    std.debug.assert(denominator != 0);
    return (numerator * scale) / denominator;
}

fn mix64(input: u64) u64 {
    var z = input +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

test "Stage 6 canonical plan sizes are fixed" {
    try std.testing.expectEqual(@as(usize, 540), sparsePlanCount());
    try std.testing.expectEqual(@as(usize, 2592), coveragePlanCount());
}

test "severity events are nested for a fixed deterministic world" {
    const low = Perturbation{
        .kind = .message_drop,
        .severity_permille = 100,
        .seed = 42,
    };
    const high = Perturbation{
        .kind = .message_drop,
        .severity_permille = 300,
        .seed = 42,
    };

    var round: u32 = 1;
    while (round <= 32) : (round += 1) {
        var sender: usize = 0;
        while (sender < 16) : (sender += 1) {
            const recipient = (sender + 1) % 16;
            if (eventOccurs(
                low,
                0x4d45535341474544,
                round,
                sender,
                recipient,
                false,
            )) {
                try std.testing.expect(eventOccurs(
                    high,
                    0x4d45535341474544,
                    round,
                    sender,
                    recipient,
                    false,
                ));
            }
        }
    }
}

test "static edge removal is symmetric" {
    const perturbation = Perturbation{
        .kind = .edge_removal,
        .severity_permille = 333,
        .seed = 99,
    };
    var a: usize = 0;
    while (a < 16) : (a += 1) {
        var b: usize = 0;
        while (b < 16) : (b += 1) {
            try std.testing.expectEqual(
                edgeRemoved(perturbation, a, b),
                edgeRemoved(perturbation, b, a),
            );
        }
    }
}

test "zero perturbation exactly reproduces Stage 5A dynamics" {
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };
    const kinds = [_]PerturbationKind{
        .operator_omission,
        .message_drop,
        .edge_removal,
    };

    for (topologies) |topology| {
        for (policies) |policy| {
            const config = scaling.Config{
                .population_size = 17,
                .fact_count = 31,
                .topology = topology,
                .redundancy = 2,
                .bandwidth = 3,
                .policy = policy,
                .seed = 7,
                .max_rounds = 128,
            };
            const baseline = try scaling.run(config);

            for (kinds) |kind| {
                const perturbed = try run(config, .{
                    .kind = kind,
                    .severity_permille = 0,
                    .seed = 123,
                });

                try std.testing.expectEqual(baseline.success, perturbed.success);
                try std.testing.expectEqual(baseline.rounds, perturbed.rounds);
                try std.testing.expectEqual(
                    baseline.collector_initial_facts,
                    perturbed.collector_initial_facts,
                );
                try std.testing.expectEqual(
                    baseline.collector_final_facts,
                    perturbed.collector_final_facts,
                );
                try std.testing.expectEqual(
                    baseline.policy_calls,
                    perturbed.policy_calls,
                );
                try std.testing.expectEqual(
                    baseline.actions_proposed,
                    perturbed.actions_proposed,
                );
                try std.testing.expectEqual(
                    baseline.rejected_actions,
                    perturbed.rejected_actions,
                );
                try std.testing.expectEqual(
                    baseline.messages,
                    perturbed.delivered_messages,
                );
                try std.testing.expectEqual(
                    baseline.communication_units,
                    perturbed.delivered_units,
                );
                try std.testing.expectEqual(
                    baseline.useful_deliveries,
                    perturbed.useful_deliveries,
                );
                try std.testing.expectEqual(
                    baseline.duplicate_deliveries,
                    perturbed.duplicate_deliveries,
                );
                try std.testing.expectEqual(
                    baseline.violations,
                    perturbed.violations,
                );
            }
        }
    }
}

test "complete perturbed coverage matches Stage 5C at zero severity" {
    const config = scaling.Config{
        .population_size = 64,
        .fact_count = 128,
        .topology = .complete,
        .redundancy = 4,
        .bandwidth = 7,
        .policy = .seeded,
        .seed = 2,
        .max_rounds = 1,
    };

    const baseline = try scaling.completeOneRoundCoverage(config);
    const perturbed = try completeOneRoundCoverage(config, .{
        .kind = .message_drop,
        .severity_permille = 0,
        .seed = 42,
    });
    try std.testing.expectEqual(baseline.success, perturbed.success);
    try std.testing.expectEqual(
        baseline.collector_initial_facts,
        perturbed.collector_initial_facts,
    );
    try std.testing.expectEqual(
        baseline.collector_final_facts,
        perturbed.collector_final_facts,
    );
    try std.testing.expectEqual(baseline.violations, perturbed.violations);
}

test "full static ring removal isolates the collector component" {
    const config = scaling.Config{
        .population_size = 16,
        .fact_count = 32,
        .topology = .ring,
        .redundancy = 2,
        .bandwidth = 2,
        .policy = .novel_first,
        .seed = 0,
        .max_rounds = 32,
    };
    const result = try run(config, .{
        .kind = .edge_removal,
        .severity_permille = 1000,
        .seed = 1,
    });

    try std.testing.expectEqual(@as(usize, 1), result.collector_component_size);
    try std.testing.expect(
        result.collector_component_fact_coverage <=
            result.collector_initial_facts,
    );
    try std.testing.expectEqual(@as(u32, 0), result.rounds);
    try std.testing.expectEqual(@as(u64, 0), result.policy_slots);
    try std.testing.expectEqual(@as(u64, 0), result.attempted_messages);
}

test "zero-severity coverage threshold matches Stage 5C for both perturbation mechanisms" {
    const kinds = [_]PerturbationKind{ .operator_omission, .message_drop };
    for (kinds) |kind| {
        const threshold = try findCoverageThreshold(
            128,
            256,
            8,
            .seeded,
            2,
            .{
                .kind = kind,
                .severity_permille = 0,
                .seed = 999,
            },
        );
        try std.testing.expect(threshold.reachable);
        try std.testing.expectEqual(
            threshold.baseline_bandwidth,
            threshold.perturbed_bandwidth,
        );
        try std.testing.expectEqual(@as(u64, 1000), threshold.inflation_x1000);
    }
}

test "coverage threshold cannot improve below the unperturbed minimum at zero severity" {
    const threshold = try findCoverageThreshold(
        64,
        128,
        4,
        .round_robin,
        0,
        .{
            .kind = .operator_omission,
            .severity_permille = 0,
            .seed = 123,
        },
    );
    try std.testing.expect(threshold.reachable);
    try std.testing.expectEqual(
        threshold.baseline_bandwidth,
        threshold.perturbed_bandwidth,
    );
    try std.testing.expectEqual(@as(u64, 1000), threshold.inflation_x1000);
}
