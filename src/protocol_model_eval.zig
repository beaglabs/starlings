const std = @import("std");
const message = @import("message.zig");
const protocol_cfg = @import("protocol_cfg.zig");
const protocol_workflow = @import("protocol_workflow.zig");

pub const max_events: usize = protocol_cfg.max_run_events;

pub const DecodeMode = enum {
    typed_unconstrained,
    cfg_constrained,
};

pub const grammar_ebnf =
    \\Session = Interaction, { Interaction };
    \\Interaction = ClaimBatch
    \\            | "OBSERVE", "CLAIM"
    \\            | "QUERY", "EVIDENCE"
    \\            | "PROPOSE", Decision
    \\            | "CHALLENGE", "RETRACT"
    \\            | "DELEGATE", "QUERY", "EVIDENCE", "EVIDENCE";
    \\ClaimBatch = "CLAIM", { "CLAIM" };
    \\Decision = "ACCEPT" | "REJECT";
;

pub const protocol_prompt_prefix =
    \\You communicate using only this protocol vocabulary:
    \\OBSERVE
    \\QUERY
    \\CLAIM
    \\EVIDENCE
    \\PROPOSE
    \\ACCEPT
    \\REJECT
    \\CHALLENGE
    \\RETRACT
    \\DELEGATE
    \\
    \\Valid interaction forms are:
    \\OBSERVE CLAIM
    \\QUERY EVIDENCE
    \\PROPOSE ACCEPT
    \\PROPOSE REJECT
    \\CHALLENGE RETRACT
    \\DELEGATE QUERY EVIDENCE EVIDENCE
    \\CLAIM may repeat one or more times as a claim batch.
    \\A session may contain one or more valid interactions.
    \\
    \\Return only the protocol terminal sequence required by the task.
    \\Do not include explanations, punctuation, prose, or code fences.
    \\
    \\Task:
;

pub const Request = struct {
    workflow: protocol_workflow.Workflow,
    seed: u64,
    mode: DecodeMode,
    attempt: usize,
    prompt: []const u8,
    grammar: ?[]const u8,
};

pub const Sample = struct {
    kinds: [max_events]message.Kind = undefined,
    len: usize = 0,
    generated_bytes: usize = 0,
    completion_tokens: usize = 0,
    latency_us: u64 = 0,

    pub fn fromKinds(kinds: []const message.Kind) !Sample {
        if (kinds.len == 0 or kinds.len > max_events) return error.InvalidCompletion;
        var sample = Sample{
            .len = kinds.len,
            .generated_bytes = kinds.len,
        };
        std.mem.copyForwards(message.Kind, sample.kinds[0..kinds.len], kinds);
        return sample;
    }
};

pub const GenerateFn = *const fn (context: ?*anyopaque, request: Request) anyerror!Sample;

pub const Backend = struct {
    context: ?*anyopaque = null,
    generate: GenerateFn,
};

pub const Config = struct {
    first_seed: u64 = 0,
    seeds: usize = 16,
    max_attempts: usize = 2,
};

pub const ModeMetrics = struct {
    trials: usize = 0,
    attempts: usize = 0,
    first_try_valid: usize = 0,
    eventually_valid: usize = 0,
    trajectory_matches: usize = 0,
    grammar_rejections: usize = 0,
    backend_errors: usize = 0,
    generated_bytes: usize = 0,
    completion_tokens: usize = 0,
    latency_us: u64 = 0,

    pub fn firstTryValidityPermille(self: ModeMetrics) usize {
        if (self.trials == 0) return 0;
        return (self.first_try_valid * 1000) / self.trials;
    }

    pub fn eventualValidityPermille(self: ModeMetrics) usize {
        if (self.trials == 0) return 0;
        return (self.eventually_valid * 1000) / self.trials;
    }

    pub fn trajectoryMatchPermille(self: ModeMetrics) usize {
        if (self.trials == 0) return 0;
        return (self.trajectory_matches * 1000) / self.trials;
    }

    pub fn averageAttemptsPermille(self: ModeMetrics) usize {
        if (self.trials == 0) return 0;
        return (self.attempts * 1000) / self.trials;
    }
};

