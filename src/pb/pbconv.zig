//! Bidirectional conversion between native A2A types (`src/a2a/`) and the
//! protobuf-generated types in `gen/lf/a2a/v1.pb.zig`. Each public type pair
//! has a `toProto` (allocate proto from native) and `fromProto` (allocate
//! native from proto) function. Both sides take an explicit allocator and
//! transfer ownership to the caller.
//!
//! Memory model on the proto side: every owned slice (`[]const u8`, repeated
//! arrays, submessages) is allocated against the caller-supplied allocator.
//! Use `@TypeName.deinit(&proto, allocator)` from the generated bindings to
//! free a returned proto value.
const std = @import("std");
const a2a = @import("a2a");
const v1 = @import("gen/lf/a2a/v1.pb.zig");
const wkt = @import("gen/google/protobuf.pb.zig");
const errors_mod = a2a.errors;

// ---------------------------------------------------------------------------
// Optional-string helpers
// ---------------------------------------------------------------------------

/// Treat an empty proto string as "absent".
pub fn emptyToNone(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

/// Owned dup of `?str` (returns empty slice when none).
pub fn optStrToProto(allocator: std.mem.Allocator, s: ?[]const u8) ![]const u8 {
    return if (s) |v| try allocator.dupe(u8, v) else &.{};
}

/// Owned dup of `proto` empty-or-string into `?[]const u8` native.
pub fn optStrFromProto(allocator: std.mem.Allocator, s: []const u8) !?[]const u8 {
    return if (s.len == 0) null else try allocator.dupe(u8, s);
}

// ---------------------------------------------------------------------------
// String list helpers (proto: repeated string default empty; native: ?[]const []const u8)
// ---------------------------------------------------------------------------

pub fn strListToProto(
    allocator: std.mem.Allocator,
    items: ?[]const []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    if (items) |arr| {
        try out.ensureTotalCapacityPrecise(allocator, arr.len);
        for (arr) |s| out.appendAssumeCapacity(try allocator.dupe(u8, s));
    }
    return out;
}

pub fn strListFromProto(
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),
) !?[]const []const u8 {
    if (items.items.len == 0) return null;
    const out = try allocator.alloc([]const u8, items.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < items.items.len) : (i += 1) out[i] = try allocator.dupe(u8, items.items[i]);
    return out;
}

/// Mandatory string list (proto: repeated; native: []const []const u8).
pub fn strListReqToProto(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, items.len);
    for (items) |s| out.appendAssumeCapacity(try allocator.dupe(u8, s));
    return out;
}

pub fn strListReqFromProto(
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),
) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| allocator.free(s);
        allocator.free(out);
    }
    while (i < items.items.len) : (i += 1) out[i] = try allocator.dupe(u8, items.items[i]);
    return out;
}

// ---------------------------------------------------------------------------
// google.protobuf.Value <-> std.json.Value
// ---------------------------------------------------------------------------

pub const ConvError = error{ OutOfMemory, OutOfRange, InvalidTimestamp };

pub fn jsonToProtoValue(allocator: std.mem.Allocator, v: std.json.Value) ConvError!wkt.Value {
    return switch (v) {
        .null => wkt.Value{ .kind = .{ .null_value = .NULL_VALUE } },
        .bool => |b| wkt.Value{ .kind = .{ .bool_value = b } },
        .integer => |i| wkt.Value{ .kind = .{ .number_value = @floatFromInt(i) } },
        .float => |f| wkt.Value{ .kind = .{ .number_value = f } },
        .number_string => |s| blk: {
            const parsed = std.fmt.parseFloat(f64, s) catch 0.0;
            break :blk wkt.Value{ .kind = .{ .number_value = parsed } };
        },
        .string => |s| wkt.Value{ .kind = .{ .string_value = try allocator.dupe(u8, s) } },
        .array => |arr| blk: {
            var values: std.ArrayList(wkt.Value) = .empty;
            try values.ensureTotalCapacityPrecise(allocator, arr.items.len);
            for (arr.items) |item| values.appendAssumeCapacity(try jsonToProtoValue(allocator, item));
            break :blk wkt.Value{ .kind = .{ .list_value = .{ .values = values } } };
        },
        .object => |obj| wkt.Value{ .kind = .{ .struct_value = try jsonToProtoStruct(allocator, obj) } },
    };
}

pub fn protoValueToJson(allocator: std.mem.Allocator, v: wkt.Value) ConvError!std.json.Value {
    const kind = v.kind orelse return std.json.Value.null;
    return switch (kind) {
        .null_value => std.json.Value.null,
        .bool_value => |b| std.json.Value{ .bool = b },
        .number_value => |f| blk: {
            // Preserve integers exactly when the float has no fractional part
            // and fits in i53 (f64's safe-integer range) — matches the Rust
            // deserializer's behavior. i64 boundaries don't round-trip
            // through f64, so we use the broader-but-exact 2^53 cap.
            const safe_max: f64 = 9_007_199_254_740_992.0; // 2^53
            if (@floor(f) == f and f >= -safe_max and f <= safe_max) {
                break :blk std.json.Value{ .integer = @intFromFloat(f) };
            }
            break :blk std.json.Value{ .float = f };
        },
        .string_value => |s| std.json.Value{ .string = try allocator.dupe(u8, s) },
        .struct_value => |s| std.json.Value{ .object = try protoStructToObjectMap(allocator, s) },
        .list_value => |lst| blk: {
            var arr = std.json.Array.init(allocator);
            try arr.ensureTotalCapacityPrecise(lst.values.items.len);
            for (lst.values.items) |item| arr.appendAssumeCapacity(try protoValueToJson(allocator, item));
            break :blk std.json.Value{ .array = arr };
        },
    };
}

pub fn jsonToProtoStruct(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ConvError!wkt.Struct {
    var fields: std.ArrayList(wkt.Struct.FieldsEntry) = .empty;
    try fields.ensureTotalCapacityPrecise(allocator, obj.count());
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try jsonToProtoValue(allocator, entry.value_ptr.*);
        fields.appendAssumeCapacity(.{ .key = key, .value = value });
    }
    return .{ .fields = fields };
}

pub fn protoStructToObjectMap(allocator: std.mem.Allocator, s: wkt.Struct) ConvError!std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    for (s.fields.items) |entry| {
        const key = try allocator.dupe(u8, entry.key);
        const v = if (entry.value) |val| try protoValueToJson(allocator, val) else std.json.Value.null;
        try out.put(allocator, key, v);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Metadata <-> ?google.protobuf.Struct
// ---------------------------------------------------------------------------

pub fn metadataToProto(
    allocator: std.mem.Allocator,
    meta: ?a2a.Metadata,
) !?wkt.Struct {
    if (meta) |m| return try jsonToProtoStruct(allocator, m.object);
    return null;
}

pub fn metadataFromProto(
    allocator: std.mem.Allocator,
    s: ?wkt.Struct,
) !?a2a.Metadata {
    const proto_struct = s orelse return null;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const aa = arena.allocator();
    const obj = try protoStructToObjectMap(aa, proto_struct);
    return .{ .object = obj, .arena = arena };
}

// ---------------------------------------------------------------------------
// Timestamp <-> ?[]const u8 (RFC3339)
// ---------------------------------------------------------------------------
//
// Rust uses `chrono::DateTime<Utc>` natively. We carry the wire timestamp as
// an RFC3339 string (with `zeit` as the parser/formatter when callers want
// structured access). The proto representation is `google.protobuf.Timestamp`
// with `seconds` + `nanos`.

pub fn timestampToProto(
    _: std.mem.Allocator,
    ts: ?[]const u8,
) !?wkt.Timestamp {
    const s = ts orelse return null;
    // RFC3339 → seconds + nanos. We parse manually to avoid a hard dep on
    // `zeit` in this layer; the format the protocol emits is always
    // millisecond-precision UTC produced by `Instant.formatRfc3339`.
    const epoch_ns = parseRfc3339Nanos(s) catch return null;
    const seconds: i64 = @intCast(@divFloor(epoch_ns, std.time.ns_per_s));
    const nanos: i32 = @intCast(@mod(epoch_ns, std.time.ns_per_s));
    return .{ .seconds = seconds, .nanos = nanos };
}

pub fn timestampFromProto(
    allocator: std.mem.Allocator,
    ts: ?wkt.Timestamp,
) !?[]const u8 {
    const t = ts orelse return null;
    const total_ns: i128 = @as(i128, t.seconds) * std.time.ns_per_s + @as(i128, t.nanos);
    return try formatRfc3339Millis(allocator, total_ns);
}

fn parseRfc3339Nanos(input: []const u8) !i128 {
    // Minimal subset: YYYY-MM-DDTHH:MM:SS[.fraction]Z|±HH:MM
    if (input.len < 20) return error.InvalidTimestamp;

    var idx: usize = 0;
    const year: i64 = @intCast(try parseFixedDigits(4, input, &idx));
    if (input[idx] != '-') return error.InvalidTimestamp;
    idx += 1;
    const month: u8 = @intCast(try parseFixedDigits(2, input, &idx));
    if (input[idx] != '-') return error.InvalidTimestamp;
    idx += 1;
    const day: u8 = @intCast(try parseFixedDigits(2, input, &idx));
    if (input[idx] != 'T' and input[idx] != 't') return error.InvalidTimestamp;
    idx += 1;
    const hour: u8 = @intCast(try parseFixedDigits(2, input, &idx));
    if (input[idx] != ':') return error.InvalidTimestamp;
    idx += 1;
    const minute: u8 = @intCast(try parseFixedDigits(2, input, &idx));
    if (input[idx] != ':') return error.InvalidTimestamp;
    idx += 1;
    const second: u8 = @intCast(try parseFixedDigits(2, input, &idx));

    var sub_ns: u64 = 0;
    if (idx < input.len and input[idx] == '.') {
        idx += 1;
        var digits: usize = 0;
        var fraction: u64 = 0;
        while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') {
            if (digits < 9) fraction = fraction * 10 + (input[idx] - '0');
            digits += 1;
            idx += 1;
        }
        if (digits == 0) return error.InvalidTimestamp;
        var pad: usize = digits;
        while (pad < 9) : (pad += 1) fraction *= 10;
        sub_ns = fraction;
    }

    if (idx >= input.len) return error.InvalidTimestamp;
    var offset_minutes: i32 = 0;
    const tz = input[idx];
    if (tz == 'Z' or tz == 'z') {
        idx += 1;
    } else if (tz == '+' or tz == '-') {
        idx += 1;
        const sign: i32 = if (tz == '+') 1 else -1;
        const oh = try parseFixedDigits(2, input, &idx);
        if (idx >= input.len or input[idx] != ':') return error.InvalidTimestamp;
        idx += 1;
        const om = try parseFixedDigits(2, input, &idx);
        offset_minutes = sign * @as(i32, @intCast(oh * 60 + om));
    } else return error.InvalidTimestamp;
    if (idx != input.len) return error.InvalidTimestamp;

    const days = daysFromCivil(@intCast(year), month, day);
    var total_seconds: i64 = days * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min +
        @as(i64, second);
    total_seconds -= @as(i64, offset_minutes) * 60;
    return @as(i128, total_seconds) * std.time.ns_per_s + @as(i128, sub_ns);
}

fn parseFixedDigits(comptime n: usize, s: []const u8, idx: *usize) !u64 {
    if (idx.* + n > s.len) return error.InvalidTimestamp;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = s[idx.* + i];
        if (c < '0' or c > '9') return error.InvalidTimestamp;
        v = v * 10 + (c - '0');
    }
    idx.* += n;
    return v;
}

