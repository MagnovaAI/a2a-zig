//! Push notification config persistence.
//!
//! `PushConfigStore` is the vtable every backend implements; the handler
//! owns one and consults it on every push-config CRUD method. The bundled
//! `InMemoryPushConfigStore` stores configs in a nested map keyed by
//! `(task_id, config_id)` and is the obvious default for tests and small
//! deployments. Production deployments will plug in their own backend
//! (Postgres, Redis, etc.) by implementing the vtable.
const std = @import("std");
const a2a = @import("a2a");

/// Vtable for push-config storage backends.
pub const PushConfigStore = struct {
    pub const Error = error{
        OutOfMemory,
        NotFound,
        InvalidArgument,
        StorageFailed,
    };

    pub const VTable = struct {
        /// Persist `config` for `task_id`. The store must assign a fresh id
        /// when `config.id` is null and return the stored copy. The returned
        /// config is owned by `request_allocator`.
        save: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            task_id: []const u8,
            config: *const a2a.PushNotificationConfig,
        ) Error!a2a.PushNotificationConfig,

        /// Fetch a single config by `(task_id, config_id)`. Returns
        /// `error.NotFound` when the pair is unknown.
        get: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            task_id: []const u8,
            config_id: []const u8,
        ) Error!a2a.PushNotificationConfig,

        /// List every config registered for `task_id`. Returns an empty slice
        /// when no configs are registered. The slice and its contents are
        /// owned by `request_allocator`.
        list: *const fn (
            ctx: *anyopaque,
            request_allocator: std.mem.Allocator,
            task_id: []const u8,
        ) Error![]a2a.PushNotificationConfig,

        /// Drop a single config. Idempotent — a missing pair is not an error.
        delete: *const fn (
            ctx: *anyopaque,
            task_id: []const u8,
            config_id: []const u8,
        ) Error!void,

        /// Drop every config for a task. Idempotent.
        deleteAll: *const fn (
            ctx: *anyopaque,
            task_id: []const u8,
        ) Error!void,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn save(
        self: *const PushConfigStore,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
        config: *const a2a.PushNotificationConfig,
    ) Error!a2a.PushNotificationConfig {
        return self.vtable.save(self.ctx, request_allocator, task_id, config);
    }

    pub fn get(
        self: *const PushConfigStore,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
        config_id: []const u8,
    ) Error!a2a.PushNotificationConfig {
        return self.vtable.get(self.ctx, request_allocator, task_id, config_id);
    }

    pub fn list(
        self: *const PushConfigStore,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
    ) Error![]a2a.PushNotificationConfig {
        return self.vtable.list(self.ctx, request_allocator, task_id);
    }

    pub fn delete(
        self: *const PushConfigStore,
        task_id: []const u8,
        config_id: []const u8,
    ) Error!void {
        return self.vtable.delete(self.ctx, task_id, config_id);
    }

    pub fn deleteAll(
        self: *const PushConfigStore,
        task_id: []const u8,
    ) Error!void {
        return self.vtable.deleteAll(self.ctx, task_id);
    }
};

/// Deep-clone a push config into `dst`. The native config is shallow
/// (only string fields and an optional auth substruct) so we duplicate
/// everything by hand instead of round-tripping through protobuf.
fn cloneConfig(
    dst: std.mem.Allocator,
    src: a2a.PushNotificationConfig,
) error{OutOfMemory}!a2a.PushNotificationConfig {
    var out: a2a.PushNotificationConfig = .{
        .url = try dst.dupe(u8, src.url),
        .allocator = dst,
    };
    errdefer out.deinit();
    if (src.id) |s| out.id = try dst.dupe(u8, s);
    if (src.token) |s| out.token = try dst.dupe(u8, s);
    if (src.authentication) |auth| {
        var cloned: a2a.AuthenticationInfo = .{
            .scheme = try dst.dupe(u8, auth.scheme),
            .allocator = dst,
        };
        errdefer cloned.deinit();
        if (auth.credentials) |c| cloned.credentials = try dst.dupe(u8, c);
        out.authentication = cloned;
    }
    return out;
}

// ---------------------------------------------------------------------------
// In-memory backend
// ---------------------------------------------------------------------------

/// One stored config. Owned by its dedicated arena so freeing the arena
/// drops every byte associated with the entry.
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    config: a2a.PushNotificationConfig,
};

const ConfigMap = std.StringArrayHashMapUnmanaged(*Entry);

