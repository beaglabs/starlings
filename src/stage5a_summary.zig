const std = @import("std");
const scaling = @import("stage5a_scaling.zig");

pub const max_rows: usize = 1024;
pub const canonical_rows: usize = 918;
pub const canonical_population_rows: usize = 162;
pub const canonical_information_rows: usize = 216;
pub const canonical_capacity_rows: usize = 540;
pub const canonical_sha256 = "92279da22ded432f942b24f96f4f4658ee49174ba45c66239537744bee988fc6";

pub const Series = enum {
    population,
    information,
    capacity,

    pub fn name(self: Series) []const u8 {
        return switch (self) {
            .population => "population",
            .information => "information",
            .capacity => "capacity",
        };
    }
};

pub const Row = struct {
    series: Series,
    population: usize,
    facts: usize,
    topology: scaling.TopologyKind,
    diameter: usize,
    edges: usize,
    redundancy: usize,
    bandwidth: usize,
    policy: scaling.PolicyKind,
    seed: u64,
    success: bool,
    rounds: u32,
    collector_initial: usize,
    collector_final: usize,
    policy_calls: u64,
    actions: u64,
    rejected: u64,
    messages: u64,
    comm_units: u64,
    useful: u64,
    duplicate: u64,
    useful_per_1000: u64,
    violations: u64,

    pub fn completionPermille(self: Row) u64 {
        if (self.facts == 0) return 0;
        return (@as(u64, @intCast(self.collector_final)) * 1000) /
            @as(u64, @intCast(self.facts));
    }
};

pub const Summary = struct {
    rows: [max_rows]Row = undefined,
    row_count: usize = 0,
    malformed_rows: usize = 0,
    header_seen: bool = false,
    sha256_hex: [64]u8 = undefined,

    pub fn seriesCount(self: *const Summary, series: Series) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.series == series) count += 1;
        }
        return count;
    }

    pub fn violationCount(self: *const Summary) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.violations != 0) count += 1;
        }
        return count;
    }

    pub fn successCount(self: *const Summary) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.success) count += 1;
        }
        return count;
    }

    pub fn censoredCount(self: *const Summary) usize {
        return self.row_count - self.successCount();
    }

    pub fn isCanonical(self: *const Summary) bool {
        return self.header_seen and
            self.malformed_rows == 0 and
            self.row_count == canonical_rows and
            self.seriesCount(.population) == canonical_population_rows and
            self.seriesCount(.information) == canonical_information_rows and
            self.seriesCount(.capacity) == canonical_capacity_rows and
            self.violationCount() == 0 and
            std.mem.eql(u8, &self.sha256_hex, canonical_sha256);
    }
};

const Filter = struct {
    series: ?Series = null,
    topology: ?scaling.TopologyKind = null,
    policy: ?scaling.PolicyKind = null,
    population: ?usize = null,
    facts: ?usize = null,
    redundancy: ?usize = null,
    bandwidth: ?usize = null,

    fn matches(self: Filter, row: Row) bool {
        if (self.series) |v| {
            if (row.series != v) return false;
        }
        if (self.topology) |v| {
            if (row.topology != v) return false;
        }
        if (self.policy) |v| {
            if (row.policy != v) return false;
        }
        if (self.population) |v| {
            if (row.population != v) return false;
        }
        if (self.facts) |v| {
            if (row.facts != v) return false;
        }
        if (self.redundancy) |v| {
            if (row.redundancy != v) return false;
        }
        if (self.bandwidth) |v| {
            if (row.bandwidth != v) return false;
        }
        return true;
    }
};

