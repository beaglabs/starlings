const std = @import("std");
const contract = @import("contract.zig");
const core = @import("../sdk/core_types.zig");
const execution = @import("../sdk/execution.zig");
const external = @import("../sdk/external.zig");
const process_supervisor = @import("../sdk/process_supervisor.zig");
const run_store = @import("../sdk/run_store.zig");

pub const RuntimeRunner = execution.Runner(
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

pub const NativeBinding = struct {
    name: []const u8,
    context: ?*const anyopaque = null,
    execute_fn: RuntimeRunner.ExecuteFn,
};

pub const SeedInput = struct {
    name: []const u8,
    value: []const u8,
    confidence_permille: u16 = 1000,
};

pub const Runtime = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    compiled: *const contract.CompiledPack,
    runner: RuntimeRunner,
    supervisor: *process_supervisor.Supervisor,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        pack_dir: []const u8,
        compiled: *const contract.CompiledPack,
        seed: u64,
        native_bindings: []const NativeBinding,
    ) !Runtime {
        const supervisor = try arena.create(process_supervisor.Supervisor);
        supervisor.* = .{
            .io = io,
            .allocator = allocator,
        };

        var self = Runtime{
            .io = io,
            .allocator = allocator,
            .arena = arena,
            .pack_dir = pack_dir,
            .compiled = compiled,
            .runner = RuntimeRunner.init(
                seed,
                compiled.targets[0..compiled.target_count],
            ),
            .supervisor = supervisor,
        };
        errdefer supervisor.deinit();

        try self.bind(native_bindings);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.supervisor.deinit();
    }

    pub fn seedInputs(self: *Runtime, inputs: []const SeedInput) !void {
        for (inputs) |input| {
            const variable_id = self.compiled.variableId(input.name) orelse
                return error.UnknownInputVariable;
            const schema = self.runner.registry.variableSchema(variable_id) orelse
                return error.UnknownInputVariable;
            const value = try parseValue(self.arena, schema.variable.kind, input.value);
            _ = try self.runner.seedVariable(
                variable_id,
                .observed,
                value,
                input.confidence_permille,
            );
        }
    }

    fn bind(self: *Runtime, native_bindings: []const NativeBinding) !void {
        for (self.compiled.variables[0..self.compiled.variable_count]) |variable| {
            try self.runner.addVariable(variable);
        }
        for (self.compiled.invariants[0..self.compiled.invariant_count]) |*invariant| {
            try self.runner.addInvariant(invariant.asCore());
        }

        for (self.compiled.operators[0..self.compiled.operator_count]) |*operator| {
            switch (operator.runtime.kind) {
                .native => {
                    const binding_name = operator.runtime.target orelse operator.name;
                    const binding = findNativeBinding(native_bindings, binding_name) orelse
                        return error.UnboundNativeOperator;
                    try self.runner.addOperator(
                        operator.asRegistered(),
                        binding.context,
                        binding.execute_fn,
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
        self: *Runtime,
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

    fn makeInvocation(
        self: *Runtime,
        decl: contract.RuntimeDecl,
    ) !external.Invocation {
        const target = decl.target orelse return error.MissingRuntimeTarget;
        return switch (decl.kind) {
            .native => unreachable,
            .python => .{ .python = .{
                .target = try resolvePackTarget(self.arena, self.pack_dir, target),
                .timeout_ms = decl.timeout_ms,
            } },
            .subprocess => blk: {
                const argv = try self.arena.alloc([]const u8, decl.args.len + 1);
                argv[0] = try resolvePackTarget(self.arena, self.pack_dir, target);
                for (decl.args, 0..) |arg, i| {
                    argv[i + 1] = try resolveRuntimeArg(self.arena, self.pack_dir, arg);
                }
                break :blk .{ .subprocess = .{
                    .argv = argv,
                    .timeout_ms = decl.timeout_ms,
                } };
            },
        };
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
        obs: RuntimeRunner.Observation,
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

fn findNativeBinding(
    bindings: []const NativeBinding,
    name: []const u8,
) ?NativeBinding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding;
    }
    return null;
}

fn resolvePackTarget(
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    target: []const u8,
) ![]const u8 {
    if (target.len == 0) return error.MissingRuntimeTarget;
    if (std.fs.path.isAbsolute(target)) return target;

    if (std.mem.indexOfAny(u8, target, "/\\") == null) {
        return target;
    }
    try rejectParentTraversal(target);
    return std.fs.path.join(arena, &.{ pack_dir, target });
}

fn resolveRuntimeArg(
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    arg: []const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, arg, "./") or
        std.mem.startsWith(u8, arg, ".\\"))
    {
        const relative = arg[2..];
        try rejectParentTraversal(relative);
        return std.fs.path.join(arena, &.{ pack_dir, relative });
    }
    return arg;
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
        .integer => .{ .integer = std.fmt.parseInt(i64, text, 10) catch
            return error.InvalidInputValue },
        .float => .{ .float = std.fmt.parseFloat(f64, text) catch
            return error.InvalidInputValue },
        .boolean => blk: {
            if (std.mem.eql(u8, text, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, text, "false")) break :blk .{ .boolean = false };
            return error.InvalidInputValue;
        },
        .text => .{ .text = try arena.dupe(u8, text) },
        .artifact_ref => .{ .artifact_ref = run_store.parseRunId(text) catch
            return error.InvalidInputValue },
    };
}

test "runtime input parser follows declared variable type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(core.Value.eql(
        try parseValue(arena, .integer, "42"),
        .{ .integer = 42 },
    ));
    try std.testing.expect(core.Value.eql(
        try parseValue(arena, .boolean, "true"),
        .{ .boolean = true },
    ));
    try std.testing.expectError(
        error.InvalidInputValue,
        parseValue(arena, .boolean, "yes"),
    );
}

test "runtime path resolution keeps explicit pack-relative args local" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try resolveRuntimeArg(
        arena_state.allocator(),
        "packs/demo",
        "./operators/check.sh",
    );
    try std.testing.expectEqualStrings(
        "packs/demo/operators/check.sh",
        result,
    );
    try std.testing.expectError(
        error.RuntimePathEscapesPack,
        resolvePackTarget(
            arena_state.allocator(),
            "packs/demo",
            "operators/../secret",
        ),
    );
}
