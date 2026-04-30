# Relay-Dev 再設計 実装タスク分割

## 1. 文書の目的

この文書は、採用済みの再設計案を実装可能なタスクへ分割するための実装計画書です。

- アーキテクチャ方針は [architecture-redesign.md](./architecture-redesign.md)
- 詳細設計は [redesign-design-spec.md](./redesign-design-spec.md)
- 本書は「何をどの順で実装するか」を定義します

## 2. 採用前提

本タスク分割は、2026-03-24 時点で採用した次の前提に基づきます。

- 実行モデルは「2 つの長寿命エージェント常駐」ではなく、「engine が 1 job ずつ dispatch し、job ごとに role を切り替える」方式とする
- `implementer` / `reviewer` は独立プロセス常駐ではなく job の `role` として表現する
- provider CLI の会話継続はコア前提にしない。必要なら将来の最適化として `resume` 系機能を adapter 層で扱う
- 移行期間中は `queue/status.yaml` と `outputs/` を互換投影として維持する
- source of truth は段階的に `run-state.json` / `events.jsonl` / canonical artifact store に移す

## 3. 実装方針

- 小さく出せる縦スライスを優先する
- 互換投影が成立するまで既存運用を止めない
- engine と state の source of truth を先に固定し、UI や wrapper は後から置き換える
- provider 実行境界、artifact 契約、state mutation をそれぞれ独立にテストできる形を作る
- 最初のスライスでは Phase3 / Phase6 / Phase7 の typed artifact と provider adapter を優先する

## 4. マイルストーン

### M1. 実行境界の導入

目的:

- `agent-loop.ps1` から CLI 実行責務を剥がし始める
- `app/` 配下に新設計の受け皿を作る

対象タスク:

- T-01
- T-02
- T-03
- T-04
- T-05

完了条件:

- `app/cli.ps1` が追加されている
- `ExecutionRunner` が `ProviderAdapter` 経由で provider を起動できる
- 既存 `agent-loop.ps1` から直接 CLI を叩かず新 runner を呼べる

### M2. Typed Artifact の導入

目的:

- validator と遷移判断を prose 依存から外す

対象タスク:

- T-06
- T-07
- T-08
- T-09

完了条件:

- Phase3 / Phase6 / Phase7 の typed artifact が導入されている
- canonical artifact store へ保存できる
- validator が少なくとも初期 3 artifact を検証できる

### M3. State / Engine の置換

目的:

- orchestration の source of truth を `run-state.json` と `events.jsonl` に移す

対象タスク:

- T-10
- T-11
- T-12
- T-13
- T-14

完了条件:

- `RunStateStore` と `EventStore` が導入されている
- `TaskState.task_contract_ref` と repair task が扱える
- `WorkflowEngine` が `Get-NextAction` を返せる

### M4. Approval / Cutover

目的:

- terminal 依存を局所化し、互換 wrapper を整理する

対象タスク:

- T-15
- T-16
- T-17
- T-18

完了条件:

- approval が typed `ApprovalDecision` で扱える
- fake provider によるシナリオテストが通る
- `start-agents.*` が `cli.ps1` wrapper として動く

## 5. タスク一覧

### T-01. `app/` 骨組みと `cli.ps1` 追加

目的:

- 新設計のエントリポイントを追加し、既存実装と共存できる土台を作る

主な変更対象:

- `app/cli.ps1`
- `app/core/`
- `app/execution/`
- `app/phases/`
- `app/approval/`
- `app/ui/`
- `app/prompts/`

依存:

- なし

完了条件:

- ディレクトリ構成が設計書どおりに作成されている
- `cli.ps1 new|resume|step` の最低限のコマンド骨組みがある
- 既存スクリプトを壊さず追加のみで導入できる

### T-02. `ProviderAdapter` 契約と Codex/Gemini adapter 骨組み

目的:

- provider 差分を orchestration から隔離する

主な変更対象:

- `app/execution/provider-adapter.ps1`
- `app/execution/providers/codex.ps1`
- `app/execution/providers/gemini.ps1`
- 必要なら `app/execution/providers/generic-cli.ps1`

依存:

- T-01

完了条件:

- `Invoke-Provider(jobSpec) -> ProviderResult` の共通契約が定義されている
- Codex / Gemini で同じ戻り値 shape を返せる
- provider 固有エラーが `failure_class` に正規化される

### T-03. `ExecutionRunner` 抽出

目的:

- 現行の CLI 起動処理を `agent-loop.ps1` から分離する

主な変更対象:

- `app/execution/execution-runner.ps1`
- `agent-loop.ps1`

依存:

- T-02

完了条件:

