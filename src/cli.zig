const std = @import("std");
const pack_loader = @import("pack/loader.zig");
const pack_runtime = @import("pack/runtime.zig");
const content_id = @import("core/content_id.zig");
const execution = @import("sdk/execution.zig");
const run_store = @import("sdk/run_store.zig");
const core = @import("sdk/core_types.zig");

const ReplayRunner = execution.Runner(
    run_store.max_replay_variables,
    run_store.max_replay_invariants,
    run_store.max_replay_operators,
    run_store.max_replay_claims,
);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "pack") and
        std.mem.eql(u8, args[2], "validate"))
    {
        const compiled = pack_loader.loadAndCompile(
            io,
            init.gpa,
            init.arena.allocator(),
            args[3],
        ) catch |err| {
            try writeLine(
                io,
                std.Io.File.stderr(),
                "pack validation failed: {t}\n",
                .{err},
            );
            std.process.exit(2);
        };

        try writeLine(
            io,
            std.Io.File.stdout(),
            "VALID {s}@{s} variables={d} invariants={d} operators={d} targets={d}\n",
            .{
                compiled.name,
                compiled.version,
                compiled.variable_count,
                compiled.invariant_count,
                compiled.operator_count,
                compiled.target_count,
            },
        );
        return;
    }

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "pack") and
        std.mem.eql(u8, args[2], "inspect"))
    {
        const compiled = pack_loader.loadAndCompile(
            io,
            init.gpa,
            init.arena.allocator(),
            args[3],
        ) catch |err| {
            try writeLine(
                io,
                std.Io.File.stderr(),
                "pack inspection failed: {t}\n",
                .{err},
            );
            std.process.exit(2);
        };

        try inspect(io, &compiled);
        return;
    }

    if (args.len >= 3 and std.mem.eql(u8, args[1], "run")) {
        var inputs: [64]pack_runtime.SeedInput = undefined;
        var input_count: usize = 0;
        var seed: u64 = 0;
        var max_activations: u32 = 1024;

        var i: usize = 3;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--set")) {
                if (i + 1 >= args.len) {
                    try writeLine(io, std.Io.File.stderr(), "run failed: missing --set value\n", .{});
                    std.process.exit(2);
                }
                if (input_count >= inputs.len) {
                    try writeLine(io, std.Io.File.stderr(), "run failed: too many inputs\n", .{});
                    std.process.exit(2);
                }
                const assignment = args[i + 1];
                const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse {
                    try writeLine(io, std.Io.File.stderr(), "run failed: --set expects name=value\n", .{});
                    std.process.exit(2);
                };
                if (equals == 0) {
                    try writeLine(io, std.Io.File.stderr(), "run failed: empty input name\n", .{});
                    std.process.exit(2);
                }
                inputs[input_count] = .{
                    .name = assignment[0..equals],
                    .value = assignment[equals + 1 ..],
                };
                input_count += 1;
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--seed")) {
                if (i + 1 >= args.len) {
                    try writeLine(io, std.Io.File.stderr(), "run failed: missing --seed value\n", .{});
                    std.process.exit(2);
                }
                seed = std.fmt.parseInt(u64, args[i + 1], 10) catch {
                    try writeLine(io, std.Io.File.stderr(), "run failed: invalid --seed\n", .{});
                    std.process.exit(2);
                };
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--max-activations")) {
                if (i + 1 >= args.len) {
                    try writeLine(io, std.Io.File.stderr(), "run failed: missing --max-activations value\n", .{});
                    std.process.exit(2);
                }
                max_activations = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    try writeLine(io, std.Io.File.stderr(), "run failed: invalid --max-activations\n", .{});
                    std.process.exit(2);
                };
                if (max_activations == 0) {
                    try writeLine(io, std.Io.File.stderr(), "run failed: --max-activations must be positive\n", .{});
                    std.process.exit(2);
                }
                i += 2;
                continue;
            }

            try writeLine(io, std.Io.File.stderr(), "run failed: unknown option {s}\n", .{args[i]});
            std.process.exit(2);
        }

        runPack(
            io,
            init.gpa,
            init.arena.allocator(),
            args[2],
            seed,
            max_activations,
            inputs[0..input_count],
        ) catch |err| {
            try writeLine(
                io,
                std.Io.File.stderr(),
                "run failed: {t}\n",
                .{err},
            );
            std.process.exit(2);
        };
        return;
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "replay")) {
        replayRun(
            io,
            init.arena.allocator(),
            args[2],
        ) catch |err| {
            try writeLine(
                io,
                std.Io.File.stderr(),
                "replay failed: {t}\n",
                .{err},
            );
            std.process.exit(2);
        };
        return;
    }

    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  starlings pack validate <pack-dir>\n" ++
            "  starlings pack inspect <pack-dir>\n" ++
            "  starlings run <pack-dir> [--set name=value]... [--seed N] [--max-activations N]\n" ++
            "  starlings replay <run-id>\n",
    );
    std.process.exit(2);
}

