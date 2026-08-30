const std = @import("std");
const core = @import("core_types.zig");
const reg = @import("registry.zig");
const eligibility = @import("eligibility.zig");
const output_state = @import("output_state.zig");
const event_log = @import("event_log.zig");
const data_plane = @import("data_plane.zig");
const content_id = @import("../core/content_id.zig");

pub fn Runner(
    comptime max_variables: usize,
    comptime max_invariants: usize,
    comptime max_operators: usize,
    comptime max_claims: usize,
) type {
    const RegistryType = reg.Registry(max_variables, max_invariants, max_operators);
    const StateType = reg.ContextState(max_variables, max_invariants);
    const MaterializedType = output_state.MaterializedState(max_variables);
    const ClaimStoreType = output_state.ClaimStore(max_claims);
    const max_events = 64 + max_claims * 8 + max_operators * 16 + max_invariants * 8;
    const EventLogType = event_log.EventLog(max_events);

    return struct {
        const Self = @This();

        pub const max_event_records: usize = max_events;
        pub const RunEventLog = EventLogType;

        pub const Observation = struct {
            runner: *const Self,
            operator_index: usize,

            pub fn round(self: Observation) u32 {
                return self.runner.round;
            }

            pub fn operatorId(self: Observation) core.OperatorId {
                return self.runner.registry.operators[self.operator_index].manifest.id;
            }

            pub fn activationEpoch(self: Observation) u64 {
                return self.runner.executors[self.operator_index].activation_epoch;
            }

            pub fn status(self: Observation, id: core.VariableId) ?core.EpistemicStatus {
                if (!self.canRead(id)) return null;
                const index = self.runner.registry.variableIndex(id) orelse return null;
                return self.runner.state.variables[index].status;
            }

            pub fn value(self: Observation, id: core.VariableId) ?core.Value {
                if (!self.canRead(id)) return null;
                const index = self.runner.registry.variableIndex(id) orelse return null;
                return self.runner.state.variables[index].value;
            }

            pub fn invariantStatus(self: Observation, id: core.InvariantId) ?core.InvariantStatus {
                if (!self.canReadInvariant(id)) return null;
                const invariant_cell = self.runner.state.invariantCell(&self.runner.registry, id) orelse return null;
                return invariant_cell.status;
            }

            fn canRead(self: Observation, id: core.VariableId) bool {
                const op = self.runner.registry.operators[self.operator_index];
                for (op.manifest.requires_variables) |candidate| if (candidate == id) return true;
                for (op.eligibility.terms) |term| {
                    switch (term) {
                        .variable_known, .variable_resolved => |candidate| if (candidate == id) return true,
                        .invariant_satisfied => {},
                    }
                }
                return false;
            }

            fn canReadInvariant(self: Observation, id: core.InvariantId) bool {
                const op = self.runner.registry.operators[self.operator_index];
                for (op.manifest.requires_invariants) |candidate| if (candidate == id) return true;
                for (op.eligibility.terms) |term| {
                    switch (term) {
                        .invariant_satisfied => |candidate| if (candidate == id) return true,
                        else => {},
                    }
                }
                return false;
            }
        };

        pub const ExecuteFn = *const fn (?*const anyopaque, Observation) anyerror!core.OperatorOutput;

        const Executor = struct {
            context: ?*const anyopaque = null,
            execute_fn: ExecuteFn,
            has_activated: bool = false,
            activation_epoch: u64 = 0,
            last_input_fingerprint: core.ContentId = content_id.zero,
            last_settled_epoch: u64 = 0,
        };

        pub const Explanation = struct {
            status: core.EpistemicStatus,
            value: ?core.Value,
            claim_id: core.ContentId,
            accepted_claims: usize,
            conflict_count: usize,
        };

        pub const SchedulerSnapshot = struct {
            outcome: core.ResultOutcome,
            round: u32,
            eligible_operators: usize,
            pending_activations: usize,
            pending_approvals: usize,
        };

        pub const ExecutionResult = struct {
            runner: *const Self,
            summary: core.Result,

            pub fn value(self: ExecutionResult, id: core.VariableId) ?core.Value {
                const index = self.runner.registry.variableIndex(id) orelse return null;
                return self.runner.state.variables[index].value;
            }

            pub fn status(self: ExecutionResult, id: core.VariableId) ?core.EpistemicStatus {
                const index = self.runner.registry.variableIndex(id) orelse return null;
                return self.runner.state.variables[index].status;
            }

            pub fn explain(self: ExecutionResult, id: core.VariableId) ?Explanation {
                const cell = self.runner.materialized.cell(&self.runner.registry, id) orelse return null;
                return .{
                    .status = cell.status,
                    .value = cell.value,
                    .claim_id = cell.claim_id,
                    .accepted_claims = cell.accepted_claims,
                    .conflict_count = cell.conflict_count,
                };
            }
        };

        registry: RegistryType = .{},
        state: StateType = .{},
        materialized: MaterializedType = .{},
        claims: ClaimStoreType = .{},
        events: EventLogType = .{},
        executors: [max_operators]Executor = undefined,
        executor_count: usize = 0,
        targets: []const core.VariableId = &.{},
        seed: u64 = 0,
        round: u32 = 0,
        accepted_claims: usize = 0,
        rejected_claims: usize = 0,
        proposed_actions: usize = 0,
        run_started_logged: bool = false,
        configuration_locked: bool = false,
        event_sink: ?event_log.EventSink = null,
        event_sink_failed: bool = false,

        pub fn init(seed: u64, targets: []const core.VariableId) Self {
            return .{ .seed = seed, .targets = targets };
        }

        pub fn addVariable(self: *Self, schema: reg.VariableSchema) !void {
            if (self.configuration_locked) return error.RunConfigurationLocked;
            try self.registry.addVariable(schema);
        }

        pub fn addInvariant(self: *Self, invariant: core.Invariant) !void {
            if (self.configuration_locked) return error.RunConfigurationLocked;
            try self.registry.addInvariant(invariant);
        }

        pub fn addOperator(
            self: *Self,
            registered: reg.RegisteredOperator,
            context: ?*const anyopaque,
            execute_fn: ExecuteFn,
        ) !void {
            if (self.configuration_locked) return error.RunConfigurationLocked;
            if (self.executor_count >= max_operators) return error.RegistryCapacityExceeded;
            try self.registry.addOperator(registered);
            self.executors[self.executor_count] = .{
                .context = context,
                .execute_fn = execute_fn,
            };
            self.executor_count += 1;
        }

        pub fn addReplayOperator(self: *Self, registered: reg.RegisteredOperator) !void {
            try self.addOperator(registered, null, replayOnlyExecute);
        }

        pub fn setEventSink(self: *Self, sink: event_log.EventSink) !void {
            if (self.run_started_logged or self.events.len != 0) return error.RunAlreadyStarted;
            if (self.event_sink != null) return error.EventSinkAlreadyConfigured;
            self.event_sink = sink;
        }

        fn replayOnlyExecute(_: ?*const anyopaque, _: Observation) anyerror!core.OperatorOutput {
            return error.ReplayOnlyOperatorExecuted;
        }

        pub fn seedVariable(
            self: *Self,
            id: core.VariableId,
            status: core.EpistemicStatus,
            value: ?core.Value,
            confidence_permille: u16,
        ) !core.ContentId {
            const claim: core.Claim = .{
                .variable = id,
                .status = status,
                .value = value,
                .confidence_permille = confidence_permille,
                .source_operator = 0,
            };
            try claim.validateShape();

            const variable_index = self.registry.variableIndex(id) orelse return error.UnknownVariable;
            if (value) |typed_value| {
                if (typed_value.kind() != self.registry.variables[variable_index].variable.kind) {
                    return error.VariableTypeMismatch;
                }
            }

            try self.ensureRunStarted();
            try self.events.ensureCapacity(1);
            const claim_id = try self.claims.append(claim);
            try self.materialized.applyClaim(
                &self.registry,
                &self.state,
                claim,
                claim_id,
                self.round,
            );
            self.accepted_claims += 1;
            _ = try self.appendRuntimeEvent(.{ .observation_added = .{
                .round = self.round,
                .claim = claim,
                .claim_id = claim_id,
            } });
            return claim_id;
        }

        pub fn step(self: *Self) !bool {
            try self.ensureRunStarted();
            const chosen_id = self.nextPendingOperatorId() orelse return false;
            const chosen_index = self.registry.operatorIndex(chosen_id).?;
            const input_fingerprint = self.activationFingerprint(chosen_index);

            try self.events.ensureCapacity(2);
            self.round +%= 1;
            self.executors[chosen_index].has_activated = true;
            self.executors[chosen_index].activation_epoch +%= 1;
            self.executors[chosen_index].last_input_fingerprint = input_fingerprint;
            const activation_epoch = self.executors[chosen_index].activation_epoch;

            _ = try self.appendRuntimeEvent(.{ .operator_started = .{
                .round = self.round,
                .operator = chosen_id,
                .activation_epoch = activation_epoch,
                .input_fingerprint = input_fingerprint,
            } });

            const output = self.executors[chosen_index].execute_fn(
                self.executors[chosen_index].context,
                .{ .runner = self, .operator_index = chosen_index },
            ) catch |err| {
                self.executors[chosen_index].last_settled_epoch = activation_epoch;
                _ = try self.appendRuntimeEvent(.{ .operator_failed = .{
                    .round = self.round,
                    .operator = chosen_id,
                    .activation_epoch = activation_epoch,
                    .kind = classifyExecutionFailure(err),
                } });
                return err;
            };

            output_state.validateOutput(
                &self.registry,
                self.registry.operators[chosen_index].manifest,
                &output,
            ) catch |err| {
                self.rejected_claims += output.variable_claim_count;
                self.executors[chosen_index].last_settled_epoch = activation_epoch;
                _ = try self.appendRuntimeEvent(.{ .operator_failed = .{
                    .round = self.round,
                    .operator = chosen_id,
                    .activation_epoch = activation_epoch,
                    .kind = .validation,
                    .rejected_claims = @intCast(output.variable_claim_count),
                } });
                return err;
            };

            try self.events.ensureCapacity(
                output.variable_claim_count +
                    output.invariant_claim_count +
                    output.artifact_count +
                    output.action_count +
                    1,
            );

            for (output.claims()) |claim| {
                const claim_id = try self.claims.append(claim);
                try self.materialized.applyClaim(
                    &self.registry,
                    &self.state,
                    claim,
                    claim_id,
                    self.round,
                );
                self.accepted_claims += 1;
                _ = try self.appendRuntimeEvent(.{ .claim_accepted = .{
                    .round = self.round,
                    .claim = claim,
                    .claim_id = claim_id,
                } });
            }

            for (output.invariants()) |claim| {
                try self.state.setInvariant(
                    &self.registry,
                    claim.invariant,
                    claim.status,
                    self.round,
                );
                _ = try self.appendRuntimeEvent(.{ .invariant_changed = .{
                    .round = self.round,
                    .claim = claim,
                } });
            }

            for (output.artifacts[0..output.artifact_count]) |artifact| {
                _ = try self.appendRuntimeEvent(.{ .artifact_emitted = .{
                    .round = self.round,
                    .operator = chosen_id,
                    .activation_epoch = activation_epoch,
                    .artifact_id = artifact.id,
                    .size_bytes = artifact.size_bytes,
                } });
            }

            for (output.actions[0..output.action_count], 0..) |action, ordinal| {
                const action_id = data_plane.actionContentId(
                    action,
                    chosen_id,
                    activation_epoch,
                    @intCast(ordinal),
                );
                _ = try self.appendRuntimeEvent(.{ .action_proposed = .{
                    .round = self.round,
                    .operator = chosen_id,
                    .activation_epoch = activation_epoch,
                    .action_id = action_id,
                    .requires_approval = action.requires_approval,
                } });
            }

            self.proposed_actions += output.action_count;
            self.executors[chosen_index].last_settled_epoch = activation_epoch;
            _ = try self.appendRuntimeEvent(.{ .operator_completed = .{
                .round = self.round,
                .operator = chosen_id,
                .activation_epoch = activation_epoch,
                .variable_claims = @intCast(output.variable_claim_count),
                .invariant_claims = @intCast(output.invariant_claim_count),
                .actions = @intCast(output.action_count),
            } });
            return true;
        }

        pub fn run(self: *Self, max_rounds: u32) !ExecutionResult {
            if (self.round >= max_rounds) {
                return self.makeResult(self.outcomeAtBudgetBoundary());
            }
            return self.runUntilQuiescent(max_rounds - self.round);
        }

        pub fn runUntilQuiescent(self: *Self, max_activations: u32) !ExecutionResult {
            var activations: u32 = 0;

            while (activations < max_activations) {
                const progressed = try self.step();
                if (!progressed) {
                    return self.makeResult(self.outcomeAtRest());
                }
                activations += 1;
            }

            return self.makeResult(self.outcomeAtBudgetBoundary());
        }

        pub fn result(self: *const Self) ExecutionResult {
            return self.makeResult(self.currentOutcome());
        }

        pub fn schedulerSnapshot(self: *const Self) SchedulerSnapshot {
            return .{
                .outcome = self.currentOutcome(),
                .round = self.round,
                .eligible_operators = self.eligibleOperatorCount(),
                .pending_activations = self.pendingActivationCount(),
                .pending_approvals = self.pendingApprovalCount(),
            };
        }

        pub fn pendingActivationCount(self: *const Self) usize {
            var count: usize = 0;
            var i: usize = 0;
            while (i < self.registry.operator_count) : (i += 1) {
                if (!eligibility.operatorEligible(&self.registry, &self.state, i, self.round)) continue;
                if (!self.activationNeeded(i)) continue;
                count += 1;
            }
            return count;
        }

        pub fn eligibleOperatorCount(self: *const Self) usize {
            var count: usize = 0;
            var i: usize = 0;
            while (i < self.registry.operator_count) : (i += 1) {
                if (eligibility.operatorEligible(&self.registry, &self.state, i, self.round)) {
                    count += 1;
                }
            }
            return count;
        }

        pub fn artifactEmissionCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.events.slice()) |record| {
                if (std.meta.activeTag(record.event) == .artifact_emitted) count += 1;
            }
            return count;
        }

        pub fn actionProposalCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.events.slice()) |record| {
                if (std.meta.activeTag(record.event) == .action_proposed) count += 1;
            }
            return count;
        }

        pub fn actionStatus(
            self: *const Self,
            action_id: core.ContentId,
        ) ?data_plane.ActionStatus {
            var status: ?data_plane.ActionStatus = null;
            for (self.events.slice()) |record| {
                switch (record.event) {
                    .action_proposed => |payload| {
                        if (!content_id.eql(payload.action_id, action_id)) continue;
                        status = if (payload.requires_approval)
                            .pending_approval
                        else
                            .ready;
                    },
                    .action_decided => |payload| {
                        if (!content_id.eql(payload.action_id, action_id)) continue;
                        status = switch (payload.decision) {
                            .approved => .approved,
                            .rejected => .rejected,
                        };
                    },
                    else => {},
                }
            }
            return status;
        }

        pub fn pendingApprovalCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.events.slice()) |record| {
                switch (record.event) {
                    .action_proposed => |payload| {
                        if (!payload.requires_approval) continue;
                        if (self.actionStatus(payload.action_id) == .pending_approval) {
                            count += 1;
                        }
                    },
                    else => {},
                }
            }
            return count;
        }

        pub fn approveAction(self: *Self, action_id: core.ContentId) !void {
            try self.decideAction(action_id, .approved);
        }

        pub fn rejectAction(self: *Self, action_id: core.ContentId) !void {
            try self.decideAction(action_id, .rejected);
        }

        fn decideAction(
            self: *Self,
            action_id: core.ContentId,
            decision: data_plane.ActionDecision,
        ) !void {
            try self.ensureRunStarted();
            try self.requireNoOpenActivation();

            const status = self.actionStatus(action_id) orelse return error.UnknownAction;
            if (status != .pending_approval) return error.ActionNotPendingApproval;

            try self.events.ensureCapacity(1);
            _ = try self.appendRuntimeEvent(.{ .action_decided = .{
                .round = self.round,
                .action_id = action_id,
                .decision = decision,
            } });
        }

        fn makeResult(self: *const Self, outcome: core.ResultOutcome) ExecutionResult {
            var unresolved: usize = 0;
            var conflicting: usize = 0;
            var i: usize = 0;
            while (i < self.registry.variable_count) : (i += 1) {
                if (self.state.variables[i].status == .unknown) unresolved += 1;
                if (self.state.variables[i].status == .conflicting) conflicting += 1;
            }
            return .{
                .runner = self,
                .summary = .{
                    .outcome = outcome,
                    .rounds = self.round,
                    .accepted_claims = self.accepted_claims,
                    .rejected_claims = self.rejected_claims,
                    .unresolved_variables = unresolved,
                    .conflicting_variables = conflicting,
                    .proposed_actions = self.proposed_actions,
                },
            };
        }

        fn isTerminalSuccess(self: *const Self) bool {
            if (self.targets.len == 0) return false;
            for (self.targets) |id| {
                const index = self.registry.variableIndex(id) orelse return false;
                if (!self.state.variables[index].status.carriesValue()) return false;
            }
            return true;
        }

        fn hasTargetConflict(self: *const Self) bool {
            for (self.targets) |id| {
                const index = self.registry.variableIndex(id) orelse continue;
                if (self.state.variables[index].status == .conflicting) return true;
            }
            return false;
        }

        fn hasTargetBlock(self: *const Self) bool {
            for (self.targets) |id| {
                const index = self.registry.variableIndex(id) orelse continue;
                switch (self.state.variables[index].status) {
                    .not_visible, .unavailable, .blocked => return true,
                    else => {},
                }
            }
            return false;
        }

        fn currentOutcome(self: *const Self) core.ResultOutcome {
            if (self.pendingActivationCount() != 0) return .running;
            return self.outcomeAtRest();
        }

        fn outcomeAtRest(self: *const Self) core.ResultOutcome {
            if (self.isTerminalSuccess()) return .success;
            if (self.hasTargetConflict()) return .conflicting;
            if (self.hasTargetBlock()) return .blocked;
            return .quiescent;
        }

        fn outcomeAtBudgetBoundary(self: *const Self) core.ResultOutcome {
            if (self.pendingActivationCount() != 0) return .exhausted;
            return self.outcomeAtRest();
        }

        pub fn configurationDigest(self: *const Self) core.ContentId {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("starlings-sdk-run-configuration-v1");
            hashU64(&hasher, self.seed);

            hashU64(&hasher, @intCast(self.registry.variable_count));
            var i: usize = 0;
            while (i < self.registry.variable_count) : (i += 1) {
                const schema = self.registry.variables[i];
                hashU32(&hasher, schema.variable.id);
                hashSlice(&hasher, schema.variable.name);
                hasher.update(&.{@intFromEnum(schema.variable.kind)});
                hasher.update(&.{@intFromEnum(schema.variable.merge_policy)});
                if (schema.variable.unit) |unit| {
                    hasher.update(&.{1});
                    hashSlice(&hasher, unit);
                } else {
                    hasher.update(&.{0});
                }
                if (schema.freshness_rounds) |freshness| {
                    hasher.update(&.{1});
                    hashU32(&hasher, freshness);
                } else {
                    hasher.update(&.{0});
                }
            }

            hashU64(&hasher, @intCast(self.registry.invariant_count));
            for (self.registry.invariants[0..self.registry.invariant_count]) |invariant| {
                hashU32(&hasher, invariant.id);
                hashSlice(&hasher, invariant.name);
                hashU64(&hasher, @intCast(invariant.requires.len));
                for (invariant.requires) |id| hashU32(&hasher, id);
            }

            hashU64(&hasher, @intCast(self.registry.operator_count));
            for (self.registry.operators[0..self.registry.operator_count]) |op| {
                hashU32(&hasher, op.manifest.id);
                hashSlice(&hasher, op.manifest.name);
                hashIdSlice(&hasher, op.manifest.requires_variables);
                hashIdSlice(&hasher, op.manifest.requires_invariants);
                hashIdSlice(&hasher, op.manifest.provides_variables);
                hashIdSlice(&hasher, op.manifest.provides_invariants);
                hasher.update(&.{@intFromEnum(op.eligibility.mode)});
                hashU64(&hasher, @intCast(op.eligibility.terms.len));
                for (op.eligibility.terms) |term| {
                    switch (term) {
                        .variable_known => |id| {
                            hasher.update(&.{1});
                            hashU32(&hasher, id);
                        },
                        .variable_resolved => |id| {
                            hasher.update(&.{2});
                            hashU32(&hasher, id);
                        },
                        .invariant_satisfied => |id| {
                            hasher.update(&.{3});
                            hashU32(&hasher, id);
                        },
                    }
                }
            }

            hashIdSlice(&hasher, self.targets);

            var digest: core.ContentId = undefined;
            hasher.final(&digest);
            return digest;
        }

        fn ensureRunStarted(self: *Self) !void {
            if (self.event_sink_failed) return error.EventSinkFailed;
            if (self.run_started_logged) return;

            try self.events.ensureCapacity(1);
            const digest = self.configurationDigest();
            _ = try self.appendRuntimeEvent(.{ .run_started = .{
                .seed = self.seed,
                .configuration_digest = digest,
            } });
            self.run_started_logged = true;
            self.configuration_locked = true;
        }

        fn appendRuntimeEvent(self: *Self, event: event_log.RunEvent) !core.ContentId {
            const id = try self.events.append(event);
            if (self.event_sink) |sink| {
                const record = self.events.records[self.events.len - 1];
                sink.append(record) catch |err| {
                    self.event_sink_failed = true;
                    return err;
                };
            }
            return id;
        }

        pub fn eventRecords(self: *const Self) []const event_log.EventRecord {
            return self.events.slice();
        }

        pub fn eventHeadId(self: *const Self) core.ContentId {
            return self.events.headId();
        }

        pub fn validateEventLog(self: *const Self) !void {
            try self.events.validate();
        }

        pub fn replayFrom(self: *Self, source: *const RunEventLog) !void {
            if (source == &self.events) return error.ReplaySourceAliasesTarget;
            try self.replayRecords(source.slice());
        }

        pub fn replayRecords(self: *Self, records: []const event_log.EventRecord) !void {
            try event_log.validateRecords(records);
            self.resetRuntimeState();

            for (records) |record| {
                try self.applyReplayEvent(record.event);
                const replayed_id = try self.events.append(record.event);
                if (!content_id.eql(replayed_id, record.id)) {
                    return error.EventReplayIdentityMismatch;
                }
            }
        }

        fn resetRuntimeState(self: *Self) void {
            self.state = .{};
            self.materialized = .{};
            self.claims = .{};
            self.events = .{};
            self.round = 0;
            self.accepted_claims = 0;
            self.rejected_claims = 0;
            self.proposed_actions = 0;
            self.run_started_logged = false;
            self.configuration_locked = false;
            self.event_sink_failed = false;

            if (comptime max_operators != 0) {
                for (self.executors[0..self.executor_count]) |*executor| {
                    executor.has_activated = false;
                    executor.activation_epoch = 0;
                    executor.last_input_fingerprint = content_id.zero;
                    executor.last_settled_epoch = 0;
                }
            }
        }

        fn applyReplayEvent(self: *Self, event: event_log.RunEvent) !void {
            switch (event) {
                .run_started => |payload| {
                    if (self.run_started_logged) return error.DuplicateRunStarted;
                    if (self.round != 0) return error.EventRoundMismatch;
                    if (payload.seed != self.seed) return error.ReplaySeedMismatch;

                    const expected = self.configurationDigest();
                    if (!content_id.eql(expected, payload.configuration_digest)) {
                        return error.ReplayConfigurationMismatch;
                    }

                    self.run_started_logged = true;
                    self.configuration_locked = true;
                },
                .observation_added => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    try self.requireNoOpenActivation();
                    try self.advanceReplayRound(payload.round, false);

                    const claim_id = try self.claims.append(payload.claim);
                    if (!content_id.eql(claim_id, payload.claim_id)) {
                        return error.ClaimIdentityMismatch;
                    }
                    try self.materialized.applyClaim(
                        &self.registry,
                        &self.state,
                        payload.claim,
                        claim_id,
                        payload.round,
                    );
                    self.accepted_claims += 1;
                },
                .operator_started => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.requireNoOpenActivation();

                    const index = self.registry.operatorIndex(payload.operator) orelse
                        return error.UnknownOperator;
                    if (index >= self.executor_count) return error.UnknownOperator;
                    if (payload.round != self.round +% 1) return error.EventRoundMismatch;
                    if (payload.activation_epoch != self.executors[index].activation_epoch +% 1) {
                        return error.ActivationEpochMismatch;
                    }
                    if (!eligibility.operatorEligible(
                        &self.registry,
                        &self.state,
                        index,
                        self.round,
                    )) return error.ReplayOperatorNotEligible;
                    if (!self.activationNeeded(index)) return error.ReplayActivationNotNeeded;

                    const expected_operator = self.nextPendingOperatorId() orelse
                        return error.ReplayActivationNotNeeded;
                    if (expected_operator != payload.operator) {
                        return error.ReplayArbitrationMismatch;
                    }

                    const expected = self.activationFingerprint(index);
                    if (!content_id.eql(expected, payload.input_fingerprint)) {
                        return error.ReplayActivationFingerprintMismatch;
                    }

                    self.round = payload.round;
                    self.executors[index].has_activated = true;
                    self.executors[index].activation_epoch = payload.activation_epoch;
                    self.executors[index].last_input_fingerprint = payload.input_fingerprint;
                },
                .claim_accepted => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.advanceReplayRound(payload.round, true);
                    const open_index = try self.openActivationIndex();
                    const operator_id = self.registry.operators[open_index].manifest.id;
                    if (payload.claim.source_operator != operator_id) {
                        return error.ReplayOperatorMismatch;
                    }

                    var replay_output = core.OperatorOutput{};
                    try replay_output.addClaim(payload.claim);
                    try output_state.validateOutput(
                        &self.registry,
                        self.registry.operators[open_index].manifest,
                        &replay_output,
                    );

                    const claim_id = try self.claims.append(payload.claim);
                    if (!content_id.eql(claim_id, payload.claim_id)) {
                        return error.ClaimIdentityMismatch;
                    }
                    try self.materialized.applyClaim(
                        &self.registry,
                        &self.state,
                        payload.claim,
                        claim_id,
                        payload.round,
                    );
                    self.accepted_claims += 1;
                },
                .invariant_changed => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.advanceReplayRound(payload.round, true);
                    const open_index = try self.openActivationIndex();
                    const operator_id = self.registry.operators[open_index].manifest.id;
                    if (payload.claim.source_operator != operator_id) {
                        return error.ReplayOperatorMismatch;
                    }

                    var replay_output = core.OperatorOutput{};
                    try replay_output.addInvariant(payload.claim);
                    try output_state.validateOutput(
                        &self.registry,
                        self.registry.operators[open_index].manifest,
                        &replay_output,
                    );

                    try self.state.setInvariant(
                        &self.registry,
                        payload.claim.invariant,
                        payload.claim.status,
                        payload.round,
                    );
                },
                .operator_completed => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.advanceReplayRound(payload.round, true);
                    const index = try self.openActivationIndex();
                    const operator_id = self.registry.operators[index].manifest.id;
                    if (operator_id != payload.operator) return error.ReplayOperatorMismatch;
                    if (self.executors[index].activation_epoch != payload.activation_epoch) {
                        return error.ActivationEpochMismatch;
                    }

                    self.proposed_actions += @as(usize, payload.actions);
                    self.executors[index].last_settled_epoch = payload.activation_epoch;
                },
                .operator_failed => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.advanceReplayRound(payload.round, true);
                    const index = try self.openActivationIndex();
                    const operator_id = self.registry.operators[index].manifest.id;
                    if (operator_id != payload.operator) return error.ReplayOperatorMismatch;
                    if (self.executors[index].activation_epoch != payload.activation_epoch) {
                        return error.ActivationEpochMismatch;
                    }

                    self.rejected_claims += @as(usize, payload.rejected_claims);
                    self.executors[index].last_settled_epoch = payload.activation_epoch;
                },
                .artifact_emitted => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.advanceReplayRound(payload.round, true);
                    const index = try self.openActivationIndex();
                    const operator_id = self.registry.operators[index].manifest.id;
                    if (operator_id != payload.operator) return error.ReplayOperatorMismatch;
                    if (self.executors[index].activation_epoch != payload.activation_epoch) {
                        return error.ActivationEpochMismatch;
                    }
                },
                .action_proposed => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    if (comptime max_operators == 0) return error.UnknownOperator;
                    try self.advanceReplayRound(payload.round, true);
                    const index = try self.openActivationIndex();
                    const operator_id = self.registry.operators[index].manifest.id;
                    if (operator_id != payload.operator) return error.ReplayOperatorMismatch;
                    if (self.executors[index].activation_epoch != payload.activation_epoch) {
                        return error.ActivationEpochMismatch;
                    }
                    if (self.actionStatus(payload.action_id) != null) {
                        return error.DuplicateActionProposal;
                    }
                },
                .action_decided => |payload| {
                    if (!self.run_started_logged) return error.MissingRunStarted;
                    try self.requireNoOpenActivation();
                    try self.advanceReplayRound(payload.round, true);
                    const status = self.actionStatus(payload.action_id) orelse
                        return error.UnknownAction;
                    if (status != .pending_approval) {
                        return error.ActionNotPendingApproval;
                    }
                },
            }
        }

        fn advanceReplayRound(self: *Self, round: u32, exact: bool) !void {
            if (exact) {
                if (round != self.round) return error.EventRoundMismatch;
                return;
            }
            if (round < self.round) return error.EventRoundRegression;
            self.round = round;
        }

        fn openActivationIndex(self: *const Self) error{ NoOpenActivation, MultipleOpenActivations }!usize {
            if (comptime max_operators == 0) return error.NoOpenActivation;

            var found: ?usize = null;
            for (self.executors[0..self.executor_count], 0..) |executor, i| {
                if (executor.activation_epoch <= executor.last_settled_epoch) continue;
                if (found != null) return error.MultipleOpenActivations;
                found = i;
            }
            return found orelse error.NoOpenActivation;
        }

        fn requireNoOpenActivation(self: *const Self) !void {
            if (self.openActivationIndex()) |_| {
                return error.OpenActivationExists;
            } else |err| switch (err) {
                error.NoOpenActivation => return,
                else => return err,
            }
        }

        pub fn operatorActivationEpoch(self: *const Self, id: core.OperatorId) ?u64 {
            if (comptime max_operators == 0) return null;
            const index = self.registry.operatorIndex(id) orelse return null;
            if (index >= self.executor_count) return null;
            return self.executors[index].activation_epoch;
        }

        pub fn openActivationOperatorId(
            self: *const Self,
        ) error{MultipleOpenActivations}!?core.OperatorId {
            if (comptime max_operators == 0) return null;

            var found: ?core.OperatorId = null;
            for (self.executors[0..self.executor_count], 0..) |executor, i| {
                if (executor.activation_epoch <= executor.last_settled_epoch) continue;
                if (found != null) return error.MultipleOpenActivations;
                found = self.registry.operators[i].manifest.id;
            }
            return found;
        }

        fn activationNeeded(self: *const Self, operator_index: usize) bool {
            if (comptime max_operators == 0) return false;
            if (!self.executors[operator_index].has_activated) return true;
            const current = self.activationFingerprint(operator_index);
            return !std.mem.eql(
                u8,
                &current,
                &self.executors[operator_index].last_input_fingerprint,
            );
        }

        fn activationFingerprint(self: *const Self, operator_index: usize) core.ContentId {
            if (comptime max_operators == 0) return content_id.zero;

            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("starlings-sdk-activation-input-v1");

            const op = self.registry.operators[operator_index];
            hashU32(&hasher, op.manifest.id);

            for (op.manifest.requires_variables) |id| {
                self.hashVariableDependency(&hasher, 1, id);
            }
            for (op.manifest.requires_invariants) |id| {
                self.hashInvariantDependency(&hasher, 2, id);
            }
            for (op.eligibility.terms) |term| {
                switch (term) {
                    .variable_known => |id| self.hashVariableDependency(&hasher, 3, id),
                    .variable_resolved => |id| self.hashVariableDependency(&hasher, 4, id),
                    .invariant_satisfied => |id| self.hashInvariantDependency(&hasher, 5, id),
                }
            }

            var digest: core.ContentId = undefined;
            hasher.final(&digest);
            return digest;
        }

        fn hashVariableDependency(
            self: *const Self,
            hasher: *std.crypto.hash.Blake3,
            tag: u8,
            id: core.VariableId,
        ) void {
            hasher.update(&.{tag});
            hashU32(hasher, id);

            const index = self.registry.variableIndex(id) orelse {
                hashU64(hasher, 0);
                return;
            };
            const cell = self.state.variables[index];
            hashU64(hasher, cell.revision);
            hasher.update(&.{@intFromEnum(cell.status)});
        }

        fn hashInvariantDependency(
            self: *const Self,
            hasher: *std.crypto.hash.Blake3,
            tag: u8,
            id: core.InvariantId,
        ) void {
            hasher.update(&.{tag});
            hashU32(hasher, id);

            if (comptime max_invariants == 0) {
                hashU64(hasher, 0);
                return;
            }

            const index = self.registry.invariantIndex(id) orelse {
                hashU64(hasher, 0);
                return;
            };
            const cell = self.state.invariants[index];
            hashU64(hasher, cell.revision);
            hasher.update(&.{@intFromEnum(cell.status)});
        }

        fn nextPendingOperatorId(self: *const Self) ?core.OperatorId {
            if (comptime max_operators == 0) return null;

            var eligible_ids: [max_operators]core.OperatorId = undefined;
            var candidate_count: usize = 0;

            var i: usize = 0;
            while (i < self.registry.operator_count) : (i += 1) {
                if (!eligibility.operatorEligible(&self.registry, &self.state, i, self.round)) continue;
                if (!self.activationNeeded(i)) continue;
                eligible_ids[candidate_count] = self.registry.operators[i].manifest.id;
                candidate_count += 1;
            }

            if (candidate_count == 0) return null;
            return self.chooseOperator(eligible_ids[0..candidate_count]);
        }

        fn chooseOperator(self: *const Self, ids: []const core.OperatorId) core.OperatorId {
            var chosen = ids[0];
            var chosen_priority = priority(self.seed, self.round, chosen);
            for (ids[1..]) |id| {
                const candidate = priority(self.seed, self.round, id);
                if (std.mem.order(u8, &candidate, &chosen_priority) == .lt) {
                    chosen = id;
                    chosen_priority = candidate;
                }
            }
            return chosen;
        }
    };
}

