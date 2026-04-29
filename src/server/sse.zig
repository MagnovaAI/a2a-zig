//! Server-side SSE writer.
//!
//! Drains a `StreamIterator` and writes each event as a Server-Sent
//! Events frame: `data: <json>\n\n`. The wire format matches what the
//! client-side `sse` library parses, and the JSON body is the canonical
//! ProtoJSON encoding of `StreamResponse`.
//!
//! `writeStream` is the worker run by `httpz.Response.startEventStream`.
//! It owns the iterator and the connection: it closes both when the
//! stream is drained or the connection drops.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");

const log = std.log.scoped(.a2a_server);

/// Minimum information a worker needs to push an event stream over an
/// already-handed-off socket.
pub const StreamSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    iterator: a2a.StreamIterator,

    pub fn deinit(self: *StreamSource) void {
        self.iterator.deinit();
        self.* = undefined;
    }
};

/// Drain `source.iterator` into the SSE wire format and ship each frame
/// over `stream`. Closes `source` and `stream` before returning.
///
/// Errors are logged and swallowed: the connection is best-effort and a
/// half-broken socket should not propagate further.
pub fn writeStream(source: *StreamSource, stream: std.Io.net.Stream) void {
    const io = source.io;
    defer {
        stream.close(io);
        source.iterator.deinit();
        const a = source.allocator;
        a.destroy(source);
    }

    while (true) {
        const next = source.iterator.next() catch |err| {
            log.warn("SSE: iterator returned error: {s}", .{@errorName(err)});
            writeError(io, stream, @errorName(err)) catch {};
            return;
        };
        var event = next orelse return;
        defer event.deinit();

        var arena = std.heap.ArenaAllocator.init(source.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const json = encodeEventToJson(aa, event) catch |err| {
            log.warn("SSE: failed to encode event: {s}", .{@errorName(err)});
            return;
        };

        writeFrame(io, stream, json) catch |err| {
            log.debug("SSE: write failed (likely client disconnect): {s}", .{@errorName(err)});
            return;
        };
    }
}

fn writeFrame(io: std.Io, stream: std.Io.net.Stream, payload: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll("data: ");
    try w.interface.writeAll(payload);
    try w.interface.writeAll("\n\n");
    try w.interface.flush();
}

fn writeError(io: std.Io, stream: std.Io.net.Stream, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll("event: error\ndata: ");
    try w.interface.writeAll(msg);
    try w.interface.writeAll("\n\n");
    try w.interface.flush();
}

fn encodeEventToJson(arena: std.mem.Allocator, event: a2a.StreamResponse) ![]const u8 {
    var pb_event = try pb.conv.streamResponseToProto(arena, event);
    defer pb_event.deinit(arena);
    return try pb_event.jsonEncode(.{}, .{}, arena);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encodeEventToJson produces canonical proto-json" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var status_event: a2a.StreamResponse = .{
        .status_update = .{
            .task_id = try a.dupe(u8, "t1"),
            .context_id = try a.dupe(u8, "c1"),
            .status = .{ .state = .working, .allocator = a },
            .allocator = a,
        },
    };
    defer status_event.deinit();

    const json = try encodeEventToJson(aa, status_event);
    try testing.expect(std.mem.indexOf(u8, json, "statusUpdate") != null);
}
