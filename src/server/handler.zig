//! Transport-agnostic request handler.
//!
//! `RequestHandler` is the vtable every protocol binding (JSON-RPC, REST,
//! gRPC down the line) calls into. `DefaultRequestHandler` ships the
//! standard implementation that ties together the executor, task store,
//! push config store, push sender, and execution manager:
//!
//!   * unary methods (`getTask`, `cancelTask`, push CRUD, ...) run inline
//!     on the calling thread and return a fully-formed response.
//!   * streaming methods (`sendStreamingMessage`, `subscribeToTask`) hand
//!     the caller a `StreamIterator` backed by a broadcast subscription.
//!     A worker thread drives the underlying executor, persists each
//!     event to the task store, fans push notifications out, and
//!     publishes the event to the bus.
//!
//! Memory model: every method takes a `request_allocator` that owns the
//! response. Long-lived state (the active execution registry, the worker
//! thread's snapshot) lives in the handler's storage allocator.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");

const middleware = @import("middleware.zig");
const exec_mod = @import("executor.zig");
const task_store_mod = @import("task_store/store.zig");
const execution_mod = @import("execution.zig");
const push_store = @import("push/store.zig");
const push_sender = @import("push/sender.zig");

const log = std.log.scoped(.a2a_server);

const ServiceParams = middleware.ServiceParams;
const AgentExecutor = exec_mod.AgentExecutor;
const ExecutorContext = exec_mod.ExecutorContext;
const StreamIterator = a2a.StreamIterator;
const TaskStore = task_store_mod.TaskStore;
const PushConfigStore = push_store.PushConfigStore;
const HttpPushSender = push_sender.HttpPushSender;
const ActiveExecution = execution_mod.ActiveExecution;
const ExecutionEvent = execution_mod.ExecutionEvent;
const ExecutionManager = execution_mod.ExecutionManager;

// ---------------------------------------------------------------------------
// RequestHandler — vtable consumed by every protocol binding
// ---------------------------------------------------------------------------

pub const RequestHandler = struct {
    pub const Error = error{
        OutOfMemory,
        ExecutorFailed,
        StorageFailed,
        TaskNotFound,
        TaskNotCancelable,
        PushNotificationNotSupported,
        UnsupportedOperation,
        InvalidArgument,
        InternalError,
    };

    pub const VTable = struct {
        sendMessage: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.SendMessageRequest,
        ) Error!a2a.SendMessageResponse,

        sendStreamingMessage: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.SendMessageRequest,
        ) Error!StreamIterator,

        getTask: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.GetTaskRequest,
        ) Error!a2a.Task,

        listTasks: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.ListTasksRequest,
        ) Error!a2a.ListTasksResponse,

        cancelTask: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.CancelTaskRequest,
        ) Error!a2a.Task,

        subscribeToTask: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.SubscribeToTaskRequest,
        ) Error!StreamIterator,

        createPushConfig: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.CreateTaskPushNotificationConfigRequest,
        ) Error!a2a.TaskPushNotificationConfig,

        getPushConfig: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.GetTaskPushNotificationConfigRequest,
        ) Error!a2a.TaskPushNotificationConfig,

        listPushConfigs: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.ListTaskPushNotificationConfigsRequest,
        ) Error!a2a.ListTaskPushNotificationConfigsResponse,

        deletePushConfig: *const fn (
            ctx: *anyopaque,
            params: *const ServiceParams,
            req: a2a.DeleteTaskPushNotificationConfigRequest,
        ) Error!void,

        getExtendedAgentCard: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: a2a.GetExtendedAgentCardRequest,
        ) Error!a2a.AgentCard,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn sendMessage(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.SendMessageRequest,
    ) Error!a2a.SendMessageResponse {
        return self.vtable.sendMessage(self.ctx, request_allocator, params, req);
    }

    pub fn sendStreamingMessage(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.SendMessageRequest,
    ) Error!StreamIterator {
        return self.vtable.sendStreamingMessage(self.ctx, request_allocator, params, req);
    }

    pub fn getTask(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.GetTaskRequest,
    ) Error!a2a.Task {
        return self.vtable.getTask(self.ctx, request_allocator, params, req);
    }

    pub fn listTasks(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.ListTasksRequest,
    ) Error!a2a.ListTasksResponse {
        return self.vtable.listTasks(self.ctx, request_allocator, params, req);
    }

    pub fn cancelTask(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.CancelTaskRequest,
    ) Error!a2a.Task {
        return self.vtable.cancelTask(self.ctx, request_allocator, params, req);
    }

    pub fn subscribeToTask(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.SubscribeToTaskRequest,
    ) Error!StreamIterator {
        return self.vtable.subscribeToTask(self.ctx, request_allocator, params, req);
    }

    pub fn createPushConfig(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.CreateTaskPushNotificationConfigRequest,
    ) Error!a2a.TaskPushNotificationConfig {
        return self.vtable.createPushConfig(self.ctx, request_allocator, params, req);
    }

    pub fn getPushConfig(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.GetTaskPushNotificationConfigRequest,
    ) Error!a2a.TaskPushNotificationConfig {
        return self.vtable.getPushConfig(self.ctx, request_allocator, params, req);
    }

    pub fn listPushConfigs(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.ListTaskPushNotificationConfigsRequest,
    ) Error!a2a.ListTaskPushNotificationConfigsResponse {
        return self.vtable.listPushConfigs(self.ctx, request_allocator, params, req);
    }

    pub fn deletePushConfig(
        self: *const RequestHandler,
        params: *const ServiceParams,
        req: a2a.DeleteTaskPushNotificationConfigRequest,
    ) Error!void {
        return self.vtable.deletePushConfig(self.ctx, params, req);
    }

    pub fn getExtendedAgentCard(
        self: *const RequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.GetExtendedAgentCardRequest,
    ) Error!a2a.AgentCard {
        return self.vtable.getExtendedAgentCard(self.ctx, request_allocator, params, req);
    }
};

// ---------------------------------------------------------------------------
// DefaultRequestHandler — standard implementation
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Default page size when a list call doesn't supply one.
    default_page_size: usize = 50,
};

