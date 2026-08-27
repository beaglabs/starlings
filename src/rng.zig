pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    /// SplitMix64: small, deterministic, and sufficient for reproducible
    /// scheduling experiments. This is not a cryptographic RNG.
    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    pub fn bounded(self: *Rng, upper: usize) usize {
        if (upper == 0) return 0;
        return @intCast(self.next() % @as(u64, @intCast(upper)));
    }
};
