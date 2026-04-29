//! Live execution state for in-flight tasks.
//!
//! `ActiveExecution` tracks one in-flight task: the latest snapshot, the
//! event sequence number, the cooperative cancel flag, and a broadcast
//! channel that fans every published event out to subscribed listeners.
//! `ExecutionManager` is a registry of active executions keyed by task id;
//! it lets unary calls find the in-flight execution to interact with and
//! lets streaming subscribers attach.
//!
//! Memory model:
//!   * The owning storage allocator on `ActiveExecution` holds the snapshot
//!     and the broadcast channel; both live until `deinit`.
//!   * Every published event clones its `StreamResponse` into the storage
//!     allocator so subscribers can drain after the executor has freed its
//!     own copy. Subscriptions deep-clone again on `next` if they hand the
//!     event back to a request-scoped consumer.
//!   * Cancellation is cooperative: the executor polls `canceled` via the
//!     `ExecutorContext` it received and stops at a safe point.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");
const broadcast = @import("broadcast");

const log = std.log.scoped(.a2a_server);

/// One event flowing through the broadcast channel.
pub const ExecutionEvent = struct {
    sequence: u64,
    /// Either a stream-response payload or a transport-level error code.
    /// We keep just code + message because the full `A2AError` details are
    /// not propagated through the stream.
    result: Result,
    /// Allocator that owns the payload and message memory. Subscribers free
    /// via `deinitEvent` when discarding pending events.
    allocator: std.mem.Allocator,

    pub const Result = union(enum) {
        ok: a2a.StreamResponse,
        err: struct {
            code: i32,
            message: []const u8,
        },
    };
};

/// Free an event's owned memory. Called by the broadcast channel's drain
/// path when a subscription is dropped with pending events queued.
pub fn deinitEvent(allocator: std.mem.Allocator, event: *ExecutionEvent) void {
    _ = allocator;
    switch (event.result) {
        .ok => |*sr| sr.deinit(),
        .err => |e| event.allocator.free(e.message),
    }
    event.* = undefined;
}

fn cloneEvent(allocator: std.mem.Allocator, src: ExecutionEvent) error{OutOfMemory}!ExecutionEvent {
    return switch (src.result) {
        .ok => |sr| blk: {
            // Deep-clone the StreamResponse via the protobuf round-trip so
            // each subscriber holds an independent copy.
            var pb_sr = pb.conv.streamResponseToProto(allocator, sr) catch return error.OutOfMemory;
            defer pb_sr.deinit(allocator);
            const cloned = pb.conv.streamResponseFromProto(allocator, pb_sr) catch return error.OutOfMemory;
            break :blk .{
                .sequence = src.sequence,
                .result = .{ .ok = cloned },
                .allocator = allocator,
            };
        },
        .err => |e| .{
            .sequence = src.sequence,
            .result = .{ .err = .{
                .code = e.code,
                .message = try allocator.dupe(u8, e.message),
            } },
            .allocator = allocator,
        },
    };
}

pub const Subscription = broadcast.Subscription(ExecutionEvent);

