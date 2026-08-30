const std = @import("std");
const contract = @import("../pack/contract.zig");
const pack_loader = @import("../pack/loader.zig");
const core = @import("core_types.zig");
const execution = @import("execution.zig");
const external = @import("external.zig");
const process_supervisor = @import("process_supervisor.zig");
const run_store = @import("run_store.zig");
const event_log = @import("event_log.zig");
const artifact_store = @import("artifact_store.zig");

pub const AgentRunner = execution.Runner(
    contract.max_variables,
    contract.max_invariants,
    contract.max_operators,
    run_store.max_replay_claims,
);

pub const max_external_request_bytes: usize = 64 * 1024;
pub const max_external_response_bytes: usize = 256 * 1024;

const BufferedExternal = external.BufferedExternalOperator(
    max_external_request_bytes,
    max_external_response_bytes,
);

/// A loaded, immutable declarative population. YAML describes state,
/// capabilities and implementation bindings, never an authored workflow.
pub const Population = struct {
    path: []const u8,
    compiled: contract.CompiledPack,

    pub fn load(
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        path: []const u8,
    ) !Population {
        return .{
            .path = try arena.dupe(u8, path),
            .compiled = try pack_loader.loadAndCompile(io, gpa, arena, path),
        };
    }
};

pub const NativeBinding = struct {
    name: []const u8,
    context: ?*const anyopaque = null,
    execute_fn: AgentRunner.ExecuteFn,
};

/// Model providers are host-owned inference substrates. Many logical model
/// operators may bind to the same provider and remain distinct through their
/// operator identity, profile, local observations and declared capabilities.
pub const ModelProvider = struct {
    name: []const u8,
    context: ?*anyopaque = null,
    infer_fn: *const fn (?*anyopaque, ModelRequest) anyerror!core.OperatorOutput,

    pub fn infer(self: ModelProvider, request: ModelRequest) !core.OperatorOutput {
        return self.infer_fn(self.context, request);
    }
};

pub const ModelRequest = struct {
    operator_id: core.OperatorId,
    operator_name: []const u8,
    role: contract.OperatorRole,
    profile: ?[]const u8,
    timeout_ms: u32,
    round: u32,
    observations: []const external.WireObservation,
    invariants: []const external.WireInvariant,
    provides_variables: []const core.VariableId,
    provides_invariants: []const core.InvariantId,
};

pub const Bindings = struct {
    native: []const NativeBinding = &.{},
    models: []const ModelProvider = &.{},
};

pub const Observation = struct {
    name: []const u8,
    status: core.EpistemicStatus,
    value: ?core.Value = null,
    confidence_permille: u16 = 1000,
};

pub const Step = enum {
    progress,
    idle,
};

