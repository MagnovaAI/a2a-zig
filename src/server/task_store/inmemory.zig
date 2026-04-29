//! In-memory task store. Volatile — contents do not survive process restart.
//!
//! Tasks are deep-cloned on insert and deep-cloned again on read, so the
//! store and the caller never share heap state. Cloning routes through the
//! protobuf conversion layer, which gives us a free, well-tested deep copy.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");
const store_mod = @import("store.zig");

pub const TaskStore = store_mod.TaskStore;
pub const TaskVersion = store_mod.TaskVersion;

const Entry = struct {
    /// Storage allocator used to own this entry's deep clone of the task.
    arena: std.heap.ArenaAllocator,
    task: a2a.Task,
    version: TaskVersion,
};

pub const InMemoryTaskStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.StringArrayHashMapUnmanaged(*Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) InMemoryTaskStore {
        return .{ .allocator = allocator, .io = io };
    }

    fn lock(self: *InMemoryTaskStore) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *InMemoryTaskStore) void {
        self.mutex.unlock(self.io);
    }

    pub fn deinit(self: *InMemoryTaskStore) void {
        // Teardown is single-threaded by contract; no locking needed and
        // taking the lock here is unsafe because we then `undefined` the
        // struct that backs the mutex.
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            destroyEntry(self.allocator, e.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn store(self: *InMemoryTaskStore) TaskStore {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn destroyEntry(allocator: std.mem.Allocator, entry: *Entry) void {
        entry.arena.deinit();
        allocator.destroy(entry);
    }

    /// Deep-clone a task into its own arena. The returned entry owns the
    /// clone; freeing the arena drops every byte associated with it.
    fn cloneTask(self: *InMemoryTaskStore, task: *const a2a.Task) !*Entry {
        const entry = try self.allocator.create(Entry);
        entry.* = .{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .task = undefined,
            .version = 0,
        };
        errdefer {
            entry.arena.deinit();
            self.allocator.destroy(entry);
        }
        const aa = entry.arena.allocator();
        var pb_task = try pb.conv.taskToProto(aa, task.*);
        defer pb_task.deinit(aa);
        entry.task = try pb.conv.taskFromProto(aa, pb_task);
        return entry;
    }

    fn cloneOut(allocator: std.mem.Allocator, src: *const a2a.Task) !a2a.Task {
        var pb_task = try pb.conv.taskToProto(allocator, src.*);
        defer pb_task.deinit(allocator);
        return pb.conv.taskFromProto(allocator, pb_task);
    }

    fn vtCreate(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        task: *const a2a.Task,
    ) TaskStore.Error!TaskVersion {
        return error_mod: {
            const self: *InMemoryTaskStore = @ptrCast(@alignCast(ctx));
            self.lock();
            defer self.unlock();

            if (self.entries.contains(task.id)) break :error_mod TaskStore.Error.AlreadyExists;

            const entry = self.cloneTask(task) catch break :error_mod TaskStore.Error.OutOfMemory;
            errdefer destroyEntry(self.allocator, entry);
            entry.version = 1;

            const owned_key = self.allocator.dupe(u8, task.id) catch break :error_mod TaskStore.Error.OutOfMemory;
            errdefer self.allocator.free(owned_key);

            self.entries.put(self.allocator, owned_key, entry) catch break :error_mod TaskStore.Error.OutOfMemory;
            break :error_mod 1;
        };
    }

    fn vtUpdate(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        task: *const a2a.Task,
    ) TaskStore.Error!TaskVersion {
        return error_mod: {
            const self: *InMemoryTaskStore = @ptrCast(@alignCast(ctx));
            self.lock();
            defer self.unlock();

            const old_entry = self.entries.get(task.id) orelse break :error_mod TaskStore.Error.NotFound;
            const new_entry = self.cloneTask(task) catch break :error_mod TaskStore.Error.OutOfMemory;
            new_entry.version = old_entry.version + 1;

            // Replace in-place; the key memory is owned by the map already.
            self.entries.getPtr(task.id).?.* = new_entry;
            destroyEntry(self.allocator, old_entry);
            break :error_mod new_entry.version;
        };
    }

    fn vtGet(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
    ) TaskStore.Error!?a2a.Task {
        const self: *InMemoryTaskStore = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();

        const entry = self.entries.get(task_id) orelse return null;
        return cloneOut(request_allocator, &entry.task) catch TaskStore.Error.OutOfMemory;
    }

    fn vtList(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        req: *const a2a.ListTasksRequest,
    ) TaskStore.Error!a2a.ListTasksResponse {
        const self: *InMemoryTaskStore = @ptrCast(@alignCast(ctx));
        return self.listImpl(request_allocator, req) catch |err| switch (err) {
            error.OutOfMemory => TaskStore.Error.OutOfMemory,
            else => TaskStore.Error.StorageFailed,
        };
    }

    fn listImpl(
        self: *InMemoryTaskStore,
        request_allocator: std.mem.Allocator,
        req: *const a2a.ListTasksRequest,
    ) !a2a.ListTasksResponse {
        self.lock();
        defer self.unlock();

        // Collect filtered borrowed pointers, then sort by id.
        var matched: std.array_list.Managed(*Entry) = .init(request_allocator);
        defer matched.deinit();

        var it = self.entries.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (req.context_id) |cid| {
                if (!std.mem.eql(u8, entry.task.context_id, cid)) continue;
            }
            if (req.status) |status| {
                if (entry.task.status.state != status) continue;
            }
            try matched.append(entry);
        }

        std.sort.pdq(*Entry, matched.items, {}, struct {
            fn lessThan(_: void, a: *Entry, b: *Entry) bool {
                return std.mem.lessThan(u8, a.task.id, b.task.id);
            }
        }.lessThan);

        const default_page_size: i32 = 50;
        const page_size: i32 = blk: {
            if (req.page_size) |n| if (n > 0) break :blk n;
            break :blk default_page_size;
        };
        const start: usize = blk: {
            if (req.page_token) |tok| {
                if (std.fmt.parseInt(usize, tok, 10)) |n| break :blk n else |_| break :blk 0;
            }
            break :blk 0;
        };
        const total: usize = matched.items.len;
        const end: usize = @min(start + @as(usize, @intCast(page_size)), total);

        const window = matched.items[start..end];
        const out_tasks = try request_allocator.alloc(a2a.Task, window.len);
        var written: usize = 0;
        errdefer {
            for (out_tasks[0..written]) |*t| t.deinit();
            request_allocator.free(out_tasks);
        }
        while (written < window.len) : (written += 1) {
            out_tasks[written] = try cloneOut(request_allocator, &window[written].task);
            try truncateHistory(request_allocator, &out_tasks[written], req.history_length);
        }

        const next_token: []const u8 = if (end < total)
            try std.fmt.allocPrint(request_allocator, "{d}", .{end})
        else
            try request_allocator.dupe(u8, "");

        return .{
            .tasks = out_tasks,
            .next_page_token = next_token,
            .page_size = page_size,
            .total_size = @intCast(total),
            .allocator = request_allocator,
        };
    }

    fn truncateHistory(
        allocator: std.mem.Allocator,
        task: *a2a.Task,
        history_length: ?i32,
    ) !void {
        const hl_opt = history_length orelse return;
        const hl: usize = @intCast(@max(0, hl_opt));
        const history = task.history orelse return;
        if (hl == 0) {
            for (history) |*m| m.deinit();
            allocator.free(history);
            task.history = null;
            return;
        }
        if (history.len <= hl) return;
        const skip = history.len - hl;
        for (history[0..skip]) |*m| m.deinit();
        const trimmed = try allocator.alloc(a2a.Message, hl);
        @memcpy(trimmed, history[skip..]);
        allocator.free(history);
        task.history = trimmed;
    }

    const vtable: TaskStore.VTable = .{
        .create = vtCreate,
        .update = vtUpdate,
        .get = vtGet,
        .list = vtList,
    };
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeTask(allocator: std.mem.Allocator, id: []const u8, ctx: []const u8, state: a2a.TaskState) !a2a.Task {
    return .{
        .id = try allocator.dupe(u8, id),
        .context_id = try allocator.dupe(u8, ctx),
        .status = .{ .state = state, .allocator = allocator },
        .allocator = allocator,
    };
}

test "create and get" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t = try makeTask(a, "t1", "c1", .submitted);
    defer t.deinit();
    const ver = try ts.create(a, &t);
    try testing.expectEqual(@as(TaskVersion, 1), ver);

    var got = (try ts.get(a, "t1")).?;
    defer got.deinit();
    try testing.expectEqualStrings("t1", got.id);
    try testing.expectEqualStrings("c1", got.context_id);
}

test "create rejects duplicates" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t1 = try makeTask(a, "t1", "c1", .submitted);
    defer t1.deinit();
    _ = try ts.create(a, &t1);

    var t2 = try makeTask(a, "t1", "c1", .submitted);
    defer t2.deinit();
    try testing.expectError(TaskStore.Error.AlreadyExists, ts.create(a, &t2));
}

