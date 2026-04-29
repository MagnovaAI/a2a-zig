# Changelog

## v0.1.0 — 2026-04-29

First public release. A2A protocol SDK for Zig 0.16.

### Protocol types
- Full A2A v1 type system: `AgentCard`, `Task`, `Message`, `Part`, `Artifact`, `TaskStatus`, status/artifact stream events, and every request/response envelope.
- JSON-RPC 2.0 envelope (`JsonRpcRequest`, `JsonRpcResponse`, `JsonRpcId`, `JsonRpcError`) with the documented A2A method names and error codes.
- `A2AError` with HTTP status mapping and convenience constructors per spec error code.
- Forward-compatible `unknown` arms on every tagged union so future protocol additions round-trip.
- `StreamIterator` shared between client and server.

### Generated protobuf bindings
- Vendored `proto/a2a.proto`. `zig build gen-proto` regenerates `src/pb/gen/`.
- Native↔proto conversion layer (`pb.conv`) — round-trips every protocol type via canonical proto-JSON, used as the wire format on REST and JSON-RPC bodies.

### Foundations (`lib/`)
- `sysclock` — monotonic + realtime clocks via libc `clock_gettime` (Zig 0.16 dropped `std.time.milliTimestamp`).
- `sse` — Server-Sent Events parser used by the client.
- `broadcast` — single-producer multi-consumer event channel with deep-clone publish semantics.

### Client SDK (`a2a_client`)
- `RestTransport` and `JsonRpcTransport` over `std.http.Client`.
- `A2AClient` with chained `CallInterceptor` middleware (logging, auth).
- `InMemoryCredentialsStore` and `AuthInterceptor` for bearer-token, API-key, and basic auth.
- `AgentCardResolver` for fetching well-known agent cards.
- `A2AClientFactory` selects a transport based on agent-card interface declarations.
- `streaming.Cursor` drains SSE event streams from the server.

### Server SDK (`a2a_server`)
- `DefaultRequestHandler` orchestrates executor dispatch, task store persistence, push-notification fan-out, and broadcast subscriptions for streaming.
- `AgentExecutor` vtable for plugging in business logic (`execute`, `cancel`).
- `InMemoryTaskStore` thread-safe by default; `TaskStore` vtable for swapping in custom backends.
- Push notifications: `PushConfigStore` + `InMemoryPushConfigStore`, plus `HttpPushSender` for webhook delivery.
- JSON-RPC and REST bindings dispatch onto the request handler.
- `SSE` writer drains a `StreamIterator` over the wire.
- `StaticAgentCard` and `AgentCardProducer` serve `/.well-known/agent-card.json` with permissive CORS.
- `Server` facade composes everything onto httpz routes.
- `tls.Config` loads PEM cert/key files for `ianic/tls.zig`.

### Example
- `examples/helloworld/main.zig` boots a server with an echo executor in a background thread, runs a client against it, and prints the response. Exercises the full client→HTTP→server→executor path.

### Tests
- 240+ unit tests across protocol types, protobuf conversion, foundations, client transports, and every server module. All passing under Debug allocator with leak detection.

### Known caveats
- **TLS is config-only.** `httpz` doesn't ship native TLS support; `tls.zig` provides a loader for `ianic/tls.zig` that you can wire into a custom accept loop. Production deployments should terminate TLS at a reverse proxy and proxy plain HTTP to the A2A server.
- **Streaming has unit-level coverage but no end-to-end integration test.** Logic is in place across `broadcast` → `SSE` → handler worker thread, but client-pulls-from-real-server has only been smoke-tested.
- **httpz's listener thread leaks on shutdown when detached.** Detaching the server thread (as the helloworld example does) leaves a small allocation owned by the worker. Acceptable for demos; long-running deployments should `join` the thread.

### Dependencies (vendored under `zig-pkg/`)
- `alexrios/uuid` — UUIDv7
- `rockorager/zeit` — RFC 3339, ISO 8601, time zones
- `Arwalk/zig-protobuf` — protobuf codec + codegen
- `karlseguin/http.zig` — HTTP/1.1 server
- `ianic/tls.zig` — TLS 1.3 (config loader only)

### Compatibility
- Zig **0.16.0** exactly. The codebase uses 0.16-only stdlib APIs (`std.Io`, `std.Io.Mutex`, `std.array_list.Managed`, etc.) and will not compile on earlier or later toolchains without changes.
