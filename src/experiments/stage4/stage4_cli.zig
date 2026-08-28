const std = @import("std");
const experiment = @import("stage4_population_experiment.zig");
const formal = @import("../../core/formal_population.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try usage(io);
        std.process.exit(2);
    }

    if (std.mem.eql(u8, args[1], "validate")) {
        try validate(io);
        return;
    }

    if (std.mem.eql(u8, args[1], "simulate")) {
        const environment_seed = if (args.len >= 3)
            try std.fmt.parseInt(u64, args[2], 10)
        else
            0;
        const max_rounds = if (args.len >= 4)
            try std.fmt.parseInt(u32, args[3], 10)
        else
            8;

        try simulate(io, environment_seed, max_rounds);
        return;
    }

    try usage(io);
    std.process.exit(2);
}

fn validate(io: std.Io) !void {
    const summary = try experiment.validateRotations(8);
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Stage 4 formal population validation\n", .{});
    try writeLine(io, out, "runs: {d}\n", .{summary.runs});
    try writeLine(io, out, "successes: {d}\n", .{summary.successes});
    try writeLine(
        io,
        out,
        "success_rate: {d}.{d}%\n",
        .{
            summary.successRatePermille() / 10,
            summary.successRatePermille() % 10,
        },
    );
    try writeLine(io, out, "rounds: {d}\n", .{summary.total_rounds});
    try writeLine(io, out, "communication_cost: {d}\n", .{summary.total_communication});
    try writeLine(io, out, "computation_cost: {d}\n", .{summary.total_computation});
    try writeLine(io, out, "violations: {d}\n", .{summary.total_violations});

    if (summary.successes != summary.runs or summary.total_violations != 0) {
        std.process.exit(1);
    }
}

fn simulate(io: std.Io, environment_seed: u64, max_rounds: u32) !void {
    const result = try experiment.runEnvironment(
        environment_seed,
        .rotating_claim,
        max_rounds,
    );
    const out = std.Io.File.stdout();

    try writeLine(io, out, "Stage 4 population simulation\n", .{});
    try writeLine(io, out, "environment_seed: {d}\n", .{environment_seed});
    try writeLine(io, out, "outcome: {s}\n", .{outcomeName(result.simulation.outcome)});
    try writeLine(io, out, "rounds: {d}\n", .{result.simulation.rounds});
    try writeLine(io, out, "policy_calls: {d}\n", .{result.simulation.policy_calls});
    try writeLine(io, out, "actions_proposed: {d}\n", .{result.simulation.actions_proposed});
    try writeLine(io, out, "rejected_actions: {d}\n", .{result.simulation.rejected_actions});
    try writeLine(io, out, "communication_cost: {d}\n", .{result.simulation.cost.communication});
    try writeLine(io, out, "computation_cost: {d}\n", .{result.simulation.cost.computation});
    try writeLine(io, out, "violations: {d}\n", .{result.simulation.cost.violations});

    try out.writeStreamingAll(io, "final_states:");
    for (result.final_states) |state| {
        try writeLine(io, out, " {d}", .{state});
    }
    try out.writeStreamingAll(io, "\n");

    if (result.simulation.outcome != .success) std.process.exit(1);
}

fn outcomeName(outcome: formal.Outcome) []const u8 {
    return switch (outcome) {
        .running => "running",
        .success => "success",
        .failure => "failure",
        .exhausted => "exhausted",
    };
}

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage:\n" ++
            "  zig run src/stage4_cli.zig -- validate\n" ++
            "  zig run src/stage4_cli.zig -- simulate [environment_seed] [max_rounds]\n",
    );
}

fn writeLine(io: std.Io, out: std.Io.File, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try out.writeStreamingAll(io, line);
}

test "outcome names remain stable for CLI output" {
    try std.testing.expectEqualStrings("success", outcomeName(.success));
    try std.testing.expectEqualStrings("exhausted", outcomeName(.exhausted));
}
