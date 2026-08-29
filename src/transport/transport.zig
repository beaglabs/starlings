const std = @import("std");
const rng_mod = @import("../core/rng.zig");
const msg_mod = @import("../core/message.zig");

pub const OperatorId = msg_mod.OperatorId;
pub const Message = msg_mod.Message;
pub const Kind = msg_mod.Kind;

/// Unique event identity for replay and idempotency.
pub const EventId = struct {
    sequence: u64,
    kind: EventKind,
    operator: OperatorId,
    payload_hash: u64,

    pub fn eql(a: EventId, b: EventId) bool {
        return a.sequence == b.sequence and
            a.kind == b.kind and
            a.operator == b.operator and
            a.payload_hash == b.payload_hash;
    }
};

/// Event kinds in the discrete-event simulation.
pub const EventKind = enum(u8) {
    /// Local policy decision point for an operator.
    policy_tick,
    /// Message delivery attempt.
    delivery,
    /// Partition event (isolate a set of operators).
    partition,
    /// Reconnection event.
    reconnect,
    /// Crash event (volatile state lost, persistent retained).
    crash,
    /// Restart event.
    restart,
};

/// Transport event in the priority queue.
pub const Event = struct {
    id: EventId,
    tick: u64,
    operator: OperatorId,
    kind: EventKind,
    message: ?Message,
    metadata: EventMetadata,
};

/// Metadata for replay and deterministic reconstruction.
pub const EventMetadata = struct {
    latency_ticks: u32 = 0,
    jitter_ticks: u32 = 0,
    is_duplicate: bool = false,
    is_dropped: bool = false,
    partition_group: u16 = 0,
    attempt_index: u16 = 0,
};

