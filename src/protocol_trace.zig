const std = @import("std");
const benchmark = @import("benchmark.zig");
const message = @import("message.zig");
const runtime = @import("runtime.zig");

pub const max_events: usize = 4096;

pub const CorpusEvent = struct {
    strategy: benchmark.Strategy,
    task: benchmark.TaskShape,
    seed: u64,
    trace: runtime.TraceEvent,
};

pub const Corpus = struct {
    events: [max_events]CorpusEvent = undefined,
    len: usize = 0,
    runs: usize = 0,
    successful_runs: usize = 0,

    pub fn append(self: *Corpus, event: CorpusEvent) !void {
        if (self.len >= max_events) return error.CorpusCapacityExceeded;
        self.events[self.len] = event;
        self.len += 1;
    }
};

pub const Analysis = struct {
    total_events: usize,
    kind_counts: [kind_count]usize,
    observed_kinds: usize,
    unique_shapes: usize,
    repeated_shape_events: usize,
    messages_with_causal_refs: usize,
    unique_kind_transitions: usize,
    abi_bytes: usize,
    canonical_bytes: usize,
};

const kind_count: usize = @typeInfo(message.Kind).@"enum".fields.len;
const shape_capacity: usize = 128;
const transition_capacity: usize = kind_count * kind_count;

const Shape = struct {
    kind: message.Kind,
    has_payload: bool,
    has_causal_ref: bool,
};

pub fn buildCorpus(first_seed: u64, seeds: usize) !Corpus {
    var corpus = Corpus{};

    var seed_offset: usize = 0;
    while (seed_offset < seeds) : (seed_offset += 1) {
        const seed = first_seed + seed_offset;
        inline for (.{ benchmark.TaskShape.partitioned, benchmark.TaskShape.overlapping }) |task| {
            inline for (.{ benchmark.Strategy.broadcast_all, benchmark.Strategy.centralized, benchmark.Strategy.point_to_point }) |strategy| {
                const result = try benchmark.run(strategy, .{ .seed = seed, .task = task });
                corpus.runs += 1;
                if (result.metrics.success) corpus.successful_runs += 1;

                var i: usize = 0;
                while (i < result.trace_len) : (i += 1) {
                    try corpus.append(.{
                        .strategy = strategy,
                        .task = task,
                        .seed = seed,
                        .trace = result.trace[i].?,
                    });
                }
            }
        }
    }

    return corpus;
}

pub fn analyze(corpus: *const Corpus) Analysis {
    var kind_counts = [_]usize{0} ** kind_count;
    var shapes: [shape_capacity]Shape = undefined;
    var unique_shapes: usize = 0;
    var causal_refs: usize = 0;
    var transition_seen = [_]bool{false} ** transition_capacity;
    var unique_transitions: usize = 0;
    var canonical_bytes: usize = 0;

    var previous_kind: ?message.Kind = null;
    var i: usize = 0;
    while (i < corpus.len) : (i += 1) {
        const msg = corpus.events[i].trace.message;
        const kind_index: usize = @intFromEnum(msg.kind);
        kind_counts[kind_index] += 1;
        if (msg.causal_ref != null) causal_refs += 1;
        canonical_bytes += canonicalMessageSize(msg);

        const shape = Shape{
            .kind = msg.kind,
            .has_payload = msg.payload != 0,
            .has_causal_ref = msg.causal_ref != null,
        };
        if (!containsShape(shapes[0..unique_shapes], shape)) {
            if (unique_shapes < shape_capacity) {
                shapes[unique_shapes] = shape;
                unique_shapes += 1;
            }
        }

        if (previous_kind) |prev| {
            const transition_index = @intFromEnum(prev) * kind_count + kind_index;
            if (!transition_seen[transition_index]) {
                transition_seen[transition_index] = true;
                unique_transitions += 1;
            }
        }
        previous_kind = msg.kind;
    }

    var observed_kinds: usize = 0;
    for (kind_counts) |count| {
        if (count > 0) observed_kinds += 1;
    }

    return .{
        .total_events = corpus.len,
        .kind_counts = kind_counts,
        .observed_kinds = observed_kinds,
        .unique_shapes = unique_shapes,
        .repeated_shape_events = corpus.len - unique_shapes,
        .messages_with_causal_refs = causal_refs,
        .unique_kind_transitions = unique_transitions,
        .abi_bytes = corpus.len * @sizeOf(message.Message),
        .canonical_bytes = canonical_bytes,
    };
}

fn containsShape(shapes: []const Shape, candidate: Shape) bool {
    for (shapes) |shape| {
        if (shape.kind == candidate.kind and
            shape.has_payload == candidate.has_payload and
            shape.has_causal_ref == candidate.has_causal_ref)
        {
            return true;
        }
    }
    return false;
}

/// Versioned compact baseline for protocol-message representation. This is not
/// yet the CFG encoding. It provides a deterministic lower-complexity baseline:
/// version:u8 | sender:u32-le | recipient:u32-le | kind:u8 | payload:u64-le |
/// causal-present:u8 | causal-id?:32 bytes | logical-clock:u64-le.
pub fn canonicalMessageSize(msg: message.Message) usize {
    const fixed: usize = 1 + 4 + 4 + 1 + 8 + 1 + 8;
    const causal_bytes: usize = if (msg.causal_ref != null) 32 else 0;
    return fixed + causal_bytes;
}

test "stage 3a corpus is deterministic and covers all trusted baselines" {
    const a = try buildCorpus(100, 4);
    const b = try buildCorpus(100, 4);
    try std.testing.expectEqual(@as(usize, 24), a.runs);
    try std.testing.expectEqual(a.runs, a.successful_runs);
    try std.testing.expectEqual(a.len, b.len);

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        try std.testing.expectEqualDeep(a.events[i], b.events[i]);
    }
}

test "current trusted corpus exposes insufficient kind diversity for CFG promotion" {
    const corpus = try buildCorpus(200, 8);
    const analysis = analyze(&corpus);
    try std.testing.expect(analysis.total_events > 0);
    try std.testing.expectEqual(@as(usize, 1), analysis.observed_kinds);
    try std.testing.expectEqual(corpus.len, analysis.kind_counts[@intFromEnum(message.Kind.claim)]);
    try std.testing.expect(analysis.repeated_shape_events > 0);
}

test "compact canonical representation is no larger than ABI representation" {
    const corpus = try buildCorpus(300, 4);
    const analysis = analyze(&corpus);
    try std.testing.expect(analysis.canonical_bytes <= analysis.abi_bytes);
}