fn classifyExecutionFailure(err: anyerror) event_log.FailureKind {
    if (err == error.OperatorTimeout) return .timeout;
    if (err == error.OperatorCrashed) return .crash;
    return .execution;
}

fn hashSlice(hasher: *std.crypto.hash.Blake3, bytes: []const u8) void {
    hashU64(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn hashIdSlice(hasher: *std.crypto.hash.Blake3, ids: []const u32) void {
    hashU64(hasher, @intCast(ids.len));
    for (ids) |id| hashU32(hasher, id);
}

fn hashU32(hasher: *std.crypto.hash.Blake3, value: u32) void {
    var bytes: [4]u8 = undefined;
    encodeU32(value, &bytes);
    hasher.update(&bytes);
}

fn hashU64(hasher: *std.crypto.hash.Blake3, value: u64) void {
    var bytes: [8]u8 = undefined;
    encodeU64(value, &bytes);
    hasher.update(&bytes);
}

fn priority(seed: u64, round: u32, operator_id: core.OperatorId) core.ContentId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("starlings-sdk-arbitration-v1");

    var seed_bytes: [8]u8 = undefined;
    encodeU64(seed, &seed_bytes);
    hasher.update(&seed_bytes);

    var round_bytes: [4]u8 = undefined;
    encodeU32(round, &round_bytes);
    hasher.update(&round_bytes);

    var id_bytes: [4]u8 = undefined;
    encodeU32(operator_id, &id_bytes);
    hasher.update(&id_bytes);

    var digest: core.ContentId = undefined;
    hasher.final(&digest);
    return digest;
}

fn encodeU32(value: u32, out: *[4]u8) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const shift: u5 = @intCast(i * 8);
        out[i] = @truncate(value >> shift);
    }
}

