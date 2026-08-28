const std = @import("std");
const convergence = @import("distributed_fact_convergence.zig");
const model_eval = @import("../../protocol/protocol_model_eval.zig");

pub const backend_error_sentinel = "__BACKEND_ERROR__";
pub const max_completion_bytes: usize = 4096;
const max_runs: usize = 256;
const max_invalid_examples: usize = 128;
const max_invalid_completion_bytes: usize = 256;
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

pub const RunKey = struct {
    environment_seed: u64,
    sampling_seed: u64,
};

pub const RunResult = struct {
    key: RunKey,
    mode: model_eval.DecodeMode,
    success: bool,
    model_calls: usize,
    protocol_actions: usize,
    invalid_actions: usize,
    backend_errors: usize,
    semantic_violations: usize,
    rounds: usize,
    network_messages: usize,
    useful_fact_deliveries: usize,
    duplicate_fact_transmissions: usize,
    completion_tokens: usize,
    generated_bytes: usize,
    latency_us: u64,
    trajectory_hash: u64,

    pub fn protocolValidityPermille(self: RunResult) usize {
        if (self.model_calls == 0) return 0;
        return (self.protocol_actions * 1000) / self.model_calls;
    }
};

pub const InvalidExample = struct {
    key: RunKey,
    mode: model_eval.DecodeMode,
    round: u32,
    worker: u8,
    escaped_completion: [max_invalid_completion_bytes]u8 = [_]u8{0} ** max_invalid_completion_bytes,
    completion_len: usize = 0,
};

pub const Summary = struct {
    typed: ModeMetrics = .{},
    constrained: ModeMetrics = .{},
    records: usize = 0,
    malformed_records: usize = 0,
    replay_errors: usize = 0,
    runs: [max_runs]RunResult = undefined,
    run_count: usize = 0,
    invalid_examples: [max_invalid_examples]InvalidExample = undefined,
    invalid_example_count: usize = 0,

    pub fn balanced(self: *const Summary) bool {
        var typed_count: usize = 0;
        var constrained_count: usize = 0;

        for (self.runs[0..self.run_count]) |run| {
            switch (run.mode) {
                .typed_unconstrained => {
                    typed_count += 1;
                    if (findRun(self, run.key, .cfg_constrained) == null) return false;
                },
                .cfg_constrained => {
                    constrained_count += 1;
                    if (findRun(self, run.key, .typed_unconstrained) == null) return false;
                },
            }
        }

        return typed_count == constrained_count;
    }

    fn recordInvalid(self: *Summary, record: RawRecord) void {
        if (self.invalid_example_count >= max_invalid_examples) return;

        var example = InvalidExample{
            .key = record.key,
            .mode = record.mode,
            .round = record.round,
            .worker = record.worker,
        };
        const copy_len = @min(record.escaped_completion.len, max_invalid_completion_bytes);
        std.mem.copyForwards(
            u8,
            example.escaped_completion[0..copy_len],
            record.escaped_completion[0..copy_len],
        );
        example.completion_len = copy_len;
        self.invalid_examples[self.invalid_example_count] = example;
        self.invalid_example_count += 1;
    }
};

