const std = @import("std");
const core = @import("core_types.zig");

pub const wire_version: u8 = 1;
pub const wire_header_request = "STARLINGS/1 REQUEST";
pub const wire_header_response = "STARLINGS/1 RESPONSE";

pub const WireObservation = struct {
    variable: core.VariableId,
    status: core.EpistemicStatus,
    value: ?core.Value = null,
};

pub const WireInvariant = struct {
    invariant: core.InvariantId,
    status: core.InvariantStatus,
};

pub const SubprocessAdapter = struct {
    argv: []const []const u8,
    timeout_ms: u32 = 30_000,
};

pub const PythonMode = enum(u8) {
    script,
    module,
};

pub const PythonAdapter = struct {
    interpreter: []const u8 = "python3",
    target: []const u8,
    mode: PythonMode = .script,
    timeout_ms: u32 = 30_000,

    pub fn command(self: PythonAdapter, out: *[4][]const u8) []const []const u8 {
        out[0] = self.interpreter;
        return switch (self.mode) {
            .script => blk: {
                out[1] = self.target;
                break :blk out[0..2];
            },
            .module => blk: {
                out[1] = "-m";
                out[2] = self.target;
                break :blk out[0..3];
            },
        };
    }
};

pub const Invocation = union(enum) {
    subprocess: SubprocessAdapter,
    python: PythonAdapter,

    pub fn timeoutMs(self: Invocation) u32 {
        return switch (self) {
            .subprocess => |v| v.timeout_ms,
            .python => |v| v.timeout_ms,
        };
    }
};

pub const Transport = struct {
    context: ?*anyopaque = null,
    invoke_fn: *const fn (
        ?*anyopaque,
        Invocation,
        []const u8,
        []u8,
    ) anyerror![]const u8,

    pub fn invoke(
        self: Transport,
        invocation: Invocation,
        request: []const u8,
        response_buffer: []u8,
    ) ![]const u8 {
        return self.invoke_fn(self.context, invocation, request, response_buffer);
    }
};

pub const ExternalOperator = struct {
    invocation: Invocation,
    transport: Transport,

    pub fn invoke(
        self: ExternalOperator,
        request: []const u8,
        response_buffer: []u8,
    ) !core.OperatorOutput {
        const response = try self.transport.invoke(self.invocation, request, response_buffer);
        return parseResponse(response);
    }
};

pub fn BufferedExternalOperator(
    comptime request_capacity: usize,
    comptime response_capacity: usize,
) type {
    return struct {
        const Self = @This();

        operator_id: core.OperatorId,
        external: ExternalOperator,
        request_storage: [request_capacity]u8 = undefined,
        response_storage: [response_capacity]u8 = undefined,

        pub fn invoke(
            self: *Self,
            round: u32,
            observations: []const WireObservation,
        ) !core.OperatorOutput {
            return self.invokeState(round, observations, &.{});
        }

        pub fn invokeState(
            self: *Self,
            round: u32,
            observations: []const WireObservation,
            invariants: []const WireInvariant,
        ) !core.OperatorOutput {
            return self.invokeExecution(
                round,
                observations,
                invariants,
                &.{},
                &.{},
            );
        }

        pub fn invokeExecution(
            self: *Self,
            round: u32,
            observations: []const WireObservation,
            invariants: []const WireInvariant,
            provides_variables: []const core.VariableId,
            provides_invariants: []const core.InvariantId,
        ) !core.OperatorOutput {
            const request = try buildRequestExecution(
                self.operator_id,
                round,
                observations,
                invariants,
                provides_variables,
                provides_invariants,
                &self.request_storage,
            );
            return self.external.invoke(request, &self.response_storage);
        }
    };
}