test "update bumps version and replaces state" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t = try makeTask(a, "t1", "c1", .submitted);
    defer t.deinit();
    _ = try ts.create(a, &t);

    var t2 = try makeTask(a, "t1", "c1", .working);
    defer t2.deinit();
    const ver = try ts.update(a, &t2);
    try testing.expectEqual(@as(TaskVersion, 2), ver);

    var got = (try ts.get(a, "t1")).?;
    defer got.deinit();
    try testing.expectEqual(a2a.TaskState.working, got.status.state);
}

test "update on missing task errors" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t = try makeTask(a, "ghost", "c", .working);
    defer t.deinit();
    try testing.expectError(TaskStore.Error.NotFound, ts.update(a, &t));
}

test "get returns null for unknown id" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();
    try testing.expect((try ts.get(a, "nope")) == null);
}

test "list filters by context id" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t1 = try makeTask(a, "t1", "c1", .submitted);
    defer t1.deinit();
    var t2 = try makeTask(a, "t2", "c2", .working);
    defer t2.deinit();
    var t3 = try makeTask(a, "t3", "c1", .completed);
    defer t3.deinit();
    _ = try ts.create(a, &t1);
    _ = try ts.create(a, &t2);
    _ = try ts.create(a, &t3);

    var req = a2a.ListTasksRequest{ .allocator = a };
    defer req.deinit();
    req.context_id = try a.dupe(u8, "c1");
    var resp = try ts.list(a, &req);
    defer resp.deinit();
    try testing.expectEqual(@as(usize, 2), resp.tasks.len);
    try testing.expectEqual(@as(i32, 2), resp.total_size);
}

