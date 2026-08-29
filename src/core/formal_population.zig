const std = @import("std");

pub const OperatorId = u32;

pub const Outcome = enum {
    running,
    success,
    failure,
    exhausted,
};

pub const Cost = struct {
    communication: u64 = 0,
    computation: u64 = 0,
    violations: u64 = 0,

    pub fn add(self: *Cost, other: Cost) void {
        self.communication +%= other.communication;
        self.computation +%= other.computation;
        self.violations +%= other.violations;
    }
};

pub const RoundEffect = struct {
    cost: Cost = .{},
    rejected_actions: usize = 0,
};

pub const SimulationResult = struct {
    outcome: Outcome,
    rounds: u32,
    cost: Cost,
    policy_calls: usize,
    actions_proposed: usize,
    rejected_actions: usize,
};

pub const Error = error{
    OperatorCapacityExceeded,
    DuplicateOperator,
    UnknownOperator,
    SelfEdge,
};

pub fn Topology(comptime max_operators: usize) type {
    return struct {
        const Self = @This();

        edges: [max_operators][max_operators]bool,

        pub fn init() Self {
            return .{
                .edges = std.mem.zeroes([max_operators][max_operators]bool),
            };
        }

        pub fn connect(self: *Self, a: usize, b: usize) Error!void {
            if (a == b) return error.SelfEdge;
            if (a >= max_operators or b >= max_operators) return error.UnknownOperator;
            self.edges[a][b] = true;
            self.edges[b][a] = true;
        }

        pub fn disconnect(self: *Self, a: usize, b: usize) void {
            if (a >= max_operators or b >= max_operators or a == b) return;
            self.edges[a][b] = false;
            self.edges[b][a] = false;
        }

        pub fn isNeighbor(self: *const Self, a: usize, b: usize) bool {
            if (a >= max_operators or b >= max_operators) return false;
            return self.edges[a][b];
        }

        pub fn degree(self: *const Self, operator_index: usize, operator_count: usize) usize {
            if (operator_index >= operator_count or operator_count > max_operators) return 0;

            var result: usize = 0;
            var i: usize = 0;
            while (i < operator_count) : (i += 1) {
                if (self.edges[operator_index][i]) result += 1;
            }
            return result;
        }

        pub fn ring(operator_count: usize) Error!Self {
            if (operator_count > max_operators) return error.OperatorCapacityExceeded;

            var topology = Self.init();
            if (operator_count < 2) return topology;

            var i: usize = 0;
            while (i < operator_count) : (i += 1) {
                const next = (i + 1) % operator_count;
                if (!topology.isNeighbor(i, next)) try topology.connect(i, next);
            }
            return topology;
        }
    };
}

pub fn Population(comptime State: type, comptime max_operators: usize) type {
    return struct {
        const Self = @This();
        pub const TopologyType = Topology(max_operators);

        ids: [max_operators]OperatorId = [_]OperatorId{0} ** max_operators,
        states: [max_operators]State = undefined,
        active: [max_operators]bool = [_]bool{false} ** max_operators,
        operator_count: usize = 0,
        topology: TopologyType = TopologyType.init(),

        pub fn addOperator(self: *Self, id: OperatorId, initial_state: State) Error!usize {
            if (self.indexOf(id) != null) return error.DuplicateOperator;
            if (self.operator_count >= max_operators) return error.OperatorCapacityExceeded;

            const index = self.operator_count;
            self.ids[index] = id;
            self.states[index] = initial_state;
            self.active[index] = true;
            self.operator_count += 1;
            return index;
        }

        pub fn indexOf(self: *const Self, id: OperatorId) ?usize {
            var i: usize = 0;
            while (i < self.operator_count) : (i += 1) {
                if (self.ids[i] == id) return i;
            }
            return null;
        }

        pub fn setActive(self: *Self, id: OperatorId, is_active: bool) Error!void {
            const index = self.indexOf(id) orelse return error.UnknownOperator;
            self.active[index] = is_active;
        }

        pub fn connect(self: *Self, a_id: OperatorId, b_id: OperatorId) Error!void {
            const a = self.indexOf(a_id) orelse return error.UnknownOperator;
            const b = self.indexOf(b_id) orelse return error.UnknownOperator;
            try self.topology.connect(a, b);
        }

        pub fn activeCount(self: *const Self) usize {
            var result: usize = 0;
            var i: usize = 0;
            while (i < self.operator_count) : (i += 1) {
                if (self.active[i]) result += 1;
            }
            return result;
        }
    };
}

pub fn Policy(comptime Observation: type, comptime Action: type) type {
    return struct {
        const Self = @This();

        context: ?*const anyopaque = null,
        decide_fn: *const fn (?*const anyopaque, Observation) ?Action,

        pub fn decide(self: Self, observation: Observation) ?Action {
            return self.decide_fn(self.context, observation);
        }
    };
}

