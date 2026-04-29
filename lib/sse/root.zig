//! Server-Sent Events (text/event-stream) framer.
//!
//! Implements the WHATWG event-stream parsing rules used by HTML EventSource:
//!
//!   * `data: <text>` lines accumulate into the current event's data buffer
//!     (one `\n` between consecutive `data:` lines).
//!   * `event: <name>` sets the event name for the next dispatch.
//!   * `id: <text>` sets the last-event-id for the next dispatch.
//!   * `retry: <ms>` records a reconnect hint.
//!   * `: <text>` is a comment and is ignored.
//!   * A blank line (CR, LF, or CRLF) dispatches the accumulated event.
//!
//! Parsing is byte-by-byte and incremental: callers feed bytes via `feed` and
//! pull whole events out via `nextEvent` or by registering a callback via
//! `setOnEvent`. Both `\r\n` and `\n` and bare `\r` line endings are accepted.
const std = @import("std");

pub const Event = struct {
    /// Event type. Empty string indicates the default (`message`) type.
    event: []const u8 = &.{},
    /// Optional last-event-id.
    id: []const u8 = &.{},
    /// Concatenated `data:` lines, joined by single `\n`. Empty events are
    /// skipped — they are valid in the spec but carry no payload.
    data: []const u8 = &.{},
    /// Optional reconnect hint, in milliseconds.
    retry: ?u64 = null,

    /// Free everything. Used by the parser only when handing ownership to a
    /// caller via `nextEvent`.
    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.event);
        allocator.free(self.id);
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Streaming parser. Not thread-safe; one parser per connection.
pub const Parser = struct {
    allocator: std.mem.Allocator,

    // Per-event accumulators (cleared on dispatch).
    event_buf: std.ArrayList(u8) = .empty,
    id_buf: std.ArrayList(u8) = .empty,
    data_buf: std.ArrayList(u8) = .empty,
    retry: ?u64 = null,

    // Inbound line buffer. Bytes accumulate here until we see a line
    // terminator, then we process them as a single line.
    line_buf: std.ArrayList(u8) = .empty,

    // CRLF state: when we see a `\r` we need to swallow a following `\n`.
    expect_lf: bool = false,

    // Dispatched events waiting for the caller.
    pending: std.ArrayList(Event) = .empty,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        self.event_buf.deinit(self.allocator);
        self.id_buf.deinit(self.allocator);
        self.data_buf.deinit(self.allocator);
        self.line_buf.deinit(self.allocator);
        for (self.pending.items) |*ev| ev.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    /// Feed bytes to the parser. May produce zero or more dispatched events
    /// reachable via `nextEvent`.
    pub fn feed(self: *Parser, bytes: []const u8) !void {
        for (bytes) |b| try self.feedByte(b);
    }

    /// Pull the next dispatched event, or null if none are pending. The
    /// caller owns the returned event and must `deinit` it.
    pub fn nextEvent(self: *Parser) ?Event {
        if (self.pending.items.len == 0) return null;
        return self.pending.orderedRemove(0);
    }

    fn feedByte(self: *Parser, b: u8) !void {
        if (self.expect_lf) {
            self.expect_lf = false;
            if (b == '\n') return; // swallow the LF half of CRLF
        }

        switch (b) {
            '\r' => {
                self.expect_lf = true;
                try self.processLine();
            },
            '\n' => try self.processLine(),
            else => try self.line_buf.append(self.allocator, b),
        }
    }

    fn processLine(self: *Parser) !void {
        const line = self.line_buf.items;
        defer self.line_buf.clearRetainingCapacity();

        if (line.len == 0) {
            try self.dispatch();
            return;
        }
        if (line[0] == ':') return; // comment

        // Split on the first ':' separator.
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field: []const u8 = if (colon) |c| line[0..c] else line;
        var value: []const u8 = if (colon) |c| line[c + 1 ..] else &.{};
        // Per spec: a single leading SPACE is stripped from the value.
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            self.event_buf.clearRetainingCapacity();
            try self.event_buf.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (self.data_buf.items.len > 0) try self.data_buf.append(self.allocator, '\n');
            try self.data_buf.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "id")) {
            self.id_buf.clearRetainingCapacity();
            try self.id_buf.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry = std.fmt.parseInt(u64, value, 10) catch self.retry;
        }
        // Unknown field: ignore per spec.
    }

    fn dispatch(self: *Parser) !void {
        if (self.data_buf.items.len == 0 and
            self.event_buf.items.len == 0 and
            self.id_buf.items.len == 0)
        {
            return; // nothing to dispatch
        }
        if (self.data_buf.items.len == 0) {
            // Empty event payload — clear accumulators but don't dispatch.
            self.event_buf.clearRetainingCapacity();
            self.id_buf.clearRetainingCapacity();
            return;
        }

        const event_owned = try self.event_buf.toOwnedSlice(self.allocator);
        const id_owned = try self.id_buf.toOwnedSlice(self.allocator);
        const data_owned = try self.data_buf.toOwnedSlice(self.allocator);

        try self.pending.append(self.allocator, .{
            .event = event_owned,
            .id = id_owned,
            .data = data_owned,
            .retry = self.retry,
        });
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "single event lf-terminated" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("data: hello\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("hello", ev.data);
    try testing.expectEqualStrings("", ev.event);
    try testing.expect(p.nextEvent() == null);
}

test "multi-line data joined with newlines" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("data: line1\ndata: line2\ndata: line3\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("line1\nline2\nline3", ev.data);
}

test "named event with id" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("event: status\nid: 42\ndata: payload\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("status", ev.event);
    try testing.expectEqualStrings("42", ev.id);
    try testing.expectEqualStrings("payload", ev.data);
}

test "comment is ignored" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed(": heartbeat\ndata: ok\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("ok", ev.data);
}

test "crlf line endings" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("data: one\r\ndata: two\r\n\r\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("one\ntwo", ev.data);
}

test "bare cr line endings" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("data: one\rdata: two\r\r");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("one\ntwo", ev.data);
}

test "value without leading space" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("data:no-space\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("no-space", ev.data);
}

test "field without colon is whole-line key" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    // `data` with empty value is allowed.
    try p.feed("data\n\n");
    // No data → no dispatch (data_buf empty).
    try testing.expect(p.nextEvent() == null);
    try p.feed("data: something\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("something", ev.data);
}

test "multiple events in one feed" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("data: a\n\ndata: b\n\ndata: c\n\n");

    var e1 = p.nextEvent().?;
    defer e1.deinit(a);
    try testing.expectEqualStrings("a", e1.data);

    var e2 = p.nextEvent().?;
    defer e2.deinit(a);
    try testing.expectEqualStrings("b", e2.data);

    var e3 = p.nextEvent().?;
    defer e3.deinit(a);
    try testing.expectEqualStrings("c", e3.data);

    try testing.expect(p.nextEvent() == null);
}

test "split feeds across boundaries" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("dat");
    try p.feed("a: hel");
    try p.feed("lo\n");
    try p.feed("\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqualStrings("hello", ev.data);
}

test "retry field parsed" {
    const a = testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    try p.feed("retry: 5000\ndata: x\n\n");
    var ev = p.nextEvent().?;
    defer ev.deinit(a);
    try testing.expectEqual(@as(?u64, 5000), ev.retry);
}
