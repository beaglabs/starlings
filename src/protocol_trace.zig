const std = @import("std");
const benchmark = @import("benchmark.zig");
const message = @import("message.zig");
const runtime = @import("runtime.zig");

pub const max_corpus_records: usize = 4096;
const kind_count: usize = @typeInfo(message.Kind).@"enum".fields.len;
const shape_count: usize = kind_count * 2;
const transition_count: usize = kind_count * kind_count;

pub const Record = struct {
    strategy: benchmark.Strategy,
    task: benchmark.TaskShape,
    seed: u64,
    event: runtime.TraceEvent,
};

pub const Corpus = struct {
    records: [max_corpus_records]Record = undefined,
    len: usize = 0,
    runs: usize = 0,
    successful_runs: usize = 0,

    pub fn append(self: *Corpus, record: Record) !void {
        if (self.len >= self.records.len) return error.CorpusCapacityExceeded;
        self.records[self.len] = record;
        self.len += 1;
    }
};

pub const Analysis = struct {
    runs: usize,
    successful_runs: usize,
    events: usize,
    kind_counts: [kind_count]usize,
    unique_kinds: usize,
    unique_shapes: usize,
    repeated_shape_events: usize,
    messages_with_causal_refs: usize,
    unique_kind_transitions: usize,
    abi_bytes: usize,
    canonical_bytes: usize,

    pub fn canonicalSavings(self: Analysis) usize {
        return self.abi_bytes - self.canonical_bytes;
    }

    pub fn protocolDiversityPermille(self: Analysis) usize {
        if (kind_count == 0) return 0;
        return (self.unique_kinds * 1000) / kind_count;
    }
};

pub fn buildCorpus(first_seed: u64, seeds_per_case: usize) !Corpus {
    var corpus = Corpus{};
    const strategies = [_]benchmark.Strategy{ .broadcast_all, .centralized, .point_to_point };
    const tasks = [_]benchmark.TaskShape{ .partitioned, .overlapping };

    for (strategies) |strategy| {
        for (tasks) |task| {
            var seed_offset: usize = 0;
            while (seed_offset < seeds_per_case) : (seed_offset += 1) {
                const seed = first_seed + seed_offset;
                const result = try benchmark.run(strategy, .{ .seed = seed, .task = task });
                corpus.runs += 1;
                if (result.metrics.success) corpus.successful_runs += 1;

                var i: usize = 0;
                while (i < result.trace_len) : (i += 1) {
                    try corpus.append(.{
                        .strategy = strategy,
                        .task = task,
                        .seed = seed,
                        .event = result.trace[i].?,
                    });
                }
            }
        }
    }

    return corpus;
}

pub fn analyze(corpus: *const Corpus) Analysis {
    var counts = [_]usize{0} ** kind_count;
    var shapes = [_]bool{false} ** shape_count;
    var transitions = [_]bool{false} ** transition_count;
    var causal_refs: usize = 0;
    var canonical_bytes: usize = 0;

    var previous_kind: ?message.Kind = null;
    var previous_run_strategy: ?benchmark.Strategy = null;
    var previous_run_task: ?benchmark.TaskShape = null;
    var previous_run_seed: ?u64 = null;

    var i: usize = 0;
    while (i < corpus.len) : (i += 1) {
        const record = corpus.records[i];
        const msg = record.event.message;
        const kind_index: usize = @intFromEnum(msg.kind);
        counts[kind_index] += 1;

        const has_causal = msg.causal_ref != null;
        if (has_causal) causal_refs += 1;
        const shape_index = kind_index * 2 + @as(usize, if (has_causal) 1 else 0);
        shapes[shape_index] = true;
        canonical_bytes += canonicalMessageSize(msg);

        const same_run = previous_run_strategy != null and
            previous_run_strategy.? == record.strategy and
            previous_run_task.? == record.task and
            previous_run_seed.? == record.seed;
        if (same_run and previous_kind != null) {
            const from: usize = @intFromEnum(previous_kind.?);
            transitions[from * kind_count + kind_index] = true;
        }

        previous_kind = msg.kind;
        previous_run_strategy = record.strategy;
        previous_run_task = record.task;
        previous_run_seed = record.seed;
    }

    var unique_kinds: usize = 0;
    for (counts) |count| if (count > 0) {
        unique_kinds += 1;
    };

    var unique_shapes: usize = 0;
    for (shapes) |present| if (present) {
        unique_shapes += 1;
    };

    var unique_transitions: usize = 0;
    for (transitions) |present| if (present) {
        unique_transitions += 1;
    };

    return .{
        .runs = corpus.runs,
        .successful_runs = corpus.successful_runs,
        .events = corpus.len,
        .kind_counts = counts,
        .unique_kinds = unique_kinds,
        .unique_shapes = unique_shapes,
        .repeated_shape_events = corpus.len - unique_shapes,
        .messages_with_causal_refs = causal_refs,
        .unique_kind_transitions = unique_transitions,
        .abi_bytes = corpus.len * @sizeOf(message.Message),
        .canonical_bytes = canonical_bytes,
    };
}

/// Versioned compact baseline for protocol-message representation. This is not
/// yet the CFG encoding. It provides a deterministic lower-complexity baseline:
/// version:u8 | sender:u32-le | recipient:u32-le | kind:u8 | payload:u64-le |
/// causal-present:u8 | causal-id?:32 bytes | logical-clock:u64-le.
pub fn canonicalMessageSize(msg: message.Message) usize {
    const fixed = 1 + 4 + 4 + 1 + 8 + 1 + 8;
    return fixed + if (msg.causal_ref != null) 32 else 0;
}

test "stage 3a corpus is deterministic and covers all trusted baselines" {
    const a = try buildCorpus(100, 4);
    const b = try buildCorpus(100, 4);
    try std.testing.expectEqual(@as(usize, 24), a.runs);
    try std.testing.expectEqual(a.runs, a.successful_runs);
    try std.testing.expectEqual(a.len, b.len);

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        try std.testing.expectEqualDeep(a.records[i], b.records[i]);
    }
}

test "current trusted corpus exposes insufficient kind diversity for CFG promotion" {
    const corpus = try buildCorpus(0, 2);
    const analysis = analyze(&corpus);
    try std.testing.expectEqual(@as(usize, 12), analysis.runs);
    try std.testing.expectEqual(analysis.runs, analysis.successful_runs);
    try std.testing.expectEqual(@as(usize, 1), analysis.unique_kinds);
    try std.testing.expectEqual(@as(usize, 1), analysis.unique_shapes);
    try std.testing.expectEqual(@as(usize, 1), analysis.unique_kind_transitions);
    try std.testing.expectEqual(@as(usize, 0), analysis.messages_with_causal_refs);
    try std.testing.expect(analysis.repeated_shape_events > 0);
}

test "compact canonical baseline is smaller than in-memory message ABI" {
    const corpus = try buildCorpus(500, 2);
    const analysis = analyze(&corpus);
    try std.testing.expect(analysis.canonical_bytes < analysis.abi_bytes);
    try std.testing.expect(analysis.canonicalSavings() > 0);
}
