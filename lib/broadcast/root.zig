//! Single-producer / many-consumer event fan-out.
//!
//! A `Broadcaster(T)` owns a list of subscriber queues. Every published event
//! is pushed to every live subscriber. Subscribers pull events with `next`,
//! which blocks until an event is available, the broadcaster closes, or the
//! subscription is dropped. Slow subscribers grow their own queue without
//! penalising other subscribers; this is the right trade-off when subscriber
//! count is small (typically 1–3 per task) and events are short-lived.
//!
//! Ownership: the broadcaster owns subscription objects. Calling
//! `subscribe()` returns a `*Subscription(T)`; the consumer must call
//! `subscription.unsubscribe()` when done. Closing the broadcaster wakes
//! every subscriber, which then sees `null` from `next` and unsubscribes.
//!
//! `T` must own its memory: events are deep-cloned by the caller when they
//! cross the publish boundary so each subscriber holds an independent copy.
//! The broadcaster doesn't dictate how cloning is done — the caller passes
//! values to `publish` and is responsible for cloning per subscriber if
//! that's needed. The default behavior is move semantics (one subscriber
//! gets the value); for true broadcast the caller passes a clone.
const std = @import("std");

/// Broadcaster of values of type `T`. The caller pushes one value per
/// subscriber per `publish` invocation (typed `[]const T` slice — see
/// `publishCloned` for a deep-clone helper).
pub fn Broadcaster(comptime T: type) type {
    return struct {
        const Self = @This();
        const Sub = Subscription(T);

        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        subscribers: std.array_list.Managed(*Sub),
        closed: bool = false,
        deinit_value: ?*const fn (allocator: std.mem.Allocator, value: *T) void = null,

        /// Construct an empty broadcaster. `deinit_value` is invoked on each
        /// pending event when a subscription is dropped while events remain
        /// in its queue, so callers can free owned slices.
        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            deinit_value: ?*const fn (allocator: std.mem.Allocator, value: *T) void,
        ) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .subscribers = .init(allocator),
                .deinit_value = deinit_value,
            };
        }

        /// Stop accepting new events, wake every subscriber so they see
        /// `null` from `next`, and free the broadcaster's bookkeeping. The
        /// subscriptions themselves remain valid: the consumer drains them
        /// (via `next` returning `null`) and then drops them with
        /// `unsubscribe`. After `deinit`, `unsubscribe` becomes a memory-
        /// only cleanup — the broadcaster's tracking has already been
        /// torn down so subs detach themselves locally.
        pub fn deinit(self: *Self) void {
            self.close();
            self.mutex.lockUncancelable(self.io);
            const subs_copy = self.subscribers.toOwnedSlice() catch &.{};
            // Invalidate every subscription's pointer so a later
            // `unsubscribe` short-circuits instead of touching freed state.
            for (subs_copy) |sub| sub.broadcaster = null;
            self.mutex.unlock(self.io);
            self.allocator.free(subs_copy);
            self.* = undefined;
        }

        /// Mark the broadcaster as closed. Idempotent; subsequent `publish`
        /// calls return `error.Closed` and pending subscribers see `null`.
        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return;
            self.closed = true;
            for (self.subscribers.items) |sub| {
                sub.signalClose();
            }
        }

        /// Subscribe a fresh consumer. The returned subscription must be
        /// `unsubscribe`d by the consumer.
        pub fn subscribe(self: *Self) !*Sub {
            const sub = try self.allocator.create(Sub);
            sub.* = .{
                .broadcaster = self,
                .allocator = self.allocator,
                .io = self.io,
                .queue = .init(self.allocator),
            };

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.subscribers.append(sub) catch {
                self.allocator.destroy(sub);
                return error.OutOfMemory;
            };
            return sub;
        }

        /// Push a clone of `value` to every live subscriber. The caller
        /// supplies a `clone` function so each subscriber holds independent
        /// memory.
        pub fn publishCloned(
            self: *Self,
            value: T,
            comptime clone: fn (allocator: std.mem.Allocator, src: T) error{OutOfMemory}!T,
        ) error{ OutOfMemory, Closed }!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            for (self.subscribers.items) |sub| {
                const cloned = try clone(self.allocator, value);
                sub.enqueueLocked(cloned) catch {
                    if (self.deinit_value) |fn_ptr| {
                        var v = cloned;
                        fn_ptr(self.allocator, &v);
                    }
                    return error.OutOfMemory;
                };
            }
        }

        /// Forget a subscription (called from `Subscription.unsubscribe`).
        fn forgetSubscription(self: *Self, sub: *Sub) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.subscribers.items, 0..) |s, i| {
                if (s == sub) {
                    _ = self.subscribers.orderedRemove(i);
                    break;
                }
            }
        }
    };
}

