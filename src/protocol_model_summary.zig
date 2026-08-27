const std = @import("std");
const protocol_cfg = @import("protocol_cfg.zig");
const protocol_model_eval = @import("protocol_model_eval.zig");
const protocol_workflow = @import("protocol_workflow.zig");

pub const backend_error_sentinel = "__BACKEND_ERROR__";
pub const max_completion_bytes: usize = 4096;
const workflow_count: usize = @typeInfo(protocol_workflow.Workflow).@"enum".fields.len;

pub const WorkflowMetrics = struct {
    typed: protocol_model_eval.ModeMetrics = .{},
    constrained: protocol_model_eval.ModeMetrics = .{},
};

pub const Summary = struct {
    overall: protocol_model_eval.Experiment = .{},
    by_workflow: [workflow_count]WorkflowMetrics = [_]WorkflowMetrics{.{}} ** workflow_count,
    records: usize = 0,
    malformed_records: usize = 0,

    pub fn balanced(self: Summary) bool {
        if (self.overall.typed.trials != self.overall.constrained.trials) return false;
        for (self.by_workflow) |metrics| {
            if (metrics.typed.trials != metrics.constrained.trials) return false;
        }
        return true;
    }
};

const RawRecord = struct {
    workflow: protocol_workflow.Workflow,
    seed: u64,
    mode: protocol_model_eval.DecodeMode,
    attempt: usize,
    completion_tokens: usize,
    latency_us: u64,
    escaped_completion: []const u8,
};

pub fn summarizeTsv(tsv: []const u8) Summary {
    var result = Summary{};
    var lines = std.mem.splitScalar(u8, tsv, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0 or line[0] == '#') continue;

        const record = parseRawLine(line) catch {
            result.malformed_records += 1;
            continue;
        };
        result.records += 1;

        // Stage 3E.1 is deliberately the 1,200 base-generation experiment:
        // one attempt per workflow/seed/mode. Retry experiments remain Stage 3E.
        if (record.attempt != 0) {
            result.malformed_records += 1;
            continue;
        }

        var completion_buf: [max_completion_bytes]u8 = undefined;
        const completion = unescapeCompletion(record.escaped_completion, &completion_buf) catch {
            result.malformed_records += 1;
            continue;
        };

        const overall = metricsForMode(&result.overall, record.mode);
        const workflow_metrics = &result.by_workflow[@intFromEnum(record.workflow)];
        const per_workflow = workflowMetricsForMode(workflow_metrics, record.mode);

        applyRecord(overall, record, completion);
        applyRecord(per_workflow, record, completion);
    }

    return result;
}

fn applyRecord(
    metrics: *protocol_model_eval.ModeMetrics,
    record: RawRecord,
    completion: []const u8,
) void {
    metrics.trials += 1;
    metrics.attempts += 1;
    metrics.completion_tokens += record.completion_tokens;
    metrics.latency_us +%= record.latency_us;

    if (std.mem.eql(u8, completion, backend_error_sentinel)) {
        metrics.backend_errors += 1;
        return;
    }

    metrics.generated_bytes += completion.len;

    const sample = protocol_model_eval.parseCompletion(completion) catch {
        metrics.grammar_rejections += 1;
        return;
    };

    _ = protocol_cfg.parseKinds(sample.kinds[0..sample.len]) catch {
        metrics.grammar_rejections += 1;
        return;
    };

    metrics.first_try_valid += 1;
    metrics.eventually_valid += 1;
    if (protocol_model_eval.taskMatches(record.workflow, sample.kinds[0..sample.len])) {
        metrics.task_successes += 1;
    }
}

fn metricsForMode(
    experiment: *protocol_model_eval.Experiment,
    mode: protocol_model_eval.DecodeMode,
) *protocol_model_eval.ModeMetrics {
    return switch (mode) {
        .typed_unconstrained => &experiment.typed,
        .cfg_constrained => &experiment.constrained,
    };
}

fn workflowMetricsForMode(
    metrics: *WorkflowMetrics,
    mode: protocol_model_eval.DecodeMode,
) *protocol_model_eval.ModeMetrics {
    return switch (mode) {
        .typed_unconstrained => &metrics.typed,
        .cfg_constrained => &metrics.constrained,
    };
}

fn parseRawLine(line: []const u8) !RawRecord {
    var rest = line;
    const workflow_text = try nextField(&rest);
    const seed_text = try nextField(&rest);
    const mode_text = try nextField(&rest);
    const attempt_text = try nextField(&rest);
    const tokens_text = try nextField(&rest);
    const latency_text = try nextField(&rest);
    if (rest.len == 0) return error.InvalidRecord;

    return .{
        .workflow = try parseWorkflow(workflow_text),
        .seed = try std.fmt.parseInt(u64, seed_text, 10),
        .mode = try parseMode(mode_text),
        .attempt = try std.fmt.parseInt(usize, attempt_text, 10),
        .completion_tokens = try std.fmt.parseInt(usize, tokens_text, 10),
        .latency_us = try std.fmt.parseInt(u64, latency_text, 10),
        .escaped_completion = rest,
    };
}

