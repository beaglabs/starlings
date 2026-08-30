const std = @import("std");
const content_id = @import("../core/content_id.zig");
const core = @import("core_types.zig");
const reg = @import("registry.zig");
const event_log = @import("event_log.zig");
const execution = @import("execution.zig");

pub const storage_version: u8 = 1;
pub const default_root_path = ".starlings/runs";
pub const configuration_file_name = "configuration.bin";
pub const events_file_name = "events.ndjson";

pub const max_configuration_bytes: usize = 8 * 1024 * 1024;
pub const max_event_file_bytes: usize = 64 * 1024 * 1024;
pub const max_event_payload_bytes: usize = 4 * 1024 * 1024;

pub const max_replay_variables: usize = 256;
pub const max_replay_invariants: usize = 128;
pub const max_replay_operators: usize = 128;
pub const max_replay_dependencies: usize = 64;
pub const max_replay_targets: usize = 64;
pub const max_replay_claims: usize = 512;

const configuration_magic = "STCFG001";

pub const SnapshotInvariant = struct {
    id: core.InvariantId,
    name: []const u8,
    requires: [max_replay_dependencies]core.VariableId = undefined,
    require_count: usize = 0,

    pub fn asCore(self: *const SnapshotInvariant) core.Invariant {
        return .{
            .id = self.id,
            .name = self.name,
            .requires = self.requires[0..self.require_count],
        };
    }
};

pub const SnapshotOperator = struct {
    id: core.OperatorId,
    name: []const u8,
    requires_variables: [max_replay_dependencies]core.VariableId = undefined,
    requires_variable_count: usize = 0,
    requires_invariants: [max_replay_dependencies]core.InvariantId = undefined,
    requires_invariant_count: usize = 0,
    provides_variables: [max_replay_dependencies]core.VariableId = undefined,
    provides_variable_count: usize = 0,
    provides_invariants: [max_replay_dependencies]core.InvariantId = undefined,
    provides_invariant_count: usize = 0,
    eligibility_mode: reg.DependencyMode = .all,
    eligibility_terms: [max_replay_dependencies]reg.DependencyTerm = undefined,
    eligibility_term_count: usize = 0,

    pub fn asRegistered(self: *const SnapshotOperator) reg.RegisteredOperator {
        return .{
            .manifest = .{
                .id = self.id,
                .name = self.name,
                .requires_variables = self.requires_variables[0..self.requires_variable_count],
                .requires_invariants = self.requires_invariants[0..self.requires_invariant_count],
                .provides_variables = self.provides_variables[0..self.provides_variable_count],
                .provides_invariants = self.provides_invariants[0..self.provides_invariant_count],
            },
            .eligibility = .{
                .mode = self.eligibility_mode,
                .terms = self.eligibility_terms[0..self.eligibility_term_count],
            },
        };
    }
};

pub const ReplayConfiguration = struct {
    run_id: core.ContentId,
    seed: u64,
    configuration_digest: core.ContentId,
    variables: [max_replay_variables]reg.VariableSchema = undefined,
    variable_count: usize = 0,
    invariants: [max_replay_invariants]SnapshotInvariant = undefined,
    invariant_count: usize = 0,
    operators: [max_replay_operators]SnapshotOperator = undefined,
    operator_count: usize = 0,
    targets: [max_replay_targets]core.VariableId = undefined,
    target_count: usize = 0,

    pub fn targetSlice(self: *const ReplayConfiguration) []const core.VariableId {
        return self.targets[0..self.target_count];
    }

    pub fn configure(self: *const ReplayConfiguration, runner: anytype) !void {
        for (self.variables[0..self.variable_count]) |variable| {
            try runner.addVariable(variable);
        }
        for (self.invariants[0..self.invariant_count]) |*invariant| {
            try runner.addInvariant(invariant.asCore());
        }
        for (self.operators[0..self.operator_count]) |*operator| {
            try runner.addReplayOperator(operator.asRegistered());
        }
    }
};

pub const RunWriter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    events_file: std.Io.File,
    run_id: core.ContentId,
    next_sequence: u64 = 0,
    next_offset: u64 = 0,
    head: core.ContentId = content_id.zero,
    failed: bool = false,

    pub fn deinit(self: *RunWriter) void {
        self.events_file.close(self.io);
    }

    pub fn eventSink(self: *RunWriter) event_log.EventSink {
        return .{
            .context = self,
            .append_fn = appendFromSink,
        };
    }

    pub fn appendRecord(self: *RunWriter, record: event_log.EventRecord) !void {
        if (self.failed) return error.EventStoreFailed;
        if (record.sequence != self.next_sequence) return error.EventSequenceMismatch;
        if (!content_id.eql(record.previous, self.head)) return error.EventParentMismatch;

        const expected_id = event_log.eventContentId(record.sequence, record.previous, record.event);
        if (!content_id.eql(expected_id, record.id)) return error.EventIdMismatch;

        const line = try encodeRecordLine(self.allocator, record);
        defer self.allocator.free(line);

        self.events_file.writePositionalAll(self.io, line, self.next_offset) catch |err| {
            self.failed = true;
            return err;
        };
        self.events_file.sync(self.io) catch |err| {
            self.failed = true;
            return err;
        };

        self.next_offset += @intCast(line.len);
        self.next_sequence += 1;
        self.head = record.id;
    }

    fn appendFromSink(context: ?*anyopaque, record: event_log.EventRecord) anyerror!void {
        const opaque = context orelse return error.MissingEventStoreContext;
        const self: *RunWriter = @ptrCast(@alignCast(opaque));
        try self.appendRecord(record);
    }
};

