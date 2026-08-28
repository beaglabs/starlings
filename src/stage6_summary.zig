const std = @import("std");
const scaling = @import("stage5a_scaling.zig");
const perturb = @import("stage6_perturbation.zig");

pub const max_rows: usize = 4096;

pub const SparseDataset = struct {
    rows: [max_rows]SparseRow = undefined,
    row_count: usize = 0,
    malformed_rows: usize = 0,
    header_seen: bool = false,

    pub fn violationRows(self: *const SparseDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.violations != 0) count += 1;
        }
        return count;
    }

    pub fn severityZeroFailures(self: *const SparseDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.severity_permille == 0 and !row.success) count += 1;
        }
        return count;
    }
};

pub const CoverageDataset = struct {
    rows: [max_rows]CoverageRow = undefined,
    row_count: usize = 0,
    malformed_rows: usize = 0,
    header_seen: bool = false,

    pub fn violationRows(self: *const CoverageDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.violations != 0) count += 1;
        }
        return count;
    }

    pub fn unreachableRows(self: *const CoverageDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (!row.reachable) count += 1;
        }
        return count;
    }

    pub fn severityZeroAnomalies(self: *const CoverageDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.severity_permille != 0) continue;
            if (!row.reachable or
                row.perturbed_bandwidth != row.baseline_bandwidth or
                row.inflation_x1000 != 1000)
            {
                count += 1;
            }
        }
        return count;
    }
};

pub const SparseRow = struct {
    anchor: []const u8,
    population: usize,
    facts: usize,
    topology: scaling.TopologyKind,
    diameter: usize,
    redundancy: usize,
    bandwidth: usize,
    policy: scaling.PolicyKind,
    lambda_x1e6: u64,
    trial_seed: u64,
    perturbation: perturb.PerturbationKind,
    severity_permille: u16,
    perturbation_seed: u64,
    success: bool,
    rounds: u32,
    collector_initial: usize,
    collector_final: usize,
    policy_slots: u64,
    policy_calls: u64,
    operator_omissions: u64,
    actions: u64,
    rejected: u64,
    attempted_messages: u64,
    delivered_messages: u64,
    suppressed_messages: u64,
    attempted_units: u64,
    delivered_units: u64,
    suppressed_units: u64,
    delivery_ratio_permille: u64,
    useful: u64,
    duplicate: u64,
    violations: u64,
    removed_edges: usize,
    component_size: usize,
    component_fact_coverage: usize,
    structurally_reachable: bool,
};

pub const CoverageRow = struct {
    population: usize,
    facts: usize,
    facts_per_operator_x1000: u64,
    redundancy: usize,
    policy: scaling.PolicyKind,
    trial_seed: u64,
    perturbation: perturb.PerturbationKind,
    severity_permille: u16,
    perturbation_seed: u64,
    baseline_bandwidth: usize,
    perturbed_bandwidth: usize,
    reachable: bool,
    inflation_x1000: u64,
    collector_initial: usize,
    collector_final_at_threshold: usize,
    active_senders: usize,
    delivered_senders: usize,
    selected_fact_units: u64,
    suppressed_fact_units: u64,
    max_coverage_full_bandwidth: usize,
    violations: u64,
};

pub const SparseBoundary = struct {
    rows: usize = 0,
    last_all_success_permille: u16 = 0,
    first_any_censored_permille: u16 = 0,
    first_all_censored_permille: u16 = 0,
    first_any_structural_permille: u16 = 0,
    first_all_structural_permille: u16 = 0,
    nonmonotonic_success: usize = 0,
    severity0_successes: usize = 0,
};

pub const SparseSeverityStats = struct {
    rows: usize = 0,
    successes: usize = 0,
    structurally_reachable: usize = 0,
    avg_success_rounds: u64 = 0,
    avg_delivery_ratio_permille: u64 = 0,
    avg_removed_edges_x1000: u64 = 0,
    avg_component_fraction_permille: u64 = 0,
};

pub const CoverageStats = struct {
    rows: usize = 0,
    reachable: usize = 0,
    median_baseline_bandwidth: u64 = 0,
    median_perturbed_bandwidth: u64 = 0,
    median_inflation_x1000: u64 = 0,
    median_coverage_fraction_permille: u64 = 0,
};

pub fn parseSparseTsv(tsv: []const u8) SparseDataset {
    var dataset = SparseDataset{};
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    var line_number: usize = 0;

    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (line_number == 1 and std.mem.startsWith(u8, line, "anchor\tpopulation\t")) {
            dataset.header_seen = true;
            continue;
        }

        const row = parseSparseRow(line) catch {
            dataset.malformed_rows += 1;
            continue;
        };
        if (dataset.row_count >= max_rows) {
            dataset.malformed_rows += 1;
            continue;
        }
        dataset.rows[dataset.row_count] = row;
        dataset.row_count += 1;
    }

    return dataset;
}

