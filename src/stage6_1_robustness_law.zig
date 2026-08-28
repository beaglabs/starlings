const std = @import("std");
const scaling = @import("stage5a_scaling.zig");
const perturb = @import("stage6_perturbation.zig");
const stage6 = @import("stage6_summary.zig");

pub const canonical_rows: usize = 2592;
pub const canonical_representative_rows: usize = 1296;
pub const canonical_sha256 =
    "86f15137ee2c3d1b066daeb6e61fa9f052ddf55cb5eb4f4c4f44aed2a11bdb04";

pub const HoldoutKind = enum {
    training,
    population_extrapolation,
    density_extrapolation,
    redundancy_extrapolation,
    severity_extrapolation,

    pub fn name(self: HoldoutKind) []const u8 {
        return switch (self) {
            .training => "training",
            .population_extrapolation => "population_N_256",
            .density_extrapolation => "density_F_over_N_4",
            .redundancy_extrapolation => "redundancy_R_8",
            .severity_extrapolation => "severity_p_500",
        };
    }
};

pub const LawKind = enum {
    naive_f_exp,
    missing_exact,
    global_scaled_exact,
    mechanism_scaled_exact,

    pub fn name(self: LawKind) []const u8 {
        return switch (self) {
            .naive_f_exp => "naive_F_exp",
            .missing_exact => "missing_exact",
            .global_scaled_exact => "global_scaled_exact",
            .mechanism_scaled_exact => "mechanism_scaled_exact",
        };
    }
};

pub const PolicyAudit = struct {
    pairs: usize = 0,
    missing_pairs: usize = 0,
    mismatches: usize = 0,
};

pub const Dataset = struct {
    coverage: stage6.CoverageDataset,
    sha256_hex: [64]u8 = undefined,
    policy_audit: PolicyAudit,

    pub fn representativeRows(self: *const Dataset) usize {
        var count: usize = 0;
        for (self.coverage.rows[0..self.coverage.row_count]) |row| {
            if (isRepresentative(row)) count += 1;
        }
        return count;
    }

    pub fn isCanonical(self: *const Dataset) bool {
        return self.coverage.header_seen and
            self.coverage.row_count == canonical_rows and
            self.coverage.malformed_rows == 0 and
            self.coverage.violationRows() == 0 and
            self.coverage.severityZeroAnomalies() == 0 and
            self.representativeRows() == canonical_representative_rows and
            self.policy_audit.pairs == canonical_representative_rows and
            self.policy_audit.missing_pairs == 0 and
            self.policy_audit.mismatches == 0 and
            std.mem.eql(u8, &self.sha256_hex, canonical_sha256);
    }
};

pub const FitParameters = struct {
    global_c: f64 = 1.0,
    operator_omission_c: f64 = 1.0,
    message_drop_c: f64 = 1.0,
};

pub const Score = struct {
    rows: usize = 0,
    reachable_rows: usize = 0,
    unreachable_rows: usize = 0,
    brier_score: f64 = 0,
    log_loss: f64 = 0,
    accuracy: f64 = 0,
    observed_reachability: f64 = 0,
    mean_predicted_reachability: f64 = 0,
};

pub const SplitCounts = struct {
    representatives: usize = 0,
    training: usize = 0,
    fit: usize = 0,
    validation: usize = 0,
    population: usize = 0,
    density: usize = 0,
    redundancy: usize = 0,
    severity: usize = 0,
};

pub const CalibrationBin = struct {
    rows: usize = 0,
    reachable_rows: usize = 0,
    predicted_sum: f64 = 0,

    pub fn observed(self: CalibrationBin) f64 {
        if (self.rows == 0) return 0;
        return @as(f64, @floatFromInt(self.reachable_rows)) /
            @as(f64, @floatFromInt(self.rows));
    }

    pub fn predicted(self: CalibrationBin) f64 {
        if (self.rows == 0) return 0;
        return self.predicted_sum / @as(f64, @floatFromInt(self.rows));
    }
};

pub const hazard_edges = [_]f64{
    0.0,
    0.05,
    0.10,
    0.25,
    0.50,
    1.0,
    2.0,
    4.0,
    8.0,
    16.0,
    32.0,
    64.0,
    1.0e300,
};
pub const calibration_bin_count = hazard_edges.len - 1;

const EvalSubset = enum {
    fit,
    validation,
    training_all,
    population,
    density,
    redundancy,
    severity,
};

