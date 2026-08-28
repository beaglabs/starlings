const std = @import("std");
const scaling = @import("stage5a_scaling.zig");
const regimes = @import("stage5c_regimes.zig");

pub const max_rows: usize = 4096;

pub const BoundaryDataset = struct {
    rows: [max_rows]regimes.BoundaryRecord = undefined,
    row_count: usize = 0,
    malformed_rows: usize = 0,
    header_seen: bool = false,

    pub fn violationRows(self: *const BoundaryDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.violations_4096 != 0 or row.violations_16384 != 0) count += 1;
        }
        return count;
    }

    pub fn censored4096(self: *const BoundaryDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (!row.success_4096) count += 1;
        }
        return count;
    }

    pub fn delayed(self: *const BoundaryDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.delayedConvergence()) count += 1;
        }
        return count;
    }

    pub fn persistent(self: *const BoundaryDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.persistentCensoring()) count += 1;
        }
        return count;
    }
};

pub const SaturationDataset = struct {
    rows: [max_rows]regimes.SaturationRecord = undefined,
    row_count: usize = 0,
    malformed_rows: usize = 0,
    header_seen: bool = false,

    pub fn violationRows(self: *const SaturationDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.violations != 0) count += 1;
        }
        return count;
    }

    pub fn minimalityFailures(self: *const SaturationDataset) usize {
        var count: usize = 0;
        for (self.rows[0..self.row_count]) |row| {
            if (row.below_threshold_success) count += 1;
        }
        return count;
    }
};

pub const BoundaryBand = struct {
    rows: usize = 0,
    last_all_success_4096: usize = 0,
    first_any_censored_4096: usize = 0,
    first_all_censored_4096: usize = 0,
    last_all_success_16384: usize = 0,
    first_any_censored_16384: usize = 0,
    first_all_censored_16384: usize = 0,
    nonmonotonic_4096: usize = 0,
    nonmonotonic_16384: usize = 0,
};

pub const SaturationStats = struct {
    rows: usize = 0,
    median_min_bandwidth: u64 = 0,
    median_aggregate_capacity_x1000: u64 = 0,
    min_aggregate_capacity_x1000: u64 = 0,
    max_aggregate_capacity_x1000: u64 = 0,
    aggregate_spread_permille: u64 = 0,
    median_redundant_capacity_x1000: u64 = 0,
    min_redundant_capacity_x1000: u64 = 0,
    max_redundant_capacity_x1000: u64 = 0,
    redundant_spread_permille: u64 = 0,
};

