const std = @import("std");
const core = @import("../sdk/core_types.zig");
const reg = @import("../sdk/registry.zig");

pub const api_version = "starlings/v1";
pub const kind_name = "EmergencePack";

pub const max_variables: usize = 256;
pub const max_invariants: usize = 128;
pub const max_operators: usize = 128;
pub const max_targets: usize = 64;
pub const max_dependencies: usize = 64;
pub const max_runtime_args: usize = 16;

pub const OperatorRole = enum {
    model,
    collector,
    tool,
    transform,
    validator,
    actor,
};

pub const RuntimeKind = enum {
    native,
    python,
    subprocess,
    model,
};

pub const ValueType = enum {
    integer,
    float,
    boolean,
    text,
    artifact_ref,
};

pub const Merge = enum {
    latest,
    highest_confidence,
    retain_all_conflict,
};

pub const Metadata = struct {
    name: []const u8,
    version: []const u8,
};

pub const StateFiles = struct {
    variables: []const u8,
    invariants: []const u8,
};

pub const PopulationFiles = struct {
    operators: []const u8,
};

pub const PolicyFiles = struct {
    actions: []const u8,
};

pub const Manifest = struct {
    apiVersion: []const u8,
    kind: []const u8,
    metadata: Metadata,
    state: StateFiles,
    population: PopulationFiles,
    policy: ?PolicyFiles = null,
    targets: []const []const u8,
};

pub const VariableDecl = struct {
    name: []const u8,
    @"type": ValueType,
    unit: ?[]const u8 = null,
    merge: Merge = .retain_all_conflict,
    freshness_rounds: ?u32 = null,
};

pub const VariableFile = struct {
    variables: []const VariableDecl,
};

pub const InvariantDecl = struct {
    name: []const u8,
    requires: []const []const u8 = &.{},
};

pub const InvariantFile = struct {
    invariants: []const InvariantDecl,
};

pub const RequirementSet = struct {
    variables: []const []const u8 = &.{},
    invariants: []const []const u8 = &.{},
};

pub const RuntimeDecl = struct {
    kind: RuntimeKind,
    target: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    timeout_ms: u32 = 30_000,
    profile: ?[]const u8 = null,
};

pub const OperatorDecl = struct {
    name: []const u8,
    role: OperatorRole = .transform,
    runtime: RuntimeDecl,
    requires: RequirementSet = .{},
    provides: RequirementSet = .{},
};

pub const OperatorFile = struct {
    operators: []const OperatorDecl,
};

pub const Spec = struct {
    manifest: Manifest,
    variable_file: VariableFile,
    invariant_file: InvariantFile,
    operator_file: OperatorFile,
};

pub const CompiledInvariant = struct {
    id: core.InvariantId,
    name: []const u8,
    requires: [max_dependencies]core.VariableId = undefined,
    require_count: usize = 0,

    pub fn asCore(self: *const CompiledInvariant) core.Invariant {
        return .{
            .id = self.id,
            .name = self.name,
            .requires = self.requires[0..self.require_count],
        };
    }
};

pub const CompiledOperator = struct {
    id: core.OperatorId,
    name: []const u8,
    role: OperatorRole,
    runtime: RuntimeDecl,
    requires_variables: [max_dependencies]core.VariableId = undefined,
    requires_variable_count: usize = 0,
    requires_invariants: [max_dependencies]core.InvariantId = undefined,
    requires_invariant_count: usize = 0,
    provides_variables: [max_dependencies]core.VariableId = undefined,
    provides_variable_count: usize = 0,
    provides_invariants: [max_dependencies]core.InvariantId = undefined,
    provides_invariant_count: usize = 0,

    pub fn asRegistered(self: *const CompiledOperator) reg.RegisteredOperator {
        return .{
            .manifest = .{
                .id = self.id,
                .name = self.name,
                .requires_variables = self.requires_variables[0..self.requires_variable_count],
                .requires_invariants = self.requires_invariants[0..self.requires_invariant_count],
                .provides_variables = self.provides_variables[0..self.provides_variable_count],
                .provides_invariants = self.provides_invariants[0..self.provides_invariant_count],
            },
        };
    }
};