pub const Experiment = struct {
    typed: ModeMetrics = .{},
    constrained: ModeMetrics = .{},

    pub fn validityDeltaPermille(self: Experiment) i64 {
        return @as(i64, @intCast(self.constrained.firstTryValidityPermille())) -
            @as(i64, @intCast(self.typed.firstTryValidityPermille()));
    }

    pub fn trajectoryMatchDeltaPermille(self: Experiment) i64 {
        return @as(i64, @intCast(self.constrained.trajectoryMatchPermille())) -
            @as(i64, @intCast(self.typed.trajectoryMatchPermille()));
    }

    pub fn attemptsDeltaPermille(self: Experiment) i64 {
        return @as(i64, @intCast(self.typed.averageAttemptsPermille())) -
            @as(i64, @intCast(self.constrained.averageAttemptsPermille()));
    }
};

pub fn runExperiment(backend: Backend, config: Config) !Experiment {
    if (config.seeds == 0 or config.max_attempts == 0) return error.InvalidConfig;

    var result = Experiment{};
    var seed_offset: usize = 0;
    while (seed_offset < config.seeds) : (seed_offset += 1) {
        const seed = config.first_seed + seed_offset;

        inline for (.{
            protocol_workflow.Workflow.observe_claim,
            protocol_workflow.Workflow.query_evidence,
            protocol_workflow.Workflow.proposal_accept,
            protocol_workflow.Workflow.proposal_reject,
            protocol_workflow.Workflow.challenge_retract,
            protocol_workflow.Workflow.delegation,
        }) |workflow| {
            inline for (.{ DecodeMode.typed_unconstrained, DecodeMode.cfg_constrained }) |mode| {
                const metrics = metricsForMode(&result, mode);
                try runTrial(backend, config, workflow, seed, mode, metrics);
            }
        }
    }

    return result;
}

fn runTrial(
    backend: Backend,
    config: Config,
    workflow: protocol_workflow.Workflow,
    seed: u64,
    mode: DecodeMode,
    metrics: *ModeMetrics,
) !void {
    metrics.trials += 1;
    var attempt: usize = 0;
    while (attempt < config.max_attempts) : (attempt += 1) {
        metrics.attempts += 1;

        const request = Request{
            .workflow = workflow,
            .seed = seed,
            .mode = mode,
            .attempt = attempt,
            .prompt = taskPrompt(workflow),
            .grammar = if (mode == .cfg_constrained) grammar_ebnf else null,
        };

        const sample = backend.generate(backend.context, request) catch {
            metrics.backend_errors += 1;
            continue;
        };
        if (sample.len == 0 or sample.len > max_events) {
            metrics.grammar_rejections += 1;
            continue;
        }

        metrics.generated_bytes += sample.generated_bytes;
        metrics.completion_tokens += sample.completion_tokens;
        metrics.latency_us +%= sample.latency_us;

        _ = protocol_cfg.parseKinds(sample.kinds[0..sample.len]) catch {
            metrics.grammar_rejections += 1;
            continue;
        };

        if (attempt == 0) metrics.first_try_valid += 1;
        metrics.eventually_valid += 1;
        if (trajectoryMatches(workflow, sample.kinds[0..sample.len])) {
            metrics.trajectory_matches += 1;
        }
        return;
    }
}

fn metricsForMode(result: *Experiment, mode: DecodeMode) *ModeMetrics {
    return switch (mode) {
        .typed_unconstrained => &result.typed,
        .cfg_constrained => &result.constrained,
    };
}

pub fn trajectoryMatches(workflow: protocol_workflow.Workflow, kinds: []const message.Kind) bool {
    return std.mem.eql(message.Kind, kinds, expectedKinds(workflow));
}

pub fn expectedKinds(workflow: protocol_workflow.Workflow) []const message.Kind {
    return switch (workflow) {
        .observe_claim => &.{ .observe, .claim },
        .query_evidence => &.{ .query, .evidence },
        .proposal_accept => &.{ .propose, .accept },
        .proposal_reject => &.{ .propose, .reject },
        .challenge_retract => &.{ .challenge, .retract },
        .delegation => &.{ .delegate, .query, .evidence, .evidence },
    };
}