fn daysFromCivil(y: i32, m: u8, d: u8) i64 {
    const yy: i64 = if (m <= 2) y - 1 else y;
    const era: i64 = @divFloor(yy, 400);
    const yoe: u64 = @intCast(yy - era * 400);
    const m_i64: i64 = @intCast(m);
    const d_i64: i64 = @intCast(d);
    const doy: u64 = @intCast(@divTrunc(153 * (if (m > 2) m_i64 - 3 else m_i64 + 9) + 2, 5) + d_i64 - 1);
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

fn civilFromDays(days: i64) struct { year: i32, month: u8, day: u8 } {
    const z = days + 719468;
    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @intCast(yoe);
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const year_offset: i64 = if (m <= 2) 1 else 0;
    return .{
        .year = @intCast(era * 400 + y + year_offset),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

fn formatRfc3339Millis(allocator: std.mem.Allocator, ns: i128) ![]u8 {
    const total_seconds: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    const sub_ns: i128 = ns - @as(i128, total_seconds) * std.time.ns_per_s;
    const sub_ns_u: u32 = @intCast(@mod(sub_ns + std.time.ns_per_s, std.time.ns_per_s));
    const ms_u: u32 = sub_ns_u / std.time.ns_per_ms;

    const days = @divFloor(total_seconds, std.time.s_per_day);
    const rem_seconds: u32 = @intCast(total_seconds - days * std.time.s_per_day);
    const civil = civilFromDays(days);
    if (civil.year < 0) return error.OutOfRange;
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            @as(u32, @intCast(civil.year)),
            civil.month,
            civil.day,
            @as(u32, rem_seconds / std.time.s_per_hour),
            @as(u32, (rem_seconds % std.time.s_per_hour) / std.time.s_per_min),
            @as(u32, rem_seconds % std.time.s_per_min),
            ms_u,
        },
    );
}

// ---------------------------------------------------------------------------
// Role / TaskState  (i32 enum on the proto side)
// ---------------------------------------------------------------------------

pub fn roleToProto(r: a2a.Role) v1.Role {
    return switch (r) {
        .unspecified => .ROLE_UNSPECIFIED,
        .user => .ROLE_USER,
        .agent => .ROLE_AGENT,
    };
}

pub fn roleFromProto(r: v1.Role) a2a.Role {
    return switch (r) {
        .ROLE_USER => .user,
        .ROLE_AGENT => .agent,
        else => .unspecified,
    };
}

pub fn taskStateToProto(s: a2a.TaskState) v1.TaskState {
    return switch (s) {
        .unspecified => .TASK_STATE_UNSPECIFIED,
        .submitted => .TASK_STATE_SUBMITTED,
        .working => .TASK_STATE_WORKING,
        .completed => .TASK_STATE_COMPLETED,
        .failed => .TASK_STATE_FAILED,
        .canceled => .TASK_STATE_CANCELED,
        .input_required => .TASK_STATE_INPUT_REQUIRED,
        .rejected => .TASK_STATE_REJECTED,
        .auth_required => .TASK_STATE_AUTH_REQUIRED,
    };
}

pub fn taskStateFromProto(s: v1.TaskState) a2a.TaskState {
    return switch (s) {
        .TASK_STATE_SUBMITTED => .submitted,
        .TASK_STATE_WORKING => .working,
        .TASK_STATE_COMPLETED => .completed,
        .TASK_STATE_FAILED => .failed,
        .TASK_STATE_CANCELED => .canceled,
        .TASK_STATE_INPUT_REQUIRED => .input_required,
        .TASK_STATE_REJECTED => .rejected,
        .TASK_STATE_AUTH_REQUIRED => .auth_required,
        else => .unspecified,
    };
}

// ---------------------------------------------------------------------------
// AuthenticationInfo
// ---------------------------------------------------------------------------

pub fn authenticationInfoToProto(
    allocator: std.mem.Allocator,
    src: a2a.AuthenticationInfo,
) !v1.AuthenticationInfo {
    return .{
        .scheme = try allocator.dupe(u8, src.scheme),
        .credentials = try optStrToProto(allocator, src.credentials),
    };
}

pub fn authenticationInfoFromProto(
    allocator: std.mem.Allocator,
    src: v1.AuthenticationInfo,
) !a2a.AuthenticationInfo {
    var out: a2a.AuthenticationInfo = .{
        .scheme = try allocator.dupe(u8, src.scheme),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.credentials)) |c| out.credentials = c;
    return out;
}

// ---------------------------------------------------------------------------
// Part (oneof content)
// ---------------------------------------------------------------------------

pub fn partToProto(allocator: std.mem.Allocator, src: a2a.Part) !v1.Part {
    var content: ?v1.Part.content_union = null;
    errdefer if (content) |*c| switch (c.*) {
        .text => |s| allocator.free(s),
        .raw => |b| allocator.free(b),
        .url => |s| allocator.free(s),
        .data => |*v| v.deinit(allocator),
    };
    switch (src.content) {
        .text => |s| content = .{ .text = try allocator.dupe(u8, s) },
        .raw => |b| content = .{ .raw = try allocator.dupe(u8, b) },
        .url => |s| content = .{ .url = try allocator.dupe(u8, s) },
        .data => |d| content = .{ .data = try jsonToProtoValue(allocator, d.value) },
    }
    return .{
        .content = content,
        .filename = try optStrToProto(allocator, src.filename),
        .media_type = try optStrToProto(allocator, src.media_type),
        .metadata = try metadataToProto(allocator, src.metadata),
    };
}

pub fn partFromProto(allocator: std.mem.Allocator, src: v1.Part) !a2a.Part {
    var part: a2a.Part = undefined;
    part.allocator = allocator;
    part.filename = null;
    part.media_type = null;
    part.metadata = null;

    if (src.content) |c| switch (c) {
        .text => |s| part.content = .{ .text = try allocator.dupe(u8, s) },
        .raw => |b| part.content = .{ .raw = try allocator.dupe(u8, b) },
        .url => |s| part.content = .{ .url = try allocator.dupe(u8, s) },
        .data => |v| {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer {
                arena.deinit();
                allocator.destroy(arena);
            }
            const cloned = try protoValueToJson(arena.allocator(), v);
            part.content = .{ .data = .{ .value = cloned, .arena = arena } };
        },
    } else {
        // No oneof set on the wire — collapse to an empty text part. Matches
        // the Rust converter's behavior.
        part.content = .{ .text = try allocator.dupe(u8, "") };
    }
    errdefer part.content.deinit(allocator);

    if (try optStrFromProto(allocator, src.filename)) |s| part.filename = s;
    if (try optStrFromProto(allocator, src.media_type)) |s| part.media_type = s;
    if (try metadataFromProto(allocator, src.metadata)) |m| part.metadata = m;
    return part;
}

fn partsToProto(allocator: std.mem.Allocator, src: []const a2a.Part) !std.ArrayList(v1.Part) {
    var out: std.ArrayList(v1.Part) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, src.len);
    for (src) |p| out.appendAssumeCapacity(try partToProto(allocator, p));
    return out;
}

fn partsFromProto(allocator: std.mem.Allocator, src: std.ArrayList(v1.Part)) ![]a2a.Part {
    const out = try allocator.alloc(a2a.Part, src.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |*p| p.deinit();
        allocator.free(out);
    }
    while (i < src.items.len) : (i += 1) out[i] = try partFromProto(allocator, src.items[i]);
    return out;
}

// ---------------------------------------------------------------------------
// Message
// ---------------------------------------------------------------------------

pub fn messageToProto(allocator: std.mem.Allocator, src: a2a.Message) !v1.Message {
    return .{
        .message_id = try allocator.dupe(u8, src.message_id),
        .context_id = try optStrToProto(allocator, src.context_id),
        .task_id = try optStrToProto(allocator, src.task_id),
        .role = roleToProto(src.role),
        .parts = try partsToProto(allocator, src.parts),
        .metadata = try metadataToProto(allocator, src.metadata),
        .extensions = try strListToProto(allocator, src.extensions),
        .reference_task_ids = try strListToProto(allocator, src.reference_task_ids),
    };
}

pub fn messageFromProto(allocator: std.mem.Allocator, src: v1.Message) !a2a.Message {
    var out: a2a.Message = .{
        .message_id = try allocator.dupe(u8, src.message_id),
        .role = roleFromProto(src.role),
        .allocator = allocator,
    };
    errdefer out.deinit();

    if (try optStrFromProto(allocator, src.context_id)) |s| out.context_id = s;
    if (try optStrFromProto(allocator, src.task_id)) |s| out.task_id = s;
    out.parts = try partsFromProto(allocator, src.parts);
    if (try metadataFromProto(allocator, src.metadata)) |m| out.metadata = m;
    if (try strListFromProto(allocator, src.extensions)) |arr| out.extensions = arr;
    if (try strListFromProto(allocator, src.reference_task_ids)) |arr| out.reference_task_ids = arr;
    return out;
}

// ---------------------------------------------------------------------------
// TaskStatus
// ---------------------------------------------------------------------------

pub fn taskStatusToProto(allocator: std.mem.Allocator, src: a2a.TaskStatus) !v1.TaskStatus {
    return .{
        .state = taskStateToProto(src.state),
        .message = if (src.message) |m| try messageToProto(allocator, m) else null,
        .timestamp = try timestampToProto(allocator, src.timestamp),
    };
}