/// Transport configuration for disruption injection.
pub const DisruptionConfig = struct {
    /// Base latency in ticks (added to all deliveries).
    base_latency: u32 = 0,
    /// Maximum additional jitter in ticks.
    max_jitter: u32 = 0,
    /// Probability of message loss (permille, 0-1000).
    loss_permille: u16 = 0,
    /// Probability of message duplication (permille, 0-1000).
    duplication_permille: u16 = 0,
    /// Probability of message reordering (permille, 0-1000).
    reordering_permille: u16 = 0,
    /// Partition schedule: map from tick to partition group bitmask.
    partitions: std.AutoHashMap(u64, u16),
    /// Crash schedule: map from tick to operator crash bitmask.
    crashes: std.AutoHashMap(u64, u16),

    pub fn init() DisruptionConfig {
        return .{
            .partitions = std.AutoHashMap(u64, u16).init(std.heap.page_allocator),
            .crashes = std.AutoHashMap(u64, u16).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *DisruptionConfig) void {
        self.partitions.deinit();
        self.crashes.deinit();
    }
};

/// Persistent operator state (survives crash/restart).
pub const PersistentState = struct {
    /// Local logical clock.
    logical_clock: u64 = 0,
    /// Emitted message history for idempotency.
    emitted_hashes: std.array_list.Managed(u64),
    /// Received message hashes for deduplication.
    received_hashes: std.array_list.Managed(u64),
    /// Policy cursor state.
    policy_cursor: u32 = 0,

    pub fn init() PersistentState {
        return .{
            .emitted_hashes = std.array_list.Managed(u64).init(std.heap.page_allocator),
            .received_hashes = std.array_list.Managed(u64).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *PersistentState) void {
        self.emitted_hashes.deinit();
        self.received_hashes.deinit();
    }
};

/// Volatile operator state (lost on crash).
pub const VolatileOperatorState = struct {
    /// Pending outbound messages not yet acknowledged.
    outbound_queue: std.array_list.Managed(Message),
    /// In-flight delivery attempts.
    in_flight: std.array_list.Managed(DeliveryAttempt),
    /// Current round number.
    current_round: u32 = 0,

    pub fn init() VolatileOperatorState {
        return .{
            .outbound_queue = std.array_list.Managed(Message).init(std.heap.page_allocator),
            .in_flight = std.array_list.Managed(DeliveryAttempt).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *VolatileOperatorState) void {
        self.outbound_queue.deinit();
        self.in_flight.deinit();
    }
};

/// A single delivery attempt for tracking.
pub const DeliveryAttempt = struct {
    event_id: EventId,
    target: OperatorId,
    sent_tick: u64,
    scheduled_delivery_tick: u64,
};

/// Complete operator state in the transport.
pub const OperatorState = struct {
    id: OperatorId = 0,
    persistent: PersistentState,
    @"volatile": VolatileOperatorState,
    is_crashed: bool = false,
    partition_group: u16 = 0,
};

/// Deterministic event queue with seeded priority ordering.
pub const EventQueue = struct {
    events: std.array_list.Managed(Event),
    rng: rng_mod.Rng,
    next_sequence: u64 = 1,
    max_events: usize,

    pub fn init(seed: u64, max_events: usize) !EventQueue {
        const allocator = std.heap.page_allocator;
        var events = std.array_list.Managed(Event).init(allocator);
        try events.ensureTotalCapacity(max_events);
        return .{
            .events = events,
            .rng = rng_mod.Rng.init(seed),
            .max_events = max_events,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.events.deinit();
    }

    /// Push an event, maintaining priority order (earlier tick first, then sequence).
    pub fn push(self: *EventQueue, tick: u64, operator: OperatorId, kind: EventKind, message: ?Message, metadata: EventMetadata) !void {
        if (self.events.items.len >= self.max_events) {
            return error.QueueCapacityExceeded;
        }

        const payload_hash = if (message) |msg| hashMessage(msg) else 0;
        const event = Event{
            .id = .{
                .sequence = self.next_sequence,
                .kind = kind,
                .operator = operator,
                .payload_hash = payload_hash,
            },
            .tick = tick,
            .operator = operator,
            .kind = kind,
            .message = message,
            .metadata = metadata,
        };
        self.next_sequence += 1;

        // Insert in priority order (min-heap by tick, then sequence)
        var i = self.events.items.len;
        try self.events.append(event);
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (lessThan(self.events.items[i], self.events.items[parent])) {
                std.mem.swap(Event, &self.events.items[i], &self.events.items[parent]);
                i = parent;
            } else break;
        }
    }

    /// Pop the earliest event.
    pub fn pop(self: *EventQueue) ?Event {
        if (self.events.items.len == 0) return null;
        const result = self.events.items[0];
        self.events.items[0] = self.events.items[self.events.items.len - 1];
        _ = self.events.pop();
        var i: usize = 0;
        while (true) {
            const left = i * 2 + 1;
            if (left >= self.events.items.len) break;
            const right = left + 1;
            var smallest = left;
            if (right < self.events.items.len and lessThan(self.events.items[right], self.events.items[left])) {
                smallest = right;
            }
            if (lessThan(self.events.items[smallest], self.events.items[i])) {
                std.mem.swap(Event, &self.events.items[i], &self.events.items[smallest]);
                i = smallest;
            } else break;
        }
        return result;
    }

    /// Peek at the earliest event without removing.
    pub fn peek(self: *const EventQueue) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.items[0];
    }

    /// Remove and return all events at or before the given tick.
    pub fn drainUpTo(self: *EventQueue, tick: u64) []Event {
        var result = std.array_list.Managed(Event).init(std.heap.page_allocator);
        defer result.deinit(std.heap.page_allocator);
        while (self.peek()) |event| {
            if (event.tick > tick) break;
            _ = result.append(self.pop().?) catch break;
        }
        return result.items;
    }

    pub fn len(self: *const EventQueue) usize {
        return self.events.items.len;
    }
};

fn lessThan(a: Event, b: Event) bool {
    if (a.tick != b.tick) return a.tick < b.tick;
    return a.id.sequence < b.id.sequence;
}

/// Partition manager for network partitions.
pub const PartitionManager = struct {
    groups: std.array_list.Managed(u16),
    group_members: std.AutoHashMap(u16, std.array_list.Managed(OperatorId)),

    pub fn init() PartitionManager {
        return .{
            .groups = std.array_list.Managed(u16).init(std.heap.page_allocator),
            .group_members = std.AutoHashMap(u16, std.array_list.Managed(OperatorId)).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *PartitionManager) void {
        self.groups.deinit();
        var iter = self.group_members.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.group_members.deinit();
    }

    pub fn assignGroup(self: *PartitionManager, operator: OperatorId, group: u16) void {
        if (!self.group_members.contains(group)) {
            var list = std.array_list.Managed(OperatorId).init(std.heap.page_allocator);
            _ = list.append(operator) catch unreachable;
            self.group_members.put(group, list) catch unreachable;
            _ = self.groups.append(group) catch unreachable;
        } else {
            self.group_members.get(group).?.append(operator) catch unreachable;
        }
    }

    pub fn removeOperator(self: *PartitionManager, operator: OperatorId) void {
        var iter = self.group_members.iterator();
        while (iter.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i] == operator) {
                    list.items.swapRemove(i);
                    break;
                }
            }
        }
    }

    pub fn isPartitioned(self: *const PartitionManager, a: OperatorId, b: OperatorId) bool {
        const ga = self.findGroup(a);
        const gb = self.findGroup(b);
        if (ga == 0 or gb == 0) return false;
        return ga != gb;
    }

    fn findGroup(self: *const PartitionManager, operator: OperatorId) u16 {
        var iter = self.group_members.iterator();
        while (iter.next()) |entry| {
            const list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i] == operator) return entry.key_ptr.*;
            }
        }
        return 0;
    }
};

