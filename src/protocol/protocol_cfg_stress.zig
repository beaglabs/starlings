const std = @import("std");
const message = @import("../core/message.zig");
const protocol_cfg = @import("protocol_cfg.zig");
const rng_mod = @import("../core/rng.zig");

pub const max_events: usize = protocol_cfg.max_run_events;
const production_count: usize = @typeInfo(protocol_cfg.Production).@"enum".fields.len;

pub const Session = struct {
    kinds: [max_events]message.Kind = undefined,
    len: usize = 0,
    last_start: usize = 0,
    last_production: protocol_cfg.Production = .observe_claim,

    fn appendKind(self: *Session, kind: message.Kind) !void {
        if (self.len >= max_events) return error.SessionTooLarge;
        self.kinds[self.len] = kind;
        self.len += 1;
    }
};

pub const StressStats = struct {
    sessions: usize = 0,
    accepted_sessions: usize = 0,
    roundtrip_sessions: usize = 0,
    typed_kind_bytes: usize = 0,
    cfg_structure_bytes: usize = 0,
    positive_savings_sessions: usize = 0,
    equal_savings_sessions: usize = 0,
    negative_savings_sessions: usize = 0,
    min_savings_bytes: i64 = 0,
    max_savings_bytes: i64 = 0,
    mutations: usize = 0,
    mutations_rejected: usize = 0,

    pub fn totalSavingsBytes(self: StressStats) i64 {
        return @as(i64, @intCast(self.typed_kind_bytes)) -
            @as(i64, @intCast(self.cfg_structure_bytes));
    }

    pub fn savingsPermille(self: StressStats) usize {
        if (self.typed_kind_bytes == 0 or self.cfg_structure_bytes >= self.typed_kind_bytes) return 0;
        return ((self.typed_kind_bytes - self.cfg_structure_bytes) * 1000) / self.typed_kind_bytes;
    }
};

pub fn generateSession(seed: u64) !Session {
    var rng = rng_mod.Rng.init(seed ^ 0x535441524c494e47 ^ 0x3344);
    var session = Session{};

    // Always compose at least two interactions. The final interaction is kept
    // non-ClaimBatch so truncation and order-swap mutations are guaranteed
    // invalid independently of the parser under test.
    const prefix_target = 1 + rng.bounded(15);
    var i: usize = 0;
    while (i < prefix_target) : (i += 1) {
        const production: protocol_cfg.Production = @enumFromInt(rng.bounded(production_count));
        const claim_span = 1 + rng.bounded(8);
        const needed = productionSpan(production, claim_span);

        // Reserve four terminals for the longest final production plus one
        // slot for append/prepend mutation tests.
        if (session.len + needed + 5 > max_events) break;
        try appendProduction(&session, production, claim_span);
    }

    const final_production: protocol_cfg.Production = @enumFromInt(1 + rng.bounded(production_count - 1));
    session.last_start = session.len;
    session.last_production = final_production;
    try appendProduction(&session, final_production, 1);

    return session;
}

fn productionSpan(production: protocol_cfg.Production, claim_span: usize) usize {
    return switch (production) {
        .claim_batch => claim_span,
        .observe_claim,
        .query_evidence,
        .propose_accept,
        .propose_reject,
        .challenge_retract,
        => 2,
        .delegation => 4,
    };
}

fn appendProduction(session: *Session, production: protocol_cfg.Production, claim_span: usize) !void {
    switch (production) {
        .claim_batch => {
            if (claim_span == 0) return error.InvalidClaimSpan;
            var i: usize = 0;
            while (i < claim_span) : (i += 1) try session.appendKind(.claim);
        },
        .observe_claim => {
            try session.appendKind(.observe);
            try session.appendKind(.claim);
        },
        .query_evidence => {
            try session.appendKind(.query);
            try session.appendKind(.evidence);
        },
        .propose_accept => {
            try session.appendKind(.propose);
            try session.appendKind(.accept);
        },
        .propose_reject => {
            try session.appendKind(.propose);
            try session.appendKind(.reject);
        },
        .challenge_retract => {
            try session.appendKind(.challenge);
            try session.appendKind(.retract);
        },
        .delegation => {
            try session.appendKind(.delegate);
            try session.appendKind(.query);
            try session.appendKind(.evidence);
            try session.appendKind(.evidence);
        },
    }
}

