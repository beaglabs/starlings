const std = @import("std");
const scaling = @import("stage5a_scaling.zig");
const stage5a = @import("stage5a_summary.zig");

pub const max_features: usize = 30;
pub const max_rows: usize = stage5a.max_rows;
pub const ridge_lambda: f64 = 1.0e-6;
pub const logistic_iterations: usize = 24;

pub const HoldoutKind = enum {
    training,
    population_extrapolation,
    information_extrapolation,
    capacity_interpolation,

    pub fn name(self: HoldoutKind) []const u8 {
        return switch (self) {
            .training => "training",
            .population_extrapolation => "population_extrapolation",
            .information_extrapolation => "information_extrapolation",
            .capacity_interpolation => "capacity_interpolation",
        };
    }
};

pub const LawKind = enum {
    mechanistic,
    population,
    hybrid,

    pub fn name(self: LawKind) []const u8 {
        return switch (self) {
            .mechanistic => "mechanistic",
            .population => "population",
            .hybrid => "hybrid",
        };
    }

    pub fn featureCount(self: LawKind) usize {
        return switch (self) {
            .mechanistic, .population => 5,
            .hybrid => 6,
        };
    }
};

pub const Target = enum {
    convergence,
    rounds,
    communication,
    efficiency,

    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .convergence => "convergence",
            .rounds => "rounds",
            .communication => "communication",
            .efficiency => "efficiency",
        };
    }
};

pub const Model = struct {
    feature_count: usize = 0,
    coeffs: [max_features]f64 = [_]f64{0} ** max_features,

    pub fn predictLinear(self: Model, features: *const [max_features]f64) f64 {
        var result: f64 = 0;
        var i: usize = 0;
        while (i < self.feature_count) : (i += 1) {
            result += self.coeffs[i] * features[i];
        }
        return result;
    }

    pub fn predictProbability(self: Model, features: *const [max_features]f64) f64 {
        return sigmoid(self.predictLinear(features));
    }
};

pub const Score = struct {
    rows: usize = 0,
    successful_rows: usize = 0,
    censored_rows: usize = 0,
    mean_abs_log_error: f64 = 0,
    mean_abs_percent_error: f64 = 0,
    brier_score: f64 = 0,
    accuracy: f64 = 0,
    censored_recall: f64 = 0,
};

pub const Selection = struct {
    law: LawKind,
    validation_score: f64,
    fit_rows: usize,
    validation_rows: usize,
};

pub const Regime = struct {
    topology: scaling.TopologyKind,
    policy: scaling.PolicyKind,

    pub fn name(self: Regime, buffer: *[64]u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "{s}/{s}",
            .{ self.topology.name(), self.policy.name() },
        ) catch unreachable;
    }
};

pub const FittedRegimeModel = struct {
    regime: Regime,
    target: Target,
    law: LawKind,
    model: Model,
    train_rows: usize,
    validation_score: f64,
};

pub const PooledModel = struct {
    target: Target,
    model: Model,
    train_rows: usize,
};

pub fn holdoutKind(row: stage5a.Row) HoldoutKind {
    return switch (row.series) {
        .population => if (row.population == 1000)
            .population_extrapolation
        else
            .training,
        .information => if (row.facts == 1024)
            .information_extrapolation
        else
            .training,
        .capacity => if (isCapacityHoldout(row.redundancy, row.bandwidth))
            .capacity_interpolation
        else
            .training,
    };
}

pub fn isCapacityHoldout(redundancy: usize, bandwidth: usize) bool {
    return (redundancy == 1 and bandwidth == 2) or
        (redundancy == 1 and bandwidth == 8) or
        (redundancy == 2 and bandwidth == 4) or
        (redundancy == 4 and bandwidth == 2) or
        (redundancy == 4 and bandwidth == 16) or
        (redundancy == 8 and bandwidth == 8);
}

pub fn isFitRow(row: stage5a.Row) bool {
    return holdoutKind(row) == .training and row.seed != 2;
}

pub fn isValidationRow(row: stage5a.Row) bool {
    return holdoutKind(row) == .training and row.seed == 2;
}

pub fn regimeMatches(row: stage5a.Row, regime: Regime) bool {
    return row.topology == regime.topology and row.policy == regime.policy;
}

