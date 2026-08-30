const std = @import("std");
const content_id = @import("../core/content_id.zig");

pub const ContentId = content_id.ContentId;
pub const VariableId = u32;
pub const InvariantId = u32;
pub const OperatorId = u32;

pub const EpistemicStatus = enum(u8) {
    unknown,
    observed,
    estimated,
    derived,
    not_visible,
    unavailable,
    blocked,
    conflicting,

    pub fn isResolved(self: EpistemicStatus) bool {
        return self != .unknown;
    }

    pub fn carriesValue(self: EpistemicStatus) bool {
        return switch (self) {
            .observed, .estimated, .derived => true,
            else => false,
        };
    }
};

pub const ValueKind = enum(u8) {
    integer,
    float,
    boolean,
    text,
    artifact_ref,
};

pub const Value = union(ValueKind) {
    integer: i64,
    float: f64,
    boolean: bool,
    text: []const u8,
    artifact_ref: ContentId,

    pub fn kind(self: Value) ValueKind {
        return std.meta.activeTag(self);
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.kind() != b.kind()) return false;
        return switch (a) {
            .integer => |v| v == b.integer,
            .float => |v| v == b.float,
            .boolean => |v| v == b.boolean,
            .text => |v| std.mem.eql(u8, v, b.text),
            .artifact_ref => |v| content_id.eql(v, b.artifact_ref),
        };
    }
};

pub const MergePolicy = enum(u8) {
    latest,
    highest_confidence,
    retain_all_conflict,
};

pub const Variable = struct {
    id: VariableId,
    name: []const u8,
    kind: ValueKind,
    unit: ?[]const u8 = null,
    merge_policy: MergePolicy = .retain_all_conflict,
};

pub const Invariant = struct {
    id: InvariantId,
    name: []const u8,
    requires: []const VariableId = &.{},
};

pub const EvidenceKind = enum(u8) {
    observation,
    derivation,
    validation,
    external,
};

pub const Evidence = struct {
    id: ContentId,
    source_operator: OperatorId,
    kind: EvidenceKind,
    note: []const u8 = "",
};

pub const max_claim_parents: usize = 4;

pub const Claim = struct {
    variable: VariableId,
    status: EpistemicStatus,
    value: ?Value = null,
    confidence_permille: u16 = 1000,
    source_operator: OperatorId,
    parents: [max_claim_parents]ContentId = [_]ContentId{content_id.zero} ** max_claim_parents,
    parent_count: u3 = 0,

    pub fn validateShape(self: Claim) !void {
        if (self.confidence_permille > 1000) return error.InvalidConfidence;
        if (@as(usize, self.parent_count) > max_claim_parents) return error.TooManyParents;
        if (self.status.carriesValue() != (self.value != null)) return error.InvalidEpistemicValue;
    }
};

pub const InvariantStatus = enum(u8) {
    unknown,
    satisfied,
    violated,
    blocked,
};

pub const InvariantClaim = struct {
    invariant: InvariantId,
    status: InvariantStatus,
    source_operator: OperatorId,
    parents: [max_claim_parents]ContentId = [_]ContentId{content_id.zero} ** max_claim_parents,
    parent_count: u3 = 0,
};

pub const ArtifactRef = struct {
    id: ContentId,
    media_type: []const u8,
    size_bytes: u64,
};

pub const ActionProposal = struct {
    name: []const u8,
    payload: []const u8 = "",
    requires_approval: bool = false,
};

pub const DiagnosticLevel = enum(u8) {
    debug,
    info,
    warning,
    error_level,
};

pub const Diagnostic = struct {
    level: DiagnosticLevel,
    message: []const u8,
};

pub const OperatorManifest = struct {
    id: OperatorId,
    name: []const u8,
    requires_variables: []const VariableId = &.{},
    requires_invariants: []const InvariantId = &.{},
    provides_variables: []const VariableId = &.{},
    provides_invariants: []const InvariantId = &.{},
};

pub const Operator = struct {
    manifest: OperatorManifest,
};

pub const max_output_claims: usize = 16;
pub const max_output_invariants: usize = 8;
pub const max_output_artifacts: usize = 8;
pub const max_output_actions: usize = 8;
pub const max_output_diagnostics: usize = 8;