pub fn parseCoverageTsv(tsv: []const u8) CoverageDataset {
    var dataset = CoverageDataset{};
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    var line_number: usize = 0;

    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (line_number == 1 and std.mem.startsWith(u8, line, "population\tfacts\t")) {
            dataset.header_seen = true;
            continue;
        }

        const row = parseCoverageRow(line) catch {
            dataset.malformed_rows += 1;
            continue;
        };
        if (dataset.row_count >= max_rows) {
            dataset.malformed_rows += 1;
            continue;
        }
        dataset.rows[dataset.row_count] = row;
        dataset.row_count += 1;
    }

    return dataset;
}

pub fn sparseBoundary(
    dataset: *const SparseDataset,
    anchor: []const u8,
    kind: perturb.PerturbationKind,
) SparseBoundary {
    var result = SparseBoundary{};
    var seen_censored = false;

    for (perturb.sparse_severities_permille) |severity| {
        var rows_at_severity: usize = 0;
        var successes: usize = 0;
        var structural_failures: usize = 0;

        for (dataset.rows[0..dataset.row_count]) |row| {
            if (!std.mem.eql(u8, row.anchor, anchor)) continue;
            if (row.perturbation != kind) continue;
            if (row.severity_permille != severity) continue;

            rows_at_severity += 1;
            result.rows += 1;
            if (row.success) successes += 1;
            if (!row.structurally_reachable) structural_failures += 1;
        }

        if (rows_at_severity == 0) continue;
        if (severity == 0) result.severity0_successes = successes;

        if (successes == rows_at_severity) {
            result.last_all_success_permille = severity;
            if (seen_censored) result.nonmonotonic_success += 1;
        } else {
            seen_censored = true;
            if (result.first_any_censored_permille == 0) {
                result.first_any_censored_permille = severity;
            }
            if (successes == 0 and result.first_all_censored_permille == 0) {
                result.first_all_censored_permille = severity;
            }
        }

        if (structural_failures != 0 and
            result.first_any_structural_permille == 0)
        {
            result.first_any_structural_permille = severity;
        }
        if (structural_failures == rows_at_severity and
            result.first_all_structural_permille == 0)
        {
            result.first_all_structural_permille = severity;
        }
    }

    return result;
}

pub fn sparseSeverityStats(
    dataset: *const SparseDataset,
    anchor: []const u8,
    kind: perturb.PerturbationKind,
    severity: u16,
) SparseSeverityStats {
    var result = SparseSeverityStats{};
    var success_round_sum: u64 = 0;
    var delivery_sum: u64 = 0;
    var removed_sum: u64 = 0;
    var component_fraction_sum: u64 = 0;

    for (dataset.rows[0..dataset.row_count]) |row| {
        if (!std.mem.eql(u8, row.anchor, anchor)) continue;
        if (row.perturbation != kind) continue;
        if (row.severity_permille != severity) continue;

        result.rows += 1;
        if (row.success) {
            result.successes += 1;
            success_round_sum += @as(u64, @intCast(row.rounds));
        }
        if (row.structurally_reachable) result.structurally_reachable += 1;
        delivery_sum += row.delivery_ratio_permille;
        removed_sum += @as(u64, @intCast(row.removed_edges)) * 1000;
        component_fraction_sum +=
            (@as(u64, @intCast(row.component_size)) * 1000) /
            @as(u64, @intCast(row.population));
    }

    if (result.rows == 0) return result;

    result.avg_success_rounds = if (result.successes == 0)
        0
    else
        success_round_sum / @as(u64, @intCast(result.successes));
    result.avg_delivery_ratio_permille =
        delivery_sum / @as(u64, @intCast(result.rows));
    result.avg_removed_edges_x1000 =
        removed_sum / @as(u64, @intCast(result.rows));
    result.avg_component_fraction_permille =
        component_fraction_sum / @as(u64, @intCast(result.rows));

    return result;
}