pub fn candidateValidation(
    summary: *const stage5a.Summary,
    regime: Regime,
    target: Target,
    law: LawKind,
) !Selection {
    const fitted = try fitRegimeSubset(summary, regime, target, law, true);
    const score = scoreRegimeSubset(
        summary,
        regime,
        target,
        law,
        fitted.model,
        .validation,
    );
    if (score.rows == 0) return error.NoValidationRows;

    return .{
        .law = law,
        .validation_score = if (target == .convergence)
            score.brier_score
        else
            score.mean_abs_log_error,
        .fit_rows = fitted.rows,
        .validation_rows = score.rows,
    };
}

pub fn selectLaw(
    summary: *const stage5a.Summary,
    regime: Regime,
    target: Target,
) !Selection {
    var best = Selection{
        .law = .mechanistic,
        .validation_score = 1.0e300,
        .fit_rows = 0,
        .validation_rows = 0,
    };

    inline for (.{ LawKind.mechanistic, LawKind.population, LawKind.hybrid }) |law| {
        const candidate = try candidateValidation(summary, regime, target, law);
        if (candidate.validation_score < best.validation_score) {
            best = candidate;
        }
    }

    if (best.validation_score >= 1.0e299) return error.NoValidationRows;
    return best;
}

pub fn fitSelectedRegime(
    summary: *const stage5a.Summary,
    regime: Regime,
    target: Target,
) !FittedRegimeModel {
    const selection = try selectLaw(summary, regime, target);
    const fitted = try fitRegimeSubset(
        summary,
        regime,
        target,
        selection.law,
        false,
    );
    return .{
        .regime = regime,
        .target = target,
        .law = selection.law,
        .model = fitted.model,
        .train_rows = fitted.rows,
        .validation_score = selection.validation_score,
    };
}

pub fn fitPooled(
    summary: *const stage5a.Summary,
    target: Target,
) !PooledModel {
    var x: [max_rows][max_features]f64 = undefined;
    var y: [max_rows]f64 = undefined;
    var rows: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        if (holdoutKind(row) != .training) continue;
        if (!targetAcceptsRow(target, row)) continue;

        pooledFeatures(row, &x[rows]);
        y[rows] = targetValue(target, row);
        rows += 1;
    }
    if (rows == 0) return error.NoTrainingRows;

    const model = if (target == .convergence)
        try fitLogistic(x[0..rows], y[0..rows], max_features)
    else
        try fitLinear(x[0..rows], y[0..rows], max_features);

    return .{ .target = target, .model = model, .train_rows = rows };
}

const Subset = struct {
    fit,
    validation,
};

const FitResult = struct {
    model: Model,
    rows: usize,
};

fn fitRegimeSubset(
    summary: *const stage5a.Summary,
    regime: Regime,
    target: Target,
    law: LawKind,
    fit_only: bool,
) !FitResult {
    var x: [max_rows][max_features]f64 = undefined;
    var y: [max_rows]f64 = undefined;
    var rows: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        if (!regimeMatches(row, regime)) continue;
        if (holdoutKind(row) != .training) continue;
        if (fit_only and row.seed == 2) continue;
        if (!targetAcceptsRow(target, row)) continue;

        regimeFeatures(row, law, &x[rows]);
        y[rows] = targetValue(target, row);
        rows += 1;
    }
    if (rows == 0) return error.NoTrainingRows;

    const feature_count = law.featureCount();
    const model = if (target == .convergence)
        try fitLogistic(x[0..rows], y[0..rows], feature_count)
    else
        try fitLinear(x[0..rows], y[0..rows], feature_count);

    return .{ .model = model, .rows = rows };
}

pub fn scorePrimaryHoldout(
    summary: *const stage5a.Summary,
    target: Target,
    kind: HoldoutKind,
) !Score {
    var combined = Score{};
    const topologies = [_]scaling.TopologyKind{ .ring, .grid, .complete };
    const policies = [_]scaling.PolicyKind{ .round_robin, .seeded, .novel_first };

    for (topologies) |topology| {
        for (policies) |policy| {
            const fitted = try fitSelectedRegime(summary, .{
                .topology = topology,
                .policy = policy,
            }, target);
            const score = scoreRegimeHoldout(summary, fitted, kind);
            mergeScore(&combined, score);
        }
    }
    return combined;
}

