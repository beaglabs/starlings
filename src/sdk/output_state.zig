const std = @import("std");
const content_id = @import("../core/content_id.zig");
const core = @import("core_types.zig");
const reg = @import("registry.zig");

pub const canonical_claim_version: u8 = 1;
pub const canonical_artifact_version: u8 = 1;

pub const ClaimRecord = struct {
    id: core.ContentId,
    claim: core.Claim,
};

pub fn ClaimStore(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        records: [capacity]ClaimRecord = undefined,
        len: usize = 0,

        pub fn append(self: *Self, claim: core.Claim) !core.ContentId {
            try claim.validateShape();
            const id = claimContentId(claim);
            if (self.find(id) != null) return id;
            if (self.len >= capacity) return error.ClaimCapacityExceeded;
            self.records[self.len] = .{ .id = id, .claim = claim };
            self.len += 1;
            return id;
        }

        pub fn find(self: *const Self, id: core.ContentId) ?usize {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (content_id.eql(self.records[i].id, id)) return i;
            }
            return null;
        }
    };
}

pub const MaterializedCell = struct {
    status: core.EpistemicStatus = .unknown,
    value: ?core.Value = null,
    claim_id: core.ContentId = content_id.zero,
    confidence_permille: u16 = 0,
    accepted_claims: usize = 0,
    conflict_count: usize = 0,

    pub fn isConflicting(self: MaterializedCell) bool {
        return self.status == .conflicting or self.conflict_count > 0;
    }
};

pub fn MaterializedState(comptime max_variables: usize) type {
    return struct {
        const Self = @This();

        cells: [max_variables]MaterializedCell = [_]MaterializedCell{.{}} ** max_variables,

        pub fn applyClaim(
            self: *Self,
            registry: anytype,
            context_state: anytype,
            claim: core.Claim,
            claim_id: core.ContentId,
            round: u32,
        ) !void {
            const index = registry.variableIndex(claim.variable) orelse return error.UnknownVariable;
            if (index >= max_variables) return error.RegistryCapacityExceeded;
            const schema = registry.variables[index];
            const current = self.cells[index];

            switch (schema.variable.merge_policy) {
                .latest => {
                    self.cells[index] = fromClaim(claim, claim_id, current.accepted_claims + 1, current.conflict_count);
                },
                .highest_confidence => {
                    if (current.accepted_claims == 0 or
                        claim.confidence_permille > current.confidence_permille or
                        (claim.confidence_permille == current.confidence_permille and lessId(claim_id, current.claim_id)))
                    {
                        self.cells[index] = fromClaim(claim, claim_id, current.accepted_claims + 1, current.conflict_count);
                    } else {
                        self.cells[index].accepted_claims += 1;
                    }
                },
                .retain_all_conflict => {
                    if (current.accepted_claims == 0) {
                        self.cells[index] = fromClaim(claim, claim_id, 1, 0);
                    } else if (sameClaimValue(current, claim)) {
                        self.cells[index].accepted_claims += 1;
                        if (claim.confidence_permille > self.cells[index].confidence_permille) {
                            self.cells[index].confidence_permille = claim.confidence_permille;
                        }
                    } else {
                        self.cells[index].status = .conflicting;
                        self.cells[index].value = null;
                        self.cells[index].accepted_claims += 1;
                        self.cells[index].conflict_count += 1;
                    }
                },
            }

            const resolved_cell = self.cells[index];
            try context_state.setVariable(
                registry,
                claim.variable,
                resolved_cell.status,
                resolved_cell.value,
                round,
            );
        }

        pub fn cell(self: *const Self, registry: anytype, id: core.VariableId) ?MaterializedCell {
            const index = registry.variableIndex(id) orelse return null;
            if (index >= max_variables) return null;
            return self.cells[index];
        }
    };
}

fn fromClaim(
    claim: core.Claim,
    claim_id: core.ContentId,
    accepted_claims: usize,
    conflict_count: usize,
) MaterializedCell {
    return .{
        .status = claim.status,
        .value = claim.value,
        .claim_id = claim_id,
        .confidence_permille = claim.confidence_permille,
        .accepted_claims = accepted_claims,
        .conflict_count = conflict_count,
    };
}