pub fn taskPrompt(workflow: protocol_workflow.Workflow) []const u8 {
    return switch (workflow) {
        .observe_claim =>
        protocol_prompt_prefix ++
            "A coordinator gives an observation to an analyst; the analyst must state the resulting claim.",
        .query_evidence =>
        protocol_prompt_prefix ++
            "A coordinator requests a known fact from a worker; the worker must return supporting evidence.",
        .proposal_accept =>
        protocol_prompt_prefix ++
            "A coordinator proposes an allowed action; the evaluator must accept it.",
        .proposal_reject =>
        protocol_prompt_prefix ++
            "A coordinator proposes an action outside the allowed set; the evaluator must reject it.",
        .challenge_retract =>
        protocol_prompt_prefix ++
            "A coordinator challenges an active claim; the claimant must retract the challenged claim.",
        .delegation =>
        protocol_prompt_prefix ++
            "A coordinator delegates an information request to a worker; the worker queries a specialist, receives evidence, and forwards evidence to the coordinator.",
    };
}

pub fn parseCompletion(completion: []const u8) !Sample {
    if (completion.len == 0) return error.InvalidCompletion;

    var sample = Sample{ .generated_bytes = completion.len };
    var tokens = std.mem.tokenizeAny(u8, completion, " \t\r\n,;[]()");
    while (tokens.next()) |token| {
        if (sample.len >= max_events) return error.InvalidCompletion;
        sample.kinds[sample.len] = try parseKind(token);
        sample.len += 1;
    }
    if (sample.len == 0) return error.InvalidCompletion;
    return sample;
}

fn parseKind(token: []const u8) !message.Kind {
    if (std.ascii.eqlIgnoreCase(token, "OBSERVE")) return .observe;
    if (std.ascii.eqlIgnoreCase(token, "QUERY")) return .query;
    if (std.ascii.eqlIgnoreCase(token, "CLAIM")) return .claim;
    if (std.ascii.eqlIgnoreCase(token, "EVIDENCE")) return .evidence;
    if (std.ascii.eqlIgnoreCase(token, "PROPOSE")) return .propose;
    if (std.ascii.eqlIgnoreCase(token, "ACCEPT")) return .accept;
    if (std.ascii.eqlIgnoreCase(token, "REJECT")) return .reject;
    if (std.ascii.eqlIgnoreCase(token, "CHALLENGE")) return .challenge;
    if (std.ascii.eqlIgnoreCase(token, "RETRACT")) return .retract;
    if (std.ascii.eqlIgnoreCase(token, "DELEGATE")) return .delegate;
    return error.UnknownTerminal;
}

pub const RecordedSample = struct {
    workflow: protocol_workflow.Workflow,
    seed: u64,
    mode: DecodeMode,
    attempt: usize,
    sample: Sample,
};

pub const RecordedBackend = struct {
    samples: []const RecordedSample,

    pub fn backend(self: *RecordedBackend) Backend {
        return .{ .context = self, .generate = generateRecorded };
    }
};

fn generateRecorded(context: ?*anyopaque, request: Request) !Sample {
    const backend: *RecordedBackend = @ptrCast(@alignCast(context orelse return error.MissingContext));
    for (backend.samples) |recorded| {
        if (recorded.workflow == request.workflow and
            recorded.seed == request.seed and
            recorded.mode == request.mode and
            recorded.attempt == request.attempt)
        {
            return recorded.sample;
        }
    }
    return error.MissingRecordedSample;
}

fn noisyFixtureGenerate(_: ?*anyopaque, request: Request) !Sample {
    if (request.mode == .typed_unconstrained and request.attempt == 0 and request.seed % 2 == 0) {
        var invalid = try Sample.fromKinds(&.{.accept});
        invalid.generated_bytes = 6;
        invalid.completion_tokens = 1;
        invalid.latency_us = 100;
        return invalid;
    }

    var sample = try Sample.fromKinds(expectedKinds(request.workflow));
    sample.generated_bytes = sample.len * 8;
    sample.completion_tokens = sample.len;
    sample.latency_us = 100;
    return sample;
}

fn wrongButValidFixtureGenerate(_: ?*anyopaque, request: Request) !Sample {
    _ = request;
    return Sample.fromKinds(&.{ .query, .evidence });
}

