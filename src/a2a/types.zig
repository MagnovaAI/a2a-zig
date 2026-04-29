//! Core protocol data types. Mirrors `a2a-rs/a2a/src/types.rs` 1:1.
//!
//! Memory model:
//!   * Strings and slices are heap-owned; every type stores its `allocator`
//!     and frees its own memory in `deinit`.
//!   * Arbitrary JSON fields (`metadata`, `data`) are paired with a
//!     `*std.heap.ArenaAllocator` that owns the value tree.
//!   * Custom `jsonStringify` and `jsonParseFromValue` implementations handle
//!     camelCase wire keys and field-presence unions.
const std = @import("std");
const errors = @import("errors.zig");
const uuid = @import("uuid");

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

pub const TaskId = []const u8;
pub const ArtifactId = []const u8;

fn newIdString(allocator: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const u = uuid.Uuid.v7(io) catch uuid.Uuid.nil;
    var buf: [36]u8 = u.toStr();
    return allocator.dupe(u8, &buf);
}

pub fn newTaskId(allocator: std.mem.Allocator) ![]u8 {
    return newIdString(allocator);
}

pub fn newContextId(allocator: std.mem.Allocator) ![]u8 {
    return newIdString(allocator);
}

pub fn newMessageId(allocator: std.mem.Allocator) ![]u8 {
    return newIdString(allocator);
}

pub fn newArtifactId(allocator: std.mem.Allocator) ![]u8 {
    return newIdString(allocator);
}

// ---------------------------------------------------------------------------
// Role
// ---------------------------------------------------------------------------