pub const OperatorOutput = struct {
    variable_claims: [max_output_claims]Claim = undefined,
    variable_claim_count: usize = 0,
    invariant_claims: [max_output_invariants]InvariantClaim = undefined,
    invariant_claim_count: usize = 0,
    artifacts: [max_output_artifacts]ArtifactRef = undefined,
    artifact_count: usize = 0,
    actions: [max_output_actions]ActionProposal = undefined,
    action_count: usize = 0,
    diagnostics: [max_output_diagnostics]Diagnostic = undefined,
    diagnostic_count: usize = 0,

    pub fn addClaim(self: *OperatorOutput, claim: Claim) !void {
        if (self.variable_claim_count >= max_output_claims) return error.OutputCapacityExceeded;
        try claim.validateShape();
        self.variable_claims[self.variable_claim_count] = claim;
        self.variable_claim_count += 1;
    }

    pub fn addInvariant(self: *OperatorOutput, claim: InvariantClaim) !void {
        if (self.invariant_claim_count >= max_output_invariants) return error.OutputCapacityExceeded;
        self.invariant_claims[self.invariant_claim_count] = claim;
        self.invariant_claim_count += 1;
    }

    pub fn addArtifact(self: *OperatorOutput, artifact: ArtifactRef) !void {
        if (self.artifact_count >= max_output_artifacts) return error.OutputCapacityExceeded;
        self.artifacts[self.artifact_count] = artifact;
        self.artifact_count += 1;
    }

    pub fn addAction(self: *OperatorOutput, action: ActionProposal) !void {
        if (self.action_count >= max_output_actions) return error.OutputCapacityExceeded;
        self.actions[self.action_count] = action;
        self.action_count += 1;
    }

    pub fn addDiagnostic(self: *OperatorOutput, diagnostic: Diagnostic) !void {
        if (self.diagnostic_count >= max_output_diagnostics) return error.OutputCapacityExceeded;
        self.diagnostics[self.diagnostic_count] = diagnostic;
        self.diagnostic_count += 1;
    }

    pub fn claims(self: *const OperatorOutput) []const Claim {
        return self.variable_claims[0..self.variable_claim_count];
    }

    pub fn invariants(self: *const OperatorOutput) []const InvariantClaim {
        return self.invariant_claims[0..self.invariant_claim_count];
    }
};

pub const ResultOutcome = enum(u8) {
    running,
    success,
    blocked,
    conflicting,
    exhausted,
    failed,
    quiescent,
};

pub const Result = struct {
    outcome: ResultOutcome,
    rounds: u32 = 0,
    accepted_claims: usize = 0,
    rejected_claims: usize = 0,
    unresolved_variables: usize = 0,
    conflicting_variables: usize = 0,
    proposed_actions: usize = 0,
};

test "epistemic states distinguish closure from values" {
    try std.testing.expect(!EpistemicStatus.unknown.isResolved());
    try std.testing.expect(EpistemicStatus.blocked.isResolved());
    try std.testing.expect(EpistemicStatus.derived.carriesValue());
    try std.testing.expect(!EpistemicStatus.unavailable.carriesValue());
}

test "value equality is typed" {
    try std.testing.expect(Value.eql(.{ .integer = 7 }, .{ .integer = 7 }));
    try std.testing.expect(!Value.eql(.{ .integer = 7 }, .{ .float = 7.0 }));
    try std.testing.expect(Value.eql(.{ .text = "starling" }, .{ .text = "starling" }));
}

test "claim shape rejects fabricated values and invalid confidence" {
    const good = Claim{
        .variable = 1,
        .status = .derived,
        .value = .{ .float = 42.5 },
        .source_operator = 7,
    };
    try good.validateShape();

    const missing = Claim{
        .variable = 1,
        .status = .derived,
        .source_operator = 7,
    };
    try std.testing.expectError(error.InvalidEpistemicValue, missing.validateShape());

    const blocked_with_value = Claim{
        .variable = 1,
        .status = .blocked,
        .value = .{ .boolean = false },
        .source_operator = 7,
    };
    try std.testing.expectError(error.InvalidEpistemicValue, blocked_with_value.validateShape());

    const bad_confidence = Claim{
        .variable = 1,
        .status = .observed,
        .value = .{ .integer = 1 },
        .confidence_permille = 1001,
        .source_operator = 7,
    };
    try std.testing.expectError(error.InvalidConfidence, bad_confidence.validateShape());
}

test "operator output uses one canonical bounded envelope" {
    var output = OperatorOutput{};
    try output.addClaim(.{
        .variable = 1,
        .status = .observed,
        .value = .{ .boolean = true },
        .source_operator = 9,
    });
    try output.addInvariant(.{
        .invariant = 2,
        .status = .satisfied,
        .source_operator = 9,
    });
    try output.addAction(.{ .name = "request_human_review", .requires_approval = true });

    try std.testing.expectEqual(@as(usize, 1), output.claims().len);
    try std.testing.expectEqual(@as(usize, 1), output.invariants().len);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
}