fn mergeScore(combined: *Score, incoming: Score) void {
    if (incoming.rows == 0) return;

    const old_rows = combined.rows;
    const new_rows = old_rows + incoming.rows;

    combined.mean_abs_log_error =
        weightedMean(
            combined.mean_abs_log_error,
            old_rows,
            incoming.mean_abs_log_error,
            incoming.rows,
        );
    combined.mean_abs_percent_error =
        weightedMean(
            combined.mean_abs_percent_error,
            old_rows,
            incoming.mean_abs_percent_error,
            incoming.rows,
        );
    combined.brier_score =
        weightedMean(
            combined.brier_score,
            old_rows,
            incoming.brier_score,
            incoming.rows,
        );
    combined.accuracy =
        weightedMean(
            combined.accuracy,
            old_rows,
            incoming.accuracy,
            incoming.rows,
        );

    const old_censored = combined.censored_rows;
    const new_censored = old_censored + incoming.censored_rows;
    combined.censored_recall = weightedMean(
        combined.censored_recall,
        old_censored,
        incoming.censored_recall,
        incoming.censored_rows,
    );

    combined.rows = new_rows;
    combined.successful_rows += incoming.successful_rows;
    combined.censored_rows = new_censored;
}

fn weightedMean(
    a: f64,
    a_count: usize,
    b: f64,
    b_count: usize,
) f64 {
    const count = a_count + b_count;
    if (count == 0) return 0;
    return (
        a * @as(f64, @floatFromInt(a_count)) +
        b * @as(f64, @floatFromInt(b_count))
    ) / @as(f64, @floatFromInt(count));
}

pub fn scoreRegimeHoldout(
    summary: *const stage5a.Summary,
    fitted: FittedRegimeModel,
    kind: HoldoutKind,
) Score {
    var score = Score{};
    var absolute_log_sum: f64 = 0;
    var absolute_percent_sum: f64 = 0;
    var brier_sum: f64 = 0;
    var correct: usize = 0;
    var censored_total: usize = 0;
    var censored_detected: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        if (!regimeMatches(row, fitted.regime)) continue;
        if (holdoutKind(row) != kind) continue;
        if (!targetAcceptsRow(fitted.target, row)) continue;

        var features: [max_features]f64 = [_]f64{0} ** max_features;
        regimeFeatures(row, fitted.law, &features);
        accumulateScore(
            fitted.target,
            fitted.model,
            &features,
            row,
            &score,
            &absolute_log_sum,
            &absolute_percent_sum,
            &brier_sum,
            &correct,
            &censored_total,
            &censored_detected,
        );
    }

    finalizeScore(
        &score,
        absolute_log_sum,
        absolute_percent_sum,
        brier_sum,
        correct,
        censored_total,
        censored_detected,
    );
    return score;
}

pub fn scorePooledHoldout(
    summary: *const stage5a.Summary,
    fitted: PooledModel,
    kind: HoldoutKind,
) Score {
    var score = Score{};
    var absolute_log_sum: f64 = 0;
    var absolute_percent_sum: f64 = 0;
    var brier_sum: f64 = 0;
    var correct: usize = 0;
    var censored_total: usize = 0;
    var censored_detected: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        if (holdoutKind(row) != kind) continue;
        if (!targetAcceptsRow(fitted.target, row)) continue;

        var features: [max_features]f64 = [_]f64{0} ** max_features;
        pooledFeatures(row, &features);
        accumulateScore(
            fitted.target,
            fitted.model,
            &features,
            row,
            &score,
            &absolute_log_sum,
            &absolute_percent_sum,
            &brier_sum,
            &correct,
            &censored_total,
            &censored_detected,
        );
    }

    finalizeScore(
        &score,
        absolute_log_sum,
        absolute_percent_sum,
        brier_sum,
        correct,
        censored_total,
        censored_detected,
    );
    return score;
}