fn sameClaimValue(current: MaterializedCell, claim: core.Claim) bool {
    if (current.status != claim.status) return false;
    if ((current.value == null) != (claim.value == null)) return false;
    if (current.value) |a| {
        return core.Value.eql(a, claim.value.?);
    }
    return true;
}

fn lessId(a: core.ContentId, b: core.ContentId) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

pub fn validateOutput(registry: anytype, manifest: core.OperatorManifest, output: *const core.OperatorOutput) !void {
    for (output.claims()) |claim| {
        try claim.validateShape();
        if (claim.source_operator != manifest.id) return error.SourceOperatorMismatch;
        const index = registry.variableIndex(claim.variable) orelse return error.UnknownVariable;
        if (!containsVariable(manifest.provides_variables, claim.variable)) return error.UnauthorizedVariableWrite;
        if (claim.value) |value| {
            if (value.kind() != registry.variables[index].variable.kind) return error.VariableTypeMismatch;
        }
    }

    for (output.invariants()) |claim| {
        if (@as(usize, claim.parent_count) > core.max_claim_parents) return error.TooManyParents;
        if (claim.source_operator != manifest.id) return error.SourceOperatorMismatch;
        if (registry.invariantIndex(claim.invariant) == null) return error.UnknownInvariant;
        if (!containsInvariant(manifest.provides_invariants, claim.invariant)) return error.UnauthorizedInvariantWrite;
    }
}

fn containsVariable(values: []const core.VariableId, id: core.VariableId) bool {
    for (values) |candidate| if (candidate == id) return true;
    return false;
}

fn containsInvariant(values: []const core.InvariantId, id: core.InvariantId) bool {
    for (values) |candidate| if (candidate == id) return true;
    return false;
}

pub fn artifactRef(media_type: []const u8, bytes: []const u8) core.ArtifactRef {
    return .{
        .id = artifactContentId(media_type, bytes),
        .media_type = media_type,
        .size_bytes = @intCast(bytes.len),
    };
}

pub fn artifactContentId(media_type: []const u8, bytes: []const u8) core.ContentId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&[_]u8{canonical_artifact_version});
    hashSlice(&hasher, media_type);
    hashSlice(&hasher, bytes);
    var digest: core.ContentId = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn claimContentId(claim: core.Claim) core.ContentId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&[_]u8{canonical_claim_version});
    hashU32(&hasher, claim.variable);
    hasher.update(&[_]u8{@intFromEnum(claim.status)});
    hashU16(&hasher, claim.confidence_permille);
    hashU32(&hasher, claim.source_operator);

    if (claim.value) |value| {
        hasher.update(&[_]u8{1, @intFromEnum(value.kind())});
        hashValue(&hasher, value);
    } else {
        hasher.update(&[_]u8{0});
    }

    hasher.update(&[_]u8{@intCast(claim.parent_count)});
    var i: usize = 0;
    while (i < claim.parent_count) : (i += 1) hasher.update(&claim.parents[i]);

    var digest: core.ContentId = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashValue(hasher: *std.crypto.hash.Blake3, value: core.Value) void {
    switch (value) {
        .integer => |v| hashU64(hasher, @bitCast(v)),
        .float => |v| {
            const bits: u64 = @bitCast(v);
            hashU64(hasher, bits);
        },
        .boolean => |v| hasher.update(&[_]u8{if (v) 1 else 0}),
        .text => |v| hashSlice(hasher, v),
        .artifact_ref => |v| hasher.update(&v),
    }
}

