const message = @import("message.zig");
const operator = @import("operator.zig");
const rng_mod = @import("rng.zig");

pub const Message = message.Message;
pub const Operator = operator.Operator;

pub const Error = error{
    OperatorCapacityExceeded,
    QueueCapacityExceeded,
    TraceCapacityExceeded,
    DuplicateOperator,
    UnknownRecipient,
};

pub const TraceEvent = struct {
    sequence: u64,
    message: Message,
};

pub fn Runtime(comptime max_operators: usize, comptime max_queue: usize, comptime max_trace: usize) type {
    return struct {
        const Self = @This();

        operators: [max_operators]Operator = undefined,
        operator_count: usize = 0,
        queue: [max_queue]Message = undefined,
        queue_len: usize = 0,
        trace: [max_trace]TraceEvent = undefined,
        trace_len: usize = 0,
        logical_clock: u64 = 0,
        rng: rng_mod.Rng,

        pub fn init(seed: u64) Self {
            return .{ .rng = rng_mod.Rng.init(seed) };
        }

        pub fn addOperator(self: *Self, op: Operator) Error!void {
            if (self.findOperator(op.id) != null) return error.DuplicateOperator;
            if (self.operator_count >= max_operators) return error.OperatorCapacityExceeded;
            self.operators[self.operator_count] = op;
            self.operator_count += 1;
        }

        pub fn enqueue(self: *Self, msg: Message) Error!void {
            if (self.queue_len >= max_queue) return error.QueueCapacityExceeded;
            self.queue[self.queue_len] = msg;
            self.queue_len += 1;
        }

        pub fn step(self: *Self) Error!bool {
            if (self.queue_len == 0) return false;

            var msg = self.queue[0];
            var i: usize = 1;
            while (i < self.queue_len) : (i += 1) {
                self.queue[i - 1] = self.queue[i];
            }
            self.queue_len -= 1;

            const index = self.findOperator(msg.recipient) orelse return error.UnknownRecipient;
            self.logical_clock +%= 1;
            msg.logical_clock = self.logical_clock;

            if (self.trace_len >= max_trace) return error.TraceCapacityExceeded;
            self.trace[self.trace_len] = .{ .sequence = self.logical_clock, .message = msg };
            self.trace_len += 1;

            if (self.operators[index].receive(msg)) |emission| {
                try self.enqueue(emission);
            }
            return true;
        }

        pub fn run(self: *Self) Error!void {
            while (try self.step()) {}
        }

        /// Exposes deterministic seeded entropy for experiments without tying the
        /// foundation to a particular scheduling policy.
        pub fn randomIndex(self: *Self, upper: usize) usize {
            return self.rng.bounded(upper);
        }

        pub fn findOperator(self: *const Self, id: message.OperatorId) ?usize {
            var i: usize = 0;
            while (i < self.operator_count) : (i += 1) {
                if (self.operators[i].id == id) return i;
            }
            return null;
        }
    };
}
