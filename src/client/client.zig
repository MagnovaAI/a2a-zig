//! High-level A2A client: composes a `Transport` with a chain of
//! `CallInterceptor` middleware and seeds a default `ServiceParams` carrying
//! the protocol version. Each protocol method runs `before` hooks in
//! registration order, dispatches through the transport, then runs `after`
//! hooks in reverse — so wrappers nest cleanly around the call.
const std = @import("std");
const a2a = @import("a2a");
const transport_mod = @import("transport.zig");
const middleware_mod = @import("middleware.zig");

const Transport = transport_mod.Transport;
const StreamIterator = transport_mod.StreamIterator;
const ServiceParams = transport_mod.ServiceParams;
const CallInterceptor = middleware_mod.CallInterceptor;
const CallResult = middleware_mod.CallResult;
const log = std.log.scoped(.a2a_client);

pub const A2AClient = struct {
    pub const Error = Transport.Error || CallInterceptor.Error;

    allocator: std.mem.Allocator,
    transport: *Transport,
    /// Borrowed pointers; the caller owns the underlying interceptors and
    /// must keep them alive for the lifetime of this client.
    interceptors: []*CallInterceptor = &.{},
    default_params: ServiceParams,

    pub fn init(allocator: std.mem.Allocator, transport: *Transport) !A2AClient {
        var params = ServiceParams.init(allocator);
        errdefer params.deinit();
        try params.append(a2a.SVC_PARAM_VERSION, a2a.VERSION);
        return .{
            .allocator = allocator,
            .transport = transport,
            .default_params = params,
        };
    }

    pub fn deinit(self: *A2AClient) void {
        self.default_params.deinit();
        self.* = undefined;
    }

    /// Replace the interceptor chain. The slice must outlive the client.
    pub fn withInterceptors(self: *A2AClient, interceptors: []*CallInterceptor) void {
        self.interceptors = interceptors;
    }

    /// Build the per-call params: a clone of `default_params` walked through
    /// every `before` hook in registration order. Caller must `deinit` the
    /// returned params.
    fn applyBefore(self: *A2AClient, method: []const u8) !ServiceParams {
        var params = ServiceParams.init(self.allocator);
        errdefer params.deinit();

        var it = self.default_params.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |v| try params.append(entry.key_ptr.*, v);
        }

        for (self.interceptors) |interceptor| {
            try interceptor.before(method, &params);
        }
        return params;
    }

    /// Run the `after` hooks in reverse. The first error is logged; all
    /// hooks still run so each interceptor can clean up its state.
    fn applyAfter(self: *A2AClient, method: []const u8, result: CallResult) void {
        if (self.interceptors.len == 0) return;
        var i: usize = self.interceptors.len;
        while (i > 0) {
            i -= 1;
            self.interceptors[i].after(method, result) catch |err| {
                log.warn("interceptor `after` hook failed: method={s} err={s}", .{ method, @errorName(err) });
            };
        }
    }

    /// Build a CallResult from a Transport.Error, used when wrapping an
    /// errored dispatch into the after-hook signal.
    fn errorAsResult(err: Transport.Error) CallResult {
        return .{ .err = .{
            .code = a2a.code.INTERNAL_ERROR,
            .message = @errorName(err),
        } };
    }

    // -------------------------------------------------------------------
    // Protocol methods
    // -------------------------------------------------------------------

    pub fn sendMessage(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.SendMessageRequest,
    ) Error!a2a.SendMessageResponse {
        const method = a2a.methods.SEND_MESSAGE;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.sendMessage(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn sendStreamingMessage(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.SendMessageRequest,
    ) Error!StreamIterator {
        const method = a2a.methods.SEND_STREAMING_MESSAGE;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.sendStreamingMessage(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn getTask(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.GetTaskRequest,
    ) Error!a2a.Task {
        const method = a2a.methods.GET_TASK;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.getTask(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn listTasks(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.ListTasksRequest,
    ) Error!a2a.ListTasksResponse {
        const method = a2a.methods.LIST_TASKS;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.listTasks(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn cancelTask(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.CancelTaskRequest,
    ) Error!a2a.Task {
        const method = a2a.methods.CANCEL_TASK;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.cancelTask(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn subscribeToTask(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.SubscribeToTaskRequest,
    ) Error!StreamIterator {
        const method = a2a.methods.SUBSCRIBE_TO_TASK;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.subscribeToTask(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn createPushConfig(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.CreateTaskPushNotificationConfigRequest,
    ) Error!a2a.TaskPushNotificationConfig {
        const method = a2a.methods.CREATE_PUSH_CONFIG;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.createPushConfig(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn getPushConfig(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.GetTaskPushNotificationConfigRequest,
    ) Error!a2a.TaskPushNotificationConfig {
        const method = a2a.methods.GET_PUSH_CONFIG;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.getPushConfig(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn listPushConfigs(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.ListTaskPushNotificationConfigsRequest,
    ) Error!a2a.ListTaskPushNotificationConfigsResponse {
        const method = a2a.methods.LIST_PUSH_CONFIGS;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.listPushConfigs(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }

    pub fn deletePushConfig(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.DeleteTaskPushNotificationConfigRequest,
    ) Error!void {
        const method = a2a.methods.DELETE_PUSH_CONFIG;
        var params = try self.applyBefore(method);
        defer params.deinit();
        self.transport.deletePushConfig(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
    }

    pub fn getExtendedAgentCard(
        self: *A2AClient,
        request_allocator: std.mem.Allocator,
        req: *const a2a.GetExtendedAgentCardRequest,
    ) Error!a2a.AgentCard {
        const method = a2a.methods.GET_EXTENDED_AGENT_CARD;
        var params = try self.applyBefore(method);
        defer params.deinit();
        const result = self.transport.getExtendedAgentCard(request_allocator, &params, req) catch |err| {
            self.applyAfter(method, errorAsResult(err));
            return err;
        };
        self.applyAfter(method, .ok);
        return result;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Stub transport that records every call for assertions.
const RecorderState = struct {
    last_method: []const u8 = "",
    last_params_count: usize = 0,
    fail_next: bool = false,
};

fn recSendMessage(
    ctx: *anyopaque,
    request_allocator: std.mem.Allocator,
    params: *const ServiceParams,
    _: *const a2a.SendMessageRequest,
) Transport.Error!a2a.SendMessageResponse {
    const state: *RecorderState = @ptrCast(@alignCast(ctx));
    state.last_method = "SendMessage";
    state.last_params_count = params.count();
    if (state.fail_next) {
        state.fail_next = false;
        return Transport.Error.TransportError;
    }
    var task = a2a.Task{
        .id = try request_allocator.dupe(u8, "t-stub"),
        .context_id = try request_allocator.dupe(u8, "c-stub"),
        .status = .{ .state = .submitted, .allocator = request_allocator },
        .allocator = request_allocator,
    };
    _ = &task;
    return a2a.SendMessageResponse{ .task = task };
}

fn recGetTask(
    ctx: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    req: *const a2a.GetTaskRequest,
) Transport.Error!a2a.Task {
    const state: *RecorderState = @ptrCast(@alignCast(ctx));
    state.last_method = "GetTask";
    return a2a.Task{
        .id = try request_allocator.dupe(u8, req.id),
        .context_id = try request_allocator.dupe(u8, "ctx"),
        .status = .{ .state = .working, .allocator = request_allocator },
        .allocator = request_allocator,
    };
}

fn recUnimplementedStream(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *const ServiceParams,
    _: *const a2a.SendMessageRequest,
) Transport.Error!StreamIterator {
    return Transport.Error.TransportError;
}

fn recUnimplementedSub(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *const ServiceParams,
    _: *const a2a.SubscribeToTaskRequest,
) Transport.Error!StreamIterator {
    return Transport.Error.TransportError;
}

fn recListTasks(
    _: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    _: *const a2a.ListTasksRequest,
) Transport.Error!a2a.ListTasksResponse {
    const tasks = try request_allocator.alloc(a2a.Task, 0);
    return .{
        .tasks = tasks,
        .next_page_token = try request_allocator.dupe(u8, ""),
        .page_size = 0,
        .total_size = 0,
        .allocator = request_allocator,
    };
}

fn recCancelTask(
    _: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    req: *const a2a.CancelTaskRequest,
) Transport.Error!a2a.Task {
    return a2a.Task{
        .id = try request_allocator.dupe(u8, req.id),
        .context_id = try request_allocator.dupe(u8, ""),
        .status = .{ .state = .canceled, .allocator = request_allocator },
        .allocator = request_allocator,
    };
}

fn recCreatePushConfig(
    _: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    req: *const a2a.CreateTaskPushNotificationConfigRequest,
) Transport.Error!a2a.TaskPushNotificationConfig {
    return .{
        .task_id = try request_allocator.dupe(u8, req.task_id),
        .config = .{
            .url = try request_allocator.dupe(u8, req.config.url),
            .allocator = request_allocator,
        },
        .allocator = request_allocator,
    };
}

fn recGetPushConfig(
    _: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    req: *const a2a.GetTaskPushNotificationConfigRequest,
) Transport.Error!a2a.TaskPushNotificationConfig {
    return .{
        .task_id = try request_allocator.dupe(u8, req.task_id),
        .config = .{
            .url = try request_allocator.dupe(u8, "https://example.com"),
            .allocator = request_allocator,
        },
        .allocator = request_allocator,
    };
}

fn recListPushConfigs(
    _: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    _: *const a2a.ListTaskPushNotificationConfigsRequest,
) Transport.Error!a2a.ListTaskPushNotificationConfigsResponse {
    const configs = try request_allocator.alloc(a2a.TaskPushNotificationConfig, 0);
    return .{
        .configs = configs,
        .allocator = request_allocator,
    };
}

fn recDeletePushConfig(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *const ServiceParams,
    _: *const a2a.DeleteTaskPushNotificationConfigRequest,
) Transport.Error!void {}

fn recGetExtendedAgentCard(
    _: *anyopaque,
    request_allocator: std.mem.Allocator,
    _: *const ServiceParams,
    _: *const a2a.GetExtendedAgentCardRequest,
) Transport.Error!a2a.AgentCard {
    return .{
        .name = try request_allocator.dupe(u8, "stub"),
        .description = try request_allocator.dupe(u8, "stub"),
        .version = try request_allocator.dupe(u8, "1.0"),
        .supported_interfaces = try request_allocator.alloc(a2a.AgentInterface, 0),
        .capabilities = a2a.AgentCapabilities.default(request_allocator),
        .default_input_modes = try request_allocator.alloc([]const u8, 0),
        .default_output_modes = try request_allocator.alloc([]const u8, 0),
        .skills = try request_allocator.alloc(a2a.AgentSkill, 0),
        .allocator = request_allocator,
    };
}

fn recDestroy(_: *anyopaque) void {}

const recorder_vtable: Transport.VTable = .{
    .send_message = recSendMessage,
    .send_streaming_message = recUnimplementedStream,
    .get_task = recGetTask,
    .list_tasks = recListTasks,
    .cancel_task = recCancelTask,
    .subscribe_to_task = recUnimplementedSub,
    .create_push_config = recCreatePushConfig,
    .get_push_config = recGetPushConfig,
    .list_push_configs = recListPushConfigs,
    .delete_push_config = recDeletePushConfig,
    .get_extended_agent_card = recGetExtendedAgentCard,
    .destroy = recDestroy,
};

fn makeRecorder(state: *RecorderState) Transport {
    return .{ .ctx = @ptrCast(state), .vtable = &recorder_vtable };
}

// CountingInterceptor: records before/after invocations for ordering tests.
const CountingState = struct {
    name: []const u8,
    log: *std.array_list.Managed([]const u8),
    allocator: std.mem.Allocator,
};

fn countingBefore(ctx: *anyopaque, _: []const u8, _: *ServiceParams) CallInterceptor.Error!void {
    const state: *CountingState = @ptrCast(@alignCast(ctx));
    const entry = std.fmt.allocPrint(state.allocator, "before:{s}", .{state.name}) catch return error.OutOfMemory;
    state.log.append(entry) catch return error.OutOfMemory;
}

fn countingAfter(ctx: *anyopaque, _: []const u8, _: CallResult) CallInterceptor.Error!void {
    const state: *CountingState = @ptrCast(@alignCast(ctx));
    const entry = std.fmt.allocPrint(state.allocator, "after:{s}", .{state.name}) catch return error.OutOfMemory;
    state.log.append(entry) catch return error.OutOfMemory;
}

const counting_vtable: CallInterceptor.VTable = .{
    .before = countingBefore,
    .after = countingAfter,
};

fn makeCountingInterceptor(state: *CountingState) CallInterceptor {
    return .{ .ctx = @ptrCast(state), .vtable = &counting_vtable };
}

test "default params seeds A2A-Version" {
    const a = testing.allocator;
    var state: RecorderState = .{};
    var t = makeRecorder(&state);
    var client = try A2AClient.init(a, &t);
    defer client.deinit();

    const ver = client.default_params.get(a2a.SVC_PARAM_VERSION).?;
    try testing.expectEqual(@as(usize, 1), ver.len);
    try testing.expectEqualStrings(a2a.VERSION, ver[0]);
}

test "send_message dispatches and surfaces the version param" {
    const a = testing.allocator;
    var state: RecorderState = .{};
    var t = makeRecorder(&state);
    var client = try A2AClient.init(a, &t);
    defer client.deinit();

    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "hi");
    var req = a2a.SendMessageRequest{
        .message = try a2a.Message.init(a, .user, parts),
        .allocator = a,
    };
    defer req.deinit();

    var resp = try client.sendMessage(a, &req);
    defer resp.deinit();

    try testing.expectEqualStrings("SendMessage", state.last_method);
    // default_params has 1 entry (A2A-Version) so the count is 1.
    try testing.expectEqual(@as(usize, 1), state.last_params_count);
}

test "interceptor before hook can mutate params for one call" {
    const a = testing.allocator;
    var state: RecorderState = .{};
    var t = makeRecorder(&state);
    var client = try A2AClient.init(a, &t);
    defer client.deinit();

    var entries: std.array_list.Managed([]const u8) = .init(a);
    defer {
        for (entries.items) |s| a.free(s);
        entries.deinit();
    }

    var c1: CountingState = .{ .name = "c1", .log = &entries, .allocator = a };
    var c2: CountingState = .{ .name = "c2", .log = &entries, .allocator = a };
    var i_a = makeCountingInterceptor(&c1);
    var i_b = makeCountingInterceptor(&c2);
    var pointers = [_]*CallInterceptor{ &i_a, &i_b };
    client.withInterceptors(&pointers);

    const req = a2a.GetTaskRequest{ .id = try a.dupe(u8, "t-1"), .allocator = a };
    var req_local = req;
    defer req_local.deinit();
    var task = try client.getTask(a, &req_local);
    defer task.deinit();

    // Before runs in registration order; after runs in reverse.
    try testing.expectEqual(@as(usize, 4), entries.items.len);
    try testing.expectEqualStrings("before:c1", entries.items[0]);
    try testing.expectEqualStrings("before:c2", entries.items[1]);
    try testing.expectEqualStrings("after:c2", entries.items[2]);
    try testing.expectEqualStrings("after:c1", entries.items[3]);
}

test "transport error still runs after hooks" {
    const a = testing.allocator;
    var state: RecorderState = .{ .fail_next = true };
    var t = makeRecorder(&state);
    var client = try A2AClient.init(a, &t);
    defer client.deinit();

    var entries: std.array_list.Managed([]const u8) = .init(a);
    defer {
        for (entries.items) |s| a.free(s);
        entries.deinit();
    }
    var c1: CountingState = .{ .name = "x", .log = &entries, .allocator = a };
    var i_a = makeCountingInterceptor(&c1);
    var pointers = [_]*CallInterceptor{&i_a};
    client.withInterceptors(&pointers);

    const parts = try a.alloc(a2a.Part, 0);
    var req = a2a.SendMessageRequest{
        .message = try a2a.Message.init(a, .user, parts),
        .allocator = a,
    };
    defer req.deinit();

    const result = client.sendMessage(a, &req);
    try testing.expectError(Transport.Error.TransportError, result);

    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqualStrings("before:x", entries.items[0]);
    try testing.expectEqualStrings("after:x", entries.items[1]);
}