const RawRecord = struct {
    key: RunKey,
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
    key: RunKey,
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

    fn init(key: RunKey, mode: model_eval.DecodeMode) RunAccumulator {
        return .{
            .key = key,
            .mode = mode,
            .knowledge = convergence.initialKnowledge(key.environment_seed),
        };
    }

    fn ingest(
        self: *RunAccumulator,
        summary: *Summary,
        record: RawRecord,
        completion: []const u8,
    ) !void {
        if (self.solved) return error.RecordAfterSuccess;
        if (!keyEql(record.key, self.key) or record.mode != self.mode) return error.WrongRun;
        if (record.round != self.current_round) return error.UnexpectedRound;
        if (record.worker == 0 or @as(usize, record.worker) > convergence.worker_count) {
            return error.InvalidWorker;
        }

        const worker_index: usize = @intCast(record.worker - 1);
        if (self.seen_workers[worker_index]) return error.DuplicateWorker;
        if (record.knowledge_before != self.knowledge[worker_index]) return error.KnowledgeMismatch;
        if (record.generation_seed != convergence.generationSeed(
            record.key.sampling_seed,
            record.round,
            record.worker,
        )) {
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
                summary.recordInvalid(record);
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

    fn result(self: *const RunAccumulator) RunResult {
        return .{
            .key = self.key,
            .mode = self.mode,
            .success = self.solved,
            .model_calls = self.model_calls,
            .protocol_actions = self.protocol_actions,
            .invalid_actions = self.invalid_actions,
            .backend_errors = self.backend_errors,
            .semantic_violations = self.semantic_violations,
            .rounds = self.rounds,
            .network_messages = self.network_messages,
            .useful_fact_deliveries = self.useful_fact_deliveries,
            .duplicate_fact_transmissions = self.duplicate_fact_transmissions,
            .completion_tokens = self.completion_tokens,
            .generated_bytes = self.generated_bytes,
            .latency_us = self.latency_us,
            .trajectory_hash = self.trajectory_hash,
        };
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
            active = RunAccumulator.init(record.key, record.mode);
        } else if (!keyEql(active.?.key, record.key) or active.?.mode != record.mode) {
            if (active) |*run| {
                finishRun(&summary, run) catch {
                    summary.replay_errors += 1;
                };
            }
            active = RunAccumulator.init(record.key, record.mode);
        }

        if (active) |*run| {
            run.ingest(&summary, record, completion) catch {
                summary.replay_errors += 1;
            };
        }
    }

    if (active) |*run| {
        finishRun(&summary, run) catch {
            summary.replay_errors += 1;
        };
    }

    summary.typed.unique_successful_trajectories =
        countUniqueSuccessfulTrajectories(&summary, .typed_unconstrained, null);
    summary.constrained.unique_successful_trajectories =
        countUniqueSuccessfulTrajectories(&summary, .cfg_constrained, null);

    return summary;
}

fn finishRun(summary: *Summary, run: *RunAccumulator) !void {
    if (!run.complete()) return error.IncompleteRun;
    if (summary.run_count >= max_runs) return error.TooManyRuns;
    if (findRun(summary, run.key, run.mode) != null) return error.DuplicateRun;

    const run_result = run.result();
    summary.runs[summary.run_count] = run_result;
    summary.run_count += 1;

    const metrics = metricsForMode(summary, run.mode);
    metrics.runs += 1;
    if (run_result.success) metrics.successes += 1;
    metrics.model_calls += run_result.model_calls;
    metrics.protocol_actions += run_result.protocol_actions;
    metrics.invalid_actions += run_result.invalid_actions;
    metrics.backend_errors += run_result.backend_errors;
    metrics.semantic_violations += run_result.semantic_violations;
    metrics.rounds += run_result.rounds;
    metrics.network_messages += run_result.network_messages;
    metrics.useful_fact_deliveries += run_result.useful_fact_deliveries;
    metrics.duplicate_fact_transmissions += run_result.duplicate_fact_transmissions;
    metrics.completion_tokens += run_result.completion_tokens;
    metrics.generated_bytes += run_result.generated_bytes;
    metrics.latency_us +%= run_result.latency_us;
}

fn metricsForMode(summary: *Summary, mode: model_eval.DecodeMode) *ModeMetrics {
    return switch (mode) {
        .typed_unconstrained => &summary.typed,
        .cfg_constrained => &summary.constrained,
    };
}

fn findRun(
    summary: *const Summary,
    key: RunKey,
    mode: model_eval.DecodeMode,
) ?*const RunResult {
    for (summary.runs[0..summary.run_count]) |*run| {
        if (run.mode == mode and keyEql(run.key, key)) return run;
    }
    return null;
}

fn keyEql(a: RunKey, b: RunKey) bool {
    return a.environment_seed == b.environment_seed and
        a.sampling_seed == b.sampling_seed;
}

fn countUniqueSuccessfulTrajectories(
    summary: *const Summary,
    mode: model_eval.DecodeMode,
    environment_seed: ?u64,
) usize {
    var hashes: [max_runs]u64 = undefined;
    var count: usize = 0;

    for (summary.runs[0..summary.run_count]) |run| {
        if (run.mode != mode or !run.success) continue;
        if (environment_seed != null and run.key.environment_seed != environment_seed.?) continue;

        var seen = false;
        for (hashes[0..count]) |hash| {
            if (hash == run.trajectory_hash) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            hashes[count] = run.trajectory_hash;
            count += 1;
        }
    }

    return count;
}

fn countSuccessfulRuns(
    summary: *const Summary,
    mode: model_eval.DecodeMode,
    environment_seed: u64,
) usize {
    var count: usize = 0;
    for (summary.runs[0..summary.run_count]) |run| {
        if (run.mode == mode and
            run.success and
            run.key.environment_seed == environment_seed)
        {
            count += 1;
        }
    }
    return count;
}

fn parseRawLine(line: []const u8) !RawRecord {
    var fields: [10][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.splitScalar(u8, line, '\t');

    while (iterator.next()) |field| {
        if (count >= fields.len) return error.InvalidRecord;
        fields[count] = field;
        count += 1;
    }
    if (count != fields.len) return error.InvalidRecord;
    for (fields[0..9]) |field| {
        if (field.len == 0) return error.InvalidRecord;
    }

    return .{
        .key = .{
            .environment_seed = try std.fmt.parseInt(u64, fields[0], 10),
            .sampling_seed = try std.fmt.parseInt(u64, fields[1], 10),
        },
        .mode = try parseMode(fields[2]),
        .round = try std.fmt.parseInt(u32, fields[3], 10),
        .worker = try std.fmt.parseInt(u8, fields[4], 10),
        .knowledge_before = try std.fmt.parseInt(u8, fields[5], 10),
        .generation_seed = try std.fmt.parseInt(u32, fields[6], 10),
        .completion_tokens = try std.fmt.parseInt(usize, fields[7], 10),
        .latency_us = try std.fmt.parseInt(u64, fields[8], 10),
        .escaped_completion = fields[9],
    };
}

fn parseMode(text: []const u8) !model_eval.DecodeMode {
    if (std.mem.eql(u8, text, "typed_unconstrained")) return .typed_unconstrained;
    if (std.mem.eql(u8, text, "cfg_constrained")) return .cfg_constrained;
    return error.UnknownMode;
}

fn modeName(mode: model_eval.DecodeMode) []const u8 {
    return switch (mode) {
        .typed_unconstrained => "typed_unconstrained",
        .cfg_constrained => "cfg_constrained",
    };
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

    try writeLine(io, out, "Stage 3F.0 Distributed Fact Convergence v2\n", .{});
    try writeLine(io, out, "records: {d}\n", .{result.records});
    try writeLine(io, out, "population_runs: {d}\n", .{result.run_count});
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

    try writePairs(io, out, &result);
    try writeEnvironmentDiversity(io, out, &result);
    try writeInvalidExamples(io, out, &result);

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
        "usage: zig run src/stage3f0_summary.zig -- <trials-v2.tsv>\n",
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

fn writePairs(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try out.writeStreamingAll(
        io,
        "\npaired runs\nenv\tsampling\ttyped-success\tcfg-success\ttyped-rounds\tcfg-rounds\ttyped-valid\tcfg-valid\ttyped-msg\tcfg-msg\ttyped-tokens\tcfg-tokens\ttyped-bytes\tcfg-bytes\n",
    );

    for (summary.runs[0..summary.run_count]) |typed| {
        if (typed.mode != .typed_unconstrained) continue;
        const constrained = findRun(summary, typed.key, .cfg_constrained) orelse continue;

        try writeLine(
            io,
            out,
            "{d}\t{d}\t{s}\t{s}\t{d}\t{d}\t{d}.{d}%\t{d}.{d}%\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                typed.key.environment_seed,
                typed.key.sampling_seed,
                if (typed.success) "yes" else "no",
                if (constrained.success) "yes" else "no",
                typed.rounds,
                constrained.rounds,
                typed.protocolValidityPermille() / 10,
                typed.protocolValidityPermille() % 10,
                constrained.protocolValidityPermille() / 10,
                constrained.protocolValidityPermille() % 10,
                typed.network_messages,
                constrained.network_messages,
                typed.completion_tokens,
                constrained.completion_tokens,
                typed.generated_bytes,
                constrained.generated_bytes,
            },
        );
    }
}

fn writeEnvironmentDiversity(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try out.writeStreamingAll(
        io,
        "\ntrajectory diversity by environment\nenv\ttyped-success-runs\ttyped-unique\tcfg-success-runs\tcfg-unique\n",
    );

    var seen_environments: [max_runs]u64 = undefined;
    var seen_count: usize = 0;

    for (summary.runs[0..summary.run_count]) |run| {
        var already_seen = false;
        for (seen_environments[0..seen_count]) |environment_seed| {
            if (environment_seed == run.key.environment_seed) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) continue;

        seen_environments[seen_count] = run.key.environment_seed;
        seen_count += 1;

        try writeLine(
            io,
            out,
            "{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                run.key.environment_seed,
                countSuccessfulRuns(summary, .typed_unconstrained, run.key.environment_seed),
                countUniqueSuccessfulTrajectories(summary, .typed_unconstrained, run.key.environment_seed),
                countSuccessfulRuns(summary, .cfg_constrained, run.key.environment_seed),
                countUniqueSuccessfulTrajectories(summary, .cfg_constrained, run.key.environment_seed),
            },
        );
    }
}

fn writeInvalidExamples(io: std.Io, out: std.Io.File, summary: *const Summary) !void {
    try writeLine(
        io,
        out,
        "\ninvalid completion examples: {d}\n",
        .{summary.invalid_example_count},
    );
    if (summary.invalid_example_count == 0) return;

    try out.writeStreamingAll(
        io,
        "env\tsampling\tmode\tround\tworker\tcompletion\n",
    );

    for (summary.invalid_examples[0..summary.invalid_example_count]) |example| {
        const completion = if (example.completion_len == 0)
            "<empty>"
        else
            example.escaped_completion[0..example.completion_len];

        try writeLine(
            io,
            out,
            "{d}\t{d}\t{s}\t{d}\t{d}\t{s}\n",
            .{
                example.key.environment_seed,
                example.key.sampling_seed,
                modeName(example.mode),
                example.round,
                example.worker,
                completion,
            },
        );
    }
}

fn writeLine(io: std.Io, out: std.Io.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "summary pairs environment and sampling seeds and measures same-state diversity" {
    const tsv =
        "0\t0\ttyped_unconstrained\t1\t1\t3\t102\t2\t100\tCLAIM A,B\n" ++
        "0\t0\ttyped_unconstrained\t1\t2\t6\t103\t2\t100\tCLAIM B,C\n" ++
        "0\t0\ttyped_unconstrained\t1\t3\t12\t104\t2\t100\tCLAIM C,D\n" ++
        "0\t0\ttyped_unconstrained\t1\t4\t24\t105\t2\t100\tCLAIM D,E\n" ++
        "0\t0\ttyped_unconstrained\t1\t5\t17\t106\t2\t100\tCLAIM A,E\n" ++
        "0\t0\ttyped_unconstrained\t2\t1\t23\t203\t3\t100\tQUERY EVIDENCE D\n" ++
        "0\t0\ttyped_unconstrained\t2\t2\t15\t204\t2\t100\tCLAIM D\n" ++
        "0\t0\ttyped_unconstrained\t2\t3\t30\t205\t2\t100\tCLAIM C\n" ++
        "0\t0\ttyped_unconstrained\t2\t4\t29\t206\t2\t100\tCLAIM D\n" ++
        "0\t0\ttyped_unconstrained\t2\t5\t27\t207\t2\t100\tCLAIM E\n" ++
        "0\t0\tcfg_constrained\t1\t1\t3\t102\t2\t100\tCLAIM A,B\n" ++
        "0\t0\tcfg_constrained\t1\t2\t6\t103\t2\t100\tCLAIM B,C\n" ++
        "0\t0\tcfg_constrained\t1\t3\t12\t104\t2\t100\tCLAIM C,D\n" ++
        "0\t0\tcfg_constrained\t1\t4\t24\t105\t2\t100\tCLAIM D,E\n" ++
        "0\t0\tcfg_constrained\t1\t5\t17\t106\t2\t100\tCLAIM A,E\n" ++
        "0\t0\tcfg_constrained\t2\t1\t23\t203\t2\t100\tCLAIM A,B,C,E\n" ++
        "0\t0\tcfg_constrained\t2\t2\t15\t204\t2\t100\tCLAIM D\n" ++
        "0\t0\tcfg_constrained\t2\t3\t30\t205\t2\t100\tCLAIM C\n" ++
        "0\t0\tcfg_constrained\t2\t4\t29\t206\t2\t100\tCLAIM D\n" ++
        "0\t0\tcfg_constrained\t2\t5\t27\t207\t2\t100\tCLAIM E\n";

    const result = summarizeTsv(tsv);
    try std.testing.expectEqual(@as(usize, 20), result.records);
    try std.testing.expectEqual(@as(usize, 2), result.run_count);
    try std.testing.expectEqual(@as(usize, 0), result.malformed_records);
    try std.testing.expectEqual(@as(usize, 0), result.replay_errors);
    try std.testing.expect(result.balanced());
    try std.testing.expectEqual(@as(usize, 1), result.typed.successes);
    try std.testing.expectEqual(@as(usize, 1), result.constrained.successes);
    try std.testing.expectEqual(@as(usize, 1), countUniqueSuccessfulTrajectories(
        &result,
        .typed_unconstrained,
        0,
    ));
}

test "sampling seed is independently verified during replay" {
    var summary = Summary{};
    var run = RunAccumulator.init(.{
        .environment_seed = 0,
        .sampling_seed = 7,
    }, .typed_unconstrained);
    const record = RawRecord{
        .key = .{ .environment_seed = 0, .sampling_seed = 7 },
        .mode = .typed_unconstrained,
        .round = 1,
        .worker = 1,
        .knowledge_before = 3,
        .generation_seed = convergence.generationSeed(8, 1, 1),
        .completion_tokens = 2,
        .latency_us = 100,
        .escaped_completion = "CLAIM A",
    };

    try std.testing.expectError(
        error.GenerationSeedMismatch,
        run.ingest(&summary, record, "CLAIM A"),
    );
}

test "invalid completion is retained for diagnostics" {
    var summary = Summary{};
    var run = RunAccumulator.init(.{
        .environment_seed = 0,
        .sampling_seed = 0,
    }, .typed_unconstrained);
    const record = RawRecord{
        .key = .{ .environment_seed = 0, .sampling_seed = 0 },
        .mode = .typed_unconstrained,
        .round = 1,
        .worker = 1,
        .knowledge_before = 3,
        .generation_seed = convergence.generationSeed(0, 1, 1),
        .completion_tokens = 3,
        .latency_us = 100,
        .escaped_completion = "I think CLAIM A",
    };

    try run.ingest(&summary, record, "I think CLAIM A");
    try std.testing.expectEqual(@as(usize, 1), run.invalid_actions);
    try std.testing.expectEqual(@as(usize, 1), summary.invalid_example_count);
}

test "empty completion remains a protocol-invalid record, not malformed TSV" {
    const line = "0\t0\ttyped_unconstrained\t1\t1\t3\t102\t0\t100\t";
    const record = try parseRawLine(line);
    try std.testing.expectEqual(@as(usize, 0), record.escaped_completion.len);
}


test "same environment can contain multiple successful sampling trajectories" {
    var summary = Summary{};
    summary.runs[0] = .{
        .key = .{ .environment_seed = 2, .sampling_seed = 10 },
        .mode = .typed_unconstrained,
        .success = true,
        .model_calls = 10,
        .protocol_actions = 10,
        .invalid_actions = 0,
        .backend_errors = 0,
        .semantic_violations = 0,
        .rounds = 2,
        .network_messages = 20,
        .useful_fact_deliveries = 8,
        .duplicate_fact_transmissions = 10,
        .completion_tokens = 30,
        .generated_bytes = 60,
        .latency_us = 1000,
        .trajectory_hash = 111,
    };
    summary.runs[1] = summary.runs[0];
    summary.runs[1].key.sampling_seed = 11;
    summary.runs[1].trajectory_hash = 222;
    summary.runs[2] = summary.runs[0];
    summary.runs[2].key.environment_seed = 3;
    summary.runs[2].key.sampling_seed = 10;
    summary.runs[2].trajectory_hash = 333;
    summary.run_count = 3;

    try std.testing.expectEqual(
        @as(usize, 2),
        countUniqueSuccessfulTrajectories(&summary, .typed_unconstrained, 2),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countUniqueSuccessfulTrajectories(&summary, .typed_unconstrained, 3),
    );
}
