const std = @import("std");
const content_id = @import("content_id.zig");

pub const ContentId = content_id.ContentId;
pub const zero_id = content_id.zero;
pub const canonical_version: u8 = 1;

pub const EventKind = enum(u8) {
    observe,
    claim,
    evidence,
    decision,
};

pub const Event = struct {
    kind: EventKind,
    payload: u64,
    parents: [2]ContentId = .{ zero_id, zero_id },
    parent_count: u2 = 0,
};

pub const AppendRecord = struct {
    sequence: u64,
    event: Event,
};

pub fn AppendLog(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        records: [capacity]AppendRecord = undefined,
        len: usize = 0,

        pub fn append(self: *Self, event: Event) !u64 {
            if (self.len >= capacity) return error.CapacityExceeded;
            const sequence: u64 = @intCast(self.len + 1);
            self.records[self.len] = .{ .sequence = sequence, .event = event };
            self.len += 1;
            return sequence;
        }

        pub fn replayUnion(self: *const Self) u64 {
            var state: u64 = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) state |= self.records[i].event.payload;
            return state;
        }
    };
}

pub const DagNode = struct {
    id: ContentId,
    event: Event,
};

pub const InsertResult = struct {
    id: ContentId,
    inserted: bool,
};

pub fn MerkleDag(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        nodes: [capacity]DagNode = undefined,
        len: usize = 0,

        pub fn insert(self: *Self, event: Event) !InsertResult {
            const id = contentId(event);
            if (self.find(id) != null) return .{ .id = id, .inserted = false };
            if (self.len >= capacity) return error.CapacityExceeded;

            var p: usize = 0;
            while (p < event.parent_count) : (p += 1) {
                if (self.find(event.parents[p]) == null) return error.UnknownParent;
            }

            self.nodes[self.len] = .{ .id = id, .event = event };
            self.len += 1;
            return .{ .id = id, .inserted = true };
        }

        pub fn find(self: *const Self, id: ContentId) ?usize {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (content_id.eql(self.nodes[i].id, id)) return i;
            }
            return null;
        }

        pub fn replayUnion(self: *const Self) u64 {
            var state: u64 = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) state |= self.nodes[i].event.payload;
            return state;
        }

        pub fn ancestorCount(self: *const Self, head: ContentId) !usize {
            if (self.find(head) == null) return error.UnknownNode;
            var seen: [capacity]ContentId = [_]ContentId{zero_id} ** capacity;
            var seen_len: usize = 0;
            var stack: [capacity]ContentId = undefined;
            var stack_len: usize = 1;
            stack[0] = head;

            while (stack_len > 0) {
                stack_len -= 1;
                const current = stack[stack_len];
                if (contains(seen[0..seen_len], current)) continue;
                seen[seen_len] = current;
                seen_len += 1;

                const idx = self.find(current).?;
                const node = self.nodes[idx];
                var p: usize = 0;
                while (p < node.event.parent_count) : (p += 1) {
                    if (stack_len >= capacity) return error.CapacityExceeded;
                    stack[stack_len] = node.event.parents[p];
                    stack_len += 1;
                }
            }

            return seen_len;
        }

        pub fn missingCount(remote: *const Self, local: *const Self) usize {
            var count: usize = 0;
            var i: usize = 0;
            while (i < remote.len) : (i += 1) {
                if (local.find(remote.nodes[i].id) == null) count += 1;
            }
            return count;
        }
    };
}

fn contains(values: []const ContentId, value: ContentId) bool {
    for (values) |candidate| if (content_id.eql(candidate, value)) return true;
    return false;
}

/// Canonical event identity for Starlings provenance.
///
/// Encoding v1 is hashed incrementally as:
///   version:u8 || kind:u8 || payload:u64-le || parent_count:u8 || parents[0..count]
///
/// Parent order is significant because it is part of the causal expression.
/// Changing this encoding requires incrementing `canonical_version`.
pub fn contentId(event: Event) ContentId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    const header = [_]u8{ canonical_version, @intFromEnum(event.kind) };
    hasher.update(&header);

    var payload_bytes: [8]u8 = undefined;
    encodeU64Le(event.payload, &payload_bytes);
    hasher.update(&payload_bytes);

    const parent_count = [_]u8{@intCast(event.parent_count)};
    hasher.update(&parent_count);

    var i: usize = 0;
    while (i < event.parent_count) : (i += 1) hasher.update(&event.parents[i]);

    var digest: ContentId = undefined;
    hasher.final(&digest);
    return digest;
}

fn encodeU64Le(value: u64, out: *[8]u8) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        out[i] = @truncate(value >> shift);
    }
}

test "content identity is stable and sensitive to causal parents" {
    const parent_a = contentId(.{ .kind = .observe, .payload = 1 });
    const parent_b = contentId(.{ .kind = .observe, .payload = 2 });

    const a = contentId(.{ .kind = .claim, .payload = 4, .parents = .{ parent_a, zero_id }, .parent_count = 1 });
    const b = contentId(.{ .kind = .claim, .payload = 4, .parents = .{ parent_a, zero_id }, .parent_count = 1 });
    const c = contentId(.{ .kind = .claim, .payload = 4, .parents = .{ parent_b, zero_id }, .parent_count = 1 });

    try std.testing.expect(content_id.eql(a, b));
    try std.testing.expect(!content_id.eql(a, c));
}

test "canonical encoding is versioned and parent order is significant" {
    const left = contentId(.{ .kind = .observe, .payload = 1 });
    const right = contentId(.{ .kind = .observe, .payload = 2 });
    const ab = contentId(.{ .kind = .decision, .payload = 3, .parents = .{ left, right }, .parent_count = 2 });
    const ba = contentId(.{ .kind = .decision, .payload = 3, .parents = .{ right, left }, .parent_count = 2 });
    try std.testing.expectEqual(@as(u8, 1), canonical_version);
    try std.testing.expect(!content_id.eql(ab, ba));
}

test "merkle dag deduplicates identical causal events" {
    var dag = MerkleDag(8){};
    const event: Event = .{ .kind = .observe, .payload = 1 };
    const first = try dag.insert(event);
    const second = try dag.insert(event);
    try std.testing.expect(first.inserted);
    try std.testing.expect(!second.inserted);
    try std.testing.expect(content_id.eql(first.id, second.id));
    try std.testing.expectEqual(@as(usize, 1), dag.len);
}

test "causal ancestry is reconstructable" {
    var dag = MerkleDag(8){};
    const root = try dag.insert(.{ .kind = .observe, .payload = 1 });
    const middle = try dag.insert(.{ .kind = .claim, .payload = 2, .parents = .{ root.id, zero_id }, .parent_count = 1 });
    const head = try dag.insert(.{ .kind = .decision, .payload = 4, .parents = .{ middle.id, zero_id }, .parent_count = 1 });
    try std.testing.expectEqual(@as(usize, 3), try dag.ancestorCount(head.id));
}

test "reconciliation counts only missing content" {
    var remote = MerkleDag(8){};
    var local = MerkleDag(8){};
    const a = try remote.insert(.{ .kind = .observe, .payload = 1 });
    _ = try remote.insert(.{ .kind = .claim, .payload = 2, .parents = .{ a.id, zero_id }, .parent_count = 1 });
    _ = try local.insert(.{ .kind = .observe, .payload = 1 });
    try std.testing.expectEqual(@as(usize, 1), remote.missingCount(&local));
}