pub fn taskStatusFromProto(allocator: std.mem.Allocator, src: v1.TaskStatus) !a2a.TaskStatus {
    var out: a2a.TaskStatus = .{
        .state = taskStateFromProto(src.state),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (src.message) |m| out.message = try messageFromProto(allocator, m);
    if (try timestampFromProto(allocator, src.timestamp)) |s| out.timestamp = s;
    return out;
}

// ---------------------------------------------------------------------------
// Artifact
// ---------------------------------------------------------------------------

pub fn artifactToProto(allocator: std.mem.Allocator, src: a2a.Artifact) !v1.Artifact {
    return .{
        .artifact_id = try allocator.dupe(u8, src.artifact_id),
        .name = try optStrToProto(allocator, src.name),
        .description = try optStrToProto(allocator, src.description),
        .parts = try partsToProto(allocator, src.parts),
        .metadata = try metadataToProto(allocator, src.metadata),
        .extensions = try strListToProto(allocator, src.extensions),
    };
}

pub fn artifactFromProto(allocator: std.mem.Allocator, src: v1.Artifact) !a2a.Artifact {
    var out: a2a.Artifact = .{
        .artifact_id = try allocator.dupe(u8, src.artifact_id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.name)) |s| out.name = s;
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    out.parts = try partsFromProto(allocator, src.parts);
    if (try metadataFromProto(allocator, src.metadata)) |m| out.metadata = m;
    if (try strListFromProto(allocator, src.extensions)) |arr| out.extensions = arr;
    return out;
}

fn artifactsToProto(allocator: std.mem.Allocator, src: ?[]a2a.Artifact) !std.ArrayList(v1.Artifact) {
    var out: std.ArrayList(v1.Artifact) = .empty;
    if (src) |arr| {
        try out.ensureTotalCapacityPrecise(allocator, arr.len);
        for (arr) |a| out.appendAssumeCapacity(try artifactToProto(allocator, a));
    }
    return out;
}

fn artifactsFromProto(allocator: std.mem.Allocator, src: std.ArrayList(v1.Artifact)) !?[]a2a.Artifact {
    if (src.items.len == 0) return null;
    const out = try allocator.alloc(a2a.Artifact, src.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |*a| a.deinit();
        allocator.free(out);
    }
    while (i < src.items.len) : (i += 1) out[i] = try artifactFromProto(allocator, src.items[i]);
    return out;
}

fn historyToProto(allocator: std.mem.Allocator, src: ?[]a2a.Message) !std.ArrayList(v1.Message) {
    var out: std.ArrayList(v1.Message) = .empty;
    if (src) |arr| {
        try out.ensureTotalCapacityPrecise(allocator, arr.len);
        for (arr) |m| out.appendAssumeCapacity(try messageToProto(allocator, m));
    }
    return out;
}

fn historyFromProto(allocator: std.mem.Allocator, src: std.ArrayList(v1.Message)) !?[]a2a.Message {
    if (src.items.len == 0) return null;
    const out = try allocator.alloc(a2a.Message, src.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |*m| m.deinit();
        allocator.free(out);
    }
    while (i < src.items.len) : (i += 1) out[i] = try messageFromProto(allocator, src.items[i]);
    return out;
}

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

pub fn taskToProto(allocator: std.mem.Allocator, src: a2a.Task) !v1.Task {
    return .{
        .id = try allocator.dupe(u8, src.id),
        .context_id = try allocator.dupe(u8, src.context_id),
        .status = try taskStatusToProto(allocator, src.status),
        .artifacts = try artifactsToProto(allocator, src.artifacts),
        .history = try historyToProto(allocator, src.history),
        .metadata = try metadataToProto(allocator, src.metadata),
    };
}

pub fn taskFromProto(allocator: std.mem.Allocator, src: v1.Task) !a2a.Task {
    var out: a2a.Task = .{
        .id = try allocator.dupe(u8, src.id),
        .context_id = try allocator.dupe(u8, src.context_id),
        .status = .{ .allocator = allocator },
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (src.status) |st| {
        out.status.deinit();
        out.status = try taskStatusFromProto(allocator, st);
    }
    if (try artifactsFromProto(allocator, src.artifacts)) |arr| out.artifacts = arr;
    if (try historyFromProto(allocator, src.history)) |arr| out.history = arr;
    if (try metadataFromProto(allocator, src.metadata)) |m| out.metadata = m;
    return out;
}

// ---------------------------------------------------------------------------
// PushNotificationConfig + TaskPushNotificationConfig
//
// The proto flattens the native nested `{task_id, config: {url, id, ...}}`
// shape into a single message with all fields at the top level. We
// flatten/unflatten on the conversion boundary.
// ---------------------------------------------------------------------------

pub fn pushNotificationConfigToTaskProto(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    tenant: ?[]const u8,
    src: a2a.PushNotificationConfig,
) !v1.TaskPushNotificationConfig {
    return .{
        .tenant = try optStrToProto(allocator, tenant),
        .id = try optStrToProto(allocator, src.id),
        .task_id = try allocator.dupe(u8, task_id),
        .url = try allocator.dupe(u8, src.url),
        .token = try optStrToProto(allocator, src.token),
        .authentication = if (src.authentication) |auth|
            try authenticationInfoToProto(allocator, auth)
        else
            null,
    };
}

pub fn taskPushNotificationConfigToProto(
    allocator: std.mem.Allocator,
    src: a2a.TaskPushNotificationConfig,
) !v1.TaskPushNotificationConfig {
    return pushNotificationConfigToTaskProto(allocator, src.task_id, src.tenant, src.config);
}

pub fn taskPushNotificationConfigFromProto(
    allocator: std.mem.Allocator,
    src: v1.TaskPushNotificationConfig,
) !a2a.TaskPushNotificationConfig {
    var cfg = a2a.PushNotificationConfig{
        .url = try allocator.dupe(u8, src.url),
        .allocator = allocator,
    };
    errdefer cfg.deinit();
    if (try optStrFromProto(allocator, src.id)) |s| cfg.id = s;
    if (try optStrFromProto(allocator, src.token)) |s| cfg.token = s;
    if (src.authentication) |auth| cfg.authentication = try authenticationInfoFromProto(allocator, auth);

    var out: a2a.TaskPushNotificationConfig = .{
        .task_id = try allocator.dupe(u8, src.task_id),
        .config = cfg,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

// ---------------------------------------------------------------------------
// Push notification request/response wrappers
// ---------------------------------------------------------------------------

pub fn createTaskPushNotificationConfigRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.CreateTaskPushNotificationConfigRequest,
) !v1.TaskPushNotificationConfig {
    return pushNotificationConfigToTaskProto(allocator, src.task_id, src.tenant, src.config);
}

pub fn createTaskPushNotificationConfigRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.TaskPushNotificationConfig,
) !a2a.CreateTaskPushNotificationConfigRequest {
    var cfg = a2a.PushNotificationConfig{
        .url = try allocator.dupe(u8, src.url),
        .allocator = allocator,
    };
    errdefer cfg.deinit();
    if (try optStrFromProto(allocator, src.id)) |s| cfg.id = s;
    if (try optStrFromProto(allocator, src.token)) |s| cfg.token = s;
    if (src.authentication) |auth| cfg.authentication = try authenticationInfoFromProto(allocator, auth);

    var out: a2a.CreateTaskPushNotificationConfigRequest = .{
        .task_id = try allocator.dupe(u8, src.task_id),
        .config = cfg,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

pub fn getTaskPushNotificationConfigRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.GetTaskPushNotificationConfigRequest,
) !v1.GetTaskPushNotificationConfigRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .task_id = try allocator.dupe(u8, src.task_id),
        .id = try allocator.dupe(u8, src.id),
    };
}

pub fn getTaskPushNotificationConfigRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.GetTaskPushNotificationConfigRequest,
) !a2a.GetTaskPushNotificationConfigRequest {
    var out: a2a.GetTaskPushNotificationConfigRequest = .{
        .task_id = try allocator.dupe(u8, src.task_id),
        .id = try allocator.dupe(u8, src.id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

pub fn deleteTaskPushNotificationConfigRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.DeleteTaskPushNotificationConfigRequest,
) !v1.DeleteTaskPushNotificationConfigRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .task_id = try allocator.dupe(u8, src.task_id),
        .id = try allocator.dupe(u8, src.id),
    };
}

pub fn deleteTaskPushNotificationConfigRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.DeleteTaskPushNotificationConfigRequest,
) !a2a.DeleteTaskPushNotificationConfigRequest {
    var out: a2a.DeleteTaskPushNotificationConfigRequest = .{
        .task_id = try allocator.dupe(u8, src.task_id),
        .id = try allocator.dupe(u8, src.id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

pub fn listTaskPushNotificationConfigsRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.ListTaskPushNotificationConfigsRequest,
) !v1.ListTaskPushNotificationConfigsRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .task_id = try allocator.dupe(u8, src.task_id),
        .page_size = src.page_size orelse 0,
        .page_token = try optStrToProto(allocator, src.page_token),
    };
}

pub fn listTaskPushNotificationConfigsRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.ListTaskPushNotificationConfigsRequest,
) !a2a.ListTaskPushNotificationConfigsRequest {
    var out: a2a.ListTaskPushNotificationConfigsRequest = .{
        .task_id = try allocator.dupe(u8, src.task_id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    if (try optStrFromProto(allocator, src.page_token)) |s| out.page_token = s;
    if (src.page_size > 0) out.page_size = src.page_size;
    return out;
}

pub fn listTaskPushNotificationConfigsResponseToProto(
    allocator: std.mem.Allocator,
    src: a2a.ListTaskPushNotificationConfigsResponse,
) !v1.ListTaskPushNotificationConfigsResponse {
    var configs: std.ArrayList(v1.TaskPushNotificationConfig) = .empty;
    try configs.ensureTotalCapacityPrecise(allocator, src.configs.len);
    for (src.configs) |c| configs.appendAssumeCapacity(try taskPushNotificationConfigToProto(allocator, c));
    return .{
        .configs = configs,
        .next_page_token = try optStrToProto(allocator, src.next_page_token),
    };
}

pub fn listTaskPushNotificationConfigsResponseFromProto(
    allocator: std.mem.Allocator,
    src: v1.ListTaskPushNotificationConfigsResponse,
) !a2a.ListTaskPushNotificationConfigsResponse {
    const configs = try allocator.alloc(a2a.TaskPushNotificationConfig, src.configs.items.len);
    var i: usize = 0;
    errdefer {
        for (configs[0..i]) |*c| c.deinit();
        allocator.free(configs);
    }
    while (i < src.configs.items.len) : (i += 1) {
        configs[i] = try taskPushNotificationConfigFromProto(allocator, src.configs.items[i]);
    }
    var out: a2a.ListTaskPushNotificationConfigsResponse = .{
        .configs = configs,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.next_page_token)) |s| out.next_page_token = s;
    return out;
}

// ---------------------------------------------------------------------------
// SendMessageConfiguration
// ---------------------------------------------------------------------------

pub fn sendMessageConfigurationToProto(
    allocator: std.mem.Allocator,
    src: a2a.SendMessageConfiguration,
) !v1.SendMessageConfiguration {
    var task_pnc: ?v1.TaskPushNotificationConfig = null;
    if (src.push_notification_config) |pnc| {
        task_pnc = .{
            .tenant = &.{},
            .id = try optStrToProto(allocator, pnc.id),
            .task_id = &.{},
            .url = try allocator.dupe(u8, pnc.url),
            .token = try optStrToProto(allocator, pnc.token),
            .authentication = if (pnc.authentication) |auth|
                try authenticationInfoToProto(allocator, auth)
            else
                null,
        };
    }
    return .{
        .accepted_output_modes = try strListToProto(allocator, src.accepted_output_modes),
        .task_push_notification_config = task_pnc,
        .history_length = src.history_length,
        .return_immediately = src.return_immediately orelse false,
    };
}

pub fn sendMessageConfigurationFromProto(
    allocator: std.mem.Allocator,
    src: v1.SendMessageConfiguration,
) !a2a.SendMessageConfiguration {
    var out: a2a.SendMessageConfiguration = .{ .allocator = allocator };
    errdefer out.deinit();
    if (try strListFromProto(allocator, src.accepted_output_modes)) |arr| out.accepted_output_modes = arr;
    if (src.task_push_notification_config) |tpnc| {
        var pnc = a2a.PushNotificationConfig{
            .url = try allocator.dupe(u8, tpnc.url),
            .allocator = allocator,
        };
        errdefer pnc.deinit();
        if (try optStrFromProto(allocator, tpnc.id)) |s| pnc.id = s;
        if (try optStrFromProto(allocator, tpnc.token)) |s| pnc.token = s;
        if (tpnc.authentication) |auth| pnc.authentication = try authenticationInfoFromProto(allocator, auth);
        out.push_notification_config = pnc;
    }
    if (src.history_length) |n| out.history_length = n;
    out.return_immediately = src.return_immediately;
    return out;
}

// ---------------------------------------------------------------------------
// SendMessageRequest
// ---------------------------------------------------------------------------

pub fn sendMessageRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.SendMessageRequest,
) !v1.SendMessageRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .message = try messageToProto(allocator, src.message),
        .configuration = if (src.configuration) |c| try sendMessageConfigurationToProto(allocator, c) else null,
        .metadata = try metadataToProto(allocator, src.metadata),
    };
}

pub fn sendMessageRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.SendMessageRequest,
) !a2a.SendMessageRequest {
    const msg = if (src.message) |m|
        try messageFromProto(allocator, m)
    else
        // Wire allows omitted message; collapse to empty user message to
        // match the Rust converter's permissive behavior.
        try a2a.Message.init(allocator, .user, try allocator.alloc(a2a.Part, 0));

    var out: a2a.SendMessageRequest = .{
        .message = msg,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    if (src.configuration) |c| out.configuration = try sendMessageConfigurationFromProto(allocator, c);
    if (try metadataFromProto(allocator, src.metadata)) |m| out.metadata = m;
    return out;
}

// ---------------------------------------------------------------------------
// GetTaskRequest
// ---------------------------------------------------------------------------

pub fn getTaskRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.GetTaskRequest,
) !v1.GetTaskRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .id = try allocator.dupe(u8, src.id),
        .history_length = src.history_length,
    };
}

pub fn getTaskRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.GetTaskRequest,
) !a2a.GetTaskRequest {
    var out: a2a.GetTaskRequest = .{
        .id = try allocator.dupe(u8, src.id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    if (src.history_length) |n| out.history_length = n;
    return out;
}

// ---------------------------------------------------------------------------
// ListTasksRequest / ListTasksResponse
// ---------------------------------------------------------------------------

pub fn listTasksRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.ListTasksRequest,
) !v1.ListTasksRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .context_id = try optStrToProto(allocator, src.context_id),
        .status = if (src.status) |s| taskStateToProto(s) else .TASK_STATE_UNSPECIFIED,
        .page_size = src.page_size,
        .page_token = try optStrToProto(allocator, src.page_token),
        .history_length = src.history_length,
        .status_timestamp_after = try timestampToProto(allocator, src.status_timestamp_after),
        .include_artifacts = src.include_artifacts,
    };
}

pub fn listTasksRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.ListTasksRequest,
) !a2a.ListTasksRequest {
    var out: a2a.ListTasksRequest = .{ .allocator = allocator };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    if (try optStrFromProto(allocator, src.context_id)) |s| out.context_id = s;
    if (src.status != .TASK_STATE_UNSPECIFIED) out.status = taskStateFromProto(src.status);
    if (src.page_size) |n| out.page_size = n;
    if (try optStrFromProto(allocator, src.page_token)) |s| out.page_token = s;
    if (src.history_length) |n| out.history_length = n;
    if (try timestampFromProto(allocator, src.status_timestamp_after)) |s| out.status_timestamp_after = s;
    if (src.include_artifacts) |b| out.include_artifacts = b;
    return out;
}