fn encodeU64(value: u64, out: *[8]u8) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        out[i] = @truncate(value >> shift);
    }
}

test "runner assembles a dependency chain without a central workflow" {
    const R = Runner(4, 1, 4, 16);
    var runner = R.init(7, &.{3});

    try runner.addVariable(.{ .variable = .{ .id = 1, .name = "input", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 2, .name = "middle", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 3, .name = "final", .kind = .integer } });

    const Ops = struct {
        fn first(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            const input = obs.value(1).?.integer;
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = input + 1 },
                .source_operator = 10,
            });
            return out;
        }

        fn second(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            const middle = obs.value(2).?.integer;
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 3,
                .status = .derived,
                .value = .{ .integer = middle * 2 },
                .source_operator = 11,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "first",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, null, Ops.first);

    try runner.addOperator(.{ .manifest = .{
        .id = 11,
        .name = "second",
        .requires_variables = &.{2},
        .provides_variables = &.{3},
    } }, null, Ops.second);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 20 }, 1000);
    const result = try runner.run(8);

    try std.testing.expectEqual(core.ResultOutcome.success, result.summary.outcome);
    try std.testing.expect(core.Value.eql(result.value(3).?, .{ .integer = 42 }));
    try std.testing.expectEqual(@as(u32, 2), result.summary.rounds);
    try std.testing.expectEqual(@as(usize, 3), result.summary.accepted_claims);

    const explanation = result.explain(3).?;
    try std.testing.expectEqual(@as(usize, 1), explanation.accepted_claims);
    try std.testing.expect(!content_id.isZero(explanation.claim_id));
}

