//! REST (HTTP+JSON) transport.
//!
//! Each A2A operation maps to a RESTful endpoint. Request and response bodies
//! travel as ProtoJSON-canonical JSON, produced by the generated `pb.v1`
//! types' `jsonEncode`/`jsonDecode` methods. The transport is a sync wrapper
//! around `std.http.Client.fetch` for unary calls; streaming endpoints
//! (`SendStreamingMessage`, `SubscribeToTask`) are not yet wired and will
//! land alongside the SSE-driven `StreamIterator`.
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

const SEND_MESSAGE_PATH = "/message:send";
const STREAM_MESSAGE_PATH = "/message:stream";
const EXTENDED_AGENT_CARD_PATH = "/extendedAgentCard";

const RestError = Transport.Error || error{
    HttpRequestFailed,
    HttpStatusError,
    InvalidResponse,
    NotImplemented,
};

/// REST transport state. Owned by `RestTransportFactory`-built `Transport`
/// instances; freed via `Transport.destroy`.
pub const RestTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    /// Trailing slash trimmed.
    base_url: []const u8,
    /// Hard cap on a single response body, default 8 MiB.
    max_response_bytes: usize = 8 * 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8) !*RestTransport {
        const self = try allocator.create(RestTransport);
        errdefer allocator.destroy(self);
        const trimmed = std.mem.trimEnd(u8, base_url, "/");
        const owned = try allocator.dupe(u8, trimmed);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .base_url = owned,
        };
        return self;
    }

    fn destroy(self: *RestTransport) void {
        self.client.deinit();
        self.allocator.free(self.base_url);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Wrap this transport in the protocol-binding-agnostic `Transport`
    /// interface. The vtable's `destroy` calls back into `RestTransport.destroy`.
    pub fn transport(self: *RestTransport) *Transport {
        const out = self.allocator.create(Transport) catch unreachable;
        out.* = .{ .ctx = @ptrCast(self), .vtable = &vtable };
        return out;
    }

    fn buildHeaders(
        self: *RestTransport,
        params: *const ServiceParams,
        accept: []const u8,
    ) ![]std.http.Header {
        var n: usize = 1; // accept
        var it = params.entries.iterator();
        while (it.next()) |entry| n += entry.value_ptr.*.len;

        const out = try self.allocator.alloc(std.http.Header, n);
        errdefer self.allocator.free(out);
        out[0] = .{ .name = "Accept", .value = accept };
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

    fn buildUrl(
        self: *RestTransport,
        path: []const u8,
        query_pairs: []const QueryPair,
    ) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(self.allocator);
        defer w.deinit();
        try w.writer.writeAll(self.base_url);
        try w.writer.writeAll(path);
        var first = true;
        for (query_pairs) |q| {
            try w.writer.writeByte(if (first) '?' else '&');
            first = false;
            try writeUrlEncoded(&w.writer, q.key);
            try w.writer.writeByte('=');
            try writeUrlEncoded(&w.writer, q.value);
        }
        return self.allocator.dupe(u8, w.written());
    }

    fn fetch(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        method: std.http.Method,
        url: []const u8,
        headers: []const std.http.Header,
        payload: ?[]const u8,
    ) ![]u8 {
        var body: std.Io.Writer.Allocating = .init(request_allocator);
        errdefer body.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .extra_headers = headers,
            .payload = payload,
            .response_writer = &body.writer,
            .keep_alive = false,
        }) catch |err| {
            log.err("REST fetch failed: method={s} url={s} err={s}", .{ @tagName(method), url, @errorName(err) });
            body.deinit();
            return RestError.HttpRequestFailed;
        };

        const status = @intFromEnum(result.status);
        if (status < 200 or status >= 300) {
            log.err("REST status error: method={s} url={s} status={d}", .{ @tagName(method), url, status });
            body.deinit();
            return RestError.HttpStatusError;
        }
        if (body.written().len > self.max_response_bytes) {
            body.deinit();
            return RestError.InvalidResponse;
        }
        return body.toOwnedSlice();
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
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.sendMessageImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn sendMessageImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) RestError!a2a.SendMessageResponse {
        var pb_req = pb.conv.sendMessageRequestToProto(request_allocator, req.*) catch return RestError.OutOfMemory;
        defer pb_req.deinit(request_allocator);

        const body = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer request_allocator.free(body);

        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);
        const url = self.buildUrl(SEND_MESSAGE_PATH, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);

        const resp = try self.fetch(request_allocator, .POST, url, headers, body);
        defer request_allocator.free(resp);

        const parsed = pb.v1.SendMessageResponse.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.sendMessageResponseFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtSendStreamingMessage(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) Transport.Error!StreamIterator {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.sendStreamingMessageImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn sendStreamingMessageImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) RestError!StreamIterator {
        var pb_req = pb.conv.sendMessageRequestToProto(request_allocator, req.*) catch return RestError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const body = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer request_allocator.free(body);

        const headers = self.buildHeaders(params, "text/event-stream") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);
        const url = self.buildUrl(STREAM_MESSAGE_PATH, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);

        const bytes = streaming.fetchResponseBytes(request_allocator, &self.client, .{
            .method = .POST,
            .url = url,
            .headers = headers,
            .payload = body,
            .max_bytes = self.max_response_bytes,
        }) catch |err| return mapStreamingFetchErr(err);

        const cursor = streaming.Cursor.create(request_allocator, bytes, .raw_stream_response) catch {
            request_allocator.free(bytes);
            return RestError.OutOfMemory;
        };
        return cursor.iterator();
    }

    fn vtGetTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskRequest,
    ) Transport.Error!a2a.Task {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.getTaskImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn getTaskImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskRequest,
    ) RestError!a2a.Task {
        const path = std.fmt.allocPrint(request_allocator, "/tasks/{s}", .{req.id}) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);

        var query: std.array_list.Managed(QueryPair) = .init(request_allocator);
        defer query.deinit();
        var hl_buf: [16]u8 = undefined;
        if (req.history_length) |n| {
            const s = std.fmt.bufPrint(&hl_buf, "{d}", .{n}) catch return RestError.OutOfMemory;
            try query.append(.{ .key = "historyLength", .value = s });
        }

        const url = self.buildUrl(path, query.items) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .GET, url, headers, null);
        defer request_allocator.free(resp);

        const parsed = pb.v1.Task.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.taskFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtListTasks(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTasksRequest,
    ) Transport.Error!a2a.ListTasksResponse {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.listTasksImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn listTasksImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTasksRequest,
    ) RestError!a2a.ListTasksResponse {
        var query: std.array_list.Managed(QueryPair) = .init(request_allocator);
        defer query.deinit();
        var ps_buf: [16]u8 = undefined;
        var hl_buf: [16]u8 = undefined;
        if (req.context_id) |s| try query.append(.{ .key = "contextId", .value = s });
        if (req.status) |s| try query.append(.{ .key = "status", .value = s.toWire() });
        if (req.page_size) |n| {
            const s = std.fmt.bufPrint(&ps_buf, "{d}", .{n}) catch return RestError.OutOfMemory;
            try query.append(.{ .key = "pageSize", .value = s });
        }
        if (req.page_token) |s| try query.append(.{ .key = "pageToken", .value = s });
        if (req.history_length) |n| {
            const s = std.fmt.bufPrint(&hl_buf, "{d}", .{n}) catch return RestError.OutOfMemory;
            try query.append(.{ .key = "historyLength", .value = s });
        }
        if (req.status_timestamp_after) |s| try query.append(.{ .key = "statusTimestampAfter", .value = s });
        if (req.include_artifacts) |b| try query.append(.{ .key = "includeArtifacts", .value = if (b) "true" else "false" });

        const url = self.buildUrl("/tasks", query.items) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .GET, url, headers, null);
        defer request_allocator.free(resp);

        const parsed = pb.v1.ListTasksResponse.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.listTasksResponseFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtCancelTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CancelTaskRequest,
    ) Transport.Error!a2a.Task {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.cancelTaskImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn cancelTaskImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CancelTaskRequest,
    ) RestError!a2a.Task {
        var pb_req = pb.conv.cancelTaskRequestToProto(request_allocator, req.*) catch return RestError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const body = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer request_allocator.free(body);

        const path = std.fmt.allocPrint(request_allocator, "/tasks/{s}:cancel", .{req.id}) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);
        const url = self.buildUrl(path, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .POST, url, headers, body);
        defer request_allocator.free(resp);

        const parsed = pb.v1.Task.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.taskFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtSubscribeToTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SubscribeToTaskRequest,
    ) Transport.Error!StreamIterator {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.subscribeToTaskImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn subscribeToTaskImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SubscribeToTaskRequest,
    ) RestError!StreamIterator {
        const path = std.fmt.allocPrint(
            request_allocator,
            "/tasks/{s}:subscribe",
            .{req.id},
        ) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);
        const url = self.buildUrl(path, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "text/event-stream") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const bytes = streaming.fetchResponseBytes(request_allocator, &self.client, .{
            .method = .GET,
            .url = url,
            .headers = headers,
            .payload = null,
            .max_bytes = self.max_response_bytes,
        }) catch |err| return mapStreamingFetchErr(err);

        const cursor = streaming.Cursor.create(request_allocator, bytes, .raw_stream_response) catch {
            request_allocator.free(bytes);
            return RestError.OutOfMemory;
        };
        return cursor.iterator();
    }

    fn vtCreatePushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CreateTaskPushNotificationConfigRequest,
    ) Transport.Error!a2a.TaskPushNotificationConfig {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.createPushConfigImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn createPushConfigImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CreateTaskPushNotificationConfigRequest,
    ) RestError!a2a.TaskPushNotificationConfig {
        var pb_req = pb.conv.createTaskPushNotificationConfigRequestToProto(request_allocator, req.*) catch return RestError.OutOfMemory;
        defer pb_req.deinit(request_allocator);
        const body = pb_req.jsonEncode(.{}, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer request_allocator.free(body);

        const path = std.fmt.allocPrint(
            request_allocator,
            "/tasks/{s}/pushNotificationConfigs",
            .{req.task_id},
        ) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);
        const url = self.buildUrl(path, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .POST, url, headers, body);
        defer request_allocator.free(resp);

        const parsed = pb.v1.TaskPushNotificationConfig.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.taskPushNotificationConfigFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtGetPushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskPushNotificationConfigRequest,
    ) Transport.Error!a2a.TaskPushNotificationConfig {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.getPushConfigImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn getPushConfigImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskPushNotificationConfigRequest,
    ) RestError!a2a.TaskPushNotificationConfig {
        const path = std.fmt.allocPrint(
            request_allocator,
            "/tasks/{s}/pushNotificationConfigs/{s}",
            .{ req.task_id, req.id },
        ) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);
        const url = self.buildUrl(path, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .GET, url, headers, null);
        defer request_allocator.free(resp);

        const parsed = pb.v1.TaskPushNotificationConfig.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.taskPushNotificationConfigFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtListPushConfigs(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTaskPushNotificationConfigsRequest,
    ) Transport.Error!a2a.ListTaskPushNotificationConfigsResponse {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.listPushConfigsImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn listPushConfigsImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTaskPushNotificationConfigsRequest,
    ) RestError!a2a.ListTaskPushNotificationConfigsResponse {
        var query: std.array_list.Managed(QueryPair) = .init(request_allocator);
        defer query.deinit();
        var ps_buf: [16]u8 = undefined;
        if (req.page_size) |n| {
            const s = std.fmt.bufPrint(&ps_buf, "{d}", .{n}) catch return RestError.OutOfMemory;
            try query.append(.{ .key = "pageSize", .value = s });
        }
        if (req.page_token) |s| try query.append(.{ .key = "pageToken", .value = s });

        const path = std.fmt.allocPrint(
            request_allocator,
            "/tasks/{s}/pushNotificationConfigs",
            .{req.task_id},
        ) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);
        const url = self.buildUrl(path, query.items) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .GET, url, headers, null);
        defer request_allocator.free(resp);

        const parsed = pb.v1.ListTaskPushNotificationConfigsResponse.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.listTaskPushNotificationConfigsResponseFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtDeletePushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.DeleteTaskPushNotificationConfigRequest,
    ) Transport.Error!void {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.deletePushConfigImpl(request_allocator, params, req) catch |err| mapErr(err);
    }

    fn deletePushConfigImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.DeleteTaskPushNotificationConfigRequest,
    ) RestError!void {
        const path = std.fmt.allocPrint(
            request_allocator,
            "/tasks/{s}/pushNotificationConfigs/{s}",
            .{ req.task_id, req.id },
        ) catch return RestError.OutOfMemory;
        defer request_allocator.free(path);
        const url = self.buildUrl(path, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .DELETE, url, headers, null);
        request_allocator.free(resp);
    }

    fn vtGetExtendedAgentCard(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        _: *const a2a.GetExtendedAgentCardRequest,
    ) Transport.Error!a2a.AgentCard {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
        return self.getExtendedAgentCardImpl(request_allocator, params) catch |err| mapErr(err);
    }

    fn getExtendedAgentCardImpl(
        self: *RestTransport,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
    ) RestError!a2a.AgentCard {
        const url = self.buildUrl(EXTENDED_AGENT_CARD_PATH, &.{}) catch return RestError.OutOfMemory;
        defer self.allocator.free(url);
        const headers = self.buildHeaders(params, "application/json") catch return RestError.OutOfMemory;
        defer self.allocator.free(headers);

        const resp = try self.fetch(request_allocator, .GET, url, headers, null);
        defer request_allocator.free(resp);

        const parsed = pb.v1.AgentCard.jsonDecode(resp, .{}, request_allocator) catch return RestError.InvalidResponse;
        defer parsed.deinit();
        return pb.conv.agentCardFromProto(request_allocator, parsed.value) catch RestError.OutOfMemory;
    }

    fn vtDestroy(ctx: *anyopaque) void {
        const self: *RestTransport = @ptrCast(@alignCast(ctx));
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

const QueryPair = struct {
    key: []const u8,
    value: []const u8,
};

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        const safe = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn mapErr(err: RestError) Transport.Error {
    return switch (err) {
        error.OutOfMemory => Transport.Error.OutOfMemory,
        error.UnexpectedToken => Transport.Error.UnexpectedToken,
        error.MissingField => Transport.Error.MissingField,
        else => Transport.Error.TransportError,
    };
}

fn mapStreamingFetchErr(err: streaming.FetchError) RestError {
    return switch (err) {
        error.OutOfMemory => RestError.OutOfMemory,
        error.HttpRequestFailed => RestError.HttpRequestFailed,
        error.HttpStatusError => RestError.HttpStatusError,
        error.ResponseTooLarge => RestError.InvalidResponse,
    };
}

// ---------------------------------------------------------------------------
// RestTransportFactory
// ---------------------------------------------------------------------------

pub const RestTransportFactory = struct {
    state: u8 = 0, // dummy field for `*anyopaque` round-trip

    pub fn factory(self: *RestTransportFactory) TransportFactory {
        return .{ .ctx = @ptrCast(self), .vtable = &factory_vtable };
    }

    fn vtProtocol(_: *anyopaque) []const u8 {
        return a2a.TRANSPORT_PROTOCOL_HTTP_JSON;
    }

    fn vtCreate(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: *const a2a.AgentCard,
        iface: *const a2a.AgentInterface,
    ) TransportFactory.Error!*Transport {
        const io = std.Io.Threaded.global_single_threaded.io();
        const rest = RestTransport.init(allocator, io, iface.url) catch return TransportFactory.Error.OutOfMemory;
        return rest.transport();
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

test "url encoding leaves safe chars alone" {
    const a = testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try writeUrlEncoded(&w.writer, "abcXYZ-_.~012");
    try testing.expectEqualStrings("abcXYZ-_.~012", w.written());
}

test "url encoding percent-encodes spaces and slashes" {
    const a = testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try writeUrlEncoded(&w.writer, "a b/c");
    try testing.expectEqualStrings("a%20b%2Fc", w.written());
}

test "trims base url trailing slashes" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var rest = try RestTransport.init(a, io, "http://localhost:3000///");
    defer rest.destroy();
    try testing.expectEqualStrings("http://localhost:3000", rest.base_url);
}

test "factory exposes HTTP+JSON protocol" {
    var f: RestTransportFactory = .{};
    const tf = f.factory();
    try testing.expectEqualStrings("HTTP+JSON", tf.protocol());
}

test "build url joins base, path, and query pairs" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var rest = try RestTransport.init(a, io, "http://localhost:3000");
    defer rest.destroy();

    const pairs = [_]QueryPair{
        .{ .key = "historyLength", .value = "10" },
        .{ .key = "context id", .value = "c=1" },
    };
    const url = try rest.buildUrl("/tasks", &pairs);
    defer a.free(url);
    try testing.expectEqualStrings(
        "http://localhost:3000/tasks?historyLength=10&context%20id=c%3D1",
        url,
    );
}