pub fn LoadedEventLog(comptime capacity: usize) type {
    return struct {
        log: event_log.EventLog(capacity),
        ignored_trailing_bytes: usize = 0,
    };
}

pub fn formatRunId(id: core.ContentId, out: *[64]u8) []const u8 {
    encodeHex(&id, out);
    return out;
}

pub fn parseRunId(text: []const u8) !core.ContentId {
    if (text.len != 64) return error.InvalidRunId;
    var id: core.ContentId = undefined;
    try decodeHex(text, &id);
    return id;
}

pub fn createRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    runner: anytype,
) !RunWriter {
    var run_id: core.ContentId = undefined;
    io.random(&run_id);
    if (content_id.isZero(run_id)) run_id[31] = 1;
    return createRunWithId(io, allocator, root_dir, runner, run_id);
}

pub fn createRunWithId(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    runner: anytype,
    run_id: core.ContentId,
) !RunWriter {
    if (content_id.isZero(run_id)) return error.InvalidRunId;
    try validateSnapshotBounds(runner);

    const configuration_digest = runner.configurationDigest();

    var run_name_buffer: [64]u8 = undefined;
    const run_name = formatRunId(run_id, &run_name_buffer);

    try root_dir.createDir(io, run_name, .default_dir);
    var run_dir = try root_dir.openDir(io, run_name, .{});
    defer run_dir.close(io);

    const configuration = try encodeConfiguration(allocator, runner, run_id, configuration_digest);
    defer allocator.free(configuration);

    var configuration_file = try run_dir.createFile(io, configuration_file_name, .{
        .exclusive = true,
    });
    defer configuration_file.close(io);
    try configuration_file.writeStreamingAll(io, configuration);
    try configuration_file.sync(io);

    const events_file = try run_dir.createFile(io, events_file_name, .{
        .read = true,
        .exclusive = true,
    });

    return .{
        .io = io,
        .allocator = allocator,
        .events_file = events_file,
        .run_id = run_id,
    };
}

pub fn loadConfiguration(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    run_id: core.ContentId,
) !ReplayConfiguration {
    var run_dir = try openRunDir(io, root_dir, run_id);
    defer run_dir.close(io);

    const bytes = try run_dir.readFileAlloc(
        io,
        configuration_file_name,
        allocator,
        .limited(max_configuration_bytes),
    );

    var decoder = Decoder{ .bytes = bytes };
    const magic = try decoder.take(configuration_magic.len);
    if (!std.mem.eql(u8, magic, configuration_magic)) return error.UnsupportedRunConfiguration;

    const version = try decoder.readU8();
    if (version != storage_version) return error.UnsupportedStorageVersion;

    var result = ReplayConfiguration{
        .run_id = try decoder.readContentId(),
        .seed = try decoder.readU64(),
        .configuration_digest = try decoder.readContentId(),
    };

    const variable_count = try decoder.readCount(max_replay_variables);
    const invariant_count = try decoder.readCount(max_replay_invariants);
    const operator_count = try decoder.readCount(max_replay_operators);
    const target_count = try decoder.readCount(max_replay_targets);

    while (result.variable_count < variable_count) : (result.variable_count += 1) {
        const id = try decoder.readU32();
        const name = try decoder.readString();
        const kind = try decodeValueKind(try decoder.readU8());
        const merge_policy = try decodeMergePolicy(try decoder.readU8());

        const unit = switch (try decoder.readU8()) {
            0 => null,
            1 => try decoder.readString(),
            else => return error.InvalidRunConfiguration,
        };

        const freshness_rounds: ?u32 = switch (try decoder.readU8()) {
            0 => null,
            1 => try decoder.readU32(),
            else => return error.InvalidRunConfiguration,
        };

        result.variables[result.variable_count] = .{
            .variable = .{
                .id = id,
                .name = name,
                .kind = kind,
                .unit = unit,
                .merge_policy = merge_policy,
            },
            .freshness_rounds = freshness_rounds,
        };
    }

    while (result.invariant_count < invariant_count) : (result.invariant_count += 1) {
        var invariant = SnapshotInvariant{
            .id = try decoder.readU32(),
            .name = try decoder.readString(),
        };
        const require_count = try decoder.readCount(max_replay_dependencies);
        while (invariant.require_count < require_count) : (invariant.require_count += 1) {
            invariant.requires[invariant.require_count] = try decoder.readU32();
        }
        result.invariants[result.invariant_count] = invariant;
    }

    while (result.operator_count < operator_count) : (result.operator_count += 1) {
        var operator = SnapshotOperator{
            .id = try decoder.readU32(),
            .name = try decoder.readString(),
        };

        const requires_variable_count = try decoder.readCount(max_replay_dependencies);
        while (operator.requires_variable_count < requires_variable_count) : (operator.requires_variable_count += 1) {
            operator.requires_variables[operator.requires_variable_count] = try decoder.readU32();
        }

        const requires_invariant_count = try decoder.readCount(max_replay_dependencies);
        while (operator.requires_invariant_count < requires_invariant_count) : (operator.requires_invariant_count += 1) {
            operator.requires_invariants[operator.requires_invariant_count] = try decoder.readU32();
        }

        const provides_variable_count = try decoder.readCount(max_replay_dependencies);
        while (operator.provides_variable_count < provides_variable_count) : (operator.provides_variable_count += 1) {
            operator.provides_variables[operator.provides_variable_count] = try decoder.readU32();
        }

        const provides_invariant_count = try decoder.readCount(max_replay_dependencies);
        while (operator.provides_invariant_count < provides_invariant_count) : (operator.provides_invariant_count += 1) {
            operator.provides_invariants[operator.provides_invariant_count] = try decoder.readU32();
        }

        operator.eligibility_mode = try decodeDependencyMode(try decoder.readU8());
        const term_count = try decoder.readCount(max_replay_dependencies);
        while (operator.eligibility_term_count < term_count) : (operator.eligibility_term_count += 1) {
            const tag = try decoder.readU8();
            const id = try decoder.readU32();
            operator.eligibility_terms[operator.eligibility_term_count] = switch (tag) {
                1 => .{ .variable_known = id },
                2 => .{ .variable_resolved = id },
                3 => .{ .invariant_satisfied = id },
                else => return error.InvalidRunConfiguration,
            };
        }

        result.operators[result.operator_count] = operator;
    }

    while (result.target_count < target_count) : (result.target_count += 1) {
        result.targets[result.target_count] = try decoder.readU32();
    }

    if (!decoder.done()) return error.InvalidRunConfiguration;

    if (!content_id.eql(result.run_id, run_id)) return error.RunIdMismatch;
    return result;
}