pub const Metrics = struct {
    runs: usize = 0,
    successes: usize = 0,
    censored: usize = 0,
    violations: u64 = 0,
    success_rounds_sum: u64 = 0,
    success_rounds_min: u32 = 0,
    success_rounds_max: u32 = 0,
    success_rounds_median: u32 = 0,
    comm_units_sum: u64 = 0,
    useful_sum: u64 = 0,
    duplicate_sum: u64 = 0,
    censored_completion_permille_sum: u64 = 0,

    pub fn successRatePermille(self: Metrics) u64 {
        if (self.runs == 0) return 0;
        return (@as(u64, @intCast(self.successes)) * 1000) /
            @as(u64, @intCast(self.runs));
    }

    pub fn averageSuccessRoundsTenths(self: Metrics) u64 {
        if (self.successes == 0) return 0;
        return (self.success_rounds_sum * 10) /
            @as(u64, @intCast(self.successes));
    }

    pub fn averageCommunicationUnits(self: Metrics) u64 {
        if (self.runs == 0) return 0;
        return self.comm_units_sum / @as(u64, @intCast(self.runs));
    }

    pub fn usefulPerThousand(self: Metrics) u64 {
        if (self.comm_units_sum == 0) return 0;
        return (self.useful_sum * 1000) / self.comm_units_sum;
    }

    pub fn duplicatePermille(self: Metrics) u64 {
        if (self.comm_units_sum == 0) return 0;
        return (self.duplicate_sum * 1000) / self.comm_units_sum;
    }

    pub fn censoredCompletionPermille(self: Metrics) u64 {
        if (self.censored == 0) return 0;
        return self.censored_completion_permille_sum /
            @as(u64, @intCast(self.censored));
    }
};

pub fn summarizeTsv(tsv: []const u8) Summary {
    var summary = Summary{};
    hashHex(tsv, &summary.sha256_hex);

    var lines = std.mem.splitScalar(u8, tsv, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (line_number == 1 and std.mem.startsWith(u8, line, "series\t")) {
            summary.header_seen = true;
            continue;
        }

        const row = parseRow(line) catch {
            summary.malformed_rows += 1;
            continue;
        };
        if (summary.row_count >= max_rows) {
            summary.malformed_rows += 1;
            continue;
        }
        summary.rows[summary.row_count] = row;
        summary.row_count += 1;
    }
    return summary;
}

pub fn aggregate(summary: *const Summary, filter: Filter) Metrics {
    var metrics = Metrics{};
    var successful_rounds: [max_rows]u32 = undefined;
    var successful_count: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        if (!filter.matches(row)) continue;

        metrics.runs += 1;
        metrics.violations +%= row.violations;
        metrics.comm_units_sum +%= row.comm_units;
        metrics.useful_sum +%= row.useful;
        metrics.duplicate_sum +%= row.duplicate;

        if (row.success) {
            metrics.successes += 1;
            metrics.success_rounds_sum +%= row.rounds;
            successful_rounds[successful_count] = row.rounds;
            successful_count += 1;

            if (metrics.successes == 1 or row.rounds < metrics.success_rounds_min) {
                metrics.success_rounds_min = row.rounds;
            }
            if (row.rounds > metrics.success_rounds_max) {
                metrics.success_rounds_max = row.rounds;
            }
        } else {
            metrics.censored += 1;
            metrics.censored_completion_permille_sum +%= row.completionPermille();
        }
    }

    if (successful_count != 0) {
        insertionSortU32(successful_rounds[0..successful_count]);
        const middle = successful_count / 2;
        metrics.success_rounds_median = if ((successful_count % 2) == 1)
            successful_rounds[middle]
        else
            @intCast(
                (@as(u64, @intCast(successful_rounds[middle - 1])) +
                    @as(u64, @intCast(successful_rounds[middle]))) / 2,
            );
    }

    return metrics;
}

fn insertionSortU32(values: []u32) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const value = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > value) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = value;
    }
}

