# Relay-Dev 評価レポート

- 評価日: 2026-04-15
- 対象: `C:\Projects\testrun\relay-dev`
- 確認方法: `README.md`、各 `skills/*/SKILL.md`、`app/` / `lib/` の中核実装、`.github/workflows/ci.yml`、`pwsh -NoLogo -NoProfile -File tests/regression.ps1` 実行、`powershell -NoLogo -NoProfile -File .\app\cli.ps1 show` 実行

## 1. 総評（3〜5行）

- 現状の完成度は高く、試作段階は明確に脱している。`run-state.json` / `events.jsonl` を正本に置き、`step` を single-writer に寄せ、typed artifact と approval gate で制御する設計は妥当。
- 設計の成熟度も高い。skill 分割は単なる説明資料ではなく、`front-door` / `seed-author` / `operator-launch` / `troubleshooter` / `course-corrector` の責務が実装上の運用面と噛み合っている。
- 運用可能性は十分ある。特に `start-agents.ps1` に visible terminal と monitor を寄せ、`operator-launch` が canonical state first を求めている点は実務的に良い。
- 重大欠陥なし。現実的な改善余地は、Phase0 seed の鮮度担保、canonical-first 運用の実装徹底、`pwsh` 前提の明文化であり、アーキテクチャ破綻ではない。

## 2. リスク評価（確率×影響度で評価）

### 自律制御

- 発生確率: 低
- 影響度: 中
- 総合リスク: 低
- 評価理由: `README.md` は `run-state.json` / `events.jsonl` を正本、`app/cli.ps1` を single writer と定義しており、`skills/relay-dev-operator-launch/SKILL.md` も canonical state first を要求している。実装側でも `app/core/workflow-engine.ps1` が `Get-NextAction`、`Apply-JobResult`、`Apply-ApprovalDecision` を通じて phase 遷移、approval gate、Phase2 clarification pause、Phase7 open requirement fail を明示的に扱っている。`tests/regression.ps1` でも Phase2 clarification、Phase7 conditional_go、failed-run recovery、run lock contention まで通っており、通常運用での誤遷移リスクは低い。

### セキュリティ

- 発生確率: 低
- 影響度: 重大
- 総合リスク: 中
- 評価理由: 実行面は `app/execution/provider-adapter.ps1` と `app/execution/execution-runner.ps1` が外部 CLI を起動する方式で、`config/settings.yaml` でも provider command/flags は差し替え可能、`paths.project_dir` は `..` になっている。したがって理論上の最悪ケースは「過剰権限の provider 設定や広い workspace への書き込み」だが、実運用上は `app/prompts/system/implementer.md` / `reviewer.md` の safety rules と `human_review` 既定有効が抑止線として機能している。多人数・多テナント環境向けの強固な sandbox ではないが、信頼された内部運用では低確率寄り。

### 状態管理

- 発生確率: 中
- 影響度: 中
- 総合リスク: 中
- 評価理由: mid-run の状態整合性は改善済みで、`app/cli.ps1` は `step` 全体を `app/core/run-lock.ps1` の run lock で保護し、`run-state.json` / `events.jsonl` / stale recovery を一貫して扱っている。一方で現実的なリスクは bootstrap 側に残る。`skills/relay-dev-seed-author/SKILL.md` は seed import 前に「現在の task と整合しているか」を確認する前提だが、`app/cli.ps1` は `outputs/phase0_context.*` が validator を通ればそのまま `SeedPhase0` するため、古い seed を誤再利用し得る。また `skills/relay-dev-operator-launch/SKILL.md` は canonical state first を求めるのに対し、`start-agents.ps1` は Resume/New の入口で `queue/status.yaml` を見ており、canonical pointer 欠落時の bootstrap が projection 依存になっている。

### テスト戦略

- 発生確率: 中
- 影響度: 中
- 総合リスク: 中
- 評価理由: テスト戦略そのものは良い。`.github/workflows/ci.yml` で構文チェックと regression を回し、`tests/regression.ps1` は artifact validator、approval、Phase2 fallback、Phase7 follow-up、failed-run recovery、run lock contention まで押さえている。ただしカバー範囲は実質 `pwsh` 前提で、今回の確認でも `pwsh -NoLogo -NoProfile -File tests/regression.ps1` は通る一方、`powershell -NoLogo -NoProfile -File .\app\cli.ps1 show` は parse error になった。つまり supported path の品質は高いが、Windows の手動オペレーション導線に対する回帰検知はまだ十分ではない。