fn hashSlice(hasher: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hashU64(hasher, @intCast(bytes.len));
    hasher.update(bytes);
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

test "claim identity is canonical and provenance-sensitive" {
    var parent = content_id.zero;
    parent[0] = 7;

    const a = core.Claim{
        .variable = 1,
        .status = .derived,
        .value = .{ .float = 42.0 },
        .source_operator = 9,
        .parents = .{ parent, content_id.zero, content_id.zero, content_id.zero },
        .parent_count = 1,
    };
    const b = a;
    var c = a;
    c.confidence_permille = 900;

    try std.testing.expect(content_id.eql(claimContentId(a), claimContentId(b)));
    try std.testing.expect(!content_id.eql(claimContentId(a), claimContentId(c)));
}

test "artifacts are content addressed by media type and bytes" {
    const a = artifactRef("text/plain", "hello");
    const b = artifactRef("text/plain", "hello");
    const c = artifactRef("application/octet-stream", "hello");
    try std.testing.expect(content_id.eql(a.id, b.id));
    try std.testing.expect(!content_id.eql(a.id, c.id));
}

test "manifest validation rejects unauthorized writes" {
    const R = reg.Registry(2, 1, 1);
    var registry = R{};
    try registry.addVariable(.{ .variable = .{ .id = 1, .name = "allowed", .kind = .integer } });
    try registry.addVariable(.{ .variable = .{ .id = 2, .name = "forbidden", .kind = .integer } });

    const manifest: core.OperatorManifest = .{
        .id = 7,
        .name = "writer",
        .provides_variables = &.{1},
    };

    var output = core.OperatorOutput{};
    try output.addClaim(.{
        .variable = 2,
        .status = .derived,
        .value = .{ .integer = 4 },
        .source_operator = 7,
    });

    try std.testing.expectError(
        error.UnauthorizedVariableWrite,
        validateOutput(&registry, manifest, &output),
    );
}

test "retain-all policy preserves disagreement as conflict" {
    const R = reg.Registry(1, 0, 0);
    const S = reg.ContextState(1, 0);
    const M = MaterializedState(1);
    var registry = R{};
    var state = S{};
    var materialized = M{};
    var claims = ClaimStore(4){};

    try registry.addVariable(.{ .variable = .{
        .id = 1,
        .name = "height",
        .kind = .float,
        .merge_policy = .retain_all_conflict,
    } });

    const a: core.Claim = .{
        .variable = 1,
        .status = .estimated,
        .value = .{ .float = 30.7 },
        .source_operator = 1,
    };
    const b: core.Claim = .{
        .variable = 1,
        .status = .estimated,
        .value = .{ .float = 47.9 },
        .source_operator = 2,
    };

    const aid = try claims.append(a);
    const bid = try claims.append(b);
    try materialized.applyClaim(&registry, &state, a, aid, 1);
    try materialized.applyClaim(&registry, &state, b, bid, 2);

    const cell = materialized.cell(&registry, 1).?;
    try std.testing.expect(cell.isConflicting());
    try std.testing.expectEqual(core.EpistemicStatus.conflicting, cell.status);
    try std.testing.expectEqual(@as(usize, 2), claims.len);
}

test "highest-confidence policy resolves deterministically" {
    const R = reg.Registry(1, 0, 0);
    const S = reg.ContextState(1, 0);
    const M = MaterializedState(1);
    var registry = R{};
    var state = S{};
    var materialized = M{};

    try registry.addVariable(.{ .variable = .{
        .id = 1,
        .name = "slope",
        .kind = .float,
        .merge_policy = .highest_confidence,
    } });

    const low: core.Claim = .{
        .variable = 1,
        .status = .estimated,
        .value = .{ .float = 3.0 },
        .confidence_permille = 500,
        .source_operator = 1,
    };
    const high: core.Claim = .{
        .variable = 1,
        .status = .estimated,
        .value = .{ .float = 4.0 },
        .confidence_permille = 900,
        .source_operator = 2,
    };

    try materialized.applyClaim(&registry, &state, low, claimContentId(low), 1);
    try materialized.applyClaim(&registry, &state, high, claimContentId(high), 2);
    const cell = materialized.cell(&registry, 1).?;
    try std.testing.expect(core.Value.eql(cell.value.?, .{ .float = 4.0 }));
}