/// SDK-first single-node agent runtime. The embedded Runner remains the
/// deterministic reference semantics; applications own lifecycle and decide
/// when to call step(), inject observations, attach persistence, or later
/// exchange claims with peers.
pub const Agent = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    population: *const Population,
    runner: AgentRunner,
    supervisor: *process_supervisor.Supervisor,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        population: *const Population,
        seed: u64,
        bindings: Bindings,
    ) !Agent {
        const supervisor = try arena.create(process_supervisor.Supervisor);
        supervisor.* = .{
            .io = io,
            .allocator = allocator,
        };

        var self = Agent{
            .io = io,
            .allocator = allocator,
            .arena = arena,
            .population = population,
            .runner = AgentRunner.init(
                seed,
                population.compiled.targets[0..population.compiled.target_count],
            ),
            .supervisor = supervisor,
        };
        errdefer supervisor.deinit();

        try self.bind(bindings);
        return self;
    }

    pub fn deinit(self: *Agent) void {
        self.supervisor.deinit();
    }

    pub fn observe(self: *Agent, observation: Observation) !core.ContentId {
        const variable_id = self.population.compiled.variableId(observation.name) orelse
            return error.UnknownInputVariable;
        return self.runner.seedVariable(
            variable_id,
            observation.status,
            observation.value,
            observation.confidence_permille,
        );
    }

    pub fn observeText(
        self: *Agent,
        name: []const u8,
        text: []const u8,
        confidence_permille: u16,
    ) !core.ContentId {
        const variable_id = self.population.compiled.variableId(name) orelse
            return error.UnknownInputVariable;
        const schema = self.runner.registry.variableSchema(variable_id) orelse
            return error.UnknownInputVariable;
        const value = try parseValue(self.arena, schema.variable.kind, text);
        return self.runner.seedVariable(
            variable_id,
            .observed,
            value,
            confidence_permille,
        );
    }

    pub fn step(self: *Agent) !Step {
        return if (try self.runner.step()) .progress else .idle;
    }

    pub fn result(self: *const Agent) AgentRunner.ExecutionResult {
        return self.runner.result();
    }

    pub fn snapshot(self: *const Agent) AgentRunner.SchedulerSnapshot {
        return self.runner.schedulerSnapshot();
    }

    pub fn status(self: *const Agent, name: []const u8) ?core.EpistemicStatus {
        const id = self.population.compiled.variableId(name) orelse return null;
        return self.runner.result().status(id);
    }

    pub fn value(self: *const Agent, name: []const u8) ?core.Value {
        const id = self.population.compiled.variableId(name) orelse return null;
        return self.runner.result().value(id);
    }

    pub fn explain(self: *const Agent, name: []const u8) ?AgentRunner.Explanation {
        const id = self.population.compiled.variableId(name) orelse return null;
        return self.runner.result().explain(id);
    }

    pub fn setEventSink(self: *Agent, sink: event_log.EventSink) !void {
        try self.runner.setEventSink(sink);
    }

    pub fn setArtifactVerifier(self: *Agent, verifier: artifact_store.Verifier) !void {
        try self.runner.setArtifactVerifier(verifier);
    }

    pub fn approveAction(self: *Agent, action_id: core.ContentId) !void {
        try self.runner.approveAction(action_id);
    }

    pub fn rejectAction(self: *Agent, action_id: core.ContentId) !void {
        try self.runner.rejectAction(action_id);
    }

    pub fn eventRecords(self: *const Agent) []const event_log.EventRecord {
        return self.runner.eventRecords();
    }

    pub fn eventHeadId(self: *const Agent) core.ContentId {
        return self.runner.eventHeadId();
    }

    fn bind(self: *Agent, bindings: Bindings) !void {
        for (self.population.compiled.variables[0..self.population.compiled.variable_count]) |variable| {
            try self.runner.addVariable(variable);
        }
        for (self.population.compiled.invariants[0..self.population.compiled.invariant_count]) |*invariant| {
            try self.runner.addInvariant(invariant.asCore());
        }

        for (self.population.compiled.operators[0..self.population.compiled.operator_count]) |*operator| {
            switch (operator.runtime.kind) {
                .native => {
                    const binding_name = operator.runtime.target orelse operator.name;
                    const binding = findNativeBinding(bindings.native, binding_name) orelse
                        return error.UnboundNativeOperator;
                    try self.runner.addOperator(
                        operator.asRegistered(),
                        binding.context,
                        binding.execute_fn,
                    );
                },
                .model => {
                    const provider_name = operator.runtime.target orelse
                        return error.MissingRuntimeTarget;
                    const provider = findModelProvider(bindings.models, provider_name) orelse
                        return error.UnboundModelProvider;
                    const context = try self.makeModelContext(operator, provider);
                    try self.runner.addOperator(
                        operator.asRegistered(),
                        context,
                        ModelContext.execute,
                    );
                },
                .python, .subprocess => {
                    const context = try self.makeExternalContext(operator);
                    try self.runner.addOperator(
                        operator.asRegistered(),
                        context,
                        ExternalContext.execute,
                    );
                },
            }
        }
    }

    fn makeExternalContext(
        self: *Agent,
        operator: *const contract.CompiledOperator,
    ) !*ExternalContext {
        const context = try self.arena.create(ExternalContext);
        context.* = .{
            .buffered = .{
                .operator_id = operator.id,
                .external = .{
                    .invocation = try self.makeInvocation(operator.runtime),
                    .transport = self.supervisor.transport(),
                },
            },
            .required_variable_count = operator.requires_variable_count,
            .required_invariant_count = operator.requires_invariant_count,
            .provided_variable_count = operator.provides_variable_count,
            .provided_invariant_count = operator.provides_invariant_count,
        };
        @memcpy(
            context.required_variables[0..operator.requires_variable_count],
            operator.requires_variables[0..operator.requires_variable_count],
        );
        @memcpy(
            context.required_invariants[0..operator.requires_invariant_count],
            operator.requires_invariants[0..operator.requires_invariant_count],
        );
        @memcpy(
            context.provided_variables[0..operator.provides_variable_count],
            operator.provides_variables[0..operator.provides_variable_count],
        );
        @memcpy(
            context.provided_invariants[0..operator.provides_invariant_count],
            operator.provides_invariants[0..operator.provides_invariant_count],
        );
        return context;
    }

    fn makeModelContext(
        self: *Agent,
        operator: *const contract.CompiledOperator,
        provider: ModelProvider,
    ) !*ModelContext {
        const context = try self.arena.create(ModelContext);
        context.* = .{
            .provider = provider,
            .operator_id = operator.id,
            .operator_name = operator.name,
            .role = operator.role,
            .profile = operator.runtime.profile,
            .timeout_ms = operator.runtime.timeout_ms,
            .required_variable_count = operator.requires_variable_count,
            .required_invariant_count = operator.requires_invariant_count,
            .provided_variable_count = operator.provides_variable_count,
            .provided_invariant_count = operator.provides_invariant_count,
        };
        @memcpy(
            context.required_variables[0..operator.requires_variable_count],
            operator.requires_variables[0..operator.requires_variable_count],
        );
        @memcpy(
            context.required_invariants[0..operator.requires_invariant_count],
            operator.requires_invariants[0..operator.requires_invariant_count],
        );
        @memcpy(
            context.provided_variables[0..operator.provides_variable_count],
            operator.provides_variables[0..operator.provides_variable_count],
        );
        @memcpy(
            context.provided_invariants[0..operator.provides_invariant_count],
            operator.provides_invariants[0..operator.provides_invariant_count],
        );
        return context;
    }

    fn makeInvocation(
        self: *Agent,
        decl: contract.RuntimeDecl,
    ) !external.Invocation {
        const target = decl.target orelse return error.MissingRuntimeTarget;
        return switch (decl.kind) {
            .native, .model => unreachable,
            .python => .{ .python = .{
                .target = try resolvePackTarget(self.arena, self.population.path, target),
                .timeout_ms = decl.timeout_ms,
            } },
            .subprocess => blk: {
                const argv = try self.arena.alloc([]const u8, decl.args.len + 1);
                argv[0] = try resolvePackTarget(self.arena, self.population.path, target);
                for (decl.args, 0..) |arg, i| {
                    argv[i + 1] = try resolveRuntimeArg(self.arena, self.population.path, arg);
                }
                break :blk .{ .subprocess = .{
                    .argv = argv,
                    .timeout_ms = decl.timeout_ms,
                } };
            },
        };
    }
};