fn scoreRegimeSubset(
    summary: *const stage5a.Summary,
    regime: Regime,
    target: Target,
    law: LawKind,
    model: Model,
    subset: Subset,
) Score {
    var score = Score{};
    var absolute_log_sum: f64 = 0;
    var absolute_percent_sum: f64 = 0;
    var brier_sum: f64 = 0;
    var correct: usize = 0;
    var censored_total: usize = 0;
    var censored_detected: usize = 0;

    for (summary.rows[0..summary.row_count]) |row| {
        if (!regimeMatches(row, regime)) continue;
        if (holdoutKind(row) != .training) continue;
        if (subset == .fit and row.seed == 2) continue;
        if (subset == .validation and row.seed != 2) continue;
        if (!targetAcceptsRow(target, row)) continue;

        var features: [max_features]f64 = [_]f64{0} ** max_features;
        regimeFeatures(row, law, &features);
        accumulateScore(
            target,
            model,
            &features,
            row,
            &score,
            &absolute_log_sum,
            &absolute_percent_sum,
            &brier_sum,
            &correct,
            &censored_total,
            &censored_detected,
        );
    }

    finalizeScore(
        &score,
        absolute_log_sum,
        absolute_percent_sum,
        brier_sum,
        correct,
        censored_total,
        censored_detected,
    );
    return score;
}

fn targetAcceptsRow(target: Target, row: stage5a.Row) bool {
    return target == .convergence or row.success;
}

fn targetValue(target: Target, row: stage5a.Row) f64 {
    return switch (target) {
        .convergence => if (row.success) 1.0 else 0.0,
        .rounds => @log(@as(f64, @floatFromInt(row.rounds))),
        .communication => @log(@as(f64, @floatFromInt(@max(row.comm_units, 1)))),
        .efficiency => efficiencyLogit(row),
    };
}

fn efficiencyLogit(row: stage5a.Row) f64 {
    if (row.comm_units == 0) return 0;
    const raw =
        @as(f64, @floatFromInt(row.useful)) /
        @as(f64, @floatFromInt(row.comm_units));
    const p = @max(1.0e-6, @min(1.0 - 1.0e-6, raw));
    return @log(p / (1.0 - p));
}

fn observedValue(target: Target, row: stage5a.Row) f64 {
    return switch (target) {
        .convergence => if (row.success) 1.0 else 0.0,
        .rounds => @as(f64, @floatFromInt(row.rounds)),
        .communication => @as(f64, @floatFromInt(row.comm_units)),
        .efficiency => if (row.comm_units == 0)
            0
        else
            1000.0 *
                @as(f64, @floatFromInt(row.useful)) /
                @as(f64, @floatFromInt(row.comm_units)),
    };
}

fn predictedValue(
    target: Target,
    model: Model,
    features: *const [max_features]f64,
) f64 {
    const eta = model.predictLinear(features);
    return switch (target) {
        .convergence => sigmoid(eta),
        .rounds, .communication => @exp(eta),
        .efficiency => 1000.0 * sigmoid(eta),
    };
}

fn accumulateScore(
    target: Target,
    model: Model,
    features: *const [max_features]f64,
    row: stage5a.Row,
    score: *Score,
    absolute_log_sum: *f64,
    absolute_percent_sum: *f64,
    brier_sum: *f64,
    correct: *usize,
    censored_total: *usize,
    censored_detected: *usize,
) void {
    score.rows += 1;
    if (row.success) {
        score.successful_rows += 1;
    } else {
        score.censored_rows += 1;
    }

    const observed = observedValue(target, row);
    const predicted = predictedValue(target, model, features);

    if (target == .convergence) {
        const diff = predicted - observed;
        brier_sum.* += diff * diff;
        const predicted_success = predicted >= 0.5;
        if (predicted_success == row.success) correct.* += 1;
        if (!row.success) {
            censored_total.* += 1;
            if (!predicted_success) censored_detected.* += 1;
        }
        return;
    }

    const safe_observed = @max(observed, 1.0e-9);
    const safe_predicted = @max(predicted, 1.0e-9);
    absolute_log_sum.* += @abs(@log(safe_predicted) - @log(safe_observed));
    absolute_percent_sum.* += @abs(predicted - observed) / safe_observed;
}