/// One subscriber's pending events. Constructed by `Broadcaster.subscribe`.
pub fn Subscription(comptime T: type) type {
    return struct {
        const Self = @This();
        const Bus = Broadcaster(T);

        broadcaster: ?*Bus,
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        queue: std.array_list.Managed(T),
        closed_local: bool = false,

        /// Block until an event is available or the stream closes. Returns
        /// `null` once the broadcaster has closed and the queue is drained.
        pub fn next(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.queue.items.len == 0) {
                if (self.closed_local) return null;
                self.cond.wait(self.io, &self.mutex) catch return null;
            }
            return self.queue.orderedRemove(0);
        }

        /// Non-blocking variant for tests and callers that want to integrate
        /// the queue with their own polling loop.
        pub fn tryNext(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }

        /// Drop this subscription. The broadcaster forgets it; any events
        /// still pending in the queue are freed via the broadcaster's
        /// `deinit_value` callback if one was provided.
        pub fn unsubscribe(self: *Self) void {
            if (self.broadcaster) |bus| {
                bus.forgetSubscription(self);
                self.broadcaster = null;
                // Drain remaining items.
                if (bus.deinit_value) |fn_ptr| {
                    self.mutex.lockUncancelable(self.io);
                    for (self.queue.items) |*v| fn_ptr(self.allocator, v);
                    self.mutex.unlock(self.io);
                }
            }
            self.queue.deinit();
            const a = self.allocator;
            a.destroy(self);
        }

        /// Called by the broadcaster while holding the broadcaster mutex —
        /// not the subscription mutex. Locks ourselves for the queue push.
        fn enqueueLocked(self: *Self, value: T) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.queue.append(value);
            self.cond.signal(self.io);
        }

        fn signalClose(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed_local = true;
            self.cond.broadcast(self.io);
        }
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn cloneU64(_: std.mem.Allocator, src: u64) error{OutOfMemory}!u64 {
    return src;
}

test "single subscriber receives published events in order" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bus = Broadcaster(u64).init(a, io, null);
    defer bus.deinit();

    const sub = try bus.subscribe();
    defer sub.unsubscribe();

    try bus.publishCloned(1, cloneU64);
    try bus.publishCloned(2, cloneU64);
    try bus.publishCloned(3, cloneU64);

    try testing.expectEqual(@as(?u64, 1), sub.tryNext());
    try testing.expectEqual(@as(?u64, 2), sub.tryNext());
    try testing.expectEqual(@as(?u64, 3), sub.tryNext());
    try testing.expect(sub.tryNext() == null);
}

test "multiple subscribers each see every event" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bus = Broadcaster(u64).init(a, io, null);
    defer bus.deinit();

    const sub_a = try bus.subscribe();
    defer sub_a.unsubscribe();
    const sub_b = try bus.subscribe();
    defer sub_b.unsubscribe();

    try bus.publishCloned(7, cloneU64);
    try bus.publishCloned(8, cloneU64);

    try testing.expectEqual(@as(?u64, 7), sub_a.tryNext());
    try testing.expectEqual(@as(?u64, 8), sub_a.tryNext());
    try testing.expectEqual(@as(?u64, 7), sub_b.tryNext());
    try testing.expectEqual(@as(?u64, 8), sub_b.tryNext());
}

test "close wakes blocked subscribers and yields null" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bus = Broadcaster(u64).init(a, io, null);

    const sub = try bus.subscribe();
    defer sub.unsubscribe();

    bus.close();
    bus.deinit();
    try testing.expect(sub.next() == null);
}

test "publish after close fails fast" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bus = Broadcaster(u64).init(a, io, null);

    bus.close();
    try testing.expectError(error.Closed, bus.publishCloned(1, cloneU64));
    bus.deinit();
}

test "late subscriber misses events published before subscribe" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bus = Broadcaster(u64).init(a, io, null);
    defer bus.deinit();

    const sub_a = try bus.subscribe();
    defer sub_a.unsubscribe();
    try bus.publishCloned(1, cloneU64);

    const sub_b = try bus.subscribe();
    defer sub_b.unsubscribe();
    try bus.publishCloned(2, cloneU64);

    try testing.expectEqual(@as(?u64, 1), sub_a.tryNext());
    try testing.expectEqual(@as(?u64, 2), sub_a.tryNext());
    try testing.expect(sub_a.tryNext() == null);

    try testing.expectEqual(@as(?u64, 2), sub_b.tryNext());
    try testing.expect(sub_b.tryNext() == null);
}

const StringEvent = struct {
    text: []const u8,
};

fn cloneStringEvent(allocator: std.mem.Allocator, src: StringEvent) error{OutOfMemory}!StringEvent {
    return .{ .text = try allocator.dupe(u8, src.text) };
}

fn deinitStringEvent(allocator: std.mem.Allocator, value: *StringEvent) void {
    allocator.free(value.text);
    value.* = undefined;
}

test "deinit_value frees pending events when subscription drops" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var bus = Broadcaster(StringEvent).init(a, io, deinitStringEvent);
    defer bus.deinit();

    const sub = try bus.subscribe();
    try bus.publishCloned(.{ .text = "hello" }, cloneStringEvent);
    try bus.publishCloned(.{ .text = "world" }, cloneStringEvent);
    // Don't drain — drop the subscription with two events still queued.
    sub.unsubscribe();
}
