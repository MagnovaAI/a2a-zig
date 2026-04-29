//! REST (HTTP+JSON) binding.
//!
//! `Handler` dispatches A2A operations onto a `RequestHandler` based on the
//! method + path of the inbound HTTP request. The wire format on the body
//! is the canonical native-JSON representation of the matching `a2a.*`
//! type — same encoding the JSON-RPC `params`/`result` fields carry.
//!
//! Endpoint map (see also the Rust reference):
//!   POST /message:send                                   -> sendMessage
//!   POST /message:stream                                 -> sendStreamingMessage (SSE)
//!   GET  /tasks                                          -> listTasks
//!   GET  /tasks/{id}                                     -> getTask
//!   POST /tasks/{id}:cancel                              -> cancelTask
//!   GET  /tasks/{id}:subscribe                           -> subscribeToTask (SSE)
//!   POST /tasks/{id}/pushNotificationConfigs            -> createPushConfig
//!   GET  /tasks/{id}/pushNotificationConfigs            -> listPushConfigs
//!   GET  /tasks/{id}/pushNotificationConfigs/{cfg_id}    -> getPushConfig
//!   DELETE /tasks/{id}/pushNotificationConfigs/{cfg_id}  -> deletePushConfig
//!   GET  /extendedAgentCard                              -> getExtendedAgentCard
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");
const httpz = @import("httpz");

const handler_mod = @import("handler.zig");
const middleware = @import("middleware.zig");
const sse_mod = @import("sse.zig");

const log = std.log.scoped(.a2a_server);

const RequestHandler = handler_mod.RequestHandler;
const ServiceParams = middleware.ServiceParams;

