# Pulse mode demo / パルスモード デモ

Pulse mode shows a calm, human‑readable stream of ChainSync updates (slots, short hashes, and timing) without changing protocol flow.
パルスモードは、プロトコルの流れを変えずに、slot/短いハッシュ/時間差を読みやすく表示します。

## Sample output / 出力例

```text
⏳ Awaiting next block...
▶️ RollForward slot=123456 hash=abc123def456 Δ850ms
⏪ RollBackward slot=123400 depth=56
```

## How to record a demo / デモの記録方法

```bash
asciinema rec docs/pulse.cast
zig run src/main.zig -- --pulse preview-node.world.dev.cardano.org 30002
# Ctrl-D to stop
```

```bash
asciinema rec docs/pulse.cast
zig run src/main.zig -- --pulse preview-node.world.dev.cardano.org 30002
# Ctrl-D で停止
```