fn finalizeScore(
    score: *Score,
    absolute_log_sum: f64,
    absolute_percent_sum: f64,
    brier_sum: f64,
    correct: usize,
    censored_total: usize,
    censored_detected: usize,
) void {
    if (score.rows == 0) return;

    if (absolute_log_sum != 0 or absolute_percent_sum != 0) {
        score.mean_abs_log_error =
            absolute_log_sum / @as(f64, @floatFromInt(score.rows));
        score.mean_abs_percent_error =
            absolute_percent_sum / @as(f64, @floatFromInt(score.rows));
    }

    if (brier_sum != 0 or score.successful_rows + score.censored_rows == score.rows) {
        score.brier_score = brier_sum / @as(f64, @floatFromInt(score.rows));
        score.accuracy =
            @as(f64, @floatFromInt(correct)) /
            @as(f64, @floatFromInt(score.rows));
        score.censored_recall = if (censored_total == 0)
            0
        else
            @as(f64, @floatFromInt(censored_detected)) /
                @as(f64, @floatFromInt(censored_total));
    }
}

fn regimeFeatures(
    row: stage5a.Row,
    law: LawKind,
    output: *[max_features]f64,
) void {
    output.* = [_]f64{0} ** max_features;
    output[0] = 1;
    switch (law) {
        .mechanistic => {
            output[1] = @log(@as(f64, @floatFromInt(row.diameter + 1)));
            output[2] = @log(@as(f64, @floatFromInt(row.facts)));
            output[3] = @log(@as(f64, @floatFromInt(row.redundancy)));
            output[4] = @log(@as(f64, @floatFromInt(row.bandwidth)));
        },
        .population => {
            output[1] = @log(@as(f64, @floatFromInt(row.population)));
            output[2] = @log(@as(f64, @floatFromInt(row.facts)));
            output[3] = @log(@as(f64, @floatFromInt(row.redundancy)));
            output[4] = @log(@as(f64, @floatFromInt(row.bandwidth)));
        },
        .hybrid => {
            output[1] = @log(@as(f64, @floatFromInt(row.population)));
            output[2] = @log(@as(f64, @floatFromInt(row.diameter + 1)));
            output[3] = @log(@as(f64, @floatFromInt(row.facts)));
            output[4] = @log(@as(f64, @floatFromInt(row.redundancy)));
            output[5] = @log(@as(f64, @floatFromInt(row.bandwidth)));
        },
    }
}

fn pooledFeatures(row: stage5a.Row, output: *[max_features]f64) void {
    output.* = [_]f64{0} ** max_features;
    const numeric = [_]f64{
        @log(@as(f64, @floatFromInt(row.population))),
        @log(@as(f64, @floatFromInt(row.facts))),
        @log(@as(f64, @floatFromInt(row.diameter + 1))),
        @log(@as(f64, @floatFromInt(row.redundancy))),
        @log(@as(f64, @floatFromInt(row.bandwidth))),
    };

    output[0] = 1;
    for (numeric, 0..) |value, index| output[1 + index] = value;

    const is_grid: f64 = if (row.topology == .grid) 1 else 0;
    const is_complete: f64 = if (row.topology == .complete) 1 else 0;
    const is_seeded: f64 = if (row.policy == .seeded) 1 else 0;
    const is_novel: f64 = if (row.policy == .novel_first) 1 else 0;

    output[6] = is_grid;
    output[7] = is_complete;
    output[8] = is_seeded;
    output[9] = is_novel;

    var cursor: usize = 10;
    for (numeric) |value| {
        output[cursor] = value * is_grid;
        output[cursor + 1] = value * is_complete;
        cursor += 2;
    }
    for (numeric) |value| {
        output[cursor] = value * is_seeded;
        output[cursor + 1] = value * is_novel;
        cursor += 2;
    }
    std.debug.assert(cursor == max_features);
}

fn fitLinear(
    x: []const [max_features]f64,
    y: []const f64,
    feature_count: usize,
) !Model {
    var matrix: [max_features][max_features]f64 =
        [_][max_features]f64{[_]f64{0} ** max_features} ** max_features;
    var rhs: [max_features]f64 = [_]f64{0} ** max_features;

    for (x, y) |features, target| {
        var i: usize = 0;
        while (i < feature_count) : (i += 1) {
            rhs[i] += features[i] * target;
            var j: usize = 0;
            while (j < feature_count) : (j += 1) {
                matrix[i][j] += features[i] * features[j];
            }
        }
    }
    addRidge(&matrix, feature_count);
    const coeffs = try solve(matrix, rhs, feature_count);
    return .{ .feature_count = feature_count, .coeffs = coeffs };
}