test "missing prerequisites become quiescent rather than fabricating state" {
    const R = Runner(2, 0, 2, 8);
    var runner = R.init(0, &.{2});
    try runner.addVariable(.{ .variable = .{ .id = 1, .name = "missing", .kind = .boolean } });
    try runner.addVariable(.{ .variable = .{ .id = 2, .name = "answer", .kind = .boolean } });

    const Ops = struct {
        fn run(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .boolean = true },
                .source_operator = 1,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 1,
        .name = "blocked",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, null, Ops.run);

    const result = try runner.run(4);
    try std.testing.expectEqual(core.ResultOutcome.quiescent, result.summary.outcome);
    try std.testing.expect(result.value(2) == null);
    try std.testing.expectEqual(@as(usize, 0), runner.pendingActivationCount());
}

test "operator observations cannot read undeclared variables" {
    const R = Runner(3, 0, 2, 8);
    var runner = R.init(0, &.{3});
    try runner.addVariable(.{ .variable = .{ .id = 1, .name = "allowed", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 2, .name = "private", .kind = .integer } });
    try runner.addVariable(.{ .variable = .{ .id = 3, .name = "out", .kind = .boolean } });

    const Ops = struct {
        fn run(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            try std.testing.expect(obs.value(1) != null);
            try std.testing.expect(obs.value(2) == null);
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 3,
                .status = .derived,
                .value = .{ .boolean = true },
                .source_operator = 1,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 1,
        .name = "scoped",
        .requires_variables = &.{1},
        .provides_variables = &.{3},
    } }, null, Ops.run);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 1 }, 1000);
    _ = try runner.seedVariable(2, .observed, .{ .integer = 999 }, 1000);
    const result = try runner.run(4);
    try std.testing.expectEqual(core.ResultOutcome.success, result.summary.outcome);
}