pub fn parseDataset(tsv: []const u8) Dataset {
    var dataset = Dataset{
        .coverage = stage6.parseCoverageTsv(tsv),
        .policy_audit = .{},
    };
    hashHex(tsv, &dataset.sha256_hex);
    dataset.policy_audit = auditPolicyInvariant(&dataset.coverage);
    return dataset;
}

pub fn isRepresentative(row: stage6.CoverageRow) bool {
    // At B=F, round-robin and seeded emit the same local knowledge set.
    // Keep one policy copy so the reachability law is not pseudo-replicated.
    return row.policy == scaling.PolicyKind.round_robin;
}

pub fn holdoutKind(row: stage6.CoverageRow) HoldoutKind {
    // Priority makes the hard holdouts disjoint. Their union is unseen during
    // fitting and seed-2 candidate validation.
    if (row.population == 256) return .population_extrapolation;
    if (row.facts_per_operator_x1000 == 4000) return .density_extrapolation;
    if (row.redundancy == 8) return .redundancy_extrapolation;
    if (row.severity_permille == 500) return .severity_extrapolation;
    return .training;
}

pub fn splitCounts(dataset: *const Dataset) SplitCounts {
    var counts = SplitCounts{};

    for (dataset.coverage.rows[0..dataset.coverage.row_count]) |row| {
        if (!isRepresentative(row)) continue;
        counts.representatives += 1;

        switch (holdoutKind(row)) {
            .training => {
                counts.training += 1;
                if (row.trial_seed == 2) {
                    counts.validation += 1;
                } else {
                    counts.fit += 1;
                }
            },
            .population_extrapolation => counts.population += 1,
            .density_extrapolation => counts.density += 1,
            .redundancy_extrapolation => counts.redundancy += 1,
            .severity_extrapolation => counts.severity += 1,
        }
    }

    return counts;
}

pub fn missingFacts(row: stage6.CoverageRow) usize {
    std.debug.assert(row.collector_initial <= row.facts);
    return row.facts - row.collector_initial;
}

pub fn faultProbability(row: stage6.CoverageRow) f64 {
    return @as(f64, @floatFromInt(row.severity_permille)) / 1000.0;
}

pub fn allCopiesLostProbability(row: stage6.CoverageRow) f64 {
    const p = faultProbability(row);
    return std.math.pow(
        f64,
        p,
        @as(f64, @floatFromInt(row.redundancy)),
    );
}

pub fn exactMissingFactHazard(row: stage6.CoverageRow) f64 {
    const p_r = allCopiesLostProbability(row);
    if (p_r <= 0) return 0;
    if (p_r >= 1) return 1.0e300;

    return -@as(f64, @floatFromInt(missingFacts(row))) *
        @log(1.0 - p_r);
}

pub fn predict(
    row: stage6.CoverageRow,
    law: LawKind,
    fit: FitParameters,
) f64 {
    const p_r = allCopiesLostProbability(row);
    return switch (law) {
        .naive_f_exp => @exp(
            -@as(f64, @floatFromInt(row.facts)) * p_r,
        ),
        .missing_exact => @exp(-exactMissingFactHazard(row)),
        .global_scaled_exact => @exp(
            -fit.global_c * exactMissingFactHazard(row),
        ),
        .mechanism_scaled_exact => blk: {
            const scale = switch (row.perturbation) {
                .operator_omission => fit.operator_omission_c,
                .message_drop => fit.message_drop_c,
                .edge_removal => unreachable,
            };
            break :blk @exp(-scale * exactMissingFactHazard(row));
        },
    };
}

pub fn fitParameters(
    dataset: *const Dataset,
    use_all_training_seeds: bool,
) !FitParameters {
    const subset: EvalSubset = if (use_all_training_seeds)
        .training_all
    else
        .fit;

    return .{
        .global_c = try fitScale(dataset, subset, null),
        .operator_omission_c = try fitScale(
            dataset,
            subset,
            perturb.PerturbationKind.operator_omission,
        ),
        .message_drop_c = try fitScale(
            dataset,
            subset,
            perturb.PerturbationKind.message_drop,
        ),
    };
}

pub fn scoreValidation(
    dataset: *const Dataset,
    law: LawKind,
    fit: FitParameters,
) Score {
    return scoreSubset(dataset, .validation, law, fit);
}