pub fn loadEventLog(
    comptime capacity: usize,
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    run_id: core.ContentId,
) !LoadedEventLog(capacity) {
    var run_dir = try openRunDir(io, root_dir, run_id);
    defer run_dir.close(io);

    const source = try run_dir.readFileAlloc(
        io,
        events_file_name,
        allocator,
        .limited(max_event_file_bytes),
    );

    var result = LoadedEventLog(capacity){
        .log = .{},
    };

    var start: usize = 0;
    while (std.mem.indexOfScalar(u8, source[start..], '\n')) |relative_newline| {
        const newline = start + relative_newline;
        const line = source[start..newline];
        if (line.len == 0) return error.InvalidEventRecordLine;

        const record = try decodeRecordLine(allocator, line);
        if (record.sequence != @as(u64, @intCast(result.log.len))) {
            return error.EventSequenceMismatch;
        }
        if (!content_id.eql(record.previous, result.log.headId())) {
            return error.EventParentMismatch;
        }

        const replayed_id = try result.log.append(record.event);
        if (!content_id.eql(replayed_id, record.id)) return error.EventIdMismatch;

        start = newline + 1;
    }

    if (start < source.len) {
        result.ignored_trailing_bytes = source.len - start;
    }

    try result.log.validate();
    return result;
}

pub fn openDefaultRoot(io: std.Io) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, default_root_path, .{});
}

pub fn createDefaultRoot(io: std.Io) !std.Io.Dir {
    return std.Io.Dir.cwd().createDirPathOpen(io, default_root_path, .{});
}

fn openRunDir(io: std.Io, root_dir: std.Io.Dir, run_id: core.ContentId) !std.Io.Dir {
    var run_name_buffer: [64]u8 = undefined;
    const run_name = formatRunId(run_id, &run_name_buffer);
    return root_dir.openDir(io, run_name, .{});
}

fn validateSnapshotBounds(runner: anytype) !void {
    if (runner.registry.variable_count > max_replay_variables or
        runner.registry.invariant_count > max_replay_invariants or
        runner.registry.operator_count > max_replay_operators or
        runner.targets.len > max_replay_targets)
    {
        return error.ReplayConfigurationCapacityExceeded;
    }

    for (runner.registry.invariants[0..runner.registry.invariant_count]) |invariant| {
        if (invariant.requires.len > max_replay_dependencies) {
            return error.ReplayConfigurationCapacityExceeded;
        }
    }

    for (runner.registry.operators[0..runner.registry.operator_count]) |operator| {
        if (operator.manifest.requires_variables.len > max_replay_dependencies or
            operator.manifest.requires_invariants.len > max_replay_dependencies or
            operator.manifest.provides_variables.len > max_replay_dependencies or
            operator.manifest.provides_invariants.len > max_replay_dependencies or
            operator.eligibility.terms.len > max_replay_dependencies)
        {
            return error.ReplayConfigurationCapacityExceeded;
        }
    }
}

