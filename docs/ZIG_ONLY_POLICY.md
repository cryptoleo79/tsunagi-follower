# ZIG ONLY POLICY

## 日本語

### 定義
「Zig-only」とは、TSUNAGI NodeをZigのみでゼロから作る方針です。  
外部言語のランタイムや既存実装に依存しません。  

### なぜZig-onlyなのか
- シンプルで軽量に保つため
- 信頼と可視性を高めるため
- 運用者が理解しやすく、制御しやすいため

### ルール
- 外部言語ランタイムを追加しない
- Rust/Haskellのライブラリを取り込まない
- 暗号まわりはZigファースト / Zigオンリー

### 例外プロセス
どうしても依存が必要な場合は、必ず書面で記録します。  
記録には以下を含めます:
- 理由
- 代替案
- リスク
- 影響と移行の計画

## English

### Definition
“Zig-only” means TSUNAGI Node is built from the ground up in Zig.  
We do not rely on external language runtimes or existing implementations.  

### Why Zig-only
- Keep things simple and lightweight
- Increase trust and visibility
- Make operation easier to understand and control

### Rules
- No external language runtimes
- No Rust/Haskell libraries
- Crypto must be Zig‑first / Zig‑only

### Exception process
If a dependency is ever required, we must record a written decision.  
The record must include:
- Reason
- Alternatives
- Risks
- Impact and migration plan