test "list filters by status" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t1 = try makeTask(a, "t1", "c1", .submitted);
    defer t1.deinit();
    var t2 = try makeTask(a, "t2", "c1", .working);
    defer t2.deinit();
    _ = try ts.create(a, &t1);
    _ = try ts.create(a, &t2);

    var req = a2a.ListTasksRequest{ .allocator = a };
    defer req.deinit();
    req.status = .working;
    var resp = try ts.list(a, &req);
    defer resp.deinit();
    try testing.expectEqual(@as(usize, 1), resp.tasks.len);
    try testing.expectEqualStrings("t2", resp.tasks[0].id);
}

test "list paginates with token continuation" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var name_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&name_buf, "t{d}", .{i});
        var t = try makeTask(a, id, "c1", .submitted);
        defer t.deinit();
        _ = try ts.create(a, &t);
    }

    var req = a2a.ListTasksRequest{ .allocator = a };
    defer req.deinit();
    req.page_size = 2;
    var resp = try ts.list(a, &req);
    defer resp.deinit();
    try testing.expectEqual(@as(usize, 2), resp.tasks.len);
    try testing.expectEqual(@as(i32, 5), resp.total_size);
    try testing.expect(resp.next_page_token.len > 0);

    var req2 = a2a.ListTasksRequest{ .allocator = a };
    defer req2.deinit();
    req2.page_size = 2;
    req2.page_token = try a.dupe(u8, resp.next_page_token);
    var resp2 = try ts.list(a, &req2);
    defer resp2.deinit();
    try testing.expectEqual(@as(usize, 2), resp2.tasks.len);
}

test "list with zero page_size falls back to default window" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "t{d}", .{i});
        var t = try makeTask(a, id, "c1", .submitted);
        defer t.deinit();
        _ = try ts.create(a, &t);
    }

    var req = a2a.ListTasksRequest{ .allocator = a };
    defer req.deinit();
    req.page_size = 0;
    var resp = try ts.list(a, &req);
    defer resp.deinit();
    try testing.expectEqual(@as(usize, 3), resp.tasks.len);
    try testing.expectEqual(@as(i32, 50), resp.page_size);
}

test "list truncates history to history_length" {
    const a = testing.allocator;
    var s = InMemoryTaskStore.init(a, std.Io.Threaded.global_single_threaded.io());
    defer s.deinit();
    const ts = s.store();

    var t = try makeTask(a, "t1", "c1", .working);
    defer t.deinit();
    const history = try a.alloc(a2a.Message, 3);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const parts = try a.alloc(a2a.Part, 1);
        var name_buf: [2]u8 = undefined;
        const text = try std.fmt.bufPrint(&name_buf, "{d}", .{i + 1});
        parts[0] = try a2a.Part.text(a, text);
        history[i] = try a2a.Message.init(a, if (i % 2 == 0) .user else .agent, parts);
    }
    t.history = history;
    _ = try ts.create(a, &t);

    var req = a2a.ListTasksRequest{ .allocator = a };
    defer req.deinit();
    req.history_length = 1;
    var resp = try ts.list(a, &req);
    defer resp.deinit();
    try testing.expect(resp.tasks[0].history != null);
    try testing.expectEqual(@as(usize, 1), resp.tasks[0].history.?.len);
}