fn runPack(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pack_dir: []const u8,
    seed: u64,
    max_activations: u32,
    inputs: []const pack_runtime.SeedInput,
) !void {
    var compiled = try pack_loader.loadAndCompile(
        io,
        gpa,
        arena,
        pack_dir,
    );

    var runtime = try pack_runtime.Runtime.init(
        io,
        gpa,
        arena,
        pack_dir,
        &compiled,
        seed,
        &.{},
    );
    defer runtime.deinit();

    var root = try run_store.createDefaultRoot(io);
    defer root.close(io);

    var writer = try run_store.createRun(
        io,
        gpa,
        root,
        &runtime.runner,
    );
    defer writer.deinit();

    try runtime.runner.setArtifactVerifier(writer.artifactVerifier());
    try runtime.runner.setEventSink(writer.eventSink());
    try runtime.seedInputs(inputs);

    const result = try runtime.runner.runUntilQuiescent(max_activations);
    const snapshot = runtime.runner.schedulerSnapshot();

    var run_id_buffer: [64]u8 = undefined;
    const run_id = run_store.formatRunId(writer.run_id, &run_id_buffer);
    var head_buffer: [64]u8 = undefined;
    const head = run_store.formatRunId(runtime.runner.eventHeadId(), &head_buffer);

    try writeLine(
        io,
        std.Io.File.stdout(),
        "RUN {s} pack={s}@{s} outcome={s} round={d} accepted={d} rejected={d} actions={d} artifacts={d} pending={d} approvals={d} head={s}\n",
        .{
            run_id,
            compiled.name,
            compiled.version,
            @tagName(result.summary.outcome),
            result.summary.rounds,
            result.summary.accepted_claims,
            result.summary.rejected_claims,
            result.summary.proposed_actions,
            runtime.runner.artifactEmissionCount(),
            snapshot.pending_activations,
            snapshot.pending_approvals,
            head,
        },
    );

    for (compiled.targets[0..compiled.target_count]) |target_id| {
        var target_name: []const u8 = "<unknown>";
        for (compiled.variables[0..compiled.variable_count]) |schema| {
            if (schema.variable.id == target_id) {
                target_name = schema.variable.name;
                break;
            }
        }

        const status = result.status(target_id) orelse .unknown;
        var value_buffer: [256]u8 = undefined;
        const value_text = try formatValue(result.value(target_id), &value_buffer);
        try writeLine(
            io,
            std.Io.File.stdout(),
            "TARGET {s} status={s} value={s}\n",
            .{ target_name, @tagName(status), value_text },
        );
    }
}

fn formatValue(value: ?core.Value, out: *[256]u8) ![]const u8 {
    const actual = value orelse return "-";
    return switch (actual) {
        .integer => |v| std.fmt.bufPrint(out, "{d}", .{v}),
        .float => |v| std.fmt.bufPrint(out, "{d}", .{v}),
        .boolean => |v| if (v) "true" else "false",
        .text => |v| if (v.len <= out.len) blk: {
            @memcpy(out[0..v.len], v);
            break :blk out[0..v.len];
        } else error.OutputTooLarge,
        .artifact_ref => |id| blk: {
            var id_buffer: [64]u8 = undefined;
            const text = run_store.formatRunId(id, &id_buffer);
            @memcpy(out[0..text.len], text);
            break :blk out[0..text.len];
        },
    };
}

