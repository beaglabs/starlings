const std = @import("std");
const contract = @import("contract.zig");

pub const max_pack_file_bytes: usize = 4 * 1024 * 1024;
pub const max_yaml_lines: usize = 4096;

const Line = struct {
    indent: usize,
    text: []const u8,
    number: usize,
};

const ParsedLines = struct {
    items: [max_yaml_lines]Line = undefined,
    count: usize = 0,

    fn slice(self: *const ParsedLines) []const Line {
        return self.items[0..self.count];
    }
};

pub fn loadAndCompile(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pack_dir: []const u8,
) !contract.CompiledPack {
    _ = gpa;

    var dir = try std.Io.Dir.cwd().openDir(io, pack_dir, .{});
    defer dir.close(io);

    const manifest_source = try dir.readFileAlloc(
        io,
        "pack.yaml",
        arena,
        .limited(max_pack_file_bytes),
    );
    const manifest = try parseManifest(arena, manifest_source);

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
        try validatePolicySource(policy_source);
    }

    const variables = try parseVariables(arena, variable_source);
    const invariants = try parseInvariants(arena, invariant_source);
    const operators = try parseOperators(arena, operator_source);

    return contract.compile(.{
        .manifest = manifest,
        .variable_file = variables,
        .invariant_file = invariants,
        .operator_file = operators,
    });
}

