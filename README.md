# Tsunagi Node (Zig)  
**Cardano ChainSync Follower / 軽量フォロワー**

---

## Overview

**EN**  
Tsunagi is a Zig-first Cardano networking project focused on **Node-to-Node (N2N) communication and ChainSync**.  
It connects to Cardano Preview and Mainnet peers, performs a v14 handshake over MUX, and follows the chain with rollback-aware persistent state.

**JA（日本語）**  
Tsunagi は Zig で実装された Cardano の **軽量 ChainSync フォロワー**です。  
Node-to-Node v14 ハンドシェイク（MUX）を行い、ロールバック対応でチェーンを追跡します。

---

## Current Features (v0.5.x)

- ✅ Node-to-Node **v14 handshake (MUX)**
- ✅ ChainSync (FindIntersect / RequestNext)
- ✅ RollForward / RollBackward 対応
- ✅ 永続状態（Persistent State）
  - `cursor.json`
  - `journal.ndjson`
  - `utxo.snapshot`
- ✅ Preview / Mainnet 分離（`TSUNAGI_HOME`）
- ✅ Tx 検出ヒューリスティック + TPS 表示
- ✅ 英語 / 日本語 CLI
- ✅ `doctor` コマンドによる状態チェック

---

## What this is NOT (まだ未対応)

- ❌ フル検証ノード（台帳・コンセンサス検証）
- ❌ ブロック生成（BP）
- ❌ 完全な UTxO 適用（枠組みは実装済み）

👉 現在は **Light ChainSync follower** です。  
将来のフルノード実装に向けた基盤です。

---

## Requirements

- Zig **0.13.x**
- Linux / macOS
- Outbound TCP access to Cardano relays

---

## Build & Test

```bash
cd tsunagi-node
zig build test --summary all
