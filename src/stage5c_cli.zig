const std = @import("std");
const scaling = @import("stage5a_scaling.zig");
const regimes = @import("stage5c_regimes.zig");
const summary = @import("stage5c_summary.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try usage(io);
        std.process.exit(2);
    }

    if (std.mem.eql(u8, args[1], "validate")) {
        try validate(io);
        return;
    }

    if (std.mem.eql(u8, args[1], "plan")) {
        const full = parseProfile(args);
        const out = std.Io.File.stdout();
        try writeLine(io, out, "Stage 5C experiment plan\n", .{});
        try writeLine(io, out, "profile: {s}\n", .{if (full) "full" else "smoke"});
        try writeLine(
            io,
            out,
            "boundary_base_cases: {d}\n",
            .{if (full) regimes.boundaryPlanCount() else smokeBoundaryCount()},
        );
        try writeLine(
            io,
            out,
            "saturation_threshold_cases: {d}\n",
            .{if (full) regimes.saturationPlanCount() else smokeSaturationCount()},
        );
        try writeLine(
            io,
            out,
            "boundary_horizons: {d} -> {d} only when censored\n",
            .{ regimes.boundary_base_horizon, regimes.boundary_extended_horizon },
        );
        return;
    }

    if (std.mem.eql(u8, args[1], "boundary")) {
        const full = parseProfile(args);
        try runBoundarySweep(io, full);
        return;
    }

    if (std.mem.eql(u8, args[1], "saturation")) {
        const full = parseProfile(args);
        try runSaturationSweep(io, full);
        return;
    }

    if (std.mem.eql(u8, args[1], "summarize-boundary")) {
        if (args.len != 3) {
            try usage(io);
            std.process.exit(2);
        }
        const tsv = try std.Io.Dir.cwd().readFileAlloc(
            io,
            args[2],
            allocator,
            .limited(128 * 1024 * 1024),
        );
        defer allocator.free(tsv);
        try writeBoundarySummary(io, summary.parseBoundaryTsv(tsv));
        return;
    }

    if (std.mem.eql(u8, args[1], "summarize-saturation")) {
        if (args.len != 3) {
            try usage(io);
            std.process.exit(2);
        }
        const tsv = try std.Io.Dir.cwd().readFileAlloc(
            io,
            args[2],
            allocator,
            .limited(128 * 1024 * 1024),
        );
        defer allocator.free(tsv);
        try writeSaturationSummary(io, summary.parseSaturationTsv(tsv));
        return;
    }

    try usage(io);
    std.process.exit(2);
}

fn parseProfile(args: []const []const u8) bool {
    if (args.len < 3) return false;
    if (std.mem.eql(u8, args[2], "smoke")) return false;
    if (std.mem.eql(u8, args[2], "full")) return true;
    return false;
}

fn validate(io: std.Io) !void {
    const boundary = try regimes.runBoundaryCase(
        128,
        .ring,
        2,
        .novel_first,
        0,
        64,
        256,
    );
    const saturation = try regimes.findSaturationThreshold(
        32,
        64,
        2,
        .round_robin,
        0,
    );

    const out = std.Io.File.stdout();
    try writeLine(io, out, "Stage 5C validation\n", .{});
    try writeLine(
        io,
        out,
        "boundary_violations: {d}\n",
        .{boundary.violations_4096 + boundary.violations_16384},
    );
    try writeLine(
        io,
        out,
        "saturation_min_bandwidth: {d}\n",
        .{saturation.min_bandwidth},
    );
    try writeLine(
        io,
        out,
        "saturation_below_threshold_success: {s}\n",
        .{if (saturation.below_threshold_success) "yes" else "no"},
    );
    try writeLine(io, out, "saturation_violations: {d}\n", .{saturation.violations});

    if (boundary.violations_4096 != 0 or
        boundary.violations_16384 != 0 or
        saturation.below_threshold_success or
        saturation.violations != 0)
    {
        std.process.exit(1);
    }
}

fn runBoundarySweep(io: std.Io, full: bool) !void {
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(
        io,
        "population\tfacts\ttopology\tdiameter\tredundancy\tbandwidth\tpolicy\tseed\tq_fb_x1000\tq_fdb_x1000\tq_fnb_x1000\tq_fdnrb_x1000\tsuccess_4096\trounds_4096\tcollector_4096\tcomm_4096\tuseful_4096\tduplicate_4096\tviolations_4096\textended_attempted\tsuccess_16384\trounds_16384\tcollector_16384\tcomm_16384\tuseful_16384\tduplicate_16384\tviolations_16384\n",
    );

    if (full) {
        for (regimes.boundary_facts) |facts| {
            for (regimes.boundary_topologies) |topology| {
                for (regimes.boundary_bandwidths) |bandwidth| {
                    for (regimes.all_policies) |policy| {
                        for (regimes.seeds) |seed| {
                            const record = try regimes.runCanonicalBoundaryCase(
                                facts,
                                topology,
                                bandwidth,
                                policy,
                                seed,
                            );
                            try writeBoundaryRow(io, out, record);
                        }
                    }
                }
            }
        }
        return;
    }

    const facts_values = [_]usize{ 256, 512, 1024 };
    const topologies = [_]scaling.TopologyKind{ .ring, .grid };
    for (facts_values) |facts| {
        for (topologies) |topology| {
            for (regimes.all_policies) |policy| {
                const record = try regimes.runBoundaryCase(
                    facts,
                    topology,
                    2,
                    policy,
                    0,
                    512,
                    2048,
                );
                try writeBoundaryRow(io, out, record);
            }
        }
    }
}

