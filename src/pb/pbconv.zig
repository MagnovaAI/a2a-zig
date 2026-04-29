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