/// httpz endpoint adapter for REST.
pub const Handler = struct {
    inner: RequestHandler,
    /// Long-lived allocator for SSE streams that must outlive the per-request arena.
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, inner: RequestHandler) Handler {
        return .{ .allocator = allocator, .inner = inner, .io = io };
    }

    pub fn action(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        try writeCorsHeaders(req, res);
        if (req.method == .OPTIONS) {
            res.status = 204;
            return;
        }

        const arena = res.arena;
        var params = serviceParamsFromHeaders(arena, req) catch {
            return writeError(res, 500, "service params alloc");
        };
        defer params.deinit();

        const path = req.url.path;
        const method = req.method;

        // /message:send
        if (method == .POST and std.mem.eql(u8, path, "/message:send")) {
            return self.handleSendMessage(arena, &params, req, res);
        }
        // /message:stream
        if (method == .POST and std.mem.eql(u8, path, "/message:stream")) {
            return self.handleSendStreaming(arena, &params, req, res);
        }
        // /extendedAgentCard
        if (method == .GET and std.mem.eql(u8, path, "/extendedAgentCard")) {
            return self.handleExtendedCard(arena, &params, res);
        }
        // /tasks (list)
        if (method == .GET and std.mem.eql(u8, path, "/tasks")) {
            return self.handleListTasks(arena, &params, req, res);
        }

        // Tasks subtree.
        if (std.mem.startsWith(u8, path, "/tasks/")) {
            const remainder = path["/tasks/".len..];
            if (std.mem.indexOfScalar(u8, remainder, '/')) |slash_idx| {
                const task_id = remainder[0..slash_idx];
                const tail = remainder[slash_idx..];
                if (std.mem.eql(u8, tail, "/pushNotificationConfigs")) {
                    if (method == .POST) return self.handleCreatePushConfig(arena, &params, task_id, req, res);
                    if (method == .GET) return self.handleListPushConfigs(arena, &params, task_id, req, res);
                }
                if (std.mem.startsWith(u8, tail, "/pushNotificationConfigs/")) {
                    const cfg_id = tail["/pushNotificationConfigs/".len..];
                    if (cfg_id.len > 0) {
                        if (method == .GET) return self.handleGetPushConfig(arena, &params, task_id, cfg_id, res);
                        if (method == .DELETE) return self.handleDeletePushConfig(arena, &params, task_id, cfg_id, res);
                    }
                }
            } else {
                // /tasks/{id} or /tasks/{id}:cancel or /tasks/{id}:subscribe
                if (std.mem.indexOfScalar(u8, remainder, ':')) |colon_idx| {
                    const task_id = remainder[0..colon_idx];
                    const verb = remainder[colon_idx + 1 ..];
                    if (method == .POST and std.mem.eql(u8, verb, "cancel")) {
                        return self.handleCancelTask(arena, &params, task_id, req, res);
                    }
                    if (method == .GET and std.mem.eql(u8, verb, "subscribe")) {
                        return self.handleSubscribe(arena, &params, task_id, res);
                    }
                } else if (method == .GET) {
                    return self.handleGetTask(arena, &params, remainder, res);
                }
            }
        }

        return writeError(res, 404, "not found");
    }

    // ---------- Per-endpoint handlers ----------

    fn handleSendMessage(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        const body = req.body() orelse return writeError(res, 400, "missing body");
        const sm_req = decodeProtoBody(arena, body, pb.v1.SendMessageRequest, pb.conv.sendMessageRequestFromProto) catch
            return writeError(res, 400, "invalid SendMessageRequest");
        var resp = self.inner.sendMessage(arena, params, sm_req) catch |err|
            return writeRestHandlerError(res, err);
        defer resp.deinit();
        try writeProtoBody(arena, res, 200, resp, pb.conv.sendMessageResponseToProto);
    }

    fn handleSendStreaming(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        const body = req.body() orelse return writeError(res, 400, "missing body");
        const sm_req = decodeProtoBody(arena, body, pb.v1.SendMessageRequest, pb.conv.sendMessageRequestFromProto) catch
            return writeError(res, 400, "invalid SendMessageRequest");
        var iter = self.inner.sendStreamingMessage(arena, params, sm_req) catch |err|
            return writeRestHandlerError(res, err);

        const source = self.allocator.create(sse_mod.StreamSource) catch {
            iter.deinit();
            return writeError(res, 500, "alloc stream source");
        };
        source.* = .{ .allocator = self.allocator, .io = self.io, .iterator = iter };
        try res.startEventStream(source, sse_mod.writeStream);
    }

    fn handleListTasks(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        var lt_req: a2a.ListTasksRequest = .{ .allocator = arena };
        defer lt_req.deinit();
        const q = req.url.query;
        if (q.len > 0) {
            try parseListTasksQuery(arena, q, &lt_req);
        }
        var resp = self.inner.listTasks(arena, params, lt_req) catch |err|
            return writeRestHandlerError(res, err);
        defer resp.deinit();
        try writeProtoBody(arena, res, 200, resp, pb.conv.listTasksResponseToProto);
        // ownership of the request was claimed by the handler (defer above is a no-op then)
        lt_req = .{ .allocator = arena }; // already deinit'd by handler
    }

    fn handleGetTask(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        res: *httpz.Response,
    ) !void {
        const gt_req: a2a.GetTaskRequest = .{
            .id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .allocator = arena,
        };
        var task = self.inner.getTask(arena, params, gt_req) catch |err|
            return writeRestHandlerError(res, err);
        defer task.deinit();
        try writeProtoBody(arena, res, 200, task, pb.conv.taskToProto);
    }

    fn handleCancelTask(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        _: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        const ct_req: a2a.CancelTaskRequest = .{
            .id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .allocator = arena,
        };
        var task = self.inner.cancelTask(arena, params, ct_req) catch |err|
            return writeRestHandlerError(res, err);
        defer task.deinit();
        try writeProtoBody(arena, res, 200, task, pb.conv.taskToProto);
    }

    fn handleSubscribe(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        res: *httpz.Response,
    ) !void {
        const sub_req: a2a.SubscribeToTaskRequest = .{
            .id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .allocator = arena,
        };
        var iter = self.inner.subscribeToTask(arena, params, sub_req) catch |err|
            return writeRestHandlerError(res, err);
        const source = self.allocator.create(sse_mod.StreamSource) catch {
            iter.deinit();
            return writeError(res, 500, "alloc stream source");
        };
        source.* = .{ .allocator = self.allocator, .io = self.io, .iterator = iter };
        try res.startEventStream(source, sse_mod.writeStream);
    }

    fn handleCreatePushConfig(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        const body = req.body() orelse return writeError(res, 400, "missing body");
        var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
            return writeError(res, 400, "invalid JSON");
        defer parsed.deinit();
        const cfg = a2a.PushNotificationConfig.jsonParseFromValue(arena, parsed.value, .{}) catch
            return writeError(res, 400, "invalid PushNotificationConfig");
        const create_req: a2a.CreateTaskPushNotificationConfigRequest = .{
            .task_id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .config = cfg,
            .allocator = arena,
        };
        var resp = self.inner.createPushConfig(arena, params, create_req) catch |err|
            return writeRestHandlerError(res, err);
        defer resp.deinit();
        try writeProtoBody(arena, res, 200, resp, pb.conv.taskPushNotificationConfigToProto);
    }

    fn handleListPushConfigs(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        var list_req: a2a.ListTaskPushNotificationConfigsRequest = .{
            .task_id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .allocator = arena,
        };
        if (req.url.query.len > 0) {
            parsePushListQuery(arena, req.url.query, &list_req) catch {};
        }
        var resp = self.inner.listPushConfigs(arena, params, list_req) catch |err|
            return writeRestHandlerError(res, err);
        defer resp.deinit();
        try writeProtoBody(arena, res, 200, resp, pb.conv.listTaskPushNotificationConfigsResponseToProto);
    }

    fn handleGetPushConfig(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        cfg_id: []const u8,
        res: *httpz.Response,
    ) !void {
        const get_req: a2a.GetTaskPushNotificationConfigRequest = .{
            .task_id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .id = arena.dupe(u8, cfg_id) catch return writeError(res, 500, "alloc"),
            .allocator = arena,
        };
        var resp = self.inner.getPushConfig(arena, params, get_req) catch |err|
            return writeRestHandlerError(res, err);
        defer resp.deinit();
        try writeProtoBody(arena, res, 200, resp, pb.conv.taskPushNotificationConfigToProto);
    }

    fn handleDeletePushConfig(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        task_id: []const u8,
        cfg_id: []const u8,
        res: *httpz.Response,
    ) !void {
        const del_req: a2a.DeleteTaskPushNotificationConfigRequest = .{
            .task_id = arena.dupe(u8, task_id) catch return writeError(res, 500, "alloc"),
            .id = arena.dupe(u8, cfg_id) catch return writeError(res, 500, "alloc"),
            .allocator = arena,
        };
        self.inner.deletePushConfig(params, del_req) catch |err|
            return writeRestHandlerError(res, err);
        res.status = 204;
    }

    fn handleExtendedCard(
        self: *Handler,
        arena: std.mem.Allocator,
        params: *const ServiceParams,
        res: *httpz.Response,
    ) !void {
        const empty: a2a.GetExtendedAgentCardRequest = .{ .allocator = arena };
        var card = self.inner.getExtendedAgentCard(arena, params, empty) catch |err|
            return writeRestHandlerError(res, err);
        defer card.deinit();
        try writeProtoBody(arena, res, 200, card, pb.conv.agentCardToProto);
    }
};

