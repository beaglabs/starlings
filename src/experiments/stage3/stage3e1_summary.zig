const std = @import("std");
const model_eval = @import("../../protocol/protocol_model_eval.zig");
const model_summary = @import("../../protocol/protocol_model_summary.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        try usage(io);
        std.process.exit(2);
    }

    const tsv = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[1],
        allocator,
        .limited(32 * 1024 * 1024),
    );
    defer allocator.free(tsv);

    const result = model_summary.summarizeTsv(tsv);
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Stage 3E.1 llama.cpp live-trial summary\n", .{});
    try writeLine(io, out, "records: {d}\n", .{result.records});
    try writeLine(io, out, "malformed_records: {d}\n", .{result.malformed_records});
    try writeLine(io, out, "parse_errors: {d}\n", .{result.parse_errors});
    try writeLine(io, out, "escape_errors: {d}\n", .{result.escape_errors});
    try writeLine(io, out, "invalid_attempts: {d}\n", .{result.invalid_attempts});
    try writeLine(io, out, "balanced_pairs: {s}\n\n", .{if (result.balanced()) "yes" else "no"});

    try writeHeader(io, out);
    try writeMetrics(io, out, "typed_unconstrained", result.overall.typed);
    try writeMetrics(io, out, "cfg_constrained", result.overall.constrained);

    try writeLine(
        io,
        out,
        "\ndeltas (constrained - typed): first_valid={d} permille, trajectory_match={d} permille\n",
        .{ result.overall.validityDeltaPermille(), result.overall.trajectoryMatchDeltaPermille() },
    );

    const workflow_names = [_][]const u8{
        "observe_claim",
        "query_evidence",
        "proposal_accept",
        "proposal_reject",
        "challenge_retract",
        "delegation",
    };

    try writeLine(io, out, "\nby workflow\n", .{});
    var i: usize = 0;
    while (i < workflow_names.len) : (i += 1) {
        try writeLine(io, out, "\n{s}\n", .{workflow_names[i]});
        try writeHeader(io, out);
        try writeMetrics(io, out, "typed_unconstrained", result.by_workflow[i].typed);
        try writeMetrics(io, out, "cfg_constrained", result.by_workflow[i].constrained);
    }

    if (result.malformed_records != 0 or !result.balanced()) {
        try writeLine(
            io,
            out,
            "\nWARNING: malformed or unbalanced trial data; do not use this file for a promotion decision.\n",
            .{},
        );
        std.process.exit(2);
    }
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage: zig run src/stage3e1_summary.zig -- <trials.tsv>\n",
    );
}

fn writeHeader(io: std.Io, out: std.Io.File) !void {
    try out.writeStreamingAll(
        io,
        "mode\ttrials\tfirst-valid\ttrajectory-match\tgrammar-rej\tbackend-err\ttokens\tbytes\tavg-latency-us\n",
    );
}

fn writeMetrics(io: std.Io, out: std.Io.File, name: []const u8, metrics: model_eval.ModeMetrics) !void {
    const avg_latency = if (metrics.trials == 0) 0 else metrics.latency_us / metrics.trials;
    try writeLine(
        io,
        out,
        "{s}\t{d}\t{d}.{d}%\t{d}.{d}%\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            name,
            metrics.trials,
            metrics.firstTryValidityPermille() / 10,
            metrics.firstTryValidityPermille() % 10,
            metrics.trajectoryMatchPermille() / 10,
            metrics.trajectoryMatchPermille() % 10,
            metrics.grammar_rejections,
            metrics.backend_errors,
            metrics.completion_tokens,
            metrics.generated_bytes,
            avg_latency,
        },
    );
}

fn writeLine(io: std.Io, out: std.Io.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}
