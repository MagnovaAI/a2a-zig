//! Transport vtable and factory interface.
//!
//! Design notes:
//!   * Each method dispatches through a vtable of function pointers. The first
//!     argument is `*anyopaque` (the underlying state); the remaining
//!     arguments mirror the protocol method signatures. The wrapping
//!     `Transport` struct holds the state + vtable and provides typed
//!     dispatch methods.
//!   * Streaming responses use a pull-based `StreamIterator` with `next` and
//!     `deinit` function pointers — the caller drives it by calling `next`
//!     until it returns null.
//!   * Async handling lives at the call site; the vtable itself is sync.
//!     When real HTTP lands, the per-method functions either block or run on
//!     a worker pool; the public API stays the same.
const std = @import("std");
const a2a = @import("a2a");

pub const A2AError = a2a.A2AError;

// ---------------------------------------------------------------------------
// ServiceParams — flat string→[]string map
// ---------------------------------------------------------------------------

/// Header-style service parameters carried alongside every transport call
/// (e.g., `A2A-Version`, `A2A-Extensions`). Keys and values are owned.
pub const ServiceParams = struct {
    entries: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ServiceParams {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ServiceParams) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |v| self.allocator.free(v);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append `value` to the list under `key`. Both are duplicated.
    pub fn append(self: *ServiceParams, key: []const u8, value: []const u8) !void {
        const dup_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(dup_value);

        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            const new = try self.allocator.alloc([]const u8, old.len + 1);
            @memcpy(new[0..old.len], old);
            new[old.len] = dup_value;
            self.allocator.free(old);
            gop.value_ptr.* = new;
        } else {
            const dup_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(dup_key);
            const new = try self.allocator.alloc([]const u8, 1);
            new[0] = dup_value;
            gop.key_ptr.* = dup_key;
            gop.value_ptr.* = new;
        }
    }

    pub fn get(self: *const ServiceParams, key: []const u8) ?[]const []const u8 {
        return self.entries.get(key);
    }

    pub fn count(self: *const ServiceParams) usize {
        return self.entries.count();
    }
};

/// Re-export of the protocol-level `StreamIterator` (defined in `a2a.event`)
/// so existing transport code keeps using `transport.StreamIterator`.
pub const StreamIterator = a2a.StreamIterator;

// ---------------------------------------------------------------------------
// Transport vtable
// ---------------------------------------------------------------------------