pub fn scoreHardHoldout(
    dataset: *const Dataset,
    kind: HoldoutKind,
    law: LawKind,
    fit: FitParameters,
) Score {
    const subset: EvalSubset = switch (kind) {
        .training => .training_all,
        .population_extrapolation => .population,
        .density_extrapolation => .density,
        .redundancy_extrapolation => .redundancy,
        .severity_extrapolation => .severity,
    };
    return scoreSubset(dataset, subset, law, fit);
}

pub fn hazardCalibration(
    dataset: *const Dataset,
) [calibration_bin_count]CalibrationBin {
    var bins = [_]CalibrationBin{.{}} ** calibration_bin_count;
    const unit_fit = FitParameters{};

    for (dataset.coverage.rows[0..dataset.coverage.row_count]) |row| {
        if (!isRepresentative(row)) continue;

        const hazard = exactMissingFactHazard(row);
        var index: usize = calibration_bin_count - 1;
        var i: usize = 0;
        while (i < calibration_bin_count) : (i += 1) {
            if (hazard >= hazard_edges[i] and hazard < hazard_edges[i + 1]) {
                index = i;
                break;
            }
        }

        bins[index].rows += 1;
        if (row.reachable) bins[index].reachable_rows += 1;
        bins[index].predicted_sum += predict(row, .missing_exact, unit_fit);
    }

    return bins;
}

pub fn auditPolicyInvariant(
    coverage: *const stage6.CoverageDataset,
) PolicyAudit {
    var audit = PolicyAudit{};

    for (coverage.rows[0..coverage.row_count]) |rr| {
        if (rr.policy != scaling.PolicyKind.round_robin) continue;

        var found = false;
        for (coverage.rows[0..coverage.row_count]) |seeded| {
            if (seeded.policy != scaling.PolicyKind.seeded) continue;
            if (!sameReachabilityKey(rr, seeded)) continue;

            found = true;
            audit.pairs += 1;
            if (rr.reachable != seeded.reachable or
                rr.collector_initial != seeded.collector_initial or
                rr.max_coverage_full_bandwidth !=
                    seeded.max_coverage_full_bandwidth)
            {
                audit.mismatches += 1;
            }
            break;
        }

        if (!found) audit.missing_pairs += 1;
    }

    return audit;
}

fn sameReachabilityKey(
    a: stage6.CoverageRow,
    b: stage6.CoverageRow,
) bool {
    return a.population == b.population and
        a.facts == b.facts and
        a.facts_per_operator_x1000 == b.facts_per_operator_x1000 and
        a.redundancy == b.redundancy and
        a.trial_seed == b.trial_seed and
        a.perturbation == b.perturbation and
        a.severity_permille == b.severity_permille and
        a.perturbation_seed == b.perturbation_seed;
}

fn fitScale(
    dataset: *const Dataset,
    subset: EvalSubset,
    mechanism: ?perturb.PerturbationKind,
) !f64 {
    var rows: usize = 0;
    for (dataset.coverage.rows[0..dataset.coverage.row_count]) |row| {
        if (!isRepresentative(row)) continue;
        if (!subsetMatches(row, subset)) continue;
        if (mechanism) |kind| {
            if (row.perturbation != kind) continue;
        }
        rows += 1;
    }
    if (rows == 0) return error.NoTrainingRows;

    // Optimize log(c), keeping c positive. The broad interval is intentionally
    // conservative; Stage 6.1 is testing whether a single scalar correction
    // is enough, not trying to hide misspecification with a flexible model.
    var left: f64 = @log(@as(f64, 1.0e-3));
    var right: f64 = @log(@as(f64, 1.0e3));
    const golden: f64 = 0.6180339887498948482;

    var x1: f64 = right - golden * (right - left);
    var x2: f64 = left + golden * (right - left);
    var f1 = negativeLogLikelihood(
        dataset,
        subset,
        mechanism,
        @exp(x1),
    );
    var f2 = negativeLogLikelihood(
        dataset,
        subset,
        mechanism,
        @exp(x2),
    );

    var iteration: usize = 0;
    while (iteration < 96) : (iteration += 1) {
        if (f1 < f2) {
            right = x2;
            x2 = x1;
            f2 = f1;
            x1 = right - golden * (right - left);
            f1 = negativeLogLikelihood(
                dataset,
                subset,
                mechanism,
                @exp(x1),
            );
        } else {
            left = x1;
            x1 = x2;
            f1 = f2;
            x2 = left + golden * (right - left);
            f2 = negativeLogLikelihood(
                dataset,
                subset,
                mechanism,
                @exp(x2),
            );
        }
    }

    return @exp((left + right) / 2.0);
}