pub fn listTasksResponseToProto(
    allocator: std.mem.Allocator,
    src: a2a.ListTasksResponse,
) !v1.ListTasksResponse {
    var tasks: std.ArrayList(v1.Task) = .empty;
    try tasks.ensureTotalCapacityPrecise(allocator, src.tasks.len);
    for (src.tasks) |t| tasks.appendAssumeCapacity(try taskToProto(allocator, t));
    return .{
        .tasks = tasks,
        .next_page_token = try allocator.dupe(u8, src.next_page_token),
        .page_size = src.page_size,
        .total_size = src.total_size,
    };
}

pub fn listTasksResponseFromProto(
    allocator: std.mem.Allocator,
    src: v1.ListTasksResponse,
) !a2a.ListTasksResponse {
    const tasks = try allocator.alloc(a2a.Task, src.tasks.items.len);
    var i: usize = 0;
    errdefer {
        for (tasks[0..i]) |*t| t.deinit();
        allocator.free(tasks);
    }
    while (i < src.tasks.items.len) : (i += 1) tasks[i] = try taskFromProto(allocator, src.tasks.items[i]);

    return .{
        .tasks = tasks,
        .next_page_token = try allocator.dupe(u8, src.next_page_token),
        .page_size = src.page_size,
        .total_size = src.total_size,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// CancelTaskRequest
// ---------------------------------------------------------------------------

pub fn cancelTaskRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.CancelTaskRequest,
) !v1.CancelTaskRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .id = try allocator.dupe(u8, src.id),
        .metadata = try metadataToProto(allocator, src.metadata),
    };
}

pub fn cancelTaskRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.CancelTaskRequest,
) !a2a.CancelTaskRequest {
    var out: a2a.CancelTaskRequest = .{
        .id = try allocator.dupe(u8, src.id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    if (try metadataFromProto(allocator, src.metadata)) |m| out.metadata = m;
    return out;
}

// ---------------------------------------------------------------------------
// SubscribeToTaskRequest
// ---------------------------------------------------------------------------

pub fn subscribeToTaskRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.SubscribeToTaskRequest,
) !v1.SubscribeToTaskRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
        .id = try allocator.dupe(u8, src.id),
    };
}

pub fn subscribeToTaskRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.SubscribeToTaskRequest,
) !a2a.SubscribeToTaskRequest {
    var out: a2a.SubscribeToTaskRequest = .{
        .id = try allocator.dupe(u8, src.id),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

// ---------------------------------------------------------------------------
// GetExtendedAgentCardRequest
// ---------------------------------------------------------------------------

pub fn getExtendedAgentCardRequestToProto(
    allocator: std.mem.Allocator,
    src: a2a.GetExtendedAgentCardRequest,
) !v1.GetExtendedAgentCardRequest {
    return .{
        .tenant = try optStrToProto(allocator, src.tenant),
    };
}

pub fn getExtendedAgentCardRequestFromProto(
    allocator: std.mem.Allocator,
    src: v1.GetExtendedAgentCardRequest,
) !a2a.GetExtendedAgentCardRequest {
    var out: a2a.GetExtendedAgentCardRequest = .{ .allocator = allocator };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

// ---------------------------------------------------------------------------
// AgentInterface
// ---------------------------------------------------------------------------

pub fn agentInterfaceToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentInterface,
) !v1.AgentInterface {
    return .{
        .url = try allocator.dupe(u8, src.url),
        .protocol_binding = try allocator.dupe(u8, src.protocol_binding),
        .tenant = try optStrToProto(allocator, src.tenant),
        .protocol_version = try allocator.dupe(u8, src.protocol_version),
    };
}

pub fn agentInterfaceFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentInterface,
) !a2a.AgentInterface {
    var out: a2a.AgentInterface = .{
        .url = try allocator.dupe(u8, src.url),
        .protocol_binding = try allocator.dupe(u8, src.protocol_binding),
        .protocol_version = try allocator.dupe(u8, src.protocol_version),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.tenant)) |s| out.tenant = s;
    return out;
}

// ---------------------------------------------------------------------------
// AgentProvider
// ---------------------------------------------------------------------------

pub fn agentProviderToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentProvider,
) !v1.AgentProvider {
    return .{
        .url = try allocator.dupe(u8, src.url),
        .organization = try allocator.dupe(u8, src.organization),
    };
}

pub fn agentProviderFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentProvider,
) !a2a.AgentProvider {
    return .{
        .organization = try allocator.dupe(u8, src.organization),
        .url = try allocator.dupe(u8, src.url),
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// AgentExtension
// ---------------------------------------------------------------------------

pub fn agentExtensionToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentExtension,
) !v1.AgentExtension {
    return .{
        .uri = try allocator.dupe(u8, src.uri),
        .description = try optStrToProto(allocator, src.description),
        .required = src.required orelse false,
        .params = try metadataToProto(allocator, src.params),
    };
}

pub fn agentExtensionFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentExtension,
) !a2a.AgentExtension {
    var out: a2a.AgentExtension = .{
        .uri = try allocator.dupe(u8, src.uri),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    out.required = src.required;
    if (try metadataFromProto(allocator, src.params)) |m| out.params = m;
    return out;
}

// ---------------------------------------------------------------------------
// AgentCapabilities
// ---------------------------------------------------------------------------

pub fn agentCapabilitiesToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentCapabilities,
) !v1.AgentCapabilities {
    var ext_list: std.ArrayList(v1.AgentExtension) = .empty;
    if (src.extensions) |arr| {
        try ext_list.ensureTotalCapacityPrecise(allocator, arr.len);
        for (arr) |e| ext_list.appendAssumeCapacity(try agentExtensionToProto(allocator, e));
    }
    return .{
        .streaming = src.streaming,
        .push_notifications = src.push_notifications,
        .extensions = ext_list,
        .extended_agent_card = src.extended_agent_card,
    };
}

pub fn agentCapabilitiesFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentCapabilities,
) !a2a.AgentCapabilities {
    var out: a2a.AgentCapabilities = .{ .allocator = allocator };
    errdefer out.deinit();
    if (src.streaming) |b| out.streaming = b;
    if (src.push_notifications) |b| out.push_notifications = b;
    if (src.extended_agent_card) |b| out.extended_agent_card = b;
    if (src.extensions.items.len > 0) {
        const dst = try allocator.alloc(a2a.AgentExtension, src.extensions.items.len);
        var i: usize = 0;
        errdefer {
            for (dst[0..i]) |*e| e.deinit();
            allocator.free(dst);
        }
        while (i < src.extensions.items.len) : (i += 1) {
            dst[i] = try agentExtensionFromProto(allocator, src.extensions.items[i]);
        }
        out.extensions = dst;
    }
    return out;
}

// ---------------------------------------------------------------------------
// SecurityRequirement (proto: schemes -> StringList; native: scheme -> [scopes])
// ---------------------------------------------------------------------------

pub fn securityRequirementToProto(
    allocator: std.mem.Allocator,
    src: a2a.SecurityRequirement,
) !v1.SecurityRequirement {
    var entries: std.ArrayList(v1.SecurityRequirement.SchemesEntry) = .empty;
    try entries.ensureTotalCapacityPrecise(allocator, src.entries.count());
    var it = src.entries.iterator();
    while (it.next()) |e| {
        var list: std.ArrayList([]const u8) = .empty;
        try list.ensureTotalCapacityPrecise(allocator, e.value_ptr.*.len);
        for (e.value_ptr.*) |scope| list.appendAssumeCapacity(try allocator.dupe(u8, scope));
        entries.appendAssumeCapacity(.{
            .key = try allocator.dupe(u8, e.key_ptr.*),
            .value = .{ .list = list },
        });
    }
    return .{ .schemes = entries };
}

pub fn securityRequirementFromProto(
    allocator: std.mem.Allocator,
    src: v1.SecurityRequirement,
) !a2a.SecurityRequirement {
    var out: a2a.SecurityRequirement = .{ .allocator = allocator };
    errdefer out.deinit();
    for (src.schemes.items) |entry| {
        const scopes_src = if (entry.value) |sl| sl.list.items else &[_][]const u8{};
        const scopes = try allocator.alloc([]const u8, scopes_src.len);
        var i: usize = 0;
        errdefer {
            for (scopes[0..i]) |s| allocator.free(s);
            allocator.free(scopes);
        }
        while (i < scopes_src.len) : (i += 1) scopes[i] = try allocator.dupe(u8, scopes_src[i]);
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        try out.entries.put(allocator, key, scopes);
    }
    return out;
}

fn securityRequirementsToProtoList(
    allocator: std.mem.Allocator,
    src: ?[]a2a.SecurityRequirement,
) !std.ArrayList(v1.SecurityRequirement) {
    var out: std.ArrayList(v1.SecurityRequirement) = .empty;
    if (src) |arr| {
        try out.ensureTotalCapacityPrecise(allocator, arr.len);
        for (arr) |r| out.appendAssumeCapacity(try securityRequirementToProto(allocator, r));
    }
    return out;
}

fn securityRequirementsFromProtoList(
    allocator: std.mem.Allocator,
    src: std.ArrayList(v1.SecurityRequirement),
) !?[]a2a.SecurityRequirement {
    if (src.items.len == 0) return null;
    const out = try allocator.alloc(a2a.SecurityRequirement, src.items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |*r| r.deinit();
        allocator.free(out);
    }
    while (i < src.items.len) : (i += 1) {
        out[i] = try securityRequirementFromProto(allocator, src.items[i]);
    }
    return out;
}

// ---------------------------------------------------------------------------
// AgentSkill
// ---------------------------------------------------------------------------

pub fn agentSkillToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentSkill,
) !v1.AgentSkill {
    return .{
        .id = try allocator.dupe(u8, src.id),
        .name = try allocator.dupe(u8, src.name),
        .description = try allocator.dupe(u8, src.description),
        .tags = try strListReqToProto(allocator, src.tags),
        .examples = try strListToProto(allocator, src.examples),
        .input_modes = try strListToProto(allocator, src.input_modes),
        .output_modes = try strListToProto(allocator, src.output_modes),
        .security_requirements = try securityRequirementsToProtoList(allocator, src.security_requirements),
    };
}

pub fn agentSkillFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentSkill,
) !a2a.AgentSkill {
    var out: a2a.AgentSkill = .{
        .id = try allocator.dupe(u8, src.id),
        .name = try allocator.dupe(u8, src.name),
        .description = try allocator.dupe(u8, src.description),
        .allocator = allocator,
    };
    errdefer out.deinit();
    out.tags = try strListReqFromProto(allocator, src.tags);
    if (try strListFromProto(allocator, src.examples)) |arr| out.examples = arr;
    if (try strListFromProto(allocator, src.input_modes)) |arr| out.input_modes = arr;
    if (try strListFromProto(allocator, src.output_modes)) |arr| out.output_modes = arr;
    if (try securityRequirementsFromProtoList(allocator, src.security_requirements)) |arr| {
        out.security_requirements = arr;
    }
    return out;
}

// ---------------------------------------------------------------------------
// AgentCardSignature
// ---------------------------------------------------------------------------

pub fn agentCardSignatureToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentCardSignature,
) !v1.AgentCardSignature {
    return .{
        .protected = try allocator.dupe(u8, src.protected),
        .signature = try allocator.dupe(u8, src.signature),
        .header = try metadataToProto(allocator, src.header),
    };
}

pub fn agentCardSignatureFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentCardSignature,
) !a2a.AgentCardSignature {
    var out: a2a.AgentCardSignature = .{
        .protected = try allocator.dupe(u8, src.protected),
        .signature = try allocator.dupe(u8, src.signature),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try metadataFromProto(allocator, src.header)) |m| out.header = m;
    return out;
}

// ---------------------------------------------------------------------------
// Security schemes
// ---------------------------------------------------------------------------

pub fn apiKeySecuritySchemeToProto(
    allocator: std.mem.Allocator,
    src: a2a.ApiKeySecurityScheme,
) !v1.APIKeySecurityScheme {
    return .{
        .description = try optStrToProto(allocator, src.description),
        .location = try allocator.dupe(u8, src.location),
        .name = try allocator.dupe(u8, src.name),
    };
}

