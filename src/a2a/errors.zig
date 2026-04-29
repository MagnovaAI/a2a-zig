//! A2A protocol errors.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

/// A2A-specific error codes (JSON-RPC).
pub const code = struct {
    // A2A application errors
    pub const TASK_NOT_FOUND: i32 = -32001;
    pub const TASK_NOT_CANCELABLE: i32 = -32002;
    pub const PUSH_NOTIFICATION_NOT_SUPPORTED: i32 = -32003;
    pub const UNSUPPORTED_OPERATION: i32 = -32004;
    pub const CONTENT_TYPE_NOT_SUPPORTED: i32 = -32005;
    pub const INVALID_AGENT_RESPONSE: i32 = -32006;
    pub const EXTENDED_CARD_NOT_CONFIGURED: i32 = -32007;
    pub const EXTENSION_SUPPORT_REQUIRED: i32 = -32008;
    pub const VERSION_NOT_SUPPORTED: i32 = -32009;

    // Standard JSON-RPC errors
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
};

/// A2A protocol error.
///
/// `message` is owned by `allocator`. `details`, when set, is a `std.json.Value`
/// whose memory is owned by `details_arena`. The arena is freed in `deinit`.
pub const A2AError = struct {
    code: i32,
    message: []const u8,
    details: ?std.json.Value = null,
    details_arena: ?*std.heap.ArenaAllocator = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, c: i32, message: []const u8) !A2AError {
        return .{
            .code = c,
            .message = try allocator.dupe(u8, message),
            .details = null,
            .allocator = allocator,
        };
    }

    pub fn initFmt(
        allocator: std.mem.Allocator,
        c: i32,
        comptime fmt: []const u8,
        args: anytype,
    ) !A2AError {
        const msg = try std.fmt.allocPrint(allocator, fmt, args);
        return .{
            .code = c,
            .message = msg,
            .details = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *A2AError) void {
        self.allocator.free(self.message);
        if (self.details_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        self.* = undefined;
    }

    /// Attach details. The arena owns the json value's memory; ownership transfers here.
    pub fn withDetails(
        self: *A2AError,
        arena: *std.heap.ArenaAllocator,
        details: std.json.Value,
    ) void {
        if (self.details_arena) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        self.details_arena = arena;
        self.details = details;
    }

    // ---- convenience constructors ----

    pub fn taskNotFound(allocator: std.mem.Allocator, task_id: []const u8) !A2AError {
        return initFmt(allocator, code.TASK_NOT_FOUND, "task not found: {s}", .{task_id});
    }

    pub fn taskNotCancelable(allocator: std.mem.Allocator, task_id: []const u8) !A2AError {
        return initFmt(allocator, code.TASK_NOT_CANCELABLE, "task cannot be canceled: {s}", .{task_id});
    }

    pub fn pushNotificationNotSupported(allocator: std.mem.Allocator) !A2AError {
        return init(allocator, code.PUSH_NOTIFICATION_NOT_SUPPORTED, "push notification not supported");
    }

    pub fn unsupportedOperation(allocator: std.mem.Allocator, msg: []const u8) !A2AError {
        return init(allocator, code.UNSUPPORTED_OPERATION, msg);
    }

    pub fn contentTypeNotSupported(allocator: std.mem.Allocator) !A2AError {
        return init(allocator, code.CONTENT_TYPE_NOT_SUPPORTED, "incompatible content types");
    }

    pub fn invalidAgentResponse(allocator: std.mem.Allocator) !A2AError {
        return init(allocator, code.INVALID_AGENT_RESPONSE, "invalid agent response");
    }

    pub fn versionNotSupported(allocator: std.mem.Allocator, version: []const u8) !A2AError {
        return initFmt(allocator, code.VERSION_NOT_SUPPORTED, "version not supported: {s}", .{version});
    }

    pub fn internal(allocator: std.mem.Allocator, msg: []const u8) !A2AError {
        return init(allocator, code.INTERNAL_ERROR, msg);
    }

    pub fn invalidParams(allocator: std.mem.Allocator, msg: []const u8) !A2AError {
        return init(allocator, code.INVALID_PARAMS, msg);
    }

    pub fn parseError(allocator: std.mem.Allocator, msg: []const u8) !A2AError {
        return init(allocator, code.PARSE_ERROR, msg);
    }

    pub fn invalidRequest(allocator: std.mem.Allocator, msg: []const u8) !A2AError {
        return init(allocator, code.INVALID_REQUEST, msg);
    }

    pub fn methodNotFound(allocator: std.mem.Allocator, method: []const u8) !A2AError {
        return initFmt(allocator, code.METHOD_NOT_FOUND, "method not found: {s}", .{method});
    }

    /// Map A2A error code to HTTP status code for REST binding.
    pub fn httpStatusCode(self: *const A2AError) u16 {
        return switch (self.code) {
            code.TASK_NOT_FOUND => 404,
            code.TASK_NOT_CANCELABLE => 409,
            code.PUSH_NOTIFICATION_NOT_SUPPORTED => 400,
            code.UNSUPPORTED_OPERATION => 400,
            code.CONTENT_TYPE_NOT_SUPPORTED => 415,
            code.VERSION_NOT_SUPPORTED => 400,
            code.PARSE_ERROR => 400,
            code.INVALID_REQUEST => 400,
            code.METHOD_NOT_FOUND => 404,
            code.INVALID_PARAMS => 400,
            code.INTERNAL_ERROR => 500,
            else => 500,
        };
    }

    /// Convert to a JSON-RPC error object. Caller owns the result and must call `deinit`.
    /// If details are set, they are deep-cloned into a fresh arena owned by the result.
    pub fn toJsonRpcError(self: *const A2AError, allocator: std.mem.Allocator) !jsonrpc.JsonRpcError {
        var data: ?std.json.Value = null;
        var data_arena: ?*std.heap.ArenaAllocator = null;
        if (self.details) |d| {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer {
                arena.deinit();
                allocator.destroy(arena);
            }
            data = try cloneJsonValue(arena.allocator(), d);
            data_arena = arena;
        }
        return .{
            .code = self.code,
            .message = try allocator.dupe(u8, self.message),
            .data = data,
            .data_arena = data_arena,
            .allocator = allocator,
        };
    }
};

/// Deep-clone a `std.json.Value` into `allocator`.
pub fn cloneJsonValue(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try cloneJsonValue(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try out.put(allocator, k, val);
            }
            break :blk .{ .object = out };
        },
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "error constructors" {
    const a = testing.allocator;

    var e = try A2AError.taskNotFound(a, "t1");
    defer e.deinit();
    try testing.expectEqual(code.TASK_NOT_FOUND, e.code);
    try testing.expect(std.mem.indexOf(u8, e.message, "t1") != null);

    var e2 = try A2AError.taskNotCancelable(a, "t2");
    defer e2.deinit();
    try testing.expectEqual(code.TASK_NOT_CANCELABLE, e2.code);

    var e3 = try A2AError.pushNotificationNotSupported(a);
    defer e3.deinit();
    try testing.expectEqual(code.PUSH_NOTIFICATION_NOT_SUPPORTED, e3.code);

    var e4 = try A2AError.unsupportedOperation(a, "nope");
    defer e4.deinit();
    try testing.expectEqual(code.UNSUPPORTED_OPERATION, e4.code);

    var e5 = try A2AError.contentTypeNotSupported(a);
    defer e5.deinit();
    try testing.expectEqual(code.CONTENT_TYPE_NOT_SUPPORTED, e5.code);

    var e6 = try A2AError.invalidAgentResponse(a);
    defer e6.deinit();
    try testing.expectEqual(code.INVALID_AGENT_RESPONSE, e6.code);

    var e7 = try A2AError.versionNotSupported(a, "2.0");
    defer e7.deinit();
    try testing.expectEqual(code.VERSION_NOT_SUPPORTED, e7.code);

    var e8 = try A2AError.internal(a, "boom");
    defer e8.deinit();
    try testing.expectEqual(code.INTERNAL_ERROR, e8.code);

    var e9 = try A2AError.invalidParams(a, "bad param");
    defer e9.deinit();
    try testing.expectEqual(code.INVALID_PARAMS, e9.code);

    var e10 = try A2AError.parseError(a, "bad json");
    defer e10.deinit();
    try testing.expectEqual(code.PARSE_ERROR, e10.code);

    var e11 = try A2AError.invalidRequest(a, "bad req");
    defer e11.deinit();
    try testing.expectEqual(code.INVALID_REQUEST, e11.code);

    var e12 = try A2AError.methodNotFound(a, "foo");
    defer e12.deinit();
    try testing.expectEqual(code.METHOD_NOT_FOUND, e12.code);
}

test "http status codes" {
    const a = testing.allocator;

    var e1 = try A2AError.taskNotFound(a, "x");
    defer e1.deinit();
    try testing.expectEqual(@as(u16, 404), e1.httpStatusCode());

    var e2 = try A2AError.taskNotCancelable(a, "x");
    defer e2.deinit();
    try testing.expectEqual(@as(u16, 409), e2.httpStatusCode());

    var e3 = try A2AError.internal(a, "x");
    defer e3.deinit();
    try testing.expectEqual(@as(u16, 500), e3.httpStatusCode());

    var e4 = try A2AError.invalidParams(a, "x");
    defer e4.deinit();
    try testing.expectEqual(@as(u16, 400), e4.httpStatusCode());

    var e5 = try A2AError.contentTypeNotSupported(a);
    defer e5.deinit();
    try testing.expectEqual(@as(u16, 415), e5.httpStatusCode());

    var e6 = try A2AError.init(a, 9999, "unknown");
    defer e6.deinit();
    try testing.expectEqual(@as(u16, 500), e6.httpStatusCode());
}

test "http status codes for remaining a2a mappings" {
    const a = testing.allocator;

    var e1 = try A2AError.pushNotificationNotSupported(a);
    defer e1.deinit();
    try testing.expectEqual(@as(u16, 400), e1.httpStatusCode());

    var e2 = try A2AError.unsupportedOperation(a, "nope");
    defer e2.deinit();
    try testing.expectEqual(@as(u16, 400), e2.httpStatusCode());

    var e3 = try A2AError.versionNotSupported(a, "9.9");
    defer e3.deinit();
    try testing.expectEqual(@as(u16, 400), e3.httpStatusCode());

    var e4 = try A2AError.parseError(a, "bad");
    defer e4.deinit();
    try testing.expectEqual(@as(u16, 400), e4.httpStatusCode());

    var e5 = try A2AError.invalidRequest(a, "bad");
    defer e5.deinit();
    try testing.expectEqual(@as(u16, 400), e5.httpStatusCode());

    var e6 = try A2AError.methodNotFound(a, "missing");
    defer e6.deinit();
    try testing.expectEqual(@as(u16, 404), e6.httpStatusCode());
}

test "to_jsonrpc_error" {
    const a = testing.allocator;
    var e = try A2AError.taskNotFound(a, "t1");
    defer e.deinit();

    var rpc = try e.toJsonRpcError(a);
    defer rpc.deinit();
    try testing.expectEqual(code.TASK_NOT_FOUND, rpc.code);
    try testing.expect(std.mem.indexOf(u8, rpc.message, "t1") != null);
    try testing.expect(rpc.data == null);
}

test "with_details" {
    const a = testing.allocator;
    var e = try A2AError.internal(a, "err");
    defer e.deinit();

    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    const aa = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, try aa.dupe(u8, "key"), .{ .string = try aa.dupe(u8, "val") });
    e.withDetails(arena, .{ .object = obj });

    try testing.expect(e.details != null);
    var rpc = try e.toJsonRpcError(a);
    defer rpc.deinit();
    try testing.expect(rpc.data != null);
}
