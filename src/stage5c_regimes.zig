const std = @import("std");
const scaling = @import("stage5a_scaling.zig");

pub const boundary_population: usize = 128;
pub const boundary_redundancy: usize = 2;
pub const boundary_base_horizon: u32 = 4096;
pub const boundary_extended_horizon: u32 = 16384;

pub const boundary_facts = [_]usize{
    128, 192, 256, 320, 384, 448, 512,
    640, 768, 896, 1024, 1280, 1536, 2048,
};
pub const boundary_bandwidths = [_]usize{ 1, 2, 4 };
pub const boundary_topologies = [_]scaling.TopologyKind{ .ring, .grid };
pub const all_policies = [_]scaling.PolicyKind{
    .round_robin,
    .seeded,
    .novel_first,
};
pub const seeds = [_]u64{ 0, 1, 2 };

pub const saturation_populations = [_]usize{ 32, 64, 128, 256 };
pub const saturation_fact_ratio_permille = [_]usize{ 500, 1000, 2000, 4000 };
pub const saturation_redundancies = [_]usize{ 1, 2, 4, 8 };

pub const BoundaryRecord = struct {
    population: usize,
    facts: usize,
    topology: scaling.TopologyKind,
    diameter: usize,
    redundancy: usize,
    bandwidth: usize,
    policy: scaling.PolicyKind,
    seed: u64,
    q_fb_x1000: u64,
    q_fdb_x1000: u64,
    q_fnb_x1000: u64,
    q_fdnrb_x1000: u64,

    success_4096: bool,
    rounds_4096: u32,
    collector_4096: usize,
    comm_4096: u64,
    useful_4096: u64,
    duplicate_4096: u64,
    violations_4096: u64,

    extended_attempted: bool,
    success_16384: bool,
    rounds_16384: u32,
    collector_16384: usize,
    comm_16384: u64,
    useful_16384: u64,
    duplicate_16384: u64,
    violations_16384: u64,

    pub fn delayedConvergence(self: BoundaryRecord) bool {
        return !self.success_4096 and
            self.extended_attempted and
            self.success_16384;
    }

    pub fn persistentCensoring(self: BoundaryRecord) bool {
        return !self.success_4096 and
            self.extended_attempted and
            !self.success_16384;
    }
};

pub const SaturationRecord = struct {
    population: usize,
    facts: usize,
    facts_per_operator_x1000: u64,
    redundancy: usize,
    policy: scaling.PolicyKind,
    seed: u64,
    min_bandwidth: usize,
    bandwidth_fraction_x1000: u64,
    aggregate_capacity_x1000: u64,
    redundant_capacity_x1000: u64,
    collector_initial: usize,
    collector_final: usize,
    active_senders: usize,
    selected_fact_units: u64,
    below_threshold_success: bool,
    violations: u64,
};

pub fn boundaryPlanCount() usize {
    return boundary_facts.len *
        boundary_bandwidths.len *
        boundary_topologies.len *
        all_policies.len *
        seeds.len;
}

pub fn saturationPlanCount() usize {
    return saturation_populations.len *
        saturation_fact_ratio_permille.len *
        saturation_redundancies.len *
        all_policies.len *
        seeds.len;
}

