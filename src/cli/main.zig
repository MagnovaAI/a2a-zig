const std = @import("std");
const a2a = @import("a2a");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;
    try w.print("a2a CLI - protocol v{s}\n", .{a2a.VERSION});
    try w.flush();
}