pub const DefaultRequestHandler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    executor: AgentExecutor,
    task_store: TaskStore,
    execution_manager: ExecutionManager,
    push_config_store: ?PushConfigStore = null,
    push_sender: ?*HttpPushSender = null,
    capabilities: ?a2a.AgentCapabilities = null,
    extended_card: ?a2a.AgentCard = null,
    options: Options = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        executor: AgentExecutor,
        task_store: TaskStore,
    ) DefaultRequestHandler {
        return .{
            .allocator = allocator,
            .io = io,
            .executor = executor,
            .task_store = task_store,
            .execution_manager = ExecutionManager.init(allocator, io),
        };
    }

    pub fn deinit(self: *DefaultRequestHandler) void {
        self.execution_manager.deinit();
        if (self.extended_card) |*c| c.deinit();
        self.* = undefined;
    }

    /// Wrap this handler in the protocol-binding-agnostic vtable interface.
    pub fn handler(self: *DefaultRequestHandler) RequestHandler {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    /// Configure push-notification support. Pass the persistence backend and
    /// optionally a custom sender. When `sender` is null, the handler still
    /// accepts CRUD on push configs but does not deliver webhooks.
    pub fn withPushSupport(
        self: *DefaultRequestHandler,
        push_cfg_store: PushConfigStore,
        sender: ?*HttpPushSender,
    ) void {
        self.push_config_store = push_cfg_store;
        self.push_sender = sender;
    }

    /// Replace the agent capabilities reported by the handler. The default
    /// handler does not actually expose capabilities directly — they're
    /// surfaced through the `AgentCard`. Storing them here lets callers
    /// query the runtime configuration in tests.
    pub fn setCapabilities(self: *DefaultRequestHandler, caps: a2a.AgentCapabilities) void {
        self.capabilities = caps;
    }

    /// Provide the extended `AgentCard` returned from `getExtendedAgentCard`.
    /// Ownership transfers to the handler.
    pub fn setExtendedCard(self: *DefaultRequestHandler, card: a2a.AgentCard) void {
        if (self.extended_card) |*c| c.deinit();
        self.extended_card = card;
    }

    // ---------- shared helpers ----------

    fn loadTask(
        self: *DefaultRequestHandler,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
    ) RequestHandler.Error!a2a.Task {
        const got = self.task_store.get(request_allocator, task_id) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        };
        return got orelse RequestHandler.Error.TaskNotFound;
    }

    /// Persist a task: try `update`, fall back to `create` on `NotFound`.
    fn saveTask(
        self: *DefaultRequestHandler,
        request_allocator: std.mem.Allocator,
        task: *const a2a.Task,
    ) RequestHandler.Error!void {
        if (self.task_store.update(request_allocator, task)) |_| {
            return;
        } else |err| switch (err) {
            error.NotFound => {
                _ = self.task_store.create(request_allocator, task) catch |create_err| switch (create_err) {
                    error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
                    else => return RequestHandler.Error.StorageFailed,
                };
            },
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        }
    }

    fn pushStoreOrErr(self: *DefaultRequestHandler) RequestHandler.Error!*const PushConfigStore {
        if (self.push_config_store) |*s| return s;
        return RequestHandler.Error.PushNotificationNotSupported;
    }

    /// Fan an event out to every push config registered for `task_id`. The
    /// sender's `fail_on_error` setting controls whether transport failures
    /// abort the in-flight execution. We always log on failure.
    fn deliverPushNotifications(
        self: *DefaultRequestHandler,
        task_id: []const u8,
        event: a2a.StreamResponse,
    ) RequestHandler.Error!void {
        const store = self.push_config_store orelse return;
        const sender = self.push_sender orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const configs = store.list(aa, task_id) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return,
        };
        for (configs) |*cfg| {
            sender.send(cfg, event) catch |err| switch (err) {
                error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
                error.DeliveryFailed => return RequestHandler.Error.InternalError,
            };
        }
    }

    /// Apply a stream event to the persisted task representation. Returns the
    /// (request-allocated) updated task, or null when the event doesn't
    /// affect persistent state (`message`, `unknown`).
    fn applyEventToTask(
        self: *DefaultRequestHandler,
        request_allocator: std.mem.Allocator,
        current: ?a2a.Task,
        event: a2a.StreamResponse,
    ) RequestHandler.Error!?a2a.Task {
        switch (event) {
            .task => |t| {
                const cloned = cloneTask(request_allocator, t) catch return RequestHandler.Error.OutOfMemory;
                try self.saveTask(request_allocator, &cloned);
                return cloned;
            },
            .status_update => |upd| {
                var base = if (current) |c|
                    cloneTask(request_allocator, c) catch return RequestHandler.Error.OutOfMemory
                else b: {
                    const got = self.task_store.get(request_allocator, upd.task_id) catch |err| switch (err) {
                        error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
                        else => return RequestHandler.Error.StorageFailed,
                    };
                    break :b got orelse return RequestHandler.Error.TaskNotFound;
                };
                errdefer base.deinit();
                base.status.deinit();
                base.status = cloneStatus(request_allocator, upd.status) catch return RequestHandler.Error.OutOfMemory;
                try self.saveTask(request_allocator, &base);
                return base;
            },
            .artifact_update => |upd| {
                var base = if (current) |c|
                    cloneTask(request_allocator, c) catch return RequestHandler.Error.OutOfMemory
                else b: {
                    const got = self.task_store.get(request_allocator, upd.task_id) catch |err| switch (err) {
                        error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
                        else => return RequestHandler.Error.StorageFailed,
                    };
                    break :b got orelse return RequestHandler.Error.TaskNotFound;
                };
                errdefer base.deinit();
                const new_artifact = cloneArtifact(request_allocator, upd.artifact) catch return RequestHandler.Error.OutOfMemory;
                appendArtifact(request_allocator, &base, new_artifact) catch return RequestHandler.Error.OutOfMemory;
                try self.saveTask(request_allocator, &base);
                return base;
            },
            .message, .unknown => return null,
        }
    }

    // ---------- send_message / send_streaming_message ----------

    /// Initialize task state for a `sendMessage` call.
    /// Returns (task, stored, context_id) in the request scope. `task` is
    /// the canonical state we hand to the executor and seed the active
    /// execution with; `stored` is the prior state if one existed (for the
    /// executor to inspect).
    fn prepareTaskForExecution(
        self: *DefaultRequestHandler,
        request_allocator: std.mem.Allocator,
        req: *const a2a.SendMessageRequest,
    ) RequestHandler.Error!struct {
        task: a2a.Task,
        stored: ?a2a.Task,
        context_id: []const u8,
    } {
        const task_id_owned = if (req.message.task_id) |s|
            request_allocator.dupe(u8, s) catch return RequestHandler.Error.OutOfMemory
        else
            a2a.newTaskId(request_allocator) catch return RequestHandler.Error.OutOfMemory;
        errdefer request_allocator.free(task_id_owned);

        const stored = self.task_store.get(request_allocator, task_id_owned) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        };

        const context_id = ctx: {
            if (stored) |s| break :ctx request_allocator.dupe(u8, s.context_id) catch return RequestHandler.Error.OutOfMemory;
            if (req.message.context_id) |s| break :ctx request_allocator.dupe(u8, s) catch return RequestHandler.Error.OutOfMemory;
            break :ctx a2a.newContextId(request_allocator) catch return RequestHandler.Error.OutOfMemory;
        };
        errdefer request_allocator.free(context_id);

        if (stored) |s| {
            const task = cloneTask(request_allocator, s) catch return RequestHandler.Error.OutOfMemory;
            request_allocator.free(task_id_owned);
            return .{ .task = task, .stored = s, .context_id = context_id };
        }

        // No prior task — synthesize a fresh "submitted" record and persist it.
        const initial_history = request_allocator.alloc(a2a.Message, 1) catch return RequestHandler.Error.OutOfMemory;
        initial_history[0] = cloneMessage(request_allocator, req.message) catch return RequestHandler.Error.OutOfMemory;

        var task: a2a.Task = .{
            .id = task_id_owned,
            .context_id = request_allocator.dupe(u8, context_id) catch return RequestHandler.Error.OutOfMemory,
            .status = .{ .state = .submitted, .allocator = request_allocator },
            .history = initial_history,
            .allocator = request_allocator,
        };
        defer task.deinit();

        _ = self.task_store.create(request_allocator, &task) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        };

        const cloned = cloneTask(request_allocator, task) catch return RequestHandler.Error.OutOfMemory;
        return .{ .task = cloned, .stored = null, .context_id = context_id };
    }

    /// Persist any push config attached to the inbound request so it gets
    /// hit during execution.
    fn saveRequestPushConfig(
        self: *DefaultRequestHandler,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
        req: *const a2a.SendMessageRequest,
    ) RequestHandler.Error!void {
        const cfg_opt = if (req.configuration) |c| c.push_notification_config else null;
        const cfg = cfg_opt orelse return;
        const store = try self.pushStoreOrErr();
        var saved = store.save(request_allocator, task_id, &cfg) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            error.InvalidArgument => return RequestHandler.Error.InvalidArgument,
            else => return RequestHandler.Error.StorageFailed,
        };
        saved.deinit();
    }

    /// Drive a single executor step-by-step, persisting and publishing each
    /// event. Runs on the calling thread (for unary `sendMessage`) or on a
    /// worker thread (for streaming).
    fn driveExecution(
        self: *DefaultRequestHandler,
        active: *ActiveExecution,
        exec_ctx: *ExecutorContext,
        cancel_path: bool,
    ) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var stream = if (cancel_path)
            self.executor.cancel(aa, exec_ctx) catch |err| {
                publishError(active, err);
                return;
            }
        else
            self.executor.execute(aa, exec_ctx) catch |err| {
                publishError(active, err);
                return;
            };
        defer stream.deinit();

        var current_task: ?a2a.Task = active.snapshotClone(aa) catch null;
        defer if (current_task) |*t| t.deinit();

        while (true) {
            if (active.isTerminal()) break;
            const next = stream.next() catch |err| {
                publishError(active, err);
                break;
            };
            const event = next orelse break;

            // The event pulled from the executor is owned by `aa` (request
            // arena). Keep a deep clone we can hand to the bus + the apply
            // step independently.
            var step_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer step_arena.deinit();
            const sa = step_arena.allocator();
            const event_for_apply = cloneStreamResponse(sa, event) catch {
                publishError(active, error.OutOfMemory);
                break;
            };
            var event_for_bus = cloneStreamResponse(self.allocator, event) catch {
                publishError(active, error.OutOfMemory);
                break;
            };

            const updated = self.applyEventToTask(sa, current_task, event_for_apply) catch |err| {
                event_for_bus.deinit();
                publishError(active, err);
                break;
            };

            self.deliverPushNotifications(exec_ctx.task_id, event_for_apply) catch |err| {
                event_for_bus.deinit();
                publishError(active, err);
                break;
            };

            // Adopt the new snapshot into our locally tracked clone.
            if (updated) |u| {
                if (current_task) |*old| old.deinit();
                current_task = cloneTask(self.allocator, u) catch null;
            }

            // Hand the event-for-bus into the broadcaster (ownership transfers).
            // If the publish fails we have to free it ourselves.
            const new_snapshot: ?a2a.Task = if (updated) |u| cloneTask(self.allocator, u) catch null else null;
            active.publish(.{ .ok = event_for_bus }, new_snapshot) catch {
                event_for_bus.deinit();
                if (new_snapshot) |s| {
                    var v = s;
                    v.deinit();
                }
                break;
            };

            if (isTerminalEvent(event_for_apply)) break;
        }
    }

    fn startExecution(
        self: *DefaultRequestHandler,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.SendMessageRequest,
        include_task_snapshot_in_context: bool,
    ) RequestHandler.Error!ExecutionStart {
        var owned_req = req; // local
        defer owned_req.deinit();

        var prep = try self.prepareTaskForExecution(request_allocator, &owned_req);
        defer {
            prep.task.deinit();
            if (prep.stored) |*s| s.deinit();
            request_allocator.free(prep.context_id);
        }

        try self.saveRequestPushConfig(request_allocator, prep.task.id, &owned_req);

        // Start tracking this execution.
        var manager_seed = cloneTask(self.allocator, prep.task) catch return RequestHandler.Error.OutOfMemory;
        const active = self.execution_manager.start(manager_seed) catch |err| switch (err) {
            error.AlreadyRunning => {
                manager_seed.deinit();
                return RequestHandler.Error.InvalidArgument;
            },
            error.OutOfMemory => {
                manager_seed.deinit();
                return RequestHandler.Error.OutOfMemory;
            },
        };
        // Manager took its own deep clone, so free our seed.
        manager_seed.deinit();

        // Build the executor context (request-allocated copies). Use a
        // shared, separately-tracked task id so the request scope can free
        // it independently of `exec_ctx.deinit()`.
        const task_id_for_request = request_allocator.dupe(u8, prep.task.id) catch return RequestHandler.Error.OutOfMemory;

        var exec_ctx = ExecutorContext{
            .message = cloneMessage(request_allocator, owned_req.message) catch return RequestHandler.Error.OutOfMemory,
            .task_id = request_allocator.dupe(u8, prep.task.id) catch return RequestHandler.Error.OutOfMemory,
            .stored_task = if (include_task_snapshot_in_context) cloneTask(request_allocator, prep.task) catch null else if (prep.stored) |s| cloneTask(request_allocator, s) catch null else null,
            .context_id = request_allocator.dupe(u8, prep.context_id) catch return RequestHandler.Error.OutOfMemory,
            .metadata = null,
            .user = null,
            .service_params = ServiceParams.init(request_allocator),
            .tenant = if (owned_req.tenant) |t| request_allocator.dupe(u8, t) catch null else null,
            .allocator = request_allocator,
        };
        var it = params.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |v| {
                exec_ctx.service_params.append(entry.key_ptr.*, v) catch break;
            }
        }

        return .{ .task_id_owned = task_id_for_request, .active = active, .exec_ctx = exec_ctx };
    }

    // ---------- vtable wrappers ----------

    fn vSendMessage(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.SendMessageRequest,
    ) RequestHandler.Error!a2a.SendMessageResponse {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));

        const interrupt_immediately = if (req.configuration) |c|
            (c.return_immediately orelse false)
        else
            false;

        var start = try self.startExecution(request_allocator, params, req, true);
        defer {
            self.execution_manager.finish(start.task_id_owned, start.active);
            request_allocator.free(start.task_id_owned);
            start.exec_ctx.deinit();
        }

        // Subscribe BEFORE starting the executor so we don't miss events.
        const sub = start.active.subscribe() catch return RequestHandler.Error.OutOfMemory;
        defer sub.unsubscribe();

        // Drive the executor inline.
        self.driveExecution(start.active, &start.exec_ctx, false);

        // Drain events and pick the response per A2A semantics.
        var last_task_id: ?[]const u8 = null;
        var last_message: ?a2a.Message = null;
        defer if (last_message) |*m| m.deinit();
        while (sub.tryNext()) |ev| {
            var event = ev;
            switch (event.result) {
                .err => |e| {
                    event.allocator.free(e.message);
                    return mapErrorCode(e.code);
                },
                .ok => |sr| {
                    if (interrupt_immediately) {
                        if (taskIdFromEvent(sr)) |tid| {
                            last_task_id = request_allocator.dupe(u8, tid) catch null;
                            event.result.ok.deinit();
                            // Finish draining without further processing.
                            while (sub.tryNext()) |skip_ev| {
                                var skip = skip_ev;
                                execution_mod.deinitEvent(skip.allocator, &skip);
                            }
                            break;
                        }
                    }
                    switch (sr) {
                        .message => |m| {
                            // last_message gets the cloned message; drop sr's task_id memory.
                            if (last_message) |*old| old.deinit();
                            last_message = cloneMessage(request_allocator, m) catch null;
                        },
                        .task => |t| last_task_id = request_allocator.dupe(u8, t.id) catch null,
                        .status_update => |u| last_task_id = request_allocator.dupe(u8, u.task_id) catch null,
                        .artifact_update => |u| last_task_id = request_allocator.dupe(u8, u.task_id) catch null,
                        .unknown => {},
                    }
                    event.result.ok.deinit();
                },
            }
        }

        if (last_message) |m| {
            last_message = null;
            return .{ .message = m };
        }
        if (last_task_id) |tid| {
            defer request_allocator.free(tid);
            const t = try self.loadTask(request_allocator, tid);
            return .{ .task = t };
        }
        const t = try self.loadTask(request_allocator, start.task_id_owned);
        return .{ .task = t };
    }

    fn vSendStreamingMessage(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.SendMessageRequest,
    ) RequestHandler.Error!StreamIterator {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var start = try self.startExecution(request_allocator, params, req, false);
        const sub = start.active.subscribe() catch {
            self.execution_manager.finish(start.task_id_owned, start.active);
            request_allocator.free(start.task_id_owned);
            start.exec_ctx.deinit();
            return RequestHandler.Error.OutOfMemory;
        };

        // Hand the executor over to a worker thread so the caller can pull
        // events as they're produced.
        const worker = self.allocator.create(Worker) catch {
            sub.unsubscribe();
            self.execution_manager.finish(start.task_id_owned, start.active);
            request_allocator.free(start.task_id_owned);
            start.exec_ctx.deinit();
            return RequestHandler.Error.OutOfMemory;
        };
        worker.* = .{
            .handler = self,
            .active = start.active,
            .exec_ctx = start.exec_ctx,
            .task_id_owned = start.task_id_owned,
            .request_allocator = request_allocator,
            .cancel_path = false,
        };
        const thread = std.Thread.spawn(.{}, Worker.run, .{worker}) catch {
            self.allocator.destroy(worker);
            sub.unsubscribe();
            self.execution_manager.finish(start.task_id_owned, start.active);
            request_allocator.free(start.task_id_owned);
            start.exec_ctx.deinit();
            return RequestHandler.Error.OutOfMemory;
        };
        worker.thread = thread;

        return makeSubscriptionIterator(self.allocator, sub);
    }

    fn vGetTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.GetTaskRequest,
    ) RequestHandler.Error!a2a.Task {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        return self.loadTask(request_allocator, owned.id);
    }

    fn vListTasks(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.ListTasksRequest,
    ) RequestHandler.Error!a2a.ListTasksResponse {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        return self.task_store.list(request_allocator, &owned) catch |err| switch (err) {
            error.OutOfMemory => RequestHandler.Error.OutOfMemory,
            else => RequestHandler.Error.StorageFailed,
        };
    }

    fn vCancelTask(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: a2a.CancelTaskRequest,
    ) RequestHandler.Error!a2a.Task {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned_req = req;
        defer owned_req.deinit();
        const req_ref = &owned_req;

        var task = try self.loadTask(request_allocator, req_ref.id);
        defer task.deinit();
        if (task.status.state.isTerminal()) return RequestHandler.Error.TaskNotCancelable;

        const active_opt = self.execution_manager.get(req_ref.id);
        if (active_opt) |a| a.requestCancel();

        var exec_ctx = ExecutorContext{
            .message = null,
            .task_id = request_allocator.dupe(u8, req_ref.id) catch return RequestHandler.Error.OutOfMemory,
            .stored_task = cloneTask(request_allocator, task) catch null,
            .context_id = request_allocator.dupe(u8, task.context_id) catch return RequestHandler.Error.OutOfMemory,
            .metadata = null,
            .user = null,
            .service_params = ServiceParams.init(request_allocator),
            .tenant = if (req_ref.tenant) |t| request_allocator.dupe(u8, t) catch null else null,
            .allocator = request_allocator,
        };
        defer exec_ctx.deinit();
        var it = params.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |v| {
                exec_ctx.service_params.append(entry.key_ptr.*, v) catch break;
            }
        }

        var stream = self.executor.cancel(request_allocator, &exec_ctx) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            error.ExecutorFailed => return RequestHandler.Error.ExecutorFailed,
        };
        defer stream.deinit();

        var current: ?a2a.Task = cloneTask(request_allocator, task) catch null;
        defer if (current) |*t| t.deinit();

        while (true) {
            const ev = stream.next() catch |err| switch (err) {
                error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
                else => return RequestHandler.Error.ExecutorFailed,
            };
            const event = ev orelse break;

            var apply_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer apply_arena.deinit();
            const aa = apply_arena.allocator();
            const ev_for_apply = cloneStreamResponse(aa, event) catch return RequestHandler.Error.OutOfMemory;

            const updated = try self.applyEventToTask(aa, current, ev_for_apply);
            try self.deliverPushNotifications(req_ref.id, ev_for_apply);

            if (updated) |u| {
                if (current) |*c| c.deinit();
                current = cloneTask(request_allocator, u) catch null;
            }

            if (active_opt) |a| {
                const bus_event = cloneStreamResponse(self.allocator, event) catch return RequestHandler.Error.OutOfMemory;
                const bus_snap: ?a2a.Task = if (updated) |u| cloneTask(self.allocator, u) catch null else null;
                a.publish(.{ .ok = bus_event }, bus_snap) catch {
                    var v = bus_event;
                    v.deinit();
                    if (bus_snap) |s| {
                        var sv = s;
                        sv.deinit();
                    }
                };
            }

            if (isTerminalEvent(ev_for_apply)) break;
        }

        if (active_opt) |a| {
            self.execution_manager.finish(req_ref.id, a);
        }

        return self.loadTask(request_allocator, req_ref.id);
    }

    fn vSubscribeToTask(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.SubscribeToTaskRequest,
    ) RequestHandler.Error!StreamIterator {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        const active = self.execution_manager.get(owned.id) orelse return RequestHandler.Error.TaskNotFound;
        const sub = active.subscribe() catch return RequestHandler.Error.OutOfMemory;
        return makeSubscriptionIterator(self.allocator, sub);
    }

    fn vCreatePushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.CreateTaskPushNotificationConfigRequest,
    ) RequestHandler.Error!a2a.TaskPushNotificationConfig {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        const store = try self.pushStoreOrErr();
        const saved = store.save(request_allocator, owned.task_id, &owned.config) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            error.InvalidArgument => return RequestHandler.Error.InvalidArgument,
            else => return RequestHandler.Error.StorageFailed,
        };
        return wrapTaskPushConfig(request_allocator, owned.task_id, owned.tenant, saved) catch
            RequestHandler.Error.OutOfMemory;
    }

    fn vGetPushConfig(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.GetTaskPushNotificationConfigRequest,
    ) RequestHandler.Error!a2a.TaskPushNotificationConfig {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        const store = try self.pushStoreOrErr();
        const got = store.get(request_allocator, owned.task_id, owned.id) catch |err| switch (err) {
            error.NotFound => return RequestHandler.Error.PushNotificationNotSupported,
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        };
        return wrapTaskPushConfig(request_allocator, owned.task_id, owned.tenant, got) catch
            RequestHandler.Error.OutOfMemory;
    }

    fn vListPushConfigs(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.ListTaskPushNotificationConfigsRequest,
    ) RequestHandler.Error!a2a.ListTaskPushNotificationConfigsResponse {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        const store = try self.pushStoreOrErr();
        const all = store.list(request_allocator, owned.task_id) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        };
        defer {
            for (all) |*c| @constCast(c).deinit();
            request_allocator.free(all);
        }

        // Sort by id (lexicographic) for stable pagination.
        std.sort.block(a2a.PushNotificationConfig, all, {}, configIdLessThan);

        const requested_size: usize = if (owned.page_size) |s| (if (s > 0) @as(usize, @intCast(s)) else self.options.default_page_size) else self.options.default_page_size;
        const start_offset: usize = b: {
            if (owned.page_token) |tok| {
                if (std.fmt.parseInt(usize, tok, 10) catch null) |n| break :b @min(n, all.len);
            }
            break :b 0;
        };
        const end_offset = @min(start_offset + requested_size, all.len);

        const slice = all[start_offset..end_offset];
        const wrapped = request_allocator.alloc(a2a.TaskPushNotificationConfig, slice.len) catch
            return RequestHandler.Error.OutOfMemory;
        var i: usize = 0;
        errdefer {
            for (wrapped[0..i]) |*w| w.deinit();
            request_allocator.free(wrapped);
        }
        while (i < slice.len) : (i += 1) {
            const cfg_clone = cloneNotificationConfig(request_allocator, slice[i]) catch
                return RequestHandler.Error.OutOfMemory;
            wrapped[i] = wrapTaskPushConfig(request_allocator, owned.task_id, owned.tenant, cfg_clone) catch
                return RequestHandler.Error.OutOfMemory;
        }

        const next_token: []const u8 = if (end_offset < all.len)
            std.fmt.allocPrint(request_allocator, "{d}", .{end_offset}) catch return RequestHandler.Error.OutOfMemory
        else
            request_allocator.dupe(u8, "") catch return RequestHandler.Error.OutOfMemory;

        return .{
            .configs = wrapped,
            .next_page_token = next_token,
            .allocator = request_allocator,
        };
    }

    fn vDeletePushConfig(
        ctx: *anyopaque,
        _: *const ServiceParams,
        req: a2a.DeleteTaskPushNotificationConfigRequest,
    ) RequestHandler.Error!void {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        const store = try self.pushStoreOrErr();
        store.delete(owned.task_id, owned.id) catch |err| switch (err) {
            error.OutOfMemory => return RequestHandler.Error.OutOfMemory,
            else => return RequestHandler.Error.StorageFailed,
        };
    }

    fn vGetExtendedAgentCard(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        _: *const ServiceParams,
        req: a2a.GetExtendedAgentCardRequest,
    ) RequestHandler.Error!a2a.AgentCard {
        const self: *DefaultRequestHandler = @ptrCast(@alignCast(ctx));
        var owned = req;
        defer owned.deinit();
        const card = self.extended_card orelse return RequestHandler.Error.UnsupportedOperation;
        var pb_card = pb.conv.agentCardToProto(request_allocator, card) catch return RequestHandler.Error.OutOfMemory;
        defer pb_card.deinit(request_allocator);
        return pb.conv.agentCardFromProto(request_allocator, pb_card) catch RequestHandler.Error.OutOfMemory;
    }

    const vtable: RequestHandler.VTable = .{
        .sendMessage = vSendMessage,
        .sendStreamingMessage = vSendStreamingMessage,
        .getTask = vGetTask,
        .listTasks = vListTasks,
        .cancelTask = vCancelTask,
        .subscribeToTask = vSubscribeToTask,
        .createPushConfig = vCreatePushConfig,
        .getPushConfig = vGetPushConfig,
        .listPushConfigs = vListPushConfigs,
        .deletePushConfig = vDeletePushConfig,
        .getExtendedAgentCard = vGetExtendedAgentCard,
    };
};

