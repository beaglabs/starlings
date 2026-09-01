const std = @import("std");
const starlings = @import("starlings");

const initial_history_b64 = "W10="; // base64("[]")

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: starlings-harbor-bridge <pack-path>\n",
        );
        std.process.exit(2);
    }

    var population = try starlings.Population.load(
        io,
        init.gpa,
        init.arena.allocator(),
        args[1],
    );
    var agent = try starlings.Agent.init(
        io,
        init.gpa,
        init.arena.allocator(),
        &population,
        42,
        .{},
    );
    defer agent.deinit();

    var stdin_buffer: [256 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const reader = &stdin_reader.interface;
    const stdout = std.Io.File.stdout();

    var started = false;
    var last_action_count: usize = 0;

    while (try reader.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "QUIT")) return;

        if (std.mem.startsWith(u8, line, "START ")) {
            if (started) {
                try writeError(io, stdout, "duplicate-start");
                continue;
            }
            const task_b64 = line["START ".len..];
            _ = try agent.observeText("task.b64", task_b64, 1000);
            _ = try agent.observeText("history.b64", initial_history_b64, 1000);
            started = true;
            try driveAndRespond(io, stdout, &agent, &last_action_count);
            continue;
        }

        if (std.mem.startsWith(u8, line, "HISTORY ")) {
            if (!started) {
                try writeError(io, stdout, "history-before-start");
                continue;
            }
            const history_b64 = line["HISTORY ".len..];
            _ = try agent.observeText("history.b64", history_b64, 1000);
            try driveAndRespond(io, stdout, &agent, &last_action_count);
            continue;
        }

        try writeError(io, stdout, "unknown-command");
    }
}

fn driveAndRespond(
    io: std.Io,
    stdout: std.Io.File,
    agent: *starlings.Agent,
    last_action_count: *usize,
) !void {
    var activations: usize = 0;
    while (activations < 32) : (activations += 1) {
        if (try agent.step() == .idle) break;
    }
    if (activations == 32) {
        try writeError(io, stdout, "activation-budget");
        return;
    }

    if (agent.value("final.b64")) |value| {
        switch (value) {
            .text => |payload| {
                try writePayload(io, stdout, "FINAL ", payload);
                return;
            },
            else => return error.InvalidFinalValue,
        }
    }

    if (agent.explain("action.b64")) |explanation| {
        if (explanation.accepted_claims > last_action_count.*) {
            if (agent.value("action.b64")) |value| {
                switch (value) {
                    .text => |payload| {
                        last_action_count.* = explanation.accepted_claims;
                        try writePayload(io, stdout, "ACTION ", payload);
                        return;
                    },
                    else => return error.InvalidActionValue,
                }
            }
        }
    }

    try stdout.writeStreamingAll(io, "IDLE\n");
}

fn writePayload(
    io: std.Io,
    stdout: std.Io.File,
    prefix: []const u8,
    payload: []const u8,
) !void {
    try stdout.writeStreamingAll(io, prefix);
    try stdout.writeStreamingAll(io, payload);
    try stdout.writeStreamingAll(io, "\n");
}

fn writeError(io: std.Io, stdout: std.Io.File, message: []const u8) !void {
    try writePayload(io, stdout, "ERROR ", message);
}
