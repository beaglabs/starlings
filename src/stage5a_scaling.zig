const std = @import("std");

pub const max_operators: usize = 1024;
pub const max_facts: usize = 1024;
pub const word_count: usize = max_facts / 64;
pub const collector_index: usize = 0;

pub const Error = error{
    InvalidPopulationSize,
    InvalidFactCount,
    InvalidRedundancy,
    InvalidBandwidth,
    InvalidMaxRounds,
};

pub const TopologyKind = enum {
    ring,
    complete,
    grid,

    pub fn name(self: TopologyKind) []const u8 {
        return switch (self) {
            .ring => "ring",
            .complete => "complete",
            .grid => "grid",
        };
    }
};

pub const PolicyKind = enum {
    round_robin,
    seeded,
    novel_first,

    pub fn name(self: PolicyKind) []const u8 {
        return switch (self) {
            .round_robin => "round_robin",
            .seeded => "seeded",
            .novel_first => "novel_first",
        };
    }
};

pub const BitSet = struct {
    words: [word_count]u64 = [_]u64{0} ** word_count,

    pub fn set(self: *BitSet, index: usize) void {
        std.debug.assert(index < max_facts);
        self.words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
    }

    pub fn has(self: *const BitSet, index: usize) bool {
        std.debug.assert(index < max_facts);
        return (self.words[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
    }

    pub fn clear(self: *BitSet) void {
        self.words = [_]u64{0} ** word_count;
    }

    pub fn unionWith(self: *BitSet, other: BitSet) void {
        var i: usize = 0;
        while (i < word_count) : (i += 1) {
            self.words[i] |= other.words[i];
        }
    }

    pub fn intersectCount(self: BitSet, other: BitSet) usize {
        var result: usize = 0;
        var i: usize = 0;
        while (i < word_count) : (i += 1) {
            result += @as(usize, @intCast(@popCount(self.words[i] & other.words[i])));
        }
        return result;
    }

    pub fn count(self: BitSet, fact_count: usize) usize {
        var result: usize = 0;
        var i: usize = 0;
        while (i < fact_count) : (i += 1) {
            if (self.has(i)) result += 1;
        }
        return result;
    }

    pub fn containsAll(self: BitSet, fact_count: usize) bool {
        var i: usize = 0;
        while (i < fact_count) : (i += 1) {
            if (!self.has(i)) return false;
        }
        return true;
    }

    pub fn isSubsetOf(self: BitSet, other: BitSet) bool {
        var i: usize = 0;
        while (i < word_count) : (i += 1) {
            if ((self.words[i] & ~other.words[i]) != 0) return false;
        }
        return true;
    }

    pub fn eql(a: BitSet, b: BitSet) bool {
        return std.mem.eql(u64, &a.words, &b.words);
    }
};

pub const State = struct {
    knowledge: BitSet = .{},
    sent: BitSet = .{},
    cursor: u16 = 0,
};

pub const Action = struct {
    facts: BitSet,
    selected: u16,
    next_cursor: u16,
    reset_sent: bool = false,
};

pub const Config = struct {
    population_size: usize,
    fact_count: usize,
    topology: TopologyKind,
    redundancy: usize,
    bandwidth: usize,
    policy: PolicyKind,
    seed: u64 = 0,
    max_rounds: u32 = 4096,

    pub fn validate(self: Config) Error!void {
        if (self.population_size < 2 or self.population_size > max_operators) {
            return error.InvalidPopulationSize;
        }
        if (self.fact_count < 1 or self.fact_count > max_facts) {
            return error.InvalidFactCount;
        }
        if (self.redundancy < 1 or self.redundancy > self.population_size) {
            return error.InvalidRedundancy;
        }
        if (self.bandwidth < 1 or self.bandwidth > self.fact_count) {
            return error.InvalidBandwidth;
        }
        if (self.max_rounds == 0) return error.InvalidMaxRounds;
    }
};

pub const Result = struct {
    config: Config,
    success: bool,
    rounds: u32,
    diameter: usize,
    edges: usize,
    collector_initial_facts: usize,
    collector_final_facts: usize,
    policy_calls: u64,
    actions_proposed: u64,
    rejected_actions: u64,
    messages: u64,
    communication_units: u64,
    useful_deliveries: u64,
    duplicate_deliveries: u64,
    violations: u64,

    pub fn usefulPerThousandUnits(self: Result) u64 {
        if (self.communication_units == 0) return 0;
        return (self.useful_deliveries * 1000) / self.communication_units;
    }
};

pub fn run(config: Config) Error!Result {
    try config.validate();

    var states = [_]State{.{}} ** max_operators;
    initializeStates(&states, config);

    const initial_facts = states[collector_index].knowledge.count(config.fact_count);
    var result = Result{
        .config = config,
        .success = states[collector_index].knowledge.containsAll(config.fact_count),
        .rounds = 0,
        .diameter = topologyDiameter(config.topology, config.population_size),
        .edges = topologyEdges(config.topology, config.population_size),
        .collector_initial_facts = initial_facts,
        .collector_final_facts = initial_facts,
        .policy_calls = 0,
        .actions_proposed = 0,
        .rejected_actions = 0,
        .messages = 0,
        .communication_units = 0,
        .useful_deliveries = 0,
        .duplicate_deliveries = 0,
        .violations = 0,
    };

    if (result.success) return result;

    var round: u32 = 1;
    while (round <= config.max_rounds) : (round += 1) {
        var snapshot = states;
        var next = snapshot;
        var actions = [_]?Action{null} ** max_operators;
        var received = [_]BitSet{.{}} ** max_operators;

        var operator_index: usize = 0;
        while (operator_index < config.population_size) : (operator_index += 1) {
            result.policy_calls +%= 1;
            if (decide(
                config.policy,
                snapshot[operator_index],
                operator_index,
                round,
                config,
            )) |action| {
                actions[operator_index] = action;
                result.actions_proposed +%= 1;
            }
        }

        var sender: usize = 0;
        while (sender < config.population_size) : (sender += 1) {
            const action = actions[sender] orelse continue;

            if (!validateAction(action, snapshot[sender], config)) {
                result.rejected_actions +%= 1;
                result.violations +%= 1;
                continue;
            }

            if (action.reset_sent) next[sender].sent.clear();
            next[sender].sent.unionWith(action.facts);
            next[sender].cursor = action.next_cursor;

            switch (config.topology) {
                .ring => {
                    const left = (sender + config.population_size - 1) % config.population_size;
                    const right = (sender + 1) % config.population_size;
                    deliver(
                        left,
                        action,
                        snapshot[left].knowledge,
                        &received[left],
                        &result,
                    );
                    if (right != left) {
                        deliver(
                            right,
                            action,
                            snapshot[right].knowledge,
                            &received[right],
                            &result,
                        );
                    }
                },
                .complete => {
                    var recipient: usize = 0;
                    while (recipient < config.population_size) : (recipient += 1) {
                        if (recipient == sender) continue;
                        deliver(
                            recipient,
                            action,
                            snapshot[recipient].knowledge,
                            &received[recipient],
                            &result,
                        );
                    }
                },
                .grid => {
                    const width = gridWidth(config.population_size);
                    const row = sender / width;
                    const col = sender % width;

                    if (col > 0) {
                        const recipient = sender - 1;
                        deliver(recipient, action, snapshot[recipient].knowledge, &received[recipient], &result);
                    }
                    if (col + 1 < width and sender + 1 < config.population_size) {
                        const recipient = sender + 1;
                        if (recipient / width == row) {
                            deliver(recipient, action, snapshot[recipient].knowledge, &received[recipient], &result);
                        }
                    }
                    if (sender >= width) {
                        const recipient = sender - width;
                        deliver(recipient, action, snapshot[recipient].knowledge, &received[recipient], &result);
                    }
                    if (sender + width < config.population_size) {
                        const recipient = sender + width;
                        deliver(recipient, action, snapshot[recipient].knowledge, &received[recipient], &result);
                    }
                },
            }
        }

        operator_index = 0;
        while (operator_index < config.population_size) : (operator_index += 1) {
            next[operator_index].knowledge.unionWith(received[operator_index]);
        }

        states = next;
        result.rounds = round;
        result.collector_final_facts = states[collector_index].knowledge.count(config.fact_count);

        if (states[collector_index].knowledge.containsAll(config.fact_count)) {
            result.success = true;
            break;
        }
    }

    std.debug.assert(
        result.communication_units ==
            result.useful_deliveries + result.duplicate_deliveries,
    );
    return result;
}

pub fn initializeStates(states: *[max_operators]State, config: Config) void {
    var i: usize = 0;
    while (i < max_operators) : (i += 1) states[i] = .{};

    var fact: usize = 0;
    while (fact < config.fact_count) : (fact += 1) {
        const base = @as(usize, @intCast(mix64(
            config.seed ^ @as(u64, @intCast(fact)) ^ 0x535441524c494e47,
        ) % @as(u64, @intCast(config.population_size))));

        var step: usize = 1;
        if (config.population_size > 2) {
            step = 1 + @as(usize, @intCast(mix64(
                config.seed ^ @as(u64, @intCast(fact)) ^ 0x444946465553494f,
            ) % @as(u64, @intCast(config.population_size - 1))));
            while (gcd(step, config.population_size) != 1) {
                step += 1;
                if (step >= config.population_size) step = 1;
            }
        }

        var copy: usize = 0;
        while (copy < config.redundancy) : (copy += 1) {
            const operator_index = (base + copy * step) % config.population_size;
            states[operator_index].knowledge.set(fact);
        }
    }
}

fn decide(
    policy: PolicyKind,
    state: State,
    operator_index: usize,
    round: u32,
    config: Config,
) ?Action {
    if (state.knowledge.count(config.fact_count) == 0) return null;

    return switch (policy) {
        .round_robin => selectRoundRobin(state, config, false),
        .seeded => selectSeeded(state, operator_index, round, config),
        .novel_first => blk: {
            var candidate = state;
            var has_unsent = false;
            var i: usize = 0;
            while (i < config.fact_count) : (i += 1) {
                if (state.knowledge.has(i) and !state.sent.has(i)) {
                    has_unsent = true;
                    break;
                }
            }

            if (!has_unsent) {
                candidate.sent.clear();
                var action = selectRoundRobin(candidate, config, true) orelse break :blk null;
                action.reset_sent = true;
                break :blk action;
            }

            break :blk selectNovel(state, config);
        },
    };
}

fn selectRoundRobin(state: State, config: Config, reset_sent: bool) ?Action {
    var selected = BitSet{};
    var selected_count: usize = 0;
    var scanned: usize = 0;
    var cursor: usize = @as(usize, state.cursor) % config.fact_count;

    while (scanned < config.fact_count and selected_count < config.bandwidth) : (scanned += 1) {
        const fact = (cursor + scanned) % config.fact_count;
        if (!state.knowledge.has(fact)) continue;
        selected.set(fact);
        selected_count += 1;
        cursor = (fact + 1) % config.fact_count;
        scanned = 0;
    }

    if (selected_count == 0) return null;
    return .{
        .facts = selected,
        .selected = @intCast(selected_count),
        .next_cursor = @intCast(cursor),
        .reset_sent = reset_sent,
    };
}

fn selectNovel(state: State, config: Config) ?Action {
    var selected = BitSet{};
    var selected_count: usize = 0;
    const start: usize = @as(usize, state.cursor) % config.fact_count;
    var offset: usize = 0;
    var next_cursor = start;

    while (offset < config.fact_count and selected_count < config.bandwidth) : (offset += 1) {
        const fact = (start + offset) % config.fact_count;
        if (!state.knowledge.has(fact) or state.sent.has(fact)) continue;
        selected.set(fact);
        selected_count += 1;
        next_cursor = (fact + 1) % config.fact_count;
    }

    if (selected_count == 0) return null;
    return .{
        .facts = selected,
        .selected = @intCast(selected_count),
        .next_cursor = @intCast(next_cursor),
    };
}

fn selectSeeded(
    state: State,
    operator_index: usize,
    round: u32,
    config: Config,
) ?Action {
    var selected = BitSet{};
    var selected_count: usize = 0;
    const salt =
        config.seed ^
        (@as(u64, @intCast(operator_index)) *% 0x9e3779b97f4a7c15) ^
        (@as(u64, round) *% 0xbf58476d1ce4e5b9);
    const start = @as(usize, @intCast(mix64(salt) % @as(u64, @intCast(config.fact_count))));

    var step: usize = 1;
    if (config.fact_count > 2) {
        step = 1 + @as(usize, @intCast(
            mix64(salt ^ 0x94d049bb133111eb) %
                @as(u64, @intCast(config.fact_count - 1)),
        ));
        while (gcd(step, config.fact_count) != 1) {
            step += 1;
            if (step >= config.fact_count) step = 1;
        }
    }

    var offset: usize = 0;
    while (offset < config.fact_count and selected_count < config.bandwidth) : (offset += 1) {
        const fact = (start + offset * step) % config.fact_count;
        if (!state.knowledge.has(fact)) continue;
        selected.set(fact);
        selected_count += 1;
    }

    if (selected_count == 0) return null;
    return .{
        .facts = selected,
        .selected = @intCast(selected_count),
        .next_cursor = state.cursor,
    };
}

fn validateAction(action: Action, state: State, config: Config) bool {
    const selected_count = action.facts.count(config.fact_count);
    if (selected_count == 0) return false;
    if (selected_count != @as(usize, action.selected)) return false;
    if (selected_count > config.bandwidth) return false;
    return action.facts.isSubsetOf(state.knowledge);
}

fn deliver(
    recipient: usize,
    action: Action,
    snapshot_knowledge: BitSet,
    received: *BitSet,
    result: *Result,
) void {
    _ = recipient;
    result.messages +%= 1;
    result.communication_units +%= action.selected;

    var fact: usize = 0;
    while (fact < result.config.fact_count) : (fact += 1) {
        if (!action.facts.has(fact)) continue;

        if (!snapshot_knowledge.has(fact) and !received.has(fact)) {
            result.useful_deliveries +%= 1;
        } else {
            result.duplicate_deliveries +%= 1;
        }
        received.set(fact);
    }
}

pub fn topologyDegree(kind: TopologyKind, operator_index: usize, population_size: usize) usize {
    std.debug.assert(operator_index < population_size);
    return switch (kind) {
        .ring => if (population_size == 2) 1 else 2,
        .complete => population_size - 1,
        .grid => blk: {
            const width = gridWidth(population_size);
            const row = operator_index / width;
            const col = operator_index % width;
            var degree: usize = 0;
            if (col > 0) degree += 1;
            if (col + 1 < width and operator_index + 1 < population_size and (operator_index + 1) / width == row) degree += 1;
            if (operator_index >= width) degree += 1;
            if (operator_index + width < population_size) degree += 1;
            break :blk degree;
        },
    };
}

pub fn topologyEdges(kind: TopologyKind, population_size: usize) usize {
    return switch (kind) {
        .ring => if (population_size == 2) 1 else population_size,
        .complete => (population_size * (population_size - 1)) / 2,
        .grid => blk: {
            var edges: usize = 0;
            var i: usize = 0;
            while (i < population_size) : (i += 1) {
                const width = gridWidth(population_size);
                const row = i / width;
                const col = i % width;
                if (col + 1 < width and i + 1 < population_size and (i + 1) / width == row) edges += 1;
                if (i + width < population_size) edges += 1;
            }
            break :blk edges;
        },
    };
}

pub fn topologyDiameter(kind: TopologyKind, population_size: usize) usize {
    return switch (kind) {
        .ring => population_size / 2,
        .complete => 1,
        .grid => blk: {
            const width = gridWidth(population_size);
            if (population_size <= width) break :blk population_size - 1;
            const rows = (population_size + width - 1) / width;
            break :blk (rows - 1) + (width - 1);
        },
    };
}

pub fn gridWidth(population_size: usize) usize {
    var width: usize = 1;
    while (width * width < population_size) : (width += 1) {}
    return width;
}

fn gcd(a_input: usize, b_input: usize) usize {
    var a = a_input;
    var b = b_input;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

fn mix64(input: u64) u64 {
    var z = input +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

test "initial placement gives every fact exactly the requested redundancy" {
    const config = Config{
        .population_size = 17,
        .fact_count = 31,
        .topology = .ring,
        .redundancy = 4,
        .bandwidth = 2,
        .policy = .round_robin,
        .seed = 42,
    };
    var states = [_]State{.{}} ** max_operators;
    initializeStates(&states, config);

    var fact: usize = 0;
    while (fact < config.fact_count) : (fact += 1) {
        var copies: usize = 0;
        var operator_index: usize = 0;
        while (operator_index < config.population_size) : (operator_index += 1) {
            if (states[operator_index].knowledge.has(fact)) copies += 1;
        }
        try std.testing.expectEqual(config.redundancy, copies);
    }
}

test "topology metadata matches known small graphs" {
    try std.testing.expectEqual(@as(usize, 5), topologyEdges(.ring, 5));
    try std.testing.expectEqual(@as(usize, 2), topologyDiameter(.ring, 5));
    try std.testing.expectEqual(@as(usize, 10), topologyEdges(.complete, 5));
    try std.testing.expectEqual(@as(usize, 1), topologyDiameter(.complete, 5));
    try std.testing.expectEqual(@as(usize, 7), topologyEdges(.grid, 6));
    try std.testing.expectEqual(@as(usize, 3), topologyDiameter(.grid, 6));
}

test "ring diffusion converges without global policy state" {
    const result = try run(.{
        .population_size = 10,
        .fact_count = 10,
        .topology = .ring,
        .redundancy = 1,
        .bandwidth = 2,
        .policy = .round_robin,
        .seed = 7,
        .max_rounds = 128,
    });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 10), result.collector_final_facts);
    try std.testing.expectEqual(
        result.communication_units,
        result.useful_deliveries + result.duplicate_deliveries,
    );
    try std.testing.expectEqual(@as(u64, 0), result.violations);
}

test "complete topology converges for each local policy family" {
    inline for (.{ PolicyKind.round_robin, PolicyKind.seeded, PolicyKind.novel_first }) |policy| {
        const result = try run(.{
            .population_size = 16,
            .fact_count = 16,
            .topology = .complete,
            .redundancy = 1,
            .bandwidth = 1,
            .policy = policy,
            .seed = 9,
            .max_rounds = 64,
        });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u64, 0), result.violations);
    }
}

test "same scaling configuration is exactly reproducible" {
    const config = Config{
        .population_size = 20,
        .fact_count = 20,
        .topology = .grid,
        .redundancy = 2,
        .bandwidth = 2,
        .policy = .seeded,
        .seed = 12345,
        .max_rounds = 128,
    };
    const a = try run(config);
    const b = try run(config);
    try std.testing.expectEqualDeep(a, b);
}

test "configuration validation rejects impossible dimensions" {
    try std.testing.expectError(error.InvalidPopulationSize, Config{
        .population_size = 1,
        .fact_count = 1,
        .topology = .ring,
        .redundancy = 1,
        .bandwidth = 1,
        .policy = .round_robin,
    }.validate());

    try std.testing.expectError(error.InvalidRedundancy, Config{
        .population_size = 5,
        .fact_count = 5,
        .topology = .ring,
        .redundancy = 6,
        .bandwidth = 1,
        .policy = .round_robin,
    }.validate());
}
