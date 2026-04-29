//! Protobuf-backed wire types and ProtoJSON conversion for A2A.
//!
//! `gen/` holds the protobuf bindings produced by `zig build gen-proto` from
//! `proto/a2a.proto`. Each generated message exposes `encode`/`decode` for
//! the wire protocol and `jsonEncode`/`jsonDecode` for the canonical
//! ProtoJSON form. The conversion layer between these types and our native
//! ones in `src/a2a/` lives in `pbconv.zig` (forthcoming).
const std = @import("std");

pub const protobuf = @import("protobuf");
pub const v1 = @import("gen/lf/a2a/v1.pb.zig");
pub const google_api = @import("gen/google/api.pb.zig");
pub const google_protobuf = @import("gen/google/protobuf.pb.zig");
pub const conv = @import("pbconv.zig");

const testing = std.testing;

test "generated TaskState matches the wire enum" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(v1.TaskState.TASK_STATE_UNSPECIFIED));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(v1.TaskState.TASK_STATE_COMPLETED));
}

test "generated Role matches the wire enum" {
    try testing.expectEqual(@as(i32, 0), @intFromEnum(v1.Role.ROLE_UNSPECIFIED));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(v1.Role.ROLE_AGENT));
}

test {
    _ = conv;
}

test "round-trip a SendMessageConfiguration via protobuf wire" {
    const a = testing.allocator;
    var cfg = v1.SendMessageConfiguration{
        .history_length = 7,
        .return_immediately = true,
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    try cfg.encode(&encoded.writer, a);

    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try v1.SendMessageConfiguration.decode(&reader, a);
    defer decoded.deinit(a);
    try testing.expectEqual(@as(?i32, 7), decoded.history_length);
    try testing.expectEqual(true, decoded.return_immediately);
}
