const std = @import("std");
const convergence = @import("distributed_fact_convergence.zig");
const model_eval = @import("protocol_model_eval.zig");

pub const backend_error_sentinel = "__BACKEND_ERROR__";
pub const max_completion_bytes: usize = 4096;
const max_runs: usize = 256;
const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

pub const ModeMetrics = struct {
    runs: usize = 0,
    successes: usize = 0,
    model_calls: usize = 0,
    protocol_actions: usize = 0,
    invalid_actions: usize = 0,
    backend_errors: usize = 0,
    semantic_violations: usize = 0,
    rounds: usize = 0,
    network_messages: usize = 0,
    useful_fact_deliveries: usize = 0,
    duplicate_fact_transmissions: usize = 0,
    completion_tokens: usize = 0,
    generated_bytes: usize = 0,
    latency_us: u64 = 0,
    unique_successful_trajectories: usize = 0,

    pub fn successRatePermille(self: ModeMetrics) usize {
        if (self.runs == 0) return 0;
        return (self.successes * 1000) / self.runs;
    }

    pub fn protocolValidityPermille(self: ModeMetrics) usize {
        if (self.model_calls == 0) return 0;
        return (self.protocol_actions * 1000) / self.model_calls;
    }

    pub fn averageRoundsPermille(self: ModeMetrics) usize {
        if (self.runs == 0) return 0;
        return (self.rounds * 1000) / self.runs;
    }

    pub fn usefulFactsPerMessagePermille(self: ModeMetrics) usize {
        if (self.network_messages == 0) return 0;
        return (self.useful_fact_deliveries * 1000) / self.network_messages;
    }
};

pub const Summary = struct {
    typed: ModeMetrics = .{},
    constrained: ModeMetrics = .{},
    records: usize = 0,
    malformed_records: usize = 0,
    replay_errors: usize = 0,
    typed_seeds: [max_runs]u64 = undefined,
    typed_seed_count: usize = 0,
    constrained_seeds: [max_runs]u64 = undefined,
    constrained_seed_count: usize = 0,
    typed_success_hashes: [max_runs]u64 = undefined,
    typed_success_hash_count: usize = 0,
    constrained_success_hashes: [max_runs]u64 = undefined,
    constrained_success_hash_count: usize = 0,

    pub fn balanced(self: *const Summary) bool {
        if (self.typed.runs != self.constrained.runs) return false;
        if (self.typed_seed_count != self.constrained_seed_count) return false;

        var i: usize = 0;
        while (i < self.typed_seed_count) : (i += 1) {
            if (!containsSeed(self.constrained_seeds[0..self.constrained_seed_count], self.typed_seeds[i])) {
                return false;
            }
        }
        return true;
    }
};

const RawRecord = struct {
    seed: u64,
    mode: model_eval.DecodeMode,
    round: u32,
    worker: u8,
    knowledge_before: u8,
    generation_seed: u32,
    completion_tokens: usize,
    latency_us: u64,
    escaped_completion: []const u8,
};