fn encodeConfiguration(
    allocator: std.mem.Allocator,
    runner: anytype,
    run_id: core.ContentId,
    configuration_digest: core.ContentId,
) ![]u8 {
    const size = try configurationEncodedSize(runner);
    if (size > max_configuration_bytes) return error.RunConfigurationTooLarge;

    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);

    var encoder = Encoder{ .bytes = bytes };
    try encoder.writeBytes(configuration_magic);
    try encoder.writeU8(storage_version);
    try encoder.writeContentId(run_id);
    try encoder.writeU64(runner.seed);
    try encoder.writeContentId(configuration_digest);
    try encoder.writeCount(runner.registry.variable_count);
    try encoder.writeCount(runner.registry.invariant_count);
    try encoder.writeCount(runner.registry.operator_count);
    try encoder.writeCount(runner.targets.len);

    for (runner.registry.variables[0..runner.registry.variable_count]) |schema| {
        try encoder.writeU32(schema.variable.id);
        try encoder.writeString(schema.variable.name);
        try encoder.writeU8(@intFromEnum(schema.variable.kind));
        try encoder.writeU8(@intFromEnum(schema.variable.merge_policy));

        if (schema.variable.unit) |unit| {
            try encoder.writeU8(1);
            try encoder.writeString(unit);
        } else {
            try encoder.writeU8(0);
        }

        if (schema.freshness_rounds) |freshness| {
            try encoder.writeU8(1);
            try encoder.writeU32(freshness);
        } else {
            try encoder.writeU8(0);
        }
    }

    for (runner.registry.invariants[0..runner.registry.invariant_count]) |invariant| {
        try encoder.writeU32(invariant.id);
        try encoder.writeString(invariant.name);
        try encoder.writeCount(invariant.requires.len);
        for (invariant.requires) |id| try encoder.writeU32(id);
    }

    for (runner.registry.operators[0..runner.registry.operator_count]) |operator| {
        try encoder.writeU32(operator.manifest.id);
        try encoder.writeString(operator.manifest.name);

        try encoder.writeCount(operator.manifest.requires_variables.len);
        for (operator.manifest.requires_variables) |id| try encoder.writeU32(id);

        try encoder.writeCount(operator.manifest.requires_invariants.len);
        for (operator.manifest.requires_invariants) |id| try encoder.writeU32(id);

        try encoder.writeCount(operator.manifest.provides_variables.len);
        for (operator.manifest.provides_variables) |id| try encoder.writeU32(id);

        try encoder.writeCount(operator.manifest.provides_invariants.len);
        for (operator.manifest.provides_invariants) |id| try encoder.writeU32(id);

        try encoder.writeU8(@intFromEnum(operator.eligibility.mode));
        try encoder.writeCount(operator.eligibility.terms.len);
        for (operator.eligibility.terms) |term| {
            switch (term) {
                .variable_known => |id| {
                    try encoder.writeU8(1);
                    try encoder.writeU32(id);
                },
                .variable_resolved => |id| {
                    try encoder.writeU8(2);
                    try encoder.writeU32(id);
                },
                .invariant_satisfied => |id| {
                    try encoder.writeU8(3);
                    try encoder.writeU32(id);
                },
            }
        }
    }

    for (runner.targets) |target| try encoder.writeU32(target);
    if (encoder.pos != bytes.len) return error.RunConfigurationEncodingMismatch;
    return bytes;
}

fn configurationEncodedSize(runner: anytype) !usize {
    var size: usize = configuration_magic.len + 1 + 32 + 8 + 32 + 4 * 4;

    for (runner.registry.variables[0..runner.registry.variable_count]) |schema| {
        try addSize(&size, 4 + 4 + schema.variable.name.len + 1 + 1 + 1 + 1);
        if (schema.variable.unit) |unit| try addSize(&size, 4 + unit.len);
        if (schema.freshness_rounds != null) try addSize(&size, 4);
    }

    for (runner.registry.invariants[0..runner.registry.invariant_count]) |invariant| {
        try addSize(&size, 4 + 4 + invariant.name.len + 4 + invariant.requires.len * 4);
    }

    for (runner.registry.operators[0..runner.registry.operator_count]) |operator| {
        try addSize(&size, 4 + 4 + operator.manifest.name.len);
        try addSize(&size, 4 + operator.manifest.requires_variables.len * 4);
        try addSize(&size, 4 + operator.manifest.requires_invariants.len * 4);
        try addSize(&size, 4 + operator.manifest.provides_variables.len * 4);
        try addSize(&size, 4 + operator.manifest.provides_invariants.len * 4);
        try addSize(&size, 1 + 4 + operator.eligibility.terms.len * 5);
    }

    try addSize(&size, runner.targets.len * 4);
    return size;
}

fn addSize(total: *usize, amount: usize) !void {
    if (amount > max_configuration_bytes -| total.*) return error.RunConfigurationTooLarge;
    total.* += amount;
    if (total.* > max_configuration_bytes) return error.RunConfigurationTooLarge;
}

fn encodeRecordLine(allocator: std.mem.Allocator, record: event_log.EventRecord) ![]u8 {
    const payload = try encodeEventPayload(allocator, record.event);
    defer allocator.free(payload);

    var previous_hex: [64]u8 = undefined;
    var id_hex: [64]u8 = undefined;
    encodeHex(&record.previous, &previous_hex);
    encodeHex(&record.id, &id_hex);

    var prefix_buffer: [320]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &prefix_buffer,
        "{{\"v\":{d},\"seq\":{d},\"prev\":\"{s}\",\"id\":\"{s}\",\"kind\":{d},\"payload\":\"",
        .{
            storage_version,
            record.sequence,
            &previous_hex,
            &id_hex,
            @intFromEnum(std.meta.activeTag(record.event)),
        },
    );

    if (payload.len > max_event_payload_bytes) return error.EventPayloadTooLarge;
    const payload_hex_len = payload.len * 2;
    const total_len = prefix.len + payload_hex_len + 3;
    const line = try allocator.alloc(u8, total_len);
    errdefer allocator.free(line);

    @memcpy(line[0..prefix.len], prefix);
    encodeHex(payload, line[prefix.len .. prefix.len + payload_hex_len]);
    @memcpy(line[prefix.len + payload_hex_len ..], "\"}\n");
    return line;
}