fn parseRow(line: []const u8) !Row {
    var fields: [23][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, line, '\t');
    while (iterator.next()) |field| {
        if (count >= fields.len) return error.InvalidFieldCount;
        fields[count] = field;
        count += 1;
    }
    if (count != fields.len) return error.InvalidFieldCount;
    for (fields) |field| {
        if (field.len == 0) return error.EmptyField;
    }

    return .{
        .series = try parseSeries(fields[0]),
        .population = try std.fmt.parseInt(usize, fields[1], 10),
        .facts = try std.fmt.parseInt(usize, fields[2], 10),
        .topology = try parseTopology(fields[3]),
        .diameter = try std.fmt.parseInt(usize, fields[4], 10),
        .edges = try std.fmt.parseInt(usize, fields[5], 10),
        .redundancy = try std.fmt.parseInt(usize, fields[6], 10),
        .bandwidth = try std.fmt.parseInt(usize, fields[7], 10),
        .policy = try parsePolicy(fields[8]),
        .seed = try std.fmt.parseInt(u64, fields[9], 10),
        .success = try parseBool(fields[10]),
        .rounds = try std.fmt.parseInt(u32, fields[11], 10),
        .collector_initial = try std.fmt.parseInt(usize, fields[12], 10),
        .collector_final = try std.fmt.parseInt(usize, fields[13], 10),
        .policy_calls = try std.fmt.parseInt(u64, fields[14], 10),
        .actions = try std.fmt.parseInt(u64, fields[15], 10),
        .rejected = try std.fmt.parseInt(u64, fields[16], 10),
        .messages = try std.fmt.parseInt(u64, fields[17], 10),
        .comm_units = try std.fmt.parseInt(u64, fields[18], 10),
        .useful = try std.fmt.parseInt(u64, fields[19], 10),
        .duplicate = try std.fmt.parseInt(u64, fields[20], 10),
        .useful_per_1000 = try std.fmt.parseInt(u64, fields[21], 10),
        .violations = try std.fmt.parseInt(u64, fields[22], 10),
    };
}

fn parseSeries(text: []const u8) !Series {
    if (std.mem.eql(u8, text, "population")) return .population;
    if (std.mem.eql(u8, text, "information")) return .information;
    if (std.mem.eql(u8, text, "capacity")) return .capacity;
    return error.UnknownSeries;
}

fn parseTopology(text: []const u8) !scaling.TopologyKind {
    if (std.mem.eql(u8, text, "ring")) return .ring;
    if (std.mem.eql(u8, text, "grid")) return .grid;
    if (std.mem.eql(u8, text, "complete")) return .complete;
    return error.UnknownTopology;
}

fn parsePolicy(text: []const u8) !scaling.PolicyKind {
    if (std.mem.eql(u8, text, "round_robin")) return .round_robin;
    if (std.mem.eql(u8, text, "seeded")) return .seeded;
    if (std.mem.eql(u8, text, "novel_first")) return .novel_first;
    return error.UnknownPolicy;
}

fn parseBool(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "yes")) return true;
    if (std.mem.eql(u8, text, "no")) return false;
    return error.InvalidBoolean;
}

fn hashHex(input: []const u8, output: *[64]u8) void {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    hasher.update(input);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = alphabet[byte >> 4];
        output[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        try usage(io);
        std.process.exit(2);
    }

    const tsv = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[1],
        allocator,
        .limited(64 * 1024 * 1024),
    );
    defer allocator.free(tsv);

    const summary = summarizeTsv(tsv);
    const out = std.Io.File.stdout();
    try writeSummary(io, out, &summary);

    if (summary.malformed_rows != 0 or summary.violationCount() != 0) {
        std.process.exit(2);
    }
}