fn negativeLogLikelihood(
    dataset: *const Dataset,
    subset: EvalSubset,
    mechanism: ?perturb.PerturbationKind,
    scale: f64,
) f64 {
    var loss: f64 = 0;

    for (dataset.coverage.rows[0..dataset.coverage.row_count]) |row| {
        if (!isRepresentative(row)) continue;
        if (!subsetMatches(row, subset)) continue;
        if (mechanism) |kind| {
            if (row.perturbation != kind) continue;
        }

        const probability = clampProbability(
            @exp(-scale * exactMissingFactHazard(row)),
        );
        if (row.reachable) {
            loss -= @log(probability);
        } else {
            loss -= @log(1.0 - probability);
        }
    }

    return loss;
}

fn scoreSubset(
    dataset: *const Dataset,
    subset: EvalSubset,
    law: LawKind,
    fit: FitParameters,
) Score {
    var score = Score{};
    var brier_sum: f64 = 0;
    var log_loss_sum: f64 = 0;
    var correct: usize = 0;
    var predicted_sum: f64 = 0;

    for (dataset.coverage.rows[0..dataset.coverage.row_count]) |row| {
        if (!isRepresentative(row)) continue;
        if (!subsetMatches(row, subset)) continue;

        const probability = clampProbability(predict(row, law, fit));
        const observed: f64 = if (row.reachable) 1.0 else 0.0;
        const error_value = probability - observed;

        score.rows += 1;
        if (row.reachable) {
            score.reachable_rows += 1;
            log_loss_sum -= @log(probability);
        } else {
            score.unreachable_rows += 1;
            log_loss_sum -= @log(1.0 - probability);
        }
        brier_sum += error_value * error_value;
        predicted_sum += probability;

        const predicted_reachable = probability >= 0.5;
        if (predicted_reachable == row.reachable) correct += 1;
    }

    if (score.rows == 0) return score;

    const row_count = @as(f64, @floatFromInt(score.rows));
    score.brier_score = brier_sum / row_count;
    score.log_loss = log_loss_sum / row_count;
    score.accuracy =
        @as(f64, @floatFromInt(correct)) / row_count;
    score.observed_reachability =
        @as(f64, @floatFromInt(score.reachable_rows)) / row_count;
    score.mean_predicted_reachability = predicted_sum / row_count;
    return score;
}

fn subsetMatches(
    row: stage6.CoverageRow,
    subset: EvalSubset,
) bool {
    const holdout = holdoutKind(row);
    return switch (subset) {
        .fit => holdout == .training and row.trial_seed != 2,
        .validation => holdout == .training and row.trial_seed == 2,
        .training_all => holdout == .training,
        .population => holdout == .population_extrapolation,
        .density => holdout == .density_extrapolation,
        .redundancy => holdout == .redundancy_extrapolation,
        .severity => holdout == .severity_extrapolation,
    };
}