pub const CompiledPack = struct {
    name: []const u8,
    version: []const u8,
    variables: [max_variables]reg.VariableSchema = undefined,
    variable_count: usize = 0,
    invariants: [max_invariants]CompiledInvariant = undefined,
    invariant_count: usize = 0,
    operators: [max_operators]CompiledOperator = undefined,
    operator_count: usize = 0,
    targets: [max_targets]core.VariableId = undefined,
    target_count: usize = 0,

    pub fn registerInto(self: *const CompiledPack, registry: anytype) !void {
        for (self.variables[0..self.variable_count]) |variable| {
            try registry.addVariable(variable);
        }
        for (self.invariants[0..self.invariant_count]) |*invariant| {
            try registry.addInvariant(invariant.asCore());
        }
        for (self.operators[0..self.operator_count]) |*operator| {
            try registry.addOperator(operator.asRegistered());
        }
    }

    pub fn variableId(self: *const CompiledPack, name: []const u8) ?core.VariableId {
        for (self.variables[0..self.variable_count]) |schema| {
            if (std.mem.eql(u8, schema.variable.name, name)) return schema.variable.id;
        }
        return null;
    }

    pub fn invariantId(self: *const CompiledPack, name: []const u8) ?core.InvariantId {
        for (self.invariants[0..self.invariant_count]) |invariant| {
            if (std.mem.eql(u8, invariant.name, name)) return invariant.id;
        }
        return null;
    }

    pub fn operatorId(self: *const CompiledPack, name: []const u8) ?core.OperatorId {
        for (self.operators[0..self.operator_count]) |operator| {
            if (std.mem.eql(u8, operator.name, name)) return operator.id;
        }
        return null;
    }
};