fn writeSummary(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    const overall = aggregate(summary, .{});

    try writeLine(io, out, "Stage 5A.2 Deterministic Dataset Summary\n", .{});
    try writeLine(io, out, "sha256: {s}\n", .{summary.sha256_hex[0..]});
    try writeLine(io, out, "expected_sha256: {s}\n", .{canonical_sha256});
    try writeLine(io, out, "canonical: {s}\n", .{if (summary.isCanonical()) "yes" else "no"});
    try writeLine(io, out, "rows: {d}\n", .{summary.row_count});
    try writeLine(io, out, "malformed_rows: {d}\n", .{summary.malformed_rows});
    try writeLine(io, out, "violating_rows: {d}\n", .{summary.violationCount()});
    try writeLine(io, out, "population_rows: {d}\n", .{summary.seriesCount(.population)});
    try writeLine(io, out, "information_rows: {d}\n", .{summary.seriesCount(.information)});
    try writeLine(io, out, "capacity_rows: {d}\n", .{summary.seriesCount(.capacity)});
    try writeLine(io, out, "successes: {d}\n", .{overall.successes});
    try writeLine(io, out, "horizon_exhausted: {d}\n", .{overall.censored});
    try writePercentPermille(io, out, "success_rate", overall.successRatePermille());
    try writeLine(io, out, "\n", .{});

    try writeMetricsHeader(io, out, "overall empirical metrics");
    try writeMetricsRow(io, out, "all", overall);

    try writeTopologyPolicy(io, out, summary);
    try writePopulationScaling(io, out, summary);
    try writeInformationScaling(io, out, summary);
    try writeCapacityScaling(io, out, summary);
    try writeCensoringBoundaries(io, out, summary);
    try writeExtrema(io, out, summary);
    try writeCensored(io, out, summary);
}

fn writeMetricsHeader(io: std.Io, out: std.Io.File, title: []const u8) !void {
    try writeLine(io, out, "{s}\n", .{title});
    try out.writeStreamingAll(
        io,
        "group\truns\tsuccess\tcensored\tsuccess-rate\tavg-rounds-success\tmedian-rounds-success\tmin-rounds-success\tmax-rounds-success\tavg-comm-units\tuseful-per-1000\tduplicate-permille\tcensored-completion\n",
    );
}

fn writeMetricsRow(io: std.Io, out: std.Io.File, name: []const u8, metrics: Metrics) !void {
    const avg_rounds = metrics.averageSuccessRoundsTenths();
    try writeLine(
        io,
        out,
        "{s}\t{d}\t{d}\t{d}\t{d}.{d}%\t{d}.{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}.{d}%\n",
        .{
            name,
            metrics.runs,
            metrics.successes,
            metrics.censored,
            metrics.successRatePermille() / 10,
            metrics.successRatePermille() % 10,
            avg_rounds / 10,
            avg_rounds % 10,
            metrics.success_rounds_median,
            metrics.success_rounds_min,
            metrics.success_rounds_max,
            metrics.averageCommunicationUnits(),
            metrics.usefulPerThousand(),
            metrics.duplicatePermille(),
            metrics.censoredCompletionPermille() / 10,
            metrics.censoredCompletionPermille() % 10,
        },
    );
}

fn writeTopologyPolicy(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(io, out, "\ntopology x policy\n", .{});
    try out.writeStreamingAll(
        io,
        "topology\tpolicy\truns\tsuccess\tcensored\tsuccess-rate\tavg-rounds-success\tmedian-rounds-success\tavg-comm-units\tuseful-per-1000\tduplicate-permille\tcensored-completion\n",
    );

    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };
    for (topologies) |topology| {
        for (policies) |policy| {
            const metrics = aggregate(summary, .{ .topology = topology, .policy = policy });
            const avg_rounds = metrics.averageSuccessRoundsTenths();
            try writeLine(
                io,
                out,
                "{s}\t{s}\t{d}\t{d}\t{d}\t{d}.{d}%\t{d}.{d}\t{d}\t{d}\t{d}\t{d}\t{d}.{d}%\n",
                .{
                    topology.name(),
                    policy.name(),
                    metrics.runs,
                    metrics.successes,
                    metrics.censored,
                    metrics.successRatePermille() / 10,
                    metrics.successRatePermille() % 10,
                    avg_rounds / 10,
                    avg_rounds % 10,
                    metrics.success_rounds_median,
                    metrics.averageCommunicationUnits(),
                    metrics.usefulPerThousand(),
                    metrics.duplicatePermille(),
                    metrics.censoredCompletionPermille() / 10,
                    metrics.censoredCompletionPermille() % 10,
                },
            );
        }
    }
}