pub fn apiKeySecuritySchemeFromProto(
    allocator: std.mem.Allocator,
    src: v1.APIKeySecurityScheme,
) !a2a.ApiKeySecurityScheme {
    var out: a2a.ApiKeySecurityScheme = .{
        .location = try allocator.dupe(u8, src.location),
        .name = try allocator.dupe(u8, src.name),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    return out;
}

pub fn httpAuthSecuritySchemeToProto(
    allocator: std.mem.Allocator,
    src: a2a.HttpAuthSecurityScheme,
) !v1.HTTPAuthSecurityScheme {
    return .{
        .description = try optStrToProto(allocator, src.description),
        .scheme = try allocator.dupe(u8, src.scheme),
        .bearer_format = try optStrToProto(allocator, src.bearer_format),
    };
}

pub fn httpAuthSecuritySchemeFromProto(
    allocator: std.mem.Allocator,
    src: v1.HTTPAuthSecurityScheme,
) !a2a.HttpAuthSecurityScheme {
    var out: a2a.HttpAuthSecurityScheme = .{
        .scheme = try allocator.dupe(u8, src.scheme),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    if (try optStrFromProto(allocator, src.bearer_format)) |s| out.bearer_format = s;
    return out;
}

pub fn openIdConnectSecuritySchemeToProto(
    allocator: std.mem.Allocator,
    src: a2a.OpenIdConnectSecurityScheme,
) !v1.OpenIdConnectSecurityScheme {
    return .{
        .description = try optStrToProto(allocator, src.description),
        .open_id_connect_url = try allocator.dupe(u8, src.open_id_connect_url),
    };
}

pub fn openIdConnectSecuritySchemeFromProto(
    allocator: std.mem.Allocator,
    src: v1.OpenIdConnectSecurityScheme,
) !a2a.OpenIdConnectSecurityScheme {
    var out: a2a.OpenIdConnectSecurityScheme = .{
        .open_id_connect_url = try allocator.dupe(u8, src.open_id_connect_url),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    return out;
}

pub fn mutualTlsSecuritySchemeToProto(
    allocator: std.mem.Allocator,
    src: a2a.MutualTlsSecurityScheme,
) !v1.MutualTlsSecurityScheme {
    return .{
        .description = try optStrToProto(allocator, src.description),
    };
}

pub fn mutualTlsSecuritySchemeFromProto(
    allocator: std.mem.Allocator,
    src: v1.MutualTlsSecurityScheme,
) !a2a.MutualTlsSecurityScheme {
    var out: a2a.MutualTlsSecurityScheme = .{ .allocator = allocator };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    return out;
}

// ---------------------------------------------------------------------------
// OAuth flows + scopes
//
// Each flow's `scopes` is a repeated `ScopesEntry { key, value }` pair on the
// proto side. Generic over the entry type so all five flows share the helper.
// ---------------------------------------------------------------------------

fn scopesToProto(
    comptime Entry: type,
    allocator: std.mem.Allocator,
    src: a2a.agent_card.StringMap,
) !std.ArrayList(Entry) {
    var out: std.ArrayList(Entry) = .empty;
    try out.ensureTotalCapacityPrecise(allocator, src.entries.count());
    var it = src.entries.iterator();
    while (it.next()) |e| {
        out.appendAssumeCapacity(.{
            .key = try allocator.dupe(u8, e.key_ptr.*),
            .value = try allocator.dupe(u8, e.value_ptr.*),
        });
    }
    return out;
}

fn scopesFromProto(
    comptime Entry: type,
    allocator: std.mem.Allocator,
    src: std.ArrayList(Entry),
) !a2a.agent_card.StringMap {
    var out: a2a.agent_card.StringMap = .{ .allocator = allocator };
    errdefer out.deinit();
    for (src.items) |entry| {
        const k = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, entry.value);
        errdefer allocator.free(v);
        try out.entries.put(allocator, k, v);
    }
    return out;
}

pub fn authorizationCodeOAuthFlowToProto(
    allocator: std.mem.Allocator,
    src: a2a.agent_card.AuthorizationCodeOAuthFlow,
) !v1.AuthorizationCodeOAuthFlow {
    return .{
        .authorization_url = try allocator.dupe(u8, src.authorization_url),
        .token_url = try allocator.dupe(u8, src.token_url),
        .refresh_url = try optStrToProto(allocator, src.refresh_url),
        .scopes = try scopesToProto(v1.AuthorizationCodeOAuthFlow.ScopesEntry, allocator, src.scopes),
        .pkce_required = src.pkce_required orelse false,
    };
}

pub fn authorizationCodeOAuthFlowFromProto(
    allocator: std.mem.Allocator,
    src: v1.AuthorizationCodeOAuthFlow,
) !a2a.agent_card.AuthorizationCodeOAuthFlow {
    var out: a2a.agent_card.AuthorizationCodeOAuthFlow = .{
        .authorization_url = try allocator.dupe(u8, src.authorization_url),
        .token_url = try allocator.dupe(u8, src.token_url),
        .scopes = try scopesFromProto(v1.AuthorizationCodeOAuthFlow.ScopesEntry, allocator, src.scopes),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.refresh_url)) |s| out.refresh_url = s;
    out.pkce_required = src.pkce_required;
    return out;
}

pub fn clientCredentialsOAuthFlowToProto(
    allocator: std.mem.Allocator,
    src: a2a.agent_card.ClientCredentialsOAuthFlow,
) !v1.ClientCredentialsOAuthFlow {
    return .{
        .token_url = try allocator.dupe(u8, src.token_url),
        .refresh_url = try optStrToProto(allocator, src.refresh_url),
        .scopes = try scopesToProto(v1.ClientCredentialsOAuthFlow.ScopesEntry, allocator, src.scopes),
    };
}

pub fn clientCredentialsOAuthFlowFromProto(
    allocator: std.mem.Allocator,
    src: v1.ClientCredentialsOAuthFlow,
) !a2a.agent_card.ClientCredentialsOAuthFlow {
    var out: a2a.agent_card.ClientCredentialsOAuthFlow = .{
        .token_url = try allocator.dupe(u8, src.token_url),
        .scopes = try scopesFromProto(v1.ClientCredentialsOAuthFlow.ScopesEntry, allocator, src.scopes),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.refresh_url)) |s| out.refresh_url = s;
    return out;
}

pub fn implicitOAuthFlowToProto(
    allocator: std.mem.Allocator,
    src: a2a.agent_card.ImplicitOAuthFlow,
) !v1.ImplicitOAuthFlow {
    return .{
        .authorization_url = try allocator.dupe(u8, src.authorization_url),
        .refresh_url = try optStrToProto(allocator, src.refresh_url),
        .scopes = try scopesToProto(v1.ImplicitOAuthFlow.ScopesEntry, allocator, src.scopes),
    };
}

pub fn implicitOAuthFlowFromProto(
    allocator: std.mem.Allocator,
    src: v1.ImplicitOAuthFlow,
) !a2a.agent_card.ImplicitOAuthFlow {
    var out: a2a.agent_card.ImplicitOAuthFlow = .{
        .authorization_url = try allocator.dupe(u8, src.authorization_url),
        .scopes = try scopesFromProto(v1.ImplicitOAuthFlow.ScopesEntry, allocator, src.scopes),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.refresh_url)) |s| out.refresh_url = s;
    return out;
}

pub fn passwordOAuthFlowToProto(
    allocator: std.mem.Allocator,
    src: a2a.agent_card.PasswordOAuthFlow,
) !v1.PasswordOAuthFlow {
    return .{
        .token_url = try allocator.dupe(u8, src.token_url),
        .refresh_url = try optStrToProto(allocator, src.refresh_url),
        .scopes = try scopesToProto(v1.PasswordOAuthFlow.ScopesEntry, allocator, src.scopes),
    };
}

pub fn passwordOAuthFlowFromProto(
    allocator: std.mem.Allocator,
    src: v1.PasswordOAuthFlow,
) !a2a.agent_card.PasswordOAuthFlow {
    var out: a2a.agent_card.PasswordOAuthFlow = .{
        .token_url = try allocator.dupe(u8, src.token_url),
        .scopes = try scopesFromProto(v1.PasswordOAuthFlow.ScopesEntry, allocator, src.scopes),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.refresh_url)) |s| out.refresh_url = s;
    return out;
}

pub fn deviceCodeOAuthFlowToProto(
    allocator: std.mem.Allocator,
    src: a2a.agent_card.DeviceCodeOAuthFlow,
) !v1.DeviceCodeOAuthFlow {
    return .{
        .device_authorization_url = try allocator.dupe(u8, src.device_authorization_url),
        .token_url = try allocator.dupe(u8, src.token_url),
        .refresh_url = try optStrToProto(allocator, src.refresh_url),
        .scopes = try scopesToProto(v1.DeviceCodeOAuthFlow.ScopesEntry, allocator, src.scopes),
    };
}

pub fn deviceCodeOAuthFlowFromProto(
    allocator: std.mem.Allocator,
    src: v1.DeviceCodeOAuthFlow,
) !a2a.agent_card.DeviceCodeOAuthFlow {
    var out: a2a.agent_card.DeviceCodeOAuthFlow = .{
        .device_authorization_url = try allocator.dupe(u8, src.device_authorization_url),
        .token_url = try allocator.dupe(u8, src.token_url),
        .scopes = try scopesFromProto(v1.DeviceCodeOAuthFlow.ScopesEntry, allocator, src.scopes),
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.refresh_url)) |s| out.refresh_url = s;
    return out;
}

// ---------------------------------------------------------------------------
// OAuthFlows union
// ---------------------------------------------------------------------------

pub fn oauthFlowsToProto(
    allocator: std.mem.Allocator,
    src: a2a.OAuthFlows,
) !v1.OAuthFlows {
    var flow: ?v1.OAuthFlows.flow_union = null;
    switch (src) {
        .authorization_code => |f| flow = .{ .authorization_code = try authorizationCodeOAuthFlowToProto(allocator, f) },
        .client_credentials => |f| flow = .{ .client_credentials = try clientCredentialsOAuthFlowToProto(allocator, f) },
        .implicit => |f| flow = .{ .implicit = try implicitOAuthFlowToProto(allocator, f) },
        .password => |f| flow = .{ .password = try passwordOAuthFlowToProto(allocator, f) },
        .device_code => |f| flow = .{ .device_code = try deviceCodeOAuthFlowToProto(allocator, f) },
        .unknown => {
            // Unknown variants on the JSON wire have no protobuf
            // representation; collapse to an empty oneof so the proto remains
            // valid. The native side already preserved the original payload
            // for JSON re-emission.
            flow = null;
        },
    }
    return .{ .flow = flow };
}

pub fn oauthFlowsFromProto(
    allocator: std.mem.Allocator,
    src: v1.OAuthFlows,
) !a2a.OAuthFlows {
    const f = src.flow orelse return error.InvalidTimestamp;
    return switch (f) {
        .authorization_code => |x| .{ .authorization_code = try authorizationCodeOAuthFlowFromProto(allocator, x) },
        .client_credentials => |x| .{ .client_credentials = try clientCredentialsOAuthFlowFromProto(allocator, x) },
        .implicit => |x| .{ .implicit = try implicitOAuthFlowFromProto(allocator, x) },
        .password => |x| .{ .password = try passwordOAuthFlowFromProto(allocator, x) },
        .device_code => |x| .{ .device_code = try deviceCodeOAuthFlowFromProto(allocator, x) },
    };
}

// ---------------------------------------------------------------------------
// OAuth2 security scheme
// ---------------------------------------------------------------------------

pub fn oauth2SecuritySchemeToProto(
    allocator: std.mem.Allocator,
    src: a2a.OAuth2SecurityScheme,
) !v1.OAuth2SecurityScheme {
    return .{
        .description = try optStrToProto(allocator, src.description),
        .flows = try oauthFlowsToProto(allocator, src.flows),
        .oauth2_metadata_url = try optStrToProto(allocator, src.oauth2_metadata_url),
    };
}

pub fn oauth2SecuritySchemeFromProto(
    allocator: std.mem.Allocator,
    src: v1.OAuth2SecurityScheme,
) !a2a.OAuth2SecurityScheme {
    const flows_proto = src.flows orelse return error.InvalidTimestamp;
    var flows = try oauthFlowsFromProto(allocator, flows_proto);
    errdefer flows.deinit();
    var out: a2a.OAuth2SecurityScheme = .{
        .flows = flows,
        .allocator = allocator,
    };
    errdefer out.deinit();
    if (try optStrFromProto(allocator, src.description)) |s| out.description = s;
    if (try optStrFromProto(allocator, src.oauth2_metadata_url)) |s| out.oauth2_metadata_url = s;
    return out;
}