test "operator reactivates when a required input revision changes" {
    const R = Runner(2, 0, 1, 16);
    var runner = R.init(0, &.{});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });
    try runner.addVariable(.{ .variable = .{
        .id = 2,
        .name = "output",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    const Ops = struct {
        fn derive(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            const input = obs.value(1).?.integer;
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = input + 1 },
                .source_operator = 10,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "derive",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, null, Ops.derive);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 1 }, 1000);
    try std.testing.expect(try runner.step());
    try std.testing.expectEqual(@as(u64, 1), runner.operatorActivationEpoch(10).?);
    try std.testing.expect(core.Value.eql(runner.result().value(2).?, .{ .integer = 2 }));

    try std.testing.expect(!(try runner.step()));
    try std.testing.expectEqual(@as(u64, 1), runner.operatorActivationEpoch(10).?);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 2 }, 1000);
    try std.testing.expect(try runner.step());
    try std.testing.expectEqual(@as(u64, 2), runner.operatorActivationEpoch(10).?);
    try std.testing.expect(core.Value.eql(runner.result().value(2).?, .{ .integer = 3 }));
}

test "operators with no dependencies activate only once" {
    const R = Runner(1, 0, 1, 8);
    var runner = R.init(0, &.{});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "heartbeat",
        .kind = .boolean,
        .merge_policy = .latest,
    } });

    const Ops = struct {
        fn emit(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .derived,
                .value = .{ .boolean = true },
                .source_operator = 20,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 20,
        .name = "once",
        .provides_variables = &.{1},
    } }, null, Ops.emit);

    try std.testing.expect(try runner.step());
    try std.testing.expect(!(try runner.step()));
    try std.testing.expectEqual(@as(u64, 1), runner.operatorActivationEpoch(20).?);

    const snapshot = runner.schedulerSnapshot();
    try std.testing.expectEqual(core.ResultOutcome.quiescent, snapshot.outcome);
    try std.testing.expectEqual(@as(usize, 1), snapshot.eligible_operators);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending_activations);
}