fn decodeRecordLine(allocator: std.mem.Allocator, line: []const u8) !event_log.EventRecord {
    var parser = LineParser{ .bytes = line };

    try parser.expect("{\"v\":");
    const version = try parser.readUnsigned(u8);
    if (version != storage_version) return error.UnsupportedStorageVersion;

    try parser.expect(",\"seq\":");
    const sequence = try parser.readUnsigned(u64);

    try parser.expect(",\"prev\":\"");
    const previous = try parser.readContentId();

    try parser.expect("\",\"id\":\"");
    const id = try parser.readContentId();

    try parser.expect("\",\"kind\":");
    const kind = try decodeEventKind(try parser.readUnsigned(u8));

    try parser.expect(",\"payload\":\"");
    const payload_hex = try parser.takeUntil('"');
    try parser.expect("}");
    if (!parser.done()) return error.InvalidEventRecordLine;

    if ((payload_hex.len & 1) != 0) return error.InvalidEventPayload;
    const payload_len = payload_hex.len / 2;
    if (payload_len > max_event_payload_bytes) return error.EventPayloadTooLarge;

    const payload = try allocator.alloc(u8, payload_len);
    try decodeHex(payload_hex, payload);

    const event = try decodeEventPayload(kind, payload);
    return .{
        .sequence = sequence,
        .previous = previous,
        .id = id,
        .event = event,
    };
}

fn encodeEventPayload(allocator: std.mem.Allocator, event: event_log.RunEvent) ![]u8 {
    const size = try eventPayloadSize(event);
    if (size > max_event_payload_bytes) return error.EventPayloadTooLarge;

    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var encoder = Encoder{ .bytes = bytes };

    switch (event) {
        .run_started => |payload| {
            try encoder.writeU64(payload.seed);
            try encoder.writeContentId(payload.configuration_digest);
        },
        .observation_added => |payload| {
            try encoder.writeU32(payload.round);
            try encodeClaim(&encoder, payload.claim);
            try encoder.writeContentId(payload.claim_id);
        },
        .operator_started => |payload| {
            try encoder.writeU32(payload.round);
            try encoder.writeU32(payload.operator);
            try encoder.writeU64(payload.activation_epoch);
            try encoder.writeContentId(payload.input_fingerprint);
        },
        .claim_accepted => |payload| {
            try encoder.writeU32(payload.round);
            try encodeClaim(&encoder, payload.claim);
            try encoder.writeContentId(payload.claim_id);
        },
        .invariant_changed => |payload| {
            try encoder.writeU32(payload.round);
            try encodeInvariantClaim(&encoder, payload.claim);
        },
        .operator_completed => |payload| {
            try encoder.writeU32(payload.round);
            try encoder.writeU32(payload.operator);
            try encoder.writeU64(payload.activation_epoch);
            try encoder.writeU16(payload.variable_claims);
            try encoder.writeU16(payload.invariant_claims);
            try encoder.writeU16(payload.actions);
        },
        .operator_failed => |payload| {
            try encoder.writeU32(payload.round);
            try encoder.writeU32(payload.operator);
            try encoder.writeU64(payload.activation_epoch);
            try encoder.writeU8(@intFromEnum(payload.kind));
            try encoder.writeU16(payload.rejected_claims);
        },
    }

    if (encoder.pos != bytes.len) return error.EventPayloadEncodingMismatch;
    return bytes;
}

fn decodeEventPayload(kind: event_log.EventKind, bytes: []const u8) !event_log.RunEvent {
    var decoder = Decoder{ .bytes = bytes };
    const event: event_log.RunEvent = switch (kind) {
        .run_started => .{ .run_started = .{
            .seed = try decoder.readU64(),
            .configuration_digest = try decoder.readContentId(),
        } },
        .observation_added => .{ .observation_added = .{
            .round = try decoder.readU32(),
            .claim = try decodeClaim(&decoder),
            .claim_id = try decoder.readContentId(),
        } },
        .operator_started => .{ .operator_started = .{
            .round = try decoder.readU32(),
            .operator = try decoder.readU32(),
            .activation_epoch = try decoder.readU64(),
            .input_fingerprint = try decoder.readContentId(),
        } },
        .claim_accepted => .{ .claim_accepted = .{
            .round = try decoder.readU32(),
            .claim = try decodeClaim(&decoder),
            .claim_id = try decoder.readContentId(),
        } },
        .invariant_changed => .{ .invariant_changed = .{
            .round = try decoder.readU32(),
            .claim = try decodeInvariantClaim(&decoder),
        } },
        .operator_completed => .{ .operator_completed = .{
            .round = try decoder.readU32(),
            .operator = try decoder.readU32(),
            .activation_epoch = try decoder.readU64(),
            .variable_claims = try decoder.readU16(),
            .invariant_claims = try decoder.readU16(),
            .actions = try decoder.readU16(),
        } },
        .operator_failed => .{ .operator_failed = .{
            .round = try decoder.readU32(),
            .operator = try decoder.readU32(),
            .activation_epoch = try decoder.readU64(),
            .kind = try decodeFailureKind(try decoder.readU8()),
            .rejected_claims = try decoder.readU16(),
        } },
    };

    if (!decoder.done()) return error.InvalidEventPayload;
    return event;
}

fn eventPayloadSize(event: event_log.RunEvent) !usize {
    return switch (event) {
        .run_started => 8 + 32,
        .observation_added => |payload| 4 + try claimEncodedSize(payload.claim) + 32,
        .operator_started => 4 + 4 + 8 + 32,
        .claim_accepted => |payload| 4 + try claimEncodedSize(payload.claim) + 32,
        .invariant_changed => |payload| 4 + invariantClaimEncodedSize(payload.claim),
        .operator_completed => 4 + 4 + 8 + 2 + 2 + 2,
        .operator_failed => 4 + 4 + 8 + 1 + 2,
    };
}