pub fn runBoundaryCase(
    facts: usize,
    topology: scaling.TopologyKind,
    bandwidth: usize,
    policy: scaling.PolicyKind,
    seed: u64,
    base_horizon: u32,
    extended_horizon: u32,
) !BoundaryRecord {
    const config = scaling.Config{
        .population_size = boundary_population,
        .fact_count = facts,
        .topology = topology,
        .redundancy = boundary_redundancy,
        .bandwidth = bandwidth,
        .policy = policy,
        .seed = seed,
        .max_rounds = base_horizon,
    };
    const base = try scaling.run(config);

    var record = BoundaryRecord{
        .population = config.population_size,
        .facts = config.fact_count,
        .topology = config.topology,
        .diameter = base.diameter,
        .redundancy = config.redundancy,
        .bandwidth = config.bandwidth,
        .policy = config.policy,
        .seed = config.seed,
        .q_fb_x1000 = scaledRatio(
            @as(u64, @intCast(config.fact_count)),
            @as(u64, @intCast(config.bandwidth)),
            1000,
        ),
        .q_fdb_x1000 = scaledRatio(
            @as(u64, @intCast(config.fact_count * base.diameter)),
            @as(u64, @intCast(config.bandwidth)),
            1000,
        ),
        .q_fnb_x1000 = scaledRatio(
            @as(u64, @intCast(config.fact_count)),
            @as(u64, @intCast(config.population_size * config.bandwidth)),
            1000,
        ),
        .q_fdnrb_x1000 = scaledRatio(
            @as(u64, @intCast(config.fact_count * base.diameter)),
            @as(u64, @intCast(
                config.population_size *
                    config.redundancy *
                    config.bandwidth,
            )),
            1000,
        ),
        .success_4096 = base.success,
        .rounds_4096 = base.rounds,
        .collector_4096 = base.collector_final_facts,
        .comm_4096 = base.communication_units,
        .useful_4096 = base.useful_deliveries,
        .duplicate_4096 = base.duplicate_deliveries,
        .violations_4096 = base.violations,
        .extended_attempted = false,
        .success_16384 = base.success,
        .rounds_16384 = base.rounds,
        .collector_16384 = base.collector_final_facts,
        .comm_16384 = base.communication_units,
        .useful_16384 = base.useful_deliveries,
        .duplicate_16384 = base.duplicate_deliveries,
        .violations_16384 = base.violations,
    };

    if (!base.success) {
        var extended_config = config;
        extended_config.max_rounds = extended_horizon;
        const extended = try scaling.run(extended_config);
        record.extended_attempted = true;
        record.success_16384 = extended.success;
        record.rounds_16384 = extended.rounds;
        record.collector_16384 = extended.collector_final_facts;
        record.comm_16384 = extended.communication_units;
        record.useful_16384 = extended.useful_deliveries;
        record.duplicate_16384 = extended.duplicate_deliveries;
        record.violations_16384 = extended.violations;
    }

    return record;
}

pub fn runCanonicalBoundaryCase(
    facts: usize,
    topology: scaling.TopologyKind,
    bandwidth: usize,
    policy: scaling.PolicyKind,
    seed: u64,
) !BoundaryRecord {
    return runBoundaryCase(
        facts,
        topology,
        bandwidth,
        policy,
        seed,
        boundary_base_horizon,
        boundary_extended_horizon,
    );
}

pub fn saturationFactCount(population: usize, ratio_permille: usize) usize {
    return (population * ratio_permille) / 1000;
}

pub fn findSaturationThreshold(
    population: usize,
    facts: usize,
    redundancy: usize,
    policy: scaling.PolicyKind,
    seed: u64,
) !SaturationRecord {
    var low: usize = 1;
    var high: usize = facts;

    while (low < high) {
        const mid = low + (high - low) / 2;
        const coverage = try completeCoverage(
            population,
            facts,
            redundancy,
            mid,
            policy,
            seed,
        );
        if (coverage.success) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }

    const threshold = low;
    const at_threshold = try completeCoverage(
        population,
        facts,
        redundancy,
        threshold,
        policy,
        seed,
    );
    const below_success = if (threshold == 1)
        false
    else
        (try completeCoverage(
            population,
            facts,
            redundancy,
            threshold - 1,
            policy,
            seed,
        )).success;

    return .{
        .population = population,
        .facts = facts,
        .facts_per_operator_x1000 = scaledRatio(
            @as(u64, @intCast(facts)),
            @as(u64, @intCast(population)),
            1000,
        ),
        .redundancy = redundancy,
        .policy = policy,
        .seed = seed,
        .min_bandwidth = threshold,
        .bandwidth_fraction_x1000 = scaledRatio(
            @as(u64, @intCast(threshold)),
            @as(u64, @intCast(facts)),
            1000,
        ),
        .aggregate_capacity_x1000 = scaledRatio(
            @as(u64, @intCast(population * threshold)),
            @as(u64, @intCast(facts)),
            1000,
        ),
        .redundant_capacity_x1000 = scaledRatio(
            @as(u64, @intCast(population * redundancy * threshold)),
            @as(u64, @intCast(facts)),
            1000,
        ),
        .collector_initial = at_threshold.collector_initial_facts,
        .collector_final = at_threshold.collector_final_facts,
        .active_senders = at_threshold.active_senders,
        .selected_fact_units = at_threshold.selected_fact_units,
        .below_threshold_success = below_success,
        .violations = at_threshold.violations,
    };
}

