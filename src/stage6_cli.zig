const std = @import("std");
const scaling = @import("stage5a_scaling.zig");
const perturb = @import("stage6_perturbation.zig");
const summary = @import("stage6_summary.zig");

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
        try writeLine(io, out, "Stage 6 perturbation plan\n", .{});
        try writeLine(io, out, "profile: {s}\n", .{if (full) "full" else "smoke"});
        try writeLine(
            io,
            out,
            "sparse_runs: {d}\n",
            .{if (full) perturb.sparsePlanCount() else smokeSparseCount()},
        );
        try writeLine(
            io,
            out,
            "coverage_threshold_searches: {d}\n",
            .{if (full) perturb.coveragePlanCount() else smokeCoverageCount()},
        );
        try writeLine(io, out, "sparse_horizon: {d}\n", .{perturb.horizon});
        return;
    }

    if (std.mem.eql(u8, args[1], "sparse")) {
        const full = parseProfile(args);
        try runSparseSweep(io, full);
        return;
    }

    if (std.mem.eql(u8, args[1], "coverage")) {
        const full = parseProfile(args);
        try runCoverageSweep(io, full);
        return;
    }

    if (std.mem.eql(u8, args[1], "summarize-sparse")) {
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
        const dataset = summary.parseSparseTsv(tsv);
        try writeSparseSummary(io, &dataset);
        return;
    }

    if (std.mem.eql(u8, args[1], "summarize-coverage")) {
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
        const dataset = summary.parseCoverageTsv(tsv);
        try writeCoverageSummary(io, &dataset);
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
    const sparse = try perturb.runSparseAnchor(
        perturb.sparse_anchors[0],
        .message_drop,
        25,
        0,
    );
    const coverage = try perturb.findCoverageThreshold(
        64,
        128,
        4,
        .seeded,
        0,
        .{
            .kind = .message_drop,
            .severity_permille = 100,
            .seed = perturb.perturbationSeed(0),
        },
    );

    const out = std.Io.File.stdout();
    try writeLine(io, out, "Stage 6 validation\n", .{});
    try writeLine(io, out, "sparse_violations: {d}\n", .{sparse.violations});
    try writeLine(
        io,
        out,
        "sparse_delivery_ratio_permille: {d}\n",
        .{sparse.deliveryRatioPermille()},
    );
    try writeLine(
        io,
        out,
        "coverage_reachable: {s}\n",
        .{yesNo(coverage.reachable)},
    );
    try writeLine(
        io,
        out,
        "coverage_baseline_B: {d}\n",
        .{coverage.baseline_bandwidth},
    );
    try writeLine(
        io,
        out,
        "coverage_perturbed_B: {d}\n",
        .{coverage.perturbed_bandwidth},
    );
    try writeLine(io, out, "coverage_violations: {d}\n", .{coverage.violations});

    if (sparse.violations != 0 or coverage.violations != 0) {
        std.process.exit(1);
    }
}

fn runSparseSweep(io: std.Io, full: bool) !void {
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(
        io,
        "anchor\tpopulation\tfacts\ttopology\tdiameter\tredundancy\tbandwidth\tpolicy\tlambda_x1e6\ttrial_seed\tperturbation\tseverity_permille\tperturbation_seed\tsuccess\trounds\tcollector_initial\tcollector_final\tpolicy_slots\tpolicy_calls\toperator_omissions\tactions\trejected\tattempted_messages\tdelivered_messages\tsuppressed_messages\tattempted_units\tdelivered_units\tsuppressed_units\tdelivery_ratio_permille\tuseful\tduplicate\tviolations\tremoved_edges\tcomponent_size\tcomponent_fact_coverage\tstructurally_reachable\n",
    );

    if (full) {
        const progress = std.Io.File.stderr();
        var completed: usize = 0;
        const total = perturb.sparsePlanCount();

        for (perturb.sparse_anchors) |anchor| {
            for (perturb.perturbation_kinds) |kind| {
                for (perturb.sparse_severities_permille) |severity| {
                    for (perturb.trial_seeds) |trial_seed| {
                        try writeLine(
                            io,
                            progress,
                            "[{d}/{d}] {s} {s} severity={d} seed={d}\n",
                            .{
                                completed + 1,
                                total,
                                anchor.id,
                                kind.name(),
                                severity,
                                trial_seed,
                            },
                        );

                        const result = try perturb.runSparseAnchor(
                            anchor,
                            kind,
                            severity,
                            trial_seed,
                        );
                        try writeSparseRow(io, out, anchor, trial_seed, result);
                        completed += 1;
                    }
                }
            }
        }
        return;
    }

    const anchor_indices = [_]usize{ 0, 2 };
    const severities = [_]u16{ 0, 100, 300 };
    for (anchor_indices) |anchor_index| {
        const anchor = perturb.sparse_anchors[anchor_index];
        for (perturb.perturbation_kinds) |kind| {
            for (severities) |severity| {
                const result = try perturb.runSparseAnchor(
                    anchor,
                    kind,
                    severity,
                    0,
                );
                try writeSparseRow(io, out, anchor, 0, result);
            }
        }
    }
}

