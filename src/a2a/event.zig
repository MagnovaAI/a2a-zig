//! Streaming event types. Mirrors `a2a-rs/a2a/src/event.rs` 1:1.
const std = @import("std");
const types = @import("types.zig");

const Task = types.Task;
const Message = types.Message;
const Artifact = types.Artifact;
const TaskStatus = types.TaskStatus;
const Metadata = types.Metadata;

// ---------------------------------------------------------------------------
// TaskStatusUpdateEvent
// ---------------------------------------------------------------------------

pub const TaskStatusUpdateEvent = struct {
    task_id: []const u8,
    context_id: []const u8,
    status: TaskStatus,
    metadata: ?Metadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaskStatusUpdateEvent) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.context_id);
        self.status.deinit();
        if (self.metadata) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: TaskStatusUpdateEvent, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        try jw.objectField("contextId");
        try jw.write(self.context_id);
        try jw.objectField("status");
        try jw.write(self.status);
        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(std.json.Value{ .object = m.object });
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !TaskStatusUpdateEvent {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var e: TaskStatusUpdateEvent = .{
            .task_id = "",
            .context_id = "",
            .status = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer e.deinit();

        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| e.task_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("contextId")) |v| switch (v) {
            .string => |s| e.context_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("status")) |v| {
            e.status.deinit();
            e.status = try TaskStatus.jsonParseFromValue(allocator, v, opts);
        }
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| e.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        return e;
    }
};

// ---------------------------------------------------------------------------
// TaskArtifactUpdateEvent
// ---------------------------------------------------------------------------

pub const TaskArtifactUpdateEvent = struct {
    task_id: []const u8,
    context_id: []const u8,
    artifact: Artifact,
    append: ?bool = null,
    last_chunk: ?bool = null,
    metadata: ?Metadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaskArtifactUpdateEvent) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.context_id);
        self.artifact.deinit();
        if (self.metadata) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: TaskArtifactUpdateEvent, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        try jw.objectField("contextId");
        try jw.write(self.context_id);
        try jw.objectField("artifact");
        try jw.write(self.artifact);
        if (self.append) |b| {
            try jw.objectField("append");
            try jw.write(b);
        }
        if (self.last_chunk) |b| {
            try jw.objectField("lastChunk");
            try jw.write(b);
        }
        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(std.json.Value{ .object = m.object });
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !TaskArtifactUpdateEvent {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const art_v = obj.get("artifact") orelse return error.MissingField;
        var artifact = try Artifact.jsonParseFromValue(allocator, art_v, opts);
        errdefer artifact.deinit();
        var e: TaskArtifactUpdateEvent = .{
            .task_id = "",
            .context_id = "",
            .artifact = artifact,
            .allocator = allocator,
        };
        errdefer e.deinit();

        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| e.task_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("contextId")) |v| switch (v) {
            .string => |s| e.context_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("append")) |v| switch (v) {
            .bool => |b| e.append = b,
            else => {},
        };
        if (obj.get("lastChunk")) |v| switch (v) {
            .bool => |b| e.last_chunk = b,
            else => {},
        };
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| e.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        return e;
    }
};

// ---------------------------------------------------------------------------
// StreamResponse — externally-tagged 4-variant union
// ---------------------------------------------------------------------------

pub const StreamResponseTag = enum { task, message, status_update, artifact_update, unknown };