fn claimEncodedSize(claim: core.Claim) !usize {
    try claim.validateShape();
    var size: usize = 4 + 1 + 2 + 4 + 1 + @as(usize, claim.parent_count) * 32 + 1;
    if (claim.value) |value| {
        size += 1;
        size += switch (value) {
            .integer, .float => 8,
            .boolean => 1,
            .text => |text| 4 + text.len,
            .artifact_ref => 32,
        };
    }
    if (size > max_event_payload_bytes) return error.EventPayloadTooLarge;
    return size;
}

fn invariantClaimEncodedSize(claim: core.InvariantClaim) usize {
    return 4 + 1 + 4 + 1 + @as(usize, claim.parent_count) * 32;
}

fn encodeClaim(encoder: *Encoder, claim: core.Claim) !void {
    try claim.validateShape();
    try encoder.writeU32(claim.variable);
    try encoder.writeU8(@intFromEnum(claim.status));
    try encoder.writeU16(claim.confidence_permille);
    try encoder.writeU32(claim.source_operator);
    try encoder.writeU8(claim.parent_count);

    var i: usize = 0;
    while (i < claim.parent_count) : (i += 1) {
        try encoder.writeContentId(claim.parents[i]);
    }

    if (claim.value) |value| {
        try encoder.writeU8(1);
        try encoder.writeU8(@intFromEnum(value.kind()));
        switch (value) {
            .integer => |v| try encoder.writeU64(@bitCast(v)),
            .float => |v| try encoder.writeU64(@bitCast(v)),
            .boolean => |v| try encoder.writeU8(if (v) 1 else 0),
            .text => |v| try encoder.writeString(v),
            .artifact_ref => |v| try encoder.writeContentId(v),
        }
    } else {
        try encoder.writeU8(0);
    }
}

fn decodeClaim(decoder: *Decoder) !core.Claim {
    var claim = core.Claim{
        .variable = try decoder.readU32(),
        .status = try decodeEpistemicStatus(try decoder.readU8()),
        .confidence_permille = try decoder.readU16(),
        .source_operator = try decoder.readU32(),
    };

    const parent_count_raw = try decoder.readU8();
    const parent_count: usize = @intCast(parent_count_raw);
    if (parent_count > core.max_claim_parents) return error.InvalidEventPayload;
    claim.parent_count = @intCast(parent_count);

    var i: usize = 0;
    while (i < parent_count) : (i += 1) {
        claim.parents[i] = try decoder.readContentId();
    }

    switch (try decoder.readU8()) {
        0 => claim.value = null,
        1 => {
            const kind = try decodeValueKind(try decoder.readU8());
            claim.value = switch (kind) {
                .integer => .{ .integer = @bitCast(try decoder.readU64()) },
                .float => .{ .float = @bitCast(try decoder.readU64()) },
                .boolean => .{ .boolean = switch (try decoder.readU8()) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidEventPayload,
                } },
                .text => .{ .text = try decoder.readString() },
                .artifact_ref => .{ .artifact_ref = try decoder.readContentId() },
            };
        },
        else => return error.InvalidEventPayload,
    }

    try claim.validateShape();
    return claim;
}

fn encodeInvariantClaim(encoder: *Encoder, claim: core.InvariantClaim) !void {
    if (@as(usize, claim.parent_count) > core.max_claim_parents) return error.TooManyParents;
    try encoder.writeU32(claim.invariant);
    try encoder.writeU8(@intFromEnum(claim.status));
    try encoder.writeU32(claim.source_operator);
    try encoder.writeU8(claim.parent_count);

    var i: usize = 0;
    while (i < claim.parent_count) : (i += 1) {
        try encoder.writeContentId(claim.parents[i]);
    }
}

fn decodeInvariantClaim(decoder: *Decoder) !core.InvariantClaim {
    var claim = core.InvariantClaim{
        .invariant = try decoder.readU32(),
        .status = try decodeInvariantStatus(try decoder.readU8()),
        .source_operator = try decoder.readU32(),
    };

    const parent_count_raw = try decoder.readU8();
    const parent_count: usize = @intCast(parent_count_raw);
    if (parent_count > core.max_claim_parents) return error.InvalidEventPayload;
    claim.parent_count = @intCast(parent_count);

    var i: usize = 0;
    while (i < parent_count) : (i += 1) {
        claim.parents[i] = try decoder.readContentId();
    }
    return claim;
}

const Encoder = struct {
    bytes: []u8,
    pos: usize = 0,

    fn writeBytes(self: *Encoder, value: []const u8) !void {
        if (value.len > self.bytes.len -| self.pos) return error.EncodingOverflow;
        @memcpy(self.bytes[self.pos .. self.pos + value.len], value);
        self.pos += value.len;
    }

    fn writeU8(self: *Encoder, value: u8) !void {
        try self.writeBytes(&.{value});
    }

    fn writeU16(self: *Encoder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        bytes[0] = @truncate(value);
        bytes[1] = @truncate(value >> 8);
        try self.writeBytes(&bytes);
    }

    fn writeU32(self: *Encoder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        encodeU32(value, &bytes);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Encoder, value: u64) !void {
        var bytes: [8]u8 = undefined;
        encodeU64(value, &bytes);
        try self.writeBytes(&bytes);
    }

    fn writeContentId(self: *Encoder, value: core.ContentId) !void {
        try self.writeBytes(&value);
    }

    fn writeString(self: *Encoder, value: []const u8) !void {
        if (value.len > 0xffffffff) return error.EncodingOverflow;
        try self.writeU32(@intCast(value.len));
        try self.writeBytes(value);
    }

    fn writeCount(self: *Encoder, count: usize) !void {
        if (count > 0xffffffff) return error.EncodingOverflow;
        try self.writeU32(@intCast(count));
    }
};