/// State for one in-flight task. Owned by `ExecutionManager`.
pub const ActiveExecution = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    bus: broadcast.Broadcaster(ExecutionEvent),

    state_mu: std.Io.Mutex = .init,
    sequence: u64 = 0,
    /// Latest known task state. Replaced via `publish` whenever a new
    /// snapshot arrives. Owned by `allocator`.
    snapshot: ?a2a.Task = null,
    /// Cooperative cancel flag. Executors check `ExecutorContext.canceled()`
    /// (which reads this through a borrowed pointer) at safe points.
    canceled: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        initial_task: ?a2a.Task,
    ) !*ActiveExecution {
        const self = try allocator.create(ActiveExecution);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .bus = broadcast.Broadcaster(ExecutionEvent).init(allocator, io, deinitEvent),
            .snapshot = initial_task,
        };
        return self;
    }

    pub fn deinit(self: *ActiveExecution) void {
        self.bus.deinit();
        if (self.snapshot) |*t| t.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    /// Subscribe a fresh consumer. The returned subscription must be
    /// dropped with `unsubscribe()` before the execution itself is freed.
    pub fn subscribe(self: *ActiveExecution) !*Subscription {
        return self.bus.subscribe();
    }

    /// Atomically read the current sequence number. Useful for clients that
    /// resubscribe — they can drop any cached events with sequence ≤ this.
    pub fn currentSequence(self: *ActiveExecution) u64 {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        return self.sequence;
    }

    /// Return a freshly-allocated clone of the latest snapshot, if any.
    pub fn snapshotClone(
        self: *ActiveExecution,
        request_allocator: std.mem.Allocator,
    ) !?a2a.Task {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        const snap = self.snapshot orelse return null;
        var pb_task = try pb.conv.taskToProto(request_allocator, snap);
        defer pb_task.deinit(request_allocator);
        return try pb.conv.taskFromProto(request_allocator, pb_task);
    }

    /// True when the latest snapshot is in a terminal state.
    pub fn isTerminal(self: *ActiveExecution) bool {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        const snap = self.snapshot orelse return false;
        return snap.status.state.isTerminal();
    }

    /// Set the cooperative cancel flag. Executors observing the flag should
    /// stop at the next safe point.
    pub fn requestCancel(self: *ActiveExecution) void {
        self.canceled.store(true, .release);
    }

    pub fn isCanceled(self: *ActiveExecution) bool {
        return self.canceled.load(.acquire);
    }

    /// Publish a payload to every subscriber. If `new_snapshot` is set, it
    /// replaces the existing snapshot first (and ownership transfers — the
    /// execution will free it on deinit). The payload is cloned per
    /// subscriber via the broadcast channel.
    pub fn publish(
        self: *ActiveExecution,
        payload: ExecutionEvent.Result,
        new_snapshot: ?a2a.Task,
    ) error{ OutOfMemory, Closed }!void {
        const seq = blk: {
            self.state_mu.lockUncancelable(self.io);
            defer self.state_mu.unlock(self.io);
            if (new_snapshot) |snap| {
                if (self.snapshot) |*old| old.deinit();
                self.snapshot = snap;
            }
            self.sequence += 1;
            break :blk self.sequence;
        };

        // Construct the canonical event (owned by `self.allocator`) and
        // hand it to the bus, which clones it per subscriber.
        const event = try buildEventFromPayload(self.allocator, seq, payload);
        defer {
            // Free the canonical copy — every subscriber received its own.
            var ev = event;
            deinitEvent(self.allocator, &ev);
        }
        try self.bus.publishCloned(event, cloneEvent);
    }

    fn buildEventFromPayload(
        allocator: std.mem.Allocator,
        sequence: u64,
        payload: ExecutionEvent.Result,
    ) error{OutOfMemory}!ExecutionEvent {
        return switch (payload) {
            .ok => |sr| .{
                .sequence = sequence,
                .result = .{ .ok = sr },
                .allocator = allocator,
            },
            .err => |e| .{
                .sequence = sequence,
                .result = .{ .err = .{
                    .code = e.code,
                    .message = try allocator.dupe(u8, e.message),
                } },
                .allocator = allocator,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// ExecutionManager
// ---------------------------------------------------------------------------

pub const ExecutionManager = struct {
    pub const Error = error{
        OutOfMemory,
        AlreadyRunning,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    executions: std.StringArrayHashMapUnmanaged(*ActiveExecution) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ExecutionManager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *ExecutionManager) void {
        var it = self.executions.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
        }
        self.executions.deinit(self.allocator);
        self.* = undefined;
    }

    /// Start tracking a new execution. Returns `error.AlreadyRunning` if an
    /// execution with the same task id is already in flight.
    pub fn start(self: *ExecutionManager, task: a2a.Task) Error!*ActiveExecution {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        if (self.executions.contains(task.id)) return Error.AlreadyRunning;

        const owned_id = self.allocator.dupe(u8, task.id) catch return Error.OutOfMemory;
        errdefer self.allocator.free(owned_id);

        // Deep-clone the task into the storage allocator so the caller can
        // free its copy independently.
        var pb_task = pb.conv.taskToProto(self.allocator, task) catch return Error.OutOfMemory;
        defer pb_task.deinit(self.allocator);
        const owned_task = pb.conv.taskFromProto(self.allocator, pb_task) catch return Error.OutOfMemory;

        const active = ActiveExecution.init(self.allocator, self.io, owned_task) catch {
            var t = owned_task;
            t.deinit();
            return Error.OutOfMemory;
        };
        errdefer active.deinit();

        self.executions.put(self.allocator, owned_id, active) catch return Error.OutOfMemory;
        return active;
    }

    /// Look up an active execution by task id. Returns null if no execution
    /// is in flight for that id.
    pub fn get(self: *ExecutionManager, task_id: []const u8) ?*ActiveExecution {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.executions.get(task_id);
    }

    /// Remove an execution from the registry. Idempotent: only removes if
    /// the registered pointer matches `expected`. This guards against a
    /// race where one task finishes while another with the same id starts.
    pub fn finish(
        self: *ExecutionManager,
        task_id: []const u8,
        expected: *ActiveExecution,
    ) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const current = self.executions.get(task_id) orelse return;
        if (current != expected) return;

        const entry = self.executions.fetchOrderedRemove(task_id).?;
        self.allocator.free(entry.key);
        entry.value.deinit();
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeTask(allocator: std.mem.Allocator, id: []const u8, state: a2a.TaskState) !a2a.Task {
    return .{
        .id = try allocator.dupe(u8, id),
        .context_id = try allocator.dupe(u8, "ctx"),
        .status = .{ .state = state, .allocator = allocator },
        .allocator = allocator,
    };
}

test "manager rejects duplicate task ids" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t1 = try makeTask(a, "t1", .submitted);
    defer t1.deinit();
    _ = try mgr.start(t1);

    var t1b = try makeTask(a, "t1", .submitted);
    defer t1b.deinit();
    try testing.expectError(ExecutionManager.Error.AlreadyRunning, mgr.start(t1b));
}

test "subscribe and publish ok payload reaches subscriber" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);

    const sub = try exec.subscribe();
    defer sub.unsubscribe();

    // Publish a status update event.
    var update = a2a.TaskStatusUpdateEvent{
        .task_id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "ctx"),
        .status = .{ .state = .working, .allocator = a },
        .allocator = a,
    };
    defer update.deinit();
    var pb_update = try pb.conv.taskStatusUpdateEventToProto(a, update);
    defer pb_update.deinit(a);
    var update_clone = try pb.conv.taskStatusUpdateEventFromProto(a, pb_update);
    const stream_response = a2a.StreamResponse{ .status_update = update_clone };
    _ = &update_clone;

    try exec.publish(.{ .ok = stream_response }, null);

    var pulled = sub.tryNext().?;
    defer deinitEvent(a, &pulled);
    try testing.expectEqual(@as(u64, 1), pulled.sequence);
    try testing.expect(pulled.result == .ok);
    try testing.expect(pulled.result.ok == .status_update);
}

