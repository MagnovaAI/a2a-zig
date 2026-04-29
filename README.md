# a2a-zig

A Zig implementation of the A2A (Agent2Agent) v1 protocol.

## Status

Phase 1 (HTTP + JSON-RPC + REST + SSE) — in progress.

## Layout

```
src/
  a2a/      core protocol types, errors, JSON-RPC envelope, agent card
  client/   transport-agnostic client + JSON-RPC + REST bindings
  server/   handler, JSON-RPC + REST + SSE servers, task/push stores
  cli/      command-line client
examples/
  helloworld/
```

## Build

```sh
zig build           # build CLI + example
zig build test      # run all unit tests
zig build run -- --help
```

Requires Zig 0.16.0.

## Protocol version

A2A v1.0
