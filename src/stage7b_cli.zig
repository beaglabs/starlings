const std = @import("std");
const search = @import("stage7b_search.zig");
const stage7a = @import("stage7a_policy.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        try usage(io);
        std.process.exit(2);
    }

    if (std.mem.eql(u8, args[1], "validate")) {
        try validate(io);
        return;
    }
    if (std.mem.eql(u8, args[1], "plan")) {
        try plan(io);
        return;
    }
    if (std.mem.eql(u8, args[1], "search")) {
        try runSearch(io);
        return;
    }

    try usage(io);
    std.process.exit(2);
}

fn validate(io: std.Io) !void {
    const out = std.Io.File.stdout();
    const candidates = search.generateCandidates();

    var invalid_theta: usize = 0;
    var duplicate_theta: usize = 0;
    var i: usize = 0;
    while (i < candidates.len) : (i += 1) {
        candidates.items[i].theta.validate() catch {
            invalid_theta += 1;
        };

        var j: usize = i + 1;
        while (j < candidates.len) : (j += 1) {
            if (candidates.items[i].theta.eql(candidates.items[j].theta)) {
                duplicate_theta += 1;
            }
        }
    }

    const controls_exact =
        candidates.len >= 3 and
        candidates.items[0].theta.eql(stage7a.round_robin_theta) and
        candidates.items[1].theta.eql(stage7a.seeded_theta) and
        candidates.items[2].theta.eql(stage7a.novel_first_theta);

    try out.writeStreamingAll(io, "Stage 7B validation\n");
    try writeLine(
        io,
        out,
        "candidate_count: {d}\n",
        .{candidates.len},
    );
    try writeLine(
        io,
        out,
        "expected_candidate_count: {d}\n",
        .{search.canonical_candidate_count},
    );
    try writeLine(
        io,
        out,
        "invalid_theta: {d}\n",
        .{invalid_theta},
    );
    try writeLine(
        io,
        out,
        "duplicate_theta: {d}\n",
        .{duplicate_theta},
    );
    try writeLine(
        io,
        out,
        "exact_control_prefix: {s}\n",
        .{if (controls_exact) "yes" else "no"},
    );

    inline for (std.meta.tags(search.SplitKind)) |split| {
        try writeLine(
            io,
            out,
            "worlds_{s}: {d}\n",
            .{ split.name(), search.worldCount(split) },
        );
    }

    if (candidates.len != search.canonical_candidate_count or
        invalid_theta != 0 or
        duplicate_theta != 0 or
        !controls_exact)
    {
        std.process.exit(2);
    }
}

fn plan(io: std.Io) !void {
    const out = std.Io.File.stdout();
    const candidates = search.generateCandidates();
    const training_runs =
        candidates.len * search.worldCount(.training);
    const validation_upper =
        candidates.len * search.worldCount(.validation);
    const hard_per_selected =
        search.worldCount(.population_extrapolation) +
        search.worldCount(.density_extrapolation) +
        search.worldCount(.redundancy_extrapolation) +
        search.worldCount(.bandwidth_extrapolation) +
        search.worldCount(.topology_extrapolation) +
        search.worldCount(.compound_extrapolation);

    try out.writeStreamingAll(
        io,
        "Stage 7B deterministic policy-search plan\n",
    );
    try writeLine(
        io,
        out,
        "candidates: {d}\n",
        .{candidates.len},
    );
    try writeLine(
        io,
        out,
        "fixed_profiles: {d}\n",
        .{search.fixed_candidate_count},
    );
    try writeLine(
        io,
        out,
        "latin_hypercube_candidates: {d}\n",
        .{search.latin_candidate_count},
    );
    try writeLine(
        io,
        out,
        "training_worlds_per_candidate: {d}\n",
        .{search.worldCount(.training)},
    );
    try writeLine(
        io,
        out,
        "training_runs_exact: {d}\n",
        .{training_runs},
    );
    try writeLine(
        io,
        out,
        "validation_worlds_per_training_frontier_candidate: {d}\n",
        .{search.worldCount(.validation)},
    );
    try writeLine(
        io,
        out,
        "validation_run_upper_bound: {d}\n",
        .{validation_upper},
    );
    try writeLine(
        io,
        out,
        "hard_worlds_per_selected_candidate: {d}\n",
        .{hard_per_selected},
    );
    try out.writeStreamingAll(
        io,
        "selection: minimum failures first, then resource Pareto frontier\n" ++
            "validation: training-frontier candidates only; named controls retained as diagnostics\n" ++
            "hard evaluation: validation frontier plus exact named controls\n" ++
            "no hard-holdout result participates in theta selection\n",
    );
}