- CLI 起動、timeout、stdout/stderr 回収が `ExecutionRunner` に移る
- `agent-loop.ps1` は runner を呼ぶだけの薄い orchestrator bridge になる
- 既存 provider 設定で動作退行がない

### T-04. engine-managed prompt package 骨組み

目的:

- legacy `templates/` / `instructions/` 依存から新 runner を切り離す

主な変更対象:

- `app/prompts/system/`
- `app/prompts/phases/`
- `app/prompts/providers/`
- `app/phases/phase-registry.ps1`

依存:

- T-01

完了条件:

- `JobSpec.prompt_package` を組み立てる最小経路がある
- Phase3 / Phase6 / Phase7 で新 prompt package を参照できる
- 新 runner が legacy prompt を直接読まない

### T-05. `agent-loop.ps1` との橋渡し

目的:

- 既存運用を維持したまま新設計の実行境界を差し込む

主な変更対象:

- `agent-loop.ps1`
- 必要なら `start-agents.ps1`
- 必要なら `start-agents.sh`

依存:

- T-03
- T-04

完了条件:

- 既存 watcher から新 `ExecutionRunner` を呼び出せる
- 既存運用手順を大きく変えずに新経路を試せる
- rollback 時に旧経路へ戻せる切替点が明示されている

### T-06. `ArtifactRepository` と canonical path 導入

目的:

- `outputs/` 依存を source of truth から外す

主な変更対象:

- `app/core/artifact-repository.ps1` または同等モジュール
- `runs/<run-id>/artifacts/...`
- `outputs/` 投影ロジック

依存:

- T-01

完了条件:

- run-scoped / task-scoped artifact を canonical path に保存できる
- 必要な artifact だけ `outputs/` に互換投影できる
- engine / validator が legacy path を直接読まない

### T-07. 初期 typed artifact 導入

目的:

- 最小スライスとして重要な判断点を JSON 化する

対象 artifact:

- `phase3_design.json`
- `phase6_result.json`
- `phase7_verdict.json`

主な変更対象:

- `templates/` または phase module 側の出力ロジック
- `app/phases/phase3.ps1`
- `app/phases/phase6.ps1`
- `app/phases/phase7.ps1`

依存:

- T-04
- T-06

完了条件:

- 対応する Markdown と JSON がペアで出る
- JSON に詳細設計書で定義した必須キーが入る
- canonical artifact store に保存される

### T-08. 残り phase artifact の JSON 化

目的:

- 全 phase を typed artifact ベースへ揃える

対象 artifact:

- `phase0_context.json`
- `phase1_requirements.json`
- `phase2_info_gathering.json`
- `phase4_tasks.json`
- `phase5_result.json`
- `phase3-1_verdict.json`
- `phase4-1_verdict.json`
- `phase5-1_verdict.json`
- `phase5-2_verdict.json`
- `phase7-1_summary.json`
- `phase8_release.json`

依存:

- T-07

完了条件:

- 全 phase で JSON artifact が存在する
- 既存 Markdown 名は維持される
- validator が参照できる配置に揃っている

### T-09. `ArtifactValidator` 初期実装

目的:

- typed artifact を使って判定できる最小の validator を作る

主な変更対象:

- `app/core/artifact-validator.ps1`
- validator test

依存:

- T-07

完了条件:

- 少なくとも `phase3_design.json` / `phase6_result.json` / `phase7_verdict.json` を検証できる
- invalid artifact を `failure_class: invalid_artifact` に変換できる
- prose parsing に依存しない

### T-10. `TaskState` / repair task 契約導入

目的:

- `Phase7 conditional_go` を typed task として扱えるようにする

主な変更対象:

- `RunState.task_states`
- `TaskState.task_contract_ref`
- `phase7_verdict.json` の `follow_up_tasks[]`
- repair task 生成ロジック

依存:

- T-07
- T-09

完了条件:

- planned task と repair task の両方を同じ `TaskState` モデルで扱える
- `selected_task` を `task_contract_ref` から導出できる
- `pr_fixes` 相当の task を自然言語に頼らず生成できる

### T-11. `RunStateStore` / `EventStore` 導入

目的:

- orchestration state の source of truth を構築する

主な変更対象:

- `app/core/run-state-store.ps1`
- `app/core/event-store.ps1`
- `runs/<run-id>/run-state.json`
- `runs/<run-id>/events.jsonl`

依存:

- T-01

完了条件:

- single writer で snapshot と event append ができる
- temp write + rename による snapshot 更新が実装されている
- event replay に必要な基本 event が記録できる

### T-12. `status.yaml` / `outputs/` 互換投影

目的:

- 新 state / artifact を正本にしつつ現行運用を維持する

主な変更対象:

- `RunStateStore` の `status.yaml` 投影
- `ArtifactRepository` の `outputs/` 投影

