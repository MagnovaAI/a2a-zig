//! Top-level A2A server facade.
//!
//! Bundles the request handler, REST, JSON-RPC, agent-card, and (optional)
//! TLS configuration into a single `Server` that wires everything onto
//! httpz routes. Most users won't need to touch the lower-level binding
//! modules directly.
//!
//! Usage:
//! ```
//! var srv = try a2a_server.Server.init(allocator, io, .{
//!     .listen_address = .{ .ipv4 = .{ .host = "127.0.0.1", .port = 8080 } },
//!     .request_handler = handler.handler(),
//!     .agent_card_producer = sac.producer(),
//! });
//! defer srv.deinit();
//! try srv.start();
//! ```
const std = @import("std");
const httpz = @import("httpz");

const a2a = @import("a2a");
const handler_mod = @import("handler.zig");
const agent_card_mod = @import("agent_card.zig");
const jsonrpc_mod = @import("jsonrpc.zig");
const rest_mod = @import("rest.zig");

const log = std.log.scoped(.a2a_server);

const RequestHandler = handler_mod.RequestHandler;
const AgentCardProducer = agent_card_mod.AgentCardProducer;

pub const Bind = struct {
    /// IPv4 address octets. Defaults to 127.0.0.1.
    host: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 8080,

    /// Bind to all interfaces on the given port.
    pub fn allInterfaces(port: u16) Bind {
        return .{ .host = .{ 0, 0, 0, 0 }, .port = port };
    }
};

pub const Mounts = struct {
    /// Path served as the public agent card. Defaults to the well-known path.
    agent_card_path: []const u8 = agent_card_mod.WELL_KNOWN_AGENT_CARD_PATH,
    /// Path that accepts JSON-RPC POST requests. Defaults to `/`.
    jsonrpc_path: []const u8 = "/",
    /// When true, REST endpoints (`/message:send`, `/tasks/{id}`, etc.) are
    /// also mounted alongside the JSON-RPC handler. Disable to expose only
    /// JSON-RPC.
    enable_rest: bool = true,
};

pub const Options = struct {
    bind: Bind = .{},
    mounts: Mounts = .{},
    request_handler: RequestHandler,
    agent_card_producer: AgentCardProducer,
    /// Workers and tunables forwarded to httpz unchanged.
    httpz: httpz.Config = .{},
};

/// Composite httpz handler: routes hit one of the bundled binding handlers
/// based on path. The dispatcher is built by `Server.init` and lives as long
/// as the server.
pub const Dispatch = struct {
    rpc: jsonrpc_mod.Handler,
    rest: rest_mod.Handler,
    card: agent_card_mod.Handler,
    mounts: Mounts,

    /// httpz dispatcher signature: `(handler, action, req, res)`. We
    /// ignore `action` because we mount a single catch-all route and
    /// route internally based on the path.
    pub fn dispatch(
        self: *Dispatch,
        _: httpz.Action(*Dispatch),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        if (std.mem.eql(u8, req.url.path, self.mounts.agent_card_path)) {
            return self.card.action(req, res);
        }
        if (self.mounts.enable_rest and isRestPath(req.url.path)) {
            return self.rest.action(req, res);
        }
        if (std.mem.eql(u8, req.url.path, self.mounts.jsonrpc_path) and req.method == .POST) {
            return self.rpc.action(req, res);
        }
        res.status = 404;
        res.body = "{\"error\":{\"code\":404,\"message\":\"not found\"}}";
        res.content_type = httpz.ContentType.JSON;
    }

    /// Placeholder action registered with the router. The real dispatch
    /// happens in `Dispatch.dispatch` above.
    fn passthrough(_: *Dispatch, _: *httpz.Request, _: *httpz.Response) !void {}

    fn isRestPath(path: []const u8) bool {
        return std.mem.eql(u8, path, "/message:send") or
            std.mem.eql(u8, path, "/message:stream") or
            std.mem.eql(u8, path, "/extendedAgentCard") or
            std.mem.eql(u8, path, "/tasks") or
            std.mem.startsWith(u8, path, "/tasks/");
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dispatch: *Dispatch,
    http: httpz.Server(*Dispatch),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        const dispatch = try allocator.create(Dispatch);
        errdefer allocator.destroy(dispatch);
        dispatch.* = .{
            .rpc = jsonrpc_mod.Handler.init(allocator, io, options.request_handler),
            .rest = rest_mod.Handler.init(allocator, io, options.request_handler),
            .card = .{ .producer = options.agent_card_producer },
            .mounts = options.mounts,
        };

        var http_cfg = options.httpz;
        http_cfg.address = .{ .ip = .{ .ip4 = .{ .bytes = options.bind.host, .port = options.bind.port } } };

        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dispatch = dispatch,
            .http = try httpz.Server(*Dispatch).init(io, allocator, http_cfg, dispatch),
        };

        var router = try self.http.router(.{});
        // Mount a single catch-all route that dispatches inside `Dispatch`.
        router.get("/*", Dispatch.passthrough, .{});
        router.post("/*", Dispatch.passthrough, .{});
        router.delete("/*", Dispatch.passthrough, .{});
        router.put("/*", Dispatch.passthrough, .{});

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.http.deinit();
        self.allocator.destroy(self.dispatch);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Block on the accept loop. Use `startInThread` if you need the call to return.
    pub fn start(self: *Server) !void {
        try self.http.listen();
    }

    /// Spawn a worker thread that runs `start`. Returns the thread handle so
    /// callers can `join` or `detach` it.
    pub fn startInThread(self: *Server) !std.Thread {
        return try self.http.listenInNewThread();
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Bind defaults to localhost:8080" {
    const b: Bind = .{};
    try testing.expectEqual(@as([4]u8, .{ 127, 0, 0, 1 }), b.host);
    try testing.expectEqual(@as(u16, 8080), b.port);
}

test "Bind.allInterfaces uses 0.0.0.0" {
    const b = Bind.allInterfaces(9090);
    try testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), b.host);
    try testing.expectEqual(@as(u16, 9090), b.port);
}

test "Mounts defaults expose agent card and JSON-RPC at root" {
    const m: Mounts = .{};
    try testing.expectEqualStrings("/.well-known/agent-card.json", m.agent_card_path);
    try testing.expectEqualStrings("/", m.jsonrpc_path);
    try testing.expect(m.enable_rest);
}

test "Dispatch.isRestPath recognizes documented paths" {
    try testing.expect(Dispatch.isRestPath("/message:send"));
    try testing.expect(Dispatch.isRestPath("/message:stream"));
    try testing.expect(Dispatch.isRestPath("/tasks"));
    try testing.expect(Dispatch.isRestPath("/tasks/abc"));
    try testing.expect(Dispatch.isRestPath("/tasks/abc/pushNotificationConfigs"));
    try testing.expect(!Dispatch.isRestPath("/"));
    try testing.expect(!Dispatch.isRestPath("/random"));
}