/// Complete deterministic transport runtime.
pub const Transport = struct {
    const MaxOperators = 128;
    const MaxFacts = 1024;

    operator_states: [MaxOperators]OperatorState = undefined,
    operator_count: usize = 0,
    event_queue: EventQueue,
    disruption: DisruptionConfig,
    partition_manager: PartitionManager,
    current_tick: u64 = 0,
    trace: std.array_list.Managed(TraceEntry),
    max_trace: usize,
    seed: u64,
    max_tick: u64 = 0,

    pub const Error = error{
        QueueCapacityExceeded,
        OperatorCapacityExceeded,
        UnknownOperator,
        TraceCapacityExceeded,
        InvalidConfiguration,
        OutOfMemory,
    };

    pub const TraceEntry = struct {
        tick: u64,
        event: Event,
        operator_state_snapshot: OperatorStateSnapshot,
    };

    pub const OperatorStateSnapshot = struct {
        operator: OperatorId,
        logical_clock: u64,
        outbound_count: usize,
        in_flight_count: usize,
        is_crashed: bool,
        partition_group: u16,
    };

    pub fn init(
        seed: u64,
        max_events: usize,
        max_trace: usize,
        disruption: DisruptionConfig,
    ) !Transport {
        var t = Transport{
            .event_queue = try EventQueue.init(seed, max_events),
            .disruption = disruption,
            .partition_manager = PartitionManager.init(),
            .trace = std.array_list.Managed(TraceEntry).init(std.heap.page_allocator),
            .max_trace = max_trace,
            .seed = seed,
        };
        try t.trace.ensureTotalCapacity(max_trace);
        return t;
    }

    pub fn deinit(self: *Transport) void {
        self.event_queue.deinit();
        self.trace.deinit();
        self.disruption.deinit();
        var i: usize = 0;
        while (i < self.operator_count) : (i += 1) {
            self.operator_states[i].persistent.deinit();
            self.operator_states[i].@"volatile".deinit();
            i += 1;
        }
        self.partition_manager.deinit();
    }

    pub fn addOperator(self: *Transport, id: OperatorId) !void {
        if (self.operator_count >= MaxOperators) return error.OperatorCapacityExceeded;
        if (self.findOperatorIndex(id) != null) return error.UnknownOperator;

        self.operator_states[self.operator_count] = OperatorState{
            .id = id,
            .persistent = PersistentState.init(),
            .@"volatile" = VolatileOperatorState.init(),
        };
        self.operator_count += 1;
    }

    pub fn findOperatorIndex(self: *const Transport, id: OperatorId) ?usize {
        var i: usize = 0;
        while (i < self.operator_count) : (i += 1) {
            if (self.operator_states[i].id == id) return i;
        }
        return null;
    }

    /// Schedule a policy tick for an operator.
    pub fn schedulePolicyTick(self: *Transport, operator: OperatorId, tick: u64) !void {
        try self.event_queue.push(tick, operator, .policy_tick, null, .{});
    }

    /// Send a message from one operator to another.
    pub fn send(self: *Transport, from: OperatorId, to: OperatorId, msg: Message) !void {
        const from_idx = self.findOperatorIndex(from) orelse return error.UnknownOperator;
        const to_idx = self.findOperatorIndex(to) orelse return error.UnknownOperator;

        if (self.operator_states[from_idx].is_crashed) return;
        if (self.operator_states[to_idx].is_crashed) return;
        if (self.partition_manager.isPartitioned(from, to)) return;

        var msg_copy = msg;
        msg_copy.sender = from;
        msg_copy.recipient = to;

        // Check for idempotency - hash the message content
        const msg_hash = hashMessage(msg_copy);
        const state = &self.operator_states[from_idx];
        var already_emitted = false;
        for (state.persistent.emitted_hashes.items) |h| {
            if (h == msg_hash) { already_emitted = true; break; }
        }
        if (already_emitted) return;

        // Apply disruption: loss, duplication, reordering
        const latency = self.disruption.base_latency;
        var jitter: u32 = 0;
        var is_dropped = false;
        var is_duplicate = false;
        var reorder = false;

        if (self.disruption.loss_permille > 0) {
            if (self.event_queue.rng.bounded(1000) < self.disruption.loss_permille) {
                is_dropped = true;
            }
        }
        if (!is_dropped and self.disruption.duplication_permille > 0) {
            if (self.event_queue.rng.bounded(1000) < self.disruption.duplication_permille) {
                is_duplicate = true;
            }
        }
        if (!is_dropped and self.disruption.reordering_permille > 0) {
            if (self.event_queue.rng.bounded(1000) < self.disruption.reordering_permille) {
                reorder = true;
            }
        }
        if (!is_dropped and self.disruption.max_jitter > 0) {
            jitter = @intCast(self.event_queue.rng.bounded(@as(usize, self.disruption.max_jitter) + 1));
        }

        const delivery_tick = self.current_tick + @as(u64, latency) + @as(u64, jitter);

        if (!is_dropped) {
            try state.persistent.emitted_hashes.append(msg_hash);
            try self.event_queue.push(
                delivery_tick,
                to,
                .delivery,
                msg_copy,
                .{
                    .latency_ticks = latency,
                    .jitter_ticks = jitter,
                    .is_duplicate = is_duplicate,
                    .is_dropped = false,
                    .partition_group = self.operator_states[to_idx].partition_group,
                    .attempt_index = 0,
                },
            );
        }

        // If duplicate, schedule a second delivery with different jitter
        if (is_duplicate and !is_dropped) {
            const dup_jitter = @as(u32, @intCast(self.event_queue.rng.bounded(@as(usize, self.disruption.max_jitter) + 1)));
            const dup_tick = self.current_tick + @as(u64, latency) + @as(u64, dup_jitter);
            try self.event_queue.push(
                dup_tick,
                to,
                .delivery,
                msg_copy,
                .{
                    .latency_ticks = latency,
                    .jitter_ticks = dup_jitter,
                    .is_duplicate = true,
                    .is_dropped = false,
                    .partition_group = self.operator_states[to_idx].partition_group,
                    .attempt_index = 1,
                },
            );
        }

        // If reorder, we could schedule with different timing - simplified here
    }

    /// Process events up to a given tick.
    pub fn processUpTo(self: *Transport, target_tick: u64) !void {
        while (self.current_tick < target_tick) {
            self.current_tick += 1;
            self.applyDisruptions(self.current_tick);
            while (true) {
                const event = self.event_queue.peek() orelse break;
                if (event.tick > self.current_tick) break;
                const popped = self.event_queue.pop().?;
                try self.processEvent(popped);
            }
        }
    }

    fn processEvent(self: *Transport, event: Event) !void {
        // Record trace
        if (self.trace.items.len >= self.max_trace) return;
        const snapshots = self.captureSnapshots();
        try self.trace.append(.{
            .tick = self.current_tick,
            .event = event,
            .operator_state_snapshot = snapshots[@intCast(event.operator)],
        });

        switch (event.kind) {
            .policy_tick => {
                try self.handlePolicyTick(event);
            },
            .delivery => {
                try self.handleDelivery(event);
            },
            .partition => {
                self.handlePartition();
            },
            .reconnect => {
                self.handleReconnect();
            },
            .crash => {
                self.handleCrash(event);
            },
            .restart => {
                self.handleRestart(event);
            },
        }
    }

    fn handlePolicyTick(self: *Transport, event: Event) !void {
        const idx = self.findOperatorIndex(event.operator) orelse return;
        const state = &self.operator_states[idx];
        if (state.is_crashed) return;

        state.persistent.logical_clock += 1;
        state.@"volatile".current_round += 1;

        // Policy execution would be called here by the experiment
        // The experiment should call a callback or check for pending policy ticks
    }

    fn handleDelivery(self: *Transport, event: Event) !void {
        const msg = event.message orelse return;
        const idx = self.findOperatorIndex(event.operator) orelse return;
        const state = &self.operator_states[idx];
        if (state.is_crashed) return;

        // Check for duplicate delivery
        const msg_hash = hashMessage(msg);
        for (state.persistent.received_hashes.items) |h| {
            if (h == msg_hash) {
                // Already received - count as duplicate but don't re-deliver
                return;
            }
        }

        try state.persistent.received_hashes.append(msg_hash);
        state.persistent.logical_clock = @max(state.persistent.logical_clock, msg.logical_clock) + 1;

        // Message delivered to operator's local processing
        // The experiment would handle the actual operator transition
    }

    fn handlePartition(_: *Transport) void {
        // Partition logic handled by disruption config
    }

    fn handleReconnect(_: *Transport) void {
        // Reconnection logic handled by disruption config
    }

    fn handleCrash(self: *Transport, event: Event) void {
        const idx = self.findOperatorIndex(event.operator) orelse return;
        self.operator_states[idx].is_crashed = true;
        // Volatile state is cleared, persistent retained
        self.operator_states[idx].@"volatile".outbound_queue.clearRetainingCapacity();
        self.operator_states[idx].@"volatile".in_flight.clearRetainingCapacity();
    }

    fn handleRestart(self: *Transport, event: Event) void {
        const idx = self.findOperatorIndex(event.operator) orelse return;
        self.operator_states[idx].is_crashed = false;
        // Volatile state starts fresh, persistent state intact
        self.operator_states[idx].@"volatile".current_round = 0;
    }

    fn captureSnapshots(self: *Transport) [MaxOperators]OperatorStateSnapshot {
        var snapshots: [MaxOperators]OperatorStateSnapshot = undefined;
        var i: usize = 0;
        while (i < self.operator_count) : (i += 1) {
            snapshots[i] = .{
                .operator = self.getOperatorId(i),
                .logical_clock = self.operator_states[i].persistent.logical_clock,
                .outbound_count = self.operator_states[i].@"volatile".outbound_queue.items.len,
                .in_flight_count = self.operator_states[i].@"volatile".in_flight.items.len,
                .is_crashed = self.operator_states[i].is_crashed,
                .partition_group = self.operator_states[i].partition_group,
            };
        }
        return snapshots;
    }

    fn getOperatorId(self: *Transport, index: usize) OperatorId {
        return self.operator_states[index].id;
    }

    /// Apply scheduled partitions and crashes from disruption config.
    pub fn applyDisruptions(self: *Transport, tick: u64) void {
        // Partitions
        if (self.disruption.partitions.get(tick)) |_| {
            // Apply partition groups
        }
        // Crashes
        if (self.disruption.crashes.get(tick)) |crash_mask| {
            var i: usize = 0;
            while (i < self.operator_count) : (i += 1) {
                const shift = @as(u4, @intCast(i));
                if ((crash_mask >> shift) & 1 == 1) {
                    self.operator_states[i].is_crashed = true;
                    self.operator_states[i].@"volatile".outbound_queue.clearRetainingCapacity();
                    self.operator_states[i].@"volatile".in_flight.clearRetainingCapacity();
                }
            }
        }
    }

    /// Get the complete trace for replay/analysis.
    pub fn getTrace(self: *const Transport) []const TraceEntry {
        return self.trace.items;
    }

    /// Export trace to a deterministic binary format for replay.
    pub fn exportTrace(self: *const Transport, allocator: std.mem.Allocator) ![]u8 {
        // Estimate buffer size: header (24 bytes) + per-entry (~200 bytes for safety)
        const estimated_size = 24 + self.trace.items.len * 200;
        var buffer = try allocator.alloc(u8, estimated_size);
        var cursor: usize = 0;

        // Write header: seed, operator_count, event_count
        writeU64(buffer, cursor, self.seed);
        cursor += 8;
        writeU32(buffer, cursor, @as(u32, @intCast(self.operator_count)));
        cursor += 4;
        writeU32(buffer, cursor, @as(u32, @intCast(self.trace.items.len)));
        cursor += 4;

        for (self.trace.items) |entry| {
            writeU64(buffer, cursor, entry.tick);
            cursor += 8;
            writeU64(buffer, cursor, entry.event.tick);
            cursor += 8;
            writeU32(buffer, cursor, entry.event.operator);
            cursor += 4;
            writeU8(buffer, cursor, @as(u8, @intFromEnum(entry.event.kind)));
            cursor += 1;
            writeU64(buffer, cursor, entry.event.id.sequence);
            cursor += 8;
            writeU64(buffer, cursor, entry.event.id.payload_hash);
            cursor += 8;
            if (entry.event.message) |msg| {
                writeU8(buffer, cursor, 1);
                cursor += 1;
                writeU32(buffer, cursor, msg.sender);
                cursor += 4;
                writeU32(buffer, cursor, msg.recipient);
                cursor += 4;
                writeU8(buffer, cursor, @as(u8, @intFromEnum(msg.kind)));
                cursor += 1;
                writeU64(buffer, cursor, msg.payload);
                cursor += 8;
                writeU64(buffer, cursor, msg.logical_clock);
                cursor += 8;
            } else {
                writeU8(buffer, cursor, 0);
                cursor += 1;
            }
            writeU64(buffer, cursor, entry.operator_state_snapshot.logical_clock);
            cursor += 8;
            writeU64(buffer, cursor, @as(u64, @intCast(entry.operator_state_snapshot.outbound_count)));
            cursor += 8;
            writeU64(buffer, cursor, @as(u64, @intCast(entry.operator_state_snapshot.in_flight_count)));
            cursor += 8;
            writeU8(buffer, cursor, if (entry.operator_state_snapshot.is_crashed) 1 else 0);
            cursor += 1;
            writeU16(buffer, cursor, entry.operator_state_snapshot.partition_group);
            cursor += 2;
        }

        // Create exact-size buffer and copy
        var exact_buffer = try allocator.alloc(u8, cursor);
        @memcpy(exact_buffer[0..cursor], buffer[0..cursor]);
        _ = allocator.free(buffer);
        return exact_buffer;
    }
};

