//! Compatibility shims for legacy push-notification config wire shapes.
//!
//! Different server implementations have shipped different JSON shapes for
//! task push-notification config payloads. We try the canonical ProtoJSON
//! shape first, then fall back to the native nested shape, then to a bare
//! array for list responses. This mirrors the tolerance the protocol's
//! reference clients have built up over time.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");

const log = std.log.scoped(.a2a_client);

pub const Error = error{
    OutOfMemory,
    InvalidPayload,
};

/// Serialize a CreateTaskPushNotificationConfigRequest to ProtoJSON bytes.
/// Caller owns the returned slice.
pub fn serializeCreateTaskPushNotificationConfigRequest(
    allocator: std.mem.Allocator,
    req: a2a.CreateTaskPushNotificationConfigRequest,
) Error![]const u8 {
    var pb_req = pb.conv.createTaskPushNotificationConfigRequestToProto(allocator, req) catch return Error.OutOfMemory;
    defer pb_req.deinit(allocator);
    return pb_req.jsonEncode(.{}, .{}, allocator) catch Error.InvalidPayload;
}

/// Decode a TaskPushNotificationConfig from JSON bytes, accepting both the
/// flat ProtoJSON shape and the native nested `{task_id, config: {...}}`
/// shape. Caller owns the returned value.
pub fn deserializeTaskPushNotificationConfig(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error!a2a.TaskPushNotificationConfig {
    // Path 1: ProtoJSON flat shape via the generated decoder.
    if (pb.v1.TaskPushNotificationConfig.jsonDecode(payload, .{}, allocator)) |parsed| {
        defer parsed.deinit();
        return pb.conv.taskPushNotificationConfigFromProto(allocator, parsed.value) catch Error.OutOfMemory;
    } else |err| {
        log.debug("ProtoJSON decode of TaskPushNotificationConfig failed, trying native shape: {s}", .{@errorName(err)});
    }

    // Path 2: native nested shape.
    const parsed_value = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return Error.InvalidPayload;
    defer parsed_value.deinit();

    // The native shape requires a `task_id` and a nested `config`.
    const obj = switch (parsed_value.value) {
        .object => |o| o,
        else => return Error.InvalidPayload,
    };
    const task_id = switch (obj.get("task_id") orelse obj.get("taskId") orelse return Error.InvalidPayload) {
        .string => |s| s,
        else => return Error.InvalidPayload,
    };
    const cfg_v = obj.get("config") orelse return Error.InvalidPayload;
    var cfg = a2a.PushNotificationConfig.jsonParseFromValue(allocator, cfg_v, .{}) catch return Error.InvalidPayload;
    errdefer cfg.deinit();

    var out: a2a.TaskPushNotificationConfig = .{
        .task_id = allocator.dupe(u8, task_id) catch return Error.OutOfMemory,
        .config = cfg,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (obj.get("tenant")) |t| switch (t) {
        .string => |s| out.tenant = allocator.dupe(u8, s) catch return Error.OutOfMemory,
        else => {},
    };
    return out;
}

/// Decode a ListTaskPushNotificationConfigsResponse, accepting:
///   * the flat ProtoJSON shape `{ "configs": [...], "next_page_token": ... }`,
///   * a bare array of configs (no envelope, no paging), or
///   * the native nested envelope.
/// Caller owns the returned value.
pub fn deserializeListTaskPushNotificationConfigsResponse(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error!a2a.ListTaskPushNotificationConfigsResponse {
    // Path 1: ProtoJSON envelope.
    if (pb.v1.ListTaskPushNotificationConfigsResponse.jsonDecode(payload, .{}, allocator)) |parsed| {
        defer parsed.deinit();
        return pb.conv.listTaskPushNotificationConfigsResponseFromProto(allocator, parsed.value) catch Error.OutOfMemory;
    } else |err| {
        log.debug("ProtoJSON decode of list response failed, trying alternate shapes: {s}", .{@errorName(err)});
    }

    const parsed_value = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return Error.InvalidPayload;
    defer parsed_value.deinit();

    // Path 2: bare array of configs.
    if (parsed_value.value == .array) {
        const arr = parsed_value.value.array;
        const configs = allocator.alloc(a2a.TaskPushNotificationConfig, arr.items.len) catch return Error.OutOfMemory;
        var i: usize = 0;
        errdefer {
            for (configs[0..i]) |*c| c.deinit();
            allocator.free(configs);
        }
        while (i < arr.items.len) : (i += 1) {
            configs[i] = try parseConfigValue(allocator, arr.items[i]);
        }
        return .{
            .configs = configs,
            .allocator = allocator,
        };
    }

    // Path 3: native envelope { configs: [...], next_page_token? }.
    const obj = switch (parsed_value.value) {
        .object => |o| o,
        else => return Error.InvalidPayload,
    };
    const configs_v = obj.get("configs") orelse return Error.InvalidPayload;
    const arr = switch (configs_v) {
        .array => |a| a,
        else => return Error.InvalidPayload,
    };
    const configs = allocator.alloc(a2a.TaskPushNotificationConfig, arr.items.len) catch return Error.OutOfMemory;
    var i: usize = 0;
    errdefer {
        for (configs[0..i]) |*c| c.deinit();
        allocator.free(configs);
    }
    while (i < arr.items.len) : (i += 1) {
        configs[i] = try parseConfigValue(allocator, arr.items[i]);
    }

    var out: a2a.ListTaskPushNotificationConfigsResponse = .{
        .configs = configs,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (obj.get("nextPageToken") orelse obj.get("next_page_token")) |npt_v| switch (npt_v) {
        .string => |s| out.next_page_token = allocator.dupe(u8, s) catch return Error.OutOfMemory,
        else => {},
    };
    return out;
}

fn parseConfigValue(
    allocator: std.mem.Allocator,
    v: std.json.Value,
) Error!a2a.TaskPushNotificationConfig {
    // Re-stringify and try the deserializer above. Slightly wasteful for the
    // common case but keeps the fallback chain in one place.
    const bytes = std.json.Stringify.valueAlloc(allocator, v, .{}) catch return Error.OutOfMemory;
    defer allocator.free(bytes);
    return deserializeTaskPushNotificationConfig(allocator, bytes);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "serialize-create round-trips through the deserializer" {
    const a = testing.allocator;
    var native = a2a.CreateTaskPushNotificationConfigRequest{
        .task_id = try a.dupe(u8, "t1"),
        .config = .{
            .url = try a.dupe(u8, "https://example.com/hook"),
            .id = try a.dupe(u8, "cfg1"),
            .allocator = a,
        },
        .allocator = a,
    };
    defer native.deinit();

    const payload = try serializeCreateTaskPushNotificationConfigRequest(a, native);
    defer a.free(payload);
    try testing.expect(std.mem.indexOf(u8, payload, "https://example.com/hook") != null);

    var back = try deserializeTaskPushNotificationConfig(a, payload);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.task_id);
    try testing.expectEqualStrings("https://example.com/hook", back.config.url);
}

test "deserialize accepts native nested shape" {
    const a = testing.allocator;
    const payload =
        \\{"task_id":"t1","config":{"url":"https://example.com/hook"}}
    ;
    var back = try deserializeTaskPushNotificationConfig(a, payload);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.task_id);
    try testing.expectEqualStrings("https://example.com/hook", back.config.url);
}

test "deserialize-list accepts envelope shape" {
    const a = testing.allocator;
    const payload =
        \\{"configs":[{"task_id":"t1","config":{"url":"https://x/"}}],"next_page_token":"next"}
    ;
    var back = try deserializeListTaskPushNotificationConfigsResponse(a, payload);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.configs.len);
    try testing.expectEqualStrings("t1", back.configs[0].task_id);
    try testing.expectEqualStrings("next", back.next_page_token.?);
}

test "deserialize-list accepts bare array" {
    const a = testing.allocator;
    const payload =
        \\[{"task_id":"t1","config":{"url":"https://x/"}}]
    ;
    var back = try deserializeListTaskPushNotificationConfigsResponse(a, payload);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.configs.len);
    try testing.expect(back.next_page_token == null);
}

test "deserialize rejects clearly wrong shapes" {
    const a = testing.allocator;
    try testing.expectError(Error.InvalidPayload, deserializeTaskPushNotificationConfig(a, "\"not-an-object\""));
    try testing.expectError(Error.InvalidPayload, deserializeListTaskPushNotificationConfigsResponse(a, "\"nope\""));
}