test "quiescent population resumes after an external observation" {
    const R = Runner(2, 0, 1, 16);
    var runner = R.init(0, &.{2});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });
    try runner.addVariable(.{ .variable = .{
        .id = 2,
        .name = "output",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    const Ops = struct {
        fn derive(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            const input = obs.value(1).?.integer;
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = input * 2 },
                .source_operator = 10,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "derive",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, null, Ops.derive);

    const idle = try runner.runUntilQuiescent(4);
    try std.testing.expectEqual(core.ResultOutcome.quiescent, idle.summary.outcome);
    try std.testing.expectEqual(@as(usize, 0), runner.pendingActivationCount());

    _ = try runner.seedVariable(1, .observed, .{ .integer = 21 }, 1000);
    const awake = runner.schedulerSnapshot();
    try std.testing.expectEqual(core.ResultOutcome.running, awake.outcome);
    try std.testing.expectEqual(@as(usize, 1), awake.pending_activations);

    const done = try runner.runUntilQuiescent(4);
    try std.testing.expectEqual(core.ResultOutcome.success, done.summary.outcome);
    try std.testing.expect(core.Value.eql(done.value(2).?, .{ .integer = 42 }));
}

test "explicit non-value target closure is blocked at quiescence" {
    const R = Runner(1, 0, 1, 8);
    var runner = R.init(0, &.{1});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "answer",
        .kind = .boolean,
        .merge_policy = .latest,
    } });

    const Ops = struct {
        fn close(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .blocked,
                .source_operator = 10,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "close",
        .provides_variables = &.{1},
    } }, null, Ops.close);

    const result = try runner.runUntilQuiescent(4);
    try std.testing.expectEqual(core.ResultOutcome.blocked, result.summary.outcome);
    try std.testing.expectEqual(core.EpistemicStatus.blocked, result.status(1).?);
}

