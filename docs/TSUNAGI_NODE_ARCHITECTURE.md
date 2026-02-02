# TSUNAGI Node Architecture / アーキテクチャ

## 日本語

方針: `docs/ZIG_ONLY_POLICY.md`  

### スコープ（M0）
TSUNAGI Node M0は「検証できるリレー級ノード」です。  
ブロック生成（BP）や秘密鍵の運用は含みません。  

### 全体像（箱と矢印）
```
CLI ──┐
      ├─> Config ───────────────┐
      │                         │
      └─> Observability (logs)  │
                                v
Peer Manager ─> N2N Handshake ─> Mux ──> Mini-protocols
                                         ├─ ChainSync ──> Validation ──> Storage
                                         └─ BlockFetch ─> Validation ──> Storage

Validation (M0):
  - 構造・整合性チェック
  - ハッシュ検証
  - 台帳の深い検証は将来

Storage (M0):
  - headers / checkpoints / snapshots
```

### プロトコル境界（依存のルール）
- CLI/Configはネットワーク層を直接触らない  
- Peer ManagerはHandshake/Muxに依存するが、ValidationやStorageには依存しない  
- Mini-protocolsはMuxの上で動く（Muxの下には降りない）  
- ValidationはStorageに書くが、Peer Managerには依存しない  
- Observabilityはどの層からも参照できるが、制御はしない  

### ストレージモデル（M0）
保存するもの:
- ヘッダ（必要最小限）
- チェックポイント
- スナップショット（軽量）

再起動:
- 最後のチェックポイントから再開  
- ヘッダ整合性を再確認して続行  

保存しないもの:
- 秘密鍵
- ブロック生成に必要な情報

### アップグレード方針（短く）
- 互換性を壊さないことを最優先  
- 変化は小さく段階的に  
- 不確実性は明示し、検証可能にする  

### What lives where（配置の目安）
- `src/cli`  
- `src/config`  
- `src/net/peer_manager`  
- `src/net/handshake`  
- `src/net/mux`  
- `src/net/miniproto/chainsync`  
- `src/net/miniproto/blockfetch`  
- `src/validation`  
- `src/storage`  
- `src/observability`  

---

## English

Policy: `docs/ZIG_ONLY_POLICY.md`  

### Scope (M0)
TSUNAGI Node M0 is a relay‑class validating node.  
It does not include block production (BP) or key operations.  

### Overview (boxes & arrows)
```
CLI ──┐
      ├─> Config ───────────────┐
      │                         │
      └─> Observability (logs)  │
                                v
Peer Manager ─> N2N Handshake ─> Mux ──> Mini-protocols
                                         ├─ ChainSync ──> Validation ──> Storage
                                         └─ BlockFetch ─> Validation ──> Storage

Validation (M0):
  - structural checks
  - hash verification
  - deeper ledger checks are future work

Storage (M0):
  - headers / checkpoints / snapshots
```

### Protocol boundaries (dependency rules)
- CLI/Config do not touch the network layer directly  
- Peer Manager depends on Handshake/Mux, not on Validation/Storage  
- Mini‑protocols run on top of Mux (no layer breaks)  
- Validation writes to Storage, but does not depend on Peer Manager  
- Observability is visible everywhere, but does not control flow  

### Storage model (M0)
We store:
- minimal headers
- checkpoints
- light snapshots

Restart:
- resume from the last checkpoint  
- re‑check header consistency and continue  

We never store:
- private keys
- anything required for block production

### Upgrade strategy (short)
- Compatibility first  
- Changes are small and staged  
- Uncertainty is documented and verifiable  

### What lives where (suggested)
- `src/cli`  
- `src/config`  
- `src/net/peer_manager`  
- `src/net/handshake`  
- `src/net/mux`  
- `src/net/miniproto/chainsync`  
- `src/net/miniproto/blockfetch`  
- `src/validation`  
- `src/storage`  
- `src/observability`  
