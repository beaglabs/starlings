const std = @import("std");
const message = @import("message.zig");
const operator = @import("operator.zig");
const runtime = @import("runtime.zig");

pub const Strategy = enum {
    broadcast_all,
    centralized,
    point_to_point,
};

pub const Config = struct {
    seed: u64 = 0x5eed,
    /// When set, messages originating from this worker are deliberately
    /// dropped. This is benchmark-level fault injection, not runtime policy.
    drop_sender: ?message.OperatorId = null,
};

pub const Metrics = struct {
    success: bool,
    messages_sent: usize,
    messages_dropped: usize,
    bytes_sent: usize,
    communication_rounds: u32,
    payload_bits_transmitted: usize,
    unique_payload_bits: usize,
    duplicated_payload_bits: usize,
    operators_used: usize,
};

pub const Result = struct {
    strategy: Strategy,
    seed: u64,
    expected: u64,
    observed: u64,
    metrics: Metrics,
};

const worker_count: usize = 5;
const coordinator_id: message.OperatorId = 6;
const verifier_id: message.OperatorId = 7;
const expected_mask: u64 = (1 << worker_count) - 1;
const BenchRuntime = runtime.Runtime(7, 64, 64);

const Recorder = struct {
    rt: *BenchRuntime,
    drop_sender: ?message.OperatorId,
    messages_sent: usize = 0,
    messages_dropped: usize = 0,
    payload_bits_transmitted: usize = 0,
    payload_union: u64 = 0,
    max_round: u32 = 0,
    used_operators: u64 = 0,

    fn send(self: *Recorder, sender: message.OperatorId, recipient: message.OperatorId, payload: u64, round: u32) !void {
        if (self.drop_sender != null and self.drop_sender.? == sender) {
            self.messages_dropped += 1;
            return;
        }

        try self.rt.enqueue(.{
            .sender = sender,
            .recipient = recipient,
            .kind = .claim,
            .payload = payload,
            .causal_ref = @as(u64, sender),
        });

        self.messages_sent += 1;
        self.payload_bits_transmitted += @popCount(payload);
        self.payload_union |= payload;
        if (round > self.max_round) self.max_round = round;
        self.used_operators |= (@as(u64, 1) << @intCast(sender - 1));
        self.used_operators |= (@as(u64, 1) << @intCast(recipient - 1));
    }

    fn metrics(self: *const Recorder, success: bool) Metrics {
        const unique_bits: usize = @popCount(self.payload_union);
        return .{
            .success = success,
            .messages_sent = self.messages_sent,
            .messages_dropped = self.messages_dropped,
            .bytes_sent = self.messages_sent * @sizeOf(message.Message),
            .communication_rounds = self.max_round,
            .payload_bits_transmitted = self.payload_bits_transmitted,
            .unique_payload_bits = unique_bits,
            .duplicated_payload_bits = self.payload_bits_transmitted - unique_bits,
            .operators_used = @popCount(self.used_operators),
        };
    }
};

/// This benchmark validates the measurement apparatus; it is intentionally
/// simple and is not evidence that one coordination strategy is universally
/// superior. Five workers each own one independent fact. Success means the
/// verifier reconstructs all five facts. Later experiments can replace the
/// task while preserving the same measurement surface.
pub fn run(strategy: Strategy, config: Config) !Result {
    var rt = BenchRuntime.init(config.seed);

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        try rt.addOperator(.{
            .id = @intCast(i + 1),
            .state = @as(u64, 1) << @intCast(i),
            .transition = operator.accumulator,
        });
    }
    try rt.addOperator(.{ .id = coordinator_id, .transition = operator.accumulator });
    try rt.addOperator(.{ .id = verifier_id, .transition = operator.accumulator });

    var recorder = Recorder{ .rt = &rt, .drop_sender = config.drop_sender };

    switch (strategy) {
        .broadcast_all => try runBroadcast(&rt, &recorder),
        .centralized => try runCentralized(&rt, &recorder),
        .point_to_point => try runPointToPoint(&rt, &recorder),
    }

    const verifier_index = rt.findOperator(verifier_id).?;
    const observed = rt.operators[verifier_index].state;
    const success = observed == expected_mask;

    return .{
        .strategy = strategy,
        .seed = config.seed,
        .expected = expected_mask,
        .observed = observed,
        .metrics = recorder.metrics(success),
    };
}