/// Volatile in-memory store. Thread-safe via `std.Io.Mutex`. Configs are
/// deep-cloned on insert and again on every read so the store and the
/// caller never share heap state.
pub const InMemoryPushConfigStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// task_id -> (config_id -> Entry).
    tasks: std.StringArrayHashMapUnmanaged(*ConfigMap) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) InMemoryPushConfigStore {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *InMemoryPushConfigStore) void {
        // Single-threaded teardown by contract.
        var task_it = self.tasks.iterator();
        while (task_it.next()) |task_entry| {
            self.allocator.free(task_entry.key_ptr.*);
            const map = task_entry.value_ptr.*;
            var cfg_it = map.iterator();
            while (cfg_it.next()) |cfg_entry| {
                self.allocator.free(cfg_entry.key_ptr.*);
                destroyEntry(self.allocator, cfg_entry.value_ptr.*);
            }
            map.deinit(self.allocator);
            self.allocator.destroy(map);
        }
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Wrap this store in the vtable interface used by the handler.
    pub fn store(self: *InMemoryPushConfigStore) PushConfigStore {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn destroyEntry(allocator: std.mem.Allocator, entry: *Entry) void {
        entry.arena.deinit();
        allocator.destroy(entry);
    }

    fn lock(self: *InMemoryPushConfigStore) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *InMemoryPushConfigStore) void {
        self.mutex.unlock(self.io);
    }

    fn lookupTaskMap(self: *InMemoryPushConfigStore, task_id: []const u8) ?*ConfigMap {
        return self.tasks.get(task_id);
    }

    fn ensureTaskMap(self: *InMemoryPushConfigStore, task_id: []const u8) !*ConfigMap {
        if (self.tasks.get(task_id)) |existing| return existing;
        const owned_id = try self.allocator.dupe(u8, task_id);
        errdefer self.allocator.free(owned_id);
        const map = try self.allocator.create(ConfigMap);
        errdefer self.allocator.destroy(map);
        map.* = .empty;
        try self.tasks.put(self.allocator, owned_id, map);
        return map;
    }

    fn buildEntry(
        self: *InMemoryPushConfigStore,
        config: a2a.PushNotificationConfig,
    ) !*Entry {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer entry.arena.deinit();
        const aa = entry.arena.allocator();
        entry.config = try cloneConfig(aa, config);
        return entry;
    }

    // ---- vtable wrappers ----

    fn vSave(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
        config: *const a2a.PushNotificationConfig,
    ) PushConfigStore.Error!a2a.PushNotificationConfig {
        const self: *InMemoryPushConfigStore = @ptrCast(@alignCast(ctx));
        if (config.url.len == 0) return PushConfigStore.Error.InvalidArgument;

        // Make a working copy of the config that we'll mutate (assigning an
        // id when the caller didn't provide one). The clone uses our storage
        // allocator so we can move it straight into the entry.
        var with_id = cloneConfig(self.allocator, config.*) catch return PushConfigStore.Error.OutOfMemory;
        defer with_id.deinit();
        if (with_id.id == null) {
            const fresh = a2a.newTaskId(self.allocator) catch return PushConfigStore.Error.OutOfMemory;
            with_id.id = fresh;
        }
        const config_id = with_id.id.?;

        self.lock();
        defer self.unlock();
        const map = self.ensureTaskMap(task_id) catch |err| return switch (err) {
            error.OutOfMemory => PushConfigStore.Error.OutOfMemory,
        };
        const entry = self.buildEntry(with_id) catch |err| return switch (err) {
            error.OutOfMemory => PushConfigStore.Error.OutOfMemory,
        };

        // Replace any existing entry with this id.
        if (map.fetchOrderedRemove(config_id)) |old| {
            self.allocator.free(old.key);
            destroyEntry(self.allocator, old.value);
        }

        const owned_cfg_id = self.allocator.dupe(u8, config_id) catch {
            destroyEntry(self.allocator, entry);
            return PushConfigStore.Error.OutOfMemory;
        };
        map.put(self.allocator, owned_cfg_id, entry) catch {
            self.allocator.free(owned_cfg_id);
            destroyEntry(self.allocator, entry);
            return PushConfigStore.Error.OutOfMemory;
        };

        return cloneConfig(request_allocator, entry.config) catch PushConfigStore.Error.OutOfMemory;
    }

    fn vGet(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
        config_id: []const u8,
    ) PushConfigStore.Error!a2a.PushNotificationConfig {
        const self: *InMemoryPushConfigStore = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        const map = self.lookupTaskMap(task_id) orelse return PushConfigStore.Error.NotFound;
        const entry = map.get(config_id) orelse return PushConfigStore.Error.NotFound;
        return cloneConfig(request_allocator, entry.config) catch PushConfigStore.Error.OutOfMemory;
    }

    fn vList(
        ctx: *anyopaque,
        request_allocator: std.mem.Allocator,
        task_id: []const u8,
    ) PushConfigStore.Error![]a2a.PushNotificationConfig {
        const self: *InMemoryPushConfigStore = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        const map = self.lookupTaskMap(task_id) orelse {
            return request_allocator.alloc(a2a.PushNotificationConfig, 0) catch
                PushConfigStore.Error.OutOfMemory;
        };
        const out = request_allocator.alloc(a2a.PushNotificationConfig, map.count()) catch
            return PushConfigStore.Error.OutOfMemory;
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |*c| c.deinit();
            request_allocator.free(out);
        }
        var it = map.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = cloneConfig(request_allocator, e.value_ptr.*.config) catch
                return PushConfigStore.Error.OutOfMemory;
        }
        return out;
    }

    fn vDelete(
        ctx: *anyopaque,
        task_id: []const u8,
        config_id: []const u8,
    ) PushConfigStore.Error!void {
        const self: *InMemoryPushConfigStore = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        const map = self.lookupTaskMap(task_id) orelse return;
        if (map.fetchOrderedRemove(config_id)) |old| {
            self.allocator.free(old.key);
            destroyEntry(self.allocator, old.value);
        }
    }

    fn vDeleteAll(
        ctx: *anyopaque,
        task_id: []const u8,
    ) PushConfigStore.Error!void {
        const self: *InMemoryPushConfigStore = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        if (self.tasks.fetchOrderedRemove(task_id)) |old_task| {
            self.allocator.free(old_task.key);
            const map = old_task.value;
            var it = map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                destroyEntry(self.allocator, e.value_ptr.*);
            }
            map.deinit(self.allocator);
            self.allocator.destroy(map);
        }
    }

    const vtable: PushConfigStore.VTable = .{
        .save = vSave,
        .get = vGet,
        .list = vList,
        .delete = vDelete,
        .deleteAll = vDeleteAll,
    };
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeConfig(allocator: std.mem.Allocator, url: []const u8) !a2a.PushNotificationConfig {
    return .{
        .url = try allocator.dupe(u8, url),
        .allocator = allocator,
    };
}

