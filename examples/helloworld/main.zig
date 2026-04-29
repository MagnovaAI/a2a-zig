//! End-to-end A2A demo: spins up a server with an echo executor in a
//! background thread, then runs a client that sends one message and
//! prints the response. Exercises the full request path:
//!
//!   client.sendMessage  →  REST transport over HTTP
//!     →  REST handler  →  DefaultRequestHandler
//!     →  EchoExecutor   →  TaskStore  →  response back through the wire.
const std = @import("std");
const a2a = @import("a2a");
const a2a_client = @import("a2a_client");
const a2a_server = @import("a2a_server");

const PORT: u16 = 18181;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const a = dbg.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const w = &stdout.interface;

    try w.print("a2a-zig helloworld — protocol v{s}\n", .{a2a.VERSION});

    // ---- Server side ----
    var task_store_state = a2a_server.task_store.inmemory.InMemoryTaskStore.init(a, io);
    defer task_store_state.deinit();

    var echo: EchoExecutor = .{};
    const executor = echo.executor();

    var handler_state = a2a_server.DefaultRequestHandler.init(a, io, executor, task_store_state.store());
    defer handler_state.deinit();

    var card = try buildAgentCard(a);
    var sac = a2a_server.StaticAgentCard.init(a, card);
    defer sac.deinit();
    _ = &card;

    var srv = try a2a_server.Server.init(a, io, .{
        .bind = .{ .port = PORT },
        .request_handler = handler_state.handler(),
        .agent_card_producer = sac.producer(),
    });
    defer srv.deinit();

    try w.print("server: starting on http://127.0.0.1:{d}\n", .{PORT});
    try w.flush();
    const server_thread = try srv.startInThread();

    // Give the listener a moment to bind.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .real) catch {};

    // ---- Client side ----
    var base_url_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_url_buf, "http://127.0.0.1:{d}", .{PORT});
    var rest_transport = try a2a_client.RestTransport.init(a, io, base_url);
    const transport = rest_transport.transport();
    defer transport.destroy();

    var client = try a2a_client.A2AClient.init(a, transport);
    defer client.deinit();

    // Build a message and call sendMessage.
    const parts = try a.alloc(a2a.Part, 1);
    parts[0] = try a2a.Part.text(a, "hello, A2A");
    var msg = try a2a.Message.init(a, .user, parts);
    msg.task_id = try a.dupe(u8, "demo-task-1");
    var req: a2a.SendMessageRequest = .{ .message = msg, .allocator = a };
    defer req.deinit();

    try w.print("client: sending message…\n", .{});
    try w.flush();
    var resp = client.sendMessage(a, &req) catch |err| {
        try w.print("client: sendMessage failed: {s}\n", .{@errorName(err)});
        try w.flush();
        return err;
    };
    defer resp.deinit();

    switch (resp) {
        .task => |task| try w.print(
            "client: got Task id={s} state={s}\n",
            .{ task.id, @tagName(task.status.state) },
        ),
        .message => |m| try w.print(
            "client: got Message text={s}\n",
            .{m.text() orelse "(empty)"},
        ),
    }
    try w.flush();

    // Round-trip: ask for the same task back via getTask.
    var get_req: a2a.GetTaskRequest = .{
        .id = try a.dupe(u8, "demo-task-1"),
        .allocator = a,
    };
    defer get_req.deinit();
    var got = try client.getTask(a, &get_req);
    defer got.deinit();
    try w.print("client: getTask round-trip id={s} state={s}\n", .{ got.id, @tagName(got.status.state) });
    try w.flush();

    try w.print("done.\n", .{});
    try w.flush();

    // Detach the listener thread; the process exits and cleans up.
    server_thread.detach();
}

// ---------------------------------------------------------------------------
// Echo executor: emits a single completed-task event mirroring the inbound
// message.
// ---------------------------------------------------------------------------

const EchoExecutor = struct {
    fn execute(
        _: *anyopaque,
        request_allocator: std.mem.Allocator,
        ctx: *a2a_server.executor.ExecutorContext,
    ) a2a_server.executor.AgentExecutor.Error!a2a.StreamIterator {
        return makeOnce(request_allocator, ctx, .completed);
    }

    fn cancel(
        _: *anyopaque,
        request_allocator: std.mem.Allocator,
        ctx: *a2a_server.executor.ExecutorContext,
    ) a2a_server.executor.AgentExecutor.Error!a2a.StreamIterator {
        return makeOnce(request_allocator, ctx, .canceled);
    }

    const vtable: a2a_server.executor.AgentExecutor.VTable = .{ .execute = execute, .cancel = cancel };

    fn executor(self: *EchoExecutor) a2a_server.executor.AgentExecutor {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

const OnceIterator = struct {
    allocator: std.mem.Allocator,
    payload: ?a2a.StreamResponse,

    fn next(ctx: *anyopaque) a2a.StreamIterator.NextError!?a2a.StreamResponse {
        const self: *OnceIterator = @ptrCast(@alignCast(ctx));
        if (self.payload) |p| {
            self.payload = null;
            return p;
        }
        return null;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *OnceIterator = @ptrCast(@alignCast(ctx));
        if (self.payload) |*p| p.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    const vtable: a2a.StreamIterator.VTable = .{ .next = next, .deinit = deinit };
};

fn makeOnce(
    allocator: std.mem.Allocator,
    ctx: *a2a_server.executor.ExecutorContext,
    final_state: a2a.TaskState,
) !a2a.StreamIterator {
    const it = try allocator.create(OnceIterator);
    const task: a2a.Task = .{
        .id = try allocator.dupe(u8, ctx.task_id),
        .context_id = try allocator.dupe(u8, ctx.context_id),
        .status = .{ .state = final_state, .allocator = allocator },
        .allocator = allocator,
    };
    it.* = .{ .allocator = allocator, .payload = .{ .task = task } };
    return .{ .ctx = @ptrCast(it), .vtable = &OnceIterator.vtable };
}

// ---------------------------------------------------------------------------
// Agent card stub
// ---------------------------------------------------------------------------

fn buildAgentCard(allocator: std.mem.Allocator) !a2a.AgentCard {
    return .{
        .name = try allocator.dupe(u8, "HelloWorldAgent"),
        .description = try allocator.dupe(u8, "An echo agent shipped with the SDK examples"),
        .version = try allocator.dupe(u8, "0.1.0"),
        .supported_interfaces = try allocator.alloc(a2a.AgentInterface, 0),
        .capabilities = a2a.AgentCapabilities.default(allocator),
        .default_input_modes = try allocator.alloc([]const u8, 0),
        .default_output_modes = try allocator.alloc([]const u8, 0),
        .skills = try allocator.alloc(a2a.AgentSkill, 0),
        .allocator = allocator,
    };
}