fn clampProbability(value: f64) f64 {
    const epsilon = 1.0e-12;
    if (value < epsilon) return epsilon;
    if (value > 1.0 - epsilon) return 1.0 - epsilon;
    return value;
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

fn testRow(
    population: usize,
    ratio_x1000: u64,
    redundancy_count: usize,
    trial_seed: u64,
    kind: perturb.PerturbationKind,
    severity: u16,
    policy: scaling.PolicyKind,
    reachable: bool,
    collector_initial: usize,
) stage6.CoverageRow {
    const facts =
        (population * @as(usize, @intCast(ratio_x1000))) / 1000;
    return .{
        .population = population,
        .facts = facts,
        .facts_per_operator_x1000 = ratio_x1000,
        .redundancy = redundancy_count,
        .policy = policy,
        .trial_seed = trial_seed,
        .perturbation = kind,
        .severity_permille = severity,
        .perturbation_seed = trial_seed ^ 123,
        .baseline_bandwidth = 1,
        .perturbed_bandwidth = if (reachable) 1 else 0,
        .reachable = reachable,
        .inflation_x1000 = if (reachable) 1000 else 0,
        .collector_initial = collector_initial,
        .collector_final_at_threshold = if (reachable) facts else collector_initial,
        .active_senders = population,
        .delivered_senders = population - 1,
        .selected_fact_units = 0,
        .suppressed_fact_units = 0,
        .max_coverage_full_bandwidth = if (reachable) facts else collector_initial,
        .violations = 0,
    };
}

test "Stage 6.1 holdout grid is deterministic and disjoint" {
    var counts = SplitCounts{};
    const populations = [_]usize{ 64, 128, 256 };
    const ratios = [_]u64{ 1000, 2000, 4000 };
    const redundancies = [_]usize{ 1, 4, 8 };
    const mechanisms = [_]perturb.PerturbationKind{
        .operator_omission,
        .message_drop,
    };
    const severities = [_]u16{ 0, 25, 50, 100, 200, 300, 400, 500 };
    const seeds = [_]u64{ 0, 1, 2 };

    for (populations) |population| {
        for (ratios) |ratio| {
            for (redundancies) |redundancy_count| {
                for (mechanisms) |kind| {
                    for (severities) |severity| {
                        for (seeds) |seed| {
                            const row = testRow(
                                population,
                                ratio,
                                redundancy_count,
                                seed,
                                kind,
                                severity,
                                .round_robin,
                                true,
                                0,
                            );
                            counts.representatives += 1;
                            switch (holdoutKind(row)) {
                                .training => {
                                    counts.training += 1;
                                    if (seed == 2) {
                                        counts.validation += 1;
                                    } else {
                                        counts.fit += 1;
                                    }
                                },
                                .population_extrapolation => counts.population += 1,
                                .density_extrapolation => counts.density += 1,
                                .redundancy_extrapolation => counts.redundancy += 1,
                                .severity_extrapolation => counts.severity += 1,
                            }
                        }
                    }
                }
            }
        }
    }

    try std.testing.expectEqual(
        @as(usize, canonical_representative_rows),
        counts.representatives,
    );
    try std.testing.expectEqual(@as(usize, 336), counts.training);
    try std.testing.expectEqual(@as(usize, 224), counts.fit);
    try std.testing.expectEqual(@as(usize, 112), counts.validation);
    try std.testing.expectEqual(@as(usize, 432), counts.population);
    try std.testing.expectEqual(@as(usize, 288), counts.density);
    try std.testing.expectEqual(@as(usize, 192), counts.redundancy);
    try std.testing.expectEqual(@as(usize, 48), counts.severity);
}

test "exact missing-fact law uses only collector-missing facts" {
    const row = testRow(
        100,
        1000,
        1,
        0,
        .message_drop,
        100,
        .round_robin,
        true,
        10,
    );
    const expected: f64 = std.math.pow(
        f64,
        @as(f64, 0.9),
        @as(f64, 90.0),
    );
    const actual = predict(row, .missing_exact, .{});
    try std.testing.expectApproxEqAbs(expected, actual, 1.0e-12);
}

test "redundancy increases null-model reachability at fixed fault rate" {
    const low = testRow(
        100,
        1000,
        1,
        0,
        .message_drop,
        300,
        .round_robin,
        true,
        0,
    );
    const high = testRow(
        100,
        1000,
        8,
        0,
        .message_drop,
        300,
        .round_robin,
        true,
        0,
    );
    try std.testing.expect(
        predict(high, .missing_exact, .{}) >
            predict(low, .missing_exact, .{}),
    );
}

test "policy audit catches a reachability mismatch" {
    var coverage = stage6.CoverageDataset{};
    coverage.header_seen = true;
    coverage.rows[0] = testRow(
        64,
        1000,
        4,
        0,
        .message_drop,
        200,
        .round_robin,
        true,
        4,
    );
    coverage.rows[1] = testRow(
        64,
        1000,
        4,
        0,
        .message_drop,
        200,
        .seeded,
        false,
        4,
    );
    coverage.row_count = 2;

    const audit = auditPolicyInvariant(&coverage);
    try std.testing.expectEqual(@as(usize, 1), audit.pairs);
    try std.testing.expectEqual(@as(usize, 0), audit.missing_pairs);
    try std.testing.expectEqual(@as(usize, 1), audit.mismatches);
}

test "mechanism-scaled law uses the mechanism-specific coefficient" {
    const omission = testRow(
        64,
        1000,
        4,
        0,
        .operator_omission,
        300,
        .round_robin,
        true,
        0,
    );
    const dropped = testRow(
        64,
        1000,
        4,
        0,
        .message_drop,
        300,
        .round_robin,
        true,
        0,
    );
    const fit = FitParameters{
        .operator_omission_c = 2.0,
        .message_drop_c = 0.5,
    };

    try std.testing.expect(
        predict(omission, .mechanism_scaled_exact, fit) <
            predict(dropped, .mechanism_scaled_exact, fit),
    );
}
