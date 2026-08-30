const std = @import("std");
const yaml_lib = @import("yaml");
const contract = @import("contract.zig");

const Yaml = yaml_lib.Yaml;
const Value = Yaml.Value;
const Map = Yaml.Map;

pub const max_pack_file_bytes: usize = 4 * 1024 * 1024;

pub fn loadAndCompile(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pack_dir: []const u8,
) !contract.CompiledPack {
    var dir = try std.Io.Dir.cwd().openDir(io, pack_dir, .{});
    defer dir.close(io);

    const manifest_source = try dir.readFileAlloc(
        io,
        "pack.yaml",
        arena,
        .limited(max_pack_file_bytes),
    );
    const manifest = try parseManifest(gpa, arena, manifest_source);

    try validatePackRelativePath(manifest.state.variables);
    try validatePackRelativePath(manifest.state.invariants);
    try validatePackRelativePath(manifest.population.operators);

    const variable_source = try dir.readFileAlloc(
        io,
        manifest.state.variables,
        arena,
        .limited(max_pack_file_bytes),
    );
    const invariant_source = try dir.readFileAlloc(
        io,
        manifest.state.invariants,
        arena,
        .limited(max_pack_file_bytes),
    );
    const operator_source = try dir.readFileAlloc(
        io,
        manifest.population.operators,
        arena,
        .limited(max_pack_file_bytes),
    );

    if (manifest.policy) |policy| {
        try validatePackRelativePath(policy.actions);
        const policy_source = try dir.readFileAlloc(
            io,
            policy.actions,
            arena,
            .limited(max_pack_file_bytes),
        );
        try validatePolicySource(gpa, policy_source);
    }

    const variables = try parseVariables(gpa, arena, variable_source);
    const invariants = try parseInvariants(gpa, arena, invariant_source);
    const operators = try parseOperators(gpa, arena, operator_source);

    return contract.compile(.{
        .manifest = manifest,
        .variable_file = variables,
        .invariant_file = invariants,
        .operator_file = operators,
    });
}