fn runSearch(io: std.Io) !void {
    const out = std.Io.File.stdout();
    const err_out = std.Io.File.stderr();
    const candidates = search.generateCandidates();

    var train_metrics =
        [_]search.Aggregate{.{}} ** search.max_candidates;
    var train_eligible =
        search.allEligible(candidates.len);
    var total_violations: u64 = 0;

    var i: usize = 0;
    while (i < candidates.len) : (i += 1) {
        try progress(
            io,
            err_out,
            "training",
            i + 1,
            candidates.len,
            candidates.items[i],
        );
        train_metrics[i] = try search.evaluateCandidate(
            candidates.items[i],
            .training,
        );
        total_violations +%= train_metrics[i].violations;
    }

    const train_frontier = search.computeFrontier(
        candidates.len,
        &train_metrics,
        &train_eligible,
    );

    var validation_metrics =
        [_]search.Aggregate{.{}} ** search.max_candidates;
    var validation_evaluated =
        search.selectedOrControls(
            candidates.len,
            &train_frontier.flags,
        );

    var validation_total: usize = 0;
    i = 0;
    while (i < candidates.len) : (i += 1) {
        if (validation_evaluated[i]) validation_total += 1;
    }

    var validation_ordinal: usize = 0;
    i = 0;
    while (i < candidates.len) : (i += 1) {
        if (!validation_evaluated[i]) continue;
        validation_ordinal += 1;
        try progress(
            io,
            err_out,
            "validation",
            validation_ordinal,
            validation_total,
            candidates.items[i],
        );
        validation_metrics[i] = try search.evaluateCandidate(
            candidates.items[i],
            .validation,
        );
        total_violations +%= validation_metrics[i].violations;
    }

    // Selection uses only candidates that were on the training frontier.
    const validation_frontier = search.computeFrontier(
        candidates.len,
        &validation_metrics,
        &train_frontier.flags,
    );
    const hard_selected = search.selectedOrControls(
        candidates.len,
        &validation_frontier.flags,
    );

    try out.writeStreamingAll(
        io,
        "Stage 7B Policy Search and Generalization\n",
    );
    try writeLine(
        io,
        out,
        "candidate_count: {d}\n",
        .{candidates.len},
    );
    try writeLine(
        io,
        out,
        "training_min_failures: {d}\n",
        .{train_frontier.min_failures},
    );
    try writeLine(
        io,
        out,
        "training_frontier_count: {d}\n",
        .{train_frontier.count},
    );
    try writeLine(
        io,
        out,
        "validation_candidates_evaluated: {d}\n",
        .{validation_total},
    );
    try writeLine(
        io,
        out,
        "validation_min_failures: {d}\n",
        .{validation_frontier.min_failures},
    );
    try writeLine(
        io,
        out,
        "validation_frontier_count: {d}\n",
        .{validation_frontier.count},
    );

    try out.writeStreamingAll(io, "\ntraining frontier\n");
    try writeMetricHeader(io, out, "frontier");
    i = 0;
    while (i < candidates.len) : (i += 1) {
        if (!train_frontier.flags[i]) continue;
        try writeMetricRow(
            io,
            out,
            candidates.items[i],
            train_metrics[i],
            true,
        );
    }

    try out.writeStreamingAll(
        io,
        "\nvalidation evaluations (training frontier + named controls)\n",
    );
    try writeMetricHeader(io, out, "validation_frontier");
    i = 0;
    while (i < candidates.len) : (i += 1) {
        if (!validation_evaluated[i]) continue;
        try writeMetricRow(
            io,
            out,
            candidates.items[i],
            validation_metrics[i],
            validation_frontier.flags[i],
        );
    }

    try out.writeStreamingAll(io, "\nvalidation-selected frontier\n");
    try writeMetricHeader(io, out, "frontier");
    i = 0;
    while (i < candidates.len) : (i += 1) {
        if (!validation_frontier.flags[i]) continue;
        try writeMetricRow(
            io,
            out,
            candidates.items[i],
            validation_metrics[i],
            true,
        );
    }

    const hard_splits = [_]search.SplitKind{
        .population_extrapolation,
        .density_extrapolation,
        .redundancy_extrapolation,
        .bandwidth_extrapolation,
        .topology_extrapolation,
        .compound_extrapolation,
    };

    var hard_candidate_count: usize = 0;
    i = 0;
    while (i < candidates.len) : (i += 1) {
        if (hard_selected[i]) hard_candidate_count += 1;
    }

    try writeLine(
        io,
        out,
        "\nhard_selected_candidates: {d}\n",
        .{hard_candidate_count},
    );
    try out.writeStreamingAll(
        io,
        "hard holdouts (validation frontier + named controls; never used for selection)\n",
    );
    try writeHardHeader(io, out);

    var hard_step: usize = 0;
    const hard_steps = hard_candidate_count * hard_splits.len;
    for (hard_splits) |split| {
        i = 0;
        while (i < candidates.len) : (i += 1) {
            if (!hard_selected[i]) continue;
            hard_step += 1;
            try progressHard(
                io,
                err_out,
                hard_step,
                hard_steps,
                split,
                candidates.items[i],
            );
            const metrics = try search.evaluateCandidate(
                candidates.items[i],
                split,
            );
            total_violations +%= metrics.violations;
            try writeHardRow(
                io,
                out,
                split,
                candidates.items[i],
                metrics,
                validation_frontier.flags[i],
            );
        }
    }

    try writeLine(
        io,
        out,
        "\ntotal_policy_violations: {d}\n",
        .{total_violations},
    );
    if (total_violations != 0) std.process.exit(2);
}

