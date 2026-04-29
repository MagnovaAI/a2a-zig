//! JSON-RPC 2.0 binding.
//!
//! Translates inbound HTTP requests to `RequestHandler` calls and the
//! result back to a `JsonRpcResponse` body. Streaming methods
//! (`SendStreamingMessage`, `SubscribeToTask`) hand the connection to
//! `sse.writeStream`; every other method writes a unary JSON response.
//!
//! `Handler` is the httpz endpoint. Mount it at the JSON-RPC path of
//! your choice (typically `/`) with the bundled `Handler.action`.
//!
//! Request parameters and responses use the native `a2a.*` types' own
//! `jsonStringify` / `jsonParseFromValue`; we don't go through the
//! protobuf round-trip on this hot path.
const std = @import("std");
const a2a = @import("a2a");
const httpz = @import("httpz");

const handler_mod = @import("handler.zig");
const middleware = @import("middleware.zig");
const sse_mod = @import("sse.zig");

const log = std.log.scoped(.a2a_server);

const RequestHandler = handler_mod.RequestHandler;
const ServiceParams = middleware.ServiceParams;

/// httpz endpoint adapter.
pub const Handler = struct {
    inner: RequestHandler,
    /// Long-lived allocator used for SSE streams that must outlive the
    /// per-request arena.
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, inner: RequestHandler) Handler {
        return .{ .inner = inner, .allocator = allocator, .io = io };
    }

    pub fn action(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        const arena = res.arena;
        const body = req.body() orelse {
            try writeParseError(res, "missing body");
            return;
        };

        var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
            try writeParseError(res, "invalid JSON");
            return;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                try writeParseError(res, "envelope must be a JSON object");
                return;
            },
        };

        var rpc_id: a2a.JsonRpcId = if (obj.get("id")) |v|
            a2a.JsonRpcId.jsonParseFromValue(arena, v, .{}) catch a2a.JsonRpcId.null
        else
            a2a.JsonRpcId.null;

        const method_v = obj.get("method") orelse {
            try writeError(res, rpc_id, a2a.code.INVALID_REQUEST, "missing method");
            return;
        };
        const method = switch (method_v) {
            .string => |s| s,
            else => {
                try writeError(res, rpc_id, a2a.code.INVALID_REQUEST, "method must be a string");
                return;
            },
        };

        const params_v = obj.get("params") orelse std.json.Value{ .null = {} };
        var params = serviceParamsFromHeaders(arena, req) catch {
            try writeError(res, rpc_id, a2a.code.INTERNAL_ERROR, "service params alloc");
            return;
        };
        defer params.deinit();

        if (a2a.methods.isStreaming(method)) {
            try self.dispatchStreaming(arena, &rpc_id, method, params_v, &params, res);
        } else {
            try self.dispatchUnary(arena, &rpc_id, method, params_v, &params, res);
        }
    }

    fn dispatchUnary(
        self: *Handler,
        arena: std.mem.Allocator,
        rpc_id: *a2a.JsonRpcId,
        method: []const u8,
        params_v: std.json.Value,
        params: *const ServiceParams,
        res: *httpz.Response,
    ) !void {
        if (std.mem.eql(u8, method, a2a.methods.SEND_MESSAGE)) {
            const req = a2a.SendMessageRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid SendMessageRequest");
            var result = self.inner.sendMessage(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer result.deinit();
            try writeUnaryFrom(res, rpc_id, result);
        } else if (std.mem.eql(u8, method, a2a.methods.GET_TASK)) {
            const req = parseGetTaskRequest(arena, params_v) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid GetTaskRequest");
            var task = self.inner.getTask(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer task.deinit();
            try writeUnaryFrom(res, rpc_id, task);
        } else if (std.mem.eql(u8, method, a2a.methods.LIST_TASKS)) {
            const req = a2a.ListTasksRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid ListTasksRequest");
            var resp = self.inner.listTasks(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer resp.deinit();
            try writeUnaryFrom(res, rpc_id, resp);
        } else if (std.mem.eql(u8, method, a2a.methods.CANCEL_TASK)) {
            const req = a2a.CancelTaskRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid CancelTaskRequest");
            var task = self.inner.cancelTask(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer task.deinit();
            try writeUnaryFrom(res, rpc_id, task);
        } else if (std.mem.eql(u8, method, a2a.methods.CREATE_PUSH_CONFIG)) {
            const req = a2a.CreateTaskPushNotificationConfigRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid CreateTaskPushNotificationConfigRequest");
            var resp = self.inner.createPushConfig(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer resp.deinit();
            try writeUnaryFrom(res, rpc_id, resp);
        } else if (std.mem.eql(u8, method, a2a.methods.GET_PUSH_CONFIG)) {
            const req = a2a.GetTaskPushNotificationConfigRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid GetTaskPushNotificationConfigRequest");
            var resp = self.inner.getPushConfig(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer resp.deinit();
            try writeUnaryFrom(res, rpc_id, resp);
        } else if (std.mem.eql(u8, method, a2a.methods.LIST_PUSH_CONFIGS)) {
            const req = a2a.ListTaskPushNotificationConfigsRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid ListTaskPushNotificationConfigsRequest");
            var resp = self.inner.listPushConfigs(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer resp.deinit();
            try writeUnaryFrom(res, rpc_id, resp);
        } else if (std.mem.eql(u8, method, a2a.methods.DELETE_PUSH_CONFIG)) {
            const req = a2a.DeleteTaskPushNotificationConfigRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid DeleteTaskPushNotificationConfigRequest");
            self.inner.deletePushConfig(params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            try writeUnary(res, rpc_id, std.json.Value{ .null = {} });
        } else if (std.mem.eql(u8, method, a2a.methods.GET_EXTENDED_AGENT_CARD)) {
            const empty: a2a.GetExtendedAgentCardRequest = .{ .allocator = arena };
            var card = self.inner.getExtendedAgentCard(arena, params, empty) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
            defer card.deinit();
            try writeUnaryFrom(res, rpc_id, card);
        } else {
            try writeError(res, rpc_id.*, a2a.code.METHOD_NOT_FOUND, "unknown method");
        }
    }

    fn dispatchStreaming(
        self: *Handler,
        arena: std.mem.Allocator,
        rpc_id: *a2a.JsonRpcId,
        method: []const u8,
        params_v: std.json.Value,
        params: *const ServiceParams,
        res: *httpz.Response,
    ) !void {
        var iter: a2a.StreamIterator = if (std.mem.eql(u8, method, a2a.methods.SEND_STREAMING_MESSAGE)) blk: {
            const req = a2a.SendMessageRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid SendMessageRequest");
            break :blk self.inner.sendStreamingMessage(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
        } else if (std.mem.eql(u8, method, a2a.methods.SUBSCRIBE_TO_TASK)) blk: {
            const req = a2a.SubscribeToTaskRequest.jsonParseFromValue(arena, params_v, .{}) catch
                return writeError(res, rpc_id.*, a2a.code.INVALID_PARAMS, "invalid SubscribeToTaskRequest");
            break :blk self.inner.subscribeToTask(arena, params, req) catch |err|
                return writeFromHandlerErr(res, rpc_id.*, err);
        } else {
            try writeError(res, rpc_id.*, a2a.code.METHOD_NOT_FOUND, "unknown streaming method");
            return;
        };
        const source = self.allocator.create(sse_mod.StreamSource) catch {
            iter.deinit();
            return writeError(res, rpc_id.*, a2a.code.INTERNAL_ERROR, "alloc stream source");
        };
        source.* = .{ .allocator = self.allocator, .io = self.io, .iterator = iter };
        try res.startEventStream(source, sse_mod.writeStream);
    }
};

fn parseGetTaskRequest(arena: std.mem.Allocator, source: std.json.Value) !a2a.GetTaskRequest {
    const obj = switch (source) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    var r: a2a.GetTaskRequest = .{ .id = "", .allocator = arena };
    errdefer r.deinit();
    if (obj.get("id")) |v| switch (v) {
        .string => |s| r.id = try arena.dupe(u8, s),
        else => return error.UnexpectedToken,
    } else return error.MissingField;
    if (obj.get("historyLength")) |v| switch (v) {
        .integer => |n| r.history_length = @intCast(n),
        else => {},
    };
    if (obj.get("tenant")) |v| switch (v) {
        .string => |s| r.tenant = try arena.dupe(u8, s),
        else => {},
    };
    return r;
}

fn writeUnary(res: *httpz.Response, id: *a2a.JsonRpcId, result: std.json.Value) !void {
    var resp = a2a.JsonRpcResponse.success(res.arena, id.*, result, null) catch {
        return writeError(res, id.*, a2a.code.INTERNAL_ERROR, "alloc response");
    };
    id.* = .null;
    defer resp.deinit();
    res.status = 200;
    res.content_type = httpz.ContentType.JSON;
    res.body = std.json.Stringify.valueAlloc(res.arena, resp, .{}) catch {
        res.status = 500;
        return;
    };
}

/// Stringify the JSON-RPC envelope inline, embedding the value's own
/// `jsonStringify` for the `result` field. Saves us a parse-back round
/// trip through `std.json.Value`.
fn writeUnaryFrom(res: *httpz.Response, id: *a2a.JsonRpcId, value: anytype) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.JSON;

    var w: std.Io.Writer.Allocating = .init(res.arena);
    errdefer w.deinit();
    var jw: std.json.Stringify = .{ .writer = &w.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id.*);
    try jw.objectField("result");
    try jw.write(value);
    try jw.endObject();
    res.body = res.arena.dupe(u8, w.written()) catch {
        res.status = 500;
        return;
    };
    w.deinit();
}

fn writeError(res: *httpz.Response, id: a2a.JsonRpcId, code: i32, message: []const u8) !void {
    const dup = res.arena.dupe(u8, message) catch message;
    const err: a2a.JsonRpcError = .{
        .code = code,
        .message = dup,
        .allocator = res.arena,
    };
    var resp = a2a.JsonRpcResponse.failure(res.arena, id, err) catch {
        res.status = 500;
        return;
    };
    defer resp.deinit();
    res.status = 200;
    res.content_type = httpz.ContentType.JSON;
    res.body = std.json.Stringify.valueAlloc(res.arena, resp, .{}) catch {
        res.status = 500;
        return;
    };
}

fn writeParseError(res: *httpz.Response, msg: []const u8) !void {
    return writeError(res, .null, a2a.code.PARSE_ERROR, msg);
}

fn writeFromHandlerErr(res: *httpz.Response, id: a2a.JsonRpcId, err: RequestHandler.Error) !void {
    const code: i32 = switch (err) {
        error.TaskNotFound => a2a.code.TASK_NOT_FOUND,
        error.TaskNotCancelable => a2a.code.TASK_NOT_CANCELABLE,
        error.PushNotificationNotSupported => a2a.code.PUSH_NOTIFICATION_NOT_SUPPORTED,
        error.UnsupportedOperation => a2a.code.UNSUPPORTED_OPERATION,
        error.InvalidArgument => a2a.code.INVALID_PARAMS,
        else => a2a.code.INTERNAL_ERROR,
    };
    return writeError(res, id, code, @errorName(err));
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

test "method dispatch covers every documented operation" {
    try testing.expect(a2a.methods.isValid(a2a.methods.SEND_MESSAGE));
    try testing.expect(a2a.methods.isValid(a2a.methods.SEND_STREAMING_MESSAGE));
    try testing.expect(a2a.methods.isValid(a2a.methods.GET_TASK));
    try testing.expect(a2a.methods.isValid(a2a.methods.LIST_TASKS));
    try testing.expect(a2a.methods.isValid(a2a.methods.CANCEL_TASK));
    try testing.expect(a2a.methods.isValid(a2a.methods.SUBSCRIBE_TO_TASK));
    try testing.expect(a2a.methods.isValid(a2a.methods.CREATE_PUSH_CONFIG));
    try testing.expect(a2a.methods.isValid(a2a.methods.GET_PUSH_CONFIG));
    try testing.expect(a2a.methods.isValid(a2a.methods.LIST_PUSH_CONFIGS));
    try testing.expect(a2a.methods.isValid(a2a.methods.DELETE_PUSH_CONFIG));
    try testing.expect(a2a.methods.isValid(a2a.methods.GET_EXTENDED_AGENT_CARD));
}