### デプロイ安全性

- 発生確率: 低
- 影響度: 軽微
- 総合リスク: 低
- 評価理由: relay-dev 自体は Phase8 で release artifact を生成するだけで、自動デプロイまでは行わない。`app/phases/phase8.ps1` も release plan の artifact 出力に留まり、`human_review` は `Phase3-1` / `Phase4-1` / `Phase7` に既定で入る。`app/prompts/phases/phase8.md` にはデプロイ手順の例が含まれるため、理論上は危険な運用案が文書に現れる可能性はあるが、フレームワーク自身が本番変更を自動実行する構造ではない。

## 3. 改善提案（優先度は実害基準）

### P0

- P0なし。重大欠陥なし。

### P1

- `pwsh` を事実上の必須要件として運用導線に統一し、`app/cli.ps1` を Windows PowerShell 5.1 で fail fast させるか、UTF-8 non-BOM 前提を解消する。`start-agents.ps1` はすでに `pwsh` 必須だが、`README.md` の手動例は `.\app\cli.ps1 show` / `resume` を直接案内しており、実測では Windows PowerShell 5.1 で parse error になった。実害は「手動調査ができない」「壊れて見える」ことで、発生確率も低くない。
- Phase0 seed import に `tasks/task.md` fingerprint か seed origin metadata を追加し、`app/cli.ps1` の `SeedPhase0` 前に task 一致確認を入れる。現状は `skills/relay-dev-seed-author/SKILL.md` が task 整合を要求している一方で、実装は validator 通過のみで import するため、古い `outputs/phase0_context.*` が新しい run を誤初期化し得る。

### P2

- `start-agents.ps1` の Resume/New 判定を `runs/current-run.json` / `run-state.json` ベースへ寄せ、`queue/status.yaml` は表示用互換投影としてのみ使う。現在の wrapper は `queue/status.yaml` で resume UI を出したうえで `app/cli.ps1 resume` に phase/role を渡しており、canonical pointer 欠落時の挙動が skill の canonical-first 方針とずれる。
- `config/settings.yaml` の「Forbidden command detection」など、runtime で実装していない安全策の表現は prompt-based safety として書き直すか、runner 側に enforcement を追加する。現状でも内部運用としては成立するが、監査観点では「prompt 規律」と「実装担保」の境界を明文化した方が強い。

## 4. 強み

- `README.md` の「正本は `runs/`、`outputs/` / `queue/status.yaml` は互換投影」という整理が、`app/core/run-state-store.ps1` と `app/core/event-store.ps1` に実装レベルで反映されている。これは設計として正しい。
- skill 分割が実務的で、`relay-dev-front-door` が discovery、`relay-dev-seed-author` が bootstrap、`relay-dev-operator-launch` が control plane、`relay-dev-troubleshooter` が read-only diagnosis、`relay-dev-course-corrector` が change management を担う構成はよく整理されている。
- `app/core/artifact-validator.ps1` は単なる必須キー確認に留まらず、`visual_contract`、`boundary_contract`、Phase7 follow-up task、Phase6/Phase7 の verdict 整合までチェックしている。AI 出力を構造で縛る設計として評価できる。
- `tests/regression.ps1` は util テストだけではなく、approval request、conditional_go、failed-run recovery、run lock contention、prompt source-of-truth まで検証しており、回帰基盤として実質がある。
- `start-agents.ps1` が visible terminal と monitor を既定にし、`agent-loop.ps1` が approval 時に無闇に hidden 進行しないよう抑えているのは、「無人暴走」より「観測可能な自律」を優先した良い判断。

## 5. 技術成熟度評価

- 評価: 84 / 100
- 所見: `pwsh` 前提の内部運用や少人数チームでの継続利用なら、十分に安定運用可能な水準にある。5 に届いていない理由は、アーキテクチャの弱さではなく、bootstrap guardrail の実装徹底と shell 前提の明文化がまだ残っているため。