pub fn reconstruct(parsed: protocol_cfg.Parse, out: *[max_events]message.Kind) !usize {
    var len: usize = 0;
    var p: usize = 0;
    while (p < parsed.len) : (p += 1) {
        const production = parsed.productions[p];
        const span: usize = parsed.spans[p];

        switch (production) {
            .claim_batch => {
                if (span == 0) return error.InvalidParse;
                var i: usize = 0;
                while (i < span) : (i += 1) try appendOutput(out, &len, .claim);
            },
            .observe_claim => {
                if (span != 2) return error.InvalidParse;
                try appendOutput(out, &len, .observe);
                try appendOutput(out, &len, .claim);
            },
            .query_evidence => {
                if (span != 2) return error.InvalidParse;
                try appendOutput(out, &len, .query);
                try appendOutput(out, &len, .evidence);
            },
            .propose_accept => {
                if (span != 2) return error.InvalidParse;
                try appendOutput(out, &len, .propose);
                try appendOutput(out, &len, .accept);
            },
            .propose_reject => {
                if (span != 2) return error.InvalidParse;
                try appendOutput(out, &len, .propose);
                try appendOutput(out, &len, .reject);
            },
            .challenge_retract => {
                if (span != 2) return error.InvalidParse;
                try appendOutput(out, &len, .challenge);
                try appendOutput(out, &len, .retract);
            },
            .delegation => {
                if (span != 4) return error.InvalidParse;
                try appendOutput(out, &len, .delegate);
                try appendOutput(out, &len, .query);
                try appendOutput(out, &len, .evidence);
                try appendOutput(out, &len, .evidence);
            },
        }
    }
    return len;
}

fn appendOutput(out: *[max_events]message.Kind, len: *usize, kind: message.Kind) !void {
    if (len.* >= max_events) return error.SessionTooLarge;
    out[len.*] = kind;
    len.* += 1;
}

fn cfgStructureBytes(parsed: protocol_cfg.Parse) usize {
    var bytes = parsed.len;
    var i: usize = 0;
    while (i < parsed.len) : (i += 1) {
        if (parsed.productions[i] == .claim_batch) bytes += 1;
    }
    return bytes;
}

fn isRejected(kinds: []const message.Kind) bool {
    _ = protocol_cfg.parseKinds(kinds) catch return true;
    return false;
}

fn exerciseMutations(session: Session, stats: *StressStats) !void {
    var mutated: [max_events]message.Kind = undefined;

    // 1. Append an orphan response terminal.
    std.mem.copyForwards(message.Kind, mutated[0..session.len], session.kinds[0..session.len]);
    mutated[session.len] = .accept;
    stats.mutations += 1;
    if (isRejected(mutated[0 .. session.len + 1])) stats.mutations_rejected += 1;

    // 2. Prepend an orphan response terminal.
    mutated[0] = .reject;
    std.mem.copyForwards(message.Kind, mutated[1 .. session.len + 1], session.kinds[0..session.len]);
    stats.mutations += 1;
    if (isRejected(mutated[0 .. session.len + 1])) stats.mutations_rejected += 1;

    // 3. Delete the required final terminal. The generator guarantees that the
    // final interaction is not ClaimBatch, so this always creates an incomplete
    // production rather than a shorter valid claim batch.
    std.mem.copyForwards(message.Kind, mutated[0 .. session.len - 1], session.kinds[0 .. session.len - 1]);
    stats.mutations += 1;
    if (isRejected(mutated[0 .. session.len - 1])) stats.mutations_rejected += 1;

    // 4. Swap the first two terminals of the final non-ClaimBatch production.
    std.mem.copyForwards(message.Kind, mutated[0..session.len], session.kinds[0..session.len]);
    const a = session.last_start;
    const tmp = mutated[a];
    mutated[a] = mutated[a + 1];
    mutated[a + 1] = tmp;
    stats.mutations += 1;
    if (isRejected(mutated[0..session.len])) stats.mutations_rejected += 1;
}