fn writePopulationScaling(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(io, out, "\npopulation scaling (F=32 R=2 B=2)\n", .{});
    try out.writeStreamingAll(
        io,
        "N\ttopology\tpolicy\truns\tsuccess\tcensored\tmedian-rounds-success\tavg-comm-units\tuseful-per-1000\n",
    );

    const populations = [_]usize{ 20, 50, 100, 250, 500, 1000 };
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };
    for (populations) |population| {
        for (topologies) |topology| {
            for (policies) |policy| {
                const metrics = aggregate(summary, .{
                    .series = .population,
                    .population = population,
                    .topology = topology,
                    .policy = policy,
                });
                try writeLine(
                    io,
                    out,
                    "{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                    .{
                        population,
                        topology.name(),
                        policy.name(),
                        metrics.runs,
                        metrics.successes,
                        metrics.censored,
                        metrics.success_rounds_median,
                        metrics.averageCommunicationUnits(),
                        metrics.usefulPerThousand(),
                    },
                );
            }
        }
    }
}

fn writeInformationScaling(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(io, out, "\ninformation scaling (N=128 R=2 B=2)\n", .{});
    try out.writeStreamingAll(
        io,
        "F\ttopology\tpolicy\truns\tsuccess\tcensored\tmedian-rounds-success\tavg-comm-units\tuseful-per-1000\n",
    );

    const facts_values = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024 };
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };
    for (facts_values) |facts| {
        for (topologies) |topology| {
            for (policies) |policy| {
                const metrics = aggregate(summary, .{
                    .series = .information,
                    .facts = facts,
                    .topology = topology,
                    .policy = policy,
                });
                try writeLine(
                    io,
                    out,
                    "{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                    .{
                        facts,
                        topology.name(),
                        policy.name(),
                        metrics.runs,
                        metrics.successes,
                        metrics.censored,
                        metrics.success_rounds_median,
                        metrics.averageCommunicationUnits(),
                        metrics.usefulPerThousand(),
                    },
                );
            }
        }
    }
}

fn writeCapacityScaling(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(io, out, "\ncapacity scaling (N=128 F=128)\n", .{});
    try out.writeStreamingAll(
        io,
        "R\tB\ttopology\tpolicy\truns\tsuccess\tcensored\tmedian-rounds-success\tavg-comm-units\tuseful-per-1000\n",
    );

    const redundancies = [_]usize{ 1, 2, 4, 8 };
    const bandwidths = [_]usize{ 1, 2, 4, 8, 16 };
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };

    for (redundancies) |redundancy| {
        for (bandwidths) |bandwidth| {
            for (topologies) |topology| {
                for (policies) |policy| {
                    const metrics = aggregate(summary, .{
                        .series = .capacity,
                        .redundancy = redundancy,
                        .bandwidth = bandwidth,
                        .topology = topology,
                        .policy = policy,
                    });
                    try writeLine(
                        io,
                        out,
                        "{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                        .{
                            redundancy,
                            bandwidth,
                            topology.name(),
                            policy.name(),
                            metrics.runs,
                            metrics.successes,
                            metrics.censored,
                            metrics.success_rounds_median,
                            metrics.averageCommunicationUnits(),
                            metrics.usefulPerThousand(),
                        },
                    );
                }
            }
        }
    }
}

fn writeCensoringBoundaries(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(io, out, "\nfirst observed censoring boundaries\n", .{});
    try out.writeStreamingAll(
        io,
        "series\ttopology\tpolicy\tfirst-censored-value\tcensored-runs-at-boundary\n",
    );

    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };

    for (topologies) |topology| {
        for (policies) |policy| {
            try writeFirstPopulationBoundary(io, out, summary, topology, policy);
            try writeFirstInformationBoundary(io, out, summary, topology, policy);
        }
    }
}