pub fn compile(spec: Spec) !CompiledPack {
    try validateManifest(spec.manifest);

    if (spec.variable_file.variables.len > max_variables) return error.PackCapacityExceeded;
    if (spec.invariant_file.invariants.len > max_invariants) return error.PackCapacityExceeded;
    if (spec.operator_file.operators.len > max_operators) return error.PackCapacityExceeded;
    if (spec.manifest.targets.len > max_targets) return error.PackCapacityExceeded;

    var compiled = CompiledPack{
        .name = spec.manifest.metadata.name,
        .version = spec.manifest.metadata.version,
    };

    for (spec.variable_file.variables) |decl| {
        if (decl.name.len == 0) return error.EmptyName;
        if (compiled.variableId(decl.name) != null) return error.DuplicateVariable;

        const id = stableId(core.VariableId, "starlings-pack-variable-v1", decl.name);
        for (compiled.variables[0..compiled.variable_count]) |existing| {
            if (existing.variable.id == id) return error.IdentifierCollision;
        }

        compiled.variables[compiled.variable_count] = .{
            .variable = .{
                .id = id,
                .name = decl.name,
                .kind = valueKind(decl.@"type"),
                .unit = decl.unit,
                .merge_policy = mergePolicy(decl.merge),
            },
            .freshness_rounds = decl.freshness_rounds,
        };
        compiled.variable_count += 1;
    }

    for (spec.invariant_file.invariants) |decl| {
        if (decl.name.len == 0) return error.EmptyName;
        if (compiled.invariantId(decl.name) != null) return error.DuplicateInvariant;
        if (decl.requires.len > max_dependencies) return error.PackCapacityExceeded;

        const id = stableId(core.InvariantId, "starlings-pack-invariant-v1", decl.name);
        for (compiled.invariants[0..compiled.invariant_count]) |existing| {
            if (existing.id == id) return error.IdentifierCollision;
        }

        var invariant = CompiledInvariant{
            .id = id,
            .name = decl.name,
        };
        for (decl.requires) |variable_name| {
            const variable_id = compiled.variableId(variable_name) orelse return error.UnknownVariable;
            if (containsId(core.VariableId, invariant.requires[0..invariant.require_count], variable_id)) {
                return error.DuplicateDependency;
            }
            invariant.requires[invariant.require_count] = variable_id;
            invariant.require_count += 1;
        }

        compiled.invariants[compiled.invariant_count] = invariant;
        compiled.invariant_count += 1;
    }

    for (spec.operator_file.operators) |decl| {
        if (decl.name.len == 0) return error.EmptyName;
        if (compiled.operatorId(decl.name) != null) return error.DuplicateOperator;
        try validateRuntime(decl.runtime);

        if (decl.requires.variables.len > max_dependencies or
            decl.requires.invariants.len > max_dependencies or
            decl.provides.variables.len > max_dependencies or
            decl.provides.invariants.len > max_dependencies)
        {
            return error.PackCapacityExceeded;
        }

        const id = stableId(core.OperatorId, "starlings-pack-operator-v1", decl.name);
        for (compiled.operators[0..compiled.operator_count]) |existing| {
            if (existing.id == id) return error.IdentifierCollision;
        }

        var operator = CompiledOperator{
            .id = id,
            .name = decl.name,
            .role = decl.role,
            .runtime = decl.runtime,
        };

        for (decl.requires.variables) |name| {
            const variable_id = compiled.variableId(name) orelse return error.UnknownVariable;
            if (containsId(core.VariableId, operator.requires_variables[0..operator.requires_variable_count], variable_id)) {
                return error.DuplicateDependency;
            }
            operator.requires_variables[operator.requires_variable_count] = variable_id;
            operator.requires_variable_count += 1;
        }

        for (decl.requires.invariants) |name| {
            const invariant_id = compiled.invariantId(name) orelse return error.UnknownInvariant;
            if (containsId(core.InvariantId, operator.requires_invariants[0..operator.requires_invariant_count], invariant_id)) {
                return error.DuplicateDependency;
            }
            operator.requires_invariants[operator.requires_invariant_count] = invariant_id;
            operator.requires_invariant_count += 1;
        }

        for (decl.provides.variables) |name| {
            const variable_id = compiled.variableId(name) orelse return error.UnknownVariable;
            if (containsId(core.VariableId, operator.provides_variables[0..operator.provides_variable_count], variable_id)) {
                return error.DuplicateDependency;
            }
            operator.provides_variables[operator.provides_variable_count] = variable_id;
            operator.provides_variable_count += 1;
        }

        for (decl.provides.invariants) |name| {
            const invariant_id = compiled.invariantId(name) orelse return error.UnknownInvariant;
            if (containsId(core.InvariantId, operator.provides_invariants[0..operator.provides_invariant_count], invariant_id)) {
                return error.DuplicateDependency;
            }
            operator.provides_invariants[operator.provides_invariant_count] = invariant_id;
            operator.provides_invariant_count += 1;
        }

        compiled.operators[compiled.operator_count] = operator;
        compiled.operator_count += 1;
    }

    for (spec.manifest.targets) |target_name| {
        const target_id = compiled.variableId(target_name) orelse return error.UnknownTarget;
        if (containsId(core.VariableId, compiled.targets[0..compiled.target_count], target_id)) {
            return error.DuplicateTarget;
        }
        compiled.targets[compiled.target_count] = target_id;
        compiled.target_count += 1;
    }

    if (compiled.target_count == 0) return error.MissingTarget;
    return compiled;
}