pub fn coverageStats(
    dataset: *const CoverageDataset,
    kind: perturb.PerturbationKind,
    policy: scaling.PolicyKind,
    redundancy: usize,
    ratio_x1000: u64,
    severity: u16,
) CoverageStats {
    var baselines: [max_rows]u64 = undefined;
    var thresholds: [max_rows]u64 = undefined;
    var inflations: [max_rows]u64 = undefined;
    var coverage_fractions: [max_rows]u64 = undefined;
    var count: usize = 0;
    var total_rows: usize = 0;

    for (dataset.rows[0..dataset.row_count]) |row| {
        if (row.perturbation != kind) continue;
        if (row.policy != policy) continue;
        if (row.redundancy != redundancy) continue;
        if (row.facts_per_operator_x1000 != ratio_x1000) continue;
        if (row.severity_permille != severity) continue;

        total_rows += 1;
        if (!row.reachable) continue;

        baselines[count] = @intCast(row.baseline_bandwidth);
        thresholds[count] = @intCast(row.perturbed_bandwidth);
        inflations[count] = row.inflation_x1000;
        coverage_fractions[count] =
            (@as(u64, @intCast(row.max_coverage_full_bandwidth)) * 1000) /
            @as(u64, @intCast(row.facts));
        count += 1;
    }

    var result = CoverageStats{
        .rows = total_rows,
        .reachable = count,
    };
    if (count == 0) return result;

    insertionSort(baselines[0..count]);
    insertionSort(thresholds[0..count]);
    insertionSort(inflations[0..count]);
    insertionSort(coverage_fractions[0..count]);

    result.median_baseline_bandwidth = median(baselines[0..count]);
    result.median_perturbed_bandwidth = median(thresholds[0..count]);
    result.median_inflation_x1000 = median(inflations[0..count]);
    result.median_coverage_fraction_permille =
        median(coverage_fractions[0..count]);
    return result;
}

fn parseSparseRow(line: []const u8) !SparseRow {
    var fields: [36][]const u8 = undefined;
    const count = splitFields(line, &fields);
    if (count != fields.len) return error.InvalidFieldCount;

    return .{
        .anchor = fields[0],
        .population = try parseInt(usize, fields[1]),
        .facts = try parseInt(usize, fields[2]),
        .topology = try parseTopology(fields[3]),
        .diameter = try parseInt(usize, fields[4]),
        .redundancy = try parseInt(usize, fields[5]),
        .bandwidth = try parseInt(usize, fields[6]),
        .policy = try parsePolicy(fields[7]),
        .lambda_x1e6 = try parseInt(u64, fields[8]),
        .trial_seed = try parseInt(u64, fields[9]),
        .perturbation = try parsePerturbation(fields[10]),
        .severity_permille = try parseInt(u16, fields[11]),
        .perturbation_seed = try parseInt(u64, fields[12]),
        .success = try parseBool(fields[13]),
        .rounds = try parseInt(u32, fields[14]),
        .collector_initial = try parseInt(usize, fields[15]),
        .collector_final = try parseInt(usize, fields[16]),
        .policy_slots = try parseInt(u64, fields[17]),
        .policy_calls = try parseInt(u64, fields[18]),
        .operator_omissions = try parseInt(u64, fields[19]),
        .actions = try parseInt(u64, fields[20]),
        .rejected = try parseInt(u64, fields[21]),
        .attempted_messages = try parseInt(u64, fields[22]),
        .delivered_messages = try parseInt(u64, fields[23]),
        .suppressed_messages = try parseInt(u64, fields[24]),
        .attempted_units = try parseInt(u64, fields[25]),
        .delivered_units = try parseInt(u64, fields[26]),
        .suppressed_units = try parseInt(u64, fields[27]),
        .delivery_ratio_permille = try parseInt(u64, fields[28]),
        .useful = try parseInt(u64, fields[29]),
        .duplicate = try parseInt(u64, fields[30]),
        .violations = try parseInt(u64, fields[31]),
        .removed_edges = try parseInt(usize, fields[32]),
        .component_size = try parseInt(usize, fields[33]),
        .component_fact_coverage = try parseInt(usize, fields[34]),
        .structurally_reachable = try parseBool(fields[35]),
    };
}

fn parseCoverageRow(line: []const u8) !CoverageRow {
    var fields: [21][]const u8 = undefined;
    const count = splitFields(line, &fields);
    if (count != fields.len) return error.InvalidFieldCount;

    return .{
        .population = try parseInt(usize, fields[0]),
        .facts = try parseInt(usize, fields[1]),
        .facts_per_operator_x1000 = try parseInt(u64, fields[2]),
        .redundancy = try parseInt(usize, fields[3]),
        .policy = try parsePolicy(fields[4]),
        .trial_seed = try parseInt(u64, fields[5]),
        .perturbation = try parsePerturbation(fields[6]),
        .severity_permille = try parseInt(u16, fields[7]),
        .perturbation_seed = try parseInt(u64, fields[8]),
        .baseline_bandwidth = try parseInt(usize, fields[9]),
        .perturbed_bandwidth = try parseInt(usize, fields[10]),
        .reachable = try parseBool(fields[11]),
        .inflation_x1000 = try parseInt(u64, fields[12]),
        .collector_initial = try parseInt(usize, fields[13]),
        .collector_final_at_threshold = try parseInt(usize, fields[14]),
        .active_senders = try parseInt(usize, fields[15]),
        .delivered_senders = try parseInt(usize, fields[16]),
        .selected_fact_units = try parseInt(u64, fields[17]),
        .suppressed_fact_units = try parseInt(u64, fields[18]),
        .max_coverage_full_bandwidth = try parseInt(usize, fields[19]),
        .violations = try parseInt(u64, fields[20]),
    };
}