const ExecutionStart = struct {
    task_id_owned: []const u8, // request-scope
    active: *ActiveExecution,
    exec_ctx: ExecutorContext,
};

// ---------------------------------------------------------------------------
// Worker — drives a streaming execution on a dedicated thread
// ---------------------------------------------------------------------------

const Worker = struct {
    handler: *DefaultRequestHandler,
    active: *ActiveExecution,
    exec_ctx: ExecutorContext,
    task_id_owned: []const u8,
    request_allocator: std.mem.Allocator,
    cancel_path: bool,
    thread: std.Thread = undefined,

    fn run(self: *Worker) void {
        defer {
            self.handler.execution_manager.finish(self.task_id_owned, self.active);
            self.exec_ctx.deinit();
            self.request_allocator.free(self.task_id_owned);
            self.thread.detach();
            const allocator = self.handler.allocator;
            allocator.destroy(self);
        }
        self.handler.driveExecution(self.active, &self.exec_ctx, self.cancel_path);
    }
};

// ---------------------------------------------------------------------------
// SubscriptionIterator — wraps a Subscription as a StreamIterator
// ---------------------------------------------------------------------------

const SubscriptionIterator = struct {
    allocator: std.mem.Allocator,
    sub: *execution_mod.Subscription,
    snapshot_emitted: bool = false,

    fn next(ctx: *anyopaque) StreamIterator.NextError!?a2a.StreamResponse {
        const self: *SubscriptionIterator = @ptrCast(@alignCast(ctx));
        while (true) {
            const event = self.sub.next() orelse return null;
            switch (event.result) {
                .err => |e| {
                    self.allocator.free(e.message);
                    log.warn("subscription stream surfaced error: {d}", .{e.code});
                    return StreamIterator.NextError.TransportError;
                },
                .ok => |sr| {
                    // Ownership transfers to caller: don't deinit here.
                    _ = sr;
                    return event.result.ok;
                },
            }
        }
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *SubscriptionIterator = @ptrCast(@alignCast(ctx));
        self.sub.unsubscribe();
        const a = self.allocator;
        a.destroy(self);
    }

    const vtable: StreamIterator.VTable = .{ .next = next, .deinit = deinit };
};

