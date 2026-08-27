const std = @import("std");
const message = @import("message.zig");
const protocol_trace = @import("protocol_trace.zig");

/// Stage 3C candidate grammar:
///
/// Session      ::= Interaction | Interaction Session
/// Interaction  ::= ClaimBatch
///                | OBSERVE CLAIM
///                | QUERY EVIDENCE
///                | PROPOSE Decision
///                | CHALLENGE RETRACT
///                | DELEGATE QUERY EVIDENCE EVIDENCE
/// ClaimBatch   ::= CLAIM | CLAIM ClaimBatch
/// Decision     ::= ACCEPT | REJECT
///
/// This is intentionally the smallest grammar justified by the Stage 3A/3B
/// corpus. It is a CFG candidate, not yet required architecture.
pub const Production = enum(u8) {
    claim_batch,
    observe_claim,
    query_evidence,
    propose_accept,
    propose_reject,
    challenge_retract,
    delegation,
};

pub const max_productions: usize = 64;
pub const max_run_events: usize = 64;

pub const Parse = struct {
    productions: [max_productions]Production = undefined,
    spans: [max_productions]u8 = undefined,
    len: usize = 0,
    terminals: usize = 0,

    fn append(self: *Parse, production: Production, span: usize) !void {
        if (self.len >= max_productions) return error.TooManyProductions;
        if (span == 0 or span > max_run_events) return error.InvalidSequence;
        self.productions[self.len] = production;
        self.spans[self.len] = @intCast(span);
        self.len += 1;
        self.terminals += span;
    }
};

pub const Benchmark = struct {
    runs: usize = 0,
    parsed_runs: usize = 0,
    rejected_runs: usize = 0,
    canonical_bytes: usize = 0,
    framed_typed_bytes: usize = 0,
    cfg_bytes: usize = 0,
    cfg_smaller_runs: usize = 0,
    cfg_equal_runs: usize = 0,
    cfg_larger_runs: usize = 0,
    malformed_cases: usize = 0,
    malformed_rejected: usize = 0,

    pub fn cfgSavingsBytes(self: Benchmark) usize {
        if (self.cfg_bytes >= self.framed_typed_bytes) return 0;
        return self.framed_typed_bytes - self.cfg_bytes;
    }

    pub fn cfgSavingsPermille(self: Benchmark) usize {
        if (self.framed_typed_bytes == 0 or self.cfg_bytes >= self.framed_typed_bytes) return 0;
        return ((self.framed_typed_bytes - self.cfg_bytes) * 1000) / self.framed_typed_bytes;
    }
};

pub fn parseKinds(kinds: []const message.Kind) !Parse {
    if (kinds.len == 0) return error.InvalidSequence;

    var result = Parse{};
    var i: usize = 0;
    while (i < kinds.len) {
        switch (kinds[i]) {
            .claim => {
                var end = i + 1;
                while (end < kinds.len and kinds[end] == .claim) : (end += 1) {}
                try result.append(.claim_batch, end - i);
                i = end;
            },
            .observe => {
                if (!matches(kinds, i, &.{ .observe, .claim })) return error.InvalidSequence;
                try result.append(.observe_claim, 2);
                i += 2;
            },
            .query => {
                if (!matches(kinds, i, &.{ .query, .evidence })) return error.InvalidSequence;
                try result.append(.query_evidence, 2);
                i += 2;
            },
            .propose => {
                if (i + 1 >= kinds.len) return error.InvalidSequence;
                switch (kinds[i + 1]) {
                    .accept => try result.append(.propose_accept, 2),
                    .reject => try result.append(.propose_reject, 2),
                    else => return error.InvalidSequence,
                }
                i += 2;
            },
            .challenge => {
                if (!matches(kinds, i, &.{ .challenge, .retract })) return error.InvalidSequence;
                try result.append(.challenge_retract, 2);
                i += 2;
            },
            .delegate => {
                if (!matches(kinds, i, &.{ .delegate, .query, .evidence, .evidence })) {
                    return error.InvalidSequence;
                }
                try result.append(.delegation, 4);
                i += 4;
            },
            .evidence, .accept, .reject, .retract => return error.InvalidSequence,
        }
    }

    if (result.terminals != kinds.len) return error.InvalidSequence;
    return result;
}

fn matches(kinds: []const message.Kind, start: usize, expected: []const message.Kind) bool {
    if (start + expected.len > kinds.len) return false;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (kinds[start + i] != expected[i]) return false;
    }
    return true;
}

/// A fair typed baseline with one run-level version/count header. Message kinds
/// remain explicit, while the per-message version byte is removed.
pub fn framedTypedRunSize(events: []const protocol_trace.CorpusEvent) usize {
    if (events.len == 0) return 0;
    var bytes: usize = 2; // version:u8 | message_count:u8
    for (events) |event| {
        bytes += protocol_trace.canonicalMessageSize(event.trace.message) - 1;
    }
    return bytes;
}

