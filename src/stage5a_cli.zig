const std = @import("std");
const scaling = @import("stage5a_scaling.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try usage(io);
        std.process.exit(2);
    }

    if (std.mem.eql(u8, args[1], "validate")) {
        try validate(io);
        return;
    }

    if (std.mem.eql(u8, args[1], "run")) {
        if (args.len < 7) {
            try usage(io);
            std.process.exit(2);
        }
        try runOne(io, args);
        return;
    }

    if (std.mem.eql(u8, args[1], "sweep")) {
        const profile = if (args.len >= 3) args[2] else "smoke";
        if (!std.mem.eql(u8, profile, "smoke") and !std.mem.eql(u8, profile, "full")) {
            try usage(io);
            std.process.exit(2);
        }
        try sweep(io, std.mem.eql(u8, profile, "full"));
        return;
    }

    try usage(io);
    std.process.exit(2);
}

fn validate(io: std.Io) !void {
    const populations = [_]usize{ 5, 10, 20 };
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };

    var runs: usize = 0;
    var successes: usize = 0;
    var violations: u64 = 0;

    for (populations) |population_size| {
        for (topologies) |topology| {
            for (policies) |policy| {
                const result = try scaling.run(.{
                    .population_size = population_size,
                    .fact_count = population_size,
                    .topology = topology,
                    .redundancy = 2,
                    .bandwidth = 2,
                    .policy = policy,
                    .seed = 0,
                    .max_rounds = 512,
                });
                runs += 1;
                if (result.success) successes += 1;
                violations +%= result.violations;
            }
        }
    }

    const out = std.Io.File.stdout();
    try write(io, out, "Stage 5A information diffusion validation\n", .{});
    try write(io, out, "runs: {d}\n", .{runs});
    try write(io, out, "successes: {d}\n", .{successes});
    try write(io, out, "violations: {d}\n", .{violations});

    if (successes != runs or violations != 0) std.process.exit(1);
}

fn runOne(io: std.Io, args: []const []const u8) !void {
    const population_size = try std.fmt.parseInt(usize, args[2], 10);
    const topology = parseTopology(args[3]) orelse {
        try usage(io);
        std.process.exit(2);
    };
    const redundancy = try std.fmt.parseInt(usize, args[4], 10);
    const bandwidth = try std.fmt.parseInt(usize, args[5], 10);
    const policy = parsePolicy(args[6]) orelse {
        try usage(io);
        std.process.exit(2);
    };
    const seed = if (args.len >= 8)
        try std.fmt.parseInt(u64, args[7], 10)
    else
        0;
    const max_rounds = if (args.len >= 9)
        try std.fmt.parseInt(u32, args[8], 10)
    else
        4096;
    const fact_count = if (args.len >= 10)
        try std.fmt.parseInt(usize, args[9], 10)
    else
        population_size;

    const result = try scaling.run(.{
        .population_size = population_size,
        .fact_count = fact_count,
        .topology = topology,
        .redundancy = redundancy,
        .bandwidth = bandwidth,
        .policy = policy,
        .seed = seed,
        .max_rounds = max_rounds,
    });

    const out = std.Io.File.stdout();
    try write(io, out, "Stage 5A information diffusion run\n", .{});
    try write(io, out, "population: {d}\n", .{result.config.population_size});
    try write(io, out, "facts: {d}\n", .{result.config.fact_count});
    try write(io, out, "topology: {s}\n", .{result.config.topology.name()});
    try write(io, out, "diameter: {d}\n", .{result.diameter});
    try write(io, out, "edges: {d}\n", .{result.edges});
    try write(io, out, "redundancy: {d}\n", .{result.config.redundancy});
    try write(io, out, "bandwidth: {d}\n", .{result.config.bandwidth});
    try write(io, out, "policy: {s}\n", .{result.config.policy.name()});
    try write(io, out, "seed: {d}\n", .{result.config.seed});
    try write(io, out, "success: {s}\n", .{if (result.success) "yes" else "no"});
    try write(io, out, "rounds: {d}\n", .{result.rounds});
    try write(io, out, "collector_initial_facts: {d}\n", .{result.collector_initial_facts});
    try write(io, out, "collector_final_facts: {d}\n", .{result.collector_final_facts});
    try write(io, out, "policy_calls: {d}\n", .{result.policy_calls});
    try write(io, out, "actions_proposed: {d}\n", .{result.actions_proposed});
    try write(io, out, "rejected_actions: {d}\n", .{result.rejected_actions});
    try write(io, out, "messages: {d}\n", .{result.messages});
    try write(io, out, "communication_units: {d}\n", .{result.communication_units});
    try write(io, out, "useful_deliveries: {d}\n", .{result.useful_deliveries});
    try write(io, out, "duplicate_deliveries: {d}\n", .{result.duplicate_deliveries});
    try write(io, out, "useful_per_1000_units: {d}\n", .{result.usefulPerThousandUnits()});
    try write(io, out, "violations: {d}\n", .{result.violations});

    if (!result.success or result.violations != 0) std.process.exit(1);
}

