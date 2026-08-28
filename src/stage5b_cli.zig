const std = @import("std");
const stage5a = @import("stage5a_summary.zig");
const predictive = @import("stage5b_predictive.zig");
const scaling = @import("stage5a_scaling.zig");

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

    const summary = stage5a.summarizeTsv(tsv);
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Stage 5B Predictive Coordination Laws\n", .{});
    try writeLine(io, out, "dataset_sha256: {s}\n", .{summary.sha256_hex[0..]});
    try writeLine(io, out, "canonical_dataset: {s}\n", .{if (summary.isCanonical()) "yes" else "no"});
    try writeLine(io, out, "rows: {d}\n", .{summary.row_count});

    if (!summary.isCanonical()) {
        try writeLine(
            io,
            out,
            "ERROR: Stage 5B requires the frozen canonical Stage 5A dataset.\n",
            .{},
        );
        std.process.exit(2);
    }

    try writeSplit(io, out, &summary);
    try writeMethod(io, out);

    inline for (.{
        predictive.Target.convergence,
        predictive.Target.rounds,
        predictive.Target.communication,
        predictive.Target.efficiency,
    }) |target| {
        try writeTarget(io, out, &summary, target);
    }
}

fn writeSplit(
    io: std.Io,
    out: std.Io.File,
    summary: *const stage5a.Summary,
) !void {
    var training: usize = 0;
    var fit: usize = 0;
    var validation: usize = 0;
    var population: usize = 0;
    var information: usize = 0;
    var capacity: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        switch (predictive.holdoutKind(row)) {
            .training => {
                training += 1;
                if (row.seed == 2) {
                    validation += 1;
                } else {
                    fit += 1;
                }
            },
            .population_extrapolation => population += 1,
            .information_extrapolation => information += 1,
            .capacity_interpolation => capacity += 1,
        }
    }

    try writeLine(io, out, "\ndeterministic split\n", .{});
    try writeLine(io, out, "training_total: {d}\n", .{training});
    try writeLine(io, out, "candidate_fit_seed_0_1: {d}\n", .{fit});
    try writeLine(io, out, "candidate_validation_seed_2: {d}\n", .{validation});
    try writeLine(io, out, "population_extrapolation_N_1000: {d}\n", .{population});
    try writeLine(io, out, "information_extrapolation_F_1024: {d}\n", .{information});
    try writeLine(io, out, "capacity_interpolation: {d}\n", .{capacity});
}

fn writeMethod(io: std.Io, out: std.Io.File) !void {
    try writeLine(io, out, "\nmethod\n", .{});
    try out.writeStreamingAll(
        io,
        "primary: separate compact law per topology x policy regime\n" ++
            "candidate laws: mechanistic | population | hybrid\n" ++
            "candidate selection: fit seeds 0-1, validate on seed 2, training rows only\n" ++
            "refit: chosen law uses all non-holdout training seeds before hard evaluation\n" ++
            "challenger: one pooled 30-term ridge model with topology/policy interactions\n" ++
            "convergence target: all rows, Brier score / accuracy / censored recall\n" ++
            "performance targets: successful rows only; censored T_conv is never set to 4096\n" ++
            "hard extrapolation: N=1000 and F=1024\n" ++
            "capacity interpolation cells: (1,2) (1,8) (2,4) (4,2) (4,16) (8,8)\n",
    );
}

fn writeTarget(
    io: std.Io,
    out: std.Io.File,
    summary: *const stage5a.Summary,
    target: predictive.Target,
) !void {
    try writeLine(io, out, "\n=== target: {s} ===\n", .{target.name()});
    try writeCandidateTable(io, out, summary, target);
    try writeSelectedLaws(io, out, summary, target);

    const pooled = try predictive.fitPooled(summary, target);
    try writeLine(io, out, "\nhard holdout comparison\n", .{});

    if (target == .convergence) {
        try out.writeStreamingAll(
            io,
            "holdout\tmodel\trows\tsuccess\tcensored\tbrier\taccuracy\tcensored-recall\n",
        );
    } else {
        try out.writeStreamingAll(
            io,
            "holdout\tmodel\trows\tmean-abs-log-error\tmean-abs-percent-error\n",
        );
    }

    inline for (.{
        predictive.HoldoutKind.population_extrapolation,
        predictive.HoldoutKind.information_extrapolation,
        predictive.HoldoutKind.capacity_interpolation,
    }) |kind| {
        const primary = try predictive.scorePrimaryHoldout(summary, target, kind);
        const pooled_score = predictive.scorePooledHoldout(summary, pooled, kind);
        try writeScore(io, out, kind, "regime_primary", target, primary);
        try writeScore(io, out, kind, "pooled_interactions", target, pooled_score);
    }

    try writeRegimeHoldouts(io, out, summary, target);
}