// ---- Proto-JSON codec helpers ----

fn decodeProtoBody(
    arena: std.mem.Allocator,
    body: []const u8,
    comptime ProtoT: type,
    comptime fromProto: anytype,
) !ReturnPayload(@TypeOf(fromProto)) {
    const parsed = try ProtoT.jsonDecode(body, .{}, arena);
    defer parsed.deinit();
    return try fromProto(arena, parsed.value);
}

fn ReturnPayload(comptime FnT: type) type {
    const info = @typeInfo(FnT).@"fn".return_type.?;
    return @typeInfo(info).error_union.payload;
}

fn writeProtoBody(
    arena: std.mem.Allocator,
    res: *httpz.Response,
    status: u16,
    value: anytype,
    comptime toProto: anytype,
) !void {
    var pb_value = toProto(arena, value) catch {
        res.status = 500;
        return;
    };
    defer pb_value.deinit(arena);
    const json = pb_value.jsonEncode(.{}, .{}, arena) catch {
        res.status = 500;
        return;
    };
    res.status = status;
    res.content_type = httpz.ContentType.JSON;
    res.body = json;
}

// ---------------------------------------------------------------------------
// Query string parsers
// ---------------------------------------------------------------------------

fn parseListTasksQuery(arena: std.mem.Allocator, query: []const u8, out: *a2a.ListTasksRequest) !void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const raw = pair[eq + 1 ..];
        const v = try urlDecode(arena, raw);
        if (std.mem.eql(u8, k, "contextId")) {
            out.context_id = v;
        } else if (std.mem.eql(u8, k, "pageSize")) {
            out.page_size = std.fmt.parseInt(i32, v, 10) catch null;
            arena.free(v);
        } else if (std.mem.eql(u8, k, "pageToken")) {
            out.page_token = v;
        } else if (std.mem.eql(u8, k, "historyLength")) {
            out.history_length = std.fmt.parseInt(i32, v, 10) catch null;
            arena.free(v);
        } else if (std.mem.eql(u8, k, "statusTimestampAfter")) {
            out.status_timestamp_after = v;
        } else if (std.mem.eql(u8, k, "includeArtifacts")) {
            out.include_artifacts = std.mem.eql(u8, v, "true");
            arena.free(v);
        } else if (std.mem.eql(u8, k, "tenant")) {
            out.tenant = v;
        } else {
            arena.free(v);
        }
    }
}

