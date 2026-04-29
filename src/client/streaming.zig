//! Shared streaming machinery for transports that consume `text/event-stream`
//! bodies and turn each event's `data` field into a `StreamResponse`.
//!
//! Two decode strategies are supported:
//!   * `.json_rpc` — `data` is a JSON-RPC envelope; the iterator extracts
//!     `result` and decodes that as a `pb.v1.StreamResponse`.
//!   * `.raw_stream_response` — `data` is a bare ProtoJSON `StreamResponse`.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");
const sse = @import("sse");
const transport_mod = @import("transport.zig");

pub const StreamIterator = transport_mod.StreamIterator;
pub const Transport = transport_mod.Transport;

const log = std.log.scoped(.a2a_client);

pub const DecodeMode = enum {
    /// SSE event data is a JSON-RPC envelope wrapping a `StreamResponse` in
    /// `result`. Used by `JsonRpcTransport`.
    json_rpc,
    /// SSE event data is a bare ProtoJSON `StreamResponse`. Used by
    /// `RestTransport`.
    raw_stream_response,
};

pub const Cursor = struct {
    allocator: std.mem.Allocator,
    /// Owning copy of the raw response bytes. Sliced by `pos` as we consume.
    bytes: []u8,
    pos: usize = 0,
    parser: sse.Parser,
    mode: DecodeMode,
    closed: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        bytes: []u8,
        mode: DecodeMode,
    ) !*Cursor {
        const self = try allocator.create(Cursor);
        self.* = .{
            .allocator = allocator,
            .bytes = bytes,
            .parser = sse.Parser.init(allocator),
            .mode = mode,
        };
        return self;
    }

    pub fn iterator(self: *Cursor) StreamIterator {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn next(self: *Cursor) StreamIterator.NextError!?a2a.StreamResponse {
        while (true) {
            if (self.parser.nextEvent()) |ev| {
                var ev_local = ev;
                defer ev_local.deinit(self.allocator);
                const decoded = self.decodeEvent(ev_local) catch |err| {
                    // The JSON-RPC stream-error path is an in-band signal,
                    // not a parse failure — leave it at debug. Real decode
                    // bugs (malformed bytes, missing fields) are surfaced at
                    // err level in the deeper helpers.
                    log.debug("stream cursor surfacing event error: {s}", .{@errorName(err)});
                    return StreamIterator.NextError.TransportError;
                };
                if (decoded) |sr| return sr;
                continue;
            }

            if (self.closed) return null;

            // Feed more bytes in fixed-size chunks so we never block in test
            // contexts where the body is already fully buffered.
            const chunk_size: usize = 4096;
            const remaining = self.bytes.len - self.pos;
            if (remaining == 0) {
                // Final flush: a stream may end without a trailing blank
                // line. Push a synthetic terminator so any half-built event
                // gets dispatched.
                self.parser.feed("\n\n") catch return StreamIterator.NextError.OutOfMemory;
                self.closed = true;
                continue;
            }
            const take = @min(chunk_size, remaining);
            self.parser.feed(self.bytes[self.pos .. self.pos + take]) catch return StreamIterator.NextError.OutOfMemory;
            self.pos += take;
        }
    }

    fn decodeEvent(self: *Cursor, ev: sse.Event) !?a2a.StreamResponse {
        if (ev.data.len == 0) return null;
        return switch (self.mode) {
            .json_rpc => try self.decodeJsonRpcEvent(ev.data),
            .raw_stream_response => try self.decodeRawStreamResponse(ev.data),
        };
    }

    fn decodeJsonRpcEvent(self: *Cursor, data: []const u8) !?a2a.StreamResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidPayload,
        };
        if (obj.get("error")) |e| switch (e) {
            .object => return error.JsonRpcStreamError,
            .null => {},
            else => {},
        };
        const result_v = obj.get("result") orelse return null;
        const result_bytes = try std.json.Stringify.valueAlloc(self.allocator, result_v, .{});
        defer self.allocator.free(result_bytes);
        return try decodeStreamResponseBytes(self.allocator, result_bytes);
    }

    fn decodeRawStreamResponse(self: *Cursor, data: []const u8) !?a2a.StreamResponse {
        return try decodeStreamResponseBytes(self.allocator, data);
    }

    fn deinit(self: *Cursor) void {
        self.parser.deinit();
        self.allocator.free(self.bytes);
        const a = self.allocator;
        a.destroy(self);
    }

    fn vtNext(ctx: *anyopaque) StreamIterator.NextError!?a2a.StreamResponse {
        const self: *Cursor = @ptrCast(@alignCast(ctx));
        return self.next();
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Cursor = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    const vtable: StreamIterator.VTable = .{
        .next = vtNext,
        .deinit = vtDeinit,
    };
};

