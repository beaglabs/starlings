const std = @import("std");
const content_id = @import("../core/content_id.zig");
const core = @import("core_types.zig");
const output_state = @import("output_state.zig");

pub const canonical_event_version: u8 = 1;

pub const EventKind = enum(u8) {
    observation_added = 1,
    operator_started = 2,
    claim_accepted = 3,
    invariant_changed = 4,
    operator_completed = 5,
    operator_failed = 6,
};

pub const ObservationAdded = struct {
    round: u32,
    claim: core.Claim,
    claim_id: core.ContentId,
};

pub const OperatorStarted = struct {
    round: u32,
    operator: core.OperatorId,
    activation_epoch: u64,
    input_fingerprint: core.ContentId,
};

pub const ClaimAccepted = struct {
    round: u32,
    claim: core.Claim,
    claim_id: core.ContentId,
};

pub const InvariantChanged = struct {
    round: u32,
    claim: core.InvariantClaim,
};

pub const OperatorCompleted = struct {
    round: u32,
    operator: core.OperatorId,
    activation_epoch: u64,
    variable_claims: u16,
    invariant_claims: u16,
    actions: u16,
};

pub const FailureKind = enum(u8) {
    execution,
    validation,
};

pub const OperatorFailed = struct {
    round: u32,
    operator: core.OperatorId,
    activation_epoch: u64,
    kind: FailureKind,
    rejected_claims: u16 = 0,
};

pub const RunEvent = union(EventKind) {
    observation_added: ObservationAdded,
    operator_started: OperatorStarted,
    claim_accepted: ClaimAccepted,
    invariant_changed: InvariantChanged,
    operator_completed: OperatorCompleted,
    operator_failed: OperatorFailed,
};

pub const EventRecord = struct {
    sequence: u64,
    previous: core.ContentId,
    id: core.ContentId,
    event: RunEvent,
};

pub fn EventLog(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        records: [capacity]EventRecord = undefined,
        len: usize = 0,

        pub fn ensureCapacity(self: *const Self, additional: usize) !void {
            if (additional > capacity - self.len) return error.EventCapacityExceeded;
        }

        pub fn append(self: *Self, event: RunEvent) !core.ContentId {
            try self.ensureCapacity(1);
            try validateEvent(event);

            const previous = if (self.len == 0)
                content_id.zero
            else
                self.records[self.len - 1].id;
            const sequence: u64 = @intCast(self.len);
            const id = eventContentId(sequence, previous, event);

            self.records[self.len] = .{
                .sequence = sequence,
                .previous = previous,
                .id = id,
                .event = event,
            };
            self.len += 1;
            return id;
        }

        pub fn slice(self: *const Self) []const EventRecord {
            return self.records[0..self.len];
        }

        pub fn headId(self: *const Self) core.ContentId {
            if (self.len == 0) return content_id.zero;
            return self.records[self.len - 1].id;
        }

        pub fn validate(self: *const Self) !void {
            try validateRecords(self.slice());
        }
    };
}

pub fn validateRecords(records: []const EventRecord) !void {
    var previous = content_id.zero;

    for (records, 0..) |record, i| {
        if (record.sequence != @as(u64, @intCast(i))) return error.EventSequenceMismatch;
        if (!content_id.eql(record.previous, previous)) return error.EventParentMismatch;
        try validateEvent(record.event);

        const expected = eventContentId(record.sequence, record.previous, record.event);
        if (!content_id.eql(expected, record.id)) return error.EventIdMismatch;

        previous = record.id;
    }
}

pub fn eventContentId(
    sequence: u64,
    previous: core.ContentId,
    event: RunEvent,
) core.ContentId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("starlings-sdk-run-event-v1");
    hasher.update(&.{canonical_event_version});
    hashU64(&hasher, sequence);
    hasher.update(&previous);

    const kind = std.meta.activeTag(event);
    hasher.update(&.{@intFromEnum(kind)});

    switch (event) {
        .observation_added => |payload| {
            hashU32(&hasher, payload.round);
            hashClaimPayload(&hasher, payload.claim, payload.claim_id);
        },
        .operator_started => |payload| {
            hashU32(&hasher, payload.round);
            hashU32(&hasher, payload.operator);
            hashU64(&hasher, payload.activation_epoch);
            hasher.update(&payload.input_fingerprint);
        },
        .claim_accepted => |payload| {
            hashU32(&hasher, payload.round);
            hashClaimPayload(&hasher, payload.claim, payload.claim_id);
        },
        .invariant_changed => |payload| {
            hashU32(&hasher, payload.round);
            hashInvariantClaim(&hasher, payload.claim);
        },
        .operator_completed => |payload| {
            hashU32(&hasher, payload.round);
            hashU32(&hasher, payload.operator);
            hashU64(&hasher, payload.activation_epoch);
            hashU16(&hasher, payload.variable_claims);
            hashU16(&hasher, payload.invariant_claims);
            hashU16(&hasher, payload.actions);
        },
        .operator_failed => |payload| {
            hashU32(&hasher, payload.round);
            hashU32(&hasher, payload.operator);
            hashU64(&hasher, payload.activation_epoch);
            hasher.update(&.{@intFromEnum(payload.kind)});
            hashU16(&hasher, payload.rejected_claims);
        },
    }

    var digest: core.ContentId = undefined;
    hasher.final(&digest);
    return digest;
}