pub fn runStress(first_seed: u64, sessions: usize) !StressStats {
    var stats = StressStats{};
    var s: usize = 0;

    while (s < sessions) : (s += 1) {
        const session = try generateSession(first_seed + s);
        stats.sessions += 1;

        const parsed = protocol_cfg.parseKinds(session.kinds[0..session.len]) catch {
            try exerciseMutations(session, &stats);
            continue;
        };
        stats.accepted_sessions += 1;

        var reconstructed: [max_events]message.Kind = undefined;
        const reconstructed_len = try reconstruct(parsed, &reconstructed);
        if (reconstructed_len == session.len and
            std.mem.eql(message.Kind, reconstructed[0..reconstructed_len], session.kinds[0..session.len]))
        {
            stats.roundtrip_sessions += 1;
        }

        const typed_bytes = session.len;
        const cfg_bytes = cfgStructureBytes(parsed);
        stats.typed_kind_bytes += typed_bytes;
        stats.cfg_structure_bytes += cfg_bytes;

        const savings = @as(i64, @intCast(typed_bytes)) - @as(i64, @intCast(cfg_bytes));
        if (s == 0 or savings < stats.min_savings_bytes) stats.min_savings_bytes = savings;
        if (s == 0 or savings > stats.max_savings_bytes) stats.max_savings_bytes = savings;

        if (savings > 0) {
            stats.positive_savings_sessions += 1;
        } else if (savings == 0) {
            stats.equal_savings_sessions += 1;
        } else {
            stats.negative_savings_sessions += 1;
        }

        try exerciseMutations(session, &stats);
    }

    return stats;
}

test "all three-interaction production combinations parse and round-trip" {
    var combinations: usize = 0;
    var a: usize = 0;
    while (a < production_count) : (a += 1) {
        var b: usize = 0;
        while (b < production_count) : (b += 1) {
            var c: usize = 0;
            while (c < production_count) : (c += 1) {
                var session = Session{};
                const pa: protocol_cfg.Production = @enumFromInt(a);
                const pb: protocol_cfg.Production = @enumFromInt(b);
                const pc: protocol_cfg.Production = @enumFromInt(c);

                try appendProduction(&session, pa, 3);
                try appendProduction(&session, pb, 4);
                try appendProduction(&session, pc, 5);

                const parsed = try protocol_cfg.parseKinds(session.kinds[0..session.len]);
                var reconstructed: [max_events]message.Kind = undefined;
                const len = try reconstruct(parsed, &reconstructed);

                try std.testing.expectEqual(session.len, len);
                try std.testing.expect(std.mem.eql(
                    message.Kind,
                    session.kinds[0..session.len],
                    reconstructed[0..len],
                ));
                combinations += 1;
            }
        }
    }

    try std.testing.expectEqual(production_count * production_count * production_count, combinations);
}

test "seeded stress accepts unseen valid sessions and rejects guaranteed-invalid mutations" {
    const stats = try runStress(0xC0FFEE, 512);

    try std.testing.expectEqual(stats.sessions, stats.accepted_sessions);
    try std.testing.expectEqual(stats.sessions, stats.roundtrip_sessions);
    try std.testing.expectEqual(stats.mutations, stats.mutations_rejected);
    try std.testing.expectEqual(@as(usize, 512 * 4), stats.mutations);
}

test "cfg savings remain positive in aggregate across unseen compositions" {
    const stats = try runStress(0x51A7_1E55, 1024);

    try std.testing.expect(stats.totalSavingsBytes() > 0);
    try std.testing.expect(stats.savingsPermille() > 0);
    try std.testing.expect(stats.positive_savings_sessions > stats.negative_savings_sessions);
    try std.testing.expect(stats.max_savings_bytes > 0);
}