const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn done(self: *const Decoder) bool {
        return self.pos == self.bytes.len;
    }

    fn take(self: *Decoder, len: usize) ![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.TruncatedEncoding;
        const result = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return result;
    }

    fn readU8(self: *Decoder) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *Decoder) !u16 {
        const bytes = try self.take(2);
        return @as(u16, bytes[0]) |
            (@as(u16, bytes[1]) << 8);
    }

    fn readU32(self: *Decoder) !u32 {
        const bytes = try self.take(4);
        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }

    fn readU64(self: *Decoder) !u64 {
        const bytes = try self.take(8);
        var value: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const shift: u6 = @intCast(i * 8);
            value |= @as(u64, bytes[i]) << shift;
        }
        return value;
    }

    fn readContentId(self: *Decoder) !core.ContentId {
        const bytes = try self.take(32);
        var id: core.ContentId = undefined;
        @memcpy(id[0..], bytes);
        return id;
    }

    fn readString(self: *Decoder) ![]const u8 {
        const len = try self.readU32();
        return self.take(@intCast(len));
    }

    fn readCount(self: *Decoder, maximum: usize) !usize {
        const value = try self.readU32();
        const count: usize = @intCast(value);
        if (count > maximum) return error.ReplayConfigurationCapacityExceeded;
        return count;
    }
};

const LineParser = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn done(self: *const LineParser) bool {
        return self.pos == self.bytes.len;
    }

    fn expect(self: *LineParser, literal: []const u8) !void {
        if (literal.len > self.bytes.len -| self.pos) return error.InvalidEventRecordLine;
        if (!std.mem.eql(u8, self.bytes[self.pos .. self.pos + literal.len], literal)) {
            return error.InvalidEventRecordLine;
        }
        self.pos += literal.len;
    }

    fn readUnsigned(self: *LineParser, comptime T: type) !T {
        const start = self.pos;
        var value: u64 = 0;
        while (self.pos < self.bytes.len and std.ascii.isDigit(self.bytes[self.pos])) : (self.pos += 1) {
            const digit = self.bytes[self.pos] - '0';
            if (value > (std.math.maxInt(u64) - digit) / 10) return error.InvalidEventRecordLine;
            value = value * 10 + digit;
        }
        if (self.pos == start) return error.InvalidEventRecordLine;
        const max_value: u64 = @intCast(std.math.maxInt(T));
        if (value > max_value) return error.InvalidEventRecordLine;
        return @intCast(value);
    }

    fn readContentId(self: *LineParser) !core.ContentId {
        if (64 > self.bytes.len -| self.pos) return error.InvalidEventRecordLine;
        const text = self.bytes[self.pos .. self.pos + 64];
        self.pos += 64;
        var id: core.ContentId = undefined;
        try decodeHex(text, &id);
        return id;
    }

    fn takeUntil(self: *LineParser, delimiter: u8) ![]const u8 {
        const relative_end = std.mem.indexOfScalar(u8, self.bytes[self.pos..], delimiter) orelse
            return error.InvalidEventRecordLine;
        const end = self.pos + relative_end;
        const result = self.bytes[self.pos..end];
        self.pos = end + 1;
        return result;
    }
};

fn decodeEventKind(value: u8) !event_log.EventKind {
    return switch (value) {
        1 => .run_started,
        2 => .observation_added,
        3 => .operator_started,
        4 => .claim_accepted,
        5 => .invariant_changed,
        6 => .operator_completed,
        7 => .operator_failed,
        else => error.InvalidEventKind,
    };
}

fn decodeFailureKind(value: u8) !event_log.FailureKind {
    return switch (value) {
        0 => .execution,
        1 => .validation,
        else => error.InvalidEventPayload,
    };
}

fn decodeValueKind(value: u8) !core.ValueKind {
    return switch (value) {
        0 => .integer,
        1 => .float,
        2 => .boolean,
        3 => .text,
        4 => .artifact_ref,
        else => error.InvalidValueKind,
    };
}

fn decodeMergePolicy(value: u8) !core.MergePolicy {
    return switch (value) {
        0 => .latest,
        1 => .highest_confidence,
        2 => .retain_all_conflict,
        else => error.InvalidRunConfiguration,
    };
}

fn decodeDependencyMode(value: u8) !reg.DependencyMode {
    return switch (value) {
        0 => .all,
        1 => .any,
        else => error.InvalidRunConfiguration,
    };
}

fn decodeEpistemicStatus(value: u8) !core.EpistemicStatus {
    return switch (value) {
        0 => .unknown,
        1 => .observed,
        2 => .estimated,
        3 => .derived,
        4 => .not_visible,
        5 => .unavailable,
        6 => .blocked,
        7 => .conflicting,
        else => error.InvalidEventPayload,
    };
}

fn decodeInvariantStatus(value: u8) !core.InvariantStatus {
    return switch (value) {
        0 => .unknown,
        1 => .satisfied,
        2 => .violated,
        3 => .blocked,
        else => error.InvalidEventPayload,
    };
}

