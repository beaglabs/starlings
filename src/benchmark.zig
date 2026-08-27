const std = @import("std");
const message = @import("message.zig");
const operator = @import("operator.zig");
const runtime = @import("runtime.zig");
const rng_mod = @import("rng.zig");

pub const Strategy = enum {
    broadcast_all,
    centralized,
    point_to_point,
};

pub const TaskShape = enum {
    partitioned,
    overlapping,
};

pub const Config = struct {
    seed: u64 = 0x5eed,
    task: TaskShape = .partitioned,
    drop_sender: ?message.OperatorId = null,
    disabled_worker: ?message.OperatorId = null,
    loss_per_mille: u16 = 0,
};

pub const Metrics = struct {
    success: bool,
    messages_attempted: usize,
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
    task: TaskShape,
    seed: u64,
    expected: u64,
    observed: u64,
    worker_payloads: [worker_count]u64,
    metrics: Metrics,
};

pub const Aggregate = struct {
    strategy: Strategy,
    task: TaskShape,
    runs: usize,
    successes: usize,
    total_messages_attempted: usize,
    total_messages_sent: usize,
    total_messages_dropped: usize,
    total_bytes_sent: usize,
    total_rounds: usize,
    total_duplicated_payload_bits: usize,

    pub fn successRatePermille(self: Aggregate) usize {
        if (self.runs == 0) return 0;
        return (self.successes * 1000) / self.runs;
    }

    pub fn averageMessagesSent(self: Aggregate) usize {
        if (self.runs == 0) return 0;
        return self.total_messages_sent / self.runs;
    }
};

const worker_count: usize = 5;
const coordinator_id: message.OperatorId = 6;
const verifier_id: message.OperatorId = 7;
const expected_mask: u64 = (1 << worker_count) - 1;
const BenchRuntime = runtime.Runtime(7, 64, 64);

const Recorder = struct {
    rt: *BenchRuntime,
    drop_sender: ?message.OperatorId,
    loss_per_mille: u16,
    messages_attempted: usize = 0,
    messages_sent: usize = 0,
    messages_dropped: usize = 0,
    payload_bits_transmitted: usize = 0,
    payload_union: u64 = 0,
    max_round: u32 = 0,
    used_operators: u64 = 0,

    fn send(self: *Recorder, sender: message.OperatorId, recipient: message.OperatorId, payload: u64, round: u32) !void {
        self.messages_attempted += 1;
        if (self.drop_sender != null and self.drop_sender.? == sender) {
            self.messages_dropped += 1;
            return;
        }
        if (self.loss_per_mille > 0 and self.rt.randomIndex(1000) < self.loss_per_mille) {
            self.messages_dropped += 1;
            return;
        }

        try self.rt.enqueue(.{
            .sender = sender,
            .recipient = recipient,
            .kind = .claim,
            .payload = payload,
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
            .messages_attempted = self.messages_attempted,
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

fn makeWorkerPayloads(seed: u64, task: TaskShape) [worker_count]u64 {
    var permutation = [_]usize{ 0, 1, 2, 3, 4 };
    var rng = rng_mod.Rng.init(seed ^ 0x535441524c494e47);
    var i: usize = worker_count - 1;
    while (i > 0) : (i -= 1) {
        const j = rng.bounded(i + 1);
        const tmp = permutation[i];
        permutation[i] = permutation[j];
        permutation[j] = tmp;
    }

    var payloads = [_]u64{0} ** worker_count;
    i = 0;
    while (i < worker_count) : (i += 1) {
        payloads[i] = @as(u64, 1) << @intCast(permutation[i]);
        if (task == .overlapping) {
            payloads[i] |= @as(u64, 1) << @intCast(permutation[(i + 1) % worker_count]);
        }
    }
    return payloads;
}

pub fn run(strategy: Strategy, config: Config) !Result {
    var rt = BenchRuntime.init(config.seed);
    const worker_payloads = makeWorkerPayloads(config.seed, config.task);

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        try rt.addOperator(.{
            .id = @intCast(i + 1),
            .state = worker_payloads[i],
            .transition = operator.bitUnion,
        });
    }
    try rt.addOperator(.{ .id = coordinator_id, .transition = operator.bitUnion });
    try rt.addOperator(.{ .id = verifier_id, .transition = operator.bitUnion });

    var recorder = Recorder{ .rt = &rt, .drop_sender = config.drop_sender, .loss_per_mille = config.loss_per_mille };

    switch (strategy) {
        .broadcast_all => try runBroadcast(&rt, &recorder, worker_payloads, config.disabled_worker),
        .centralized => try runCentralized(&rt, &recorder, worker_payloads, config.disabled_worker),
        .point_to_point => try runPointToPoint(&rt, &recorder, worker_payloads, config.disabled_worker),
    }

    const verifier_index = rt.findOperator(verifier_id).?;
    const observed = rt.operators[verifier_index].state;
    const success = observed == expected_mask;

    return .{
        .strategy = strategy,
        .task = config.task,
        .seed = config.seed,
        .expected = expected_mask,
        .observed = observed,
        .worker_payloads = worker_payloads,
        .metrics = recorder.metrics(success),
    };
}

fn runBroadcast(rt: *BenchRuntime, recorder: *Recorder, payloads: [worker_count]u64, disabled: ?message.OperatorId) !void {
    var sender_index: usize = 0;
    while (sender_index < worker_count) : (sender_index += 1) {
        const sender: message.OperatorId = @intCast(sender_index + 1);
        if (disabled != null and disabled.? == sender) continue;
        var recipient_index: usize = 0;
        while (recipient_index < worker_count) : (recipient_index += 1) {
            const recipient: message.OperatorId = @intCast(recipient_index + 1);
            if (recipient != sender) try recorder.send(sender, recipient, payloads[sender_index], 1);
        }
        try recorder.send(sender, verifier_id, payloads[sender_index], 1);
    }
    try rt.run();
}

fn runCentralized(rt: *BenchRuntime, recorder: *Recorder, payloads: [worker_count]u64, disabled: ?message.OperatorId) !void {
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const sender: message.OperatorId = @intCast(i + 1);
        if (disabled != null and disabled.? == sender) continue;
        try recorder.send(sender, coordinator_id, payloads[i], 1);
    }
    try rt.run();
    const coordinator_index = rt.findOperator(coordinator_id).?;
    try recorder.send(coordinator_id, verifier_id, rt.operators[coordinator_index].state, 2);
    try rt.run();
}

fn runPointToPoint(rt: *BenchRuntime, recorder: *Recorder, payloads: [worker_count]u64, disabled: ?message.OperatorId) !void {
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const sender: message.OperatorId = @intCast(i + 1);
        if (disabled != null and disabled.? == sender) continue;
        try recorder.send(sender, verifier_id, payloads[i], 1);
    }
    try rt.run();
}

pub fn runAggregate(strategy: Strategy, task: TaskShape, first_seed: u64, runs: usize, loss_per_mille: u16) !Aggregate {
    var aggregate = Aggregate{ .strategy = strategy, .task = task, .runs = runs, .successes = 0, .total_messages_attempted = 0, .total_messages_sent = 0, .total_messages_dropped = 0, .total_bytes_sent = 0, .total_rounds = 0, .total_duplicated_payload_bits = 0 };
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const result = try run(strategy, .{ .seed = first_seed + i, .task = task, .loss_per_mille = loss_per_mille });
        if (result.metrics.success) aggregate.successes += 1;
        aggregate.total_messages_attempted += result.metrics.messages_attempted;
        aggregate.total_messages_sent += result.metrics.messages_sent;
        aggregate.total_messages_dropped += result.metrics.messages_dropped;
        aggregate.total_bytes_sent += result.metrics.bytes_sent;
        aggregate.total_rounds += result.metrics.communication_rounds;
        aggregate.total_duplicated_payload_bits += result.metrics.duplicated_payload_bits;
    }
    return aggregate;
}

