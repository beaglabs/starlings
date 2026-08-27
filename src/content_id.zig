const std = @import("std");

pub const ContentId = [32]u8;
pub const zero: ContentId = [_]u8{0} ** 32;

pub fn eql(a: ContentId, b: ContentId) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn isZero(id: ContentId) bool {
    return eql(id, zero);
}

test "content ids compare by all 256 bits" {
    var a = zero;
    var b = zero;
    try std.testing.expect(eql(a, b));
    b[31] = 1;
    try std.testing.expect(!eql(a, b));
    try std.testing.expect(isZero(a));
    try std.testing.expect(!isZero(b));
}