fn validateManifest(manifest: Manifest) !void {
    if (!std.mem.eql(u8, manifest.apiVersion, api_version)) return error.UnsupportedApiVersion;
    if (!std.mem.eql(u8, manifest.kind, kind_name)) return error.UnsupportedKind;
    if (manifest.metadata.name.len == 0 or manifest.metadata.version.len == 0) return error.InvalidMetadata;
    if (manifest.state.variables.len == 0 or
        manifest.state.invariants.len == 0 or
        manifest.population.operators.len == 0)
    {
        return error.InvalidManifestPath;
    }
    if (manifest.policy) |policy| {
        if (policy.actions.len == 0) return error.InvalidManifestPath;
    }
}

fn validateRuntime(runtime: RuntimeDecl) !void {
    if (runtime.timeout_ms == 0) return error.InvalidRuntimeTimeout;
    if (runtime.args.len > max_runtime_args) return error.PackCapacityExceeded;

    switch (runtime.kind) {
        .native => {
            if (runtime.args.len != 0) return error.NativeRuntimeArgumentsForbidden;
            if (runtime.profile != null) return error.RuntimeProfileUnsupported;
        },
        .python => {
            const target = runtime.target orelse return error.MissingRuntimeTarget;
            if (target.len == 0) return error.MissingRuntimeTarget;
            if (runtime.args.len != 0) return error.PythonRuntimeArgumentsUnsupported;
            if (runtime.profile != null) return error.RuntimeProfileUnsupported;
        },
        .subprocess => {
            const target = runtime.target orelse return error.MissingRuntimeTarget;
            if (target.len == 0) return error.MissingRuntimeTarget;
            if (runtime.profile != null) return error.RuntimeProfileUnsupported;
        },
        .model => {
            const target = runtime.target orelse return error.MissingRuntimeTarget;
            if (target.len == 0) return error.MissingRuntimeTarget;
            if (runtime.args.len != 0) return error.ModelRuntimeArgumentsUnsupported;
        },
    }
}

fn valueKind(value_type: ValueType) core.ValueKind {
    return switch (value_type) {
        .integer => .integer,
        .float => .float,
        .boolean => .boolean,
        .text => .text,
        .artifact_ref => .artifact_ref,
    };
}

fn mergePolicy(merge: Merge) core.MergePolicy {
    return switch (merge) {
        .latest => .latest,
        .highest_confidence => .highest_confidence,
        .retain_all_conflict => .retain_all_conflict,
    };
}

fn containsId(comptime T: type, values: []const T, needle: T) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn stableId(comptime T: type, domain: []const u8, name: []const u8) T {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(domain);
    hasher.update(&.{0});
    hasher.update(name);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var raw: u32 =
        @as(u32, digest[0]) |
        (@as(u32, digest[1]) << 8) |
        (@as(u32, digest[2]) << 16) |
        (@as(u32, digest[3]) << 24);
    if (raw == 0) raw = 1;
    return @as(T, @intCast(raw));
}

test "pack contract compiles into SDK registry without workflow edges" {
    const variables = [_]VariableDecl{
        .{ .name = "task.text", .@"type" = .text },
        .{ .name = "task.embedding", .@"type" = .artifact_ref },
        .{ .name = "patch.validated", .@"type" = .boolean },
    };
    const invariants = [_]InvariantDecl{
        .{ .name = "has_task", .requires = &.{"task.text"} },
    };
    const operators = [_]OperatorDecl{
        .{
            .name = "task-encoder",
            .runtime = .{ .kind = .python, .target = "operators/task_encoder.py" },
            .requires = .{ .variables = &.{"task.text"} },
            .provides = .{ .variables = &.{"task.embedding"} },
        },
        .{
            .name = "validator",
            .runtime = .{ .kind = .native },
            .requires = .{
                .variables = &.{"task.embedding"},
                .invariants = &.{"has_task"},
            },
            .provides = .{ .variables = &.{"patch.validated"} },
        },
    };

    const spec = Spec{
        .manifest = .{
            .apiVersion = api_version,
            .kind = kind_name,
            .metadata = .{ .name = "coding-local", .version = "0.1.0" },
            .state = .{ .variables = "variables.yaml", .invariants = "invariants.yaml" },
            .population = .{ .operators = "operators.yaml" },
            .targets = &.{"patch.validated"},
        },
        .variable_file = .{ .variables = &variables },
        .invariant_file = .{ .invariants = &invariants },
        .operator_file = .{ .operators = &operators },
    };

    var compiled = try compile(spec);
    try std.testing.expectEqual(@as(usize, 3), compiled.variable_count);
    try std.testing.expectEqual(@as(usize, 1), compiled.invariant_count);
    try std.testing.expectEqual(@as(usize, 2), compiled.operator_count);
    try std.testing.expectEqual(@as(usize, 1), compiled.target_count);

    const R = reg.Registry(max_variables, max_invariants, max_operators);
    var registry = R{};
    try compiled.registerInto(&registry);

    try std.testing.expectEqual(compiled.variable_count, registry.variable_count);
    try std.testing.expectEqual(compiled.invariant_count, registry.invariant_count);
    try std.testing.expectEqual(compiled.operator_count, registry.operator_count);
}

