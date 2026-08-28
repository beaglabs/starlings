const std = @import("std");
const robust = @import("stage6_1_robustness_law.zig");

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

    const dataset = robust.parseDataset(tsv);
    const out = std.Io.File.stdout();

    try writeDatasetAudit(io, out, &dataset);
    if (!dataset.isCanonical()) {
        try out.writeStreamingAll(
            io,
            "ERROR: Stage 6.1 requires the frozen canonical Stage 6 coverage dataset.\n",
        );
        std.process.exit(2);
    }

    const counts = robust.splitCounts(&dataset);
    try writeSplit(io, out, counts);
    try writeMethod(io, out);

    const candidate_fit = try robust.fitParameters(&dataset, false);
    try writeFit(io, out, "candidate_fit_seed_0_1", candidate_fit);

    const laws = [_]robust.LawKind{
        .naive_f_exp,
        .missing_exact,
        .global_scaled_exact,
        .mechanism_scaled_exact,
    };

    try out.writeStreamingAll(
        io,
        "\nseed-2 validation (hard holdouts unseen)\n" ++
            "law\tparameters\trows\treachable\tunreachable\tbrier\tlog-loss\taccuracy\tobserved-reachability\tmean-predicted-reachability\n",
    );

    var best_law = robust.LawKind.naive_f_exp;
    var best_brier: f64 = 1.0e300;
    for (laws) |law| {
        const score = robust.scoreValidation(
            &dataset,
            law,
            candidate_fit,
        );
        try writeScore(io, out, law, score);
        if (score.brier_score < best_brier) {
            best_brier = score.brier_score;
            best_law = law;
        }
    }
    try writeLine(
        io,
        out,
        "validation_brier_winner: {s}\n",
        .{best_law.name()},
    );

    const hard_fit = try robust.fitParameters(&dataset, true);
    try writeFit(io, out, "refit_all_nonholdout_seeds", hard_fit);

    try out.writeStreamingAll(
        io,
        "\nhard holdout evaluation\n" ++
            "holdout\tlaw\tparameters\trows\treachable\tunreachable\tbrier\tlog-loss\taccuracy\tobserved-reachability\tmean-predicted-reachability\n",
    );

    const holdouts = [_]robust.HoldoutKind{
        .population_extrapolation,
        .density_extrapolation,
        .redundancy_extrapolation,
        .severity_extrapolation,
    };

    for (holdouts) |holdout| {
        for (laws) |law| {
            const score = robust.scoreHardHoldout(
                &dataset,
                holdout,
                law,
                hard_fit,
            );
            try writeHoldoutScore(
                io,
                out,
                holdout,
                law,
                score,
            );
        }
    }

    try writeCalibration(io, out, &dataset);
}

fn writeDatasetAudit(
    io: std.Io,
    out: std.Io.File,
    dataset: *const robust.Dataset,
) !void {
    try out.writeStreamingAll(io, "Stage 6.1 Robustness Law Validation\n");
    try writeLine(
        io,
        out,
        "dataset_sha256: {s}\n",
        .{dataset.sha256_hex[0..]},
    );
    try writeLine(
        io,
        out,
        "expected_sha256: {s}\n",
        .{robust.canonical_sha256},
    );
    try writeLine(
        io,
        out,
        "canonical_dataset: {s}\n",
        .{if (dataset.isCanonical()) "yes" else "no"},
    );
    try writeLine(
        io,
        out,
        "rows: {d}\n",
        .{dataset.coverage.row_count},
    );
    try writeLine(
        io,
        out,
        "malformed_rows: {d}\n",
        .{dataset.coverage.malformed_rows},
    );
    try writeLine(
        io,
        out,
        "violation_rows: {d}\n",
        .{dataset.coverage.violationRows()},
    );
    try writeLine(
        io,
        out,
        "severity0_anomalies: {d}\n",
        .{dataset.coverage.severityZeroAnomalies()},
    );
    try writeLine(
        io,
        out,
        "representative_rows_after_policy_dedup: {d}\n",
        .{dataset.representativeRows()},
    );
    try writeLine(
        io,
        out,
        "policy_invariant_pairs: {d}\n",
        .{dataset.policy_audit.pairs},
    );
    try writeLine(
        io,
        out,
        "policy_invariant_missing_pairs: {d}\n",
        .{dataset.policy_audit.missing_pairs},
    );
    try writeLine(
        io,
        out,
        "policy_invariant_mismatches: {d}\n",
        .{dataset.policy_audit.mismatches},
    );
}