fn writeFirstPopulationBoundary(
    io: std.Io,
    out: std.Io.File,
    summary: *const Summary,
    topology: scaling.TopologyKind,
    policy: scaling.PolicyKind,
) !void {
    const populations = [_]usize{ 20, 50, 100, 250, 500, 1000 };
    for (populations) |population| {
        const metrics = aggregate(summary, .{
            .series = .population,
            .population = population,
            .topology = topology,
            .policy = policy,
        });
        if (metrics.censored != 0) {
            try writeLine(
                io,
                out,
                "population\t{s}\t{s}\tN={d}\t{d}\n",
                .{ topology.name(), policy.name(), population, metrics.censored },
            );
            return;
        }
    }
    try writeLine(
        io,
        out,
        "population\t{s}\t{s}\tnone-through-N=1000\t0\n",
        .{ topology.name(), policy.name() },
    );
}

fn writeFirstInformationBoundary(
    io: std.Io,
    out: std.Io.File,
    summary: *const Summary,
    topology: scaling.TopologyKind,
    policy: scaling.PolicyKind,
) !void {
    const facts_values = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024 };
    for (facts_values) |facts| {
        const metrics = aggregate(summary, .{
            .series = .information,
            .facts = facts,
            .topology = topology,
            .policy = policy,
        });
        if (metrics.censored != 0) {
            try writeLine(
                io,
                out,
                "information\t{s}\t{s}\tF={d}\t{d}\n",
                .{ topology.name(), policy.name(), facts, metrics.censored },
            );
            return;
        }
    }
    try writeLine(
        io,
        out,
        "information\t{s}\t{s}\tnone-through-F=1024\t0\n",
        .{ topology.name(), policy.name() },
    );
}

fn writeExtrema(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    var fastest: ?Row = null;
    var slowest: ?Row = null;
    var most_efficient: ?Row = null;
    var least_efficient: ?Row = null;

    for (summary.rows[0..summary.row_count]) |row| {
        if (row.success) {
            if (fastest == null or row.rounds < fastest.?.rounds) fastest = row;
            if (slowest == null or row.rounds > slowest.?.rounds) slowest = row;
        }
        if (row.comm_units != 0) {
            if (most_efficient == null or row.useful_per_1000 > most_efficient.?.useful_per_1000) {
                most_efficient = row;
            }
            if (least_efficient == null or row.useful_per_1000 < least_efficient.?.useful_per_1000) {
                least_efficient = row;
            }
        }
    }

    try writeLine(io, out, "\nempirical extrema\n", .{});
    if (fastest) |row| try writeExtremum(io, out, "fastest_success", row);
    if (slowest) |row| try writeExtremum(io, out, "slowest_success", row);
    if (most_efficient) |row| try writeExtremum(io, out, "highest_useful_efficiency", row);
    if (least_efficient) |row| try writeExtremum(io, out, "lowest_useful_efficiency", row);
}

fn writeExtremum(io: std.Io, out: std.Io.File, label: []const u8, row: Row) !void {
    try writeLine(
        io,
        out,
        "{s}: series={s} N={d} F={d} topology={s} R={d} B={d} policy={s} seed={d} success={s} rounds={d} comm={d} useful_per_1000={d}\n",
        .{
            label,
            row.series.name(),
            row.population,
            row.facts,
            row.topology.name(),
            row.redundancy,
            row.bandwidth,
            row.policy.name(),
            row.seed,
            if (row.success) "yes" else "no",
            row.rounds,
            row.comm_units,
            row.useful_per_1000,
        },
    );
}

fn writeCensored(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(io, out, "\nhorizon-exhausted runs (right-censored T_conv > rounds)\n", .{});
    try out.writeStreamingAll(
        io,
        "series\tN\tF\ttopology\tR\tB\tpolicy\tseed\trounds\tcollector-final\tcompletion\tcomm-units\tuseful-per-1000\n",
    );

    for (summary.rows[0..summary.row_count]) |row| {
        if (row.success) continue;
        try writeLine(
            io,
            out,
            "{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}/{d}\t{d}.{d}%\t{d}\t{d}\n",
            .{
                row.series.name(),
                row.population,
                row.facts,
                row.topology.name(),
                row.redundancy,
                row.bandwidth,
                row.policy.name(),
                row.seed,
                row.rounds,
                row.collector_final,
                row.facts,
                row.completionPermille() / 10,
                row.completionPermille() % 10,
                row.comm_units,
                row.useful_per_1000,
            },
        );
    }
}