fn runSaturationSweep(io: std.Io, full: bool) !void {
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(
        io,
        "population\tfacts\tfacts_per_operator_x1000\tredundancy\tpolicy\tseed\tmin_bandwidth\tbandwidth_fraction_x1000\taggregate_capacity_x1000\tredundant_capacity_x1000\tcollector_initial\tcollector_final\tactive_senders\tselected_fact_units\tbelow_threshold_success\tviolations\n",
    );

    if (full) {
        for (regimes.saturation_populations) |population| {
            for (regimes.saturation_fact_ratio_permille) |ratio| {
                const facts = regimes.saturationFactCount(population, ratio);
                for (regimes.saturation_redundancies) |redundancy| {
                    for (regimes.all_policies) |policy| {
                        for (regimes.seeds) |seed| {
                            const record = try regimes.findSaturationThreshold(
                                population,
                                facts,
                                redundancy,
                                policy,
                                seed,
                            );
                            try writeSaturationRow(io, out, record);
                        }
                    }
                }
            }
        }
        return;
    }

    const populations = [_]usize{ 64, 128 };
    const ratios = [_]usize{ 1000, 2000 };
    const redundancies = [_]usize{ 1, 2 };
    for (populations) |population| {
        for (ratios) |ratio| {
            const facts = regimes.saturationFactCount(population, ratio);
            for (redundancies) |redundancy| {
                for (regimes.all_policies) |policy| {
                    const record = try regimes.findSaturationThreshold(
                        population,
                        facts,
                        redundancy,
                        policy,
                        0,
                    );
                    try writeSaturationRow(io, out, record);
                }
            }
        }
    }
}

fn writeBoundarySummary(io: std.Io, dataset: summary.BoundaryDataset) !void {
    const out = std.Io.File.stdout();
    try writeLine(io, out, "Stage 5C boundary summary\n", .{});
    try writeLine(io, out, "rows: {d}\n", .{dataset.row_count});
    try writeLine(io, out, "malformed_rows: {d}\n", .{dataset.malformed_rows});
    try writeLine(io, out, "violation_rows: {d}\n", .{dataset.violationRows()});
    try writeLine(io, out, "censored_4096: {d}\n", .{dataset.censored4096()});
    try writeLine(io, out, "delayed_convergence_by_16384: {d}\n", .{dataset.delayed()});
    try writeLine(io, out, "persistent_censoring_16384: {d}\n", .{dataset.persistent()});
    try writeLine(io, out, "boundary_value_0_means: not_observed_through_F_2048\n", .{});

    try out.writeStreamingAll(
        io,
        "\ntopology\tpolicy\tB\trows\tlast_all_success_4096\tfirst_any_censored_4096\tfirst_all_censored_4096\tlast_all_success_16384\tfirst_any_censored_16384\tfirst_all_censored_16384\tnonmonotonic_4096\tnonmonotonic_16384\tq_fb_x1000_at_first_4096\tq_fdb_x1000_at_first_4096\tq_fnb_x1000_at_first_4096\tq_fdnrb_x1000_at_first_4096\n",
    );

    for (regimes.boundary_topologies) |topology| {
        for (regimes.all_policies) |policy| {
            for (regimes.boundary_bandwidths) |bandwidth| {
                const band = summary.boundaryBand(
                    &dataset,
                    topology,
                    policy,
                    bandwidth,
                );
                const coordinate = summary.firstCensoredCoordinate4096(
                    &dataset,
                    topology,
                    policy,
                    bandwidth,
                );
                try writeLine(
                    io,
                    out,
                    "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                    .{
                        topology.name(),
                        policy.name(),
                        bandwidth,
                        band.rows,
                        band.last_all_success_4096,
                        band.first_any_censored_4096,
                        band.first_all_censored_4096,
                        band.last_all_success_16384,
                        band.first_any_censored_16384,
                        band.first_all_censored_16384,
                        band.nonmonotonic_4096,
                        band.nonmonotonic_16384,
                        coordinate.q_fb_x1000,
                        coordinate.q_fdb_x1000,
                        coordinate.q_fnb_x1000,
                        coordinate.q_fdnrb_x1000,
                    },
                );
            }
        }
    }

    if (dataset.malformed_rows != 0 or dataset.violationRows() != 0) {
        std.process.exit(2);
    }
}