fn validateEvent(event: RunEvent) !void {
    switch (event) {
        .observation_added => |payload| {
            try validateClaimIdentity(payload.claim, payload.claim_id);
            if (payload.claim.source_operator != 0) return error.InvalidObservationSource;
        },
        .operator_started => |payload| {
            if (payload.operator == 0) return error.InvalidOperatorId;
            if (payload.activation_epoch == 0) return error.InvalidActivationEpoch;
        },
        .claim_accepted => |payload| {
            try validateClaimIdentity(payload.claim, payload.claim_id);
            if (payload.claim.source_operator == 0) return error.InvalidOperatorClaimSource;
        },
        .invariant_changed => |payload| {
            if (payload.claim.source_operator == 0) return error.InvalidOperatorClaimSource;
            if (@as(usize, payload.claim.parent_count) > core.max_claim_parents) {
                return error.TooManyParents;
            }
        },
        .operator_completed => |payload| {
            if (payload.operator == 0) return error.InvalidOperatorId;
            if (payload.activation_epoch == 0) return error.InvalidActivationEpoch;
        },
        .operator_failed => |payload| {
            if (payload.operator == 0) return error.InvalidOperatorId;
            if (payload.activation_epoch == 0) return error.InvalidActivationEpoch;
        },
    }
}

fn validateClaimIdentity(claim: core.Claim, id: core.ContentId) !void {
    try claim.validateShape();
    const expected = output_state.claimContentId(claim);
    if (!content_id.eql(expected, id)) return error.ClaimIdentityMismatch;
}

fn hashClaimPayload(
    hasher: *std.crypto.hash.Blake3,
    claim: core.Claim,
    id: core.ContentId,
) void {
    _ = claim;
    hasher.update(&id);
}

fn hashInvariantClaim(
    hasher: *std.crypto.hash.Blake3,
    claim: core.InvariantClaim,
) void {
    hashU32(hasher, claim.invariant);
    hasher.update(&.{@intFromEnum(claim.status)});
    hashU32(hasher, claim.source_operator);
    hasher.update(&.{@intCast(claim.parent_count)});

    var i: usize = 0;
    while (i < claim.parent_count) : (i += 1) {
        hasher.update(&claim.parents[i]);
    }
}

fn hashU16(hasher: *std.crypto.hash.Blake3, value: u16) void {
    var bytes: [2]u8 = undefined;
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    hasher.update(&bytes);
}

fn hashU32(hasher: *std.crypto.hash.Blake3, value: u32) void {
    var bytes: [4]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const shift: u5 = @intCast(i * 8);
        bytes[i] = @truncate(value >> shift);
    }
    hasher.update(&bytes);
}

fn hashU64(hasher: *std.crypto.hash.Blake3, value: u64) void {
    var bytes: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        bytes[i] = @truncate(value >> shift);
    }
    hasher.update(&bytes);
}

test "event log forms a canonical append-only hash chain" {
    const L = EventLog(8);
    var log = L{};

    const observation: core.Claim = .{
        .variable = 1,
        .status = .observed,
        .value = .{ .integer = 7 },
        .source_operator = 0,
    };
    const observation_id = output_state.claimContentId(observation);

    _ = try log.append(.{ .observation_added = .{
        .round = 0,
        .claim = observation,
        .claim_id = observation_id,
    } });
    _ = try log.append(.{ .operator_started = .{
        .round = 1,
        .operator = 10,
        .activation_epoch = 1,
        .input_fingerprint = content_id.zero,
    } });

    try log.validate();
    try std.testing.expectEqual(@as(usize, 2), log.len);
    try std.testing.expect(!content_id.isZero(log.headId()));
    try std.testing.expect(content_id.eql(log.records[1].previous, log.records[0].id));
}

test "event log validation detects tampering" {
    const L = EventLog(4);
    var log = L{};

    _ = try log.append(.{ .operator_started = .{
        .round = 1,
        .operator = 10,
        .activation_epoch = 1,
        .input_fingerprint = content_id.zero,
    } });

    var tampered = log;
    tampered.records[0].id[0] ^= 0xff;

    try std.testing.expectError(error.EventIdMismatch, tampered.validate());
}