const RunAccumulator = struct {
    seed: u64,
    mode: model_eval.DecodeMode,
    knowledge: [convergence.worker_count]u8,
    current_round: u32 = 1,
    seen_workers: [convergence.worker_count]bool = [_]bool{false} ** convergence.worker_count,
    actions: [convergence.worker_count]?convergence.Action = [_]?convergence.Action{null} ** convergence.worker_count,
    model_calls: usize = 0,
    protocol_actions: usize = 0,
    invalid_actions: usize = 0,
    backend_errors: usize = 0,
    semantic_violations: usize = 0,
    rounds: usize = 0,
    network_messages: usize = 0,
    useful_fact_deliveries: usize = 0,
    duplicate_fact_transmissions: usize = 0,
    completion_tokens: usize = 0,
    generated_bytes: usize = 0,
    latency_us: u64 = 0,
    trajectory_hash: u64 = fnv_offset,
    solved: bool = false,

    fn init(seed: u64, mode: model_eval.DecodeMode) RunAccumulator {
        return .{
            .seed = seed,
            .mode = mode,
            .knowledge = convergence.initialKnowledge(seed),
        };
    }

    fn ingest(self: *RunAccumulator, record: RawRecord, completion: []const u8) !void {
        if (self.solved) return error.RecordAfterSuccess;
        if (record.seed != self.seed or record.mode != self.mode) return error.WrongRun;
        if (record.round != self.current_round) return error.UnexpectedRound;
        if (record.worker == 0 or @as(usize, record.worker) > convergence.worker_count) return error.InvalidWorker;

        const worker_index: usize = @intCast(record.worker - 1);
        if (self.seen_workers[worker_index]) return error.DuplicateWorker;
        if (record.knowledge_before != self.knowledge[worker_index]) return error.KnowledgeMismatch;
        if (record.generation_seed != convergence.generationSeed(record.seed, record.round, record.worker)) {
            return error.GenerationSeedMismatch;
        }

        self.model_calls += 1;
        self.completion_tokens += record.completion_tokens;
        self.latency_us +%= record.latency_us;
        hashByte(&self.trajectory_hash, @intCast(record.round & 0xff));
        hashByte(&self.trajectory_hash, record.worker);
        hashSlice(&self.trajectory_hash, completion);
        hashByte(&self.trajectory_hash, 0xff);

        if (std.mem.eql(u8, completion, backend_error_sentinel)) {
            self.backend_errors += 1;
        } else {
            self.generated_bytes += completion.len;
            const action = convergence.parseAction(completion) catch {
                self.invalid_actions += 1;
                self.seen_workers[worker_index] = true;
                try self.finishRoundIfComplete();
                return;
            };
            self.protocol_actions += 1;
            self.actions[worker_index] = action;
        }

        self.seen_workers[worker_index] = true;
        try self.finishRoundIfComplete();
    }

    fn finishRoundIfComplete(self: *RunAccumulator) !void {
        for (self.seen_workers) |seen| {
            if (!seen) return;
        }

        const round_metrics = convergence.applyRound(&self.knowledge, self.actions);
        self.semantic_violations += round_metrics.semantic_violations;
        self.network_messages += round_metrics.network_messages;
        self.useful_fact_deliveries += round_metrics.useful_fact_deliveries;
        self.duplicate_fact_transmissions += round_metrics.duplicate_fact_transmissions;
        self.rounds += 1;
        self.solved = convergence.collectorSolved(self.knowledge);
        self.current_round += 1;
        self.seen_workers = [_]bool{false} ** convergence.worker_count;
        self.actions = [_]?convergence.Action{null} ** convergence.worker_count;
    }

    fn complete(self: *const RunAccumulator) bool {
        for (self.seen_workers) |seen| {
            if (seen) return false;
        }
        return self.model_calls != 0;
    }
};

pub fn summarizeTsv(tsv: []const u8) Summary {
    var summary = Summary{};
    var active: ?RunAccumulator = null;
    var lines = std.mem.splitScalar(u8, tsv, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        summary.records += 1;
        const record = parseRawLine(line) catch {
            summary.malformed_records += 1;
            continue;
        };

        var completion_buffer: [max_completion_bytes]u8 = undefined;
        const completion = unescapeCompletion(record.escaped_completion, &completion_buffer) catch {
            summary.malformed_records += 1;
            continue;
        };

        if (active == null) {
            active = RunAccumulator.init(record.seed, record.mode);
        } else if (active.?.seed != record.seed or active.?.mode != record.mode) {
            if (active) |*run| {
                finishRun(&summary, run) catch {
                    summary.replay_errors += 1;
                };
            }
            active = RunAccumulator.init(record.seed, record.mode);
        }

        if (active) |*run| {
            run.ingest(record, completion) catch {
                summary.replay_errors += 1;
            };
        }
    }

    if (active) |*run| {
        finishRun(&summary, run) catch {
            summary.replay_errors += 1;
        };
    }

    return summary;
}

fn finishRun(summary: *Summary, run: *RunAccumulator) !void {
    if (!run.complete()) return error.IncompleteRun;

    const metrics = metricsForMode(summary, run.mode);
    const seed_store = seedStoreForMode(summary, run.mode);
    if (containsSeed(seed_store.slice, run.seed)) return error.DuplicateRunSeed;
    if (seed_store.len.* >= max_runs) return error.TooManyRuns;
    seed_store.storage[seed_store.len.*] = run.seed;
    seed_store.len.* += 1;

    metrics.runs += 1;
    if (run.solved) metrics.successes += 1;
    metrics.model_calls += run.model_calls;
    metrics.protocol_actions += run.protocol_actions;
    metrics.invalid_actions += run.invalid_actions;
    metrics.backend_errors += run.backend_errors;
    metrics.semantic_violations += run.semantic_violations;
    metrics.rounds += run.rounds;
    metrics.network_messages += run.network_messages;
    metrics.useful_fact_deliveries += run.useful_fact_deliveries;
    metrics.duplicate_fact_transmissions += run.duplicate_fact_transmissions;
    metrics.completion_tokens += run.completion_tokens;
    metrics.generated_bytes += run.generated_bytes;
    metrics.latency_us +%= run.latency_us;

    if (run.solved) {
        try recordSuccessfulTrajectory(summary, run.mode, run.trajectory_hash);
        metrics.unique_successful_trajectories = successHashCount(summary, run.mode);
    }
}