test "save without id assigns one and round-trips through get" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var cfg = try makeConfig(a, "https://example.com/hook");
    defer cfg.deinit();
    var saved = try store.save(a, "t1", &cfg);
    defer saved.deinit();
    try testing.expect(saved.id != null);

    var got = try store.get(a, "t1", saved.id.?);
    defer got.deinit();
    try testing.expectEqualStrings("https://example.com/hook", got.url);
}

test "save preserves caller-provided id" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var cfg = try makeConfig(a, "https://example.com/hook");
    cfg.id = try a.dupe(u8, "my-id");
    defer cfg.deinit();
    var saved = try store.save(a, "t1", &cfg);
    defer saved.deinit();
    try testing.expectEqualStrings("my-id", saved.id.?);
}

test "save rejects empty url" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var cfg = try makeConfig(a, "");
    defer cfg.deinit();
    try testing.expectError(PushConfigStore.Error.InvalidArgument, store.save(a, "t1", &cfg));
}

test "get on unknown id is NotFound" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();
    try testing.expectError(PushConfigStore.Error.NotFound, store.get(a, "t1", "nope"));
}

test "list returns every config registered for the task" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var c1 = try makeConfig(a, "https://a.com");
    defer c1.deinit();
    var c2 = try makeConfig(a, "https://b.com");
    defer c2.deinit();
    var c3 = try makeConfig(a, "https://c.com");
    defer c3.deinit();

    var s1 = try store.save(a, "t1", &c1);
    defer s1.deinit();
    var s2 = try store.save(a, "t1", &c2);
    defer s2.deinit();
    var s3 = try store.save(a, "t2", &c3);
    defer s3.deinit();

    const list_t1 = try store.list(a, "t1");
    defer {
        for (list_t1) |*c| @constCast(c).deinit();
        a.free(list_t1);
    }
    try testing.expectEqual(@as(usize, 2), list_t1.len);

    const list_t2 = try store.list(a, "t2");
    defer {
        for (list_t2) |*c| @constCast(c).deinit();
        a.free(list_t2);
    }
    try testing.expectEqual(@as(usize, 1), list_t2.len);

    const list_t3 = try store.list(a, "t3");
    defer a.free(list_t3);
    try testing.expectEqual(@as(usize, 0), list_t3.len);
}

test "delete makes get return NotFound" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var cfg = try makeConfig(a, "https://a.com");
    defer cfg.deinit();
    var saved = try store.save(a, "t1", &cfg);
    defer saved.deinit();
    const id = saved.id.?;

    try store.delete("t1", id);
    try testing.expectError(PushConfigStore.Error.NotFound, store.get(a, "t1", id));
}

test "delete on unknown task is a no-op" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();
    try store.delete("nope", "nope"); // must not error
}

test "deleteAll drops every config for the task" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var c1 = try makeConfig(a, "https://a.com");
    defer c1.deinit();
    var c2 = try makeConfig(a, "https://b.com");
    defer c2.deinit();

    var s1 = try store.save(a, "t1", &c1);
    defer s1.deinit();
    var s2 = try store.save(a, "t1", &c2);
    defer s2.deinit();

    try store.deleteAll("t1");
    const list = try store.list(a, "t1");
    defer a.free(list);
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "save with an existing id overwrites the previous entry" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = InMemoryPushConfigStore.init(a, io);
    defer s.deinit();
    const store = s.store();

    var c1 = try makeConfig(a, "https://first.com");
    c1.id = try a.dupe(u8, "shared");
    defer c1.deinit();
    var c2 = try makeConfig(a, "https://second.com");
    c2.id = try a.dupe(u8, "shared");
    defer c2.deinit();

    var s1 = try store.save(a, "t1", &c1);
    defer s1.deinit();
    var s2 = try store.save(a, "t1", &c2);
    defer s2.deinit();

    var got = try store.get(a, "t1", "shared");
    defer got.deinit();
    try testing.expectEqualStrings("https://second.com", got.url);
}