/// The extension point for every protocol binding (JSON-RPC, REST, gRPC, ...).
///
/// Concrete transports allocate their own state and produce a `Transport` whose
/// `ctx` points at that state. The state's lifetime is bound by the transport's
/// `destroy` method — callers must invoke it before freeing the underlying
/// `Transport` value.
pub const Transport = struct {
    pub const Error = error{
        OutOfMemory,
        TransportError,
        UnexpectedToken,
        MissingField,
    };

    pub const VTable = struct {
        send_message: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.SendMessageRequest,
        ) Error!a2a.SendMessageResponse,

        send_streaming_message: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.SendMessageRequest,
        ) Error!StreamIterator,

        get_task: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.GetTaskRequest,
        ) Error!a2a.Task,

        list_tasks: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.ListTasksRequest,
        ) Error!a2a.ListTasksResponse,

        cancel_task: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.CancelTaskRequest,
        ) Error!a2a.Task,

        subscribe_to_task: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.SubscribeToTaskRequest,
        ) Error!StreamIterator,

        create_push_config: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.CreateTaskPushNotificationConfigRequest,
        ) Error!a2a.TaskPushNotificationConfig,

        get_push_config: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.GetTaskPushNotificationConfigRequest,
        ) Error!a2a.TaskPushNotificationConfig,

        list_push_configs: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.ListTaskPushNotificationConfigsRequest,
        ) Error!a2a.ListTaskPushNotificationConfigsResponse,

        delete_push_config: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.DeleteTaskPushNotificationConfigRequest,
        ) Error!void,

        get_extended_agent_card: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: *const ServiceParams,
            req: *const a2a.GetExtendedAgentCardRequest,
        ) Error!a2a.AgentCard,

        destroy: *const fn (ctx: *anyopaque) void,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn sendMessage(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) Error!a2a.SendMessageResponse {
        return self.vtable.send_message(self.ctx, allocator, params, req);
    }

    pub fn sendStreamingMessage(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SendMessageRequest,
    ) Error!StreamIterator {
        return self.vtable.send_streaming_message(self.ctx, allocator, params, req);
    }

    pub fn getTask(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskRequest,
    ) Error!a2a.Task {
        return self.vtable.get_task(self.ctx, allocator, params, req);
    }

    pub fn listTasks(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTasksRequest,
    ) Error!a2a.ListTasksResponse {
        return self.vtable.list_tasks(self.ctx, allocator, params, req);
    }

    pub fn cancelTask(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CancelTaskRequest,
    ) Error!a2a.Task {
        return self.vtable.cancel_task(self.ctx, allocator, params, req);
    }

    pub fn subscribeToTask(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.SubscribeToTaskRequest,
    ) Error!StreamIterator {
        return self.vtable.subscribe_to_task(self.ctx, allocator, params, req);
    }

    pub fn createPushConfig(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.CreateTaskPushNotificationConfigRequest,
    ) Error!a2a.TaskPushNotificationConfig {
        return self.vtable.create_push_config(self.ctx, allocator, params, req);
    }

    pub fn getPushConfig(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetTaskPushNotificationConfigRequest,
    ) Error!a2a.TaskPushNotificationConfig {
        return self.vtable.get_push_config(self.ctx, allocator, params, req);
    }

    pub fn listPushConfigs(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.ListTaskPushNotificationConfigsRequest,
    ) Error!a2a.ListTaskPushNotificationConfigsResponse {
        return self.vtable.list_push_configs(self.ctx, allocator, params, req);
    }

    pub fn deletePushConfig(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.DeleteTaskPushNotificationConfigRequest,
    ) Error!void {
        return self.vtable.delete_push_config(self.ctx, allocator, params, req);
    }

    pub fn getExtendedAgentCard(
        self: *Transport,
        allocator: std.mem.Allocator,
        params: *const ServiceParams,
        req: *const a2a.GetExtendedAgentCardRequest,
    ) Error!a2a.AgentCard {
        return self.vtable.get_extended_agent_card(self.ctx, allocator, params, req);
    }

    /// Tear down the transport's owned state. After calling `destroy`, the
    /// `Transport` value must not be used again.
    pub fn destroy(self: *Transport) void {
        self.vtable.destroy(self.ctx);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// TransportFactory
// ---------------------------------------------------------------------------

/// Factory that produces `Transport` instances from agent-card interface
/// declarations. Each protocol binding registers a factory with the client
/// factory so protocol negotiation can pick the right transport at runtime.
pub const TransportFactory = struct {
    pub const Error = error{
        OutOfMemory,
        UnsupportedProtocol,
        InvalidInterface,
    };

    pub const VTable = struct {
        /// Protocol identifier (e.g., `"JSONRPC"`, `"GRPC"`, `"HTTP+JSON"`).
        protocol: *const fn (ctx: *anyopaque) []const u8,

        /// Build a transport for the given agent interface. The allocator is
        /// used both to create the returned `Transport` (heap-allocated so its
        /// `ctx` lives independently of the factory) and for any owned state
        /// the transport itself maintains.
        create: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            card: *const a2a.AgentCard,
            iface: *const a2a.AgentInterface,
        ) Error!*Transport,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn protocol(self: *const TransportFactory) []const u8 {
        return self.vtable.protocol(self.ctx);
    }

    pub fn create(
        self: *const TransportFactory,
        allocator: std.mem.Allocator,
        card: *const a2a.AgentCard,
        iface: *const a2a.AgentInterface,
    ) Error!*Transport {
        return self.vtable.create(self.ctx, allocator, card, iface);
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ServiceParams append + get" {
    const a = testing.allocator;
    var p = ServiceParams.init(a);
    defer p.deinit();

    try p.append("A2A-Version", "1.0");
    try p.append("A2A-Extensions", "ext-a");
    try p.append("A2A-Extensions", "ext-b");

    try testing.expectEqual(@as(usize, 2), p.count());
    const ver = p.get("A2A-Version").?;
    try testing.expectEqual(@as(usize, 1), ver.len);
    try testing.expectEqualStrings("1.0", ver[0]);

    const exts = p.get("A2A-Extensions").?;
    try testing.expectEqual(@as(usize, 2), exts.len);
    try testing.expectEqualStrings("ext-a", exts[0]);
    try testing.expectEqualStrings("ext-b", exts[1]);

    try testing.expect(p.get("missing") == null);
}

test "ServiceParams empty" {
    const a = testing.allocator;
    var p = ServiceParams.init(a);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.count());
}

// Smoke-test that the vtables compile against a stub transport. We never
// invoke its methods — the goal is purely to ensure the function-pointer
// types match the declared signatures across the type system.
const StubState = struct {};

fn stubProtocol(_: *anyopaque) []const u8 {
    return "STUB";
}

fn stubCreate(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: *const a2a.AgentCard,
    _: *const a2a.AgentInterface,
) TransportFactory.Error!*Transport {
    return error.UnsupportedProtocol;
}

const stub_factory_vtable: TransportFactory.VTable = .{
    .protocol = stubProtocol,
    .create = stubCreate,
};

test "TransportFactory vtable typechecks" {
    var state: StubState = .{};
    const f: TransportFactory = .{ .ctx = @ptrCast(&state), .vtable = &stub_factory_vtable };
    try testing.expectEqualStrings("STUB", f.protocol());
    const card: a2a.AgentCard = undefined;
    const iface: a2a.AgentInterface = undefined;
    try testing.expectError(error.UnsupportedProtocol, f.create(testing.allocator, &card, &iface));
}
