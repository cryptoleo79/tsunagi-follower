# Tsunagi Follower (preview)

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/cryptoleo79/tsunagi-follower)

A tiny, diagnostic node-to-node ChainSync follower for the Cardano preview network.
It is meant for learning and debugging protocol flows, not for running a full node.
If you're new, this repo aims to keep things simple and readable.

Cardanoのpreviewネットワーク向けに作られた、最小構成の診断用node-to-node ChainSyncフォロワーです。
プロトコルの流れを学んだりデバッグしたりするためのもので、フルノードではありません。
初心者の方にも読みやすい構成を目指しています。

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

Optional: add `--pulse` for a calm, human‑readable stream (slot, short hash, time delta, rollbacks).
See `docs/pulse-demo.md` for a short demo and recording guide.
日本語: `--pulse` を付けると、読みやすい表示（slot/短いハッシュ/経過時間/ロールバック）になります。
デモと録画手順は `docs/pulse-demo.md` を参照してください。

## Setup wizard / セットアップ

English:
- Run from the repo root (where `build.zig` is).
- Interactive wizard:
  ```bash
  zig run src/main.zig -- setup
  ```
- Run using config:
  ```bash
  zig run src/main.zig -- run
  ```
- For English prompts:
  ```bash
  zig run src/main.zig -- setup --lang en
  ```

### Absolute beginner quickstart (EN)
- Install Zig (0.13.x).
- Run `zig run src/main.zig -- setup`.
- Press Enter to accept defaults.
- Run `zig run src/main.zig -- run`.
- Stop with Ctrl+C.

日本語:
- リポジトリのルート（`build.zig` がある場所）で実行してください。
- 対話式セットアップ:
  ```bash
  zig run src/main.zig -- setup
  ```
- 設定ファイルで実行:
  ```bash
  zig run src/main.zig -- run
  ```
- 英語でプロンプトを表示:
  ```bash
  zig run src/main.zig -- setup --lang en
  ```

### はじめてのクイックスタート（JP）
- Zig(0.13.x)を入れます。
- `zig run src/main.zig -- setup` を実行。
- Enterでデフォルトを選びます。
- `zig run src/main.zig -- run` を実行。
- 終了はCtrl+C。

### クイックスタート（日本語）

ビルド:
```bash
zig build
```

実行（previewネットワーク）:
```bash
zig run src/main.zig -- preview-node.world.dev.cardano.org 30002
```

注意: これは学習・デバッグ用のChainSyncフォロワーであり、フルのCardanoノードではありません。

## Vision / ビジョン

- Lightweight and easy to read, even for beginners.
- Clear, minimal diagnostics for ChainSync and mux behavior.
- Graceful shutdown and community-friendly focus.

- 初心者にも読みやすい軽量なコードを目指します。
- ChainSyncとmuxの挙動を分かりやすく診断できるようにします。
- 安全な終了処理とコミュニティ志向を大切にします。

## Design Notes / 設計メモ

- Calm output designed for humans.
- No protocol flow changes (purely observational).
- Lightweight CBOR scan to extract slot/hash.

- 人間が読みやすい落ち着いた出力。
- プロトコルの流れは変更しない（観測のみ）。
- slot/hash抽出のための軽量CBORスキャン。

## Changelog

- v0.1.2: Retry FindIntersect with tip+origin on IntersectNotFound, fix ChainSync tags, and make Ctrl-C exit quickly (socket timeout).
- v0.1.2: IntersectNotFound時にtip+originで再試行、ChainSyncタグ修正、Ctrl-Cを即時終了に（ソケットタイムアウト）。
- v0.1.1: Handle ChainSync MsgAwaitReply (5) correctly after RequestNext; fix payload freeing in AwaitReply loop.
- v0.1.1: RequestNext後のChainSync MsgAwaitReply (5) を正しく扱い、AwaitReplyループのペイロード解放を修正。
- v0.1.0: Initial preview release (minimal node-to-node ChainSync follower).
- v0.1.0: 初期previewリリース（最小構成のnode-to-node ChainSyncフォロワー）。

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