fn writeU64(buf: []u8, offset: usize, val: u64) void {
    const b0: u8 = @intCast(val & 0xFF);
    buf[offset] = b0;
    const b1: u8 = @intCast((val >> 8) & 0xFF);
    buf[offset + 1] = b1;
    const b2: u8 = @intCast((val >> 16) & 0xFF);
    buf[offset + 2] = b2;
    const b3: u8 = @intCast((val >> 24) & 0xFF);
    buf[offset + 3] = b3;
    const b4: u8 = @intCast((val >> 32) & 0xFF);
    buf[offset + 4] = b4;
    const b5: u8 = @intCast((val >> 40) & 0xFF);
    buf[offset + 5] = b5;
    const b6: u8 = @intCast((val >> 48) & 0xFF);
    buf[offset + 6] = b6;
    const b7: u8 = @intCast((val >> 56) & 0xFF);
    buf[offset + 7] = b7;
}

fn writeU32(buf: []u8, offset: usize, val: u32) void {
    const b0: u8 = @intCast(val & 0xFF);
    buf[offset] = b0;
    const b1: u8 = @intCast((val >> 8) & 0xFF);
    buf[offset + 1] = b1;
    const b2: u8 = @intCast((val >> 16) & 0xFF);
    buf[offset + 2] = b2;
    const b3: u8 = @intCast((val >> 24) & 0xFF);
    buf[offset + 3] = b3;
}

