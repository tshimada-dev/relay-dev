# Relay-Dev 評価レポート

- 評価日: 2026-04-06
- 対象: `C:\Projects\agent\relay-dev`
- 観点: CLI上で自走する自動システム開発用エージェント本体、および同梱 skill 群
- 確認方法: 実装読解、skill 定義確認、`pwsh -NoLogo -NoProfile -File tests/regression.ps1` 実行

## 1. 総評

- 現状の完成度は高く、試作段階は超えている。`run-state.json` / `events.jsonl` を正本に寄せ、typed artifact と approval gate で制御する方針は妥当。
- skill 分割も実務的で、`front-door` → `seed-author` → `operator-launch` → `troubleshooter` の責務分離は良い。
- 回帰テストは形だけではなく実質があり、主要な phase 遷移と approval フローは押さえられている。
- 重大欠陥なし。P0 を立てるほどの即時事故要因は見当たらず、主な改善余地は排他制御・seed 鮮度判定・安全策の実装担保にある。

## 2. リスク評価

### 自律制御

- 発生確率: 低
- 影響度: 中
- 総合リスク: 低
- 評価理由: `WorkflowEngine` の遷移と approval gate は一貫しており、通常の single-worker 運用では安定している。実運用上の現実的リスクは誤遷移そのものより、state/seed 取り扱いミスの方が大きい。

### セキュリティ

- 発生確率: 低
- 影響度: 重大
- 総合リスク: 中
- 評価理由: 実行安全策は主に prompt 規律に依存しており、runner 自体は provider の command/flags をそのまま通す。`workspace-write` かつ `project_dir: ".."` のため理論上は framework 側も触れるが、実運用では prompt と sandbox が抑止しており、直ちに P0 とまでは言えない。

### 状態管理

- 発生確率: 中
- 影響度: 重大
- 総合リスク: 中
- 評価理由: 設計書は run 単位 lock を前提にしているが、実装は `Write-RunState` と `Append-Event` を lock なしで書いている。通常の `start-agents.*` 運用では低確率だが、manual `step` 併用や二重起動時には現実的な競合リスクがある。

### テスト戦略

- 発生確率: 低
- 影響度: 中
- 総合リスク: 低
- 評価理由: phase 遷移、approval、artifact validator まで regression で押さえているのは強い。一方で CI はこの回帰群中心で、race 条件や real-provider smoke は未カバー。

### デプロイ安全性

- 発生確率: 低
- 影響度: 中
- 総合リスク: 低
- 評価理由: このシステムは Phase8 で release artifact を作るが、デプロイ自体を自動実行していない。さらに人間レビューが既定で `Phase3-1` / `Phase4-1` / `Phase7` に入るため、実運用上の安全性は悪くない。

## 3. 改善提案

### P0

- P0なし。重大欠陥なし。

### P1

- run 単位 lock か compare-and-swap を `step` 全体に入れ、`Write-RunState` と `Append-Event` を同一クリティカルセクションにまとめる。single-writer という設計思想自体は正しいので、実装追従で十分。
- Phase0 seed に `tasks/task.md` ハッシュか request fingerprint を持たせ、import 前に一致確認する。現状は「valid なら採用」なので、古い `outputs/phase0_context.*` を静かに再利用し得る。
- 「forbidden command detection」を本当に runner 側に実装するか、少なくとも config / README の表現を prompt-based safety に修正する。今は期待値だけが強く、監査説明として弱い。

### P2

- concurrency / recovery テストを追加する。特に「二重 `step`」「stale job 復旧時に古い artifact が残るケース」「duplicate launcher」は今の弱点に直結する。
- 旧ガード記述と実ランタイムのズレを整理する。`lib/phase-validator.ps1` はテストでは使われているが、現行 engine の中心制御ではなく、コメントの期待値が先行している。

## 4. 強み

- `runs/` を正本、`outputs/` と `queue/status.yaml` を投影に落とした判断は正しい。監査性と後方互換のバランスが良い。
- artifact validator が phase ごとの contract を具体的に持っており、「AI に任せるが、判定は構造で縛る」ができている。
- skill 側が canonical state first、read-only troubleshooting、seed 再利用条件を明示していて、運用設計として成熟している。
- visible worker + monitor + interactive approval へ寄せているのは実務的に良い。無人暴走より「見える自律」に寄せている。

## 5. 技術成熟度評価

- 評価: 82 / 100
- 所見: 内部利用や少人数チームでの継続運用は十分可能。商用安定運用に近いが、まだ「安全策を仕様で語れる段階」から「実装で担保できる段階」へ上げる余地がある。

### 減点対象

- run 単位排他の未実装
- Phase0 seed の鮮度未検証
- command safety の prompt 依存
- concurrency / real-provider 系テスト不足

## 補足根拠

- `app/core/workflow-engine.ps1`
- `app/core/run-state-store.ps1`
- `app/core/event-store.ps1`
- `app/core/job-result-policy.ps1`
- `app/execution/providers/generic-cli.ps1`
- `config/settings.yaml`
- `skills/relay-dev-operator-launch/SKILL.md`
- `skills/relay-dev-seed-author/SKILL.md`
- `skills/relay-dev-troubleshooter/SKILL.md`
- `tests/regression.ps1`
- `.github/workflows/ci.yml`
