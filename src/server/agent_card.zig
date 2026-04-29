//! Serves the agent's `AgentCard` at `/.well-known/agent-card.json`.
//!
//! The card is exposed publicly with permissive CORS so other agents and
//! tooling can discover the endpoint. Implementations can either ship a
//! single static card via `StaticAgentCard` or plug a custom
//! `AgentCardProducer` for cards that vary by request (multi-tenant
//! deployments, version-pinned skill catalogs, etc.).
const std = @import("std");
const a2a = @import("a2a");
const pb = @import("pb");
const httpz = @import("httpz");

const log = std.log.scoped(.a2a_server);

/// The well-known URL path for the public agent card.
pub const WELL_KNOWN_AGENT_CARD_PATH: []const u8 = "/.well-known/agent-card.json";

/// Vtable for producing an `AgentCard` for an inbound request.
///
/// Implementations return a freshly-allocated card; the handler frees it
/// after writing the response.
pub const AgentCardProducer = struct {
    pub const Error = error{
        OutOfMemory,
        ProducerFailed,
    };

    pub const VTable = struct {
        produce: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) Error!a2a.AgentCard,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn produce(
        self: *const AgentCardProducer,
        allocator: std.mem.Allocator,
    ) Error!a2a.AgentCard {
        return self.vtable.produce(self.ctx, allocator);
    }
};

/// A static agent card producer. Holds one canonical card built at startup
/// and clones it (via the protobuf round-trip) for every request.
pub const StaticAgentCard = struct {
    card: a2a.AgentCard,
    allocator: std.mem.Allocator,

    /// Take ownership of `card`. Caller must not free it; `deinit` will.
    pub fn init(allocator: std.mem.Allocator, card: a2a.AgentCard) StaticAgentCard {
        return .{ .card = card, .allocator = allocator };
    }

    pub fn deinit(self: *StaticAgentCard) void {
        self.card.deinit();
        self.* = undefined;
    }

    pub fn producer(self: *StaticAgentCard) AgentCardProducer {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn vtProduce(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) AgentCardProducer.Error!a2a.AgentCard {
        const self: *StaticAgentCard = @ptrCast(@alignCast(ctx));
        var pb_card = pb.conv.agentCardToProto(allocator, self.card) catch return AgentCardProducer.Error.OutOfMemory;
        defer pb_card.deinit(allocator);
        return pb.conv.agentCardFromProto(allocator, pb_card) catch AgentCardProducer.Error.ProducerFailed;
    }

    const vtable: AgentCardProducer.VTable = .{ .produce = vtProduce };
};

/// Wraps a producer with the bits httpz needs to dispatch a request.
///
/// Register `Handler.action` with httpz at `WELL_KNOWN_AGENT_CARD_PATH`.
pub const Handler = struct {
    producer: AgentCardProducer,

    pub fn action(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        try writeCorsHeaders(req, res);

        var card = self.producer.produce(res.arena) catch |err| {
            log.err("agent card producer failed: {s}", .{@errorName(err)});
            res.status = 500;
            return;
        };
        defer card.deinit();

        var pb_card = pb.conv.agentCardToProto(res.arena, card) catch {
            res.status = 500;
            return;
        };
        defer pb_card.deinit(res.arena);
        const json = pb_card.jsonEncode(.{}, .{}, res.arena) catch {
            res.status = 500;
            return;
        };
        res.status = 200;
        res.content_type = httpz.ContentType.JSON;
        res.body = json;
    }
};

fn writeCorsHeaders(req: *httpz.Request, res: *httpz.Response) !void {
    if (req.header("origin")) |origin| {
        res.header("access-control-allow-origin", origin);
        res.header("access-control-allow-credentials", "true");
        res.header("vary", "Origin");
    } else {
        res.header("access-control-allow-origin", "*");
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeMinimalCard(allocator: std.mem.Allocator) !a2a.AgentCard {
    return .{
        .name = try allocator.dupe(u8, "TestAgent"),
        .description = try allocator.dupe(u8, "A test agent"),
        .version = try allocator.dupe(u8, "1.0"),
        .supported_interfaces = try allocator.alloc(a2a.AgentInterface, 0),
        .capabilities = a2a.AgentCapabilities.default(allocator),
        .default_input_modes = try allocator.alloc([]const u8, 0),
        .default_output_modes = try allocator.alloc([]const u8, 0),
        .skills = try allocator.alloc(a2a.AgentSkill, 0),
        .allocator = allocator,
    };
}

test "well-known path matches the spec" {
    try testing.expectEqualStrings("/.well-known/agent-card.json", WELL_KNOWN_AGENT_CARD_PATH);
}

test "static producer round-trips a card" {
    const a = testing.allocator;
    var sac = StaticAgentCard.init(a, try makeMinimalCard(a));
    defer sac.deinit();

    const p = sac.producer();
    var produced = try p.produce(a);
    defer produced.deinit();
    try testing.expectEqualStrings("TestAgent", produced.name);
    try testing.expectEqualStrings("1.0", produced.version);
}

test "static producer hands out independent clones" {
    const a = testing.allocator;
    var sac = StaticAgentCard.init(a, try makeMinimalCard(a));
    defer sac.deinit();
    const p = sac.producer();

    var first = try p.produce(a);
    defer first.deinit();
    var second = try p.produce(a);
    defer second.deinit();

    // Distinct backing memory.
    try testing.expect(first.name.ptr != second.name.ptr);
}