fn sweep(io: std.Io, full: bool) !void {
    const smoke_populations = [_]usize{ 5, 10, 20, 50 };
    const full_populations = [_]usize{ 5, 10, 20, 50, 100, 250, 500, 1000 };
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const redundancies = [_]usize{ 1, 2, 4 };
    const bandwidths = [_]usize{ 1, 2, 4, 8 };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };
    const seeds = [_]u64{ 0, 1, 2 };

    const out = std.Io.File.stdout();
    try out.writeStreamingAll(
        io,
        "population\tfacts\ttopology\tdiameter\tedges\tredundancy\tbandwidth\tpolicy\tseed\tsuccess\trounds\tcollector_initial\tcollector_final\tpolicy_calls\tactions\trejected\tmessages\tcomm_units\tuseful\tduplicate\tuseful_per_1000\tviolations\n",
    );

    if (full) {
        for (full_populations) |population_size| {
            try sweepPopulation(
                io,
                out,
                population_size,
                &topologies,
                &redundancies,
                &bandwidths,
                &policies,
                &seeds,
                true,
            );
        }
    } else {
        for (smoke_populations) |population_size| {
            try sweepPopulation(
                io,
                out,
                population_size,
                &topologies,
                &redundancies,
                &bandwidths,
                &policies,
                &seeds,
                false,
            );
        }
    }
}

fn sweepPopulation(
    io: std.Io,
    out: std.Io.File,
    population_size: usize,
    topologies: []const scaling.TopologyKind,
    redundancies: []const usize,
    bandwidths: []const usize,
    policies: []const scaling.PolicyKind,
    seeds: []const u64,
    full: bool,
) !void {
    for (topologies) |topology| {
        for (redundancies) |redundancy| {
            if (!full and redundancy > 2) continue;

            for (bandwidths) |bandwidth| {
                if (bandwidth > population_size) continue;
                if (!full and bandwidth != 1 and bandwidth != 4) continue;

                for (policies) |policy| {
                    for (seeds) |seed| {
                        if (!full and seed > 1) continue;

                        const result = try scaling.run(.{
                            .population_size = population_size,
                            .fact_count = population_size,
                            .topology = topology,
                            .redundancy = redundancy,
                            .bandwidth = bandwidth,
                            .policy = policy,
                            .seed = seed,
                            .max_rounds = 4096,
                        });
                        try writeTsvRow(io, out, result);
                    }
                }
            }
        }
    }
}

fn writeTsvRow(io: std.Io, out: std.Io.File, result: scaling.Result) !void {
    try write(
        io,
        out,
        "{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{s}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            result.config.population_size,
            result.config.fact_count,
            result.config.topology.name(),
            result.diameter,
            result.edges,
            result.config.redundancy,
            result.config.bandwidth,
            result.config.policy.name(),
            result.config.seed,
            if (result.success) "yes" else "no",
            result.rounds,
            result.collector_initial_facts,
            result.collector_final_facts,
            result.policy_calls,
            result.actions_proposed,
            result.rejected_actions,
            result.messages,
            result.communication_units,
            result.useful_deliveries,
            result.duplicate_deliveries,
            result.usefulPerThousandUnits(),
            result.violations,
        },
    );
}

fn parseTopology(text: []const u8) ?scaling.TopologyKind {
    if (std.mem.eql(u8, text, "ring")) return .ring;
    if (std.mem.eql(u8, text, "grid")) return .grid;
    if (std.mem.eql(u8, text, "complete")) return .complete;
    return null;
}

fn parsePolicy(text: []const u8) ?scaling.PolicyKind {
    if (std.mem.eql(u8, text, "round_robin")) return .round_robin;
    if (std.mem.eql(u8, text, "seeded")) return .seeded;
    if (std.mem.eql(u8, text, "novel_first")) return .novel_first;
    return null;
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  zig run src/stage5a_cli.zig -- validate\n" ++
            "  zig run src/stage5a_cli.zig -- run <population> <ring|grid|complete> <redundancy> <bandwidth> <round_robin|seeded|novel_first> [seed] [max_rounds] [fact_count]\n" ++
            "  zig run src/stage5a_cli.zig -- sweep [smoke|full]\n",
    );
}

fn write(io: std.Io, out: std.Io.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "CLI enum parsers reject unknown values" {
    try std.testing.expectEqual(scaling.TopologyKind.ring, parseTopology("ring").?);
    try std.testing.expect(parseTopology("mesh") == null);
    try std.testing.expectEqual(scaling.PolicyKind.novel_first, parsePolicy("novel_first").?);
    try std.testing.expect(parsePolicy("llm") == null);
}
