const std = @import("std");
const a2a = @import("a2a");

pub fn main() !void {
    std.debug.print("hello from a2a v{s}\n", .{a2a.VERSION});
}