test "activation budget exhaustion is distinct from quiescence" {
    const R = Runner(3, 0, 2, 16);
    var runner = R.init(0, &.{3});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });
    try runner.addVariable(.{ .variable = .{
        .id = 2,
        .name = "middle",
        .kind = .integer,
        .merge_policy = .latest,
    } });
    try runner.addVariable(.{ .variable = .{
        .id = 3,
        .name = "output",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    const Ops = struct {
        fn first(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = obs.value(1).?.integer + 1 },
                .source_operator = 10,
            });
            return out;
        }

        fn second(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 3,
                .status = .derived,
                .value = .{ .integer = obs.value(2).?.integer + 1 },
                .source_operator = 11,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "first",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } }, null, Ops.first);
    try runner.addOperator(.{ .manifest = .{
        .id = 11,
        .name = "second",
        .requires_variables = &.{2},
        .provides_variables = &.{3},
    } }, null, Ops.second);

    _ = try runner.seedVariable(1, .observed, .{ .integer = 40 }, 1000);

    const exhausted = try runner.runUntilQuiescent(1);
    try std.testing.expectEqual(core.ResultOutcome.exhausted, exhausted.summary.outcome);
    try std.testing.expectEqual(@as(usize, 1), runner.pendingActivationCount());

    const done = try runner.runUntilQuiescent(1);
    try std.testing.expectEqual(core.ResultOutcome.success, done.summary.outcome);
    try std.testing.expect(core.Value.eql(done.value(3).?, .{ .integer = 42 }));
}

test "not-visible target is not counted as success" {
    const R = Runner(1, 0, 1, 8);
    var runner = R.init(0, &.{1});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "target",
        .kind = .boolean,
        .merge_policy = .latest,
    } });

    const Ops = struct {
        fn close(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .not_visible,
                .source_operator = 10,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "not-visible",
        .provides_variables = &.{1},
    } }, null, Ops.close);

    const result = try runner.runUntilQuiescent(2);
    try std.testing.expectEqual(core.ResultOutcome.blocked, result.summary.outcome);
}


test "target success is decided only after pending activations drain" {
    const R = Runner(1, 0, 2, 8);
    var runner = R.init(17, &.{1});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "target",
        .kind = .integer,
        .merge_policy = .retain_all_conflict,
    } });

    const Ops = struct {
        fn a(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .derived,
                .value = .{ .integer = 1 },
                .source_operator = 10,
            });
            return out;
        }

        fn b(_: ?*const anyopaque, _: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 1,
                .status = .derived,
                .value = .{ .integer = 2 },
                .source_operator = 11,
            });
            return out;
        }
    };

    try runner.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "a",
        .provides_variables = &.{1},
    } }, null, Ops.a);
    try runner.addOperator(.{ .manifest = .{
        .id = 11,
        .name = "b",
        .provides_variables = &.{1},
    } }, null, Ops.b);

    const result = try runner.runUntilQuiescent(4);
    try std.testing.expectEqual(core.ResultOutcome.conflicting, result.summary.outcome);
    try std.testing.expectEqual(core.EpistemicStatus.conflicting, result.status(1).?);
    try std.testing.expectEqual(@as(usize, 0), runner.pendingActivationCount());
}