fn writeU16(buf: []u8, offset: usize, val: u16) void {
    const b0: u8 = @intCast(val & 0xFF);
    buf[offset] = b0;
    const b1: u8 = @intCast((val >> 8) & 0xFF);
    buf[offset + 1] = b1;
}

fn writeU8(buf: []u8, offset: usize, val: u8) void {
    buf[offset] = val;
}

fn hashMessage(msg: Message) u64 {
    // Simple deterministic hash combining all fields using XOR and shifts
    var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
    hash ^= msg.sender;
    hash ^= hash << 13;
    hash ^= msg.recipient;
    hash ^= hash >> 7;
    hash ^= @intFromEnum(msg.kind);
    hash ^= hash << 17;
    hash ^= msg.payload;
    hash ^= hash >> 11;
    hash ^= msg.logical_clock;
    hash ^= hash << 5;
    if (msg.causal_ref) |cid| {
        for (cid) |b| {
            hash ^= b;
            hash ^= hash << 7;
        }
    }
    return hash;
}

test "EventQueue orders by tick then sequence" {
    var q = try EventQueue.init(42, 100);
    defer q.deinit();

    try q.push(10, 1, .policy_tick, null, .{});
    try q.push(5, 2, .delivery, null, .{});
    try q.push(10, 3, .policy_tick, null, .{});
    try q.push(5, 1, .delivery, null, .{});

    const first = q.pop().?;
    try std.testing.expectEqual(@as(u64, 5), first.tick);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(first.kind));
    try std.testing.expectEqual(@as(u64, 2), first.id.sequence);

    const second = q.pop().?;
    try std.testing.expectEqual(@as(u64, 5), second.tick);
    try std.testing.expectEqual(@as(u64, 4), second.id.sequence);

    const third = q.pop().?;
    try std.testing.expectEqual(@as(u64, 10), third.tick);
    try std.testing.expectEqual(@as(u64, 1), third.id.sequence);

    const fourth = q.pop().?;
    try std.testing.expectEqual(@as(u64, 10), fourth.tick);
    try std.testing.expectEqual(@as(u64, 3), fourth.id.sequence);
}