const Buffer = struct {
    bytes: []u8,
    len: usize = 0,

    fn write(self: *Buffer, value: []const u8) !void {
        if (self.len + value.len > self.bytes.len) return error.WireBufferTooSmall;
        @memcpy(self.bytes[self.len .. self.len + value.len], value);
        self.len += value.len;
    }

    fn print(self: *Buffer, comptime fmt: []const u8, args: anytype) !void {
        const written = std.fmt.bufPrint(self.bytes[self.len..], fmt, args) catch return error.WireBufferTooSmall;
        self.len += written.len;
    }

    fn slice(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn buildRequest(
    operator_id: core.OperatorId,
    round: u32,
    observations: []const WireObservation,
    out: []u8,
) ![]const u8 {
    return buildRequestState(operator_id, round, observations, &.{}, out);
}

pub fn buildRequestState(
    operator_id: core.OperatorId,
    round: u32,
    observations: []const WireObservation,
    invariants: []const WireInvariant,
    out: []u8,
) ![]const u8 {
    return buildRequestExecution(
        operator_id,
        round,
        observations,
        invariants,
        &.{},
        &.{},
        out,
    );
}

pub fn buildRequestExecution(
    operator_id: core.OperatorId,
    round: u32,
    observations: []const WireObservation,
    invariants: []const WireInvariant,
    provides_variables: []const core.VariableId,
    provides_invariants: []const core.InvariantId,
    out: []u8,
) ![]const u8 {
    var buffer = Buffer{ .bytes = out };
    try buffer.write(wire_header_request);
    try buffer.write("\n");
    try buffer.print("operator={d}\n", .{operator_id});
    try buffer.print("round={d}\n", .{round});

    for (observations) |observation| {
        if (observation.status.carriesValue() != (observation.value != null)) {
            return error.InvalidEpistemicValue;
        }
        try buffer.print(
            "var={d},{d},",
            .{ observation.variable, @intFromEnum(observation.status) },
        );
        try writeValue(&buffer, observation.value);
        try buffer.write("\n");
    }

    for (invariants) |invariant| {
        try buffer.print(
            "inv={d},{d}\n",
            .{ invariant.invariant, @intFromEnum(invariant.status) },
        );
    }
    for (provides_variables) |variable_id| {
        try buffer.print("provide_var={d}\n", .{variable_id});
    }
    for (provides_invariants) |invariant_id| {
        try buffer.print("provide_inv={d}\n", .{invariant_id});
    }

    try buffer.write("END\n");
    return buffer.slice();
}

pub fn parseResponse(input: []const u8) !core.OperatorOutput {
    var lines = std.mem.splitScalar(u8, input, '\n');
    const header = lines.next() orelse return error.InvalidWireHeader;
    if (!std.mem.eql(u8, header, wire_header_response)) return error.InvalidWireHeader;

    var output = core.OperatorOutput{};
    var saw_end = false;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "END")) {
            saw_end = true;
            break;
        }
        if (std.mem.startsWith(u8, line, "operator=")) continue;

        if (std.mem.startsWith(u8, line, "claim=")) {
            try parseClaim(line["claim=".len..], &output);
            continue;
        }

        if (std.mem.startsWith(u8, line, "invariant=")) {
            try parseInvariant(line["invariant=".len..], &output);
            continue;
        }

        if (std.mem.startsWith(u8, line, "action=")) {
            try parseAction(line["action=".len..], &output);
            continue;
        }

        return error.UnknownWireRecord;
    }

    if (!saw_end) return error.MissingWireEnd;
    return output;
}

fn parseClaim(record: []const u8, output: *core.OperatorOutput) !void {
    var parts = std.mem.splitScalar(u8, record, ',');
    const variable_text = parts.next() orelse return error.InvalidWireRecord;
    const status_text = parts.next() orelse return error.InvalidWireRecord;
    const confidence_text = parts.next() orelse return error.InvalidWireRecord;
    const source_text = parts.next() orelse return error.InvalidWireRecord;
    const value_text = parts.next() orelse return error.InvalidWireRecord;
    if (parts.next() != null) return error.InvalidWireRecord;

    const variable = try std.fmt.parseInt(core.VariableId, variable_text, 10);
    const status_raw = try std.fmt.parseInt(u8, status_text, 10);
    if (status_raw > @intFromEnum(core.EpistemicStatus.conflicting)) return error.InvalidWireValue;
    const status: core.EpistemicStatus = @enumFromInt(status_raw);
    const confidence = try std.fmt.parseInt(u16, confidence_text, 10);
    const source = try std.fmt.parseInt(core.OperatorId, source_text, 10);
    const value = try parseValue(value_text);

    try output.addClaim(.{
        .variable = variable,
        .status = status,
        .value = value,
        .confidence_permille = confidence,
        .source_operator = source,
    });
}

fn parseInvariant(record: []const u8, output: *core.OperatorOutput) !void {
    var parts = std.mem.splitScalar(u8, record, ',');
    const invariant_text = parts.next() orelse return error.InvalidWireRecord;
    const status_text = parts.next() orelse return error.InvalidWireRecord;
    const source_text = parts.next() orelse return error.InvalidWireRecord;
    if (parts.next() != null) return error.InvalidWireRecord;

    const invariant = try std.fmt.parseInt(core.InvariantId, invariant_text, 10);
    const status_raw = try std.fmt.parseInt(u8, status_text, 10);
    if (status_raw > @intFromEnum(core.InvariantStatus.blocked)) return error.InvalidWireValue;
    const status: core.InvariantStatus = @enumFromInt(status_raw);
    const source = try std.fmt.parseInt(core.OperatorId, source_text, 10);

    try output.addInvariant(.{
        .invariant = invariant,
        .status = status,
        .source_operator = source,
    });
}

