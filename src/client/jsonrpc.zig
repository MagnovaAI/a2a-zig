//! JSON-RPC 2.0 client transport.
//!
//! Sends every protocol method as a JSON-RPC POST to a single endpoint.
//! Request payloads travel as ProtoJSON-canonical JSON inside the envelope's
//! `params` field. Streaming methods set `Accept: text/event-stream` and
//! decode each SSE event as a JSON-RPC response carrying a `StreamResponse`
//! in its `result` field. Streaming impl is wired separately on top of
//! `lib/sse` and `std.http.Client.request`; here we leave streaming methods
//! returning `TransportError` so the unary methods can land first.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");
const transport = @import("transport.zig");
const streaming = @import("streaming.zig");

const ServiceParams = transport.ServiceParams;
const Transport = transport.Transport;
const TransportFactory = transport.TransportFactory;
const StreamIterator = transport.StreamIterator;
const log = std.log.scoped(.a2a_client);

const RpcError = Transport.Error || error{
    HttpRequestFailed,
    HttpStatusError,
    InvalidResponse,
    JsonRpcError,
    NotImplemented,
};

/// JSON-RPC transport state.
pub const JsonRpcTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    /// Endpoint URL. Trailing slashes are not trimmed: the server may treat a
    /// trailing slash as significant.
    endpoint: []const u8,
    /// Hard cap on a single response body, default 8 MiB.
    max_response_bytes: usize = 8 * 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8) !*JsonRpcTransport {
        const self = try allocator.create(JsonRpcTransport);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .endpoint = try allocator.dupe(u8, endpoint),
        };
        return self;
    }

    fn destroy(self: *JsonRpcTransport) void {
        self.client.deinit();
        self.allocator.free(self.endpoint);
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn transport(self: *JsonRpcTransport) *Transport {
        const out = self.allocator.create(Transport) catch unreachable;
        out.* = .{ .ctx = @ptrCast(self), .vtable = &vtable };
        return out;
    }

    fn buildHeaders(
        self: *JsonRpcTransport,
        params: *const ServiceParams,
    ) ![]std.http.Header {
        var n: usize = 1; // content-type
        var it = params.entries.iterator();
        while (it.next()) |entry| n += entry.value_ptr.*.len;

        const out = try self.allocator.alloc(std.http.Header, n);
        errdefer self.allocator.free(out);
        out[0] = .{ .name = "Content-Type", .value = "application/json" };
        var idx: usize = 1;
        var it2 = params.entries.iterator();
        while (it2.next()) |entry| {
            for (entry.value_ptr.*) |v| {
                out[idx] = .{ .name = entry.key_ptr.*, .value = v };
                idx += 1;
            }
        }
        return out;
    }

    /// Generate a fresh JSON-RPC request id (UUIDv7 string form).
    fn newId(_: *JsonRpcTransport, request_allocator: std.mem.Allocator) ![]u8 {
        return a2a.newTaskId(request_allocator);
    }

    /// Build the JSON body for a unary call: an envelope wrapping `params_json`
    /// (already a ProtoJSON-encoded string) under `id`/`method`/`params`.
    fn buildEnvelope(
        request_allocator: std.mem.Allocator,
        id: []const u8,
        method: []const u8,
        params_json: ?[]const u8,
    ) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(request_allocator);
        defer w.deinit();
        try w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeJsonString(&w.writer, id);
        try w.writer.writeAll(",\"method\":");
        try writeJsonString(&w.writer, method);
        if (params_json) |p| {
            try w.writer.writeAll(",\"params\":");
            try w.writer.writeAll(p);
        }
        try w.writer.writeByte('}');
        return request_allocator.dupe(u8, w.written());
    }

    /// Send the envelope and return the raw `result` slice (heap-owned by
    /// `request_allocator`). On JSON-RPC error, returns `JsonRpcError` with
    /// the error logged.
    fn callRaw(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        method: []const u8,
        params_json: ?[]const u8,
    ) RpcError![]u8 {
        const id = self.newId(request_allocator) catch return RpcError.OutOfMemory;
        defer request_allocator.free(id);
        const body = buildEnvelope(request_allocator, id, method, params_json) catch return RpcError.OutOfMemory;
        defer request_allocator.free(body);

        const headers = self.buildHeaders(params) catch return RpcError.OutOfMemory;
        defer self.allocator.free(headers);

        var resp_body: std.Io.Writer.Allocating = .init(request_allocator);
        errdefer resp_body.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = self.endpoint },
            .method = .POST,
            .extra_headers = headers,
            .payload = body,
            .response_writer = &resp_body.writer,
            .keep_alive = false,
        }) catch |err| {
            log.err("JSON-RPC fetch failed: method={s} err={s}", .{ method, @errorName(err) });
            resp_body.deinit();
            return RpcError.HttpRequestFailed;
        };

        const status = @intFromEnum(result.status);
        if (status < 200 or status >= 300) {
            log.err("JSON-RPC HTTP status: method={s} status={d}", .{ method, status });
            resp_body.deinit();
            return RpcError.HttpStatusError;
        }
        if (resp_body.written().len > self.max_response_bytes) {
            resp_body.deinit();
            return RpcError.InvalidResponse;
        }

        const raw = resp_body.toOwnedSlice() catch return RpcError.OutOfMemory;
        defer request_allocator.free(raw);

        const parsed = std.json.parseFromSlice(std.json.Value, request_allocator, raw, .{}) catch {
            return RpcError.InvalidResponse;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return RpcError.InvalidResponse,
        };

        if (obj.get("error")) |err_v| switch (err_v) {
            .object => |err_obj| {
                var code: i32 = a2a.code.INTERNAL_ERROR;
                if (err_obj.get("code")) |c| switch (c) {
                    .integer => |i| code = @intCast(i),
                    else => {},
                };
                var message: []const u8 = "JSON-RPC error";
                if (err_obj.get("message")) |m| switch (m) {
                    .string => |s| message = s,
                    else => {},
                };
                log.err("JSON-RPC error: method={s} code={d} message={s}", .{ method, code, message });
                return RpcError.JsonRpcError;
            },
            .null => {},
            else => return RpcError.InvalidResponse,
        };

        const result_v = obj.get("result") orelse return RpcError.InvalidResponse;
        return std.json.Stringify.valueAlloc(request_allocator, result_v, .{}) catch RpcError.OutOfMemory;
    }

    fn callTyped(
        self: *JsonRpcTransport,
        comptime PbReq: type,
        comptime PbResp: type,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        method: []const u8,
        pb_req: PbReq,
    ) RpcError!std.json.Parsed(PbResp) {
        const params_json = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RpcError.InvalidResponse;
        defer request_allocator.free(params_json);

        const result_json = try self.callRaw(request_allocator, params, method, params_json);
        defer request_allocator.free(result_json);

        return PbResp.jsonDecode(result_json, .{}, request_allocator) catch RpcError.InvalidResponse;
    }

    // -------------------------------------------------------------------
    // Vtable methods
    // -------------------------------------------------------------------

    fn vtSendMessage(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) Transport.Error!a2a.SendMessageResponse {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.sendMessageImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn sendMessageImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) RpcError!a2a.SendMessageResponse {
        var pb_req = pb.conv.sendMessageRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.SendMessageRequest, pb.v1.SendMessageResponse, request_allocator, params, a2a.methods.SEND_MESSAGE, pb_req);
        defer parsed.deinit();
        return pb.conv.sendMessageResponseFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtSendStreamingMessage(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) Transport.Error!StreamIterator {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.streamingCall(
            request_allocator,
            params,
            a2a.methods.SEND_STREAMING_MESSAGE,
            req,
            pb.v1.SendMessageRequest,
            pb.conv.sendMessageRequestToProto,
        ) catch |err| mapErr(err);
    }

    fn vtSubscribeToTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SubscribeToTaskRequest,
    ) Transport.Error!StreamIterator {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.streamingCall(
            request_allocator,
            params,
            a2a.methods.SUBSCRIBE_TO_TASK,
            req,
            pb.v1.SubscribeToTaskRequest,
            pb.conv.subscribeToTaskRequestToProto,
        ) catch |err| mapErr(err);
    }

    fn streamingCall(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        method: []const u8,
        req: anytype,
        comptime PbReq: type,
        comptime toProto: fn (std.mem.Allocator, @TypeOf(req.*)) anyerror!PbReq,
    ) RpcError!StreamIterator {
        var pb_req = toProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const params_json = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RpcError.InvalidResponse;
        defer request_allocator.free(params_json);

        const id = self.newId(request_allocator) catch return RpcError.OutOfMemory;
        defer request_allocator.free(id);
        const body = buildEnvelope(request_allocator, id, method, params_json) catch return RpcError.OutOfMemory;
        defer request_allocator.free(body);

        // Streaming responses use `Accept: text/event-stream` plus the
        // standard content-type for the request body.
        var headers_list: std.array_list.Managed(std.http.Header) = .init(self.allocator);
        defer headers_list.deinit();
        headers_list.append(.{ .name = "Content-Type", .value = "application/json" }) catch return RpcError.OutOfMemory;
        headers_list.append(.{ .name = "Accept", .value = "text/event-stream" }) catch return RpcError.OutOfMemory;
        var it = params.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |v| {
                headers_list.append(.{ .name = entry.key_ptr.*, .value = v }) catch return RpcError.OutOfMemory;
            }
        }

        const bytes = streaming.fetchResponseBytes(request_allocator, &self.client, .{
            .method = .POST,
            .url = self.endpoint,
            .headers = headers_list.items,
            .payload = body,
            .max_bytes = self.max_response_bytes,
        }) catch |err| return mapStreamingFetchErr(err);

        const cursor = streaming.Cursor.create(request_allocator, bytes, .json_rpc) catch {
            request_allocator.free(bytes);
            return RpcError.OutOfMemory;
        };
        return cursor.iterator();
    }

    fn vtGetTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskRequest,
    ) Transport.Error!a2a.Task {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.getTaskImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn getTaskImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskRequest,
    ) RpcError!a2a.Task {
        var pb_req = pb.conv.getTaskRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.GetTaskRequest, pb.v1.Task, request_allocator, params, a2a.methods.GET_TASK, pb_req);
        defer parsed.deinit();
        return pb.conv.taskFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtListTasks(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTasksRequest,
    ) Transport.Error!a2a.ListTasksResponse {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.listTasksImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn listTasksImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTasksRequest,
    ) RpcError!a2a.ListTasksResponse {
        var pb_req = pb.conv.listTasksRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.ListTasksRequest, pb.v1.ListTasksResponse, request_allocator, params, a2a.methods.LIST_TASKS, pb_req);
        defer parsed.deinit();
        return pb.conv.listTasksResponseFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtCancelTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CancelTaskRequest,
    ) Transport.Error!a2a.Task {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.cancelTaskImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn cancelTaskImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CancelTaskRequest,
    ) RpcError!a2a.Task {
        var pb_req = pb.conv.cancelTaskRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.CancelTaskRequest, pb.v1.Task, request_allocator, params, a2a.methods.CANCEL_TASK, pb_req);
        defer parsed.deinit();
        return pb.conv.taskFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtCreatePushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CreateTaskPushNotificationConfigRequest,
    ) Transport.Error!a2a.TaskPushNotificationConfig {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.createPushConfigImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn createPushConfigImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CreateTaskPushNotificationConfigRequest,
    ) RpcError!a2a.TaskPushNotificationConfig {
        var pb_req = pb.conv.createTaskPushNotificationConfigRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.TaskPushNotificationConfig, pb.v1.TaskPushNotificationConfig, request_allocator, params, a2a.methods.CREATE_PUSH_CONFIG, pb_req);
        defer parsed.deinit();
        return pb.conv.taskPushNotificationConfigFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtGetPushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskPushNotificationConfigRequest,
    ) Transport.Error!a2a.TaskPushNotificationConfig {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.getPushConfigImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn getPushConfigImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskPushNotificationConfigRequest,
    ) RpcError!a2a.TaskPushNotificationConfig {
        var pb_req = pb.conv.getTaskPushNotificationConfigRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.GetTaskPushNotificationConfigRequest, pb.v1.TaskPushNotificationConfig, request_allocator, params, a2a.methods.GET_PUSH_CONFIG, pb_req);
        defer parsed.deinit();
        return pb.conv.taskPushNotificationConfigFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtListPushConfigs(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTaskPushNotificationConfigsRequest,
    ) Transport.Error!a2a.ListTaskPushNotificationConfigsResponse {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.listPushConfigsImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn listPushConfigsImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTaskPushNotificationConfigsRequest,
    ) RpcError!a2a.ListTaskPushNotificationConfigsResponse {
        var pb_req = pb.conv.listTaskPushNotificationConfigsRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.ListTaskPushNotificationConfigsRequest, pb.v1.ListTaskPushNotificationConfigsResponse, request_allocator, params, a2a.methods.LIST_PUSH_CONFIGS, pb_req);
        defer parsed.deinit();
        return pb.conv.listTaskPushNotificationConfigsResponseFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtDeletePushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.DeleteTaskPushNotificationConfigRequest,
    ) Transport.Error!void {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.deletePushConfigImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn deletePushConfigImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.DeleteTaskPushNotificationConfigRequest,
    ) RpcError!void {
        var pb_req = pb.conv.deleteTaskPushNotificationConfigRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const params_json = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RpcError.InvalidResponse;
        defer request_allocator.free(params_json);
        const result_json = try self.callRaw(request_allocator, params, a2a.methods.DELETE_PUSH_CONFIG, params_json);
        request_allocator.free(result_json);
    }

    fn vtGetExtendedAgentCard(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetExtendedAgentCardRequest,
    ) Transport.Error!a2a.AgentCard {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        return self.getExtendedAgentCardImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn getExtendedAgentCardImpl(
        self: *JsonRpcTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetExtendedAgentCardRequest,
    ) RpcError!a2a.AgentCard {
        var pb_req = pb.conv.getExtendedAgentCardRequestToProto(request_allocator, req.*) catch return RpcError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const parsed = try self.callTyped(pb.v1.GetExtendedAgentCardRequest, pb.v1.AgentCard, request_allocator, params, a2a.methods.GET_EXTENDED_AGENT_CARD, pb_req);
        defer parsed.deinit();
        return pb.conv.agentCardFromProto(request_allocator, parsed.value) catch RpcError.OutOfMemory;
    }

    fn vtDestroy(ctx: *anyopaque) void {
        const self: *JsonRpcTransport = @ptrCast(@alignCast(ctx));
        self.destroy();
    }

    const vtable: Transport.VTable = .{
        .send_message = vtSendMessage,
        .send_streaming_message = vtSendStreamingMessage,
        .get_task = vtGetTask,
        .list_tasks = vtListTasks,
        .cancel_task = vtCancelTask,
        .subscribe_to_task = vtSubscribeToTask,
        .create_push_config = vtCreatePushConfig,
        .get_push_config = vtGetPushConfig,
        .list_push_configs = vtListPushConfigs,
        .delete_push_config = vtDeletePushConfig,
        .get_extended_agent_card = vtGetExtendedAgentCard,
        .destroy = vtDestroy,
    };
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{X:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn mapErr(err: RpcError) Transport.Error {
    return switch (err) {
        error.OutOfMemory => Transport.Error.OutOfMemory,
        error.UnexpectedToken => Transport.Error.UnexpectedToken,
        error.MissingField => Transport.Error.MissingField,
        else => Transport.Error.TransportError,
    };
}

fn mapStreamingFetchErr(err: streaming.FetchError) RpcError {
    return switch (err) {
        error.OutOfMemory => RpcError.OutOfMemory,
        error.HttpRequestFailed => RpcError.HttpRequestFailed,
        error.HttpStatusError => RpcError.HttpStatusError,
        error.ResponseTooLarge => RpcError.InvalidResponse,
    };
}

// ---------------------------------------------------------------------------
// JsonRpcTransportFactory
// ---------------------------------------------------------------------------

pub const JsonRpcTransportFactory = struct {
    state: u8 = 0,

    pub fn factory(self: *JsonRpcTransportFactory) TransportFactory {
        return .{ .ctx = @ptrCast(self), .vtable = &factory_vtable };
    }

    fn vtProtocol(_: *anyopaque) []const u8 {
        return a2a.TRANSPORT_PROTOCOL_JSONRPC;
    }

    fn vtCreate(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: *const a2a.AgentCard,
        iface: *const a2a.AgentInterface,
    ) TransportFactory.Error!*Transport {
        const io = std.Io.Threaded.global_single_threaded.io();
        const tr = JsonRpcTransport.init(allocator, io, iface.url) catch return TransportFactory.Error.OutOfMemory;
        return tr.transport();
    }

    const factory_vtable: TransportFactory.VTable = .{
        .protocol = vtProtocol,
        .create = vtCreate,
    };
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "json string escaping" {
    const a = testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try writeJsonString(&w.writer, "hello \"world\"\n");
    try testing.expectEqualStrings("\"hello \\\"world\\\"\\n\"", w.written());
}

test "envelope build with params" {
    const a = testing.allocator;
    const env = try JsonRpcTransport.buildEnvelope(a, "abc", "GetTask", "{\"id\":\"t1\"}");
    defer a.free(env);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"GetTask\",\"params\":{\"id\":\"t1\"}}",
        env,
    );
}

test "envelope build without params" {
    const a = testing.allocator;
    const env = try JsonRpcTransport.buildEnvelope(a, "abc", "Ping", null);
    defer a.free(env);
    try testing.expect(std.mem.indexOf(u8, env, "params") == null);
}

test "factory exposes JSONRPC protocol" {
    var f: JsonRpcTransportFactory = .{};
    const tf = f.factory();
    try testing.expectEqualStrings("JSONRPC", tf.protocol());
}

test "init/destroy keeps endpoint owned" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tr = try JsonRpcTransport.init(a, io, "http://localhost:3000/jsonrpc");
    defer tr.destroy();
    try testing.expectEqualStrings("http://localhost:3000/jsonrpc", tr.endpoint);
}