fn fitLogistic(
    x: []const [max_features]f64,
    y: []const f64,
    feature_count: usize,
) !Model {
    var model = Model{ .feature_count = feature_count };

    var iteration: usize = 0;
    while (iteration < logistic_iterations) : (iteration += 1) {
        var matrix: [max_features][max_features]f64 =
            [_][max_features]f64{[_]f64{0} ** max_features} ** max_features;
        var rhs: [max_features]f64 = [_]f64{0} ** max_features;

        for (x, y) |features, target| {
            const eta = model.predictLinear(&features);
            const probability = sigmoid(eta);
            const weight = @max(probability * (1.0 - probability), 1.0e-5);
            const working = eta + (target - probability) / weight;

            var i: usize = 0;
            while (i < feature_count) : (i += 1) {
                rhs[i] += weight * features[i] * working;
                var j: usize = 0;
                while (j < feature_count) : (j += 1) {
                    matrix[i][j] += weight * features[i] * features[j];
                }
            }
        }

        addRidge(&matrix, feature_count);
        model.coeffs = try solve(matrix, rhs, feature_count);
    }
    return model;
}

fn addRidge(
    matrix: *[max_features][max_features]f64,
    feature_count: usize,
) void {
    var i: usize = 0;
    while (i < feature_count) : (i += 1) {
        matrix[i][i] += ridge_lambda;
    }
}

fn solve(
    input_matrix: [max_features][max_features]f64,
    input_rhs: [max_features]f64,
    feature_count: usize,
) ![max_features]f64 {
    var matrix = input_matrix;
    var rhs = input_rhs;
    var column: usize = 0;

    while (column < feature_count) : (column += 1) {
        var pivot = column;
        var pivot_abs = @abs(matrix[column][column]);
        var row = column + 1;
        while (row < feature_count) : (row += 1) {
            const candidate = @abs(matrix[row][column]);
            if (candidate > pivot_abs) {
                pivot = row;
                pivot_abs = candidate;
            }
        }
        if (pivot_abs < 1.0e-12) return error.SingularModel;

        if (pivot != column) {
            const temp_row = matrix[column];
            matrix[column] = matrix[pivot];
            matrix[pivot] = temp_row;
            const temp_rhs = rhs[column];
            rhs[column] = rhs[pivot];
            rhs[pivot] = temp_rhs;
        }

        const divisor = matrix[column][column];
        var j = column;
        while (j < feature_count) : (j += 1) {
            matrix[column][j] /= divisor;
        }
        rhs[column] /= divisor;

        row = 0;
        while (row < feature_count) : (row += 1) {
            if (row == column) continue;
            const factor = matrix[row][column];
            if (@abs(factor) < 1.0e-18) continue;
            j = column;
            while (j < feature_count) : (j += 1) {
                matrix[row][j] -= factor * matrix[column][j];
            }
            rhs[row] -= factor * rhs[column];
        }
    }

    var result: [max_features]f64 = [_]f64{0} ** max_features;
    var i: usize = 0;
    while (i < feature_count) : (i += 1) result[i] = rhs[i];
    return result;
}

fn sigmoid(value: f64) f64 {
    if (value >= 0) {
        const z = @exp(-value);
        return 1.0 / (1.0 + z);
    }
    const z = @exp(value);
    return z / (1.0 + z);
}