test "shared model prompt exposes complete protocol to both decoding modes" {
    const prompt = taskPrompt(.delegation);
    try std.testing.expect(std.mem.startsWith(u8, prompt, protocol_prompt_prefix));

    inline for (.{
        "OBSERVE",
        "QUERY",
        "CLAIM",
        "EVIDENCE",
        "PROPOSE",
        "ACCEPT",
        "REJECT",
        "CHALLENGE",
        "RETRACT",
        "DELEGATE",
    }) |terminal| {
        try std.testing.expect(std.mem.indexOf(u8, prompt, terminal) != null);
    }

    inline for (.{
        "OBSERVE CLAIM",
        "QUERY EVIDENCE",
        "PROPOSE ACCEPT",
        "PROPOSE REJECT",
        "CHALLENGE RETRACT",
        "DELEGATE QUERY EVIDENCE EVIDENCE",
    }) |interaction| {
        try std.testing.expect(std.mem.indexOf(u8, prompt, interaction) != null);
    }
}

test "all workflow prompts share the identical protocol specification" {
    inline for (.{
        protocol_workflow.Workflow.observe_claim,
        protocol_workflow.Workflow.query_evidence,
        protocol_workflow.Workflow.proposal_accept,
        protocol_workflow.Workflow.proposal_reject,
        protocol_workflow.Workflow.challenge_retract,
        protocol_workflow.Workflow.delegation,
    }) |workflow| {
        try std.testing.expect(std.mem.startsWith(u8, taskPrompt(workflow), protocol_prompt_prefix));
    }
}

test "completion parser accepts protocol terminals and rejects prose" {
    const parsed = try parseCompletion("QUERY EVIDENCE");
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(message.Kind.query, parsed.kinds[0]);
    try std.testing.expectEqual(message.Kind.evidence, parsed.kinds[1]);

    try std.testing.expectError(error.UnknownTerminal, parseCompletion("I think QUERY EVIDENCE"));
}

test "same-task A/B evaluator measures validity and retry advantage from constraints" {
    const backend = Backend{ .generate = noisyFixtureGenerate };
    const result = try runExperiment(backend, .{ .first_seed = 10, .seeds = 8, .max_attempts = 2 });

    try std.testing.expectEqual(result.typed.trials, result.constrained.trials);
    try std.testing.expect(result.constrained.first_try_valid > result.typed.first_try_valid);
    try std.testing.expectEqual(result.typed.trials, result.typed.eventually_valid);
    try std.testing.expectEqual(result.constrained.trials, result.constrained.eventually_valid);
    try std.testing.expectEqual(result.typed.trials, result.typed.trajectory_matches);
    try std.testing.expectEqual(result.constrained.trials, result.constrained.trajectory_matches);
    try std.testing.expect(result.validityDeltaPermille() > 0);
    try std.testing.expect(result.attemptsDeltaPermille() > 0);
}

test "structurally valid wrong workflow is not counted as trajectory match" {
    const backend = Backend{ .generate = wrongButValidFixtureGenerate };
    const result = try runExperiment(backend, .{ .first_seed = 1, .seeds = 1, .max_attempts = 1 });

    try std.testing.expectEqual(result.typed.trials, result.typed.eventually_valid);
    try std.testing.expect(result.typed.trajectory_matches < result.typed.eventually_valid);
    try std.testing.expect(result.constrained.trajectory_matches < result.constrained.eventually_valid);
}

test "recorded backend replays exact model trials deterministically" {
    const typed = try Sample.fromKinds(&.{ .observe, .claim });
    const constrained = try Sample.fromKinds(&.{ .observe, .claim });
    const records = [_]RecordedSample{
        .{ .workflow = .observe_claim, .seed = 42, .mode = .typed_unconstrained, .attempt = 0, .sample = typed },
        .{ .workflow = .observe_claim, .seed = 42, .mode = .cfg_constrained, .attempt = 0, .sample = constrained },
    };
    var recorded = RecordedBackend{ .samples = &records };
    const backend = recorded.backend();

    const typed_out = try backend.generate(backend.context, .{
        .workflow = .observe_claim,
        .seed = 42,
        .mode = .typed_unconstrained,
        .attempt = 0,
        .prompt = taskPrompt(.observe_claim),
        .grammar = null,
    });
    const constrained_out = try backend.generate(backend.context, .{
        .workflow = .observe_claim,
        .seed = 42,
        .mode = .cfg_constrained,
        .attempt = 0,
        .prompt = taskPrompt(.observe_claim),
        .grammar = grammar_ebnf,
    });

    try std.testing.expectEqualDeep(typed, typed_out);
    try std.testing.expectEqualDeep(constrained, constrained_out);
}