const ModelContext = struct {
    provider: ModelProvider,
    operator_id: core.OperatorId,
    operator_name: []const u8,
    role: contract.OperatorRole,
    profile: ?[]const u8,
    timeout_ms: u32,
    required_variables: [contract.max_dependencies]core.VariableId = undefined,
    required_variable_count: usize = 0,
    required_invariants: [contract.max_dependencies]core.InvariantId = undefined,
    required_invariant_count: usize = 0,
    provided_variables: [contract.max_dependencies]core.VariableId = undefined,
    provided_variable_count: usize = 0,
    provided_invariants: [contract.max_dependencies]core.InvariantId = undefined,
    provided_invariant_count: usize = 0,

    fn execute(
        raw_context: ?*const anyopaque,
        obs: AgentRunner.Observation,
    ) !core.OperatorOutput {
        const opaque = raw_context orelse return error.MissingModelContext;
        const self: *const ModelContext = @ptrCast(@alignCast(opaque));

        var observations: [contract.max_dependencies]external.WireObservation = undefined;
        var observation_count: usize = 0;
        for (self.required_variables[0..self.required_variable_count]) |variable_id| {
            const status = obs.status(variable_id) orelse return error.ModelVariableNotReadable;
            observations[observation_count] = .{
                .variable = variable_id,
                .status = status,
                .value = obs.value(variable_id),
            };
            observation_count += 1;
        }

        var invariants: [contract.max_dependencies]external.WireInvariant = undefined;
        var invariant_count: usize = 0;
        for (self.required_invariants[0..self.required_invariant_count]) |invariant_id| {
            const status = obs.invariantStatus(invariant_id) orelse
                return error.ModelInvariantNotReadable;
            invariants[invariant_count] = .{
                .invariant = invariant_id,
                .status = status,
            };
            invariant_count += 1;
        }

        return self.provider.infer(.{
            .operator_id = self.operator_id,
            .operator_name = self.operator_name,
            .role = self.role,
            .profile = self.profile,
            .timeout_ms = self.timeout_ms,
            .round = obs.round(),
            .observations = observations[0..observation_count],
            .invariants = invariants[0..invariant_count],
            .provides_variables = self.provided_variables[0..self.provided_variable_count],
            .provides_invariants = self.provided_invariants[0..self.provided_invariant_count],
        });
    }
};

