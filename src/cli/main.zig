const std = @import("std");
const a2a = @import("a2a");

pub fn main() !void {
    std.debug.print("a2a CLI \xe2\x80\x94 protocol v{s}\n", .{a2a.VERSION});
}