fn makeSubscriptionIterator(
    allocator: std.mem.Allocator,
    sub: *execution_mod.Subscription,
) StreamIterator {
    const self = allocator.create(SubscriptionIterator) catch unreachable;
    self.* = .{ .allocator = allocator, .sub = sub };
    return .{ .ctx = @ptrCast(self), .vtable = &SubscriptionIterator.vtable };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn cloneTask(allocator: std.mem.Allocator, src: a2a.Task) !a2a.Task {
    var pb_task = try pb.conv.taskToProto(allocator, src);
    defer pb_task.deinit(allocator);
    return try pb.conv.taskFromProto(allocator, pb_task);
}

fn cloneMessage(allocator: std.mem.Allocator, src: a2a.Message) !a2a.Message {
    var pb_msg = try pb.conv.messageToProto(allocator, src);
    defer pb_msg.deinit(allocator);
    return try pb.conv.messageFromProto(allocator, pb_msg);
}

fn cloneStatus(allocator: std.mem.Allocator, src: a2a.TaskStatus) !a2a.TaskStatus {
    var pb_status = try pb.conv.taskStatusToProto(allocator, src);
    defer pb_status.deinit(allocator);
    return try pb.conv.taskStatusFromProto(allocator, pb_status);
}

fn cloneArtifact(allocator: std.mem.Allocator, src: a2a.Artifact) !a2a.Artifact {
    var pb_art = try pb.conv.artifactToProto(allocator, src);
    defer pb_art.deinit(allocator);
    return try pb.conv.artifactFromProto(allocator, pb_art);
}

fn cloneStreamResponse(allocator: std.mem.Allocator, src: a2a.StreamResponse) !a2a.StreamResponse {
    var pb_sr = try pb.conv.streamResponseToProto(allocator, src);
    defer pb_sr.deinit(allocator);
    return try pb.conv.streamResponseFromProto(allocator, pb_sr);
}

fn cloneNotificationConfig(allocator: std.mem.Allocator, src: a2a.PushNotificationConfig) !a2a.PushNotificationConfig {
    var out: a2a.PushNotificationConfig = .{
        .url = try allocator.dupe(u8, src.url),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (src.id) |s| out.id = try allocator.dupe(u8, s);
    if (src.token) |s| out.token = try allocator.dupe(u8, s);
    if (src.authentication) |auth| {
        var copy: a2a.AuthenticationInfo = .{
            .scheme = try allocator.dupe(u8, auth.scheme),
            .allocator = allocator,
        };
        errdefer copy.deinit();
        if (auth.credentials) |c| copy.credentials = try allocator.dupe(u8, c);
        out.authentication = copy;
    }
    return out;
}

fn appendArtifact(allocator: std.mem.Allocator, task: *a2a.Task, art: a2a.Artifact) !void {
    if (task.artifacts) |existing| {
        const new = try allocator.alloc(a2a.Artifact, existing.len + 1);
        @memcpy(new[0..existing.len], existing);
        new[existing.len] = art;
        allocator.free(existing);
        task.artifacts = new;
    } else {
        const new = try allocator.alloc(a2a.Artifact, 1);
        new[0] = art;
        task.artifacts = new;
    }
}

fn isTerminalEvent(event: a2a.StreamResponse) bool {
    return switch (event) {
        .task => |t| t.status.state.isTerminal(),
        .status_update => |u| u.status.state.isTerminal(),
        else => false,
    };
}

fn taskIdFromEvent(event: a2a.StreamResponse) ?[]const u8 {
    return switch (event) {
        .task => |t| t.id,
        .status_update => |u| u.task_id,
        .artifact_update => |u| u.task_id,
        .message, .unknown => null,
    };
}

fn wrapTaskPushConfig(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    tenant: ?[]const u8,
    cfg: a2a.PushNotificationConfig,
) !a2a.TaskPushNotificationConfig {
    var out: a2a.TaskPushNotificationConfig = .{
        .task_id = try allocator.dupe(u8, task_id),
        .config = cfg,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (tenant) |t| out.tenant = try allocator.dupe(u8, t);
    return out;
}

fn configIdLessThan(_: void, a: a2a.PushNotificationConfig, b: a2a.PushNotificationConfig) bool {
    const a_id = a.id orelse "";
    const b_id = b.id orelse "";
    return std.mem.order(u8, a_id, b_id) == .lt;
}

fn publishError(active: *ActiveExecution, err: anyerror) void {
    const code: i32 = switch (err) {
        error.OutOfMemory => -32603,
        else => -32603,
    };
    const msg = @errorName(err);
    active.publish(.{ .err = .{ .code = code, .message = msg } }, null) catch {};
}

fn mapErrorCode(code: i32) RequestHandler.Error {
    return switch (code) {
        a2a.code.TASK_NOT_FOUND => RequestHandler.Error.TaskNotFound,
        a2a.code.TASK_NOT_CANCELABLE => RequestHandler.Error.TaskNotCancelable,
        a2a.code.PUSH_NOTIFICATION_NOT_SUPPORTED => RequestHandler.Error.PushNotificationNotSupported,
        a2a.code.UNSUPPORTED_OPERATION => RequestHandler.Error.UnsupportedOperation,
        a2a.code.INVALID_PARAMS, a2a.code.INVALID_REQUEST => RequestHandler.Error.InvalidArgument,
        else => RequestHandler.Error.InternalError,
    };
}

// ---------------------------------------------------------------------------
// Tests — uses a stub executor that emits a single completed task.
// ---------------------------------------------------------------------------

const testing = std.testing;
const inmemory_store = @import("task_store/inmemory.zig");

const EchoExecutor = struct {
    const Self = @This();

    fn execute(
        _: *anyopaque,
        request_allocator: std.mem.Allocator,
        ctx: *ExecutorContext,
    ) AgentExecutor.Error!StreamIterator {
        return makeOnceIterator(request_allocator, ctx, .completed);
    }

    fn cancel(
        _: *anyopaque,
        request_allocator: std.mem.Allocator,
        ctx: *ExecutorContext,
    ) AgentExecutor.Error!StreamIterator {
        return makeOnceIterator(request_allocator, ctx, .canceled);
    }

    const vtable: AgentExecutor.VTable = .{ .execute = execute, .cancel = cancel };

    fn make() AgentExecutor {
        const dummy: *Self = @ptrFromInt(0xdeadbeef);
        return .{ .ctx = @ptrCast(dummy), .vtable = &vtable };
    }
};

const OnceIterator = struct {
    allocator: std.mem.Allocator,
    payload: ?a2a.StreamResponse,

    fn next(ctx: *anyopaque) StreamIterator.NextError!?a2a.StreamResponse {
        const self: *OnceIterator = @ptrCast(@alignCast(ctx));
        if (self.payload) |p| {
            self.payload = null;
            return p;
        }
        return null;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *OnceIterator = @ptrCast(@alignCast(ctx));
        if (self.payload) |*p| p.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    const vtable: StreamIterator.VTable = .{ .next = next, .deinit = deinit };
};

fn makeOnceIterator(
    allocator: std.mem.Allocator,
    ctx: *ExecutorContext,
    final_state: a2a.TaskState,
) AgentExecutor.Error!StreamIterator {
    const it = allocator.create(OnceIterator) catch return AgentExecutor.Error.OutOfMemory;
    const task: a2a.Task = .{
        .id = allocator.dupe(u8, ctx.task_id) catch return AgentExecutor.Error.OutOfMemory,
        .context_id = allocator.dupe(u8, ctx.context_id) catch return AgentExecutor.Error.OutOfMemory,
        .status = .{ .state = final_state, .allocator = allocator },
        .allocator = allocator,
    };
    it.* = .{ .allocator = allocator, .payload = .{ .task = task } };
    return .{ .ctx = @ptrCast(it), .vtable = &OnceIterator.vtable };
}

test "sendMessage drives executor and returns a task" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();

    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "hi");
    var req: a2a.SendMessageRequest = .{
        .message = try a2a.Message.init(a, .user, parts),
        .allocator = a,
    };
    req.message.task_id = try a.dupe(u8, "t-send");

    var resp = try handler.sendMessage(a, &params, req);
    defer resp.deinit();
    try testing.expect(resp == .task);
    try testing.expectEqual(a2a.TaskState.completed, resp.task.status.state);
}

test "getTask after sendMessage returns the persisted task" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();

    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "hi");
    var msg = try a2a.Message.init(a, .user, parts);
    msg.task_id = try a.dupe(u8, "t-get");
    const req: a2a.SendMessageRequest = .{ .message = msg, .allocator = a };
    var resp = try handler.sendMessage(a, &params, req);
    resp.deinit();

    var got = try handler.getTask(a, &params, .{ .id = try a.dupe(u8, "t-get"), .allocator = a });
    defer got.deinit();
    try testing.expectEqualStrings("t-get", got.id);
}

