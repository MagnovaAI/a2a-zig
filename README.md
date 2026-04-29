# a2a-zig

A Zig 0.16 SDK for the [A2A v1 protocol](https://github.com/a2aproject) — talk to other agents and expose your own agent over JSON-RPC, REST, and Server-Sent Events.

Ships both a **client** and a **server** in one library:

- Client: REST and JSON-RPC transports, auth interceptor chain, agent-card resolver, streaming subscriptions.
- Server: pluggable executor, in-memory task store, push-notification subsystem, JSON-RPC and REST bindings, SSE writer, agent-card endpoint, TLS-config loader.

## Status

`v0.1.0` — feature-complete first cut. 240+ unit tests, end-to-end demo runs. See `CHANGELOG.md` for details and known caveats.

## Requirements

- Zig **0.16.0** (exact — the codebase uses 0.16-only stdlib APIs).

## Add it to your project

```zig
// build.zig.zon
.dependencies = .{
    .a2a_zig = .{
        .url = "https://github.com/MagnovaAI/a2a-zig/archive/refs/tags/v0.1.0.tar.gz",
        // .hash = "...",  // run `zig fetch` to populate
    },
},
```

```zig
// build.zig
const a2a_dep = b.dependency("a2a_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("a2a", a2a_dep.module("a2a"));
exe.root_module.addImport("a2a_client", a2a_dep.module("a2a_client"));
exe.root_module.addImport("a2a_server", a2a_dep.module("a2a_server"));
```

The three modules are independent — pull only what you need.

## Run the demo

```sh
zig build
./zig-out/bin/helloworld
```

Output:

```
a2a-zig helloworld — protocol v1.0
server: starting on http://127.0.0.1:18181
client: sending message…
client: got Task id=demo-task-1 state=completed
client: getTask round-trip id=demo-task-1 state=completed
done.
```

The demo (`examples/helloworld/main.zig`) spins up a server with an echo executor on a background thread, runs a client against it, and exercises the full request path: REST transport → HTTP → REST handler → `DefaultRequestHandler` → executor → task store → response back through the wire.

## Quick tour

### Client — call another agent

```zig
const a2a = @import("a2a");
const a2a_client = @import("a2a_client");

var rest = try a2a_client.RestTransport.init(allocator, io, "https://agent.example.com");
const transport = rest.transport();
defer transport.destroy();

var client = try a2a_client.A2AClient.init(allocator, transport);
defer client.deinit();

const parts = try allocator.alloc(a2a.Part, 1);
parts[0] = try a2a.Part.text(allocator, "hello, agent");
var msg = try a2a.Message.init(allocator, .user, parts);
const req: a2a.SendMessageRequest = .{ .message = msg, .allocator = allocator };

var resp = try client.sendMessage(allocator, &req);
defer resp.deinit();
```

### Server — expose your agent

```zig
const a2a = @import("a2a");
const a2a_server = @import("a2a_server");

var task_store = a2a_server.task_store.inmemory.InMemoryTaskStore.init(allocator, io);
defer task_store.deinit();

var executor: MyExecutor = .{};

var handler = a2a_server.DefaultRequestHandler.init(
    allocator, io, executor.executor(), task_store.store(),
);
defer handler.deinit();

var card = a2a_server.StaticAgentCard.init(allocator, my_agent_card);
defer card.deinit();

var srv = try a2a_server.Server.init(allocator, io, .{
    .bind = .{ .port = 8080 },
    .request_handler = handler.handler(),
    .agent_card_producer = card.producer(),
});
defer srv.deinit();
try srv.start();  // or srv.startInThread()
```

Implement an executor by satisfying the `AgentExecutor` vtable (`execute`, `cancel`) — see `examples/helloworld/main.zig` for a minimal echo implementation.

## Layout

```
src/
  a2a/        Protocol types (errors, JSON-RPC envelope, AgentCard, events, Task, Message, …)
  client/     Transports (REST, JSON-RPC), auth, middleware, AgentCard resolver, A2AClient
  server/     Handler, executor, task store, push, JSON-RPC, REST, SSE, TLS config, Server facade
  pb/         Generated protobuf bindings + native↔proto conversion
  cli/        Tiny CLI binary
lib/
  sysclock/   Monotonic clock helpers (Zig 0.16 dropped std.time.milliTimestamp)
  sse/        Server-Sent Events parser (used client-side)
  broadcast/  Single-producer multi-consumer event channel
proto/        Vendored a2a.proto (protocol-version source of truth)
examples/     End-to-end demos
```

## Tests

```sh
zig build test
```

240+ tests across protocol, conversion, foundations, and both SDKs. Run `zig build lint` to lint the project (requires `ziglint` on PATH).

## Caveats for v0.1.0

- **TLS is config-only.** `httpz` doesn't ship native TLS; `tls.zig` exposes a loader for `ianic/tls.zig` you can wire into a custom accept loop. Production deployments should terminate TLS at a reverse proxy.
- **Streaming has unit tests but no end-to-end integration test yet.**
- The wire format is canonical proto-JSON for REST and JSON-RPC bodies — match this on both sides.

## License

Apache-2.0 — see `LICENSE`.
