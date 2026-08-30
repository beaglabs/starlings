const std = @import("std");
const core = @import("core_types.zig");

pub const VariableSchema = struct {
    variable: core.Variable,
    freshness_rounds: ?u32 = null,
};

pub const DependencyTerm = union(enum) {
    variable_known: core.VariableId,
    variable_resolved: core.VariableId,
    invariant_satisfied: core.InvariantId,
};

pub const DependencyMode = enum(u8) {
    all,
    any,
};

pub const DependencyExpr = struct {
    mode: DependencyMode = .all,
    terms: []const DependencyTerm = &.{},
};

pub const RegisteredOperator = struct {
    manifest: core.OperatorManifest,
    eligibility: DependencyExpr = .{},
};

pub fn Registry(
    comptime max_variables: usize,
    comptime max_invariants: usize,
    comptime max_operators: usize,
) type {
    return struct {
        const Self = @This();

        variables: [max_variables]VariableSchema = undefined,
        variable_count: usize = 0,
        invariants: [max_invariants]core.Invariant = undefined,
        invariant_count: usize = 0,
        operators: [max_operators]RegisteredOperator = undefined,
        operator_count: usize = 0,

        pub fn addVariable(self: *Self, schema: VariableSchema) !void {
            if (self.variable_count >= max_variables) return error.RegistryCapacityExceeded;
            if (self.variableIndex(schema.variable.id) != null) return error.DuplicateVariable;
            self.variables[self.variable_count] = schema;
            self.variable_count += 1;
        }

        pub fn addInvariant(self: *Self, invariant: core.Invariant) !void {
            if (self.invariant_count >= max_invariants) return error.RegistryCapacityExceeded;
            if (self.invariantIndex(invariant.id) != null) return error.DuplicateInvariant;
            for (invariant.requires) |id| {
                if (self.variableIndex(id) == null) return error.UnknownVariable;
            }
            self.invariants[self.invariant_count] = invariant;
            self.invariant_count += 1;
        }

        pub fn addOperator(self: *Self, op: RegisteredOperator) !void {
            if (self.operator_count >= max_operators) return error.RegistryCapacityExceeded;
            if (self.operatorIndex(op.manifest.id) != null) return error.DuplicateOperator;

            for (op.manifest.requires_variables) |id| {
                if (self.variableIndex(id) == null) return error.UnknownVariable;
            }
            for (op.manifest.provides_variables) |id| {
                if (self.variableIndex(id) == null) return error.UnknownVariable;
            }
            for (op.manifest.requires_invariants) |id| {
                if (self.invariantIndex(id) == null) return error.UnknownInvariant;
            }
            for (op.manifest.provides_invariants) |id| {
                if (self.invariantIndex(id) == null) return error.UnknownInvariant;
            }
            for (op.eligibility.terms) |term| {
                switch (term) {
                    .variable_known, .variable_resolved => |id| {
                        if (self.variableIndex(id) == null) return error.UnknownVariable;
                    },
                    .invariant_satisfied => |id| {
                        if (self.invariantIndex(id) == null) return error.UnknownInvariant;
                    },
                }
            }

            self.operators[self.operator_count] = op;
            self.operator_count += 1;
        }

        pub fn variableIndex(self: *const Self, id: core.VariableId) ?usize {
            var i: usize = 0;
            while (i < self.variable_count) : (i += 1) {
                if (self.variables[i].variable.id == id) return i;
            }
            return null;
        }

        pub fn invariantIndex(self: *const Self, id: core.InvariantId) ?usize {
            var i: usize = 0;
            while (i < self.invariant_count) : (i += 1) {
                if (self.invariants[i].id == id) return i;
            }
            return null;
        }

        pub fn operatorIndex(self: *const Self, id: core.OperatorId) ?usize {
            var i: usize = 0;
            while (i < self.operator_count) : (i += 1) {
                if (self.operators[i].manifest.id == id) return i;
            }
            return null;
        }
    };
}

pub const VariableCell = struct {
    status: core.EpistemicStatus = .unknown,
    value: ?core.Value = null,
    updated_round: u32 = 0,
};

pub const InvariantCell = struct {
    status: core.InvariantStatus = .unknown,
    updated_round: u32 = 0,
};

pub fn ContextState(comptime max_variables: usize, comptime max_invariants: usize) type {
    return struct {
        const Self = @This();

        variables: [max_variables]VariableCell = [_]VariableCell{.{}} ** max_variables,
        invariants: [max_invariants]InvariantCell = [_]InvariantCell{.{}} ** max_invariants,

        pub fn setVariable(
            self: *Self,
            registry: anytype,
            id: core.VariableId,
            status: core.EpistemicStatus,
            value: ?core.Value,
            round: u32,
        ) !void {
            const index = registry.variableIndex(id) orelse return error.UnknownVariable;
            if (index >= max_variables) return error.RegistryCapacityExceeded;
            if (status.carriesValue() != (value != null)) return error.InvalidEpistemicValue;
            if (value) |v| {
                if (v.kind() != registry.variables[index].variable.kind) return error.VariableTypeMismatch;
            }
            self.variables[index] = .{
                .status = status,
                .value = value,
                .updated_round = round,
            };
        }

        pub fn setInvariant(
            self: *Self,
            registry: anytype,
            id: core.InvariantId,
            status: core.InvariantStatus,
            round: u32,
        ) !void {
            const index = registry.invariantIndex(id) orelse return error.UnknownInvariant;
            if (index >= max_invariants) return error.RegistryCapacityExceeded;
            self.invariants[index] = .{ .status = status, .updated_round = round };
        }

        pub fn variableCell(self: *const Self, registry: anytype, id: core.VariableId) ?VariableCell {
            const index = registry.variableIndex(id) orelse return null;
            if (index >= max_variables) return null;
            return self.variables[index];
        }

        pub fn invariantCell(self: *const Self, registry: anytype, id: core.InvariantId) ?InvariantCell {
            const index = registry.invariantIndex(id) orelse return null;
            if (index >= max_invariants) return null;
            return self.invariants[index];
        }
    };
}

test "registry rejects duplicate and dangling declarations" {
    const R = Registry(4, 2, 2);
    var registry = R{};

    try registry.addVariable(.{ .variable = .{ .id = 1, .name = "image", .kind = .artifact_ref } });
    try std.testing.expectError(error.DuplicateVariable, registry.addVariable(.{
        .variable = .{ .id = 1, .name = "again", .kind = .artifact_ref },
    }));

    try std.testing.expectError(error.UnknownVariable, registry.addInvariant(.{
        .id = 1,
        .name = "needs_missing",
        .requires = &.{99},
    }));

    try std.testing.expectError(error.UnknownVariable, registry.addOperator(.{
        .manifest = .{
            .id = 1,
            .name = "bad",
            .requires_variables = &.{99},
        },
    }));
}

test "context state enforces declared variable types" {
    const R = Registry(2, 1, 1);
    const S = ContextState(2, 1);
    var registry = R{};
    var state = S{};

    try registry.addVariable(.{ .variable = .{ .id = 7, .name = "temperature", .kind = .float } });
    try state.setVariable(&registry, 7, .observed, .{ .float = 21.5 }, 1);
    try std.testing.expectError(
        error.VariableTypeMismatch,
        state.setVariable(&registry, 7, .observed, .{ .integer = 21 }, 2),
    );
}