test "all coordination baselines solve both task shapes without faults" {
    inline for (.{ TaskShape.partitioned, TaskShape.overlapping }) |task| {
        inline for (.{ Strategy.broadcast_all, Strategy.centralized, Strategy.point_to_point }) |strategy| {
            const result = try run(strategy, .{ .task = task });
            try std.testing.expect(result.metrics.success);
            try std.testing.expectEqual(expected_mask, result.observed);
        }
    }
}

test "coordination strategies expose expected partitioned communication tradeoffs" {
    const broadcast = try run(.broadcast_all, .{});
    const centralized = try run(.centralized, .{});
    const direct = try run(.point_to_point, .{});
    try std.testing.expectEqual(@as(usize, 25), broadcast.metrics.messages_sent);
    try std.testing.expectEqual(@as(usize, 6), centralized.metrics.messages_sent);
    try std.testing.expectEqual(@as(usize, 5), direct.metrics.messages_sent);
}

test "same seed reproduces placement and result" {
    const a = try run(.centralized, .{ .seed = 12345, .task = .overlapping });
    const b = try run(.centralized, .{ .seed = 12345, .task = .overlapping });
    try std.testing.expectEqualDeep(a, b);
}

test "different seeds change fact placement" {
    const a = try run(.point_to_point, .{ .seed = 1 });
    const b = try run(.point_to_point, .{ .seed = 2 });
    try std.testing.expect(!std.mem.eql(u64, &a.worker_payloads, &b.worker_payloads));
}

test "sender drop exposes missing information" {
    const result = try run(.point_to_point, .{ .drop_sender = 3 });
    try std.testing.expect(!result.metrics.success);
}

test "worker loss fails partitioned knowledge but overlapping survives" {
    const partitioned = try run(.point_to_point, .{ .task = .partitioned, .disabled_worker = 3 });
    const overlapping = try run(.point_to_point, .{ .task = .overlapping, .disabled_worker = 3 });
    try std.testing.expect(!partitioned.metrics.success);
    try std.testing.expect(overlapping.metrics.success);
}

test "deterministic message loss is reproducible" {
    const a = try run(.broadcast_all, .{ .seed = 77, .loss_per_mille = 300 });
    const b = try run(.broadcast_all, .{ .seed = 77, .loss_per_mille = 300 });
    try std.testing.expectEqualDeep(a, b);
}

test "aggregate runs are reproducible" {
    const a = try runAggregate(.centralized, .overlapping, 1000, 16, 100);
    const b = try runAggregate(.centralized, .overlapping, 1000, 16, 100);
    try std.testing.expectEqualDeep(a, b);
}

test "zero-loss aggregate baseline succeeds for every seed" {
    const aggregate = try runAggregate(.point_to_point, .partitioned, 0, 32, 0);
    try std.testing.expectEqual(aggregate.runs, aggregate.successes);
    try std.testing.expectEqual(@as(usize, 1000), aggregate.successRatePermille());
}
