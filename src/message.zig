const content_id = @import("content_id.zig");

pub const OperatorId = u32;
pub const ContentId = content_id.ContentId;

pub const Kind = enum(u8) {
    observe,
    query,
    claim,
    evidence,
    propose,
    accept,
    reject,
    challenge,
    retract,
    delegate,
};

pub const Message = struct {
    sender: OperatorId,
    recipient: OperatorId,
    kind: Kind,
    payload: u64 = 0,
    causal_ref: ?ContentId = null,
    logical_clock: u64 = 0,
};