fn writeSaturationSummary(io: std.Io, dataset: summary.SaturationDataset) !void {
    const out = std.Io.File.stdout();
    try writeLine(io, out, "Stage 5C saturation summary\n", .{});
    try writeLine(io, out, "rows: {d}\n", .{dataset.row_count});
    try writeLine(io, out, "malformed_rows: {d}\n", .{dataset.malformed_rows});
    try writeLine(io, out, "violation_rows: {d}\n", .{dataset.violationRows()});
    try writeLine(
        io,
        out,
        "threshold_minimality_failures: {d}\n",
        .{dataset.minimalityFailures()},
    );

    try out.writeStreamingAll(
        io,
        "\nscale invariance by policy x redundancy x F/N\npolicy\tR\tF_over_N_x1000\trows\tmedian_B_star\tmedian_NB_over_F_x1000\tmin_NB_over_F\tmax_NB_over_F\tspread_NB_permille\n",
    );
    for (regimes.all_policies) |policy| {
        for (regimes.saturation_redundancies) |redundancy| {
            for (regimes.saturation_fact_ratio_permille) |ratio| {
                const stats = summary.saturationStats(
                    &dataset,
                    policy,
                    redundancy,
                    ratio,
                );
                try writeLine(
                    io,
                    out,
                    "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                    .{
                        policy.name(),
                        redundancy,
                        ratio,
                        stats.rows,
                        stats.median_min_bandwidth,
                        stats.median_aggregate_capacity_x1000,
                        stats.min_aggregate_capacity_x1000,
                        stats.max_aggregate_capacity_x1000,
                        stats.aggregate_spread_permille,
                    },
                );
            }
        }
    }

    try out.writeStreamingAll(
        io,
        "\nredundancy normalization by policy x F/N\npolicy\tF_over_N_x1000\trows\tmedian_NB_over_F\tspread_NB_permille\tmedian_NRB_over_F\tspread_NRB_permille\n",
    );
    for (regimes.all_policies) |policy| {
        for (regimes.saturation_fact_ratio_permille) |ratio| {
            const stats = summary.saturationStats(
                &dataset,
                policy,
                null,
                ratio,
            );
            try writeLine(
                io,
                out,
                "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                .{
                    policy.name(),
                    ratio,
                    stats.rows,
                    stats.median_aggregate_capacity_x1000,
                    stats.aggregate_spread_permille,
                    stats.median_redundant_capacity_x1000,
                    stats.redundant_spread_permille,
                },
            );
        }
    }

    if (dataset.malformed_rows != 0 or
        dataset.violationRows() != 0 or
        dataset.minimalityFailures() != 0)
    {
        std.process.exit(2);
    }
}

fn writeBoundaryRow(
    io: std.Io,
    out: std.Io.File,
    row: regimes.BoundaryRecord,
) !void {
    try writeLine(
        io,
        out,
        "{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            row.population,
            row.facts,
            row.topology.name(),
            row.diameter,
            row.redundancy,
            row.bandwidth,
            row.policy.name(),
            row.seed,
            row.q_fb_x1000,
            row.q_fdb_x1000,
            row.q_fnb_x1000,
            row.q_fdnrb_x1000,
            yesNo(row.success_4096),
            row.rounds_4096,
            row.collector_4096,
            row.comm_4096,
            row.useful_4096,
            row.duplicate_4096,
            row.violations_4096,
            yesNo(row.extended_attempted),
            yesNo(row.success_16384),
            row.rounds_16384,
            row.collector_16384,
            row.comm_16384,
            row.useful_16384,
            row.duplicate_16384,
            row.violations_16384,
        },
    );
}

fn writeSaturationRow(
    io: std.Io,
    out: std.Io.File,
    row: regimes.SaturationRecord,
) !void {
    try writeLine(
        io,
        out,
        "{d}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{d}\n",
        .{
            row.population,
            row.facts,
            row.facts_per_operator_x1000,
            row.redundancy,
            row.policy.name(),
            row.seed,
            row.min_bandwidth,
            row.bandwidth_fraction_x1000,
            row.aggregate_capacity_x1000,
            row.redundant_capacity_x1000,
            row.collector_initial,
            row.collector_final,
            row.active_senders,
            row.selected_fact_units,
            yesNo(row.below_threshold_success),
            row.violations,
        },
    );
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn smokeBoundaryCount() usize {
    return 3 * 2 * 3;
}

fn smokeSaturationCount() usize {
    return 2 * 2 * 2 * 3;
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  zig run src/stage5c_cli.zig -- validate\n" ++
            "  zig run src/stage5c_cli.zig -- plan [smoke|full]\n" ++
            "  zig run src/stage5c_cli.zig -- boundary [smoke|full]\n" ++
            "  zig run src/stage5c_cli.zig -- saturation [smoke|full]\n" ++
            "  zig run src/stage5c_cli.zig -- summarize-boundary <boundary.tsv>\n" ++
            "  zig run src/stage5c_cli.zig -- summarize-saturation <saturation.tsv>\n",
    );
}

fn writeLine(
    io: std.Io,
    out: std.Io.File,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [8192]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "smoke plan sizes are fixed" {
    try std.testing.expectEqual(@as(usize, 18), smokeBoundaryCount());
    try std.testing.expectEqual(@as(usize, 24), smokeSaturationCount());
}
