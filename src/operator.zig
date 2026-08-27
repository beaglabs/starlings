const message = @import("message.zig");

pub const Message = message.Message;
pub const OperatorId = message.OperatorId;

pub const Transition = struct {
    state: u64,
    emission: ?Message = null,
};

pub const TransitionFn = *const fn (state: u64, input: Message) Transition;

pub const Operator = struct {
    id: OperatorId,
    state: u64 = 0,
    transition: TransitionFn,

    pub fn receive(self: *Operator, input: Message) ?Message {
        const result = self.transition(self.state, input);
        self.state = result.state;
        return result.emission;
    }
};

/// Useful deterministic fixture: accumulate numeric message payloads.
pub fn accumulator(state: u64, input: Message) Transition {
    return .{ .state = state +% input.payload };
}

/// Set-union semantics for bitset-backed information experiments. Repeated
/// evidence is idempotent instead of corrupting state through numeric addition.
pub fn bitUnion(state: u64, input: Message) Transition {
    return .{ .state = state | input.payload };
}

/// Useful deterministic fixture: update state and relay the value back to sender.
pub fn echo(state: u64, input: Message) Transition {
    return .{
        .state = state +% 1,
        .emission = .{
            .sender = input.recipient,
            .recipient = input.sender,
            .kind = .evidence,
            .payload = input.payload,
            .causal_ref = input.causal_ref,
        },
    };
}