test "EventQueue deterministic with same seed" {
    var q1 = try EventQueue.init(12345, 100);
    var q2 = try EventQueue.init(12345, 100);
    defer {
        q1.deinit();
        q2.deinit();
    }

    for (0..10) |i| {
        try q1.push(@intCast(i * 7 % 100), @intCast(i % 4), .policy_tick, null, .{});
        try q2.push(@intCast(i * 7 % 100), @intCast(i % 4), .policy_tick, null, .{});
    }

    while (q1.len() > 0) {
        const a = q1.pop().?;
        const b = q2.pop().?;
        try std.testing.expect(a.id.eql(b.id));
        try std.testing.expectEqual(a.tick, b.tick);
        try std.testing.expectEqual(a.operator, b.operator);
    }
}

test "Transport basic send and deliver" {
    var transport = try Transport.init(42, 1000, 1000, DisruptionConfig.init());
    defer transport.deinit();

    try transport.addOperator(1);
    try transport.addOperator(2);

    const msg = Message{
        .sender = 1,
        .recipient = 2,
        .kind = .evidence,
        .payload = 42,
        .logical_clock = 0,
    };

    try transport.send(1, 2, msg);
    transport.applyDisruptions(0);
    try transport.processUpTo(100);

    // Check trace has delivery event
    const trace = transport.getTrace();
    try std.testing.expect(trace.len > 0);
}