// ---------------------------------------------------------------------------
// SecurityScheme union
// ---------------------------------------------------------------------------

pub fn securitySchemeToProto(
    allocator: std.mem.Allocator,
    src: a2a.SecurityScheme,
) !v1.SecurityScheme {
    var scheme: ?v1.SecurityScheme.scheme_union = null;
    switch (src) {
        .api_key => |s| scheme = .{ .api_key_security_scheme = try apiKeySecuritySchemeToProto(allocator, s) },
        .http_auth => |s| scheme = .{ .http_auth_security_scheme = try httpAuthSecuritySchemeToProto(allocator, s) },
        .oauth2 => |s| scheme = .{ .oauth2_security_scheme = try oauth2SecuritySchemeToProto(allocator, s) },
        .openid_connect => |s| scheme = .{ .open_id_connect_security_scheme = try openIdConnectSecuritySchemeToProto(allocator, s) },
        .mtls => |s| scheme = .{ .mtls_security_scheme = try mutualTlsSecuritySchemeToProto(allocator, s) },
        .unknown => {
            // Same forward-compat handling as OAuthFlows: drop on the proto
            // side; native side already retains the original JSON payload.
            scheme = null;
        },
    }
    return .{ .scheme = scheme };
}

pub fn securitySchemeFromProto(
    allocator: std.mem.Allocator,
    src: v1.SecurityScheme,
) !a2a.SecurityScheme {
    const s = src.scheme orelse return error.InvalidTimestamp;
    return switch (s) {
        .api_key_security_scheme => |x| .{ .api_key = try apiKeySecuritySchemeFromProto(allocator, x) },
        .http_auth_security_scheme => |x| .{ .http_auth = try httpAuthSecuritySchemeFromProto(allocator, x) },
        .oauth2_security_scheme => |x| .{ .oauth2 = try oauth2SecuritySchemeFromProto(allocator, x) },
        .open_id_connect_security_scheme => |x| .{ .openid_connect = try openIdConnectSecuritySchemeFromProto(allocator, x) },
        .mtls_security_scheme => |x| .{ .mtls = try mutualTlsSecuritySchemeFromProto(allocator, x) },
    };
}

// ---------------------------------------------------------------------------
// AgentCard
// ---------------------------------------------------------------------------

pub fn agentCardToProto(
    allocator: std.mem.Allocator,
    src: a2a.AgentCard,
) !v1.AgentCard {
    var ifaces: std.ArrayList(v1.AgentInterface) = .empty;
    try ifaces.ensureTotalCapacityPrecise(allocator, src.supported_interfaces.len);
    for (src.supported_interfaces) |i| ifaces.appendAssumeCapacity(try agentInterfaceToProto(allocator, i));

    var skills: std.ArrayList(v1.AgentSkill) = .empty;
    try skills.ensureTotalCapacityPrecise(allocator, src.skills.len);
    for (src.skills) |s| skills.appendAssumeCapacity(try agentSkillToProto(allocator, s));

    var schemes: std.ArrayList(v1.AgentCard.SecuritySchemesEntry) = .empty;
    if (src.security_schemes) |ss| {
        try schemes.ensureTotalCapacityPrecise(allocator, ss.entries.count());
        var it = ss.entries.iterator();
        while (it.next()) |entry| {
            schemes.appendAssumeCapacity(.{
                .key = try allocator.dupe(u8, entry.key_ptr.*),
                .value = try securitySchemeToProto(allocator, entry.value_ptr.*),
            });
        }
    }

    var sigs: std.ArrayList(v1.AgentCardSignature) = .empty;
    if (src.signatures) |arr| {
        try sigs.ensureTotalCapacityPrecise(allocator, arr.len);
        for (arr) |s| sigs.appendAssumeCapacity(try agentCardSignatureToProto(allocator, s));
    }

    return .{
        .name = try allocator.dupe(u8, src.name),
        .description = try allocator.dupe(u8, src.description),
        .supported_interfaces = ifaces,
        .provider = if (src.provider) |p| try agentProviderToProto(allocator, p) else null,
        .version = try allocator.dupe(u8, src.version),
        .documentation_url = if (src.documentation_url) |s| try allocator.dupe(u8, s) else null,
        .capabilities = try agentCapabilitiesToProto(allocator, src.capabilities),
        .security_schemes = schemes,
        .security_requirements = try securityRequirementsToProtoList(allocator, src.security_requirements),
        .default_input_modes = try strListReqToProto(allocator, src.default_input_modes),
        .default_output_modes = try strListReqToProto(allocator, src.default_output_modes),
        .skills = skills,
        .signatures = sigs,
        .icon_url = if (src.icon_url) |s| try allocator.dupe(u8, s) else null,
    };
}

pub fn agentCardFromProto(
    allocator: std.mem.Allocator,
    src: v1.AgentCard,
) !a2a.AgentCard {
    const ifaces = try allocator.alloc(a2a.AgentInterface, src.supported_interfaces.items.len);
    var i: usize = 0;
    errdefer {
        for (ifaces[0..i]) |*x| x.deinit();
        allocator.free(ifaces);
    }
    while (i < src.supported_interfaces.items.len) : (i += 1) {
        ifaces[i] = try agentInterfaceFromProto(allocator, src.supported_interfaces.items[i]);
    }

    const skills = try allocator.alloc(a2a.AgentSkill, src.skills.items.len);
    var j: usize = 0;
    errdefer {
        for (skills[0..j]) |*s| s.deinit();
        allocator.free(skills);
    }
    while (j < src.skills.items.len) : (j += 1) {
        skills[j] = try agentSkillFromProto(allocator, src.skills.items[j]);
    }

    var card: a2a.AgentCard = .{
        .name = try allocator.dupe(u8, src.name),
        .description = try allocator.dupe(u8, src.description),
        .version = try allocator.dupe(u8, src.version),
        .supported_interfaces = ifaces,
        .capabilities = if (src.capabilities) |c|
            try agentCapabilitiesFromProto(allocator, c)
        else
            a2a.AgentCapabilities.default(allocator),
        .default_input_modes = try strListReqFromProto(allocator, src.default_input_modes),
        .default_output_modes = try strListReqFromProto(allocator, src.default_output_modes),
        .skills = skills,
        .allocator = allocator,
    };
    errdefer card.deinit();

    if (src.provider) |p| card.provider = try agentProviderFromProto(allocator, p);
    if (src.documentation_url) |s| if (s.len > 0) {
        card.documentation_url = try allocator.dupe(u8, s);
    };
    if (src.icon_url) |s| if (s.len > 0) {
        card.icon_url = try allocator.dupe(u8, s);
    };

    if (src.security_schemes.items.len > 0) {
        var schemes: a2a.SecuritySchemes = .{ .allocator = allocator };
        errdefer schemes.deinit();
        for (src.security_schemes.items) |entry| {
            const proto_value = entry.value orelse continue;
            var scheme = try securitySchemeFromProto(allocator, proto_value);
            errdefer scheme.deinit();
            const k = try allocator.dupe(u8, entry.key);
            errdefer allocator.free(k);
            try schemes.entries.put(allocator, k, scheme);
        }
        if (schemes.entries.count() > 0) card.security_schemes = schemes;
    }

    if (try securityRequirementsFromProtoList(allocator, src.security_requirements)) |arr| {
        card.security_requirements = arr;
    }

    if (src.signatures.items.len > 0) {
        const sigs = try allocator.alloc(a2a.AgentCardSignature, src.signatures.items.len);
        var k: usize = 0;
        errdefer {
            for (sigs[0..k]) |*s| s.deinit();
            allocator.free(sigs);
        }
        while (k < src.signatures.items.len) : (k += 1) {
            sigs[k] = try agentCardSignatureFromProto(allocator, src.signatures.items[k]);
        }
        card.signatures = sigs;
    }

    return card;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty_to_none semantics" {
    try testing.expect(emptyToNone("") == null);
    try testing.expectEqualStrings("x", emptyToNone("x").?);
}

test "role round-trips" {
    try testing.expectEqual(a2a.Role.user, roleFromProto(roleToProto(.user)));
    try testing.expectEqual(a2a.Role.agent, roleFromProto(roleToProto(.agent)));
    try testing.expectEqual(a2a.Role.unspecified, roleFromProto(roleToProto(.unspecified)));
}

test "task state round-trips" {
    const all = [_]a2a.TaskState{ .unspecified, .submitted, .working, .completed, .failed, .canceled, .input_required, .rejected, .auth_required };
    for (all) |s| try testing.expectEqual(s, taskStateFromProto(taskStateToProto(s)));
}

test "json value to proto value preserves integers" {
    const a = testing.allocator;
    const v = std.json.Value{ .integer = 42 };
    var pv = try jsonToProtoValue(a, v);
    defer pv.deinit(a);
    try testing.expectEqual(@as(f64, 42.0), pv.kind.?.number_value);
    const back = try protoValueToJson(a, pv);
    try testing.expectEqual(@as(i64, 42), back.integer);
}

test "json string round-trips through proto value" {
    const a = testing.allocator;
    const v = std.json.Value{ .string = "hello" };
    var pv = try jsonToProtoValue(a, v);
    defer pv.deinit(a);
    const back = try protoValueToJson(a, pv);
    defer if (back == .string) a.free(back.string);
    try testing.expectEqualStrings("hello", back.string);
}

test "metadata round-trip via proto struct" {
    const a = testing.allocator;
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    const aa = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, try aa.dupe(u8, "key"), .{ .string = try aa.dupe(u8, "value") });
    const meta = a2a.Metadata{ .object = obj, .arena = arena };
    var src: ?a2a.Metadata = meta;
    defer if (src) |*m| m.deinit(a);

    var proto_struct = try metadataToProto(a, src);
    defer if (proto_struct) |*ps| ps.deinit(a);

    var back = try metadataFromProto(a, proto_struct);
    defer if (back) |*m| m.deinit(a);

    try testing.expect(back != null);
    try testing.expectEqualStrings("value", back.?.object.get("key").?.string);
}

test "timestamp round-trips through proto" {
    const a = testing.allocator;
    const original = try a.dupe(u8, "2026-04-29T12:34:56.789Z");
    defer a.free(original);

    const proto = try timestampToProto(a, original);
    try testing.expect(proto != null);
    try testing.expect(proto.?.seconds > 0);

    const back = try timestampFromProto(a, proto);
    defer if (back) |s| a.free(s);
    try testing.expect(back != null);
    try testing.expectEqualStrings("2026-04-29T12:34:56.789Z", back.?);
}

test "authentication info round-trips" {
    const a = testing.allocator;
    var native = a2a.AuthenticationInfo{
        .scheme = try a.dupe(u8, "Bearer"),
        .credentials = try a.dupe(u8, "secret"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try authenticationInfoToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqualStrings("Bearer", proto.scheme);
    try testing.expectEqualStrings("secret", proto.credentials);

    var back = try authenticationInfoFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("Bearer", back.scheme);
    try testing.expectEqualStrings("secret", back.credentials.?);
}

test "authentication info empty credentials becomes null" {
    const a = testing.allocator;
    const proto = v1.AuthenticationInfo{
        .scheme = try a.dupe(u8, "Bearer"),
        .credentials = &.{},
    };
    var proto_mut = proto;
    defer proto_mut.deinit(a);
    var back = try authenticationInfoFromProto(a, proto_mut);
    defer back.deinit();
    try testing.expect(back.credentials == null);
}

test "part text round-trips through proto" {
    const a = testing.allocator;
    var native = try a2a.Part.text(a, "hello");
    defer native.deinit();
    var proto = try partToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqualStrings("hello", proto.content.?.text);
    var back = try partFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("hello", back.content.text);
}

test "part raw bytes round-trip" {
    const a = testing.allocator;
    var native = try a2a.Part.raw(a, &[_]u8{ 1, 2, 3, 4, 5 });
    defer native.deinit();
    var proto = try partToProto(a, native);
    defer proto.deinit(a);
    var back = try partFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5 }, back.content.raw);
}

