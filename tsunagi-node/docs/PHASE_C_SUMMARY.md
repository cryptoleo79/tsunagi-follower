# TSUNAGI Node — Phase C Summary (Network Skeleton)

This document summarizes Phase C milestones for TSUNAGI Node (Zig-only, no networking yet).

## Policy / Scope
- Zig-only from the ground up (see: `../docs/ZIG_ONLY_POLICY.md` in repo root docs)
- Phase C does NOT implement sockets, CBOR decoding/encoding, crypto, or real peer discovery.
- Goal is to prove boundaries, message ownership, and deterministic behavior in-memory.

## C.1 — Network skeleton wiring
- Added core types and attachment boundaries:
  - Peer manager boundary (`net/peer_manager.zig`)
  - Handshake boundary (placeholder)
  - Mux boundary
  - Mini-protocol attachment points (ChainSync / BlockFetch)
- Output: compilation success and minimal initialization.

## C.2 — Protocol message harness
- Introduced shared protocol message types:
  - `net/protocol/message.zig` defines `Message` union and protocol enums.
- Mux gained the ability to accept messages (no-op routing at the time).
- ChainSync/BlockFetch attach and emit messages through Mux boundary.

## C.3 — In-memory queue + fake peer loop
- Implemented a tiny FIFO queue (`net/runtime/queue.zig`).
- Mux upgraded to a real in-memory inbox queue:
  - `send()` enqueues
  - `recv()` dequeues
- `main.zig` drains the queue deterministically and prints ordered events.

## C.4 — Protocol state machines
- Added minimal state machines to prevent invalid call order:
  - ChainSync: `idle -> intersect_sent -> request_next_sent`
  - BlockFetch: `idle -> range_requested`
- Errors:
  - `error.InvalidState` returned on invalid order (design-time guard)
- The scripted flow still runs deterministically.

## Current Behavior (End of Phase C.4)
Running:
- `zig build`
- `./zig-out/bin/tsunagi-node`

Produces a deterministic in-memory trace:
- ChainSync find_intersect
- ChainSync request_next
- BlockFetch request_range

## Next recommended steps
Phase D (still safe, incremental):
1) Add unit tests for the state machines and message ordering.
2) Introduce an abstract transport interface (still no sockets).
3) Only after tests + transport: implement TCP connect and handshake framing.