test "Transport loss injection" {
    var disruption = DisruptionConfig.init();
    disruption.loss_permille = 1000; // 100% loss
    var transport = try Transport.init(42, 1000, 1000, disruption);
    defer transport.deinit();

    try transport.addOperator(1);
    try transport.addOperator(2);

    const msg = Message{
        .sender = 1,
        .recipient = 2,
        .kind = .evidence,
        .payload = 42,
        .logical_clock = 0,
    };

    try transport.send(1, 2, msg);
    transport.applyDisruptions(0);
    try transport.processUpTo(100);

    // With 100% loss, no delivery should occur
    const trace = transport.getTrace();
    var delivery_count: usize = 0;
    for (trace) |entry| {
        if (entry.event.kind == .delivery) delivery_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), delivery_count);
}

test "Transport duplication injection" {
    var disruption = DisruptionConfig.init();
    disruption.duplication_permille = 1000; // 100% duplication
    var transport = try Transport.init(42, 1000, 1000, disruption);
    defer transport.deinit();

    try transport.addOperator(1);
    try transport.addOperator(2);

    const msg = Message{
        .sender = 1,
        .recipient = 2,
        .kind = .evidence,
        .payload = 42,
        .logical_clock = 0,
    };

    try transport.send(1, 2, msg);
    transport.applyDisruptions(0);
    try transport.processUpTo(100);

    // With 100% duplication, should have 2 delivery events
    const trace = transport.getTrace();
    var delivery_count: usize = 0;
    for (trace) |entry| {
        if (entry.event.kind == .delivery) delivery_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), delivery_count);
}