fn writeMetricHeader(
    io: std.Io,
    out: std.Io.File,
    marker_name: []const u8,
) !void {
    try writeLine(
        io,
        out,
        "id\tsource\tlabel\tn\te\tr\tu\truns\tfailures\trounds_sum\tcommunication_sum\tduplicate_sum\tcomputation_sum\tuseful_per_1000\tduplicate_permille\tviolations\t{s}\n",
        .{marker_name},
    );
}

fn writeMetricRow(
    io: std.Io,
    out: std.Io.File,
    candidate: search.Candidate,
    metrics: search.Aggregate,
    frontier: bool,
) !void {
    try writeLine(
        io,
        out,
        "{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n",
        .{
            candidate.id,
            candidate.source.name(),
            candidate.label,
            candidate.theta.novelty_permille,
            candidate.theta.exploration_permille,
            candidate.theta.retry_permille,
            candidate.theta.bandwidth_utilization_permille,
            metrics.runs,
            metrics.failures,
            metrics.rounds_sum,
            metrics.communication_sum,
            metrics.duplicate_sum,
            metrics.computation_sum,
            metrics.usefulPerThousand(),
            metrics.duplicatePermille(),
            metrics.violations,
            if (frontier) "yes" else "no",
        },
    );
}

fn writeHardHeader(io: std.Io, out: std.Io.File) !void {
    try out.writeStreamingAll(
        io,
        "holdout\tid\tsource\tlabel\tn\te\tr\tu\truns\tfailures\trounds_sum\tcommunication_sum\tduplicate_sum\tcomputation_sum\tuseful_per_1000\tduplicate_permille\tviolations\tselected_frontier\n",
    );
}

fn writeHardRow(
    io: std.Io,
    out: std.Io.File,
    split: search.SplitKind,
    candidate: search.Candidate,
    metrics: search.Aggregate,
    selected_frontier: bool,
) !void {
    try writeLine(
        io,
        out,
        "{s}\t{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n",
        .{
            split.name(),
            candidate.id,
            candidate.source.name(),
            candidate.label,
            candidate.theta.novelty_permille,
            candidate.theta.exploration_permille,
            candidate.theta.retry_permille,
            candidate.theta.bandwidth_utilization_permille,
            metrics.runs,
            metrics.failures,
            metrics.rounds_sum,
            metrics.communication_sum,
            metrics.duplicate_sum,
            metrics.computation_sum,
            metrics.usefulPerThousand(),
            metrics.duplicatePermille(),
            metrics.violations,
            if (selected_frontier) "yes" else "no",
        },
    );
}

fn progress(
    io: std.Io,
    err_out: std.Io.File,
    phase: []const u8,
    ordinal: usize,
    total: usize,
    candidate: search.Candidate,
) !void {
    try writeLine(
        io,
        err_out,
        "[{s} {d}/{d}] id={d} n={d} e={d} r={d} u={d}\n",
        .{
            phase,
            ordinal,
            total,
            candidate.id,
            candidate.theta.novelty_permille,
            candidate.theta.exploration_permille,
            candidate.theta.retry_permille,
            candidate.theta.bandwidth_utilization_permille,
        },
    );
}

fn progressHard(
    io: std.Io,
    err_out: std.Io.File,
    ordinal: usize,
    total: usize,
    split: search.SplitKind,
    candidate: search.Candidate,
) !void {
    try writeLine(
        io,
        err_out,
        "[hard {d}/{d}] {s} id={d} n={d} e={d} r={d} u={d}\n",
        .{
            ordinal,
            total,
            split.name(),
            candidate.id,
            candidate.theta.novelty_permille,
            candidate.theta.exploration_permille,
            candidate.theta.retry_permille,
            candidate.theta.bandwidth_utilization_permille,
        },
    );
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  zig run src/stage7b_cli.zig -- validate\n" ++
            "  zig run src/stage7b_cli.zig -- plan\n" ++
            "  zig run -O ReleaseFast src/stage7b_cli.zig -- search > trials/stage7b-search.txt\n",
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