const SeedStore = struct {
    storage: *[max_runs]u64,
    len: *usize,
    slice: []const u64,
};

fn seedStoreForMode(summary: *Summary, mode: model_eval.DecodeMode) SeedStore {
    return switch (mode) {
        .typed_unconstrained => .{
            .storage = &summary.typed_seeds,
            .len = &summary.typed_seed_count,
            .slice = summary.typed_seeds[0..summary.typed_seed_count],
        },
        .cfg_constrained => .{
            .storage = &summary.constrained_seeds,
            .len = &summary.constrained_seed_count,
            .slice = summary.constrained_seeds[0..summary.constrained_seed_count],
        },
    };
}

fn metricsForMode(summary: *Summary, mode: model_eval.DecodeMode) *ModeMetrics {
    return switch (mode) {
        .typed_unconstrained => &summary.typed,
        .cfg_constrained => &summary.constrained,
    };
}

fn recordSuccessfulTrajectory(summary: *Summary, mode: model_eval.DecodeMode, hash: u64) !void {
    switch (mode) {
        .typed_unconstrained => {
            if (containsHash(summary.typed_success_hashes[0..summary.typed_success_hash_count], hash)) return;
            if (summary.typed_success_hash_count >= max_runs) return error.TooManyRuns;
            summary.typed_success_hashes[summary.typed_success_hash_count] = hash;
            summary.typed_success_hash_count += 1;
        },
        .cfg_constrained => {
            if (containsHash(summary.constrained_success_hashes[0..summary.constrained_success_hash_count], hash)) return;
            if (summary.constrained_success_hash_count >= max_runs) return error.TooManyRuns;
            summary.constrained_success_hashes[summary.constrained_success_hash_count] = hash;
            summary.constrained_success_hash_count += 1;
        },
    }
}

fn successHashCount(summary: *const Summary, mode: model_eval.DecodeMode) usize {
    return switch (mode) {
        .typed_unconstrained => summary.typed_success_hash_count,
        .cfg_constrained => summary.constrained_success_hash_count,
    };
}

fn containsSeed(seeds: []const u64, seed: u64) bool {
    for (seeds) |candidate| {
        if (candidate == seed) return true;
    }
    return false;
}

fn containsHash(hashes: []const u64, hash: u64) bool {
    for (hashes) |candidate| {
        if (candidate == hash) return true;
    }
    return false;
}

fn parseRawLine(line: []const u8) !RawRecord {
    var fields: [9][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, line, '\t');

    while (iterator.next()) |field| {
        if (count >= fields.len) return error.InvalidRecord;
        fields[count] = field;
        count += 1;
    }
    if (count != fields.len) return error.InvalidRecord;
    for (fields[0..8]) |field| {
        if (field.len == 0) return error.InvalidRecord;
    }

    return .{
        .seed = try std.fmt.parseInt(u64, fields[0], 10),
        .mode = try parseMode(fields[1]),
        .round = try std.fmt.parseInt(u32, fields[2], 10),
        .worker = try std.fmt.parseInt(u8, fields[3], 10),
        .knowledge_before = try std.fmt.parseInt(u8, fields[4], 10),
        .generation_seed = try std.fmt.parseInt(u32, fields[5], 10),
        .completion_tokens = try std.fmt.parseInt(usize, fields[6], 10),
        .latency_us = try std.fmt.parseInt(u64, fields[7], 10),
        .escaped_completion = fields[8],
    };
}

fn parseMode(text: []const u8) !model_eval.DecodeMode {
    if (std.mem.eql(u8, text, "typed_unconstrained")) return .typed_unconstrained;
    if (std.mem.eql(u8, text, "cfg_constrained")) return .cfg_constrained;
    return error.UnknownMode;
}