fn parseAction(record: []const u8, output: *core.OperatorOutput) !void {
    var parts = std.mem.splitScalar(u8, record, ',');
    const name = parts.next() orelse return error.InvalidWireRecord;
    const approval_text = parts.next() orelse return error.InvalidWireRecord;
    const payload = parts.next() orelse return error.InvalidWireRecord;
    if (parts.next() != null) return error.InvalidWireRecord;
    if (!wireSafeText(name) or !wireSafeText(payload)) return error.InvalidWireValue;

    const approval_raw = try std.fmt.parseInt(u8, approval_text, 10);
    if (approval_raw > 1) return error.InvalidWireValue;

    try output.addAction(.{
        .name = name,
        .payload = payload,
        .requires_approval = approval_raw == 1,
    });
}

fn writeValue(buffer: *Buffer, value: ?core.Value) !void {
    if (value == null) {
        try buffer.write("n");
        return;
    }

    switch (value.?) {
        .integer => |v| try buffer.print("i:{d}", .{v}),
        .float => |v| {
            const bits: u64 = @bitCast(v);
            try buffer.print("f:{x:0>16}", .{bits});
        },
        .boolean => |v| try buffer.write(if (v) "b:1" else "b:0"),
        .text => |v| {
            if (!wireSafeText(v)) return error.InvalidWireValue;
            try buffer.write("t:");
            try buffer.write(v);
        },
        .artifact_ref => |v| {
            try buffer.write("a:");
            try writeHex(buffer, &v);
        },
    }
}

fn parseValue(encoded: []const u8) !?core.Value {
    if (std.mem.eql(u8, encoded, "n")) return null;
    if (encoded.len < 2 or encoded[1] != ':') return error.InvalidWireValue;
    const payload = encoded[2..];

    return switch (encoded[0]) {
        'i' => .{ .integer = try std.fmt.parseInt(i64, payload, 10) },
        'f' => blk: {
            const bits = try std.fmt.parseInt(u64, payload, 16);
            const value: f64 = @bitCast(bits);
            break :blk .{ .float = value };
        },
        'b' => blk: {
            if (std.mem.eql(u8, payload, "1")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, payload, "0")) break :blk .{ .boolean = false };
            return error.InvalidWireValue;
        },
        't' => blk: {
            if (!wireSafeText(payload)) return error.InvalidWireValue;
            break :blk .{ .text = payload };
        },
        'a' => blk: {
            if (payload.len != 64) return error.InvalidWireValue;
            var id: core.ContentId = undefined;
            try parseHex(payload, &id);
            break :blk .{ .artifact_ref = id };
        },
        else => error.InvalidWireValue,
    };
}

fn wireSafeText(value: []const u8) bool {
    for (value) |c| {
        if (c == '\n' or c == '\r' or c == ',') return false;
    }
    return true;
}

fn writeHex(buffer: *Buffer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        const pair = [_]u8{ alphabet[byte >> 4], alphabet[byte & 0x0f] };
        try buffer.write(&pair);
    }
}