pub fn parseBoundaryTsv(tsv: []const u8) BoundaryDataset {
    var dataset = BoundaryDataset{};
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

        const row = parseBoundaryRow(line) catch {
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

pub fn parseSaturationTsv(tsv: []const u8) SaturationDataset {
    var dataset = SaturationDataset{};
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

        const row = parseSaturationRow(line) catch {
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

pub fn boundaryBand(
    dataset: *const BoundaryDataset,
    topology: scaling.TopologyKind,
    policy: scaling.PolicyKind,
    bandwidth: usize,
) BoundaryBand {
    var result = BoundaryBand{};

    var seen_censored_4096 = false;
    var seen_censored_16384 = false;

    for (regimes.boundary_facts) |facts| {
        var rows_at_f: usize = 0;
        var success_4096: usize = 0;
        var success_16384: usize = 0;

        for (dataset.rows[0..dataset.row_count]) |row| {
            if (row.topology != topology or
                row.policy != policy or
                row.bandwidth != bandwidth or
                row.facts != facts)
            {
                continue;
            }
            rows_at_f += 1;
            result.rows += 1;
            if (row.success_4096) success_4096 += 1;
            if (row.success_16384) success_16384 += 1;
        }

        if (rows_at_f == 0) continue;

        if (success_4096 == rows_at_f) {
            result.last_all_success_4096 = facts;
            if (seen_censored_4096) result.nonmonotonic_4096 += 1;
        } else {
            seen_censored_4096 = true;
            if (result.first_any_censored_4096 == 0) {
                result.first_any_censored_4096 = facts;
            }
            if (success_4096 == 0 and result.first_all_censored_4096 == 0) {
                result.first_all_censored_4096 = facts;
            }
        }

        if (success_16384 == rows_at_f) {
            result.last_all_success_16384 = facts;
            if (seen_censored_16384) result.nonmonotonic_16384 += 1;
        } else {
            seen_censored_16384 = true;
            if (result.first_any_censored_16384 == 0) {
                result.first_any_censored_16384 = facts;
            }
            if (success_16384 == 0 and result.first_all_censored_16384 == 0) {
                result.first_all_censored_16384 = facts;
            }
        }
    }

    return result;
}

pub fn saturationStats(
    dataset: *const SaturationDataset,
    policy: scaling.PolicyKind,
    redundancy: ?usize,
    facts_per_operator_x1000: u64,
) SaturationStats {
    var min_bandwidths: [max_rows]u64 = undefined;
    var aggregate: [max_rows]u64 = undefined;
    var redundant: [max_rows]u64 = undefined;
    var count: usize = 0;

    for (dataset.rows[0..dataset.row_count]) |row| {
        if (row.policy != policy) continue;
        if (row.facts_per_operator_x1000 != facts_per_operator_x1000) continue;
        if (redundancy) |expected| {
            if (row.redundancy != expected) continue;
        }

        min_bandwidths[count] = @intCast(row.min_bandwidth);
        aggregate[count] = row.aggregate_capacity_x1000;
        redundant[count] = row.redundant_capacity_x1000;
        count += 1;
    }

    if (count == 0) return .{};

    insertionSort(min_bandwidths[0..count]);
    insertionSort(aggregate[0..count]);
    insertionSort(redundant[0..count]);

    return .{
        .rows = count,
        .median_min_bandwidth = median(min_bandwidths[0..count]),
        .median_aggregate_capacity_x1000 = median(aggregate[0..count]),
        .min_aggregate_capacity_x1000 = aggregate[0],
        .max_aggregate_capacity_x1000 = aggregate[count - 1],
        .aggregate_spread_permille = normalizedSpread(aggregate[0..count]),
        .median_redundant_capacity_x1000 = median(redundant[0..count]),
        .min_redundant_capacity_x1000 = redundant[0],
        .max_redundant_capacity_x1000 = redundant[count - 1],
        .redundant_spread_permille = normalizedSpread(redundant[0..count]),
    };
}

fn normalizedSpread(sorted: []const u64) u64 {
    if (sorted.len == 0) return 0;
    const center = median(sorted);
    if (center == 0) return 0;
    return ((sorted[sorted.len - 1] - sorted[0]) * 1000) / center;
}

fn median(sorted: []const u64) u64 {
    std.debug.assert(sorted.len != 0);
    const middle = sorted.len / 2;
    if ((sorted.len % 2) == 1) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
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

fn parseBoundaryRow(line: []const u8) !regimes.BoundaryRecord {
    var fields: [27][]const u8 = undefined;
    const count = splitFields(line, &fields);
    if (count != fields.len) return error.InvalidFieldCount;

    return .{
        .population = try parseInt(usize, fields[0]),
        .facts = try parseInt(usize, fields[1]),
        .topology = try parseTopology(fields[2]),
        .diameter = try parseInt(usize, fields[3]),
        .redundancy = try parseInt(usize, fields[4]),
        .bandwidth = try parseInt(usize, fields[5]),
        .policy = try parsePolicy(fields[6]),
        .seed = try parseInt(u64, fields[7]),
        .q_fb_x1000 = try parseInt(u64, fields[8]),
        .q_fdb_x1000 = try parseInt(u64, fields[9]),
        .q_fnb_x1000 = try parseInt(u64, fields[10]),
        .q_fdnrb_x1000 = try parseInt(u64, fields[11]),
        .success_4096 = try parseBool(fields[12]),
        .rounds_4096 = try parseInt(u32, fields[13]),
        .collector_4096 = try parseInt(usize, fields[14]),
        .comm_4096 = try parseInt(u64, fields[15]),
        .useful_4096 = try parseInt(u64, fields[16]),
        .duplicate_4096 = try parseInt(u64, fields[17]),
        .violations_4096 = try parseInt(u64, fields[18]),
        .extended_attempted = try parseBool(fields[19]),
        .success_16384 = try parseBool(fields[20]),
        .rounds_16384 = try parseInt(u32, fields[21]),
        .collector_16384 = try parseInt(usize, fields[22]),
        .comm_16384 = try parseInt(u64, fields[23]),
        .useful_16384 = try parseInt(u64, fields[24]),
        .duplicate_16384 = try parseInt(u64, fields[25]),
        .violations_16384 = try parseInt(u64, fields[26]),
    };
}

fn parseSaturationRow(line: []const u8) !regimes.SaturationRecord {
    var fields: [16][]const u8 = undefined;
    const count = splitFields(line, &fields);
    if (count != fields.len) return error.InvalidFieldCount;

    return .{
        .population = try parseInt(usize, fields[0]),
        .facts = try parseInt(usize, fields[1]),
        .facts_per_operator_x1000 = try parseInt(u64, fields[2]),
        .redundancy = try parseInt(usize, fields[3]),
        .policy = try parsePolicy(fields[4]),
        .seed = try parseInt(u64, fields[5]),
        .min_bandwidth = try parseInt(usize, fields[6]),
        .bandwidth_fraction_x1000 = try parseInt(u64, fields[7]),
        .aggregate_capacity_x1000 = try parseInt(u64, fields[8]),
        .redundant_capacity_x1000 = try parseInt(u64, fields[9]),
        .collector_initial = try parseInt(usize, fields[10]),
        .collector_final = try parseInt(usize, fields[11]),
        .active_senders = try parseInt(usize, fields[12]),
        .selected_fact_units = try parseInt(u64, fields[13]),
        .below_threshold_success = try parseBool(fields[14]),
        .violations = try parseInt(u64, fields[15]),
    };
}

fn splitFields(line: []const u8, output: anytype) usize {
    var iterator = std.mem.splitScalar(u8, line, '\t');
    var count: usize = 0;
    while (iterator.next()) |field| {
        if (count >= output.len) return count + 1;
        output[count] = field;
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

test "boundary parser preserves delayed and persistent censoring state" {
    const tsv =
        "population\tfacts\ttopology\tdiameter\tredundancy\tbandwidth\tpolicy\tseed\tq_fb_x1000\tq_fdb_x1000\tq_fnb_x1000\tq_fdnrb_x1000\tsuccess_4096\trounds_4096\tcollector_4096\tcomm_4096\tuseful_4096\tduplicate_4096\tviolations_4096\textended_attempted\tsuccess_16384\trounds_16384\tcollector_16384\tcomm_16384\tuseful_16384\tduplicate_16384\tviolations_16384\n" ++
        "128\t512\tring\t64\t2\t2\tseeded\t0\t256000\t16384000\t2000\t64000\tno\t4096\t400\t100\t20\t80\t0\tyes\tyes\t6000\t512\t150\t40\t110\t0\n" ++
        "128\t1024\tring\t64\t2\t2\tseeded\t1\t512000\t32768000\t4000\t128000\tno\t4096\t600\t200\t30\t170\t0\tyes\tno\t16384\t900\t800\t100\t700\t0\n";

    const dataset = parseBoundaryTsv(tsv);
    try std.testing.expectEqual(@as(usize, 2), dataset.row_count);
    try std.testing.expectEqual(@as(usize, 1), dataset.delayed());
    try std.testing.expectEqual(@as(usize, 1), dataset.persistent());
    try std.testing.expectEqual(@as(usize, 0), dataset.violationRows());
}

test "saturation parser detects threshold minimality failures" {
    const tsv =
        "population\tfacts\tfacts_per_operator_x1000\tredundancy\tpolicy\tseed\tmin_bandwidth\tbandwidth_fraction_x1000\taggregate_capacity_x1000\tredundant_capacity_x1000\tcollector_initial\tcollector_final\tactive_senders\tselected_fact_units\tbelow_threshold_success\tviolations\n" ++
        "32\t64\t2000\t2\tround_robin\t0\t3\t46\t1500\t3000\t2\t64\t32\t96\tno\t0\n";

    const dataset = parseSaturationTsv(tsv);
    try std.testing.expectEqual(@as(usize, 1), dataset.row_count);
    try std.testing.expectEqual(@as(usize, 0), dataset.minimalityFailures());
    try std.testing.expectEqual(@as(usize, 0), dataset.violationRows());
}