fn splitFields(line: []const u8, output: anytype) usize {
    var iterator = std.mem.splitScalar(u8, line, '\t');
    var count: usize = 0;
    while (iterator.next()) |field| {
        if (count >= output.*.len) return count + 1;
        output.*[count] = field;
        count += 1;
    }
    return count;
}

fn parseInt(comptime T: type, text: []const u8) !T {
    if (text.len == 0) return error.EmptyField;
    return std.fmt.parseInt(T, text, 10);
}

fn parseBool(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "yes")) return true;
    if (std.mem.eql(u8, text, "no")) return false;
    return error.InvalidBoolean;
}

fn parseTopology(text: []const u8) !scaling.TopologyKind {
    if (std.mem.eql(u8, text, "ring")) return .ring;
    if (std.mem.eql(u8, text, "grid")) return .grid;
    if (std.mem.eql(u8, text, "complete")) return .complete;
    return error.InvalidTopology;
}

fn parsePolicy(text: []const u8) !scaling.PolicyKind {
    if (std.mem.eql(u8, text, "round_robin")) return .round_robin;
    if (std.mem.eql(u8, text, "seeded")) return .seeded;
    if (std.mem.eql(u8, text, "novel_first")) return .novel_first;
    return error.InvalidPolicy;
}

fn parsePerturbation(text: []const u8) !perturb.PerturbationKind {
    if (std.mem.eql(u8, text, "operator_omission")) return .operator_omission;
    if (std.mem.eql(u8, text, "message_drop")) return .message_drop;
    if (std.mem.eql(u8, text, "edge_removal")) return .edge_removal;
    return error.InvalidPerturbation;
}

fn insertionSort(values: []u64) void {
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

fn median(sorted: []const u64) u64 {
    std.debug.assert(sorted.len != 0);
    const middle = sorted.len / 2;
    if ((sorted.len % 2) == 1) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
}

test "sparse parser preserves structural reachability" {
    const tsv =
        "anchor\tpopulation\tfacts\ttopology\tdiameter\tredundancy\tbandwidth\tpolicy\tlambda_x1e6\ttrial_seed\tperturbation\tseverity_permille\tperturbation_seed\tsuccess\trounds\tcollector_initial\tcollector_final\tpolicy_slots\tpolicy_calls\toperator_omissions\tactions\trejected\tattempted_messages\tdelivered_messages\tsuppressed_messages\tattempted_units\tdelivered_units\tsuppressed_units\tdelivery_ratio_permille\tuseful\tduplicate\tviolations\tremoved_edges\tcomponent_size\tcomponent_fact_coverage\tstructurally_reachable\n" ++
        "ring_rr\t128\t384\tring\t64\t2\t2\tround_robin\t46875\t0\tedge_removal\t100\t42\tno\t4096\t5\t200\t1\t1\t0\t1\t0\t2\t1\t1\t4\t2\t2\t500\t1\t1\t0\t12\t60\t300\tno\n";

    const dataset = parseSparseTsv(tsv);
    try std.testing.expectEqual(@as(usize, 1), dataset.row_count);
    try std.testing.expect(!dataset.rows[0].structurally_reachable);
    try std.testing.expectEqual(@as(usize, 0), dataset.violationRows());
}

test "coverage parser preserves unreachable thresholds" {
    const tsv =
        "population\tfacts\tfacts_per_operator_x1000\tredundancy\tpolicy\ttrial_seed\tperturbation\tseverity_permille\tperturbation_seed\tbaseline_bandwidth\tperturbed_bandwidth\treachable\tinflation_x1000\tcollector_initial\tcollector_final_at_threshold\tactive_senders\tdelivered_senders\tselected_fact_units\tsuppressed_fact_units\tmax_coverage_full_bandwidth\tviolations\n" ++
        "64\t128\t2000\t4\tseeded\t0\tmessage_drop\t300\t42\t7\t0\tno\t0\t4\t100\t64\t40\t4000\t1200\t100\t0\n";

    const dataset = parseCoverageTsv(tsv);
    try std.testing.expectEqual(@as(usize, 1), dataset.row_count);
    try std.testing.expectEqual(@as(usize, 1), dataset.unreachableRows());
    try std.testing.expectEqual(@as(usize, 0), dataset.violationRows());
}