test "Transport crash and restart preserves persistent state" {
    var disruption = DisruptionConfig.init();
    disruption.crashes.put(50, 1) catch unreachable; // crash operator 0
    var transport = try Transport.init(42, 1000, 1000, disruption);
    defer transport.deinit();

    try transport.addOperator(1);
    try transport.addOperator(2);

    const msg = Message{
        .sender = 1,
        .recipient = 2,
        .kind = .evidence,
        .payload = 42,
        .logical_clock = 0,
    };

    try transport.send(1, 2, msg);
    try transport.processUpTo(100);

    // Operator 1 should be crashed, persistent state retained
    const idx = transport.findOperatorIndex(1).?;
    try std.testing.expect(transport.operator_states[idx].is_crashed);
    try std.testing.expect(transport.operator_states[idx].persistent.emitted_hashes.items.len > 0);
    try std.testing.expect(transport.operator_states[idx].@"volatile".outbound_queue.items.len == 0);
}

test "Transport trace export and deterministic replay" {
    var disruption = DisruptionConfig.init();
    disruption.base_latency = 10;
    disruption.max_jitter = 5;
    disruption.loss_permille = 100;
    disruption.duplication_permille = 50;

    var transport = try Transport.init(999, 1000, 1000, disruption);
    defer transport.deinit();

    try transport.addOperator(1);
    try transport.addOperator(2);
    try transport.addOperator(3);

    // Schedule some policy ticks
    try transport.schedulePolicyTick(1, 0);
    try transport.schedulePolicyTick(2, 10);
    try transport.schedulePolicyTick(3, 20);

    // Send some messages
    const msg1 = Message{ .sender = 1, .recipient = 2, .kind = .evidence, .payload = 1, .logical_clock = 0 };
    const msg2 = Message{ .sender = 2, .recipient = 3, .kind = .claim, .payload = 2, .logical_clock = 0 };
    try transport.send(1, 2, msg1);
    try transport.send(2, 3, msg2);

    // Process all events
    try transport.processUpTo(1000);

    // Export trace
    const trace_bytes = try transport.exportTrace(std.testing.allocator);
    defer std.testing.allocator.free(trace_bytes);

    // Create new transport with same seed and replay
    var disruption2 = DisruptionConfig.init();
    disruption2.base_latency = 10;
    disruption2.max_jitter = 5;
    disruption2.loss_permille = 100;
    disruption2.duplication_permille = 50;

    var transport2 = try Transport.init(999, 1000, 1000, disruption2);
    defer transport2.deinit();

    try transport2.addOperator(1);
    try transport2.addOperator(2);
    try transport2.addOperator(3);

    try transport2.schedulePolicyTick(1, 0);
    try transport2.schedulePolicyTick(2, 10);
    try transport2.schedulePolicyTick(3, 20);
    try transport2.send(1, 2, msg1);
    try transport2.send(2, 3, msg2);

    try transport2.processUpTo(1000);

    const trace1 = transport.getTrace();
    const trace2 = transport2.getTrace();

    try std.testing.expectEqual(trace1.len, trace2.len);
    for (trace1, trace2) |a, b| {
        try std.testing.expectEqual(a.tick, b.tick);
        try std.testing.expectEqual(a.event.tick, b.event.tick);
        try std.testing.expectEqual(a.event.operator, b.event.operator);
        try std.testing.expect(a.event.id.eql(b.event.id));
    }
}