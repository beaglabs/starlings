const std = @import("std");
const core = @import("core_types.zig");
const reg = @import("registry.zig");

pub fn variableFresh(registry: anytype, state: anytype, id: core.VariableId, round: u32) bool {
    const cell = state.variableCell(registry, id) orelse return false;
    if (!cell.status.isResolved()) return false;

    const schema = registry.variableSchema(id) orelse return false;
    if (schema.freshness_rounds) |ttl| {
        if (round < cell.updated_round) return false;
        return (round - cell.updated_round) <= ttl;
    }
    return true;
}

pub fn termSatisfied(registry: anytype, state: anytype, term: reg.DependencyTerm, round: u32) bool {
    return switch (term) {
        .variable_known => |id| blk: {
            if (!variableFresh(registry, state, id, round)) break :blk false;
            const cell = state.variableCell(registry, id) orelse break :blk false;
            break :blk cell.status.carriesValue();
        },
        .variable_resolved => |id| variableFresh(registry, state, id, round),
        .invariant_satisfied => |id| blk: {
            const cell = state.invariantCell(registry, id) orelse break :blk false;
            break :blk cell.status == .satisfied;
        },
    };
}

pub fn expressionSatisfied(registry: anytype, state: anytype, expr: reg.DependencyExpr, round: u32) bool {
    if (expr.terms.len == 0) return expr.mode == .all;

    return switch (expr.mode) {
        .all => blk: {
            for (expr.terms) |term| {
                if (!termSatisfied(registry, state, term, round)) break :blk false;
            }
            break :blk true;
        },
        .any => blk: {
            for (expr.terms) |term| {
                if (termSatisfied(registry, state, term, round)) break :blk true;
            }
            break :blk false;
        },
    };
}

pub fn operatorEligible(registry: anytype, state: anytype, operator_index: usize, round: u32) bool {
    if (operator_index >= registry.operator_count) return false;
    const op = registry.operators[operator_index];

    for (op.manifest.requires_variables) |id| {
        if (!termSatisfied(registry, state, .{ .variable_known = id }, round)) return false;
    }
    for (op.manifest.requires_invariants) |id| {
        if (!termSatisfied(registry, state, .{ .invariant_satisfied = id }, round)) return false;
    }

    return expressionSatisfied(registry, state, op.eligibility, round);
}

pub fn eligibleOperators(
    registry: anytype,
    state: anytype,
    round: u32,
    out: []core.OperatorId,
) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < registry.operator_count) : (i += 1) {
        if (!operatorEligible(registry, state, i, round)) continue;
        if (count >= out.len) return error.OutputCapacityExceeded;
        out[count] = registry.operators[i].manifest.id;
        count += 1;
    }
    return count;
}

test "freshness controls local eligibility" {
    const R = reg.Registry(3, 1, 2);
    const S = reg.ContextState(3, 1);
    var registry = R{};
    var state = S{};

    try registry.addVariable(.{
        .variable = .{ .id = 1, .name = "sensor", .kind = .float },
        .freshness_rounds = 2,
    });
    try registry.addVariable(.{ .variable = .{ .id = 2, .name = "derived", .kind = .float } });

    try registry.addOperator(.{
        .manifest = .{
            .id = 10,
            .name = "derive",
            .requires_variables = &.{1},
            .provides_variables = &.{2},
        },
    });

    try state.setVariable(&registry, 1, .observed, .{ .float = 3.0 }, 5);
    try std.testing.expect(operatorEligible(&registry, &state, 0, 7));
    try std.testing.expect(!operatorEligible(&registry, &state, 0, 8));
}

test "dependency expressions support any and invariant prerequisites" {
    const R = reg.Registry(3, 1, 2);
    const S = reg.ContextState(3, 1);
    var registry = R{};
    var state = S{};

    try registry.addVariable(.{ .variable = .{ .id = 1, .name = "a", .kind = .boolean } });
    try registry.addVariable(.{ .variable = .{ .id = 2, .name = "b", .kind = .boolean } });
    try registry.addVariable(.{ .variable = .{ .id = 3, .name = "out", .kind = .boolean } });
    try registry.addInvariant(.{ .id = 4, .name = "safe", .requires = &.{1} });

    const terms = [_]reg.DependencyTerm{
        .{ .variable_known = 1 },
        .{ .variable_known = 2 },
    };

    try registry.addOperator(.{
        .manifest = .{
            .id = 10,
            .name = "any-input",
            .provides_variables = &.{3},
        },
        .eligibility = .{ .mode = .any, .terms = &terms },
    });
    try registry.addOperator(.{
        .manifest = .{
            .id = 11,
            .name = "safe-only",
            .requires_invariants = &.{4},
            .provides_variables = &.{3},
        },
    });

    try state.setVariable(&registry, 2, .observed, .{ .boolean = true }, 1);
    try std.testing.expect(operatorEligible(&registry, &state, 0, 1));
    try std.testing.expect(!operatorEligible(&registry, &state, 1, 1));

    try state.setInvariant(&registry, 4, .satisfied, 1);
    try std.testing.expect(operatorEligible(&registry, &state, 1, 1));
}


test "zero-invariant registries support variable-only eligibility" {
    const R = reg.Registry(2, 0, 1);
    const S = reg.ContextState(2, 0);
    var registry = R{};
    var state = S{};

    try registry.addVariable(.{ .variable = .{ .id = 1, .name = "input", .kind = .integer } });
    try registry.addVariable(.{ .variable = .{ .id = 2, .name = "output", .kind = .integer } });
    try registry.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "variable-only",
        .requires_variables = &.{1},
        .provides_variables = &.{2},
    } });

    try state.setVariable(&registry, 1, .observed, .{ .integer = 7 }, 1);
    try std.testing.expect(registry.invariantIndex(99) == null);
    try std.testing.expect(state.invariantCell(&registry, 99) == null);
    try std.testing.expect(operatorEligible(&registry, &state, 0, 1));
}


test "zero-variable registries support operator-only eligibility" {
    const R = reg.Registry(0, 0, 1);
    const S = reg.ContextState(0, 0);
    var registry = R{};
    var state = S{};

    try registry.addOperator(.{ .manifest = .{
        .id = 10,
        .name = "side-effect-only",
    } });

    try std.testing.expect(registry.variableIndex(1) == null);
    try std.testing.expect(state.variableCell(&registry, 1) == null);
    try std.testing.expect(operatorEligible(&registry, &state, 0, 0));
}