fn unescapeCompletion(input: []const u8, out: *[max_completion_bytes]u8) ![]const u8 {
    var src: usize = 0;
    var dst: usize = 0;

    while (src < input.len) {
        if (dst >= out.len) return error.CompletionTooLarge;

        if (input[src] != '\\') {
            out[dst] = input[src];
            dst += 1;
            src += 1;
            continue;
        }

        src += 1;
        if (src >= input.len) return error.InvalidEscape;
        out[dst] = switch (input[src]) {
            '\\' => '\\',
            't' => '\t',
            'r' => '\r',
            'n' => '\n',
            else => return error.InvalidEscape,
        };
        dst += 1;
        src += 1;
    }

    return out[0..dst];
}

fn hashByte(hash: *u64, byte: u8) void {
    hash.* ^= byte;
    hash.* *%= fnv_prime;
}

fn hashSlice(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| hashByte(hash, byte);
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

    const result = summarizeTsv(tsv);
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Stage 3F.0 Distributed Fact Convergence\n", .{});
    try writeLine(io, out, "records: {d}\n", .{result.records});
    try writeLine(io, out, "malformed_records: {d}\n", .{result.malformed_records});
    try writeLine(io, out, "replay_errors: {d}\n", .{result.replay_errors});
    try writeLine(io, out, "balanced_runs: {s}\n\n", .{if (result.balanced()) "yes" else "no"});

    try writeHeader(io, out);
    try writeMetrics(io, out, "typed_unconstrained", result.typed);
    try writeMetrics(io, out, "cfg_constrained", result.constrained);

    const success_delta =
        @as(i64, @intCast(result.constrained.successRatePermille())) -
        @as(i64, @intCast(result.typed.successRatePermille()));
    const validity_delta =
        @as(i64, @intCast(result.constrained.protocolValidityPermille())) -
        @as(i64, @intCast(result.typed.protocolValidityPermille()));
    const message_delta =
        @as(i64, @intCast(result.constrained.network_messages)) -
        @as(i64, @intCast(result.typed.network_messages));

    try writeLine(
        io,
        out,
        "\ndeltas (constrained - typed): success={d} permille, protocol_validity={d} permille, network_messages={d}\n",
        .{ success_delta, validity_delta, message_delta },
    );

    if (result.malformed_records != 0 or result.replay_errors != 0 or !result.balanced()) {
        try writeLine(
            io,
            out,
            "\nWARNING: malformed, unreplayable, or unbalanced experiment data; do not use this file for a CFG decision.\n",
            .{},
        );
        std.process.exit(2);
    }
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage: zig run src/stage3f0_summary.zig -- <trials.tsv>\n",
    );
}

fn writeHeader(io: std.Io, out: std.Io.File) !void {
    try out.writeStreamingAll(
        io,
        "mode\truns\tsuccess\tprotocol-valid\tinvalid\tbackend\tsem-viol\tavg-rounds\tmessages\tuseful\tduplicate\tuseful/msg\ttokens\tbytes\tavg-latency-us\tunique-success-trajectories\n",
    );
}

fn writeMetrics(io: std.Io, out: std.Io.File, name: []const u8, metrics: ModeMetrics) !void {
    const avg_latency = if (metrics.model_calls == 0) 0 else metrics.latency_us / metrics.model_calls;
    const avg_rounds = metrics.averageRoundsPermille();
    const useful_ratio = metrics.usefulFactsPerMessagePermille();

    try writeLine(
        io,
        out,
        "{s}\t{d}\t{d}.{d}%\t{d}.{d}%\t{d}\t{d}\t{d}\t{d}.{d}\t{d}\t{d}\t{d}\t{d}.{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            name,
            metrics.runs,
            metrics.successRatePermille() / 10,
            metrics.successRatePermille() % 10,
            metrics.protocolValidityPermille() / 10,
            metrics.protocolValidityPermille() % 10,
            metrics.invalid_actions,
            metrics.backend_errors,
            metrics.semantic_violations,
            avg_rounds / 1000,
            (avg_rounds % 1000) / 100,
            metrics.network_messages,
            metrics.useful_fact_deliveries,
            metrics.duplicate_fact_transmissions,
            useful_ratio / 1000,
            (useful_ratio % 1000) / 100,
            metrics.completion_tokens,
            metrics.generated_bytes,
            avg_latency,
            metrics.unique_successful_trajectories,
        },
    );
}