fn completeCoverage(
    population: usize,
    facts: usize,
    redundancy: usize,
    bandwidth: usize,
    policy: scaling.PolicyKind,
    seed: u64,
) !scaling.OneRoundCoverage {
    return scaling.completeOneRoundCoverage(.{
        .population_size = population,
        .fact_count = facts,
        .topology = .complete,
        .redundancy = redundancy,
        .bandwidth = bandwidth,
        .policy = policy,
        .seed = seed,
        .max_rounds = 1,
    });
}

fn scaledRatio(numerator: u64, denominator: u64, scale: u64) u64 {
    std.debug.assert(denominator != 0);
    return (numerator * scale) / denominator;
}

test "Stage 5C canonical plan sizes are fixed" {
    try std.testing.expectEqual(@as(usize, 756), boundaryPlanCount());
    try std.testing.expectEqual(@as(usize, 576), saturationPlanCount());
}

test "boundary dimensionless coordinates are deterministic" {
    const record = try runBoundaryCase(
        128,
        .complete,
        4,
        .round_robin,
        0,
        1,
        2,
    );
    try std.testing.expectEqual(@as(u64, 32000), record.q_fb_x1000);
    try std.testing.expectEqual(@as(u64, 250), record.q_fnb_x1000);
}

test "short boundary horizon triggers a separate extended diagnostic" {
    const record = try runBoundaryCase(
        128,
        .ring,
        1,
        .seeded,
        0,
        1,
        64,
    );
    if (!record.success_4096) {
        try std.testing.expect(record.extended_attempted);
        try std.testing.expect(record.rounds_16384 >= record.rounds_4096);
    }
}

test "complete saturation threshold is minimal" {
    const record = try findSaturationThreshold(
        32,
        64,
        2,
        .round_robin,
        0,
    );
    try std.testing.expect(record.min_bandwidth >= 1);
    try std.testing.expect(record.min_bandwidth <= 64);
    try std.testing.expect(!record.below_threshold_success);
    try std.testing.expectEqual(@as(usize, 64), record.collector_final);
    try std.testing.expectEqual(@as(u64, 0), record.violations);
}

test "saturation fact ratios map exactly for canonical populations" {
    try std.testing.expectEqual(@as(usize, 16), saturationFactCount(32, 500));
    try std.testing.expectEqual(@as(usize, 128), saturationFactCount(64, 2000));
    try std.testing.expectEqual(@as(usize, 1024), saturationFactCount(256, 4000));
}


test "round robin and novel first are one-round equivalent before sent history exists" {
    const cases = [_]struct {
        population: usize,
        facts: usize,
        redundancy: usize,
        bandwidth: usize,
        seed: u64,
    }{
        .{ .population = 32, .facts = 64, .redundancy = 1, .bandwidth = 3, .seed = 0 },
        .{ .population = 64, .facts = 128, .redundancy = 2, .bandwidth = 7, .seed = 1 },
        .{ .population = 128, .facts = 512, .redundancy = 4, .bandwidth = 11, .seed = 2 },
    };

    for (cases) |case| {
        const round_robin = try scaling.completeOneRoundCoverage(.{
            .population_size = case.population,
            .fact_count = case.facts,
            .topology = .complete,
            .redundancy = case.redundancy,
            .bandwidth = case.bandwidth,
            .policy = .round_robin,
            .seed = case.seed,
            .max_rounds = 1,
        });
        const novel_first = try scaling.completeOneRoundCoverage(.{
            .population_size = case.population,
            .fact_count = case.facts,
            .topology = .complete,
            .redundancy = case.redundancy,
            .bandwidth = case.bandwidth,
            .policy = .novel_first,
            .seed = case.seed,
            .max_rounds = 1,
        });
        try std.testing.expectEqualDeep(round_robin, novel_first);
    }
}