test "append-only events replay to identical materialized and scheduler state" {
    const R = Runner(3, 1, 2, 32);

    const Ops = struct {
        fn normalize(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 2,
                .status = .derived,
                .value = .{ .integer = obs.value(1).?.integer + 1 },
                .source_operator = 10,
            });
            try out.addInvariant(.{
                .invariant = 4,
                .status = .satisfied,
                .source_operator = 10,
            });
            return out;
        }

        fn solve(_: ?*const anyopaque, obs: R.Observation) !core.OperatorOutput {
            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = 3,
                .status = .derived,
                .value = .{ .integer = obs.value(2).?.integer * 2 },
                .source_operator = 11,
            });
            try out.addAction(.{ .name = "publish-result" });
            return out;
        }

        fn setup(runner: *R) !void {
            try runner.addVariable(.{ .variable = .{
                .id = 1,
                .name = "input",
                .kind = .integer,
                .merge_policy = .latest,
            } });
            try runner.addVariable(.{ .variable = .{
                .id = 2,
                .name = "middle",
                .kind = .integer,
                .merge_policy = .latest,
            } });
            try runner.addVariable(.{ .variable = .{
                .id = 3,
                .name = "target",
                .kind = .integer,
                .merge_policy = .latest,
            } });
            try runner.addInvariant(.{
                .id = 4,
                .name = "middle.valid",
                .requires = &.{2},
            });

            try runner.addOperator(.{ .manifest = .{
                .id = 10,
                .name = "normalize",
                .requires_variables = &.{1},
                .provides_variables = &.{2},
                .provides_invariants = &.{4},
            } }, null, normalize);
            try runner.addOperator(.{ .manifest = .{
                .id = 11,
                .name = "solve",
                .requires_variables = &.{2},
                .requires_invariants = &.{4},
                .provides_variables = &.{3},
            } }, null, solve);
        }
    };

    var live = R.init(73, &.{3});
    try Ops.setup(&live);
    _ = try live.seedVariable(1, .observed, .{ .integer = 20 }, 1000);
    const live_result = try live.runUntilQuiescent(8);

    try std.testing.expectEqual(core.ResultOutcome.success, live_result.summary.outcome);
    try std.testing.expect(core.Value.eql(live_result.value(3).?, .{ .integer = 42 }));
    try live.validateEventLog();
    try std.testing.expectEqual(@as(usize, 9), live.eventRecords().len);

    var replayed = R.init(73, &.{3});
    try Ops.setup(&replayed);
    try replayed.replayFrom(&live.events);

    const replay_result = replayed.result();
    try std.testing.expectEqual(live_result.summary.outcome, replay_result.summary.outcome);
    try std.testing.expectEqual(live_result.summary.rounds, replay_result.summary.rounds);
    try std.testing.expectEqual(live_result.summary.accepted_claims, replay_result.summary.accepted_claims);
    try std.testing.expectEqual(live_result.summary.proposed_actions, replay_result.summary.proposed_actions);
    try std.testing.expect(core.Value.eql(replay_result.value(3).?, .{ .integer = 42 }));
    try std.testing.expectEqual(live.state.variables[0].revision, replayed.state.variables[0].revision);
    try std.testing.expectEqual(live.state.variables[1].revision, replayed.state.variables[1].revision);
    try std.testing.expectEqual(live.state.variables[2].revision, replayed.state.variables[2].revision);
    try std.testing.expectEqual(live.state.invariants[0].revision, replayed.state.invariants[0].revision);
    try std.testing.expectEqual(live.operatorActivationEpoch(10).?, replayed.operatorActivationEpoch(10).?);
    try std.testing.expectEqual(live.operatorActivationEpoch(11).?, replayed.operatorActivationEpoch(11).?);
    try std.testing.expect(content_id.eql(live.eventHeadId(), replayed.eventHeadId()));
    try std.testing.expectEqual(live.eventRecords().len, replayed.eventRecords().len);

    const live_snapshot = live.schedulerSnapshot();
    const replay_snapshot = replayed.schedulerSnapshot();
    try std.testing.expectEqual(live_snapshot.outcome, replay_snapshot.outcome);
    try std.testing.expectEqual(live_snapshot.pending_activations, replay_snapshot.pending_activations);
    try std.testing.expectEqual(live_snapshot.eligible_operators, replay_snapshot.eligible_operators);
}

test "replay rejects a tampered event chain" {
    const R = Runner(1, 0, 0, 8);

    var live = R.init(1, &.{1});
    try live.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });
    _ = try live.seedVariable(1, .observed, .{ .integer = 7 }, 1000);

    var tampered = live.events;
    tampered.records[0].id[0] ^= 0xff;

    var replayed = R.init(1, &.{1});
    try replayed.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    try std.testing.expectError(error.EventIdMismatch, replayed.replayFrom(&tampered));
}


test "run configuration locks after the first runtime event" {
    const R = Runner(2, 0, 0, 8);
    var runner = R.init(5, &.{1});

    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    _ = try runner.seedVariable(1, .observed, .{ .integer = 7 }, 1000);

    try std.testing.expectError(
        error.RunConfigurationLocked,
        runner.addVariable(.{ .variable = .{
            .id = 2,
            .name = "late",
            .kind = .integer,
        } }),
    );
    try std.testing.expectEqual(event_log.EventKind.run_started, std.meta.activeTag(runner.eventRecords()[0].event));
}

test "replay rejects a different run seed before applying state" {
    const R = Runner(1, 0, 0, 8);

    var live = R.init(11, &.{1});
    try live.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });
    _ = try live.seedVariable(1, .observed, .{ .integer = 9 }, 1000);

    var replayed = R.init(12, &.{1});
    try replayed.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    try std.testing.expectError(error.ReplaySeedMismatch, replayed.replayFrom(&live.events));
    try std.testing.expectEqual(core.EpistemicStatus.unknown, replayed.state.variables[0].status);
}


test "event sink failure latches the runner closed" {
    const R = Runner(1, 0, 0, 8);
    var runner = R.init(9, &.{1});
    try runner.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    const Sink = struct {
        fn append(_: ?*anyopaque, _: event_log.EventRecord) anyerror!void {
            return error.SimulatedDurabilityFailure;
        }
    };

    try runner.setEventSink(.{
        .context = null,
        .append_fn = Sink.append,
    });

    try std.testing.expectError(
        error.SimulatedDurabilityFailure,
        runner.seedVariable(1, .observed, .{ .integer = 7 }, 1000),
    );
    try std.testing.expectEqual(@as(usize, 1), runner.eventRecords().len);

    try std.testing.expectError(
        error.EventSinkFailed,
        runner.seedVariable(1, .observed, .{ .integer = 8 }, 1000),
    );
    try std.testing.expectEqual(@as(usize, 1), runner.eventRecords().len);
}