fn parsePushListQuery(arena: std.mem.Allocator, query: []const u8, out: *a2a.ListTaskPushNotificationConfigsRequest) !void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = try urlDecode(arena, pair[eq + 1 ..]);
        if (std.mem.eql(u8, k, "pageSize")) {
            out.page_size = std.fmt.parseInt(i32, v, 10) catch null;
            arena.free(v);
        } else if (std.mem.eql(u8, k, "pageToken")) {
            out.page_token = v;
        } else if (std.mem.eql(u8, k, "tenant")) {
            out.tenant = v;
        } else {
            arena.free(v);
        }
    }
}

fn urlDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try arena.alloc(u8, s.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                out[j] = s[i];
                j += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                out[j] = s[i];
                j += 1;
                continue;
            };
            out[j] = (hi << 4) | lo;
            j += 1;
            i += 2;
        } else if (s[i] == '+') {
            out[j] = ' ';
            j += 1;
        } else {
            out[j] = s[i];
            j += 1;
        }
    }
    return out[0..j];
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

fn writeJsonValue(res: *httpz.Response, status: u16, value: anytype) !void {
    res.status = status;
    res.content_type = httpz.ContentType.JSON;
    res.body = std.json.Stringify.valueAlloc(res.arena, value, .{}) catch {
        res.status = 500;
        return;
    };
}

fn writeError(res: *httpz.Response, status: u16, message: []const u8) !void {
    res.status = status;
    res.content_type = httpz.ContentType.JSON;
    var w: std.Io.Writer.Allocating = .init(res.arena);
    defer w.deinit();
    var jw: std.json.Stringify = .{ .writer = &w.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(status);
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
    res.body = res.arena.dupe(u8, w.written()) catch w.written();
}

fn writeRestHandlerError(res: *httpz.Response, err: RequestHandler.Error) !void {
    const status: u16 = switch (err) {
        error.TaskNotFound => 404,
        error.TaskNotCancelable => 409,
        error.PushNotificationNotSupported => 400,
        error.UnsupportedOperation => 400,
        error.InvalidArgument => 400,
        else => 500,
    };
    return writeError(res, status, @errorName(err));
}

fn writeCorsHeaders(req: *httpz.Request, res: *httpz.Response) !void {
    if (req.header("origin")) |origin| {
        res.header("access-control-allow-origin", origin);
        res.header("access-control-allow-credentials", "true");
        res.header("vary", "Origin");
    } else {
        res.header("access-control-allow-origin", "*");
    }
    res.header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    res.header("access-control-allow-headers", "Content-Type, Authorization, A2A-Version, A2A-Extensions");
}

fn serviceParamsFromHeaders(arena: std.mem.Allocator, req: *httpz.Request) !ServiceParams {
    var p = ServiceParams.init(arena);
    errdefer p.deinit();
    var iter = req.headers.iterator();
    while (iter.next()) |h| {
        try p.append(h.key, h.value);
    }
    return p;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "urlDecode handles percent encoding and plus" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try testing.expectEqualStrings("hello world", try urlDecode(aa, "hello%20world"));
    try testing.expectEqualStrings("a+b", try urlDecode(aa, "a%2Bb"));
    try testing.expectEqualStrings("foo bar", try urlDecode(aa, "foo+bar"));
}