fn nextField(rest: *[]const u8) ![]const u8 {
    const index = std.mem.indexOfScalar(u8, rest.*, '\t') orelse return error.InvalidRecord;
    const field = rest.*[0..index];
    if (field.len == 0) return error.InvalidRecord;
    rest.* = rest.*[index + 1 ..];
    return field;
}

fn parseWorkflow(text: []const u8) !protocol_workflow.Workflow {
    if (std.mem.eql(u8, text, "observe_claim")) return .observe_claim;
    if (std.mem.eql(u8, text, "query_evidence")) return .query_evidence;
    if (std.mem.eql(u8, text, "proposal_accept")) return .proposal_accept;
    if (std.mem.eql(u8, text, "proposal_reject")) return .proposal_reject;
    if (std.mem.eql(u8, text, "challenge_retract")) return .challenge_retract;
    if (std.mem.eql(u8, text, "delegation")) return .delegation;
    return error.UnknownWorkflow;
}

fn parseMode(text: []const u8) !protocol_model_eval.DecodeMode {
    if (std.mem.eql(u8, text, "typed_unconstrained")) return .typed_unconstrained;
    if (std.mem.eql(u8, text, "cfg_constrained")) return .cfg_constrained;
    return error.UnknownMode;
}

fn unescapeCompletion(input: []const u8, out: *[max_completion_bytes]u8) ![]const u8 {
    var src: usize = 0;
    var dst: usize = 0;

    while (src < input.len) {
        if (dst >= out.len) return error.CompletionTooLarge;

        if (input[src] != '\\') {
            out[dst] = input[src];
            dst += 1;
            src += 1;
            continue;
        }

        src += 1;
        if (src >= input.len) return error.InvalidEscape;

        out[dst] = switch (input[src]) {
            '\\' => '\\',
            't' => '\t',
            'r' => '\r',
            'n' => '\n',
            else => return error.InvalidEscape,
        };
        dst += 1;
        src += 1;
    }

    return out[0..dst];
}

test "raw summary counts invalid prose instead of dropping it" {
    const tsv =
        "observe_claim\t1\ttyped_unconstrained\t0\t5\t100\tI think OBSERVE CLAIM\n" ++
        "observe_claim\t1\tcfg_constrained\t0\t2\t90\tOBSERVE CLAIM\n";

    const summary = summarizeTsv(tsv);
    try std.testing.expectEqual(@as(usize, 2), summary.records);
    try std.testing.expectEqual(@as(usize, 0), summary.malformed_records);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.typed.grammar_rejections);
    try std.testing.expectEqual(@as(usize, 0), summary.overall.typed.first_try_valid);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.constrained.first_try_valid);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.constrained.task_successes);
}

test "raw summary preserves escaped whitespace and backend failures" {
    const tsv =
        "query_evidence\t2\ttyped_unconstrained\t0\t2\t120\tQUERY\\nEVIDENCE\n" ++
        "query_evidence\t2\tcfg_constrained\t0\t0\t0\t__BACKEND_ERROR__\n";

    const summary = summarizeTsv(tsv);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.typed.first_try_valid);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.typed.task_successes);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.constrained.backend_errors);
}

test "raw summary separates grammar validity from workflow correctness" {
    const tsv =
        "observe_claim\t3\ttyped_unconstrained\t0\t2\t100\tQUERY EVIDENCE\n" ++
        "observe_claim\t3\tcfg_constrained\t0\t2\t100\tOBSERVE CLAIM\n";

    const summary = summarizeTsv(tsv);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.typed.first_try_valid);
    try std.testing.expectEqual(@as(usize, 0), summary.overall.typed.task_successes);
    try std.testing.expectEqual(@as(usize, 1), summary.overall.constrained.task_successes);
    try std.testing.expect(summary.balanced());
}

test "raw summary rejects non-base attempts in stage 3e1" {
    const tsv =
        "observe_claim\t4\ttyped_unconstrained\t1\t2\t100\tOBSERVE CLAIM\n";

    const summary = summarizeTsv(tsv);
    try std.testing.expectEqual(@as(usize, 1), summary.records);
    try std.testing.expectEqual(@as(usize, 1), summary.malformed_records);
    try std.testing.expectEqual(@as(usize, 0), summary.overall.typed.trials);
}