fn parseHex(text: []const u8, out: []u8) !void {
    if (text.len != out.len * 2) return error.InvalidWireValue;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexNibble(text[i * 2]);
        const lo = try hexNibble(text[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidWireValue,
    };
}

test "canonical request encoding is stable" {
    var buffer: [512]u8 = undefined;
    const observations = [_]WireObservation{
        .{ .variable = 1, .status = .observed, .value = .{ .integer = 7 } },
        .{ .variable = 2, .status = .blocked },
    };
    const request = try buildRequest(9, 3, &observations, &buffer);
    try std.testing.expectEqualStrings(
        "STARLINGS/1 REQUEST\noperator=9\nround=3\nvar=1,1,i:7\nvar=2,6,n\nEND\n",
        request,
    );
}

test "canonical request encoding includes invariant state" {
    var buffer: [512]u8 = undefined;
    const observations = [_]WireObservation{
        .{ .variable = 1, .status = .observed, .value = .{ .integer = 7 } },
    };
    const invariants = [_]WireInvariant{
        .{ .invariant = 4, .status = .satisfied },
    };
    const request = try buildRequestState(9, 3, &observations, &invariants, &buffer);
    try std.testing.expectEqualStrings(
        "STARLINGS/1 REQUEST\noperator=9\nround=3\nvar=1,1,i:7\ninv=4,1\nEND\n",
        request,
    );
}

test "execution request advertises authorized output ids" {
    var buffer: [512]u8 = undefined;
    const request = try buildRequestExecution(
        9,
        3,
        &.{},
        &.{},
        &.{ 12, 13 },
        &.{4},
        &buffer,
    );
    try std.testing.expectEqualStrings(
        "STARLINGS/1 REQUEST\noperator=9\nround=3\nprovide_var=12\nprovide_var=13\nprovide_inv=4\nEND\n",
        request,
    );
}

test "response parser normalizes claims invariants and actions" {
    const response =
        "STARLINGS/1 RESPONSE\n" ++
        "operator=9\n" ++
        "claim=3,3,950,9,i:42\n" ++
        "invariant=4,1,9\n" ++
        "action=request_review,1,case-7\n" ++
        "END\n";

    const output = try parseResponse(response);
    try std.testing.expectEqual(@as(usize, 1), output.variable_claim_count);
    try std.testing.expectEqual(@as(usize, 1), output.invariant_claim_count);
    try std.testing.expectEqual(@as(usize, 1), output.action_count);
    try std.testing.expect(core.Value.eql(output.variable_claims[0].value.?, .{ .integer = 42 }));
}

test "python adapter builds script and module commands" {
    var storage: [4][]const u8 = undefined;

    const script = PythonAdapter{ .target = "operator.py" };
    const script_cmd = script.command(&storage);
    try std.testing.expectEqualStrings("python3", script_cmd[0]);
    try std.testing.expectEqualStrings("operator.py", script_cmd[1]);

    const module = PythonAdapter{ .target = "my.operator", .mode = .module };
    const module_cmd = module.command(&storage);
    try std.testing.expectEqual(@as(usize, 3), module_cmd.len);
    try std.testing.expectEqualStrings("-m", module_cmd[1]);
    try std.testing.expectEqualStrings("my.operator", module_cmd[2]);
}

test "external operator boundary is transport injectable" {
    const Fixture = struct {
        fn invoke(
            _: ?*anyopaque,
            _: Invocation,
            request: []const u8,
            response_buffer: []u8,
        ) ![]const u8 {
            try std.testing.expect(std.mem.startsWith(u8, request, wire_header_request));
            const response =
                "STARLINGS/1 RESPONSE\n" ++
                "operator=7\n" ++
                "claim=2,3,1000,7,b:1\n" ++
                "END\n";
            if (response.len > response_buffer.len) return error.WireBufferTooSmall;
            @memcpy(response_buffer[0..response.len], response);
            return response_buffer[0..response.len];
        }
    };

    const adapter = ExternalOperator{
        .invocation = .{ .python = .{ .target = "fixture.py" } },
        .transport = .{ .invoke_fn = Fixture.invoke },
    };

    var request_buffer: [256]u8 = undefined;
    const request = try buildRequest(7, 1, &.{}, &request_buffer);
    var response_buffer: [256]u8 = undefined;
    const output = try adapter.invoke(request, &response_buffer);
    try std.testing.expectEqual(@as(usize, 1), output.variable_claim_count);
}


test "buffered external operator owns wire string lifetime across return" {
    const Fixture = struct {
        fn invoke(
            _: ?*anyopaque,
            _: Invocation,
            _: []const u8,
            response_buffer: []u8,
        ) ![]const u8 {
            const response =
                "STARLINGS/1 RESPONSE\n" ++
                "operator=7\n" ++
                "claim=2,3,1000,7,t:owned-text\n" ++
                "action=request_review,1,case-7\n" ++
                "END\n";
            if (response.len > response_buffer.len) return error.WireBufferTooSmall;
            @memcpy(response_buffer[0..response.len], response);
            return response_buffer[0..response.len];
        }
    };

    const Buffered = BufferedExternalOperator(256, 512);
    var operator = Buffered{
        .operator_id = 7,
        .external = .{
            .invocation = .{ .subprocess = .{ .argv = &.{"fixture"} } },
            .transport = .{ .invoke_fn = Fixture.invoke },
        },
    };

    const output = try operator.invoke(1, &.{});
    try std.testing.expectEqualStrings("owned-text", output.variable_claims[0].value.?.text);
    try std.testing.expectEqualStrings("request_review", output.actions[0].name);
    try std.testing.expectEqualStrings("case-7", output.actions[0].payload);
}