test "hard holdouts are fixed independently of seed and outcome" {
    const base = stage5a.Row{
        .series = .population,
        .population = 1000,
        .facts = 32,
        .topology = .ring,
        .diameter = 500,
        .edges = 1000,
        .redundancy = 2,
        .bandwidth = 2,
        .policy = .novel_first,
        .seed = 0,
        .success = true,
        .rounds = 100,
        .collector_initial = 1,
        .collector_final = 32,
        .policy_calls = 1,
        .actions = 1,
        .rejected = 0,
        .messages = 1,
        .comm_units = 1,
        .useful = 1,
        .duplicate = 0,
        .useful_per_1000 = 1000,
        .violations = 0,
    };

    try std.testing.expectEqual(
        HoldoutKind.population_extrapolation,
        holdoutKind(base),
    );

    var information = base;
    information.series = .information;
    information.population = 128;
    information.facts = 1024;
    information.seed = 2;
    information.success = false;
    try std.testing.expectEqual(
        HoldoutKind.information_extrapolation,
        holdoutKind(information),
    );

    var capacity = base;
    capacity.series = .capacity;
    capacity.population = 128;
    capacity.facts = 128;
    capacity.redundancy = 4;
    capacity.bandwidth = 16;
    try std.testing.expectEqual(
        HoldoutKind.capacity_interpolation,
        holdoutKind(capacity),
    );
}

test "training validation split never admits hard holdouts" {
    const row = stage5a.Row{
        .series = .population,
        .population = 500,
        .facts = 32,
        .topology = .grid,
        .diameter = 44,
        .edges = 900,
        .redundancy = 2,
        .bandwidth = 2,
        .policy = .round_robin,
        .seed = 0,
        .success = true,
        .rounds = 100,
        .collector_initial = 1,
        .collector_final = 32,
        .policy_calls = 1,
        .actions = 1,
        .rejected = 0,
        .messages = 1,
        .comm_units = 10,
        .useful = 5,
        .duplicate = 5,
        .useful_per_1000 = 500,
        .violations = 0,
    };

    try std.testing.expect(isFitRow(row));
    try std.testing.expect(!isValidationRow(row));
    row.seed = 2;
    try std.testing.expect(!isFitRow(row));
    try std.testing.expect(isValidationRow(row));
    row.population = 1000;
    try std.testing.expect(!isFitRow(row));
    try std.testing.expect(!isValidationRow(row));
}

test "linear solver recovers a deterministic log law" {
    var x: [6][max_features]f64 =
        [_][max_features]f64{[_]f64{0} ** max_features} ** 6;
    var y: [6]f64 = undefined;

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        x[i][0] = 1;
        x[i][1] = @as(f64, @floatFromInt(i + 1));
        y[i] = 2.0 + 3.0 * x[i][1];
    }

    const model = try fitLinear(x[0..], y[0..], 2);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), model.coeffs[0], 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), model.coeffs[1], 1.0e-4);
}

test "logistic fit orders easy success above hard failure" {
    var x: [6][max_features]f64 =
        [_][max_features]f64{[_]f64{0} ** max_features} ** 6;
    const y = [_]f64{ 1, 1, 1, 0, 0, 0 };

    for (0..6) |i| {
        x[i][0] = 1;
        x[i][1] = if (i < 3)
            @as(f64, @floatFromInt(3 - i))
        else
            -@as(f64, @floatFromInt(i - 2));
    }

    const model = try fitLogistic(x[0..], y[0..], 2);
    try std.testing.expect(model.predictProbability(&x[0]) > 0.5);
    try std.testing.expect(model.predictProbability(&x[5]) < 0.5);
}

test "pooled challenger feature contract remains fixed at thirty terms" {
    var row = stage5a.Row{
        .series = .population,
        .population = 100,
        .facts = 32,
        .topology = .grid,
        .diameter = 19,
        .edges = 180,
        .redundancy = 2,
        .bandwidth = 2,
        .policy = .novel_first,
        .seed = 0,
        .success = true,
        .rounds = 10,
        .collector_initial = 1,
        .collector_final = 32,
        .policy_calls = 1,
        .actions = 1,
        .rejected = 0,
        .messages = 1,
        .comm_units = 100,
        .useful = 50,
        .duplicate = 50,
        .useful_per_1000 = 500,
        .violations = 0,
    };
    var features: [max_features]f64 = undefined;
    pooledFeatures(row, &features);
    try std.testing.expectEqual(@as(f64, 1), features[0]);
    try std.testing.expectEqual(@as(f64, 1), features[6]);
    try std.testing.expectEqual(@as(f64, 0), features[7]);
    try std.testing.expectEqual(@as(f64, 0), features[8]);
    try std.testing.expectEqual(@as(f64, 1), features[9]);
}