pub fn parseManifest(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.Manifest {
    var yaml = Yaml{ .source = source };
    defer yaml.deinit(gpa);
    try yaml.load(gpa);
    const root = try singleDocument(&yaml);
    try validateManifestSchema(root);
    return try yaml.parse(arena, contract.Manifest);
}

pub fn parseVariables(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.VariableFile {
    var yaml = Yaml{ .source = source };
    defer yaml.deinit(gpa);
    try yaml.load(gpa);
    const root = try singleDocument(&yaml);
    try validateVariableSchema(root);
    return try yaml.parse(arena, contract.VariableFile);
}

pub fn parseInvariants(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.InvariantFile {
    var yaml = Yaml{ .source = source };
    defer yaml.deinit(gpa);
    try yaml.load(gpa);
    const root = try singleDocument(&yaml);
    try validateInvariantSchema(root);
    return try yaml.parse(arena, contract.InvariantFile);
}

pub fn parseOperators(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.OperatorFile {
    var yaml = Yaml{ .source = source };
    defer yaml.deinit(gpa);
    try yaml.load(gpa);
    const root = try singleDocument(&yaml);
    try validateOperatorSchema(root);
    return try yaml.parse(arena, contract.OperatorFile);
}

pub fn validatePolicySource(gpa: std.mem.Allocator, source: []const u8) !void {
    var yaml = Yaml{ .source = source };
    defer yaml.deinit(gpa);
    try yaml.load(gpa);
    const root = try singleDocument(&yaml);
    const map = try asMap(root);
    try validateKeys(map, &.{"actions"}, &.{});
    if (map.get("actions") == null) return error.MissingSchemaField;
}

fn singleDocument(yaml: *const Yaml) !Value {
    if (yaml.docs.items.len != 1) return error.SingleYamlDocumentRequired;
    return yaml.docs.items[0];
}

fn validateManifestSchema(root: Value) !void {
    const map = try asMap(root);
    try validateKeys(
        map,
        &.{ "apiVersion", "kind", "metadata", "state", "population", "policy", "targets" },
        &.{ "workflow", "steps", "next", "after", "depends_on_operator" },
    );

    try requireFields(map, &.{ "apiVersion", "kind", "metadata", "state", "population", "targets" });

    const metadata = try asMap(map.get("metadata").?);
    try validateKeys(metadata, &.{ "name", "version" }, &.{});
    try requireFields(metadata, &.{ "name", "version" });

    const state = try asMap(map.get("state").?);
    try validateKeys(state, &.{ "variables", "invariants" }, &.{});
    try requireFields(state, &.{ "variables", "invariants" });

    const population = try asMap(map.get("population").?);
    try validateKeys(population, &.{"operators"}, &.{});
    try requireFields(population, &.{"operators"});

    if (map.get("policy")) |policy_value| {
        const policy = try asMap(policy_value);
        try validateKeys(policy, &.{"actions"}, &.{});
        try requireFields(policy, &.{"actions"});
    }

    _ = try asList(map.get("targets").?);
}

fn validateVariableSchema(root: Value) !void {
    const map = try asMap(root);
    try validateKeys(map, &.{"variables"}, &.{});
    try requireFields(map, &.{"variables"});

    const values = try asList(map.get("variables").?);
    for (values) |value| {
        const variable = try asMap(value);
        try validateKeys(
            variable,
            &.{ "name", "type", "unit", "merge", "freshness_rounds" },
            &.{},
        );
        try requireFields(variable, &.{ "name", "type" });
    }
}

fn validateInvariantSchema(root: Value) !void {
    const map = try asMap(root);
    try validateKeys(map, &.{"invariants"}, &.{});
    try requireFields(map, &.{"invariants"});

    const values = try asList(map.get("invariants").?);
    for (values) |value| {
        const invariant = try asMap(value);
        try validateKeys(invariant, &.{ "name", "requires" }, &.{});
        try requireFields(invariant, &.{"name"});
        if (invariant.get("requires")) |requires| _ = try asList(requires);
    }
}

fn validateOperatorSchema(root: Value) !void {
    const map = try asMap(root);
    try validateKeys(map, &.{"operators"}, &.{});
    try requireFields(map, &.{"operators"});

    const values = try asList(map.get("operators").?);
    for (values) |value| {
        const operator = try asMap(value);
        try validateKeys(
            operator,
            &.{ "name", "runtime", "requires", "provides" },
            &.{ "workflow", "steps", "next", "after", "depends_on_operator" },
        );
        try requireFields(operator, &.{ "name", "runtime" });

        const runtime = try asMap(operator.get("runtime").?);
        try validateKeys(runtime, &.{ "kind", "target" }, &.{});
        try requireFields(runtime, &.{"kind"});

        if (operator.get("requires")) |requirements| try validateRequirementSet(requirements);
        if (operator.get("provides")) |requirements| try validateRequirementSet(requirements);
    }
}

fn validateRequirementSet(value: Value) !void {
    const requirements = try asMap(value);
    try validateKeys(requirements, &.{ "variables", "invariants" }, &.{});
    if (requirements.get("variables")) |variables| _ = try asList(variables);
    if (requirements.get("invariants")) |invariants| _ = try asList(invariants);
}

fn validateKeys(
    map: Map,
    allowed: []const []const u8,
    forbidden: []const []const u8,
) !void {
    for (map.keys()) |key| {
        if (containsString(forbidden, key)) return error.WorkflowKeyForbidden;
        if (!containsString(allowed, key)) return error.UnknownSchemaField;
    }
}

fn requireFields(map: Map, required: []const []const u8) !void {
    for (required) |field| {
        if (map.get(field) == null) return error.MissingSchemaField;
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn asMap(value: Value) !Map {
    return value.asMap() orelse error.ExpectedYamlMapping;
}

fn asList(value: Value) !Yaml.List {
    return value.asList() orelse error.ExpectedYamlList;
}

fn validatePackRelativePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidManifestPath;
    if (path[0] == '/' or path[0] == '\\') return error.PackPathEscapesRoot;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        return error.PackPathEscapesRoot;
    }

    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PackPathEscapesRoot;
    }
}

test "YAML pack documents parse and compile into the SDK contract" {
    const manifest_source =
        \\apiVersion: starlings/v1
        \\kind: EmergencePack
        \\metadata:
        \\  name: coding-local
        \\  version: 0.1.0
        \\state:
        \\  variables: variables.yaml
        \\  invariants: invariants.yaml
        \\population:
        \\  operators: operators.yaml
        \\targets:
        \\  - patch.validated
    ;
    const variable_source =
        \\variables:
        \\  - name: task.text
        \\    type: text
        \\  - name: task.embedding
        \\    type: artifact_ref
        \\  - name: patch.validated
        \\    type: boolean
    ;
    const invariant_source =
        \\invariants:
        \\  - name: task.present
        \\    requires:
        \\      - task.text
    ;
    const operator_source =
        \\operators:
        \\  - name: task-encoder
        \\    runtime:
        \\      kind: python
        \\      target: operators/task_encoder.py
        \\    requires:
        \\      variables:
        \\        - task.text
        \\    provides:
        \\      variables:
        \\        - task.embedding
        \\  - name: validator
        \\    runtime:
        \\      kind: native
        \\    requires:
        \\      variables:
        \\        - task.embedding
        \\      invariants:
        \\        - task.present
        \\    provides:
        \\      variables:
        \\        - patch.validated
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try parseManifest(std.testing.allocator, arena, manifest_source);
    const variables = try parseVariables(std.testing.allocator, arena, variable_source);
    const invariants = try parseInvariants(std.testing.allocator, arena, invariant_source);
    const operators = try parseOperators(std.testing.allocator, arena, operator_source);

    const compiled = try contract.compile(.{
        .manifest = manifest,
        .variable_file = variables,
        .invariant_file = invariants,
        .operator_file = operators,
    });
    try std.testing.expectEqualStrings("coding-local", compiled.name);
    try std.testing.expectEqual(@as(usize, 3), compiled.variable_count);
    try std.testing.expectEqual(@as(usize, 2), compiled.operator_count);
}

test "pack schema forbids authored workflow edges" {
    const source =
        \\apiVersion: starlings/v1
        \\kind: EmergencePack
        \\metadata:
        \\  name: forbidden
        \\  version: 0.1.0
        \\state:
        \\  variables: variables.yaml
        \\  invariants: invariants.yaml
        \\population:
        \\  operators: operators.yaml
        \\workflow:
        \\  - first
        \\targets:
        \\  - done
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(
        error.WorkflowKeyForbidden,
        parseManifest(std.testing.allocator, arena_state.allocator(), source),
    );
}

test "pack schema rejects unknown fields and escaping paths" {
    const source =
        \\variables:
        \\  - name: task.text
        \\    type: text
        \\    magic: nope
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(
        error.UnknownSchemaField,
        parseVariables(std.testing.allocator, arena_state.allocator(), source),
    );
    try std.testing.expectError(error.PackPathEscapesRoot, validatePackRelativePath("../secrets.yaml"));
    try std.testing.expectError(error.PackPathEscapesRoot, validatePackRelativePath("/tmp/variables.yaml"));
}
