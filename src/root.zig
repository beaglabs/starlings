const std = @import("std");

pub const message = @import("message.zig");
pub const operator = @import("operator.zig");
pub const runtime = @import("runtime.zig");
pub const rng = @import("rng.zig");
pub const benchmark = @import("benchmark.zig");
pub const provenance = @import("provenance.zig");
pub const provenance_validation = @import("provenance_validation.zig");

test {
    _ = benchmark;
    _ = provenance;
    _ = provenance_validation;
}

test "messages route deterministically and update operator state" {
    const TestRuntime = runtime.Runtime(8, 32, 32);
    var rt = TestRuntime.init(42);

    try rt.addOperator(.{ .id = 1, .transition = operator.echo });
    try rt.addOperator(.{ .id = 2, .transition = operator.accumulator });

    try rt.enqueue(.{
        .sender = 2,
        .recipient = 1,
        .kind = .query,
        .payload = 7,
        .causal_ref = 99,
    });
    try rt.run();

    try std.testing.expectEqual(@as(u64, 1), rt.operators[0].state);
    try std.testing.expectEqual(@as(u64, 7), rt.operators[1].state);
    try std.testing.expectEqual(@as(usize, 2), rt.trace_len);
    try std.testing.expectEqual(@as(u64, 1), rt.trace[0].sequence);
    try std.testing.expectEqual(@as(u64, 2), rt.trace[1].sequence);
    try std.testing.expectEqual(message.Kind.evidence, rt.trace[1].message.kind);
    try std.testing.expectEqual(@as(?u64, 99), rt.trace[1].message.causal_ref);
}

test "same seed produces the same experimental entropy" {
    const TestRuntime = runtime.Runtime(1, 1, 1);
    var a = TestRuntime.init(0x5eed);
    var b = TestRuntime.init(0x5eed);

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(a.randomIndex(17), b.randomIndex(17));
    }
}

test "different seeds diverge" {
    const TestRuntime = runtime.Runtime(1, 1, 1);
    var a = TestRuntime.init(1);
    var b = TestRuntime.init(2);

    var different = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (a.randomIndex(1024) != b.randomIndex(1024)) different = true;
    }
    try std.testing.expect(different);
}

test "duplicate operators are rejected" {
    const TestRuntime = runtime.Runtime(2, 1, 1);
    var rt = TestRuntime.init(0);
    const op: operator.Operator = .{ .id = 7, .transition = operator.accumulator };
    try rt.addOperator(op);
    try std.testing.expectError(error.DuplicateOperator, rt.addOperator(op));
}

test "unknown recipients fail explicitly" {
    const TestRuntime = runtime.Runtime(1, 2, 2);
    var rt = TestRuntime.init(0);
    try rt.enqueue(.{ .sender = 1, .recipient = 999, .kind = .claim });
    try std.testing.expectError(error.UnknownRecipient, rt.step());
}
