const std = @import("std");
const protocol_model_eval = @import("protocol_model_eval.zig");
const protocol_workflow = @import("protocol_workflow.zig");

/// Stage 3E recorded-trial interchange format:
///
/// workflow<TAB>seed<TAB>mode<TAB>attempt<TAB>completion_tokens<TAB>latency_us<TAB>completion
///
/// Example:
/// query_evidence\t42\tcfg_constrained\t0\t2\t1250\tQUERY EVIDENCE
///
/// Completion is the final field and may contain spaces. Tabs inside a model
/// completion are intentionally unsupported because the protocol completion
/// contract is terminal-only text.
pub fn parseLine(line: []const u8) !protocol_model_eval.RecordedSample {
    var rest = std.mem.trim(u8, line, " \r\n");
    const workflow_text = try nextField(&rest);
    const seed_text = try nextField(&rest);
    const mode_text = try nextField(&rest);
    const attempt_text = try nextField(&rest);
    const tokens_text = try nextField(&rest);
    const latency_text = try nextField(&rest);
    if (rest.len == 0) return error.InvalidRecord;

    var sample = try protocol_model_eval.parseCompletion(rest);
    sample.completion_tokens = try std.fmt.parseInt(usize, tokens_text, 10);
    sample.latency_us = try std.fmt.parseInt(u64, latency_text, 10);

    return .{
        .workflow = try parseWorkflow(workflow_text),
        .seed = try std.fmt.parseInt(u64, seed_text, 10),
        .mode = try parseMode(mode_text),
        .attempt = try std.fmt.parseInt(usize, attempt_text, 10),
        .sample = sample,
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

test "recorded trial line parses model metadata and terminal completion" {
    const record = try parseLine("query_evidence\t42\tcfg_constrained\t0\t2\t1250\tQUERY EVIDENCE");

    try std.testing.expectEqual(protocol_workflow.Workflow.query_evidence, record.workflow);
    try std.testing.expectEqual(@as(u64, 42), record.seed);
    try std.testing.expectEqual(protocol_model_eval.DecodeMode.cfg_constrained, record.mode);
    try std.testing.expectEqual(@as(usize, 0), record.attempt);
    try std.testing.expectEqual(@as(usize, 2), record.sample.completion_tokens);
    try std.testing.expectEqual(@as(u64, 1250), record.sample.latency_us);
    try std.testing.expectEqual(@as(usize, 2), record.sample.len);
}

test "recorded trial rejects prose completions" {
    try std.testing.expectError(
        error.UnknownTerminal,
        parseLine("observe_claim\t1\ttyped_unconstrained\t0\t4\t100\tI think OBSERVE CLAIM"),
    );
}
