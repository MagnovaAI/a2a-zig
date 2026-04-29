//! Webhook delivery for push notifications.
//!
//! Wraps an HTTP client and posts JSON-encoded `StreamResponse` events to
//! the URL recorded in a `PushNotificationConfig`. Authentication and
//! notification-token headers are derived from the config. Failures are
//! either ignored (default — logged and execution continues) or surfaced
//! as errors that abort the in-flight execution, controlled by
//! `Config.fail_on_error`.
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");

const log = std.log.scoped(.a2a_server);

/// Tunables for `HttpPushSender`.
pub const Config = struct {
    /// Total request timeout. Default 30 seconds.
    timeout_ms: u64 = 30_000,
    /// When true, a delivery failure aborts the task execution that produced
    /// the event. When false, failures are logged and execution continues.
    fail_on_error: bool = false,
};

/// HTTP push sender. Owns a long-lived `std.http.Client`; call `deinit` when
/// you're done with it.
pub const HttpPushSender = struct {
    pub const Error = error{
        OutOfMemory,
        DeliveryFailed,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) HttpPushSender {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .config = config,
        };
    }

    pub fn deinit(self: *HttpPushSender) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Deliver `event` to `cfg.url`. The event is serialized as canonical
    /// ProtoJSON. `Authorization` and `A2A-Notification-Token` headers are
    /// added when the config requests them.
    pub fn send(
        self: *HttpPushSender,
        cfg: *const a2a.PushNotificationConfig,
        event: a2a.StreamResponse,
    ) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const body = encodeEvent(aa, event) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return self.handleError("failed to serialize event"),
        };

        const headers = self.buildHeaders(aa, cfg) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };

        const result = self.client.fetch(.{
            .location = .{ .url = cfg.url },
            .method = .POST,
            .extra_headers = headers,
            .payload = body,
            .response_writer = null,
        }) catch return self.handleError("request failed");

        const status: u16 = @intFromEnum(result.status);
        if (status < 200 or status >= 300) {
            return self.handleError("non-2xx status from push endpoint");
        }
    }

    fn handleError(self: *HttpPushSender, msg: []const u8) Error!void {
        if (self.config.fail_on_error) {
            log.warn("push delivery: {s}", .{msg});
            return Error.DeliveryFailed;
        }
        log.debug("push delivery (ignored): {s}", .{msg});
    }

    fn buildHeaders(
        self: *HttpPushSender,
        arena: std.mem.Allocator,
        cfg: *const a2a.PushNotificationConfig,
    ) ![]std.http.Header {
        _ = self;
        var n: usize = 1; // Content-Type
        if (cfg.token) |_| n += 1;
        if (cfg.authentication) |auth| {
            if (auth.credentials) |_| {
                if (isBearer(auth.scheme) or isBasic(auth.scheme)) n += 1;
            }
        }

        const out = try arena.alloc(std.http.Header, n);
        var idx: usize = 0;
        out[idx] = .{ .name = "Content-Type", .value = "application/json" };
        idx += 1;
        if (cfg.token) |tok| {
            out[idx] = .{ .name = "A2A-Notification-Token", .value = tok };
            idx += 1;
        }
        if (cfg.authentication) |auth| {
            if (auth.credentials) |creds| {
                if (isBearer(auth.scheme)) {
                    out[idx] = .{
                        .name = "Authorization",
                        .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{creds}),
                    };
                    idx += 1;
                } else if (isBasic(auth.scheme)) {
                    out[idx] = .{
                        .name = "Authorization",
                        .value = try std.fmt.allocPrint(arena, "Basic {s}", .{creds}),
                    };
                    idx += 1;
                }
            }
        }
        return out[0..idx];
    }
};

fn isBearer(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "bearer");
}

fn isBasic(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "basic");
}

/// Encode a StreamResponse to its canonical JSON representation through the
/// generated proto types so the wire format matches REST/JSON-RPC bodies.
fn encodeEvent(arena: std.mem.Allocator, event: a2a.StreamResponse) ![]const u8 {
    var pb_event = try pb.conv.streamResponseToProto(arena, event);
    defer pb_event.deinit(arena);
    return try pb_event.jsonEncode(.{}, .{}, arena);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "default config" {
    const c: Config = .{};
    try testing.expectEqual(@as(u64, 30_000), c.timeout_ms);
    try testing.expect(!c.fail_on_error);
}

test "scheme classifiers are case-insensitive" {
    try testing.expect(isBearer("bearer"));
    try testing.expect(isBearer("BEARER"));
    try testing.expect(isBearer("Bearer"));
    try testing.expect(!isBearer("basic"));
    try testing.expect(isBasic("Basic"));
    try testing.expect(!isBasic("digest"));
}

test "encodeEvent produces canonical proto-json" {
    const a = testing.allocator;
    var status_event: a2a.StreamResponse = .{
        .status_update = .{
            .task_id = try a.dupe(u8, "t1"),
            .context_id = try a.dupe(u8, "c1"),
            .status = .{ .state = .working, .allocator = a },
            .allocator = a,
        },
    };
    defer status_event.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const json = try encodeEvent(arena.allocator(), status_event);
    try testing.expect(std.mem.indexOf(u8, json, "statusUpdate") != null);
}

test "config controls error propagation policy" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var soft = HttpPushSender.init(a, io, .{ .fail_on_error = false });
    defer soft.deinit();
    var hard = HttpPushSender.init(a, io, .{ .fail_on_error = true });
    defer hard.deinit();
    try testing.expect(!soft.config.fail_on_error);
    try testing.expect(hard.config.fail_on_error);
}