test "getTask on unknown id returns TaskNotFound" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();
    try testing.expectError(
        RequestHandler.Error.TaskNotFound,
        handler.getTask(a, &params, .{ .id = try a.dupe(u8, "missing"), .allocator = a }),
    );
}

test "listTasks returns an empty page when nothing is stored" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();
    var resp = try handler.listTasks(a, &params, .{ .allocator = a });
    defer resp.deinit();
    try testing.expectEqual(@as(usize, 0), resp.tasks.len);
}

test "cancelTask refuses already-terminal tasks" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    const seed: a2a.Task = .{
        .id = try a.dupe(u8, "t-done"),
        .context_id = try a.dupe(u8, "c-done"),
        .status = .{ .state = .completed, .allocator = a },
        .allocator = a,
    };
    var seed_clone = seed;
    _ = try store_state.store().create(a, &seed);
    seed_clone.deinit();

    var params = ServiceParams.init(a);
    defer params.deinit();
    try testing.expectError(
        RequestHandler.Error.TaskNotCancelable,
        handler.cancelTask(a, &params, .{ .id = try a.dupe(u8, "t-done"), .allocator = a }),
    );
}

test "createPushConfig without a store returns PushNotificationNotSupported" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();
    var cfg: a2a.PushNotificationConfig = .{ .url = try a.dupe(u8, "https://ex.com"), .allocator = a };
    const req: a2a.CreateTaskPushNotificationConfigRequest = .{
        .task_id = try a.dupe(u8, "t1"),
        .config = cfg,
        .allocator = a,
    };
    _ = &cfg;
    // Handler claims ownership of `req` even on the error path.

    try testing.expectError(
        RequestHandler.Error.PushNotificationNotSupported,
        handler.createPushConfig(a, &params, req),
    );
}