pub const Role = enum {
    unspecified,
    user,
    agent,

    pub fn default() Role {
        return .unspecified;
    }

    pub fn toWire(self: Role) []const u8 {
        return switch (self) {
            .unspecified => "ROLE_UNSPECIFIED",
            .user => "ROLE_USER",
            .agent => "ROLE_AGENT",
        };
    }

    pub fn fromWire(s: []const u8) error{UnknownVariant}!Role {
        if (std.mem.eql(u8, s, "ROLE_USER")) return .user;
        if (std.mem.eql(u8, s, "ROLE_AGENT")) return .agent;
        if (std.mem.eql(u8, s, "ROLE_UNSPECIFIED") or s.len == 0) return .unspecified;
        return error.UnknownVariant;
    }

    pub fn jsonStringify(self: Role, jw: anytype) !void {
        try jw.write(self.toWire());
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !Role {
        return switch (source) {
            .string => |s| fromWire(s) catch error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }
};

// ---------------------------------------------------------------------------
// TaskState
// ---------------------------------------------------------------------------

pub const TaskState = enum {
    unspecified,
    submitted,
    working,
    completed,
    failed,
    canceled,
    input_required,
    rejected,
    auth_required,

    pub fn default() TaskState {
        return .unspecified;
    }

    pub fn isTerminal(self: TaskState) bool {
        return switch (self) {
            .completed, .failed, .canceled, .rejected => true,
            else => false,
        };
    }

    pub fn toWire(self: TaskState) []const u8 {
        return switch (self) {
            .unspecified => "TASK_STATE_UNSPECIFIED",
            .submitted => "TASK_STATE_SUBMITTED",
            .working => "TASK_STATE_WORKING",
            .completed => "TASK_STATE_COMPLETED",
            .failed => "TASK_STATE_FAILED",
            .canceled => "TASK_STATE_CANCELED",
            .input_required => "TASK_STATE_INPUT_REQUIRED",
            .rejected => "TASK_STATE_REJECTED",
            .auth_required => "TASK_STATE_AUTH_REQUIRED",
        };
    }

    pub fn fromWire(s: []const u8) error{UnknownVariant}!TaskState {
        if (std.mem.eql(u8, s, "TASK_STATE_SUBMITTED")) return .submitted;
        if (std.mem.eql(u8, s, "TASK_STATE_WORKING")) return .working;
        if (std.mem.eql(u8, s, "TASK_STATE_COMPLETED")) return .completed;
        if (std.mem.eql(u8, s, "TASK_STATE_FAILED")) return .failed;
        if (std.mem.eql(u8, s, "TASK_STATE_CANCELED")) return .canceled;
        if (std.mem.eql(u8, s, "TASK_STATE_INPUT_REQUIRED")) return .input_required;
        if (std.mem.eql(u8, s, "TASK_STATE_REJECTED")) return .rejected;
        if (std.mem.eql(u8, s, "TASK_STATE_AUTH_REQUIRED")) return .auth_required;
        if (std.mem.eql(u8, s, "TASK_STATE_UNSPECIFIED") or s.len == 0) return .unspecified;
        return error.UnknownVariant;
    }

    pub fn jsonStringify(self: TaskState, jw: anytype) !void {
        try jw.write(self.toWire());
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !TaskState {
        return switch (source) {
            .string => |s| fromWire(s) catch error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }
};

// ---------------------------------------------------------------------------
// Metadata helper
// ---------------------------------------------------------------------------

/// Optional metadata: an arena-owned JSON object plus its arena.
pub const Metadata = struct {
    object: std.json.ObjectMap,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// Deep-clone an existing object map and own it via a fresh arena.
    pub fn clone(allocator: std.mem.Allocator, src: std.json.ObjectMap) !Metadata {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const aa = arena.allocator();
        var out: std.json.ObjectMap = .empty;
        var it = src.iterator();
        while (it.next()) |entry| {
            const k = try aa.dupe(u8, entry.key_ptr.*);
            const v = try errors.cloneJsonValue(aa, entry.value_ptr.*);
            try out.put(aa, k, v);
        }
        return .{ .object = out, .arena = arena };
    }

    pub fn jsonStringify(self: Metadata, jw: anytype) !void {
        try jw.write(std.json.Value{ .object = self.object });
    }
};

/// Payload for `unknown` union arms.
///
/// Externally-tagged unions whose variant set can grow over time carry an
/// `unknown: UnknownVariant` arm so newer wire payloads don't crash older
/// readers. The original tag key is preserved alongside the value, so the
/// payload round-trips losslessly.
pub const UnknownVariant = struct {
    key: []const u8,
    value: std.json.Value,
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        key: []const u8,
        value: std.json.Value,
    ) !UnknownVariant {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const aa = arena.allocator();
        const k = try aa.dupe(u8, key);
        const v = try errors.cloneJsonValue(aa, value);
        return .{ .key = k, .value = v, .arena = arena, .allocator = allocator };
    }

    pub fn deinit(self: *UnknownVariant) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn jsonStringify(self: UnknownVariant, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField(self.key);
        try jw.write(self.value);
        try jw.endObject();
    }
};

// ---------------------------------------------------------------------------
// Part
// ---------------------------------------------------------------------------

pub const PartContentTag = enum { text, raw, url, data };

/// A part's content — discriminated union mirroring the Rust enum.
pub const PartContent = union(PartContentTag) {
    text: []const u8,
    raw: []const u8,
    url: []const u8,
    data: struct { value: std.json.Value, arena: *std.heap.ArenaAllocator },

    pub fn deinit(self: *PartContent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text, .url => |s| allocator.free(s),
            .raw => |b| allocator.free(b),
            .data => |*d| {
                d.arena.deinit();
                allocator.destroy(d.arena);
            },
        }
        self.* = undefined;
    }
};

/// A content part of a message or artifact.
pub const Part = struct {
    content: PartContent,
    filename: ?[]const u8 = null,
    media_type: ?[]const u8 = null,
    metadata: ?Metadata = null,
    allocator: std.mem.Allocator,

    pub fn text(allocator: std.mem.Allocator, t: []const u8) !Part {
        return .{
            .content = .{ .text = try allocator.dupe(u8, t) },
            .allocator = allocator,
        };
    }

    pub fn raw(allocator: std.mem.Allocator, bytes: []const u8) !Part {
        return .{
            .content = .{ .raw = try allocator.dupe(u8, bytes) },
            .allocator = allocator,
        };
    }

    pub fn url(allocator: std.mem.Allocator, u: []const u8) !Part {
        return .{
            .content = .{ .url = try allocator.dupe(u8, u) },
            .allocator = allocator,
        };
    }

    /// Construct a `data` part. Takes ownership of `arena` (which owns `value`).
    pub fn data(
        allocator: std.mem.Allocator,
        value: std.json.Value,
        arena: *std.heap.ArenaAllocator,
    ) Part {
        return .{
            .content = .{ .data = .{ .value = value, .arena = arena } },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Part) void {
        self.content.deinit(self.allocator);
        if (self.filename) |s| self.allocator.free(s);
        if (self.media_type) |s| self.allocator.free(s);
        if (self.metadata) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn withMediaType(self: *Part, m: []const u8) !void {
        if (self.media_type) |old| self.allocator.free(old);
        self.media_type = try self.allocator.dupe(u8, m);
    }

    pub fn withFilename(self: *Part, f: []const u8) !void {
        if (self.filename) |old| self.allocator.free(old);
        self.filename = try self.allocator.dupe(u8, f);
    }

    pub fn asText(self: *const Part) ?[]const u8 {
        return switch (self.content) {
            .text => |s| s,
            else => null,
        };
    }

    pub fn jsonStringify(self: Part, jw: anytype) !void {
        try jw.beginObject();
        switch (self.content) {
            .text => |s| {
                try jw.objectField("text");
                try jw.write(s);
            },
            .raw => |b| {
                try jw.objectField("raw");
                const enc = std.base64.standard.Encoder;
                // Stream the base64 in 3-byte-aligned chunks so each chunk
                // encodes without padding, then emit a final unaligned chunk.
                try jw.beginWriteRaw();
                try jw.writer.writeByte('"');
                var i: usize = 0;
                while (i < b.len) {
                    const remaining = b.len - i;
                    const take = if (remaining > 3072)
                        3072
                    else if (remaining % 3 == 0 or remaining < 3)
                        remaining
                    else
                        remaining - (remaining % 3);
                    var out_buf: [4096]u8 = undefined;
                    const out = enc.encode(out_buf[0..enc.calcSize(take)], b[i .. i + take]);
                    try jw.writer.writeAll(out);
                    i += take;
                }
                try jw.writer.writeByte('"');
                jw.endWriteRaw();
            },
            .url => |s| {
                try jw.objectField("url");
                try jw.write(s);
            },
            .data => |d| {
                try jw.objectField("data");
                try jw.write(d.value);
            },
        }
        if (self.filename) |f| {
            try jw.objectField("filename");
            try jw.write(f);
        }
        if (self.media_type) |m| {
            try jw.objectField("mediaType");
            try jw.write(m);
        }
        if (self.metadata) |m| {
            if (m.object.count() > 0) {
                try jw.objectField("metadata");
                try jw.write(std.json.Value{ .object = m.object });
            }
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !Part {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };

        var part: Part = undefined;
        part.allocator = allocator;
        part.filename = null;
        part.media_type = null;
        part.metadata = null;

        if (obj.get("text")) |v| switch (v) {
            .string => |s| part.content = .{ .text = try allocator.dupe(u8, s) },
            else => return error.UnexpectedToken,
        } else if (obj.get("raw")) |v| switch (v) {
            .string => |s| {
                const dec = std.base64.standard.Decoder;
                const dec_size = dec.calcSizeForSlice(s) catch return error.UnexpectedToken;
                const buf = try allocator.alloc(u8, dec_size);
                errdefer allocator.free(buf);
                dec.decode(buf, s) catch return error.UnexpectedToken;
                part.content = .{ .raw = buf };
            },
            else => return error.UnexpectedToken,
        } else if (obj.get("url")) |v| switch (v) {
            .string => |s| part.content = .{ .url = try allocator.dupe(u8, s) },
            else => return error.UnexpectedToken,
        } else if (obj.get("data")) |v| {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer {
                arena.deinit();
                allocator.destroy(arena);
            }
            const cloned = try errors.cloneJsonValue(arena.allocator(), v);
            part.content = .{ .data = .{ .value = cloned, .arena = arena } };
        } else {
            return error.UnexpectedToken;
        }
        errdefer part.content.deinit(allocator);

        if (obj.get("filename")) |v| switch (v) {
            .string => |s| part.filename = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("mediaType")) |v| switch (v) {
            .string => |s| part.media_type = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("metadata")) |v| switch (v) {
            .object => |meta_obj| {
                part.metadata = try Metadata.clone(allocator, meta_obj);
            },
            else => {},
        };

        return part;
    }
};

// ---------------------------------------------------------------------------
// String list helper (snake_case Rust `Vec<String>`)
// ---------------------------------------------------------------------------

fn freeStrSlice(allocator: std.mem.Allocator, slice: []const []const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

fn dupeStrSlice(allocator: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < src.len) : (i += 1) out[i] = try allocator.dupe(u8, src[i]);
    return out;
}

fn parseStrSlice(allocator: std.mem.Allocator, v: std.json.Value) ![]const []const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.UnexpectedToken,
    };
    const out = try allocator.alloc([]const u8, arr.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < arr.items.len) : (i += 1) {
        out[i] = switch (arr.items[i]) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Message
// ---------------------------------------------------------------------------

pub const Message = struct {
    message_id: []const u8,
    context_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    role: Role = .unspecified,
    parts: []Part = &.{},
    metadata: ?Metadata = null,
    extensions: ?[]const []const u8 = null,
    reference_task_ids: ?[]const []const u8 = null,
    allocator: std.mem.Allocator,

    /// Create a new message with a random ID. Takes ownership of `parts`.
    pub fn init(allocator: std.mem.Allocator, role: Role, parts: []Part) !Message {
        return .{
            .message_id = try newMessageId(allocator),
            .role = role,
            .parts = parts,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.message_id);
        if (self.context_id) |s| self.allocator.free(s);
        if (self.task_id) |s| self.allocator.free(s);
        for (self.parts) |*p| p.deinit();
        self.allocator.free(self.parts);
        if (self.metadata) |*m| m.deinit(self.allocator);
        if (self.extensions) |e| freeStrSlice(self.allocator, e);
        if (self.reference_task_ids) |e| freeStrSlice(self.allocator, e);
        self.* = undefined;
    }

    /// First text part's text, or null.
    pub fn text(self: *const Message) ?[]const u8 {
        for (self.parts) |p| {
            if (p.asText()) |t| return t;
        }
        return null;
    }

    pub fn jsonStringify(self: Message, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("messageId");
        try jw.write(self.message_id);
        if (self.context_id) |s| {
            try jw.objectField("contextId");
            try jw.write(s);
        }
        if (self.task_id) |s| {
            try jw.objectField("taskId");
            try jw.write(s);
        }
        try jw.objectField("role");
        try jw.write(self.role);
        try jw.objectField("parts");
        try jw.beginArray();
        for (self.parts) |p| try jw.write(p);
        try jw.endArray();
        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(std.json.Value{ .object = m.object });
        }
        if (self.extensions) |e| {
            try jw.objectField("extensions");
            try jw.beginArray();
            for (e) |s| try jw.write(s);
            try jw.endArray();
        }
        if (self.reference_task_ids) |e| {
            try jw.objectField("referenceTaskIds");
            try jw.beginArray();
            for (e) |s| try jw.write(s);
            try jw.endArray();
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !Message {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };

        var msg: Message = .{
            .message_id = "",
            .allocator = allocator,
        };
        errdefer msg.deinit();

        if (obj.get("messageId")) |v| switch (v) {
            .string => |s| msg.message_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        if (obj.get("contextId")) |v| switch (v) {
            .string => |s| msg.context_id = try allocator.dupe(u8, s),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| msg.task_id = try allocator.dupe(u8, s),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("role")) |v| {
            msg.role = try Role.jsonParseFromValue(allocator, v, opts);
        }
        if (obj.get("parts")) |v| {
            const arr = switch (v) {
                .array => |a| a,
                else => return error.UnexpectedToken,
            };
            const parts = try allocator.alloc(Part, arr.items.len);
            var i: usize = 0;
            errdefer {
                for (parts[0..i]) |*p| p.deinit();
                allocator.free(parts);
            }
            while (i < arr.items.len) : (i += 1) {
                parts[i] = try Part.jsonParseFromValue(allocator, arr.items[i], opts);
            }
            msg.parts = parts;
        }
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| msg.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        if (obj.get("extensions")) |v| switch (v) {
            .array => msg.extensions = try parseStrSlice(allocator, v),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("referenceTaskIds")) |v| switch (v) {
            .array => msg.reference_task_ids = try parseStrSlice(allocator, v),
            .null => {},
            else => return error.UnexpectedToken,
        };
        return msg;
    }
};

// ---------------------------------------------------------------------------
// TaskStatus
// ---------------------------------------------------------------------------

pub const TaskStatus = struct {
    state: TaskState = .unspecified,
    message: ?Message = null,
    /// RFC3339 timestamp string (matches chrono `DateTime<Utc>` default serialization).
    timestamp: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaskStatus) void {
        if (self.message) |*m| m.deinit();
        if (self.timestamp) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: TaskStatus, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("state");
        try jw.write(self.state);
        if (self.message) |m| {
            try jw.objectField("message");
            try jw.write(m);
        }
        if (self.timestamp) |t| {
            try jw.objectField("timestamp");
            try jw.write(t);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !TaskStatus {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var st: TaskStatus = .{ .allocator = allocator };
        errdefer st.deinit();
        if (obj.get("state")) |v| {
            st.state = try TaskState.jsonParseFromValue(allocator, v, opts);
        }
        if (obj.get("message")) |v| switch (v) {
            .object => st.message = try Message.jsonParseFromValue(allocator, v, opts),
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("timestamp")) |v| switch (v) {
            .string => |s| st.timestamp = try allocator.dupe(u8, s),
            .null => {},
            else => return error.UnexpectedToken,
        };
        return st;
    }
};

// ---------------------------------------------------------------------------
// Artifact
// ---------------------------------------------------------------------------

pub const Artifact = struct {
    artifact_id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parts: []Part = &.{},
    metadata: ?Metadata = null,
    extensions: ?[]const []const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Artifact) void {
        self.allocator.free(self.artifact_id);
        if (self.name) |s| self.allocator.free(s);
        if (self.description) |s| self.allocator.free(s);
        for (self.parts) |*p| p.deinit();
        self.allocator.free(self.parts);
        if (self.metadata) |*m| m.deinit(self.allocator);
        if (self.extensions) |e| freeStrSlice(self.allocator, e);
        self.* = undefined;
    }

    pub fn jsonStringify(self: Artifact, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("artifactId");
        try jw.write(self.artifact_id);
        if (self.name) |s| {
            try jw.objectField("name");
            try jw.write(s);
        }
        if (self.description) |s| {
            try jw.objectField("description");
            try jw.write(s);
        }
        try jw.objectField("parts");
        try jw.beginArray();
        for (self.parts) |p| try jw.write(p);
        try jw.endArray();
        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(std.json.Value{ .object = m.object });
        }
        if (self.extensions) |e| {
            try jw.objectField("extensions");
            try jw.beginArray();
            for (e) |s| try jw.write(s);
            try jw.endArray();
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !Artifact {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var a: Artifact = .{
            .artifact_id = "",
            .allocator = allocator,
        };
        errdefer a.deinit();
        if (obj.get("artifactId")) |v| switch (v) {
            .string => |s| a.artifact_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("name")) |v| switch (v) {
            .string => |s| a.name = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("description")) |v| switch (v) {
            .string => |s| a.description = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("parts")) |v| {
            const arr = switch (v) {
                .array => |x| x,
                else => return error.UnexpectedToken,
            };
            const parts = try allocator.alloc(Part, arr.items.len);
            var i: usize = 0;
            errdefer {
                for (parts[0..i]) |*p| p.deinit();
                allocator.free(parts);
            }
            while (i < arr.items.len) : (i += 1) {
                parts[i] = try Part.jsonParseFromValue(allocator, arr.items[i], opts);
            }
            a.parts = parts;
        }
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| a.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        if (obj.get("extensions")) |v| switch (v) {
            .array => a.extensions = try parseStrSlice(allocator, v),
            else => {},
        };
        return a;
    }
};

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

pub const Task = struct {
    id: []const u8,
    context_id: []const u8,
    status: TaskStatus,
    artifacts: ?[]Artifact = null,
    history: ?[]Message = null,
    metadata: ?Metadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.id);
        self.allocator.free(self.context_id);
        self.status.deinit();
        if (self.artifacts) |arr| {
            for (arr) |*a| a.deinit();
            self.allocator.free(arr);
        }
        if (self.history) |arr| {
            for (arr) |*m| m.deinit();
            self.allocator.free(arr);
        }
        if (self.metadata) |*m| m.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: Task, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("contextId");
        try jw.write(self.context_id);
        try jw.objectField("status");
        try jw.write(self.status);
        if (self.artifacts) |arr| {
            try jw.objectField("artifacts");
            try jw.beginArray();
            for (arr) |a| try jw.write(a);
            try jw.endArray();
        }
        if (self.history) |arr| {
            try jw.objectField("history");
            try jw.beginArray();
            for (arr) |m| try jw.write(m);
            try jw.endArray();
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
    ) !Task {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var t: Task = .{
            .id = "",
            .context_id = "",
            .status = .{ .allocator = allocator },
            .allocator = allocator,
        };
        errdefer t.deinit();

        if (obj.get("id")) |v| switch (v) {
            .string => |s| t.id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        if (obj.get("contextId")) |v| switch (v) {
            .string => |s| t.context_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        if (obj.get("status")) |v| {
            // `status` was zero-initialized; replace it with the parsed value.
            t.status.deinit();
            t.status = try TaskStatus.jsonParseFromValue(allocator, v, opts);
        }
        if (obj.get("artifacts")) |v| switch (v) {
            .array => |arr| {
                const out = try allocator.alloc(Artifact, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*a| a.deinit();
                    allocator.free(out);
                }
                while (i < arr.items.len) : (i += 1) {
                    out[i] = try Artifact.jsonParseFromValue(allocator, arr.items[i], opts);
                }
                t.artifacts = out;
            },
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("history")) |v| switch (v) {
            .array => |arr| {
                const out = try allocator.alloc(Message, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*m| m.deinit();
                    allocator.free(out);
                }
                while (i < arr.items.len) : (i += 1) {
                    out[i] = try Message.jsonParseFromValue(allocator, arr.items[i], opts);
                }
                t.history = out;
            },
            .null => {},
            else => return error.UnexpectedToken,
        };
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| t.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        return t;
    }
};

// ---------------------------------------------------------------------------
// Push notification types
// ---------------------------------------------------------------------------

pub const AuthenticationInfo = struct {
    scheme: []const u8,
    credentials: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AuthenticationInfo) void {
        self.allocator.free(self.scheme);
        if (self.credentials) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: AuthenticationInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("scheme");
        try jw.write(self.scheme);
        if (self.credentials) |c| {
            try jw.objectField("credentials");
            try jw.write(c);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !AuthenticationInfo {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var a: AuthenticationInfo = .{ .scheme = "", .allocator = allocator };
        errdefer a.deinit();
        if (obj.get("scheme")) |v| switch (v) {
            .string => |s| a.scheme = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("credentials")) |v| switch (v) {
            .string => |s| a.credentials = try allocator.dupe(u8, s),
            else => {},
        };
        return a;
    }
};

pub const PushNotificationConfig = struct {
    url: []const u8,
    id: ?[]const u8 = null,
    token: ?[]const u8 = null,
    authentication: ?AuthenticationInfo = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PushNotificationConfig) void {
        self.allocator.free(self.url);
        if (self.id) |s| self.allocator.free(s);
        if (self.token) |s| self.allocator.free(s);
        if (self.authentication) |*a| a.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: PushNotificationConfig, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(self.url);
        if (self.id) |s| {
            try jw.objectField("id");
            try jw.write(s);
        }
        if (self.token) |s| {
            try jw.objectField("token");
            try jw.write(s);
        }
        if (self.authentication) |a| {
            try jw.objectField("authentication");
            try jw.write(a);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !PushNotificationConfig {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var c: PushNotificationConfig = .{ .url = "", .allocator = allocator };
        errdefer c.deinit();
        if (obj.get("url")) |v| switch (v) {
            .string => |s| c.url = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("id")) |v| switch (v) {
            .string => |s| c.id = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("token")) |v| switch (v) {
            .string => |s| c.token = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("authentication")) |v| switch (v) {
            .object => c.authentication = try AuthenticationInfo.jsonParseFromValue(allocator, v, opts),
            else => {},
        };
        return c;
    }
};

pub const TaskPushNotificationConfig = struct {
    task_id: []const u8,
    config: PushNotificationConfig,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaskPushNotificationConfig) void {
        self.allocator.free(self.task_id);
        self.config.deinit();
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: TaskPushNotificationConfig, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        try jw.objectField("config");
        try jw.write(self.config);
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }
};

pub const GetTaskPushNotificationConfigRequest = struct {
    task_id: []const u8,
    id: []const u8,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GetTaskPushNotificationConfigRequest) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.id);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: GetTaskPushNotificationConfigRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        try jw.objectField("id");
        try jw.write(self.id);
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !GetTaskPushNotificationConfigRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var r: GetTaskPushNotificationConfigRequest = .{
            .task_id = "",
            .id = "",
            .allocator = allocator,
        };
        errdefer r.deinit();
        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| r.task_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("id")) |v| switch (v) {
            .string => |s| r.id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

pub const ListTaskPushNotificationConfigsRequest = struct {
    task_id: []const u8,
    page_size: ?i32 = null,
    page_token: ?[]const u8 = null,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ListTaskPushNotificationConfigsRequest) void {
        self.allocator.free(self.task_id);
        if (self.page_token) |s| self.allocator.free(s);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ListTaskPushNotificationConfigsRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        if (self.page_size) |n| {
            try jw.objectField("pageSize");
            try jw.write(n);
        }
        if (self.page_token) |s| {
            try jw.objectField("pageToken");
            try jw.write(s);
        }
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !ListTaskPushNotificationConfigsRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var r: ListTaskPushNotificationConfigsRequest = .{
            .task_id = "",
            .allocator = allocator,
        };
        errdefer r.deinit();
        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| r.task_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("pageSize")) |v| switch (v) {
            .integer => |n| r.page_size = @intCast(n),
            else => {},
        };
        if (obj.get("pageToken")) |v| switch (v) {
            .string => |s| r.page_token = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

pub const ListTaskPushNotificationConfigsResponse = struct {
    configs: []TaskPushNotificationConfig,
    next_page_token: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ListTaskPushNotificationConfigsResponse) void {
        for (self.configs) |*c| c.deinit();
        self.allocator.free(self.configs);
        if (self.next_page_token) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ListTaskPushNotificationConfigsResponse, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("configs");
        try jw.beginArray();
        for (self.configs) |c| try jw.write(c);
        try jw.endArray();
        if (self.next_page_token) |s| {
            try jw.objectField("nextPageToken");
            try jw.write(s);
        }
        try jw.endObject();
    }
};

pub const CreateTaskPushNotificationConfigRequest = struct {
    task_id: []const u8,
    config: PushNotificationConfig,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CreateTaskPushNotificationConfigRequest) void {
        self.allocator.free(self.task_id);
        self.config.deinit();
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: CreateTaskPushNotificationConfigRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        try jw.objectField("config");
        try jw.write(self.config);
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !CreateTaskPushNotificationConfigRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const cfg_v = obj.get("config") orelse return error.MissingField;
        var cfg = try PushNotificationConfig.jsonParseFromValue(allocator, cfg_v, opts);
        errdefer cfg.deinit();
        var r: CreateTaskPushNotificationConfigRequest = .{
            .task_id = "",
            .config = cfg,
            .allocator = allocator,
        };
        errdefer r.deinit();
        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| r.task_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

pub const DeleteTaskPushNotificationConfigRequest = struct {
    task_id: []const u8,
    id: []const u8,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DeleteTaskPushNotificationConfigRequest) void {
        self.allocator.free(self.task_id);
        self.allocator.free(self.id);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: DeleteTaskPushNotificationConfigRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("taskId");
        try jw.write(self.task_id);
        try jw.objectField("id");
        try jw.write(self.id);
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !DeleteTaskPushNotificationConfigRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var r: DeleteTaskPushNotificationConfigRequest = .{
            .task_id = "",
            .id = "",
            .allocator = allocator,
        };
        errdefer r.deinit();
        if (obj.get("taskId")) |v| switch (v) {
            .string => |s| r.task_id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("id")) |v| switch (v) {
            .string => |s| r.id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

// ---------------------------------------------------------------------------
// Request / Response types
// ---------------------------------------------------------------------------

pub const SendMessageConfiguration = struct {
    accepted_output_modes: ?[]const []const u8 = null,
    push_notification_config: ?PushNotificationConfig = null,
    history_length: ?i32 = null,
    return_immediately: ?bool = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SendMessageConfiguration) void {
        if (self.accepted_output_modes) |e| freeStrSlice(self.allocator, e);
        if (self.push_notification_config) |*c| c.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: SendMessageConfiguration, jw: anytype) !void {
        try jw.beginObject();
        if (self.accepted_output_modes) |arr| {
            try jw.objectField("acceptedOutputModes");
            try jw.beginArray();
            for (arr) |s| try jw.write(s);
            try jw.endArray();
        }
        if (self.push_notification_config) |c| {
            try jw.objectField("pushNotificationConfig");
            try jw.write(c);
        }
        if (self.history_length) |n| {
            try jw.objectField("historyLength");
            try jw.write(n);
        }
        if (self.return_immediately) |b| {
            try jw.objectField("returnImmediately");
            try jw.write(b);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !SendMessageConfiguration {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var c: SendMessageConfiguration = .{ .allocator = allocator };
        errdefer c.deinit();
        if (obj.get("acceptedOutputModes")) |v| switch (v) {
            .array => c.accepted_output_modes = try parseStrSlice(allocator, v),
            else => {},
        };
        if (obj.get("pushNotificationConfig")) |v| switch (v) {
            .object => c.push_notification_config = try PushNotificationConfig.jsonParseFromValue(allocator, v, opts),
            else => {},
        };
        if (obj.get("historyLength")) |v| switch (v) {
            .integer => |n| c.history_length = @intCast(n),
            else => {},
        };
        if (obj.get("returnImmediately")) |v| switch (v) {
            .bool => |b| c.return_immediately = b,
            else => {},
        };
        return c;
    }
};

pub const SendMessageRequest = struct {
    message: Message,
    configuration: ?SendMessageConfiguration = null,
    metadata: ?Metadata = null,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SendMessageRequest) void {
        self.message.deinit();
        if (self.configuration) |*c| c.deinit();
        if (self.metadata) |*m| m.deinit(self.allocator);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: SendMessageRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("message");
        try jw.write(self.message);
        if (self.configuration) |c| {
            try jw.objectField("configuration");
            try jw.write(c);
        }
        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(std.json.Value{ .object = m.object });
        }
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !SendMessageRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const msg_v = obj.get("message") orelse return error.MissingField;
        var msg = try Message.jsonParseFromValue(allocator, msg_v, opts);
        errdefer msg.deinit();
        var req: SendMessageRequest = .{ .message = msg, .allocator = allocator };
        errdefer req.deinit();
        if (obj.get("configuration")) |v| switch (v) {
            .object => req.configuration = try SendMessageConfiguration.jsonParseFromValue(allocator, v, opts),
            else => {},
        };
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| req.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| req.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return req;
    }
};

pub const SendMessageResponseTag = enum { task, message };

pub const SendMessageResponse = union(SendMessageResponseTag) {
    task: Task,
    message: Message,

    pub fn deinit(self: *SendMessageResponse) void {
        switch (self.*) {
            .task => |*t| t.deinit(),
            .message => |*m| m.deinit(),
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: SendMessageResponse, jw: anytype) !void {
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
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !SendMessageResponse {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        if (obj.get("task")) |v| {
            return .{ .task = try Task.jsonParseFromValue(allocator, v, opts) };
        }
        if (obj.get("message")) |v| {
            return .{ .message = try Message.jsonParseFromValue(allocator, v, opts) };
        }
        return error.UnexpectedToken;
    }
};

pub const GetTaskRequest = struct {
    id: []const u8,
    history_length: ?i32 = null,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GetTaskRequest) void {
        self.allocator.free(self.id);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }
};

pub const ListTasksRequest = struct {
    context_id: ?[]const u8 = null,
    status: ?TaskState = null,
    page_size: ?i32 = null,
    page_token: ?[]const u8 = null,
    history_length: ?i32 = null,
    status_timestamp_after: ?[]const u8 = null, // RFC3339
    include_artifacts: ?bool = null,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ListTasksRequest) void {
        if (self.context_id) |s| self.allocator.free(s);
        if (self.page_token) |s| self.allocator.free(s);
        if (self.status_timestamp_after) |s| self.allocator.free(s);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ListTasksRequest, jw: anytype) !void {
        try jw.beginObject();
        if (self.context_id) |s| {
            try jw.objectField("contextId");
            try jw.write(s);
        }
        if (self.status) |st| {
            try jw.objectField("status");
            try jw.write(st);
        }
        if (self.page_size) |n| {
            try jw.objectField("pageSize");
            try jw.write(n);
        }
        if (self.page_token) |s| {
            try jw.objectField("pageToken");
            try jw.write(s);
        }
        if (self.history_length) |n| {
            try jw.objectField("historyLength");
            try jw.write(n);
        }
        if (self.status_timestamp_after) |s| {
            try jw.objectField("statusTimestampAfter");
            try jw.write(s);
        }
        if (self.include_artifacts) |b| {
            try jw.objectField("includeArtifacts");
            try jw.write(b);
        }
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        opts: std.json.ParseOptions,
    ) !ListTasksRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var r: ListTasksRequest = .{ .allocator = allocator };
        errdefer r.deinit();
        if (obj.get("contextId")) |v| switch (v) {
            .string => |s| r.context_id = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("status")) |v| {
            r.status = try TaskState.jsonParseFromValue(allocator, v, opts);
        }
        if (obj.get("pageSize")) |v| switch (v) {
            .integer => |n| r.page_size = @intCast(n),
            else => {},
        };
        if (obj.get("pageToken")) |v| switch (v) {
            .string => |s| r.page_token = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("historyLength")) |v| switch (v) {
            .integer => |n| r.history_length = @intCast(n),
            else => {},
        };
        if (obj.get("statusTimestampAfter")) |v| switch (v) {
            .string => |s| r.status_timestamp_after = try allocator.dupe(u8, s),
            else => {},
        };
        if (obj.get("includeArtifacts")) |v| switch (v) {
            .bool => |b| r.include_artifacts = b,
            else => {},
        };
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

pub const CancelTaskRequest = struct {
    id: []const u8,
    metadata: ?Metadata = null,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CancelTaskRequest) void {
        self.allocator.free(self.id);
        if (self.metadata) |*m| m.deinit(self.allocator);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: CancelTaskRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(std.json.Value{ .object = m.object });
        }
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !CancelTaskRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var r: CancelTaskRequest = .{ .id = "", .allocator = allocator };
        errdefer r.deinit();
        if (obj.get("id")) |v| switch (v) {
            .string => |s| r.id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("metadata")) |v| switch (v) {
            .object => |o| r.metadata = try Metadata.clone(allocator, o),
            else => {},
        };
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

pub const SubscribeToTaskRequest = struct {
    id: []const u8,
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SubscribeToTaskRequest) void {
        self.allocator.free(self.id);
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn jsonStringify(self: SubscribeToTaskRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        if (self.tenant) |s| {
            try jw.objectField("tenant");
            try jw.write(s);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !SubscribeToTaskRequest {
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        var r: SubscribeToTaskRequest = .{ .id = "", .allocator = allocator };
        errdefer r.deinit();
        if (obj.get("id")) |v| switch (v) {
            .string => |s| r.id = try allocator.dupe(u8, s),
            else => return error.UnexpectedToken,
        } else return error.MissingField;
        if (obj.get("tenant")) |v| switch (v) {
            .string => |s| r.tenant = try allocator.dupe(u8, s),
            else => {},
        };
        return r;
    }
};

pub const GetExtendedAgentCardRequest = struct {
    tenant: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GetExtendedAgentCardRequest) void {
        if (self.tenant) |s| self.allocator.free(s);
        self.* = undefined;
    }
};

pub const ListTasksResponse = struct {
    tasks: []Task,
    next_page_token: []const u8,
    page_size: i32,
    total_size: i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ListTasksResponse) void {
        for (self.tasks) |*t| t.deinit();
        self.allocator.free(self.tasks);
        self.allocator.free(self.next_page_token);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ListTasksResponse, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("tasks");
        try jw.beginArray();
        for (self.tasks) |t| try jw.write(t);
        try jw.endArray();
        try jw.objectField("nextPageToken");
        try jw.write(self.next_page_token);
        try jw.objectField("pageSize");
        try jw.write(self.page_size);
        try jw.objectField("totalSize");
        try jw.write(self.total_size);
        try jw.endObject();
    }
};

// ---------------------------------------------------------------------------
// Transport protocol constants
// ---------------------------------------------------------------------------

pub const TRANSPORT_PROTOCOL_JSONRPC: []const u8 = "JSONRPC";
pub const TRANSPORT_PROTOCOL_GRPC: []const u8 = "GRPC";
pub const TRANSPORT_PROTOCOL_HTTP_JSON: []const u8 = "HTTP+JSON";
pub const TRANSPORT_PROTOCOL_SLIMRPC: []const u8 = "SLIMRPC";

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseValueOwned(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "task_state serde" {
    const a = testing.allocator;
    const json = try std.json.Stringify.valueAlloc(a, TaskState.completed, .{});
    defer a.free(json);
    try testing.expectEqualStrings("\"TASK_STATE_COMPLETED\"", json);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    const back = try TaskState.jsonParseFromValue(a, parsed.value, .{});
    try testing.expectEqual(TaskState.completed, back);
}

test "role serde" {
    const a = testing.allocator;
    const json = try std.json.Stringify.valueAlloc(a, Role.agent, .{});
    defer a.free(json);
    try testing.expectEqualStrings("\"ROLE_AGENT\"", json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    const back = try Role.jsonParseFromValue(a, parsed.value, .{});
    try testing.expectEqual(Role.agent, back);
}

test "part text serde" {
    const a = testing.allocator;
    var part = try Part.text(a, "hello");
    defer part.deinit();

    const json = try std.json.Stringify.valueAlloc(a, part, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"text\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"raw\"") == null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try Part.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings("hello", back.content.text);
}

test "part raw serde" {
    const a = testing.allocator;
    const bytes = [_]u8{ 1, 2, 3 };
    var part = try Part.raw(a, &bytes);
    defer part.deinit();
    const json = try std.json.Stringify.valueAlloc(a, part, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try Part.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualSlices(u8, &bytes, back.content.raw);
}

test "part url serde" {
    const a = testing.allocator;
    var part = try Part.url(a, "https://example.com/file.pdf");
    defer part.deinit();
    const json = try std.json.Stringify.valueAlloc(a, part, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "https://example.com/file.pdf") != null);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try Part.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back.content == .url);
}

test "part data serde" {
    const a = testing.allocator;
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    const aa = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, try aa.dupe(u8, "key"), .{ .string = try aa.dupe(u8, "value") });
    try obj.put(aa, try aa.dupe(u8, "count"), .{ .integer = 42 });

    var part = Part.data(a, .{ .object = obj }, arena);
    defer part.deinit();
    const json = try std.json.Stringify.valueAlloc(a, part, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try Part.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back.content == .data);
}

test "part with metadata and media type" {
    const a = testing.allocator;
    var part = try Part.text(a, "hello");
    defer part.deinit();
    try part.withMediaType("text/plain");
    try part.withFilename("test.txt");
    try testing.expectEqualStrings("text/plain", part.media_type.?);
    try testing.expectEqualStrings("test.txt", part.filename.?);

    const json = try std.json.Stringify.valueAlloc(a, part, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"mediaType\":\"text/plain\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"filename\":\"test.txt\"") != null);
}

test "part as_text" {
    const a = testing.allocator;
    var p1 = try Part.text(a, "hello");
    defer p1.deinit();
    try testing.expectEqualStrings("hello", p1.asText().?);
    var p2 = try Part.raw(a, &[_]u8{});
    defer p2.deinit();
    try testing.expect(p2.asText() == null);
}

test "message new and text" {
    const a = testing.allocator;
    const parts = try a.alloc(Part, 1);
    parts[0] = try Part.text(a, "hi");
    var msg = try Message.init(a, .user, parts);
    defer msg.deinit();
    try testing.expect(msg.message_id.len > 0);
    try testing.expectEqual(Role.user, msg.role);
    try testing.expectEqual(@as(usize, 1), msg.parts.len);
    try testing.expectEqualStrings("hi", msg.text().?);
}

test "message serde" {
    const a = testing.allocator;
    const parts = try a.alloc(Part, 1);
    parts[0] = try Part.text(a, "response");
    const ext = try a.alloc([]const u8, 1);
    ext[0] = try a.dupe(u8, "ext1");
    const refs = try a.alloc([]const u8, 1);
    refs[0] = try a.dupe(u8, "t1");
    var msg = Message{
        .message_id = try a.dupe(u8, "m1"),
        .context_id = try a.dupe(u8, "c1"),
        .role = .agent,
        .parts = parts,
        .extensions = ext,
        .reference_task_ids = refs,
        .allocator = a,
    };
    defer msg.deinit();

    const json = try std.json.Stringify.valueAlloc(a, msg, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try Message.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(msg.message_id, back.message_id);
    try testing.expectEqualStrings(msg.context_id.?, back.context_id.?);
    try testing.expectEqual(msg.role, back.role);
    try testing.expectEqual(@as(usize, 1), back.parts.len);
    try testing.expectEqual(@as(usize, 1), back.extensions.?.len);
    try testing.expectEqual(@as(usize, 1), back.reference_task_ids.?.len);
}

test "task_state is_terminal" {
    try testing.expect(TaskState.completed.isTerminal());
    try testing.expect(TaskState.failed.isTerminal());
    try testing.expect(TaskState.canceled.isTerminal());
    try testing.expect(TaskState.rejected.isTerminal());
    try testing.expect(!TaskState.submitted.isTerminal());
    try testing.expect(!TaskState.working.isTerminal());
    try testing.expect(!TaskState.input_required.isTerminal());
    try testing.expect(!TaskState.auth_required.isTerminal());
    try testing.expect(!TaskState.unspecified.isTerminal());
}

test "task full serde" {
    const a = testing.allocator;
    // status.message
    const status_parts = try a.alloc(Part, 1);
    status_parts[0] = try Part.text(a, "working");
    var status_msg = try Message.init(a, .agent, status_parts);
    // history
    const hist = try a.alloc(Message, 1);
    const hp = try a.alloc(Part, 1);
    hp[0] = try Part.text(a, "do it");
    hist[0] = try Message.init(a, .user, hp);
    // artifacts
    const arts = try a.alloc(Artifact, 1);
    const ap = try a.alloc(Part, 1);
    ap[0] = try Part.text(a, "result data");
    arts[0] = .{
        .artifact_id = try a.dupe(u8, "a1"),
        .name = try a.dupe(u8, "output"),
        .parts = ap,
        .allocator = a,
    };

    var task = Task{
        .id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .status = .{ .state = .working, .message = status_msg, .allocator = a },
        .artifacts = arts,
        .history = hist,
        .allocator = a,
    };
    defer task.deinit();
    _ = &status_msg;

    const json = try std.json.Stringify.valueAlloc(a, task, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try Task.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(task.id, back.id);
    try testing.expectEqual(task.status.state, back.status.state);
    try testing.expect(back.artifacts != null);
    try testing.expect(back.history != null);
}

test "push_notification_config serde" {
    const a = testing.allocator;
    var cfg = PushNotificationConfig{
        .url = try a.dupe(u8, "https://example.com/webhook"),
        .id = try a.dupe(u8, "cfg-1"),
        .token = try a.dupe(u8, "tok-1"),
        .authentication = AuthenticationInfo{
            .scheme = try a.dupe(u8, "Bearer"),
            .credentials = try a.dupe(u8, "secret"),
            .allocator = a,
        },
        .allocator = a,
    };
    defer cfg.deinit();

    const json = try std.json.Stringify.valueAlloc(a, cfg, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try PushNotificationConfig.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(cfg.url, back.url);
    try testing.expectEqualStrings(cfg.id.?, back.id.?);
    try testing.expectEqualStrings(cfg.authentication.?.scheme, back.authentication.?.scheme);
}

test "send_message_request serde" {
    const a = testing.allocator;
    const parts = try a.alloc(Part, 1);
    parts[0] = try Part.text(a, "hello");
    const msg = try Message.init(a, .user, parts);

    const modes = try a.alloc([]const u8, 1);
    modes[0] = try a.dupe(u8, "text/plain");

    var req = SendMessageRequest{
        .message = msg,
        .configuration = SendMessageConfiguration{
            .accepted_output_modes = modes,
            .history_length = 10,
            .return_immediately = true,
            .allocator = a,
        },
        .tenant = try a.dupe(u8, "tenant-1"),
        .allocator = a,
    };
    defer req.deinit();

    const json = try std.json.Stringify.valueAlloc(a, req, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SendMessageRequest.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(req.tenant.?, back.tenant.?);
    try testing.expectEqual(req.configuration.?.history_length, back.configuration.?.history_length);
}

test "send_message_response task variant" {
    const a = testing.allocator;
    var task = Task{
        .id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .status = .{ .state = .submitted, .allocator = a },
        .allocator = a,
    };
    var resp = SendMessageResponse{ .task = task };
    defer resp.deinit();
    _ = &task;

    const json = try std.json.Stringify.valueAlloc(a, resp, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"task\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"message\"") == null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SendMessageResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .task);
}

test "send_message_response message variant" {
    const a = testing.allocator;
    const parts = try a.alloc(Part, 1);
    parts[0] = try Part.text(a, "hi");
    var resp = SendMessageResponse{ .message = try Message.init(a, .agent, parts) };
    defer resp.deinit();

    const json = try std.json.Stringify.valueAlloc(a, resp, .{});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"message\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"task\"") == null);

    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SendMessageResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .message);
}

test "send_message_response message deserialize from inline json" {
    const a = testing.allocator;
    const json =
        \\{"message":{"messageId":"m1","role":"ROLE_AGENT","parts":[{"text":"hello"}]}}
    ;
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SendMessageResponse.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expect(back == .message);
}

test "new id functions" {
    const a = testing.allocator;
    const t = try newTaskId(a);
    defer a.free(t);
    const c = try newContextId(a);
    defer a.free(c);
    const m = try newMessageId(a);
    defer a.free(m);
    const ar = try newArtifactId(a);
    defer a.free(ar);
    try testing.expectEqual(@as(usize, 36), t.len);
    try testing.expect(!std.mem.eql(u8, t, c));
}

test "role default" {
    try testing.expectEqual(Role.unspecified, Role.default());
}

test "task_state default" {
    try testing.expectEqual(TaskState.unspecified, TaskState.default());
}

test "list_tasks_request serde" {
    const a = testing.allocator;
    var req = ListTasksRequest{
        .context_id = try a.dupe(u8, "c1"),
        .status = .working,
        .page_size = 10,
        .history_length = 5,
        .include_artifacts = true,
        .allocator = a,
    };
    defer req.deinit();

    const json = try std.json.Stringify.valueAlloc(a, req, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try ListTasksRequest.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(req.context_id.?, back.context_id.?);
    try testing.expectEqual(req.status, back.status);
    try testing.expectEqual(req.page_size, back.page_size);
    try testing.expectEqual(req.history_length, back.history_length);
    try testing.expectEqual(req.include_artifacts, back.include_artifacts);
}

test "cancel_task_request serde" {
    const a = testing.allocator;
    var req = CancelTaskRequest{
        .id = try a.dupe(u8, "t1"),
        .tenant = try a.dupe(u8, "ten"),
        .allocator = a,
    };
    defer req.deinit();

    const json = try std.json.Stringify.valueAlloc(a, req, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try CancelTaskRequest.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(req.id, back.id);
    try testing.expectEqualStrings(req.tenant.?, back.tenant.?);
}

test "subscribe_to_task_request serde" {
    const a = testing.allocator;
    var req = SubscribeToTaskRequest{
        .id = try a.dupe(u8, "t1"),
        .allocator = a,
    };
    defer req.deinit();
    const json = try std.json.Stringify.valueAlloc(a, req, .{});
    defer a.free(json);
    const parsed = try parseValueOwned(a, json);
    defer parsed.deinit();
    var back = try SubscribeToTaskRequest.jsonParseFromValue(a, parsed.value, .{});
    defer back.deinit();
    try testing.expectEqualStrings(req.id, back.id);
}

test "role all variants serde" {
    const a = testing.allocator;
    const cases = [_]struct { Role, []const u8 }{
        .{ .unspecified, "\"ROLE_UNSPECIFIED\"" },
        .{ .user, "\"ROLE_USER\"" },
        .{ .agent, "\"ROLE_AGENT\"" },
    };
    for (cases) |c| {
        const json = try std.json.Stringify.valueAlloc(a, c[0], .{});
        defer a.free(json);
        try testing.expectEqualStrings(c[1], json);
        const parsed = try parseValueOwned(a, json);
        defer parsed.deinit();
        const back = try Role.jsonParseFromValue(a, parsed.value, .{});
        try testing.expectEqual(c[0], back);
    }
    const parsed = try parseValueOwned(a, "\"\"");
    defer parsed.deinit();
    const back = try Role.jsonParseFromValue(a, parsed.value, .{});
    try testing.expectEqual(Role.unspecified, back);
}

test "task_state all variants serde" {
    const a = testing.allocator;
    const cases = [_]struct { TaskState, []const u8 }{
        .{ .unspecified, "TASK_STATE_UNSPECIFIED" },
        .{ .submitted, "TASK_STATE_SUBMITTED" },
        .{ .working, "TASK_STATE_WORKING" },
        .{ .completed, "TASK_STATE_COMPLETED" },
        .{ .failed, "TASK_STATE_FAILED" },
        .{ .canceled, "TASK_STATE_CANCELED" },
        .{ .input_required, "TASK_STATE_INPUT_REQUIRED" },
        .{ .rejected, "TASK_STATE_REJECTED" },
        .{ .auth_required, "TASK_STATE_AUTH_REQUIRED" },
    };
    for (cases) |c| {
        const json = try std.json.Stringify.valueAlloc(a, c[0], .{});
        defer a.free(json);
        const expected = try std.fmt.allocPrint(a, "\"{s}\"", .{c[1]});
        defer a.free(expected);
        try testing.expectEqualStrings(expected, json);
        const parsed = try parseValueOwned(a, json);
        defer parsed.deinit();
        const back = try TaskState.jsonParseFromValue(a, parsed.value, .{});
        try testing.expectEqual(c[0], back);
    }
    const parsed = try parseValueOwned(a, "\"\"");
    defer parsed.deinit();
    const back = try TaskState.jsonParseFromValue(a, parsed.value, .{});
    try testing.expectEqual(TaskState.unspecified, back);
}
