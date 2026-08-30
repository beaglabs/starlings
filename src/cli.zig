const std = @import("std");
const pack_loader = @import("pack/loader.zig");
const content_id = @import("core/content_id.zig");
const execution = @import("sdk/execution.zig");
const run_store = @import("sdk/run_store.zig");

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
            "  starlings replay <run-id>\n",
    );
    std.process.exit(2);
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
        "REPLAY {s} events={d} round={d} outcome={s} accepted={d} rejected={d} actions={d} pending={d} open={s} head={s}\n",
        .{
            run_id_text,
            runner.eventRecords().len,
            snapshot.round,
            @tagName(snapshot.outcome),
            summary.accepted_claims,
            summary.rejected_claims,
            summary.proposed_actions,
            snapshot.pending_activations,
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