fn writeCandidateTable(
    io: std.Io,
    out: std.Io.File,
    summary: *const stage5a.Summary,
    target: predictive.Target,
) !void {
    try writeLine(io, out, "\ncandidate validation (hard holdouts unseen)\n", .{});
    try out.writeStreamingAll(
        io,
        "topology\tpolicy\tlaw\tfit-rows\tvalidation-rows\tvalidation-score\tselected\n",
    );

    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };
    const laws = [_]predictive.LawKind{ .mechanistic, .population, .hybrid };

    for (topologies) |topology| {
        for (policies) |policy| {
            const regime = predictive.Regime{ .topology = topology, .policy = policy };
            const selected = try predictive.selectLaw(summary, regime, target);

            for (laws) |law| {
                const candidate = try predictive.candidateValidation(
                    summary,
                    regime,
                    target,
                    law,
                );
                try writeLine(
                    io,
                    out,
                    "{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{s}\n",
                    .{
                        topology.name(),
                        policy.name(),
                        law.name(),
                        candidate.fit_rows,
                        candidate.validation_rows,
                        candidate.validation_score,
                        if (law == selected.law)
                            "yes"
                        else if (law == .hybrid)
                            "diagnostic"
                        else
                            "no",
                    },
                );
            }

            if (selected.law == .one_class) {
                const candidate = try predictive.candidateValidation(
                    summary,
                    regime,
                    target,
                    .one_class,
                );
                try writeLine(
                    io,
                    out,
                    "{s}\t{s}\tone_class\t{d}\t{d}\t{d}\tyes\n",
                    .{
                        topology.name(),
                        policy.name(),
                        candidate.fit_rows,
                        candidate.validation_rows,
                        candidate.validation_score,
                    },
                );
            }
        }
    }
}

fn writeSelectedLaws(
    io: std.Io,
    out: std.Io.File,
    summary: *const stage5a.Summary,
    target: predictive.Target,
) !void {
    try writeLine(io, out, "\nselected regime laws (refit on all non-holdout training seeds)\n", .{});
    try out.writeStreamingAll(
        io,
        "topology\tpolicy\tlaw\tterm\tcoefficient\n",
    );

    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };

    for (topologies) |topology| {
        for (policies) |policy| {
            const fitted = try predictive.fitSelectedRegime(summary, .{
                .topology = topology,
                .policy = policy,
            }, target);

            var index: usize = 0;
            while (index < fitted.model.feature_count) : (index += 1) {
                try writeLine(
                    io,
                    out,
                    "{s}\t{s}\t{s}\t{s}\t{d}\n",
                    .{
                        topology.name(),
                        policy.name(),
                        fitted.law.name(),
                        fitted.law.featureName(index),
                        fitted.model.coeffs[index],
                    },
                );
            }
        }
    }
}

fn writeRegimeHoldouts(
    io: std.Io,
    out: std.Io.File,
    summary: *const stage5a.Summary,
    target: predictive.Target,
) !void {
    try writeLine(io, out, "\nregime-specific hard holdouts\n", .{});
    if (target == .convergence) {
        try out.writeStreamingAll(
            io,
            "topology\tpolicy\tlaw\tholdout\trows\tbrier\taccuracy\tcensored-recall\n",
        );
    } else {
        try out.writeStreamingAll(
            io,
            "topology\tpolicy\tlaw\tholdout\trows\tmean-abs-log-error\tmean-abs-percent-error\n",
        );
    }

    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };

    for (topologies) |topology| {
        for (policies) |policy| {
            const fitted = try predictive.fitSelectedRegime(summary, .{
                .topology = topology,
                .policy = policy,
            }, target);

            const holdouts = [_]predictive.HoldoutKind{
                .population_extrapolation,
                .information_extrapolation,
                .capacity_interpolation,
            };
            for (holdouts) |kind| {
                const score = predictive.scoreRegimeHoldout(summary, fitted, kind);
                if (score.rows == 0) continue;

                if (target == .convergence) {
                    try writeLine(
                        io,
                        out,
                        "{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n",
                        .{
                            topology.name(),
                            policy.name(),
                            fitted.law.name(),
                            kind.name(),
                            score.rows,
                            score.brier_score,
                            score.accuracy,
                            score.censored_recall,
                        },
                    );
                } else {
                    try writeLine(
                        io,
                        out,
                        "{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n",
                        .{
                            topology.name(),
                            policy.name(),
                            fitted.law.name(),
                            kind.name(),
                            score.rows,
                            score.mean_abs_log_error,
                            score.mean_abs_percent_error,
                        },
                    );
                }
            }
        }
    }
}

fn writeScore(
    io: std.Io,
    out: std.Io.File,
    kind: predictive.HoldoutKind,
    model_name: []const u8,
    target: predictive.Target,
    score: predictive.Score,
) !void {
    if (target == .convergence) {
        try writeLine(
            io,
            out,
            "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                kind.name(),
                model_name,
                score.rows,
                score.successful_rows,
                score.censored_rows,
                score.brier_score,
                score.accuracy,
                score.censored_recall,
            },
        );
    } else {
        try writeLine(
            io,
            out,
            "{s}\t{s}\t{d}\t{d}\t{d}\n",
            .{
                kind.name(),
                model_name,
                score.rows,
                score.mean_abs_log_error,
                score.mean_abs_percent_error,
            },
        );
    }
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage: zig run src/stage5b_cli.zig -- <stage5a-full.tsv>\n",
    );
}

fn writeLine(
    io: std.Io,
    out: std.Io.File,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "capacity holdout contract is stable" {
    try std.testing.expect(predictive.isCapacityHoldout(1, 2));
    try std.testing.expect(predictive.isCapacityHoldout(1, 8));
    try std.testing.expect(predictive.isCapacityHoldout(2, 4));
    try std.testing.expect(predictive.isCapacityHoldout(4, 2));
    try std.testing.expect(predictive.isCapacityHoldout(4, 16));
    try std.testing.expect(predictive.isCapacityHoldout(8, 8));

    try std.testing.expect(!predictive.isCapacityHoldout(1, 1));
    try std.testing.expect(!predictive.isCapacityHoldout(2, 2));
    try std.testing.expect(!predictive.isCapacityHoldout(8, 16));
}
