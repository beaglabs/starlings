pub const OperatorId = u32;

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
    causal_ref: ?u64 = null,
    logical_clock: u64 = 0,
};