/// Generic synchronous population simulator.
///
/// Spec supplies the domain semantics:
/// - State: local operator state X
/// - Observation: policy-visible local observation
/// - Action: emitted coordination action/message M
/// - Context: immutable experiment/environment parameters
/// - observe: local observation map
/// - apply: deterministic transition/admissibility logic F,C
/// - evaluate: global observable/objective Phi
///
/// Per-operator Policy values supply Pi. Cost supplies a common J-like
/// measurement vector. Language models are not part of this interface.
pub fn Simulator(comptime Spec: type, comptime max_operators: usize) type {
    const State = Spec.State;
    const Observation = Spec.Observation;
    const Action = Spec.Action;
    const Context = Spec.Context;
    const PopulationType = Population(State, max_operators);
    const PolicyType = Policy(Observation, Action);
    const TopologyType = Topology(max_operators);

    return struct {
        const Self = @This();

        population: PopulationType = .{},
        policies: [max_operators]PolicyType = undefined,
        context: Context,
        round: u32 = 0,
        cost: Cost = .{},
        policy_calls: usize = 0,
        actions_proposed: usize = 0,
        rejected_actions: usize = 0,

        pub fn init(context: Context) Self {
            return .{ .context = context };
        }

        pub fn addOperator(
            self: *Self,
            id: OperatorId,
            initial_state: State,
            policy: PolicyType,
        ) Error!usize {
            const index = try self.population.addOperator(id, initial_state);
            self.policies[index] = policy;
            return index;
        }

        pub fn setTopology(self: *Self, topology: TopologyType) void {
            self.population.topology = topology;
        }

        pub fn connect(self: *Self, a_id: OperatorId, b_id: OperatorId) Error!void {
            try self.population.connect(a_id, b_id);
        }

        pub fn step(self: *Self) Outcome {
            self.round +%= 1;

            var snapshot: [max_operators]State = undefined;
            var i: usize = 0;
            while (i < self.population.operator_count) : (i += 1) {
                snapshot[i] = self.population.states[i];
            }

            var actions = [_]?Action{null} ** max_operators;
            i = 0;
            while (i < self.population.operator_count) : (i += 1) {
                if (!self.population.active[i]) continue;

                const observation = Spec.observe(
                    &self.context,
                    &snapshot,
                    &self.population.topology,
                    self.population.operator_count,
                    i,
                    self.round,
                );
                self.policy_calls += 1;
                self.cost.computation +%= 1;

                if (self.policies[i].decide(observation)) |action| {
                    actions[i] = action;
                    self.actions_proposed += 1;
                }
            }

            const effect = Spec.apply(
                &self.context,
                &snapshot,
                &self.population.topology,
                self.population.operator_count,
                self.population.active,
                actions,
                &self.population.states,
            );
            self.cost.add(effect.cost);
            self.rejected_actions += effect.rejected_actions;

            return Spec.evaluate(
                &self.context,
                &self.population.states,
                self.population.operator_count,
                self.round,
            );
        }

        pub fn run(self: *Self, max_rounds: u32) SimulationResult {
            var outcome = Spec.evaluate(
                &self.context,
                &self.population.states,
                self.population.operator_count,
                self.round,
            );

            var completed: u32 = 0;
            while (outcome == .running and completed < max_rounds) : (completed += 1) {
                outcome = self.step();
            }

            if (outcome == .running) outcome = .exhausted;
            return self.result(outcome);
        }

        pub fn result(self: *const Self, outcome: Outcome) SimulationResult {
            return .{
                .outcome = outcome,
                .rounds = self.round,
                .cost = self.cost,
                .policy_calls = self.policy_calls,
                .actions_proposed = self.actions_proposed,
                .rejected_actions = self.rejected_actions,
            };
        }
    };
}

test "ring topology is symmetric and bounded" {
    const T = Topology(5);
    const topology = try T.ring(5);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(@as(usize, 2), topology.degree(i, 5));

        var j: usize = 0;
        while (j < 5) : (j += 1) {
            try std.testing.expectEqual(
                topology.isNeighbor(i, j),
                topology.isNeighbor(j, i),
            );
        }
    }
}

test "population supports heterogeneous policy functions and activation" {
    const Observation = struct { value: u8 };
    const Action = struct { value: u8 };
    const P = Population(u8, 3);
    const PolicyType = Policy(Observation, Action);

    const Fixtures = struct {
        fn identity(_: ?*const anyopaque, observation: Observation) ?Action {
            return .{ .value = observation.value };
        }

        fn suppress(_: ?*const anyopaque, _: Observation) ?Action {
            return null;
        }
    };

    var population = P{};
    _ = try population.addOperator(1, 3);
    _ = try population.addOperator(2, 7);
    try population.connect(1, 2);
    try population.setActive(2, false);

    try std.testing.expectEqual(@as(usize, 2), population.operator_count);
    try std.testing.expectEqual(@as(usize, 1), population.activeCount());
    try std.testing.expect(population.topology.isNeighbor(0, 1));

    const identity = PolicyType{ .decide_fn = Fixtures.identity };
    const suppress = PolicyType{ .decide_fn = Fixtures.suppress };
    try std.testing.expectEqual(@as(u8, 9), identity.decide(.{ .value = 9 }).?.value);
    try std.testing.expect(suppress.decide(.{ .value = 9 }) == null);
}

test "cost vectors compose deterministically" {
    var cost = Cost{ .communication = 2, .computation = 3, .violations = 1 };
    cost.add(.{ .communication = 5, .computation = 7, .violations = 2 });

    try std.testing.expectEqual(@as(u64, 7), cost.communication);
    try std.testing.expectEqual(@as(u64, 10), cost.computation);
    try std.testing.expectEqual(@as(u64, 3), cost.violations);
}