fn encodeHex(input: []const u8, output: []u8) void {
    const alphabet = "0123456789abcdef";
    std.debug.assert(output.len == input.len * 2);
    for (input, 0..) |byte, i| {
        output[i * 2] = alphabet[byte >> 4];
        output[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn decodeHex(input: []const u8, output: []u8) !void {
    if (input.len != output.len * 2) return error.InvalidHex;
    for (output, 0..) |*byte, i| {
        const high = try hexNibble(input[i * 2]);
        const low = try hexNibble(input[i * 2 + 1]);
        byte.* = (high << 4) | low;
    }
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidHex,
    };
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

test "run ids round-trip as lowercase hex" {
    var id = content_id.zero;
    id[0] = 0xab;
    id[31] = 0x7f;

    var text_buffer: [64]u8 = undefined;
    const text = formatRunId(id, &text_buffer);

    try std.testing.expectEqual(@as(usize, 64), text.len);
    try std.testing.expect(content_id.eql(id, try parseRunId(text)));
    try std.testing.expectError(error.InvalidRunId, parseRunId("short"));
}

test "durable event log survives close load and replay without operator execution" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const R = execution.Runner(3, 1, 2, 32);

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

    var writer = try createRun(io, std.testing.allocator, tmp.dir, &live);
    const run_id = writer.run_id;
    try live.setEventSink(writer.eventSink());

    _ = try live.seedVariable(1, .observed, .{ .integer = 20 }, 1000);
    const live_result = try live.runUntilQuiescent(8);
    try std.testing.expectEqual(core.ResultOutcome.success, live_result.summary.outcome);
    try std.testing.expectEqual(@as(u64, @intCast(live.eventRecords().len)), writer.next_sequence);
    writer.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const configuration = try loadConfiguration(io, arena, tmp.dir, run_id);
    try std.testing.expect(content_id.eql(configuration.configuration_digest, live.configurationDigest()));

    const loaded = try loadEventLog(R.max_event_records, io, arena, tmp.dir, run_id);
    try std.testing.expectEqual(@as(usize, 0), loaded.ignored_trailing_bytes);
    try std.testing.expectEqual(live.eventRecords().len, loaded.log.slice().len);

    var replayed = R.init(configuration.seed, configuration.targetSlice());
    try configuration.configure(&replayed);
    try std.testing.expect(content_id.eql(replayed.configurationDigest(), configuration.configuration_digest));
    try replayed.replayRecords(loaded.log.slice());

    const replay_result = replayed.result();
    try std.testing.expectEqual(live_result.summary.outcome, replay_result.summary.outcome);
    try std.testing.expectEqual(live_result.summary.rounds, replay_result.summary.rounds);
    try std.testing.expectEqual(live_result.summary.accepted_claims, replay_result.summary.accepted_claims);
    try std.testing.expectEqual(live_result.summary.proposed_actions, replay_result.summary.proposed_actions);
    try std.testing.expect(core.Value.eql(replay_result.value(3).?, .{ .integer = 42 }));
    try std.testing.expect(content_id.eql(live.eventHeadId(), replayed.eventHeadId()));

    const live_snapshot = live.schedulerSnapshot();
    const replay_snapshot = replayed.schedulerSnapshot();
    try std.testing.expectEqual(live_snapshot.outcome, replay_snapshot.outcome);
    try std.testing.expectEqual(live_snapshot.pending_activations, replay_snapshot.pending_activations);
    try std.testing.expectEqual(live_snapshot.eligible_operators, replay_snapshot.eligible_operators);
}

test "loader ignores only an unterminated crash tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const R = execution.Runner(1, 0, 0, 8);
    var live = R.init(7, &.{1});
    try live.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    var writer = try createRun(io, std.testing.allocator, tmp.dir, &live);
    const run_id = writer.run_id;
    try live.setEventSink(writer.eventSink());
    _ = try live.seedVariable(1, .observed, .{ .integer = 9 }, 1000);
    const complete_event_count = live.eventRecords().len;
    writer.deinit();

    var run_dir = try openRunDir(io, tmp.dir, run_id);
    defer run_dir.close(io);
    var events_file = try run_dir.createFile(io, events_file_name, .{
        .read = true,
        .truncate = false,
    });
    defer events_file.close(io);

    const offset = try events_file.length(io);
    const crash_tail = "{\"v\":1";
    try events_file.writePositionalAll(io, crash_tail, offset);
    try events_file.sync(io);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const loaded = try loadEventLog(
        R.max_event_records,
        io,
        arena_state.allocator(),
        tmp.dir,
        run_id,
    );
    try std.testing.expectEqual(complete_event_count, loaded.log.slice().len);
    try std.testing.expectEqual(crash_tail.len, loaded.ignored_trailing_bytes);
}

test "loader rejects a malformed complete event record" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const R = execution.Runner(1, 0, 0, 8);
    var live = R.init(7, &.{1});
    try live.addVariable(.{ .variable = .{
        .id = 1,
        .name = "input",
        .kind = .integer,
        .merge_policy = .latest,
    } });

    var writer = try createRun(io, std.testing.allocator, tmp.dir, &live);
    const run_id = writer.run_id;
    try live.setEventSink(writer.eventSink());
    _ = try live.seedVariable(1, .observed, .{ .integer = 9 }, 1000);
    writer.deinit();

    var run_dir = try openRunDir(io, tmp.dir, run_id);
    defer run_dir.close(io);
    var events_file = try run_dir.createFile(io, events_file_name, .{
        .read = true,
        .truncate = false,
    });
    defer events_file.close(io);

    const offset = try events_file.length(io);
    try events_file.writePositionalAll(io, "garbage\n", offset);
    try events_file.sync(io);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(
        error.InvalidEventRecordLine,
        loadEventLog(
            R.max_event_records,
            io,
            arena_state.allocator(),
            tmp.dir,
            run_id,
        ),
    );
}