test "part url with media type round-trips" {
    const a = testing.allocator;
    var native = try a2a.Part.url(a, "https://example.com/file.pdf");
    defer native.deinit();
    try native.withMediaType("application/pdf");
    var proto = try partToProto(a, native);
    defer proto.deinit(a);
    var back = try partFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("https://example.com/file.pdf", back.content.url);
    try testing.expectEqualStrings("application/pdf", back.media_type.?);
}

test "part data round-trips through proto value" {
    const a = testing.allocator;
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    const aa = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, try aa.dupe(u8, "k"), .{ .integer = 7 });
    var native = a2a.Part.data(a, .{ .object = obj }, arena);
    defer native.deinit();

    var proto = try partToProto(a, native);
    defer proto.deinit(a);
    try testing.expect(proto.content.? == .data);

    var back = try partFromProto(a, proto);
    defer back.deinit();
    try testing.expect(back.content == .data);
    try testing.expectEqual(@as(i64, 7), back.content.data.value.object.get("k").?.integer);
}

test "message with parts round-trips" {
    const a = testing.allocator;
    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "hi");
    var msg = try a2a.Message.init(a, .user, parts);
    defer msg.deinit();

    var proto = try messageToProto(a, msg);
    defer proto.deinit(a);
    try testing.expectEqualStrings(msg.message_id, proto.message_id);
    try testing.expectEqual(v1.Role.ROLE_USER, proto.role);
    try testing.expectEqual(@as(usize, 1), proto.parts.items.len);

    var back = try messageFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings(msg.message_id, back.message_id);
    try testing.expectEqual(a2a.Role.user, back.role);
    try testing.expectEqual(@as(usize, 1), back.parts.len);
    try testing.expectEqualStrings("hi", back.parts[0].content.text);
}

test "task status with timestamp round-trips" {
    const a = testing.allocator;
    var st = a2a.TaskStatus{
        .state = .working,
        .timestamp = try a.dupe(u8, "2026-04-29T12:34:56.789Z"),
        .allocator = a,
    };
    defer st.deinit();

    var proto = try taskStatusToProto(a, st);
    defer proto.deinit(a);
    try testing.expectEqual(v1.TaskState.TASK_STATE_WORKING, proto.state);
    try testing.expect(proto.timestamp != null);

    var back = try taskStatusFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqual(a2a.TaskState.working, back.state);
    try testing.expectEqualStrings("2026-04-29T12:34:56.789Z", back.timestamp.?);
}

test "artifact round-trips" {
    const a = testing.allocator;
    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "result");
    var native = a2a.Artifact{
        .artifact_id = try a.dupe(u8, "art1"),
        .name = try a.dupe(u8, "output.txt"),
        .parts = parts,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try artifactToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqualStrings("art1", proto.artifact_id);
    try testing.expectEqualStrings("output.txt", proto.name);

    var back = try artifactFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("art1", back.artifact_id);
    try testing.expectEqualStrings("output.txt", back.name.?);
    try testing.expectEqual(@as(usize, 1), back.parts.len);
}

test "task with status, artifacts, and history round-trips" {
    const a = testing.allocator;

    const status_msg_parts = try a.alloc(a2a.Part, 1);
    status_msg_parts[0] = try a2a.Part.text(a, "working");
    const status_msg = try a2a.Message.init(a, .agent, status_msg_parts);

    const arts = try a.alloc(a2a.Artifact, 1);
    const art_parts = try a.alloc(a2a.Part, 1);
    art_parts[0] = try a2a.Part.text(a, "artifact body");
    arts[0] = a2a.Artifact{
        .artifact_id = try a.dupe(u8, "a1"),
        .parts = art_parts,
        .allocator = a,
    };

    const hist = try a.alloc(a2a.Message, 1);
    const hist_parts = try a.alloc(a2a.Part, 1);
    hist_parts[0] = try a2a.Part.text(a, "do it");
    hist[0] = try a2a.Message.init(a, .user, hist_parts);

    var task = a2a.Task{
        .id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .status = .{ .state = .working, .message = status_msg, .allocator = a },
        .artifacts = arts,
        .history = hist,
        .allocator = a,
    };
    defer task.deinit();

    var proto = try taskToProto(a, task);
    defer proto.deinit(a);
    try testing.expectEqualStrings("t1", proto.id);
    try testing.expectEqual(@as(usize, 1), proto.artifacts.items.len);
    try testing.expectEqual(@as(usize, 1), proto.history.items.len);

    var back = try taskFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.id);
    try testing.expectEqualStrings("c1", back.context_id);
    try testing.expectEqual(a2a.TaskState.working, back.status.state);
    try testing.expect(back.artifacts != null);
    try testing.expectEqual(@as(usize, 1), back.artifacts.?.len);
    try testing.expect(back.history != null);
    try testing.expectEqual(@as(usize, 1), back.history.?.len);
}

test "task push notification config round-trips" {
    const a = testing.allocator;
    var native = a2a.TaskPushNotificationConfig{
        .task_id = try a.dupe(u8, "t1"),
        .config = .{
            .url = try a.dupe(u8, "https://example.com/hook"),
            .id = try a.dupe(u8, "cfg1"),
            .token = try a.dupe(u8, "tok-123"),
            .authentication = .{
                .scheme = try a.dupe(u8, "Bearer"),
                .credentials = try a.dupe(u8, "secret"),
                .allocator = a,
            },
            .allocator = a,
        },
        .tenant = try a.dupe(u8, "tenant-1"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try taskPushNotificationConfigToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqualStrings("t1", proto.task_id);
    try testing.expectEqualStrings("cfg1", proto.id);
    try testing.expectEqualStrings("https://example.com/hook", proto.url);

    var back = try taskPushNotificationConfigFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.task_id);
    try testing.expectEqualStrings("cfg1", back.config.id.?);
    try testing.expectEqualStrings("https://example.com/hook", back.config.url);
    try testing.expectEqualStrings("Bearer", back.config.authentication.?.scheme);
    try testing.expectEqualStrings("tenant-1", back.tenant.?);
}

test "create task push notification request round-trips" {
    const a = testing.allocator;
    var native = a2a.CreateTaskPushNotificationConfigRequest{
        .task_id = try a.dupe(u8, "t1"),
        .config = .{
            .url = try a.dupe(u8, "https://example.com/hook"),
            .allocator = a,
        },
        .allocator = a,
    };
    defer native.deinit();

    var proto = try createTaskPushNotificationConfigRequestToProto(a, native);
    defer proto.deinit(a);

    var back = try createTaskPushNotificationConfigRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.task_id);
    try testing.expectEqualStrings("https://example.com/hook", back.config.url);
}

