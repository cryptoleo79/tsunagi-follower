# Tsunagi Follower (preview)

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/cryptoleo79/tsunagi-follower)


A minimal Cardano **node-to-node ChainSync** client that:
- performs the node-to-node handshake (v14),
- sends `MsgFindIntersect`,
- then continuously follows the chain via `MsgRequestNext`,
- with strict framing/validation and safe shutdown.

This is intentionally small and diagnostic: it logs mux framing, validates ChainSync message tags, and ignores non‑ChainSync mini‑protocol frames.

## What it implements

- **Cardano node-to-node mini‑protocol mux** framing
- **Handshake** mini‑protocol (0), version 14
- **ChainSync** mini‑protocol (2)

## How to run

```bash
zig run src/main.zig -- preview-node.world.dev.cardano.org 30002
```

You can pass a host/port as arguments. Defaults are:
- host: `preview-node.world.dev.cardano.org`
- port: `30002`

## Quickstart

Build:
```bash
zig build
```

Run (preview network):
```bash
zig run src/main.zig -- preview-node.world.dev.cardano.org 30002
```

Note: this is a diagnostic ChainSync follower for learning and debugging, not a full Cardano node.

## Key design decisions

- **FindIntersect encoding**  
  Uses a **node‑to‑node ChainSync Point**:  
  `MsgFindIntersect = [4, [[slot, hash]]]` with `slot = 0` and a 32‑byte hash.  
  This avoids the preview node disconnect observed when using `[null]`.

- **Validation**  
  - Validates mux **mini‑protocol id** and **responder mode** for ChainSync frames.  
  - Decodes the **first CBOR integer tag** to enforce correct message types:
    - `MsgIntersectFound (6)` or `MsgIntersectNotFound (7)` after FindIntersect
    - `MsgRollForward (3)` or `MsgRollBackward (4)` after RequestNext
  - Minimal structural check for `MsgIntersectFound` ensures a well‑formed point
    `[slot, hash]` with a 32‑byte hash.

- **Demultiplexing**  
  A small demux helper reads mux frames until a **ChainSync responder** frame arrives.
  Other mini‑protocol frames are logged and ignored (no state impact).

- **Shutdown handling**  
  SIGINT/SIGTERM set a stop flag. The ChainSync loop exits cleanly without sending
  further messages, and the TCP stream is closed by normal `defer` cleanup.

## Notes

This is a deliberately minimal follower used for protocol validation and diagnostics.
It does **not** decode blocks or headers and does not persist chain state.
