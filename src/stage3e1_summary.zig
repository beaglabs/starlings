const std = @import("std");
const model_eval = @import("protocol_model_eval.zig");
const model_summary = @import("protocol_model_summary.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const path = args.next() orelse {
        try usage();
        std.process.exit(2);
    };
    if (args.next() != null) {
        try usage();
        std.process.exit(2);
    }

    const tsv = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
    defer allocator.free(tsv);

    const result = model_summary.summarizeTsv(tsv);
    var out = std.fs.File.stdout();

    try writeLine(&out, "Stage 3E.1 llama.cpp live-trial summary\n", .{});
    try writeLine(&out, "records: {d}\n", .{result.records});
    try writeLine(&out, "malformed_records: {d}\n", .{result.malformed_records});
    try writeLine(&out, "balanced_pairs: {s}\n\n", .{if (result.balanced()) "yes" else "no"});

    try writeHeader(&out);
    try writeMetrics(&out, "typed_unconstrained", result.overall.typed);
    try writeMetrics(&out, "cfg_constrained", result.overall.constrained);

    try writeLine(
        &out,
        "\ndeltas (constrained - typed): first_valid={d} permille, task_success={d} permille\n",
        .{ result.overall.validityDeltaPermille(), result.overall.taskSuccessDeltaPermille() },
    );

    const workflow_names = [_][]const u8{
        "observe_claim",
        "query_evidence",
        "proposal_accept",
        "proposal_reject",
        "challenge_retract",
        "delegation",
    };

    try writeLine(&out, "\nby workflow\n", .{});
    var i: usize = 0;
    while (i < workflow_names.len) : (i += 1) {
        try writeLine(&out, "\n{s}\n", .{workflow_names[i]});
        try writeHeader(&out);
        try writeMetrics(&out, "typed_unconstrained", result.by_workflow[i].typed);
        try writeMetrics(&out, "cfg_constrained", result.by_workflow[i].constrained);
    }

    if (result.malformed_records != 0 or !result.balanced()) {
        try writeLine(
            &out,
            "\nWARNING: malformed or unbalanced trial data; do not use this file for a promotion decision.\n",
            .{},
        );
        std.process.exit(2);
    }
}

fn usage() !void {
    var out = std.fs.File.stderr();
    try out.writeAll(
        "usage: zig run src/stage3e1_summary.zig -- <trials.tsv>\n",
    );
}

fn writeHeader(out: *std.fs.File) !void {
    try out.writeAll(
        "mode                 trials  first-valid  task-success  grammar-rej  backend-err  tokens  bytes  avg-latency-us\n",
    );
}

fn writeMetrics(out: *std.fs.File, name: []const u8, metrics: model_eval.ModeMetrics) !void {
    const avg_latency = if (metrics.trials == 0) 0 else metrics.latency_us / metrics.trials;
    try writeLine(
        out,
        "{s: <20} {d: >6}  {d: >4}.{d}%       {d: >4}.{d}%        {d: >6}       {d: >6}  {d: >6}  {d: >5}  {d: >14}\n",
        .{
            name,
            metrics.trials,
            metrics.firstTryValidityPermille() / 10,
            metrics.firstTryValidityPermille() % 10,
            metrics.taskSuccessPermille() / 10,
            metrics.taskSuccessPermille() % 10,
            metrics.grammar_rejections,
            metrics.backend_errors,
            metrics.completion_tokens,
            metrics.generated_bytes,
            avg_latency,
        },
    );
}

fn writeLine(out: *std.fs.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeAll(line);
}