test "publish with new snapshot replaces stored snapshot" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);

    const new_snap = try makeTask(a, "t1", .working);
    try exec.publish(
        .{ .err = .{ .code = 0, .message = "" } }, // no-op event
        new_snap,
    );

    var snapshot = (try exec.snapshotClone(a)).?;
    defer snapshot.deinit();
    try testing.expectEqual(a2a.TaskState.working, snapshot.status.state);
    try testing.expectEqual(@as(u64, 1), exec.currentSequence());
}

test "isTerminal reflects snapshot state" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);
    try testing.expect(!exec.isTerminal());

    const done = try makeTask(a, "t1", .completed);
    try exec.publish(.{ .err = .{ .code = 0, .message = "" } }, done);
    try testing.expect(exec.isTerminal());
}

test "requestCancel and isCanceled" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);

    try testing.expect(!exec.isCanceled());
    exec.requestCancel();
    try testing.expect(exec.isCanceled());
}

test "two subscribers each see every event" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);

    const s1 = try exec.subscribe();
    defer s1.unsubscribe();
    const s2 = try exec.subscribe();
    defer s2.unsubscribe();

    try exec.publish(.{ .err = .{ .code = -32603, .message = "boom" } }, null);
    try exec.publish(.{ .err = .{ .code = -32604, .message = "again" } }, null);

    var e1 = s1.tryNext().?;
    defer deinitEvent(a, &e1);
    try testing.expectEqual(@as(u64, 1), e1.sequence);
    var e2 = s1.tryNext().?;
    defer deinitEvent(a, &e2);
    try testing.expectEqual(@as(u64, 2), e2.sequence);
    try testing.expect(s1.tryNext() == null);

    var f1 = s2.tryNext().?;
    defer deinitEvent(a, &f1);
    try testing.expectEqual(@as(u64, 1), f1.sequence);
    var f2 = s2.tryNext().?;
    defer deinitEvent(a, &f2);
    try testing.expectEqual(@as(u64, 2), f2.sequence);
}

test "finish only removes when pointer matches" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);

    // Pretend a different pointer was passed — should be a no-op.
    var dummy: ActiveExecution = undefined;
    mgr.finish("t1", &dummy);
    try testing.expect(mgr.get("t1") != null);

    // Real pointer — removes.
    mgr.finish("t1", exec);
    try testing.expect(mgr.get("t1") == null);
}

test "snapshotClone returns independent memory" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var mgr = ExecutionManager.init(a, io);
    defer mgr.deinit();

    var t = try makeTask(a, "t1", .submitted);
    defer t.deinit();
    const exec = try mgr.start(t);

    var clone1 = (try exec.snapshotClone(a)).?;
    defer clone1.deinit();
    var clone2 = (try exec.snapshotClone(a)).?;
    defer clone2.deinit();

    try testing.expect(clone1.id.ptr != clone2.id.ptr);
    try testing.expectEqualStrings("t1", clone1.id);
    try testing.expectEqualStrings("t1", clone2.id);
}
