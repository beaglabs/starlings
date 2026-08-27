const std = @import("std");

pub const ContentId = u64;

pub const EventKind = enum(u8) {
    observe,
    claim,
    evidence,
    decision,
};

pub const Event = struct {
    kind: EventKind,
    payload: u64,
    parents: [2]ContentId = .{ 0, 0 },
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
                if (self.nodes[i].id == id) return i;
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
            var seen: [capacity]ContentId = [_]ContentId{0} ** capacity;
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
    for (values) |candidate| if (candidate == value) return true;
    return false;
}

/// Stable experimental content identifier. This is deliberately not presented
/// as a cryptographic commitment. If the DAG hypothesis validates, the digest
/// implementation can be replaced by SHA-256/BLAKE3 without changing DAG semantics.
pub fn contentId(event: Event) ContentId {
    var h: u64 = 0xcbf29ce484222325;
    h = mix(h, @intFromEnum(event.kind));
    h = mix64(h, event.payload);
    h = mix(h, event.parent_count);

    var i: usize = 0;
    while (i < event.parent_count) : (i += 1) h = mix64(h, event.parents[i]);
    return avalanche(h);
}

fn mix(h_in: u64, byte: anytype) u64 {
    var h = h_in;
    h ^= @as(u64, @intCast(byte));
    return h *% 0x100000001b3;
}

fn mix64(h_in: u64, value: u64) u64 {
    var h = h_in;
    var byte_index: usize = 0;
    while (byte_index < 8) : (byte_index += 1) {
        const shift: u6 = @intCast(byte_index * 8);
        h = mix(h, @as(u8, @truncate(value >> shift)));
    }
    return h;
}

fn avalanche(value: u64) u64 {
    var x = value;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

test "content identity is stable and sensitive to causal parents" {
    const parent_a = contentId(.{ .kind = .observe, .payload = 1 });
    const parent_b = contentId(.{ .kind = .observe, .payload = 2 });

    const a = contentId(.{ .kind = .claim, .payload = 4, .parents = .{ parent_a, 0 }, .parent_count = 1 });
    const b = contentId(.{ .kind = .claim, .payload = 4, .parents = .{ parent_a, 0 }, .parent_count = 1 });
    const c = contentId(.{ .kind = .claim, .payload = 4, .parents = .{ parent_b, 0 }, .parent_count = 1 });

    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "merkle dag deduplicates identical causal events" {
    var dag = MerkleDag(8){};
    const event: Event = .{ .kind = .observe, .payload = 1 };
    const first = try dag.insert(event);
    const second = try dag.insert(event);
    try std.testing.expect(first.inserted);
    try std.testing.expect(!second.inserted);
    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(@as(usize, 1), dag.len);
}

test "causal ancestry is reconstructable" {
    var dag = MerkleDag(8){};
    const root = try dag.insert(.{ .kind = .observe, .payload = 1 });
    const middle = try dag.insert(.{ .kind = .claim, .payload = 2, .parents = .{ root.id, 0 }, .parent_count = 1 });
    const head = try dag.insert(.{ .kind = .decision, .payload = 4, .parents = .{ middle.id, 0 }, .parent_count = 1 });
    try std.testing.expectEqual(@as(usize, 3), try dag.ancestorCount(head.id));
}

test "reconciliation counts only missing content" {
    var remote = MerkleDag(8){};
    var local = MerkleDag(8){};
    const a = try remote.insert(.{ .kind = .observe, .payload = 1 });
    _ = try remote.insert(.{ .kind = .claim, .payload = 2, .parents = .{ a.id, 0 }, .parent_count = 1 });
    _ = try local.insert(.{ .kind = .observe, .payload = 1 });
    try std.testing.expectEqual(@as(usize, 1), remote.missingCount(&local));
}