test "push CRUD round trip with a configured store" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var pcs = push_store.InMemoryPushConfigStore.init(a, io);
    defer pcs.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    h.withPushSupport(pcs.store(), null);
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();

    var cfg: a2a.PushNotificationConfig = .{ .url = try a.dupe(u8, "https://ex.com"), .allocator = a };
    cfg.id = try a.dupe(u8, "cfg-1");
    const create_req: a2a.CreateTaskPushNotificationConfigRequest = .{
        .task_id = try a.dupe(u8, "t1"),
        .config = cfg,
        .allocator = a,
    };
    var saved = try handler.createPushConfig(a, &params, create_req);
    saved.deinit();

    const get_req: a2a.GetTaskPushNotificationConfigRequest = .{
        .task_id = try a.dupe(u8, "t1"),
        .id = try a.dupe(u8, "cfg-1"),
        .allocator = a,
    };
    var got = try handler.getPushConfig(a, &params, get_req);
    defer got.deinit();
    try testing.expectEqualStrings("https://ex.com", got.config.url);

    const list_req: a2a.ListTaskPushNotificationConfigsRequest = .{
        .task_id = try a.dupe(u8, "t1"),
        .allocator = a,
    };
    var listed = try handler.listPushConfigs(a, &params, list_req);
    defer listed.deinit();
    try testing.expectEqual(@as(usize, 1), listed.configs.len);

    const del_req: a2a.DeleteTaskPushNotificationConfigRequest = .{
        .task_id = try a.dupe(u8, "t1"),
        .id = try a.dupe(u8, "cfg-1"),
        .allocator = a,
    };
    try handler.deletePushConfig(&params, del_req);

    const get_req2: a2a.GetTaskPushNotificationConfigRequest = .{
        .task_id = try a.dupe(u8, "t1"),
        .id = try a.dupe(u8, "cfg-1"),
        .allocator = a,
    };
    try testing.expectError(
        RequestHandler.Error.PushNotificationNotSupported,
        handler.getPushConfig(a, &params, get_req2),
    );
}