fn runCoverageSweep(io: std.Io, full: bool) !void {
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(
        io,
        "population\tfacts\tfacts_per_operator_x1000\tredundancy\tpolicy\ttrial_seed\tperturbation\tseverity_permille\tperturbation_seed\tbaseline_bandwidth\tperturbed_bandwidth\treachable\tinflation_x1000\tcollector_initial\tcollector_final_at_threshold\tactive_senders\tdelivered_senders\tselected_fact_units\tsuppressed_fact_units\tmax_coverage_full_bandwidth\tviolations\n",
    );

    if (full) {
        for (perturb.coverage_populations) |population_size| {
            for (perturb.coverage_ratios_permille) |ratio| {
                const facts = (population_size * ratio) / 1000;
                for (perturb.coverage_redundancies) |redundancy_count| {
                    for (perturb.coverage_policies) |policy| {
                        for (perturb.coverage_kinds) |kind| {
                            for (perturb.coverage_severities_permille) |severity| {
                                for (perturb.trial_seeds) |trial_seed| {
                                    const threshold =
                                        try perturb.findCoverageThreshold(
                                            population_size,
                                            facts,
                                            redundancy_count,
                                            policy,
                                            trial_seed,
                                            .{
                                                .kind = kind,
                                                .severity_permille = severity,
                                                .seed = perturb.perturbationSeed(
                                                    trial_seed,
                                                ),
                                            },
                                        );
                                    try writeCoverageRow(io, out, threshold);
                                }
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    const ratios = [_]usize{ 1000, 4000 };
    const redundancies = [_]usize{ 1, 8 };
    const severities = [_]u16{ 0, 200 };
    for (ratios) |ratio| {
        const facts = (64 * ratio) / 1000;
        for (redundancies) |redundancy_count| {
            for (perturb.coverage_policies) |policy| {
                for (perturb.coverage_kinds) |kind| {
                    for (severities) |severity| {
                        const threshold = try perturb.findCoverageThreshold(
                            64,
                            facts,
                            redundancy_count,
                            policy,
                            0,
                            .{
                                .kind = kind,
                                .severity_permille = severity,
                                .seed = perturb.perturbationSeed(0),
                            },
                        );
                        try writeCoverageRow(io, out, threshold);
                    }
                }
            }
        }
    }
}

fn writeSparseSummary(
    io: std.Io,
    dataset: *const summary.SparseDataset,
) !void {
    const out = std.Io.File.stdout();
    try writeLine(io, out, "Stage 6 sparse robustness summary\n", .{});
    try writeLine(io, out, "rows: {d}\n", .{dataset.row_count});
    try writeLine(io, out, "malformed_rows: {d}\n", .{dataset.malformed_rows});
    try writeLine(io, out, "violation_rows: {d}\n", .{dataset.violationRows()});
    try writeLine(
        io,
        out,
        "severity0_failures: {d}\n",
        .{dataset.severityZeroFailures()},
    );

    try out.writeStreamingAll(
        io,
        "\nanchor\ttopology\tpolicy\tlambda_x1e6\tperturbation\trows\tmax_observed_severity_permille\tseverity0_successes\tlast_all_success_permille\tfirst_any_censored_permille\tfirst_all_censored_permille\tfirst_any_structural_permille\tfirst_all_structural_permille\tnonmonotonic_success\n",
    );

    for (perturb.sparse_anchors) |anchor| {
        for (perturb.perturbation_kinds) |kind| {
            const boundary = summary.sparseBoundary(dataset, anchor.id, kind);
            if (boundary.rows == 0) continue;
            try writeLine(
                io,
                out,
                "{s}\t{s}\t{s}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                .{
                    anchor.id,
                    anchor.topology.name(),
                    anchor.policy.name(),
                    anchor.lambdaX1e6(),
                    kind.name(),
                    boundary.rows,
                    boundary.max_observed_severity_permille,
                    boundary.severity0_successes,
                    boundary.last_all_success_permille,
                    boundary.first_any_censored_permille,
                    boundary.first_all_censored_permille,
                    boundary.first_any_structural_permille,
                    boundary.first_all_structural_permille,
                    boundary.nonmonotonic_success,
                },
            );
        }
    }

    try out.writeStreamingAll(
        io,
        "\nseverity detail\nanchor\tperturbation\tseverity_permille\trows\tsuccesses\tstructurally_reachable\tavg_success_rounds\tavg_delivery_ratio_permille\tavg_removed_edges_x1000\tavg_component_fraction_permille\n",
    );
    for (perturb.sparse_anchors) |anchor| {
        for (perturb.perturbation_kinds) |kind| {
            for (perturb.sparse_severities_permille) |severity| {
                const stats = summary.sparseSeverityStats(
                    dataset,
                    anchor.id,
                    kind,
                    severity,
                );
                if (stats.rows == 0) continue;
                try writeLine(
                    io,
                    out,
                    "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                    .{
                        anchor.id,
                        kind.name(),
                        severity,
                        stats.rows,
                        stats.successes,
                        stats.structurally_reachable,
                        stats.avg_success_rounds,
                        stats.avg_delivery_ratio_permille,
                        stats.avg_removed_edges_x1000,
                        stats.avg_component_fraction_permille,
                    },
                );
            }
        }
    }

    if (dataset.malformed_rows != 0 or
        dataset.violationRows() != 0 or
        dataset.severityZeroFailures() != 0)
    {
        std.process.exit(2);
    }
}

fn writeCoverageSummary(
    io: std.Io,
    dataset: *const summary.CoverageDataset,
) !void {
    const out = std.Io.File.stdout();
    try writeLine(io, out, "Stage 6 coverage robustness summary\n", .{});
    try writeLine(io, out, "rows: {d}\n", .{dataset.row_count});
    try writeLine(io, out, "malformed_rows: {d}\n", .{dataset.malformed_rows});
    try writeLine(io, out, "violation_rows: {d}\n", .{dataset.violationRows()});
    try writeLine(io, out, "unreachable_rows: {d}\n", .{dataset.unreachableRows()});
    try writeLine(
        io,
        out,
        "severity0_anomalies: {d}\n",
        .{dataset.severityZeroAnomalies()},
    );

    try out.writeStreamingAll(
        io,
        "\nperturbation\tpolicy\tR\tF_over_N_x1000\tseverity_permille\trows\treachable\tmedian_baseline_B\tmedian_perturbed_B\tmedian_inflation_x1000\tmedian_max_coverage_fraction_permille\n",
    );

    for (perturb.coverage_kinds) |kind| {
        for (perturb.coverage_policies) |policy| {
            for (perturb.coverage_redundancies) |redundancy_count| {
                for (perturb.coverage_ratios_permille) |ratio| {
                    for (perturb.coverage_severities_permille) |severity| {
                        const stats = summary.coverageStats(
                            dataset,
                            kind,
                            policy,
                            redundancy_count,
                            ratio,
                            severity,
                        );
                        if (stats.rows == 0) continue;
                        try writeLine(
                            io,
                            out,
                            "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
                            .{
                                kind.name(),
                                policy.name(),
                                redundancy_count,
                                ratio,
                                severity,
                                stats.rows,
                                stats.reachable,
                                stats.median_baseline_bandwidth,
                                stats.median_perturbed_bandwidth,
                                stats.median_inflation_x1000,
                                stats.median_coverage_fraction_permille,
                            },
                        );
                    }
                }
            }
        }
    }

    if (dataset.malformed_rows != 0 or
        dataset.violationRows() != 0 or
        dataset.severityZeroAnomalies() != 0)
    {
        std.process.exit(2);
    }
}

fn writeSparseRow(
    io: std.Io,
    out: std.Io.File,
    anchor: perturb.SparseAnchor,
    trial_seed: u64,
    result: perturb.Result,
) !void {
    // Zig 0.16's formatter supports at most 32 arguments per call.
    // Emit one logical 36-column TSV row in two bounded writes.
    try writeLine(
        io,
        out,
        "{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}",
        .{
            anchor.id,
            result.base.population_size,
            result.base.fact_count,
            result.base.topology.name(),
            result.diameter,
            result.base.redundancy,
            result.base.bandwidth,
            result.base.policy.name(),
            anchor.lambdaX1e6(),
            trial_seed,
            result.perturbation.kind.name(),
            result.perturbation.severity_permille,
            result.perturbation.seed,
            yesNo(result.success),
            result.rounds,
            result.collector_initial_facts,
            result.collector_final_facts,
            result.policy_slots,
        },
    );
    try writeLine(
        io,
        out,
        "\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n",
        .{
            result.policy_calls,
            result.operator_omissions,
            result.actions_proposed,
            result.rejected_actions,
            result.attempted_messages,
            result.delivered_messages,
            result.suppressed_messages,
            result.attempted_units,
            result.delivered_units,
            result.suppressed_units,
            result.deliveryRatioPermille(),
            result.useful_deliveries,
            result.duplicate_deliveries,
            result.violations,
            result.removed_edges,
            result.collector_component_size,
            result.collector_component_fact_coverage,
            yesNo(result.structurallyReachable()),
        },
    );
}

fn writeCoverageRow(
    io: std.Io,
    out: std.Io.File,
    row: perturb.CoverageThreshold,
) !void {
    try writeLine(
        io,
        out,
        "{d}\t{d}\t{d}\t{d}\t{s}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            row.population_size,
            row.facts,
            row.facts_per_operator_x1000,
            row.redundancy_count,
            row.policy.name(),
            row.trial_seed,
            row.perturbation.kind.name(),
            row.perturbation.severity_permille,
            row.perturbation.seed,
            row.baseline_bandwidth,
            row.perturbed_bandwidth,
            yesNo(row.reachable),
            row.inflation_x1000,
            row.collector_initial,
            row.collector_final_at_threshold,
            row.active_senders_at_threshold,
            row.delivered_senders_at_threshold,
            row.selected_fact_units_at_threshold,
            row.suppressed_fact_units_at_threshold,
            row.max_coverage_at_full_bandwidth,
            row.violations,
        },
    );
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn smokeSparseCount() usize {
    return 2 * 3 * 3;
}

fn smokeCoverageCount() usize {
    return 2 * 2 * 2 * 2 * 2;
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  zig run src/stage6_cli.zig -- validate\n" ++
            "  zig run src/stage6_cli.zig -- plan [smoke|full]\n" ++
            "  zig run src/stage6_cli.zig -- sparse [smoke|full]\n" ++
            "  zig run src/stage6_cli.zig -- coverage [smoke|full]\n" ++
            "  zig run src/stage6_cli.zig -- summarize-sparse <sparse.tsv>\n" ++
            "  zig run src/stage6_cli.zig -- summarize-coverage <coverage.tsv>\n",
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

test "Stage 6 smoke plan sizes are fixed" {
    try std.testing.expectEqual(@as(usize, 18), smokeSparseCount());
    try std.testing.expectEqual(@as(usize, 32), smokeCoverageCount());
}
