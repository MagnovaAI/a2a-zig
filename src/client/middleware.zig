//! Client-level call interceptors.
const std = @import("std");
const a2a = @import("a2a");
const transport = @import("transport.zig");

const ServiceParams = transport.ServiceParams;
const log = std.log.scoped(.a2a_client);

/// Result passed to `after` — either success (`null`) or a borrowed error code +
/// message. We use a reduced shape because the production hooks only inspect
/// the code; the full `A2AError` lifetime isn't worth threading through.
pub const CallResult = union(enum) {
    ok,
    err: struct {
        code: i32,
        message: []const u8,
    },
};

/// Interceptor for modifying requests and responses at the client level.
///
/// Concrete interceptors implement this vtable. The container that drives them
/// is responsible for calling `before` in registration order and `after` in
/// reverse — so wrappers nest cleanly around the call.
pub const CallInterceptor = struct {
    pub const Error = error{ OutOfMemory, InterceptorFailed };

    pub const VTable = struct {
        before: *const fn (
            ctx: *anyopaque,
            method: []const u8,
            params: *ServiceParams,
        ) Error!void = defaultBefore,

        after: *const fn (
            ctx: *anyopaque,
            method: []const u8,
            result: CallResult,
        ) Error!void = defaultAfter,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn before(self: *CallInterceptor, method: []const u8, params: *ServiceParams) Error!void {
        return self.vtable.before(self.ctx, method, params);
    }

    pub fn after(self: *CallInterceptor, method: []const u8, result: CallResult) Error!void {
        return self.vtable.after(self.ctx, method, result);
    }
};

fn defaultBefore(_: *anyopaque, _: []const u8, _: *ServiceParams) CallInterceptor.Error!void {}
fn defaultAfter(_: *anyopaque, _: []const u8, _: CallResult) CallInterceptor.Error!void {}

// ---------------------------------------------------------------------------
// LoggingInterceptor
// ---------------------------------------------------------------------------

pub const LoggingInterceptor = struct {
    state: u8 = 0, // dummy field so we have a valid `*anyopaque`

    pub fn interceptor(self: *LoggingInterceptor) CallInterceptor {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn before(_: *anyopaque, method: []const u8, _: *ServiceParams) CallInterceptor.Error!void {
        log.info("A2A client request: {s}", .{method});
    }

    fn after(_: *anyopaque, method: []const u8, result: CallResult) CallInterceptor.Error!void {
        switch (result) {
            .ok => log.info("A2A client response: {s}", .{method}),
            .err => |e| log.warn("A2A client error: {s} ({d}): {s}", .{ method, e.code, e.message }),
        }
    }

    const vtable: CallInterceptor.VTable = .{
        .before = before,
        .after = after,
    };
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const NoopInterceptor = struct {
    state: u8 = 0,

    pub fn interceptor(self: *NoopInterceptor) CallInterceptor {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: CallInterceptor.VTable = .{};
};

test "default before/after are no-ops" {
    const a = testing.allocator;
    var params = ServiceParams.init(a);
    defer params.deinit();
    var noop: NoopInterceptor = .{};
    var i = noop.interceptor();
    try i.before("test", &params);
    try i.after("test", .ok);
    try i.after("test", .{ .err = .{ .code = -32603, .message = "fail" } });
    try testing.expectEqual(@as(usize, 0), params.count());
}

test "logging interceptor smoke" {
    const a = testing.allocator;
    var params = ServiceParams.init(a);
    defer params.deinit();
    var li: LoggingInterceptor = .{};
    var i = li.interceptor();
    try i.before(a2a.methods.SEND_MESSAGE, &params);
    try i.after(a2a.methods.SEND_MESSAGE, .ok);
    try i.after(a2a.methods.SEND_MESSAGE, .{ .err = .{ .code = -32603, .message = "boom" } });
}
