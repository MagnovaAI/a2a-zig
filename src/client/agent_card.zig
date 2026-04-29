//! Agent card resolver. Fetches `.well-known/agent-card.json` from a base URL
//! and parses it into an `AgentCard`.
const std = @import("std");
const a2a = @import("a2a");

const log = std.log.scoped(.a2a_client);

pub const ResolveError = error{
    OutOfMemory,
    UnsupportedUriScheme,
    InvalidUri,
    HttpRequestFailed,
    HttpStatusError,
    ResponseTooLarge,
    InvalidResponse,
    UnexpectedToken,
    MissingField,
};

/// Resolves agent cards from `.well-known/agent-card.json` endpoints.
///
/// The resolver owns an `std.http.Client`. Construct with `init`, drive with
/// `resolve`, tear down with `deinit`. Not thread-safe; create one resolver
/// per concurrent caller.
pub const AgentCardResolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    /// Hard cap on the response body size (default 1 MiB). Bodies larger than
    /// this fail with `ResponseTooLarge` rather than being silently truncated.
    max_response_bytes: usize = 1 * 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AgentCardResolver {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *AgentCardResolver) void {
        self.client.deinit();
        self.* = undefined;
    }

    /// Fetch and parse the agent card at `{base_url}/.well-known/agent-card.json`.
    ///
    /// Returned card is owned by `allocator`; caller must `deinit` it.
    pub fn resolve(
        self: *AgentCardResolver,
        allocator: std.mem.Allocator,
        base_url: []const u8,
    ) ResolveError!a2a.AgentCard {
        const trimmed = std.mem.trimEnd(u8, base_url, "/");
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/.well-known/agent-card.json",
            .{trimmed},
        );
        defer allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
            .keep_alive = false,
        }) catch |err| {
            log.err("agent card fetch failed: url={s} err={s}", .{ url, @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedUriScheme => error.UnsupportedUriScheme,
                error.InvalidUri => error.InvalidUri,
                else => error.HttpRequestFailed,
            };
        };

        if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
            log.err("agent card fetch returned HTTP {d}: {s}", .{ @intFromEnum(result.status), url });
            return error.HttpStatusError;
        }

        const bytes = body.written();
        if (bytes.len > self.max_response_bytes) {
            log.err("agent card response exceeds {d} bytes: {d}", .{ self.max_response_bytes, bytes.len });
            return error.ResponseTooLarge;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
            log.err("agent card JSON parse failed: {s}", .{@errorName(err)});
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        return a2a.AgentCard.jsonParseFromValue(allocator, parsed.value, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnexpectedToken => error.UnexpectedToken,
            error.MissingField => error.MissingField,
            else => error.InvalidResponse,
        };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const builtin = @import("builtin");
const testing = std.testing;

test "trims trailing slash from base url" {
    // We can't drive the real client without a server, so this just exercises
    // the URL building logic via a parse round-trip.
    const a = testing.allocator;
    const trimmed = std.mem.trimEnd(u8, "http://localhost:3000/", "/");
    const url = try std.fmt.allocPrint(a, "{s}/.well-known/agent-card.json", .{trimmed});
    defer a.free(url);
    try testing.expectEqualStrings("http://localhost:3000/.well-known/agent-card.json", url);
}

test "init/deinit owns its http client" {
    if (builtin.is_test and !builtin.os.tag.isDarwin() and !builtin.os.tag.isBSD() and builtin.os.tag != .linux) return;
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var r = AgentCardResolver.init(a, io);
    defer r.deinit();
    try testing.expect(r.max_response_bytes > 0);
}