const ExternalContext = struct {
    buffered: BufferedExternal,
    required_variables: [contract.max_dependencies]core.VariableId = undefined,
    required_variable_count: usize = 0,
    required_invariants: [contract.max_dependencies]core.InvariantId = undefined,
    required_invariant_count: usize = 0,
    provided_variables: [contract.max_dependencies]core.VariableId = undefined,
    provided_variable_count: usize = 0,
    provided_invariants: [contract.max_dependencies]core.InvariantId = undefined,
    provided_invariant_count: usize = 0,

    fn execute(
        raw_context: ?*const anyopaque,
        obs: AgentRunner.Observation,
    ) !core.OperatorOutput {
        const opaque_context = raw_context orelse return error.MissingExternalOperatorContext;
        const self: *@This() = @constCast(@ptrCast(@alignCast(opaque_context)));

        var observations: [contract.max_dependencies]external.WireObservation = undefined;
        var observation_count: usize = 0;
        for (self.required_variables[0..self.required_variable_count]) |variable_id| {
            const status = obs.status(variable_id) orelse return error.ExternalVariableNotReadable;
            observations[observation_count] = .{
                .variable = variable_id,
                .status = status,
                .value = obs.value(variable_id),
            };
            observation_count += 1;
        }

        var invariants: [contract.max_dependencies]external.WireInvariant = undefined;
        var invariant_count: usize = 0;
        for (self.required_invariants[0..self.required_invariant_count]) |invariant_id| {
            const status = obs.invariantStatus(invariant_id) orelse
                return error.ExternalInvariantNotReadable;
            invariants[invariant_count] = .{
                .invariant = invariant_id,
                .status = status,
            };
            invariant_count += 1;
        }

        return self.buffered.invokeExecution(
            obs.round(),
            observations[0..observation_count],
            invariants[0..invariant_count],
            self.provided_variables[0..self.provided_variable_count],
            self.provided_invariants[0..self.provided_invariant_count],
        );
    }
};

fn findNativeBinding(bindings: []const NativeBinding, name: []const u8) ?NativeBinding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding;
    }
    return null;
}

fn findModelProvider(providers: []const ModelProvider, name: []const u8) ?ModelProvider {
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.name, name)) return provider;
    }
    return null;
}

fn resolvePackTarget(
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    target: []const u8,
) ![]const u8 {
    if (target.len == 0) return error.MissingRuntimeTarget;
    if (pathIsAbsolute(target)) return target;

    if (!containsPathSeparator(target)) return target;
    try rejectParentTraversal(target);
    return joinPackPath(arena, pack_dir, target);
}

fn resolveRuntimeArg(
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    arg: []const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, ".\\")) {
        const relative = arg[2..];
        try rejectParentTraversal(relative);
        return joinPackPath(arena, pack_dir, relative);
    }
    return arg;
}

fn pathIsAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn joinPackPath(
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    relative: []const u8,
) ![]const u8 {
    const separator_needed = pack_dir.len != 0 and
        pack_dir[pack_dir.len - 1] != '/' and
        pack_dir[pack_dir.len - 1] != '\\';
    const prefix_len = pack_dir.len + @as(usize, if (separator_needed) 1 else 0);
    const out = try arena.alloc(u8, prefix_len + relative.len);

    if (pack_dir.len != 0) @memcpy(out[0..pack_dir.len], pack_dir);
    var cursor = pack_dir.len;
    if (separator_needed) {
        out[cursor] = '/';
        cursor += 1;
    }
    @memcpy(out[cursor..], relative);
    return out;
}

