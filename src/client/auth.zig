//! Authentication credentials store and interceptor.
const std = @import("std");
const a2a = @import("a2a");
const transport = @import("transport.zig");
const middleware = @import("middleware.zig");

const ServiceParams = transport.ServiceParams;
const CallInterceptor = middleware.CallInterceptor;

// ---------------------------------------------------------------------------
// CredentialsStore vtable
// ---------------------------------------------------------------------------

/// Trait for providing credentials for authentication. Implementations return
/// the credential string for a scheme name (or `null` when none is configured).
///
/// Returned slices are owned by the store; callers must `dupe` if they need to
/// retain them past the next mutation.
pub const CredentialsStore = struct {
    pub const Error = error{OutOfMemory};

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, scheme: []const u8) ?[]const u8,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn get(self: *const CredentialsStore, scheme: []const u8) ?[]const u8 {
        return self.vtable.get(self.ctx, scheme);
    }
};

// ---------------------------------------------------------------------------
// InMemoryCredentialsStore
// ---------------------------------------------------------------------------

/// Simple in-memory credentials store backed by a hash map.
///
/// This store is not thread-safe; wrap externally if you need concurrent
/// mutation. The common usage pattern (set credentials at startup, read them
/// per-request) is fine without locking on the read path.
pub const InMemoryCredentialsStore = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InMemoryCredentialsStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InMemoryCredentialsStore) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Insert or overwrite the credential for `scheme`. Both arguments are
    /// duplicated.
    pub fn set(self: *InMemoryCredentialsStore, scheme: []const u8, credential: []const u8) !void {
        const dup_cred = try self.allocator.dupe(u8, credential);
        errdefer self.allocator.free(dup_cred);

        const gop = try self.entries.getOrPut(self.allocator, scheme);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = dup_cred;
        } else {
            const dup_key = try self.allocator.dupe(u8, scheme);
            gop.key_ptr.* = dup_key;
            gop.value_ptr.* = dup_cred;
        }
    }

    pub fn get(self: *const InMemoryCredentialsStore, scheme: []const u8) ?[]const u8 {
        return self.entries.get(scheme);
    }

    pub fn store(self: *InMemoryCredentialsStore) CredentialsStore {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn vtableGet(ctx: *anyopaque, scheme: []const u8) ?[]const u8 {
        const self: *InMemoryCredentialsStore = @ptrCast(@alignCast(ctx));
        return self.get(scheme);
    }

    const vtable: CredentialsStore.VTable = .{ .get = vtableGet };
};

// ---------------------------------------------------------------------------
// AuthInterceptor — adds an Authorization-style header to outgoing requests.
// ---------------------------------------------------------------------------

pub const AuthInterceptor = struct {
    header_name: []const u8,
    header_value: []const u8,
    allocator: std.mem.Allocator,

    /// Build an interceptor that injects `Authorization: Bearer <token>`.
    pub fn bearer(allocator: std.mem.Allocator, token: []const u8) !AuthInterceptor {
        const name = try allocator.dupe(u8, "Authorization");
        errdefer allocator.free(name);
        const value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        return .{ .header_name = name, .header_value = value, .allocator = allocator };
    }

    /// Build an interceptor with an arbitrary header.
    pub fn custom(
        allocator: std.mem.Allocator,
        header_name: []const u8,
        header_value: []const u8,
    ) !AuthInterceptor {
        const name = try allocator.dupe(u8, header_name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header_value);
        return .{ .header_name = name, .header_value = value, .allocator = allocator };
    }

    pub fn deinit(self: *AuthInterceptor) void {
        self.allocator.free(self.header_name);
        self.allocator.free(self.header_value);
        self.* = undefined;
    }

    pub fn interceptor(self: *AuthInterceptor) CallInterceptor {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn before(ctx: *anyopaque, _: []const u8, params: *ServiceParams) CallInterceptor.Error!void {
        const self: *AuthInterceptor = @ptrCast(@alignCast(ctx));
        params.append(self.header_name, self.header_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    const vtable: CallInterceptor.VTable = .{
        .before = before,
    };
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "in-memory credentials store starts empty" {
    const a = testing.allocator;
    var s = InMemoryCredentialsStore.init(a);
    defer s.deinit();
    try testing.expect(s.get("anything") == null);
}

test "in-memory credentials store set+get" {
    const a = testing.allocator;
    var s = InMemoryCredentialsStore.init(a);
    defer s.deinit();
    try s.set("bearer", "token123");
    try testing.expectEqualStrings("token123", s.get("bearer").?);
}

test "in-memory credentials store overwrite" {
    const a = testing.allocator;
    var s = InMemoryCredentialsStore.init(a);
    defer s.deinit();
    try s.set("api-key", "first");
    try s.set("api-key", "second");
    try testing.expectEqualStrings("second", s.get("api-key").?);
}

test "credentials store vtable dispatches" {
    const a = testing.allocator;
    var s = InMemoryCredentialsStore.init(a);
    defer s.deinit();
    try s.set("api-key", "secret");
    const cs = s.store();
    try testing.expectEqualStrings("secret", cs.get("api-key").?);
    try testing.expect(cs.get("nonexistent") == null);
}

test "auth interceptor bearer adds Authorization header" {
    const a = testing.allocator;
    var ai = try AuthInterceptor.bearer(a, "mytoken");
    defer ai.deinit();
    var i = ai.interceptor();

    var params = ServiceParams.init(a);
    defer params.deinit();
    try i.before("test", &params);

    const auth = params.get("Authorization").?;
    try testing.expectEqual(@as(usize, 1), auth.len);
    try testing.expectEqualStrings("Bearer mytoken", auth[0]);
}

test "auth interceptor custom header" {
    const a = testing.allocator;
    var ai = try AuthInterceptor.custom(a, "X-API-Key", "key123");
    defer ai.deinit();
    var i = ai.interceptor();

    var params = ServiceParams.init(a);
    defer params.deinit();
    try i.before("test", &params);

    const apikey = params.get("X-API-Key").?;
    try testing.expectEqual(@as(usize, 1), apikey.len);
    try testing.expectEqualStrings("key123", apikey[0]);
}