fn writeSplit(
    io: std.Io,
    out: std.Io.File,
    counts: robust.SplitCounts,
) !void {
    try out.writeStreamingAll(io, "\ndeterministic split\n");
    try writeLine(
        io,
        out,
        "representatives: {d}\n",
        .{counts.representatives},
    );
    try writeLine(
        io,
        out,
        "nonholdout_total: {d}\n",
        .{counts.training},
    );
    try writeLine(
        io,
        out,
        "candidate_fit_seed_0_1: {d}\n",
        .{counts.fit},
    );
    try writeLine(
        io,
        out,
        "candidate_validation_seed_2: {d}\n",
        .{counts.validation},
    );
    try writeLine(
        io,
        out,
        "population_holdout_N_256: {d}\n",
        .{counts.population},
    );
    try writeLine(
        io,
        out,
        "density_holdout_F_over_N_4: {d}\n",
        .{counts.density},
    );
    try writeLine(
        io,
        out,
        "redundancy_holdout_R_8: {d}\n",
        .{counts.redundancy},
    );
    try writeLine(
        io,
        out,
        "severity_holdout_p_500: {d}\n",
        .{counts.severity},
    );
}

fn writeMethod(io: std.Io, out: std.Io.File) !void {
    try out.writeStreamingAll(
        io,
        "\nmethod\n" ++
            "reachability evidence: round_robin representative only; seeded is an exact B=F invariant/control, not independent evidence\n" ++
            "M = F - collector_initial\n" ++
            "h_exact = -M log(1 - p^R)\n" ++
            "naive_F_exp: P = exp(-F p^R)\n" ++
            "missing_exact: P = exp(-h_exact) = (1-p^R)^M\n" ++
            "global_scaled_exact: P = exp(-c h_exact), one fitted c\n" ++
            "mechanism_scaled_exact: P = exp(-c_k h_exact), one c per transient fault mechanism\n" ++
            "scalar corrections fit by deterministic Bernoulli maximum likelihood\n" ++
            "candidate fit: nonholdout seeds 0-1\n" ++
            "candidate validation: nonholdout seed 2\n" ++
            "hard evaluation: refit scalar corrections on all nonholdout seeds\n" ++
            "hard holdouts are disjoint by priority: N=256, then F/N=4, then R=8, then p=0.5\n",
    );
}

fn writeFit(
    io: std.Io,
    out: std.Io.File,
    label: []const u8,
    fit: robust.FitParameters,
) !void {
    try writeLine(io, out, "\n{s}\n", .{label});
    try writeLine(io, out, "global_c: {d}\n", .{fit.global_c});
    try writeLine(
        io,
        out,
        "operator_omission_c: {d}\n",
        .{fit.operator_omission_c},
    );
    try writeLine(
        io,
        out,
        "message_drop_c: {d}\n",
        .{fit.message_drop_c},
    );
}

fn writeScore(
    io: std.Io,
    out: std.Io.File,
    law: robust.LawKind,
    score: robust.Score,
) !void {
    try writeLine(
        io,
        out,
        "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            law.name(),
            parameterCount(law),
            score.rows,
            score.reachable_rows,
            score.unreachable_rows,
            score.brier_score,
            score.log_loss,
            score.accuracy,
            score.observed_reachability,
            score.mean_predicted_reachability,
        },
    );
}

fn writeHoldoutScore(
    io: std.Io,
    out: std.Io.File,
    holdout: robust.HoldoutKind,
    law: robust.LawKind,
    score: robust.Score,
) !void {
    try writeLine(
        io,
        out,
        "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            holdout.name(),
            law.name(),
            parameterCount(law),
            score.rows,
            score.reachable_rows,
            score.unreachable_rows,
            score.brier_score,
            score.log_loss,
            score.accuracy,
            score.observed_reachability,
            score.mean_predicted_reachability,
        },
    );
}

fn writeCalibration(
    io: std.Io,
    out: std.Io.File,
    dataset: *const robust.Dataset,
) !void {
    const bins = robust.hazardCalibration(dataset);
    try out.writeStreamingAll(
        io,
        "\nparameter-free hazard collapse\n" ++
            "hazard_low\thazard_high\trows\treachable\tobserved_reachability\tpredicted_missing_exact\n",
    );

    var i: usize = 0;
    while (i < robust.calibration_bin_count) : (i += 1) {
        const bin = bins[i];
        if (bin.rows == 0) continue;
        try writeLine(
            io,
            out,
            "{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                robust.hazard_edges[i],
                robust.hazard_edges[i + 1],
                bin.rows,
                bin.reachable_rows,
                bin.observed(),
                bin.predicted(),
            },
        );
    }
}

fn parameterCount(law: robust.LawKind) usize {
    return switch (law) {
        .naive_f_exp, .missing_exact => 0,
        .global_scaled_exact => 1,
        .mechanism_scaled_exact => 2,
    };
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  zig run -O ReleaseFast src/stage6_1_cli.zig -- trials/stage6-coverage.tsv\n",
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