/// CFG representation:
/// version:u8 | production_count:u8 | production tags | claim-batch counts |
/// per-message metadata with both version and kind omitted.
///
/// Terminal kinds are reconstructed from grammar productions. ClaimBatch needs
/// one span byte because its recursive CLAIM count is variable.
pub fn cfgRunSize(events: []const protocol_trace.CorpusEvent, parsed: Parse) usize {
    if (events.len == 0) return 0;

    var bytes: usize = 2; // version:u8 | production_count:u8
    var p: usize = 0;
    while (p < parsed.len) : (p += 1) {
        bytes += 1; // production tag
        if (parsed.productions[p] == .claim_batch) bytes += 1; // recursive span
    }

    for (events) |event| {
        bytes += protocol_trace.canonicalMessageSize(event.trace.message) - 2;
    }
    return bytes;
}

pub fn benchmarkCorpus(corpus: *const protocol_trace.Corpus) !Benchmark {
    var result = Benchmark{};
    var kinds: [max_run_events]message.Kind = undefined;

    var start: usize = 0;
    while (start < corpus.len) {
        const run_id = corpus.events[start].run_id;
        var end = start;
        while (end < corpus.len and corpus.events[end].run_id == run_id) : (end += 1) {}

        const run_len = end - start;
        if (run_len == 0 or run_len > max_run_events) return error.RunTooLarge;

        var i: usize = 0;
        while (i < run_len) : (i += 1) {
            kinds[i] = corpus.events[start + i].trace.message.kind;
        }

        result.runs += 1;
        const run_events = corpus.events[start..end];

        var canonical: usize = 0;
        for (run_events) |event| {
            canonical += protocol_trace.canonicalMessageSize(event.trace.message);
        }
        const framed = framedTypedRunSize(run_events);

        result.canonical_bytes += canonical;
        result.framed_typed_bytes += framed;

        const parsed = parseKinds(kinds[0..run_len]) catch {
            result.rejected_runs += 1;
            start = end;
            continue;
        };

        result.parsed_runs += 1;
        const cfg_bytes = cfgRunSize(run_events, parsed);
        result.cfg_bytes += cfg_bytes;

        if (cfg_bytes < framed) {
            result.cfg_smaller_runs += 1;
        } else if (cfg_bytes == framed) {
            result.cfg_equal_runs += 1;
        } else {
            result.cfg_larger_runs += 1;
        }

        start = end;
    }

    const malformed = [_][]const message.Kind{
        &.{ .observe, .evidence },
        &.{ .query, .claim },
        &.{ .propose, .retract },
        &.{ .challenge, .accept },
        &.{ .delegate, .query, .evidence },
        &.{.accept},
        &.{ .delegate, .evidence },
        &.{ .observe, .claim, .reject },
    };

    result.malformed_cases = malformed.len;
    for (malformed) |sequence| {
        _ = parseKinds(sequence) catch {
            result.malformed_rejected += 1;
            continue;
        };
    }

    return result;
}

test "cfg accepts every stage 3b workflow family" {
    const valid = [_][]const message.Kind{
        &.{ .observe, .claim },
        &.{ .query, .evidence },
        &.{ .propose, .accept },
        &.{ .propose, .reject },
        &.{ .challenge, .retract },
        &.{ .delegate, .query, .evidence, .evidence },
        &.{ .claim, .claim, .claim, .claim, .claim },
    };

    for (valid) |sequence| {
        const parsed = try parseKinds(sequence);
        try std.testing.expectEqual(sequence.len, parsed.terminals);
        try std.testing.expect(parsed.len > 0);
    }
}

test "cfg composes multiple interactions in one session" {
    const sequence = [_]message.Kind{
        .observe, .claim,
        .query, .evidence,
        .propose, .accept,
        .challenge, .retract,
    };
    const parsed = try parseKinds(&sequence);
    try std.testing.expectEqual(@as(usize, 4), parsed.len);
    try std.testing.expectEqual(sequence.len, parsed.terminals);
}

test "cfg rejects malformed protocol compositions" {
    const invalid = [_][]const message.Kind{
        &.{ .observe, .evidence },
        &.{ .query, .reject },
        &.{ .propose, .evidence },
        &.{ .challenge, .claim },
        &.{ .delegate, .query, .evidence },
        &.{.retract},
    };

    for (invalid) |sequence| {
        try std.testing.expectError(error.InvalidSequence, parseKinds(sequence));
    }
}

test "stage 3c benchmark parses full expanded corpus and beats framed typed encoding" {
    const corpus = try protocol_trace.buildExpandedCorpus(1000, 8);
    const result = try benchmarkCorpus(&corpus);

    try std.testing.expectEqual(result.runs, result.parsed_runs);
    try std.testing.expectEqual(@as(usize, 0), result.rejected_runs);
    try std.testing.expect(result.canonical_bytes > result.framed_typed_bytes);
    try std.testing.expect(result.framed_typed_bytes > result.cfg_bytes);
    try std.testing.expect(result.cfgSavingsBytes() > 0);
    try std.testing.expect(result.cfgSavingsPermille() > 0);
    try std.testing.expectEqual(result.malformed_cases, result.malformed_rejected);
    try std.testing.expectEqual(@as(usize, 0), result.cfg_larger_runs);
}