依存:

- T-06
- T-11

完了条件:

- `run-state.json` 更新時に `status.yaml` が再生成される
- 現行 dashboard と watcher が最低限動作する
- 直接 `status.yaml` を編集しない経路へ寄せられる

### T-13. `WorkflowEngine` action model 実装

目的:

- 次 action 判定を一箇所に集約する

主な変更対象:

- `app/core/workflow-engine.ps1`

依存:

- T-09
- T-10
- T-11

完了条件:

- `Get-NextAction(runState, context)` が `DispatchJob | RequestApproval | Wait | FailRun | CompleteRun` を返せる
- `Apply-JobResult` と `Apply-ApprovalDecision` の mutation が分離されている
- 実行や file parsing を持ち込まない

### T-14. `TransitionResolver` 実装

目的:

- phase 遷移と rollback を typed rule に置き換える

主な変更対象:

- `app/core/transition-resolver.ps1`
- `app/phases/phase-registry.ps1`

依存:

- T-13

完了条件:

- `go / conditional_go / reject` の遷移を phase 定義から解決できる
- `Phase7 conditional_go` と `reject` を区別できる
- feedback の文字列解析に依存しない

### T-15. `ApprovalManager` と terminal adapter

目的:

- approval を typed object として engine に戻す

主な変更対象:

- `app/approval/approval-manager.ps1`
- `app/approval/terminal-adapter.ps1`
- `pending_approval`
- `open_requirements`

依存:

- T-11
- T-13

完了条件:

- `approve / conditional_approve / reject / skip / abort` を構造化して扱える
- `approval.resolved` の永続化は engine のみが行う
- terminal UI は adapter に閉じ込められる

### T-16. Fake provider とシナリオテスト

目的:

- 実 provider を起動せず workflow 回帰を検証できるようにする

主な変更対象:

- provider mock
- engine / state / validator の scenario tests

依存:

- T-09
- T-13
- T-14
- T-15

完了条件:

- `Phase4-1 go -> Phase5`
- `Phase6 conditional_go -> 次 task or Phase7`
- `Phase7 conditional_go -> repair task spawn`
- `Phase7 reject -> rollback`
- `approval pending -> resume`

の各シナリオが自動テスト化されている

### T-17. `start-agents.*` の wrapper 化

目的:

- 常駐 watcher 前提を徐々に後退させる

主な変更対象:

- `start-agents.ps1`
- `start-agents.sh`
- `app/cli.ps1`

依存:

- T-11
- T-13

完了条件:

- `start-agents.*` は `cli.ps1 new|resume|step` を呼ぶ wrapper になる
- 新規 / 再開フローが `run-state.json` ベースで動く
- watcher ロジックが source of truth ではなくなる

### T-18. cutover 条件の検証と legacy 縮退

目的:

- 新旧二重管理期間を終わらせる

主な変更対象:

- `agent-loop.ps1`
- `lib/status-io.ps1`
- 旧 phase transition / feedback parsing

依存:

- T-12
- T-16
- T-17

完了条件:

- engine が次 action を単独で決定している
- `status.yaml` が source of truth ではない
- legacy parsing に依存する主要遷移が削除または wrapper 化されている

## 6. 直近の着手順

最初の実装スライスは次の順で着手します。

1. T-01 `app/` 骨組みと `cli.ps1`
2. T-02 `ProviderAdapter` 契約
3. T-04 prompt package 骨組み
4. T-07 初期 typed artifact
5. T-11 `RunStateStore` / `EventStore` 骨組み
6. T-03 `ExecutionRunner` 抽出
7. T-09 `ArtifactValidator` 初期実装

この順にすると、最初の小さな価値は次の形で出せます。

- provider 実行責務が `agent-loop.ps1` から分離される
- `phase3_design.json` / `phase6_result.json` / `phase7_verdict.json` が正規 artifact として保存される
- `run-state.json` と `events.jsonl` の受け皿ができる

## 7. 並行化の指針

次の組み合わせは並行化しやすいです。

- T-02 と T-04
- T-06 と T-07
- T-08 の各 phase artifact 追加
- T-13 実装と T-16 テスト基盤準備

次の組み合わせは同時に進めないほうが安全です。

- T-11 と T-12
- T-13 と T-14
- T-17 と T-18

## 8. 完了の判断基準

本タスク分割が完了したと判断できる条件は次です。

- `run-state.json` / `events.jsonl` / canonical artifact store が source of truth になっている
- implementer / reviewer の role 切替が `WorkflowEngine` の job dispatch で制御されている
- repair task と approval 条件が typed state で扱われている
- fake provider による主要シナリオテストが通る
- `start-agents.*` と legacy loop は wrapper または廃止対象まで縮退している