fn writeLine(io: std.Io, out: std.Io.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [2048]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "summary replays two distinct successful controlled-emergence trajectories" {
    const tsv =
        "0\ttyped_unconstrained\t1\t1\t3\t102\t2\t100\tCLAIM A,B\n" ++
        "0\ttyped_unconstrained\t1\t2\t6\t103\t2\t100\tCLAIM B,C\n" ++
        "0\ttyped_unconstrained\t1\t3\t12\t104\t2\t100\tCLAIM C,D\n" ++
        "0\ttyped_unconstrained\t1\t4\t24\t105\t2\t100\tCLAIM D,E\n" ++
        "0\ttyped_unconstrained\t1\t5\t17\t106\t2\t100\tCLAIM A,E\n" ++
        "0\ttyped_unconstrained\t2\t1\t23\t203\t3\t100\tQUERY EVIDENCE D\n" ++
        "0\ttyped_unconstrained\t2\t2\t15\t204\t2\t100\tCLAIM D\n" ++
        "0\ttyped_unconstrained\t2\t3\t30\t205\t2\t100\tCLAIM C\n" ++
        "0\ttyped_unconstrained\t2\t4\t29\t206\t2\t100\tCLAIM D\n" ++
        "0\ttyped_unconstrained\t2\t5\t27\t207\t2\t100\tCLAIM E\n" ++
        "0\tcfg_constrained\t1\t1\t3\t102\t2\t100\tCLAIM A,B\n" ++
        "0\tcfg_constrained\t1\t2\t6\t103\t2\t100\tCLAIM B,C\n" ++
        "0\tcfg_constrained\t1\t3\t12\t104\t2\t100\tCLAIM C,D\n" ++
        "0\tcfg_constrained\t1\t4\t24\t105\t2\t100\tCLAIM D,E\n" ++
        "0\tcfg_constrained\t1\t5\t17\t106\t2\t100\tCLAIM A,E\n" ++
        "0\tcfg_constrained\t2\t1\t23\t203\t2\t100\tCLAIM A,B,C,E\n" ++
        "0\tcfg_constrained\t2\t2\t15\t204\t2\t100\tCLAIM D\n" ++
        "0\tcfg_constrained\t2\t3\t30\t205\t2\t100\tCLAIM C\n" ++
        "0\tcfg_constrained\t2\t4\t29\t206\t2\t100\tCLAIM D\n" ++
        "0\tcfg_constrained\t2\t5\t27\t207\t2\t100\tCLAIM E\n";

    const result = summarizeTsv(tsv);
    try std.testing.expectEqual(@as(usize, 20), result.records);
    try std.testing.expectEqual(@as(usize, 0), result.malformed_records);
    try std.testing.expectEqual(@as(usize, 0), result.replay_errors);
    try std.testing.expect(result.balanced());
    try std.testing.expectEqual(@as(usize, 1), result.typed.successes);
    try std.testing.expectEqual(@as(usize, 1), result.constrained.successes);
    try std.testing.expectEqual(@as(usize, 10), result.typed.protocol_actions);
    try std.testing.expectEqual(@as(usize, 10), result.constrained.protocol_actions);
    try std.testing.expectEqual(@as(usize, 22), result.typed.network_messages);
    try std.testing.expectEqual(@as(usize, 20), result.constrained.network_messages);
    try std.testing.expectEqual(@as(usize, 1), result.typed.unique_successful_trajectories);
    try std.testing.expectEqual(@as(usize, 1), result.constrained.unique_successful_trajectories);
}

test "replay rejects a record whose prompt knowledge does not match deterministic state" {
    var run = RunAccumulator.init(0, .typed_unconstrained);
    const record = RawRecord{
        .seed = 0,
        .mode = .typed_unconstrained,
        .round = 1,
        .worker = 1,
        .knowledge_before = 31,
        .generation_seed = convergence.generationSeed(0, 1, 1),
        .completion_tokens = 2,
        .latency_us = 100,
        .escaped_completion = "CLAIM A",
    };

    try std.testing.expectError(
        error.KnowledgeMismatch,
        run.ingest(record, "CLAIM A"),
    );
}

test "empty completion is a protocol-invalid model action, not malformed data" {
    const line = "0\ttyped_unconstrained\t1\t1\t3\t102\t0\t100\t";
    const record = try parseRawLine(line);
    try std.testing.expectEqual(@as(usize, 0), record.escaped_completion.len);
}
