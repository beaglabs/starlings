const std = @import("std");
const core = @import("core_types.zig");

pub const canonical_action_version: u8 = 1;

pub const ActionStatus = enum(u8) {
    ready,
    pending_approval,
    approved,
    rejected,
};

pub const ActionDecision = enum(u8) {
    approved,
    rejected,
};

pub fn actionContentId(
    proposal: core.ActionProposal,
    source_operator: core.OperatorId,
    activation_epoch: u64,
    ordinal: u16,
) core.ContentId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("starlings-sdk-action-proposal-v1");
    hasher.update(&.{canonical_action_version});
    hashU32(&hasher, source_operator);
    hashU64(&hasher, activation_epoch);
    hashU16(&hasher, ordinal);
    hashSlice(&hasher, proposal.name);
    hashSlice(&hasher, proposal.payload);
    hasher.update(&.{if (proposal.requires_approval) 1 else 0});

    var digest: core.ContentId = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn validateArtifact(artifact: core.ArtifactRef) !void {
    if (artifact.media_type.len == 0) return error.InvalidArtifactMediaType;
}

pub fn validateAction(action: core.ActionProposal) !void {
    if (action.name.len == 0) return error.InvalidActionName;
}

fn hashSlice(hasher: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hashU64(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn hashU16(hasher: *std.crypto.hash.Blake3, value: u16) void {
    const bytes = [_]u8{
        @truncate(value),
        @truncate(value >> 8),
    };
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

test "action identities bind proposal operator epoch and ordinal" {
    const proposal = core.ActionProposal{
        .name = "publish",
        .payload = "case-7",
        .requires_approval = true,
    };

    const a = actionContentId(proposal, 10, 1, 0);
    const b = actionContentId(proposal, 10, 1, 0);
    const next_epoch = actionContentId(proposal, 10, 2, 0);
    const next_ordinal = actionContentId(proposal, 10, 1, 1);

    try std.testing.expect(std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &next_epoch));
    try std.testing.expect(!std.mem.eql(u8, &a, &next_ordinal));
}

test "data-plane descriptors reject empty names" {
    try std.testing.expectError(
        error.InvalidArtifactMediaType,
        validateArtifact(.{
            .id = [_]u8{1} ** 32,
            .media_type = "",
            .size_bytes = 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidActionName,
        validateAction(.{ .name = "" }),
    );
}