pub fn parseManifest(
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.Manifest {
    const parsed = try tokenize(source);
    const lines = parsed.slice();
    if (lines.len == 0) return error.EmptyYamlDocument;

    var api_version: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var metadata_name: ?[]const u8 = null;
    var metadata_version: ?[]const u8 = null;
    var variables_path: ?[]const u8 = null;
    var invariants_path: ?[]const u8 = null;
    var operators_path: ?[]const u8 = null;
    var policy_actions: ?[]const u8 = null;

    var targets_buf: [contract.max_targets][]const u8 = undefined;
    var target_count: usize = 0;

    var section: enum { none, metadata, state, population, policy, targets } = .none;

    for (lines) |line| {
        if (line.indent == 0) {
            section = .none;

            if (try scalarField(line, "apiVersion")) |value| {
                if (api_version != null) return error.DuplicateSchemaField;
                api_version = value;
                continue;
            }
            if (try scalarField(line, "kind")) |value| {
                if (kind != null) return error.DuplicateSchemaField;
                kind = value;
                continue;
            }
            if (isHeader(line, "metadata")) {
                section = .metadata;
                continue;
            }
            if (isHeader(line, "state")) {
                section = .state;
                continue;
            }
            if (isHeader(line, "population")) {
                section = .population;
                continue;
            }
            if (isHeader(line, "policy")) {
                section = .policy;
                continue;
            }
            if (isHeader(line, "targets")) {
                section = .targets;
                continue;
            }

            if (isForbiddenWorkflowKey(line.text)) return error.WorkflowKeyForbidden;
            return error.UnknownSchemaField;
        }

        switch (section) {
            .metadata => {
                try expectIndent(line, 2);
                if (try scalarField(line, "name")) |value| {
                    if (metadata_name != null) return error.DuplicateSchemaField;
                    metadata_name = value;
                } else if (try scalarField(line, "version")) |value| {
                    if (metadata_version != null) return error.DuplicateSchemaField;
                    metadata_version = value;
                } else return error.UnknownSchemaField;
            },
            .state => {
                try expectIndent(line, 2);
                if (try scalarField(line, "variables")) |value| {
                    if (variables_path != null) return error.DuplicateSchemaField;
                    variables_path = value;
                } else if (try scalarField(line, "invariants")) |value| {
                    if (invariants_path != null) return error.DuplicateSchemaField;
                    invariants_path = value;
                } else return error.UnknownSchemaField;
            },
            .population => {
                try expectIndent(line, 2);
                if (try scalarField(line, "operators")) |value| {
                    if (operators_path != null) return error.DuplicateSchemaField;
                    operators_path = value;
                } else return error.UnknownSchemaField;
            },
            .policy => {
                try expectIndent(line, 2);
                if (try scalarField(line, "actions")) |value| {
                    if (policy_actions != null) return error.DuplicateSchemaField;
                    policy_actions = value;
                } else return error.UnknownSchemaField;
            },
            .targets => {
                try expectIndent(line, 2);
                if (target_count >= targets_buf.len) return error.PackCapacityExceeded;
                targets_buf[target_count] = try listScalar(line);
                target_count += 1;
            },
            .none => return error.InvalidYamlIndentation,
        }
    }

    const targets = try arena.alloc([]const u8, target_count);
    @memcpy(targets, targets_buf[0..target_count]);

    return .{
        .apiVersion = api_version orelse return error.MissingSchemaField,
        .kind = kind orelse return error.MissingSchemaField,
        .metadata = .{
            .name = metadata_name orelse return error.MissingSchemaField,
            .version = metadata_version orelse return error.MissingSchemaField,
        },
        .state = .{
            .variables = variables_path orelse return error.MissingSchemaField,
            .invariants = invariants_path orelse return error.MissingSchemaField,
        },
        .population = .{
            .operators = operators_path orelse return error.MissingSchemaField,
        },
        .policy = if (policy_actions) |actions| .{ .actions = actions } else null,
        .targets = targets,
    };
}

pub fn parseVariables(
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.VariableFile {
    const parsed = try tokenize(source);
    const lines = parsed.slice();
    if (lines.len == 0 or !isHeader(lines[0], "variables") or lines[0].indent != 0) {
        return error.MissingSchemaField;
    }

    var buf: [contract.max_variables]contract.VariableDecl = undefined;
    var count: usize = 0;
    var current: ?contract.VariableDecl = null;
    var has_type = false;
    var has_merge = false;

    for (lines[1..]) |line| {
        if (line.indent == 2 and startsListItem(line.text)) {
            if (current) |decl| {
                if (!has_type) return error.MissingSchemaField;
                if (count >= buf.len) return error.PackCapacityExceeded;
                buf[count] = decl;
                count += 1;
            }

            const item = line.text[2..];
            const name = (try scalarTextField(item, "name")) orelse return error.MissingSchemaField;
            current = .{
                .name = name,
                .@"type" = .text,
            };
            has_type = false;
            has_merge = false;
            continue;
        }

        if (line.indent != 4 or current == null) return error.InvalidYamlIndentation;
        var decl = current.?;

        if (try scalarField(line, "type")) |value| {
            if (has_type) return error.DuplicateSchemaField;
            decl.@"type" = std.meta.stringToEnum(contract.ValueType, value) orelse return error.InvalidEnum;
            has_type = true;
        } else if (try scalarField(line, "unit")) |value| {
            if (decl.unit != null) return error.DuplicateSchemaField;
            decl.unit = value;
        } else if (try scalarField(line, "merge")) |value| {
            if (has_merge) return error.DuplicateSchemaField;
            decl.merge = std.meta.stringToEnum(contract.Merge, value) orelse return error.InvalidEnum;
            has_merge = true;
        } else if (try scalarField(line, "freshness_rounds")) |value| {
            if (decl.freshness_rounds != null) return error.DuplicateSchemaField;
            decl.freshness_rounds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
        } else {
            if (isForbiddenWorkflowKey(line.text)) return error.WorkflowKeyForbidden;
            return error.UnknownSchemaField;
        }

        current = decl;
    }

    if (current) |decl| {
        if (!has_type) return error.MissingSchemaField;
        if (count >= buf.len) return error.PackCapacityExceeded;
        buf[count] = decl;
        count += 1;
    }

    const out = try arena.alloc(contract.VariableDecl, count);
    @memcpy(out, buf[0..count]);
    return .{ .variables = out };
}

pub fn parseInvariants(
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.InvariantFile {
    const parsed = try tokenize(source);
    const lines = parsed.slice();
    if (lines.len == 0 or !isHeader(lines[0], "invariants") or lines[0].indent != 0) {
        return error.MissingSchemaField;
    }

    var out_buf: [contract.max_invariants]contract.InvariantDecl = undefined;
    var count: usize = 0;
    var i: usize = 1;

    while (i < lines.len) {
        const line = lines[i];
        if (line.indent != 2 or !startsListItem(line.text)) return error.InvalidYamlIndentation;

        const name = (try scalarTextField(line.text[2..], "name")) orelse return error.MissingSchemaField;
        var req_buf: [contract.max_dependencies][]const u8 = undefined;
        var req_count: usize = 0;
        i += 1;

        while (i < lines.len and lines[i].indent > 2) {
            const nested = lines[i];
            if (nested.indent == 4 and isHeader(nested, "requires")) {
                i += 1;
                while (i < lines.len and lines[i].indent > 4) {
                    try expectIndent(lines[i], 6);
                    if (req_count >= req_buf.len) return error.PackCapacityExceeded;
                    req_buf[req_count] = try listScalar(lines[i]);
                    req_count += 1;
                    i += 1;
                }
                continue;
            }
            return error.UnknownSchemaField;
        }

        if (count >= out_buf.len) return error.PackCapacityExceeded;
        const requires = try arena.alloc([]const u8, req_count);
        @memcpy(requires, req_buf[0..req_count]);
        out_buf[count] = .{ .name = name, .requires = requires };
        count += 1;
    }

    const out = try arena.alloc(contract.InvariantDecl, count);
    @memcpy(out, out_buf[0..count]);
    return .{ .invariants = out };
}

pub fn parseOperators(
    arena: std.mem.Allocator,
    source: []const u8,
) !contract.OperatorFile {
    const parsed = try tokenize(source);
    const lines = parsed.slice();
    if (lines.len == 0 or !isHeader(lines[0], "operators") or lines[0].indent != 0) {
        return error.MissingSchemaField;
    }

    var out_buf: [contract.max_operators]contract.OperatorDecl = undefined;
    var count: usize = 0;
    var i: usize = 1;

    while (i < lines.len) {
        const line = lines[i];
        if (line.indent != 2 or !startsListItem(line.text)) return error.InvalidYamlIndentation;

        const name = (try scalarTextField(line.text[2..], "name")) orelse return error.MissingSchemaField;
        var runtime: ?contract.RuntimeDecl = null;
        var requires: contract.RequirementSet = .{};
        var provides: contract.RequirementSet = .{};

        i += 1;
        while (i < lines.len and lines[i].indent > 2) {
            const nested = lines[i];
            if (nested.indent != 4) return error.InvalidYamlIndentation;

            if (isForbiddenWorkflowKey(nested.text)) return error.WorkflowKeyForbidden;

            if (isHeader(nested, "runtime")) {
                const result = try parseRuntime(arena, lines, &i);
                runtime = result;
                continue;
            }

            if (isHeader(nested, "requires")) {
                requires = try parseRequirementSet(arena, lines, &i);
                continue;
            }

            if (isHeader(nested, "provides")) {
                provides = try parseRequirementSet(arena, lines, &i);
                continue;
            }

            return error.UnknownSchemaField;
        }

        if (count >= out_buf.len) return error.PackCapacityExceeded;
        out_buf[count] = .{
            .name = name,
            .runtime = runtime orelse return error.MissingSchemaField,
            .requires = requires,
            .provides = provides,
        };
        count += 1;
    }

    const out = try arena.alloc(contract.OperatorDecl, count);
    @memcpy(out, out_buf[0..count]);
    return .{ .operators = out };
}

pub fn validatePolicySource(source: []const u8) !void {
    const parsed = try tokenize(source);
    const lines = parsed.slice();
    if (lines.len == 0) return error.MissingSchemaField;
    if (lines[0].indent != 0 or !isHeader(lines[0], "actions")) {
        return error.MissingSchemaField;
    }

    for (lines[1..]) |line| {
        if (line.indent == 0) return error.UnknownSchemaField;
        if (line.indent < 2) return error.InvalidYamlIndentation;
    }
}

fn parseRuntime(
    arena: std.mem.Allocator,
    lines: []const Line,
    index: *usize,
) !contract.RuntimeDecl {
    index.* += 1;
    var kind: ?contract.RuntimeKind = null;
    var target: ?[]const u8 = null;
    var timeout_ms: ?u32 = null;
    var arg_buf: [contract.max_runtime_args][]const u8 = undefined;
    var arg_count: usize = 0;
    var saw_args = false;

    while (index.* < lines.len and lines[index.*].indent > 4) {
        const line = lines[index.*];
        try expectIndent(line, 6);

        if (try scalarField(line, "kind")) |value| {
            if (kind != null) return error.DuplicateSchemaField;
            kind = std.meta.stringToEnum(contract.RuntimeKind, value) orelse return error.InvalidEnum;
            index.* += 1;
            continue;
        }
        if (try scalarField(line, "target")) |value| {
            if (target != null) return error.DuplicateSchemaField;
            target = value;
            index.* += 1;
            continue;
        }
        if (try scalarField(line, "timeout_ms")) |value| {
            if (timeout_ms != null) return error.DuplicateSchemaField;
            timeout_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
            index.* += 1;
            continue;
        }
        if (isHeader(line, "args")) {
            if (saw_args) return error.DuplicateSchemaField;
            saw_args = true;
            index.* += 1;
            while (index.* < lines.len and lines[index.*].indent > 6) {
                const item = lines[index.*];
                try expectIndent(item, 8);
                if (arg_count >= arg_buf.len) return error.PackCapacityExceeded;
                arg_buf[arg_count] = try listScalar(item);
                arg_count += 1;
                index.* += 1;
            }
            continue;
        }
        return error.UnknownSchemaField;
    }

    const args = try arena.alloc([]const u8, arg_count);
    @memcpy(args, arg_buf[0..arg_count]);

    return .{
        .kind = kind orelse return error.MissingSchemaField,
        .target = target,
        .args = args,
        .timeout_ms = timeout_ms orelse 30_000,
    };
}

fn parseRequirementSet(
    arena: std.mem.Allocator,
    lines: []const Line,
    index: *usize,
) !contract.RequirementSet {
    index.* += 1;

    var variable_buf: [contract.max_dependencies][]const u8 = undefined;
    var variable_count: usize = 0;
    var invariant_buf: [contract.max_dependencies][]const u8 = undefined;
    var invariant_count: usize = 0;

    while (index.* < lines.len and lines[index.*].indent > 4) {
        const header = lines[index.*];
        try expectIndent(header, 6);

        const Destination = enum { variables, invariants };
        const destination: Destination = if (isHeader(header, "variables"))
            .variables
        else if (isHeader(header, "invariants"))
            .invariants
        else
            return error.UnknownSchemaField;

        index.* += 1;
        while (index.* < lines.len and lines[index.*].indent > 6) {
            const item = lines[index.*];
            try expectIndent(item, 8);
            const value = try listScalar(item);

            switch (destination) {
                .variables => {
                    if (variable_count >= variable_buf.len) return error.PackCapacityExceeded;
                    variable_buf[variable_count] = value;
                    variable_count += 1;
                },
                .invariants => {
                    if (invariant_count >= invariant_buf.len) return error.PackCapacityExceeded;
                    invariant_buf[invariant_count] = value;
                    invariant_count += 1;
                },
            }
            index.* += 1;
        }
    }

    const variables = try arena.alloc([]const u8, variable_count);
    @memcpy(variables, variable_buf[0..variable_count]);
    const invariants = try arena.alloc([]const u8, invariant_count);
    @memcpy(invariants, invariant_buf[0..invariant_count]);

    return .{
        .variables = variables,
        .invariants = invariants,
    };
}

fn tokenize(source: []const u8) !ParsedLines {
    var result = ParsedLines{};
    var it = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;

    while (it.next()) |raw_line| {
        number += 1;

        if (std.mem.indexOfScalar(u8, raw_line, '\t') != null) return error.TabsNotAllowed;

        const without_cr = trimLineEnd(raw_line);
        const trimmed = std.mem.trim(u8, without_cr, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var indent: usize = 0;
        while (indent < without_cr.len and without_cr[indent] == ' ') : (indent += 1) {}
        if ((indent % 2) != 0) return error.InvalidYamlIndentation;

        if (result.count >= result.items.len) return error.PackCapacityExceeded;
        result.items[result.count] = .{
            .indent = indent,
            .text = without_cr[indent..],
            .number = number,
        };
        result.count += 1;
    }

    return result;
}

fn trimLineEnd(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0) {
        const ch = line[end - 1];
        if (ch != ' ' and ch != '\r') break;
        end -= 1;
    }
    return line[0..end];
}

fn scalarField(line: Line, key: []const u8) !?[]const u8 {
    return scalarTextField(line.text, key);
}

fn scalarTextField(text: []const u8, key: []const u8) !?[]const u8 {
    if (text.len <= key.len + 1) return null;
    if (!std.mem.startsWith(u8, text, key)) return null;
    if (text[key.len] != ':') return null;

    const value = std.mem.trim(u8, text[key.len + 1 ..], " ");
    if (value.len == 0) return error.MissingSchemaField;
    const unquoted = try unquote(value);
    return unquoted;
}

fn isHeader(line: Line, key: []const u8) bool {
    return line.text.len == key.len + 1 and
        std.mem.startsWith(u8, line.text, key) and
        line.text[key.len] == ':';
}

fn startsListItem(text: []const u8) bool {
    return text.len >= 2 and text[0] == '-' and text[1] == ' ';
}

fn listScalar(line: Line) ![]const u8 {
    if (!startsListItem(line.text)) return error.ExpectedYamlListItem;
    const value = std.mem.trim(u8, line.text[2..], " ");
    if (value.len == 0) return error.ExpectedYamlListItem;
    return unquote(value);
}

fn unquote(value: []const u8) ![]const u8 {
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }

    if (value[0] == '"' or value[0] == '\'' or
        value[value.len - 1] == '"' or value[value.len - 1] == '\'')
    {
        return error.InvalidQuotedScalar;
    }

    return value;
}

fn expectIndent(line: Line, expected: usize) !void {
    if (line.indent != expected) return error.InvalidYamlIndentation;
}

fn isForbiddenWorkflowKey(text: []const u8) bool {
    const keys = [_][]const u8{
        "workflow",
        "steps",
        "next",
        "after",
        "depends_on_operator",
    };
    for (keys) |key| {
        if (std.mem.startsWith(u8, text, key) and text.len > key.len and text[key.len] == ':') {
            return true;
        }
    }
    return false;
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

    const manifest = try parseManifest(arena, manifest_source);
    const variables = try parseVariables(arena, variable_source);
    const invariants = try parseInvariants(arena, invariant_source);
    const operators = try parseOperators(arena, operator_source);

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

test "operator runtime parser accepts argv and timeout" {
    const source =
        \\operators:
        \\  - name: check
        \\    runtime:
        \\      kind: subprocess
        \\      target: /usr/bin/env
        \\      timeout_ms: 1500
        \\      args:
        \\        - python3
        \\        - ./operators/check.py
        \\    provides:
        \\      variables:
        \\        - done
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseOperators(arena_state.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), parsed.operators.len);
    try std.testing.expectEqual(contract.RuntimeKind.subprocess, parsed.operators[0].runtime.kind);
    try std.testing.expectEqual(@as(u32, 1500), parsed.operators[0].runtime.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), parsed.operators[0].runtime.args.len);
    try std.testing.expectEqualStrings("python3", parsed.operators[0].runtime.args[0]);
    try std.testing.expectEqualStrings("./operators/check.py", parsed.operators[0].runtime.args[1]);
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
        parseManifest(arena_state.allocator(), source),
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
        parseVariables(arena_state.allocator(), source),
    );
    try std.testing.expectError(error.PackPathEscapesRoot, validatePackRelativePath("../secrets.yaml"));
    try std.testing.expectError(error.PackPathEscapesRoot, validatePackRelativePath("/tmp/variables.yaml"));
}
