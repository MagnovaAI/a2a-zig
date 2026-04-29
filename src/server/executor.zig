//! Agent executor: the user-supplied entry point invoked by the handler when
//! a message arrives or a task is canceled.
//!
//! Implementations expose two methods (via vtable):
//!   * `execute(ctx)` — the message-driven entry point.
//!   * `cancel(ctx)`  — invoked when an in-progress task is canceled.
//!
//! Both return a `StreamIterator` of events. For unary work the iterator
//! yields a single `task` or `message` and ends; for streaming work it
//! produces interleaved status/artifact updates ending in a terminal task
//! state.
const std = @import("std");
const a2a = @import("a2a");
const middleware = @import("middleware.zig");

const ServiceParams = middleware.ServiceParams;
const User = middleware.User;
pub const StreamIterator = a2a.StreamIterator;

/// Context passed to every executor invocation. All owned slices reference
/// memory in the request scope's allocator and live until the response is
/// finalized — the executor must `dupe` anything it retains past that point.
pub const ExecutorContext = struct {
    /// The inbound message that triggered execution. `null` for cancellation
    /// requests that didn't carry a message.
    message: ?a2a.Message = null,
    task_id: []const u8,
    /// Existing task state if this is a continuation; null on first call.
    stored_task: ?a2a.Task = null,
    context_id: []const u8,
    metadata: ?a2a.Metadata = null,
    user: ?User = null,
    service_params: ServiceParams,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn taskInfo(self: *const ExecutorContext) struct { task_id: []const u8, context_id: []const u8 } {
        return .{ .task_id = self.task_id, .context_id = self.context_id };
    }

    pub fn deinit(self: *ExecutorContext) void {
        if (self.message) |*m| m.deinit();
        if (self.stored_task) |*t| t.deinit();
        if (self.metadata) |*m| m.deinit(self.allocator);
        if (self.user) |*u| u.deinit();
        self.service_params.deinit();
        self.allocator.free(self.task_id);
        self.allocator.free(self.context_id);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }
};

/// User-implemented business logic. Plug a concrete implementation into
/// `Server` to handle inbound messages.
pub const AgentExecutor = struct {
    pub const Error = error{
        OutOfMemory,
        ExecutorFailed,
    };

    pub const VTable = struct {
        execute: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            exec_ctx: *ExecutorContext,
        ) Error!StreamIterator,

        cancel: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            exec_ctx: *ExecutorContext,
        ) Error!StreamIterator,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn execute(
        self: *const AgentExecutor,
        request_allocator: std.mem.Allocator,
        exec_ctx: *ExecutorContext,
    ) Error!StreamIterator {
        return self.vtable.execute(self.ctx, request_allocator, exec_ctx);
    }

    pub fn cancel(
        self: *const AgentExecutor,
        request_allocator: std.mem.Allocator,
        exec_ctx: *ExecutorContext,
    ) Error!StreamIterator {
        return self.vtable.cancel(self.ctx, request_allocator, exec_ctx);
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ExecutorContext.taskInfo borrows the owned ids" {
    const a = testing.allocator;
    var params = ServiceParams.init(a);
    var ctx: ExecutorContext = .{
        .task_id = try a.dupe(u8, "t-42"),
        .context_id = try a.dupe(u8, "c-7"),
        .service_params = params,
        .allocator = a,
    };
    _ = &params;
    defer ctx.deinit();
    const info = ctx.taskInfo();
    try testing.expectEqualStrings("t-42", info.task_id);
    try testing.expectEqualStrings("c-7", info.context_id);
}

// Stub executor used to confirm vtable typing matches.
const StubExecutorState = struct {};

fn stubExecute(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *ExecutorContext,
) AgentExecutor.Error!StreamIterator {
    return AgentExecutor.Error.ExecutorFailed;
}

fn stubCancel(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *ExecutorContext,
) AgentExecutor.Error!StreamIterator {
    return AgentExecutor.Error.ExecutorFailed;
}

const stub_vtable: AgentExecutor.VTable = .{
    .execute = stubExecute,
    .cancel = stubCancel,
};

test "AgentExecutor vtable typechecks with a stub" {
    var state: StubExecutorState = .{};
    const exec: AgentExecutor = .{ .ctx = @ptrCast(&state), .vtable = &stub_vtable };

    const a = testing.allocator;
    var params = ServiceParams.init(a);
    var exec_ctx: ExecutorContext = .{
        .task_id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .service_params = params,
        .allocator = a,
    };
    _ = &params;
    defer exec_ctx.deinit();
    try testing.expectError(AgentExecutor.Error.ExecutorFailed, exec.execute(a, &exec_ctx));
    try testing.expectError(AgentExecutor.Error.ExecutorFailed, exec.cancel(a, &exec_ctx));
}
