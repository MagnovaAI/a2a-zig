//! Persistence interface for tasks.
//!
//! Implementations are owned by the `Server` and shared across requests.
//! Every method takes a per-call allocator so returned `Task` values can be
//! freed with the request scope. The store keeps its own deep-cloned copy of
//! every task, so callers may free their input immediately after `create`
//! and `update` return.
const std = @import("std");
const a2a = @import("a2a");

pub const TaskVersion = u64;

/// Vtable for task storage backends.
pub const TaskStore = struct {
    pub const Error = error{
        OutOfMemory,
        AlreadyExists,
        NotFound,
        StorageFailed,
    };

    pub const VTable = struct {
        create: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            task: *const a2a.Task,
        ) Error!TaskVersion,

        update: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            task: *const a2a.Task,
        ) Error!TaskVersion,

        /// Returns `null` when the id is unknown. Caller owns the result.
        get: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            task_id: []const u8,
        ) Error!?a2a.Task,

        list: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            req: *const a2a.ListTasksRequest,
        ) Error!a2a.ListTasksResponse,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn create(
        self: *const TaskStore,
        request_allocator: std.mem.Allocator,
        task: *const a2a.Task,
    ) Error!TaskVersion {
        return self.vtable.create(self.ctx, request_allocator, task);
    }

    pub fn update(
        self: *const TaskStore,
        request_allocator: std.mem.Allocator,
        task: *const a2a.Task,
    ) Error!TaskVersion {
        return self.vtable.update(self.ctx, request_allocator, task);
    }

    pub fn get(
        self: *const TaskStore,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
    ) Error!?a2a.Task {
        return self.vtable.get(self.ctx, request_allocator, task_id);
    }

    pub fn list(
        self: *const TaskStore,
        request_allocator: std.mem.Allocator,
        req: *const a2a.ListTasksRequest,
    ) Error!a2a.ListTasksResponse {
        return self.vtable.list(self.ctx, request_allocator, req);
    }
};