fn decodeStreamResponseBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !a2a.StreamResponse {
    const parsed = try pb.v1.StreamResponse.jsonDecode(bytes, .{}, allocator);
    defer parsed.deinit();
    return try pb.conv.streamResponseFromProto(allocator, parsed.value);
}

// ---------------------------------------------------------------------------
// HTTP streaming reader
//
// Buffers the entire response body into memory before decoding. For most A2A
// streams (which produce a bounded number of update events) this is fine and
// vastly simpler than a true incremental reader. We can swap this for a
// streaming `Response.reader()` later without changing the cursor API.
// ---------------------------------------------------------------------------

pub const FetchOptions = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const FetchError = error{
    HttpRequestFailed,
    HttpStatusError,
    ResponseTooLarge,
    OutOfMemory,
};

/// Send `opts.method opts.url` with the given headers and optional body,
/// then drain the response body into a freshly-allocated slice owned by the
/// caller. Returns `error.HttpStatusError` on non-2xx responses.
pub fn fetchResponseBytes(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    opts: FetchOptions,
) FetchError![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = opts.url },
        .method = opts.method,
        .extra_headers = opts.headers,
        .payload = opts.payload,
        .response_writer = &body.writer,
        .keep_alive = false,
    }) catch |err| {
        log.err("streaming fetch failed: method={s} url={s} err={s}", .{
            @tagName(opts.method),
            opts.url,
            @errorName(err),
        });
        body.deinit();
        return FetchError.HttpRequestFailed;
    };

    const status = @intFromEnum(result.status);
    if (status < 200 or status >= 300) {
        log.err("streaming HTTP status: method={s} url={s} status={d}", .{
            @tagName(opts.method),
            opts.url,
            status,
        });
        body.deinit();
        return FetchError.HttpStatusError;
    }
    if (body.written().len > opts.max_bytes) {
        body.deinit();
        return FetchError.ResponseTooLarge;
    }
    return body.toOwnedSlice() catch FetchError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "json-rpc cursor decodes a status-update event" {
    const a = testing.allocator;
    const data =
        \\{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"t1","contextId":"c1","status":{"state":"TASK_STATE_WORKING"}}}}
    ;
    var sse_buf: std.array_list.Managed(u8) = .init(a);
    defer sse_buf.deinit();
    try sse_buf.appendSlice("data: ");
    try sse_buf.appendSlice(data);
    try sse_buf.appendSlice("\n\n");

    const owned = try a.dupe(u8, sse_buf.items);
    var cursor = try Cursor.create(a, owned, .json_rpc);
    var iter = cursor.iterator();
    defer iter.deinit();

    var ev = (try iter.next()).?;
    defer ev.deinit();
    try testing.expect(ev == .status_update);
    try testing.expectEqualStrings("t1", ev.status_update.task_id);

    try testing.expect((try iter.next()) == null);
}

test "raw cursor decodes multiple events split across chunks" {
    const a = testing.allocator;
    const ev1 =
        \\{"task":{"id":"t1","contextId":"c1","status":{"state":"TASK_STATE_SUBMITTED"}}}
    ;
    const ev2 =
        \\{"message":{"messageId":"m1","role":"ROLE_AGENT","parts":[{"text":"hi"}]}}
    ;
    var sse_buf: std.array_list.Managed(u8) = .init(a);
    defer sse_buf.deinit();
    try sse_buf.appendSlice("data: ");
    try sse_buf.appendSlice(ev1);
    try sse_buf.appendSlice("\n\ndata: ");
    try sse_buf.appendSlice(ev2);
    try sse_buf.appendSlice("\n\n");

    const owned = try a.dupe(u8, sse_buf.items);
    var cursor = try Cursor.create(a, owned, .raw_stream_response);
    var iter = cursor.iterator();
    defer iter.deinit();

    var first = (try iter.next()).?;
    defer first.deinit();
    try testing.expect(first == .task);

    var second = (try iter.next()).?;
    defer second.deinit();
    try testing.expect(second == .message);

    try testing.expect((try iter.next()) == null);
}

test "json-rpc cursor surfaces error result as TransportError" {
    const a = testing.allocator;
    const data =
        \\{"jsonrpc":"2.0","id":"1","error":{"code":-32603,"message":"boom"}}
    ;
    var sse_buf: std.array_list.Managed(u8) = .init(a);
    defer sse_buf.deinit();
    try sse_buf.appendSlice("data: ");
    try sse_buf.appendSlice(data);
    try sse_buf.appendSlice("\n\n");

    const owned = try a.dupe(u8, sse_buf.items);
    var cursor = try Cursor.create(a, owned, .json_rpc);
    var iter = cursor.iterator();
    defer iter.deinit();

    try testing.expectError(StreamIterator.NextError.TransportError, iter.next());
}