fn containsPathSeparator(path: []const u8) bool {
    for (path) |ch| {
        if (ch == '/' or ch == '\\') return true;
    }
    return false;
}

fn rejectParentTraversal(path: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.RuntimePathEscapesPack;
    }
}

pub fn parseValue(
    arena: std.mem.Allocator,
    kind: core.ValueKind,
    text: []const u8,
) !core.Value {
    return switch (kind) {
        .integer => .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInputValue },
        .float => .{ .float = std.fmt.parseFloat(f64, text) catch return error.InvalidInputValue },
        .boolean => blk: {
            if (std.mem.eql(u8, text, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, text, "false")) break :blk .{ .boolean = false };
            return error.InvalidInputValue;
        },
        .text => .{ .text = try arena.dupe(u8, text) },
        .artifact_ref => .{ .artifact_ref = run_store.parseRunId(text) catch return error.InvalidInputValue },
    };
}

test "one model provider backs multiple logical model operators" {
    const variables = [_]contract.VariableDecl{
        .{ .name = "source.text", .@"type" = .text, .merge = .latest },
        .{ .name = "method.candidate", .@"type" = .text, .merge = .retain_all_conflict },
    };
    const operators = [_]contract.OperatorDecl{
        .{
            .name = "interpreter",
            .role = .model,
            .runtime = .{ .kind = .model, .target = "shared-local", .profile = "interpreter" },
            .requires = .{ .variables = &.{"source.text"} },
            .provides = .{ .variables = &.{"method.candidate"} },
        },
        .{
            .name = "skeptic",
            .role = .model,
            .runtime = .{ .kind = .model, .target = "shared-local", .profile = "skeptic" },
            .requires = .{ .variables = &.{"source.text"} },
            .provides = .{ .variables = &.{"method.candidate"} },
        },
    };
    const compiled = try contract.compile(.{
        .manifest = .{
            .apiVersion = contract.api_version,
            .kind = contract.kind_name,
            .metadata = .{ .name = "shared-model", .version = "0.1.0" },
            .state = .{ .variables = "variables.yaml", .invariants = "invariants.yaml" },
            .population = .{ .operators = "operators.yaml" },
            .targets = &.{"method.candidate"},
        },
        .variable_file = .{ .variables = &variables },
        .invariant_file = .{ .invariants = &.{} },
        .operator_file = .{ .operators = &operators },
    });

    const FakeModel = struct {
        calls: usize = 0,

        fn infer(raw: ?*anyopaque, request: ModelRequest) !core.OperatorOutput {
            const opaque = raw orelse return error.MissingModelState;
            const self: *@This() = @ptrCast(@alignCast(opaque));
            self.calls += 1;

            const output_id = request.provides_variables[0];
            const text = if (std.mem.eql(u8, request.profile orelse "", "skeptic"))
                "candidate-b"
            else
                "candidate-a";

            var out = core.OperatorOutput{};
            try out.addClaim(.{
                .variable = output_id,
                .status = .derived,
                .value = .{ .text = text },
                .confidence_permille = 1000,
                .source_operator = request.operator_id,
            });
            return out;
        }
    };

    var fake = FakeModel{};
    const providers = [_]ModelProvider{.{
        .name = "shared-local",
        .context = &fake,
        .infer_fn = FakeModel.infer,
    }};

    const population = Population{
        .path = ".",
        .compiled = compiled,
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var agent = try Agent.init(
        std.testing.io,
        std.testing.allocator,
        arena_state.allocator(),
        &population,
        9,
        .{ .models = &providers },
    );
    defer agent.deinit();

    _ = try agent.observe(.{
        .name = "source.text",
        .status = .observed,
        .value = .{ .text = "paper" },
    });

    try std.testing.expectEqual(Step.progress, try agent.step());
    try std.testing.expectEqual(Step.progress, try agent.step());
    try std.testing.expectEqual(Step.idle, try agent.step());
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(core.EpistemicStatus.conflicting, agent.status("method.candidate").?);
}