test "getExtendedAgentCard surfaces the configured card" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var store_state = inmemory_store.InMemoryTaskStore.init(a, io);
    defer store_state.deinit();
    var h = DefaultRequestHandler.init(a, io, EchoExecutor.make(), store_state.store());
    defer h.deinit();
    const handler = h.handler();

    var params = ServiceParams.init(a);
    defer params.deinit();

    try testing.expectError(
        RequestHandler.Error.UnsupportedOperation,
        handler.getExtendedAgentCard(a, &params, .{ .allocator = a }),
    );

    const card: a2a.AgentCard = .{
        .name = try a.dupe(u8, "Ext"),
        .description = try a.dupe(u8, "Extended"),
        .version = try a.dupe(u8, "1.0"),
        .supported_interfaces = try a.alloc(a2a.AgentInterface, 0),
        .capabilities = a2a.AgentCapabilities.default(a),
        .default_input_modes = try a.alloc([]const u8, 0),
        .default_output_modes = try a.alloc([]const u8, 0),
        .skills = try a.alloc(a2a.AgentSkill, 0),
        .allocator = a,
    };
    h.setExtendedCard(card);

    var produced = try handler.getExtendedAgentCard(a, &params, .{ .allocator = a });
    defer produced.deinit();
    try testing.expectEqualStrings("Ext", produced.name);
}