fn runBroadcast(rt: *BenchRuntime, recorder: *Recorder) !void {
    var sender_index: usize = 0;
    while (sender_index < worker_count) : (sender_index += 1) {
        const sender: message.OperatorId = @intCast(sender_index + 1);
        const fact = @as(u64, 1) << @intCast(sender_index);

        var recipient_index: usize = 0;
        while (recipient_index < worker_count) : (recipient_index += 1) {
            const recipient: message.OperatorId = @intCast(recipient_index + 1);
            if (recipient != sender) try recorder.send(sender, recipient, fact, 1);
        }
        try recorder.send(sender, verifier_id, fact, 1);
    }
    try rt.run();
}

fn runCentralized(rt: *BenchRuntime, recorder: *Recorder) !void {
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const sender: message.OperatorId = @intCast(i + 1);
        const fact = @as(u64, 1) << @intCast(i);
        try recorder.send(sender, coordinator_id, fact, 1);
    }
    try rt.run();

    const coordinator_index = rt.findOperator(coordinator_id).?;
    try recorder.send(coordinator_id, verifier_id, rt.operators[coordinator_index].state, 2);
    try rt.run();
}

fn runPointToPoint(rt: *BenchRuntime, recorder: *Recorder) !void {
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const sender: message.OperatorId = @intCast(i + 1);
        const fact = @as(u64, 1) << @intCast(i);
        try recorder.send(sender, verifier_id, fact, 1);
    }
    try rt.run();
}

test "all coordination baselines solve the distributed-information task" {
    inline for (.{ Strategy.broadcast_all, Strategy.centralized, Strategy.point_to_point }) |strategy| {
        const result = try run(strategy, .{});
        try std.testing.expect(result.metrics.success);
        try std.testing.expectEqual(expected_mask, result.observed);
        try std.testing.expectEqual(@as(usize, worker_count), result.metrics.unique_payload_bits);
    }
}

test "coordination strategies expose expected communication tradeoffs" {
    const broadcast = try run(.broadcast_all, .{});
    const centralized = try run(.centralized, .{});
    const direct = try run(.point_to_point, .{});

    try std.testing.expectEqual(@as(usize, 25), broadcast.metrics.messages_sent);
    try std.testing.expectEqual(@as(u32, 1), broadcast.metrics.communication_rounds);
    try std.testing.expectEqual(@as(usize, 20), broadcast.metrics.duplicated_payload_bits);

    try std.testing.expectEqual(@as(usize, 6), centralized.metrics.messages_sent);
    try std.testing.expectEqual(@as(u32, 2), centralized.metrics.communication_rounds);
    try std.testing.expectEqual(@as(usize, 5), centralized.metrics.duplicated_payload_bits);

    try std.testing.expectEqual(@as(usize, 5), direct.metrics.messages_sent);
    try std.testing.expectEqual(@as(u32, 1), direct.metrics.communication_rounds);
    try std.testing.expectEqual(@as(usize, 0), direct.metrics.duplicated_payload_bits);
}

test "benchmark results are reproducible for the same seed" {
    const a = try run(.centralized, .{ .seed = 12345 });
    const b = try run(.centralized, .{ .seed = 12345 });
    try std.testing.expectEqualDeep(a, b);
}

test "fault injection makes missing information visible" {
    const result = try run(.point_to_point, .{ .drop_sender = 3 });
    try std.testing.expect(!result.metrics.success);
    try std.testing.expectEqual(@as(usize, 1), result.metrics.messages_dropped);
    try std.testing.expect(result.observed != result.expected);
}