fn replayRun(
    io: std.Io,
    arena: std.mem.Allocator,
    run_id_text: []const u8,
) !void {
    const run_id = try run_store.parseRunId(run_id_text);

    var root = try run_store.openDefaultRoot(io);
    defer root.close(io);

    const configuration = try run_store.loadConfiguration(
        io,
        arena,
        root,
        run_id,
    );

    var runner = ReplayRunner.init(configuration.seed, configuration.targetSlice());
    try configuration.configure(&runner);

    const replay_digest = runner.configurationDigest();
    if (!content_id.eql(replay_digest, configuration.configuration_digest)) {
        return error.ReplayConfigurationMismatch;
    }

    const loaded = try run_store.loadEventLog(
        ReplayRunner.max_event_records,
        io,
        arena,
        root,
        run_id,
    );
    try runner.replayRecords(loaded.log.slice());

    if (loaded.ignored_trailing_bytes != 0) {
        try writeLine(
            io,
            std.Io.File.stderr(),
            "warning: ignored {d} unterminated trailing event bytes\n",
            .{loaded.ignored_trailing_bytes},
        );
    }

    const snapshot = runner.schedulerSnapshot();
    const summary = runner.result().summary;
    const open_activation = try runner.openActivationOperatorId();

    var open_buffer: [32]u8 = undefined;
    const open_text: []const u8 = if (open_activation) |operator_id|
        try std.fmt.bufPrint(&open_buffer, "{d}", .{operator_id})
    else
        "none";

    var head_buffer: [64]u8 = undefined;
    const head = run_store.formatRunId(runner.eventHeadId(), &head_buffer);

    try writeLine(
        io,
        std.Io.File.stdout(),
        "REPLAY {s} events={d} round={d} outcome={s} accepted={d} rejected={d} actions={d} artifacts={d} pending={d} approvals={d} open={s} head={s}\n",
        .{
            run_id_text,
            runner.eventRecords().len,
            snapshot.round,
            @tagName(snapshot.outcome),
            summary.accepted_claims,
            summary.rejected_claims,
            summary.proposed_actions,
            runner.artifactEmissionCount(),
            snapshot.pending_activations,
            snapshot.pending_approvals,
            open_text,
            head,
        },
    );
}

fn inspect(io: std.Io, compiled: anytype) !void {
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Pack: {s} {s}\n\n", .{ compiled.name, compiled.version });
    try writeLine(io, out, "Variables:  {d}\n", .{compiled.variable_count});
    try writeLine(io, out, "Invariants: {d}\n", .{compiled.invariant_count});
    try writeLine(io, out, "Operators:  {d}\n", .{compiled.operator_count});
    try writeLine(io, out, "Targets:    {d}\n\n", .{compiled.target_count});

    try writeLine(io, out, "VARIABLES\n", .{});
    for (compiled.variables[0..compiled.variable_count]) |schema| {
        try writeLine(
            io,
            out,
            "  {s}  type={s} merge={s} id=0x{x}\n",
            .{
                schema.variable.name,
                @tagName(schema.variable.kind),
                @tagName(schema.variable.merge_policy),
                schema.variable.id,
            },
        );
    }

    try writeLine(io, out, "\nINVARIANTS\n", .{});
    for (compiled.invariants[0..compiled.invariant_count]) |invariant| {
        try writeLine(
            io,
            out,
            "  {s}  requires={d} id=0x{x}\n",
            .{ invariant.name, invariant.require_count, invariant.id },
        );
    }

    try writeLine(io, out, "\nOPERATORS\n", .{});
    for (compiled.operators[0..compiled.operator_count]) |operator| {
        try writeLine(
            io,
            out,
            "  {s}  runtime={s} requires={d}+{d} provides={d}+{d} id=0x{x}\n",
            .{
                operator.name,
                @tagName(operator.runtime.kind),
                operator.requires_variable_count,
                operator.requires_invariant_count,
                operator.provides_variable_count,
                operator.provides_invariant_count,
                operator.id,
            },
        );
    }

    try writeLine(io, out, "\nTARGETS\n", .{});
    for (compiled.targets[0..compiled.target_count]) |target_id| {
        var target_name: []const u8 = "<unknown>";
        for (compiled.variables[0..compiled.variable_count]) |schema| {
            if (schema.variable.id == target_id) {
                target_name = schema.variable.name;
                break;
            }
        }
        try writeLine(io, out, "  {s}  id=0x{x}\n", .{ target_name, target_id });
    }
}

fn writeLine(
    io: std.Io,
    out: std.Io.File,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}