pub const StreamResponse = union(StreamResponseTag) {
    task: Task,
    message: Message,
    status_update: TaskStatusUpdateEvent,
    artifact_update: TaskArtifactUpdateEvent,
    /// Forward-compat fallback for variants the local build doesn't recognize.
    unknown: types.UnknownVariant,

    pub fn deinit(self: *StreamResponse) void {
        switch (self.*) {
            .task => |*t| t.deinit(),
            .message => |*m| m.deinit(),
            .status_update => |*s| s.deinit(),
            .artifact_update => |*a| a.deinit(),
            .unknown => |*u| u.deinit(),
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: StreamResponse, jw: anytype) !void {
        switch (self) {
            .unknown => |u| try jw.write(u),
            else => {
                try jw.beginObject();
                switch (self) {
                    .task => |t| {
                        try jw.objectField("task");
                        try jw.write(t);
                    },
                    .message => |m| {
                        try jw.objectField("message");
                        try jw.write(m);
                    },
                    .status_update => |s| {
                        try jw.objectField("statusUpdate");
                        try jw.write(s);
                    },
                    .artifact_update => |a| {
                        try jw.objectField("artifactUpdate");
                        try jw.write(a);
                    },
                    .unknown => unreachable,
                }
                try jw.endObject();
            },
        }
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !StreamResponse {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        if (obj.get("message")) |v| {
            return .{ .message = try Message.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("task")) |v| {
            return .{ .task = try Task.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("statusUpdate")) |v| {
            return .{ .status_update = try TaskStatusUpdateEvent.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("artifactUpdate")) |v| {
            return .{ .artifact_update = try TaskArtifactUpdateEvent.jsonParseFromValue(allocator, v, opts) };
        }
        // Forward-compat: capture the first key/value pair so unknown variants
        // round-trip without dropping data.
        var it = obj.iterator();
        if (it.next()) |entry| {
            return .{ .unknown = try types.UnknownVariant.init(allocator, entry.key_ptr.*, entry.value_ptr.*) };
        }
        return error.UnexpectedToken;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Role = types.Role;
const TaskState = types.TaskState;
const Part = types.Part;

fn parseValueOwned(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "stream_response status_update serde" {
    const a = testing.allocator;
    var event = StreamResponse{
        .status_update = .{
            .task_id = try a.dupe(u8, "t1"),
            .context_id = try a.dupe(u8, "c1"),
            .status = .{ .state = .working, .allocator = a },
            .allocator = a,
        },
    };
    defer event.deinit();

    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"statusUpdate\"") != null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try StreamResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .status_update);
}

test "stream_response task serde" {
    const a = testing.allocator;
    var event = StreamResponse{
        .task = .{
            .id = try a.dupe(u8, "t1"),
            .context_id = try a.dupe(u8, "c1"),
            .status = .{ .state = .completed, .allocator = a },
            .allocator = a,
        },
    };
    defer event.deinit();
    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"task\"") != null);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try StreamResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .task);
}

test "stream_response message serde" {
    const a = testing.allocator;
    const parts = try a.alloc(Part, 1);
    parts[0] = try Part.text(a, "hello");
    var event = StreamResponse{ .message = try Message.init(a, .agent, parts) };
    defer event.deinit();

    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"message\"") != null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try StreamResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .message);
}

test "stream_response artifact_update serde" {
    const a = testing.allocator;
    var event = StreamResponse{
        .artifact_update = .{
            .task_id = try a.dupe(u8, "t1"),
            .context_id = try a.dupe(u8, "c1"),
            .artifact = .{
                .artifact_id = try a.dupe(u8, "a1"),
                .allocator = a,
            },
            .append = true,
            .last_chunk = false,
            .allocator = a,
        },
    };
    defer event.deinit();

    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"artifactUpdate\"") != null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try StreamResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .artifact_update);
}

test "stream_response unknown variant captured for forward compat" {
    const a = testing.allocator;
    const parsed = try parseValueOwned(a, "{\"futureEvent\": {\"value\": 42}}");
    defer parsed.deinit();
    var sr = try StreamResponse.jsonParseFromValue(a, parsed.value, .{});
    defer sr.deinit();
    try testing.expect(sr == .unknown);
    try testing.expectEqualStrings("futureEvent", sr.unknown.key);

    const json = try std.json.Stringify.valueAlloc(a, sr, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "futureEvent") != null);
}

test "task_status_update_event with metadata" {
    const a = testing.allocator;

    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    const aa = arena.allocator();
    var meta_obj: std.json.ObjectMap = .empty;
    try meta_obj.put(aa, try aa.dupe(u8, "key"), .{ .string = try aa.dupe(u8, "val") });

    const empty_parts = try a.alloc(Part, 0);
    const status_msg = try Message.init(a, .agent, empty_parts);

    var event = TaskStatusUpdateEvent{
        .task_id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .status = .{
            .state = .working,
            .message = status_msg,
            .allocator = a,
        },
        .metadata = .{ .object = meta_obj, .arena = arena },
        .allocator = a,
    };
    defer event.deinit();

    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try TaskStatusUpdateEvent.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back.metadata != null);
    try testing.expectEqual(TaskState.working, back.status.state);
}

test "task_artifact_update_event full" {
    const a = testing.allocator;
    const ap = try a.alloc(Part, 1);
    ap[0] = try Part.text(a, "content");
    var event = TaskArtifactUpdateEvent{
        .task_id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .artifact = .{
            .artifact_id = try a.dupe(u8, "a1"),
            .name = try a.dupe(u8, "file.txt"),
            .description = try a.dupe(u8, "A file"),
            .parts = ap,
            .allocator = a,
        },
        .last_chunk = true,
        .allocator = a,
    };
    defer event.deinit();

    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try TaskArtifactUpdateEvent.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqual(@as(?bool, true), back.last_chunk);
    try testing.expect(back.append == null);
}
