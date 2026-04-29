//! JSON-RPC 2.0 envelope types.
const std = @import("std");

/// JSON-RPC ID — string, integer, or null.
pub const JsonRpcId = union(enum) {
    string: []const u8,
    number: i64,
    null,

    pub fn deinit(self: *JsonRpcId, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
        self.* = .null;
    }

    pub fn fromString(allocator: std.mem.Allocator, s: []const u8) !JsonRpcId {
        return .{ .string = try allocator.dupe(u8, s) };
    }

    pub fn fromNumber(n: i64) JsonRpcId {
        return .{ .number = n };
    }

    pub fn eql(self: JsonRpcId, other: JsonRpcId) bool {
        return switch (self) {
            .string => |a| switch (other) {
                .string => |b| std.mem.eql(u8, a, b),
                else => false,
            },
            .number => |a| switch (other) {
                .number => |b| a == b,
                else => false,
            },
            .null => other == .null,
        };
    }

    pub fn jsonStringify(self: JsonRpcId, jw: anytype) !void {
        switch (self) {
            .string => |s| try jw.write(s),
            .number => |n| try jw.write(n),
            .null => try jw.write(null),
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !JsonRpcId {
        const v = try std.json.Value.jsonParse(allocator, source, options);
        return fromValue(allocator, v);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !JsonRpcId {
        return fromValue(allocator, source);
    }

    fn fromValue(allocator: std.mem.Allocator, v: std.json.Value) error{ OutOfMemory, UnexpectedToken }!JsonRpcId {
        return switch (v) {
            .null => .null,
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .integer => |i| .{ .number = i },
            .number_string => |s| blk: {
                const n = std.fmt.parseInt(i64, s, 10) catch return error.UnexpectedToken;
                break :blk .{ .number = n };
            },
            .float => error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }
};

/// JSON-RPC 2.0 error object.
///
/// `message` is owned by `allocator`. `data`, when set, is owned by `data_arena`.
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
    data_arena: ?*std.heap.ArenaAllocator = null,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *JsonRpcError) void {
        if (self.allocator) |a| {
            a.free(self.message);
            if (self.data_arena) |arena| {
                arena.deinit();
                a.destroy(arena);
            }
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: JsonRpcError, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(self.code);
        try jw.objectField("message");
        try jw.write(self.message);
        if (self.data) |d| {
            try jw.objectField("data");
            try jw.write(d);
        }
        try jw.endObject();
    }
};

/// JSON-RPC 2.0 request envelope.
///
/// `jsonrpc`, `method` are owned by `allocator`. `params`, when set, is owned by `params_arena`.
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    id: JsonRpcId,
    method: []const u8,
    params: ?std.json.Value = null,
    params_arena: ?*std.heap.ArenaAllocator = null,
    allocator: ?std.mem.Allocator = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: JsonRpcId,
        method: []const u8,
        params: ?std.json.Value,
        params_arena: ?*std.heap.ArenaAllocator,
    ) !JsonRpcRequest {
        return .{
            .jsonrpc = try allocator.dupe(u8, "2.0"),
            .id = id,
            .method = try allocator.dupe(u8, method),
            .params = params,
            .params_arena = params_arena,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JsonRpcRequest) void {
        if (self.allocator) |a| {
            a.free(self.jsonrpc);
            a.free(self.method);
            self.id.deinit(a);
            if (self.params_arena) |arena| {
                arena.deinit();
                a.destroy(arena);
            }
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: JsonRpcRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(self.jsonrpc);
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("method");
        try jw.write(self.method);
        if (self.params) |p| {
            try jw.objectField("params");
            try jw.write(p);
        }
        try jw.endObject();
    }
};

/// JSON-RPC 2.0 response envelope.
///
/// `result`, when set, is owned by `result_arena`.
pub const JsonRpcResponse = struct {
    jsonrpc: []const u8,
    id: JsonRpcId,
    result: ?std.json.Value = null,
    result_arena: ?*std.heap.ArenaAllocator = null,
    @"error": ?JsonRpcError = null,
    allocator: ?std.mem.Allocator = null,

    pub fn success(
        allocator: std.mem.Allocator,
        id: JsonRpcId,
        result: std.json.Value,
        result_arena: ?*std.heap.ArenaAllocator,
    ) !JsonRpcResponse {
        return .{
            .jsonrpc = try allocator.dupe(u8, "2.0"),
            .id = id,
            .result = result,
            .result_arena = result_arena,
            .@"error" = null,
            .allocator = allocator,
        };
    }

    pub fn failure(allocator: std.mem.Allocator, id: JsonRpcId, err: JsonRpcError) !JsonRpcResponse {
        return .{
            .jsonrpc = try allocator.dupe(u8, "2.0"),
            .id = id,
            .result = null,
            .result_arena = null,
            .@"error" = err,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JsonRpcResponse) void {
        if (self.allocator) |a| {
            a.free(self.jsonrpc);
            self.id.deinit(a);
            if (self.result_arena) |arena| {
                arena.deinit();
                a.destroy(arena);
            }
            if (self.@"error") |*e| e.deinit();
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: JsonRpcResponse, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(self.jsonrpc);
        try jw.objectField("id");
        try jw.write(self.id);
        if (self.result) |r| {
            try jw.objectField("result");
            try jw.write(r);
        }
        if (self.@"error") |e| {
            try jw.objectField("error");
            try jw.write(e);
        }
        try jw.endObject();
    }
};

/// A2A JSON-RPC method names.
pub const methods = struct {
    pub const SEND_MESSAGE = "SendMessage";
    pub const SEND_STREAMING_MESSAGE = "SendStreamingMessage";
    pub const GET_TASK = "GetTask";
    pub const LIST_TASKS = "ListTasks";
    pub const CANCEL_TASK = "CancelTask";
    pub const SUBSCRIBE_TO_TASK = "SubscribeToTask";
    pub const CREATE_PUSH_CONFIG = "CreateTaskPushNotificationConfig";
    pub const GET_PUSH_CONFIG = "GetTaskPushNotificationConfig";
    pub const LIST_PUSH_CONFIGS = "ListTaskPushNotificationConfigs";
    pub const DELETE_PUSH_CONFIG = "DeleteTaskPushNotificationConfig";
    pub const GET_EXTENDED_AGENT_CARD = "GetExtendedAgentCard";

    pub fn isStreaming(method: []const u8) bool {
        return std.mem.eql(u8, method, SEND_STREAMING_MESSAGE) or
            std.mem.eql(u8, method, SUBSCRIBE_TO_TASK);
    }

    pub fn isValid(method: []const u8) bool {
        const all = [_][]const u8{
            SEND_MESSAGE,
            SEND_STREAMING_MESSAGE,
            GET_TASK,
            LIST_TASKS,
            CANCEL_TASK,
            SUBSCRIBE_TO_TASK,
            CREATE_PUSH_CONFIG,
            GET_PUSH_CONFIG,
            LIST_PUSH_CONFIGS,
            DELETE_PUSH_CONFIG,
            GET_EXTENDED_AGENT_CARD,
        };
        for (all) |m| if (std.mem.eql(u8, method, m)) return true;
        return false;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "jsonrpc_id string roundtrip" {
    const a = testing.allocator;
    var id = try JsonRpcId.fromString(a, "abc");
    defer id.deinit(a);
    const json = try std.json.Stringify.valueAlloc(a, id, .{});
    defer a.free(json);
    try testing.expectEqualStrings("\"abc\"", json);

    const back = try std.json.parseFromSlice(JsonRpcId, a, json, .{});
    defer back.deinit();
    try testing.expect(back.value.eql(id));
}

test "jsonrpc_id number roundtrip" {
    const a = testing.allocator;
    const id = JsonRpcId.fromNumber(42);
    const json = try std.json.Stringify.valueAlloc(a, id, .{});
    defer a.free(json);
    try testing.expectEqualStrings("42", json);

    const back = try std.json.parseFromSlice(JsonRpcId, a, json, .{});
    defer back.deinit();
    try testing.expect(back.value.eql(id));
}

test "jsonrpc_id null roundtrip" {
    const a = testing.allocator;
    const id: JsonRpcId = .null;
    const json = try std.json.Stringify.valueAlloc(a, id, .{});
    defer a.free(json);
    try testing.expectEqualStrings("null", json);
}

test "jsonrpc_id rejects array" {
    const a = testing.allocator;
    const result = std.json.parseFromSlice(JsonRpcId, a, "[1,2]", .{});
    try testing.expectError(error.UnexpectedToken, result);
}

test "jsonrpc_id rejects fractional" {
    const a = testing.allocator;
    const result = std.json.parseFromSlice(JsonRpcId, a, "3.14", .{});
    try testing.expectError(error.UnexpectedToken, result);
}

test "jsonrpc_request omits params when none" {
    const a = testing.allocator;
    var req = try JsonRpcRequest.init(a, JsonRpcId.fromNumber(1), methods.GET_TASK, null, null);
    defer req.deinit();
    const json = try std.json.Stringify.valueAlloc(a, req, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "params") == null);
}

test "jsonrpc_response success serializes" {
    const a = testing.allocator;
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    const aa = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, try aa.dupe(u8, "status"), .{ .string = try aa.dupe(u8, "ok") });
    var resp = try JsonRpcResponse.success(a, JsonRpcId.fromNumber(1), .{ .object = obj }, arena);
    defer resp.deinit();

    const json = try std.json.Stringify.valueAlloc(a, resp, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error\"") == null);
}

test "jsonrpc_response failure serializes" {
    const a = testing.allocator;
    const err = JsonRpcError{
        .code = -32600,
        .message = try a.dupe(u8, "invalid"),
        .data = null,
        .allocator = a,
    };
    const id = try JsonRpcId.fromString(a, "e1");
    var resp = try JsonRpcResponse.failure(a, id, err);
    defer resp.deinit();

    const json = try std.json.Stringify.valueAlloc(a, resp, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"result\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
}

test "methods.isStreaming" {
    try testing.expect(methods.isStreaming(methods.SEND_STREAMING_MESSAGE));
    try testing.expect(methods.isStreaming(methods.SUBSCRIBE_TO_TASK));
    try testing.expect(!methods.isStreaming(methods.SEND_MESSAGE));
    try testing.expect(!methods.isStreaming(methods.GET_TASK));
    try testing.expect(!methods.isStreaming("unknown"));
}

test "methods.isValid" {
    try testing.expect(methods.isValid(methods.SEND_MESSAGE));
    try testing.expect(methods.isValid(methods.SEND_STREAMING_MESSAGE));
    try testing.expect(methods.isValid(methods.GET_TASK));
    try testing.expect(methods.isValid(methods.LIST_TASKS));
    try testing.expect(methods.isValid(methods.CANCEL_TASK));
    try testing.expect(methods.isValid(methods.SUBSCRIBE_TO_TASK));
    try testing.expect(methods.isValid(methods.CREATE_PUSH_CONFIG));
    try testing.expect(methods.isValid(methods.GET_PUSH_CONFIG));
    try testing.expect(methods.isValid(methods.LIST_PUSH_CONFIGS));
    try testing.expect(methods.isValid(methods.DELETE_PUSH_CONFIG));
    try testing.expect(methods.isValid(methods.GET_EXTENDED_AGENT_CARD));
    try testing.expect(!methods.isValid("message.send"));
    try testing.expect(!methods.isValid("unknown.method"));
}
