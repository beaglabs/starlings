const std = @import("std");

pub const content_id = @import("core/content_id.zig");
pub const message = @import("core/message.zig");
pub const operator = @import("core/operator.zig");
pub const runtime = @import("core/runtime.zig");
pub const rng = @import("core/rng.zig");
pub const benchmark = @import("core/benchmark.zig");
pub const formal_population = @import("core/formal_population.zig");
pub const sdk = @import("sdk/root.zig");
pub const provenance = @import("provenance/provenance.zig");
pub const provenance_validation = @import("provenance/provenance_validation.zig");
pub const provenance_stress = @import("provenance/provenance_stress.zig");
pub const protocol_workflow = @import("protocol/protocol_workflow.zig");
pub const protocol_trace = @import("protocol/protocol_trace.zig");
pub const protocol_cfg = @import("protocol/protocol_cfg.zig");
pub const protocol_cfg_stress = @import("protocol/protocol_cfg_stress.zig");
pub const protocol_model_eval = @import("protocol/protocol_model_eval.zig");
pub const protocol_model_record = @import("protocol/protocol_model_record.zig");
pub const protocol_model_summary = @import("protocol/protocol_model_summary.zig");

test {
    _ = content_id;
    _ = benchmark;
    _ = formal_population;
    _ = sdk;
    _ = provenance;
    _ = provenance_validation;
    _ = provenance_stress;
    _ = protocol_workflow;
    _ = protocol_trace;
    _ = protocol_cfg;
    _ = protocol_cfg_stress;
    _ = protocol_model_eval;
    _ = protocol_model_record;
    _ = protocol_model_summary;
}

pub const root_tests = @import("tests/root_runtime.zig");

test {
    _ = root_tests;
}