fn writePercentPermille(io: std.Io, out: std.Io.File, label: []const u8, value: u64) !void {
    try writeLine(io, out, "{s}: {d}.{d}%\n", .{ label, value / 10, value % 10 });
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage: zig run src/stage5a_summary.zig -- <stage5a.tsv>\n",
    );
}

fn writeLine(io: std.Io, out: std.Io.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "summary parses success and censored rows without treating censoring as convergence" {
    const tsv =
        "series\tpopulation\tfacts\ttopology\tdiameter\tedges\tredundancy\tbandwidth\tpolicy\tseed\tsuccess\trounds\tcollector_initial\tcollector_final\tpolicy_calls\tactions\trejected\tmessages\tcomm_units\tuseful\tduplicate\tuseful_per_1000\tviolations\n" ++
        "population\t20\t32\tring\t10\t20\t2\t2\tround_robin\t0\tyes\t39\t2\t32\t780\t779\t0\t1558\t3108\t545\t2563\t175\t0\n" ++
        "population\t1000\t32\tring\t500\t1000\t2\t2\tseeded\t0\tno\t4096\t1\t31\t4096000\t4088696\t0\t8177392\t16337444\t30886\t16306558\t1\t0\n";

    const summary = summarizeTsv(tsv);
    const metrics = aggregate(&summary, .{});

    try std.testing.expect(summary.header_seen);
    try std.testing.expectEqual(@as(usize, 2), summary.row_count);
    try std.testing.expectEqual(@as(usize, 0), summary.malformed_rows);
    try std.testing.expectEqual(@as(usize, 1), metrics.successes);
    try std.testing.expectEqual(@as(usize, 1), metrics.censored);
    try std.testing.expectEqual(@as(u32, 39), metrics.success_rounds_median);
    try std.testing.expectEqual(@as(u64, 968), metrics.censoredCompletionPermille());
}

test "median uses only successful convergence times" {
    const tsv =
        "series\tpopulation\tfacts\ttopology\tdiameter\tedges\tredundancy\tbandwidth\tpolicy\tseed\tsuccess\trounds\tcollector_initial\tcollector_final\tpolicy_calls\tactions\trejected\tmessages\tcomm_units\tuseful\tduplicate\tuseful_per_1000\tviolations\n" ++
        "population\t20\t32\tring\t10\t20\t2\t2\tround_robin\t0\tyes\t10\t2\t32\t1\t1\t0\t1\t2\t1\t1\t500\t0\n" ++
        "population\t20\t32\tring\t10\t20\t2\t2\tround_robin\t1\tno\t4096\t2\t31\t1\t1\t0\t1\t2\t1\t1\t500\t0\n" ++
        "population\t20\t32\tring\t10\t20\t2\t2\tround_robin\t2\tyes\t30\t2\t32\t1\t1\t0\t1\t2\t1\t1\t500\t0\n";

    const summary = summarizeTsv(tsv);
    const metrics = aggregate(&summary, .{});
    try std.testing.expectEqual(@as(u32, 20), metrics.success_rounds_median);
    try std.testing.expectEqual(@as(u64, 200), metrics.averageSuccessRoundsTenths());
}

test "row parser rejects malformed field counts" {
    try std.testing.expectError(
        error.InvalidFieldCount,
        parseRow("population\t20\t32"),
    );
}

test "sha256 identity uses canonical lowercase hexadecimal encoding" {
    var output: [64]u8 = undefined;
    hashHex("abc", &output);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        output[0..],
    );
}