test "runtime declarations accept bounded subprocess argv" {
    const variables = [_]VariableDecl{
        .{ .name = "done", .@"type" = .boolean },
    };
    const operators = [_]OperatorDecl{
        .{
            .name = "shell-check",
            .runtime = .{
                .kind = .subprocess,
                .target = "/bin/sh",
                .args = &.{ "operators/check.sh" },
                .timeout_ms = 1500,
            },
            .provides = .{ .variables = &.{"done"} },
        },
    };

    const compiled = try compile(.{
        .manifest = .{
            .apiVersion = api_version,
            .kind = kind_name,
            .metadata = .{ .name = "runtime-args", .version = "0.1.0" },
            .state = .{ .variables = "variables.yaml", .invariants = "invariants.yaml" },
            .population = .{ .operators = "operators.yaml" },
            .targets = &.{"done"},
        },
        .variable_file = .{ .variables = &variables },
        .invariant_file = .{ .invariants = &.{} },
        .operator_file = .{ .operators = &operators },
    });

    try std.testing.expectEqual(@as(usize, 1), compiled.operators[0].runtime.args.len);
    try std.testing.expectEqual(@as(u32, 1500), compiled.operators[0].runtime.timeout_ms);
}

test "stable pack identifiers do not depend on declaration order" {
    const a = stableId(core.VariableId, "starlings-pack-variable-v1", "task.text");
    const b = stableId(core.VariableId, "starlings-pack-variable-v1", "task.text");
    const c = stableId(core.VariableId, "starlings-pack-variable-v1", "task.embedding");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "pack contract rejects dangling dependencies and targets" {
    const variables = [_]VariableDecl{
        .{ .name = "task.text", .@"type" = .text },
    };
    const bad_operators = [_]OperatorDecl{
        .{
            .name = "bad",
            .runtime = .{ .kind = .native },
            .requires = .{ .variables = &.{"missing"} },
        },
    };

    const base_manifest = Manifest{
        .apiVersion = api_version,
        .kind = kind_name,
        .metadata = .{ .name = "bad", .version = "0.1.0" },
        .state = .{ .variables = "variables.yaml", .invariants = "invariants.yaml" },
        .population = .{ .operators = "operators.yaml" },
        .targets = &.{"task.text"},
    };

    try std.testing.expectError(error.UnknownVariable, compile(.{
        .manifest = base_manifest,
        .variable_file = .{ .variables = &variables },
        .invariant_file = .{ .invariants = &.{} },
        .operator_file = .{ .operators = &bad_operators },
    }));

    var bad_target = base_manifest;
    bad_target.targets = &.{"missing"};
    try std.testing.expectError(error.UnknownTarget, compile(.{
        .manifest = bad_target,
        .variable_file = .{ .variables = &variables },
        .invariant_file = .{ .invariants = &.{} },
        .operator_file = .{ .operators = &.{} },
    }));
}
