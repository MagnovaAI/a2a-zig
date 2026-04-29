//! Server-side request context and interceptor surface.
const std = @import("std");
const a2a = @import("a2a");

/// Authenticated user identity attached to a request.
pub const User = struct {
    name: []const u8,
    authenticated: bool = true,
    /// Arena-owned attribute map. The server fills this from auth middleware
    /// output; consumers read it but do not mutate it after the request
    /// reaches the executor.
    attributes: ?a2a.Metadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *User) void {
        self.allocator.free(self.name);
        if (self.attributes) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    /// Build an authenticated user with no extra attributes. Caller-owned name.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !User {
        return .{
            .name = try allocator.dupe(u8, name),
            .authenticated = true,
            .allocator = allocator,
        };
    }
};

/// Service parameters reaching the server side: HTTP headers and protocol
/// extension metadata, keyed by name. Mirrors the client `ServiceParams` so
/// interceptors can be shared between sides where it makes sense.
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

/// Per-request context threaded through interceptors and into the executor.
/// Owned by the request scope; freed when the response is finalized.
pub const CallContext = struct {
    method: []const u8,
    service_params: ServiceParams,
    tenant: ?[]const u8 = null,
    user: ?User = null,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        method: []const u8,
        params: ServiceParams,
    ) !CallContext {
        return .{
            .method = try allocator.dupe(u8, method),
            .service_params = params,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CallContext) void {
        self.allocator.free(self.method);
        self.service_params.deinit();
        if (self.tenant) |s| self.allocator.free(s);
        if (self.user) |*u| u.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "User.init produces an authenticated entry" {
    const a = testing.allocator;
    var u = try User.init(a, "alice");
    defer u.deinit();
    try testing.expectEqualStrings("alice", u.name);
    try testing.expect(u.authenticated);
    try testing.expect(u.attributes == null);
}

test "ServiceParams append + get" {
    const a = testing.allocator;
    var p = ServiceParams.init(a);
    defer p.deinit();
    try p.append("X-Tenant", "tenant-1");
    try p.append("X-Tenant", "tenant-2");
    const list = p.get("X-Tenant").?;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("tenant-1", list[0]);
    try testing.expectEqualStrings("tenant-2", list[1]);
}

test "CallContext owns its method and params" {
    const a = testing.allocator;
    var params = ServiceParams.init(a);
    try params.append("Content-Type", "application/json");
    var ctx = try CallContext.init(a, a2a.methods.SEND_MESSAGE, params);
    defer ctx.deinit();
    try testing.expectEqualStrings("SendMessage", ctx.method);
    try testing.expectEqual(@as(usize, 1), ctx.service_params.count());
    try testing.expect(ctx.user == null);
    try testing.expect(ctx.tenant == null);
}