test "get task push notification request round-trips" {
    const a = testing.allocator;
    var native = a2a.GetTaskPushNotificationConfigRequest{
        .task_id = try a.dupe(u8, "t1"),
        .id = try a.dupe(u8, "cfg1"),
        .tenant = try a.dupe(u8, "tenant-1"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try getTaskPushNotificationConfigRequestToProto(a, native);
    defer proto.deinit(a);

    var back = try getTaskPushNotificationConfigRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.task_id);
    try testing.expectEqualStrings("cfg1", back.id);
    try testing.expectEqualStrings("tenant-1", back.tenant.?);
}

test "delete task push notification request round-trips" {
    const a = testing.allocator;
    var native = a2a.DeleteTaskPushNotificationConfigRequest{
        .task_id = try a.dupe(u8, "t1"),
        .id = try a.dupe(u8, "cfg1"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try deleteTaskPushNotificationConfigRequestToProto(a, native);
    defer proto.deinit(a);

    var back = try deleteTaskPushNotificationConfigRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.task_id);
    try testing.expectEqualStrings("cfg1", back.id);
}

test "list task push notification request page params round-trip" {
    const a = testing.allocator;
    var native = a2a.ListTaskPushNotificationConfigsRequest{
        .task_id = try a.dupe(u8, "t1"),
        .page_size = 25,
        .page_token = try a.dupe(u8, "tok"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try listTaskPushNotificationConfigsRequestToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(@as(i32, 25), proto.page_size);
    try testing.expectEqualStrings("tok", proto.page_token);

    var back = try listTaskPushNotificationConfigsRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqual(@as(?i32, 25), back.page_size);
    try testing.expectEqualStrings("tok", back.page_token.?);
}

test "send message configuration round-trips" {
    const a = testing.allocator;
    const modes = try a.alloc([]const u8, 1);
    modes[0] = try a.dupe(u8, "text/plain");
    var native = a2a.SendMessageConfiguration{
        .accepted_output_modes = modes,
        .history_length = 10,
        .return_immediately = true,
        .push_notification_config = .{
            .url = try a.dupe(u8, "https://example.com/hook"),
            .id = try a.dupe(u8, "cfg1"),
            .allocator = a,
        },
        .allocator = a,
    };
    defer native.deinit();

    var proto = try sendMessageConfigurationToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(@as(?i32, 10), proto.history_length);
    try testing.expectEqual(true, proto.return_immediately);
    try testing.expect(proto.task_push_notification_config != null);
    try testing.expectEqualStrings("https://example.com/hook", proto.task_push_notification_config.?.url);

    var back = try sendMessageConfigurationFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqual(@as(?i32, 10), back.history_length);
    try testing.expectEqualStrings("https://example.com/hook", back.push_notification_config.?.url);
}

test "send message request round-trips" {
    const a = testing.allocator;
    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "hello");
    var native = a2a.SendMessageRequest{
        .message = try a2a.Message.init(a, .user, parts),
        .tenant = try a.dupe(u8, "tenant-1"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try sendMessageRequestToProto(a, native);
    defer proto.deinit(a);

    var back = try sendMessageRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("tenant-1", back.tenant.?);
    try testing.expectEqual(a2a.Role.user, back.message.role);
    try testing.expectEqual(@as(usize, 1), back.message.parts.len);
}

test "send message request with missing message decodes to empty user message" {
    const a = testing.allocator;
    var proto = v1.SendMessageRequest{
        .tenant = &.{},
        .message = null,
    };
    defer proto.deinit(a);

    var back = try sendMessageRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqual(a2a.Role.user, back.message.role);
    try testing.expectEqual(@as(usize, 0), back.message.parts.len);
}

test "get task request round-trips" {
    const a = testing.allocator;
    var native = a2a.GetTaskRequest{
        .id = try a.dupe(u8, "t1"),
        .history_length = 5,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try getTaskRequestToProto(a, native);
    defer proto.deinit(a);

    var back = try getTaskRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("t1", back.id);
    try testing.expectEqual(@as(?i32, 5), back.history_length);
}

test "list tasks request status filter round-trips" {
    const a = testing.allocator;
    var native = a2a.ListTasksRequest{
        .context_id = try a.dupe(u8, "c1"),
        .status = .working,
        .page_size = 50,
        .include_artifacts = true,
        .status_timestamp_after = try a.dupe(u8, "2026-04-29T00:00:00Z"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try listTasksRequestToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(v1.TaskState.TASK_STATE_WORKING, proto.status);
    try testing.expect(proto.status_timestamp_after != null);

    var back = try listTasksRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("c1", back.context_id.?);
    try testing.expectEqual(@as(?a2a.TaskState, .working), back.status);
    try testing.expectEqualStrings("2026-04-29T00:00:00.000Z", back.status_timestamp_after.?);
}

test "list tasks response carries tasks and paging" {
    const a = testing.allocator;
    const tasks = try a.alloc(a2a.Task, 1);
    tasks[0] = .{
        .id = try a.dupe(u8, "t1"),
        .context_id = try a.dupe(u8, "c1"),
        .status = .{ .state = .completed, .allocator = a },
        .allocator = a,
    };
    var native = a2a.ListTasksResponse{
        .tasks = tasks,
        .next_page_token = try a.dupe(u8, "next"),
        .page_size = 25,
        .total_size = 137,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try listTasksResponseToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(@as(usize, 1), proto.tasks.items.len);
    try testing.expectEqual(@as(i32, 25), proto.page_size);

    var back = try listTasksResponseFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("next", back.next_page_token);
    try testing.expectEqual(@as(i32, 137), back.total_size);
}

test "cancel and subscribe requests round-trip" {
    const a = testing.allocator;
    var cancel = a2a.CancelTaskRequest{
        .id = try a.dupe(u8, "t1"),
        .allocator = a,
    };
    defer cancel.deinit();
    var cancel_proto = try cancelTaskRequestToProto(a, cancel);
    defer cancel_proto.deinit(a);
    var cancel_back = try cancelTaskRequestFromProto(a, cancel_proto);
    defer cancel_back.deinit();
    try testing.expectEqualStrings("t1", cancel_back.id);

    var sub = a2a.SubscribeToTaskRequest{
        .id = try a.dupe(u8, "t1"),
        .tenant = try a.dupe(u8, "tenant-1"),
        .allocator = a,
    };
    defer sub.deinit();
    var sub_proto = try subscribeToTaskRequestToProto(a, sub);
    defer sub_proto.deinit(a);
    var sub_back = try subscribeToTaskRequestFromProto(a, sub_proto);
    defer sub_back.deinit();
    try testing.expectEqualStrings("t1", sub_back.id);
    try testing.expectEqualStrings("tenant-1", sub_back.tenant.?);
}

test "get extended agent card request round-trips" {
    const a = testing.allocator;
    var native = a2a.GetExtendedAgentCardRequest{
        .tenant = try a.dupe(u8, "tenant-1"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try getExtendedAgentCardRequestToProto(a, native);
    defer proto.deinit(a);

    var back = try getExtendedAgentCardRequestFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("tenant-1", back.tenant.?);
}

test "list task push notification response round-trips" {
    const a = testing.allocator;
    const configs = try a.alloc(a2a.TaskPushNotificationConfig, 1);
    configs[0] = .{
        .task_id = try a.dupe(u8, "t1"),
        .config = .{
            .url = try a.dupe(u8, "https://example.com/hook"),
            .allocator = a,
        },
        .allocator = a,
    };
    var native = a2a.ListTaskPushNotificationConfigsResponse{
        .configs = configs,
        .next_page_token = try a.dupe(u8, "next"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try listTaskPushNotificationConfigsResponseToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(@as(usize, 1), proto.configs.items.len);
    try testing.expectEqualStrings("next", proto.next_page_token);

    var back = try listTaskPushNotificationConfigsResponseFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.configs.len);
    try testing.expectEqualStrings("next", back.next_page_token.?);
}

test "agent interface round-trips" {
    const a = testing.allocator;
    var native = try a2a.AgentInterface.init(a, "http://localhost:3000", "JSONRPC");
    defer native.deinit();

    var proto = try agentInterfaceToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqualStrings("http://localhost:3000", proto.url);
    try testing.expectEqualStrings("JSONRPC", proto.protocol_binding);

    var back = try agentInterfaceFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings(native.url, back.url);
    try testing.expectEqualStrings(native.protocol_binding, back.protocol_binding);
}

test "agent provider round-trips" {
    const a = testing.allocator;
    var native = a2a.AgentProvider{
        .organization = try a.dupe(u8, "Magnova"),
        .url = try a.dupe(u8, "https://magnova.ai"),
        .allocator = a,
    };
    defer native.deinit();

    var proto = try agentProviderToProto(a, native);
    defer proto.deinit(a);
    var back = try agentProviderFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("Magnova", back.organization);
    try testing.expectEqualStrings("https://magnova.ai", back.url);
}

test "agent capabilities round-trips with extensions" {
    const a = testing.allocator;
    const exts = try a.alloc(a2a.AgentExtension, 1);
    exts[0] = .{
        .uri = try a.dupe(u8, "https://example.com/ext"),
        .required = true,
        .allocator = a,
    };
    var native = a2a.AgentCapabilities{
        .streaming = true,
        .push_notifications = false,
        .extensions = exts,
        .extended_agent_card = true,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try agentCapabilitiesToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(@as(?bool, true), proto.streaming);
    try testing.expectEqual(@as(usize, 1), proto.extensions.items.len);

    var back = try agentCapabilitiesFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqual(@as(?bool, true), back.streaming);
    try testing.expect(back.extensions != null);
    try testing.expectEqual(@as(usize, 1), back.extensions.?.len);
    try testing.expectEqualStrings("https://example.com/ext", back.extensions.?[0].uri);
}

test "agent skill round-trips" {
    const a = testing.allocator;
    const tags = try a.alloc([]const u8, 1);
    tags[0] = try a.dupe(u8, "demo");
    var native = a2a.AgentSkill{
        .id = try a.dupe(u8, "echo"),
        .name = try a.dupe(u8, "Echo"),
        .description = try a.dupe(u8, "Echoes input"),
        .tags = tags,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try agentSkillToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqualStrings("echo", proto.id);
    try testing.expectEqual(@as(usize, 1), proto.tags.items.len);

    var back = try agentSkillFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("echo", back.id);
    try testing.expectEqual(@as(usize, 1), back.tags.len);
    try testing.expectEqualStrings("demo", back.tags[0]);
}

test "security requirement round-trips with scopes" {
    const a = testing.allocator;
    var req: a2a.SecurityRequirement = .{ .allocator = a };
    defer req.deinit();
    const scopes = try a.alloc([]const u8, 2);
    scopes[0] = try a.dupe(u8, "read");
    scopes[1] = try a.dupe(u8, "write");
    try req.entries.put(a, try a.dupe(u8, "bearer"), scopes);

    var proto = try securityRequirementToProto(a, req);
    defer proto.deinit(a);
    try testing.expectEqual(@as(usize, 1), proto.schemes.items.len);
    try testing.expectEqualStrings("bearer", proto.schemes.items[0].key);
    try testing.expectEqual(@as(usize, 2), proto.schemes.items[0].value.?.list.items.len);

    var back = try securityRequirementFromProto(a, proto);
    defer back.deinit();
    const back_scopes = back.entries.get("bearer").?;
    try testing.expectEqual(@as(usize, 2), back_scopes.len);
    try testing.expectEqualStrings("read", back_scopes[0]);
    try testing.expectEqualStrings("write", back_scopes[1]);
}

test "api key security scheme round-trips" {
    const a = testing.allocator;
    var native = a2a.ApiKeySecurityScheme{
        .location = try a.dupe(u8, "header"),
        .name = try a.dupe(u8, "X-API-Key"),
        .description = try a.dupe(u8, "use this to auth"),
        .allocator = a,
    };
    defer native.deinit();
    var proto = try apiKeySecuritySchemeToProto(a, native);
    defer proto.deinit(a);
    var back = try apiKeySecuritySchemeFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("header", back.location);
    try testing.expectEqualStrings("X-API-Key", back.name);
    try testing.expectEqualStrings("use this to auth", back.description.?);
}

test "http auth security scheme round-trips" {
    const a = testing.allocator;
    var native = a2a.HttpAuthSecurityScheme{
        .scheme = try a.dupe(u8, "Bearer"),
        .bearer_format = try a.dupe(u8, "JWT"),
        .allocator = a,
    };
    defer native.deinit();
    var proto = try httpAuthSecuritySchemeToProto(a, native);
    defer proto.deinit(a);
    var back = try httpAuthSecuritySchemeFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("Bearer", back.scheme);
    try testing.expectEqualStrings("JWT", back.bearer_format.?);
}

test "openid connect security scheme round-trips" {
    const a = testing.allocator;
    var native = a2a.OpenIdConnectSecurityScheme{
        .open_id_connect_url = try a.dupe(u8, "https://example.com/.well-known/openid-configuration"),
        .allocator = a,
    };
    defer native.deinit();
    var proto = try openIdConnectSecuritySchemeToProto(a, native);
    defer proto.deinit(a);
    var back = try openIdConnectSecuritySchemeFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("https://example.com/.well-known/openid-configuration", back.open_id_connect_url);
}

test "mtls security scheme round-trips" {
    const a = testing.allocator;
    var native = a2a.MutualTlsSecurityScheme{
        .description = try a.dupe(u8, "client cert required"),
        .allocator = a,
    };
    defer native.deinit();
    var proto = try mutualTlsSecuritySchemeToProto(a, native);
    defer proto.deinit(a);
    var back = try mutualTlsSecuritySchemeFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("client cert required", back.description.?);
}

test "client credentials oauth flow round-trips with scopes" {
    const a = testing.allocator;
    var scopes: a2a.agent_card.StringMap = .{ .allocator = a };
    try scopes.entries.put(a, try a.dupe(u8, "read"), try a.dupe(u8, "Read access"));

    var native = a2a.agent_card.ClientCredentialsOAuthFlow{
        .token_url = try a.dupe(u8, "https://auth.example.com/token"),
        .scopes = scopes,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try clientCredentialsOAuthFlowToProto(a, native);
    defer proto.deinit(a);
    try testing.expectEqual(@as(usize, 1), proto.scopes.items.len);

    var back = try clientCredentialsOAuthFlowFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("Read access", back.scopes.entries.get("read").?);
}

test "oauth2 scheme with client credentials flow round-trips" {
    const a = testing.allocator;
    var scopes: a2a.agent_card.StringMap = .{ .allocator = a };
    try scopes.entries.put(a, try a.dupe(u8, "write"), try a.dupe(u8, "Write access"));

    var native = a2a.OAuth2SecurityScheme{
        .flows = .{ .client_credentials = .{
            .token_url = try a.dupe(u8, "https://auth.example.com/token"),
            .scopes = scopes,
            .allocator = a,
        } },
        .allocator = a,
    };
    defer native.deinit();

    var proto = try oauth2SecuritySchemeToProto(a, native);
    defer proto.deinit(a);

    var back = try oauth2SecuritySchemeFromProto(a, proto);
    defer back.deinit();
    try testing.expect(back.flows == .client_credentials);
    try testing.expectEqualStrings("Write access", back.flows.client_credentials.scopes.entries.get("write").?);
}

test "security scheme union round-trips api key" {
    const a = testing.allocator;
    var native = a2a.SecurityScheme{
        .api_key = .{
            .location = try a.dupe(u8, "header"),
            .name = try a.dupe(u8, "X-API-Key"),
            .allocator = a,
        },
    };
    defer native.deinit();
    var proto = try securitySchemeToProto(a, native);
    defer proto.deinit(a);
    var back = try securitySchemeFromProto(a, proto);
    defer back.deinit();
    try testing.expect(back == .api_key);
    try testing.expectEqualStrings("X-API-Key", back.api_key.name);
}

test "agent card minimal round-trips" {
    const a = testing.allocator;
    const ifaces = try a.alloc(a2a.AgentInterface, 1);
    ifaces[0] = try a2a.AgentInterface.init(a, "http://localhost:3000", "JSONRPC");

    const skills = try a.alloc(a2a.AgentSkill, 0);
    const input_modes = try a.alloc([]const u8, 1);
    input_modes[0] = try a.dupe(u8, "text/plain");
    const output_modes = try a.alloc([]const u8, 1);
    output_modes[0] = try a.dupe(u8, "text/plain");

    var native = a2a.AgentCard{
        .name = try a.dupe(u8, "Test Agent"),
        .description = try a.dupe(u8, "A test agent"),
        .version = try a.dupe(u8, "1.0.0"),
        .supported_interfaces = ifaces,
        .capabilities = .{ .streaming = true, .allocator = a },
        .default_input_modes = input_modes,
        .default_output_modes = output_modes,
        .skills = skills,
        .allocator = a,
    };
    defer native.deinit();

    var proto = try agentCardToProto(a, native);
    defer proto.deinit(a);

    var back = try agentCardFromProto(a, proto);
    defer back.deinit();
    try testing.expectEqualStrings("Test Agent", back.name);
    try testing.expectEqual(@as(?bool, true), back.capabilities.streaming);
    try testing.expectEqual(@as(usize, 1), back.supported_interfaces.len);
    try testing.expectEqualStrings("JSONRPC", back.supported_interfaces[0].protocol_binding);
}

test "task wire round-trip via protobuf bytes" {
    const a = testing.allocator;
    var task = a2a.Task{
        .id = try a.dupe(u8, "t-wire"),
        .context_id = try a.dupe(u8, "c-wire"),
        .status = .{ .state = .completed, .allocator = a },
        .allocator = a,
    };
    defer task.deinit();

    var proto = try taskToProto(a, task);
    defer proto.deinit(a);

    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    try proto.encode(&encoded.writer, a);

    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try v1.Task.decode(&reader, a);
    defer decoded.deinit(a);

    var back = try taskFromProto(a, decoded);
    defer back.deinit();
    try testing.expectEqualStrings("t-wire", back.id);
    try testing.expectEqualStrings("c-wire", back.context_id);
    try testing.expectEqual(a2a.TaskState.completed, back.status.state);
}
