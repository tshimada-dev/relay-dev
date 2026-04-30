# Architecture

relay-dev のアーキテクチャは、**canonical state を 1 ヶ所に集中させ、書き込みを単一経路に限定する**ことで、AI 出力のぶれを構造的に吸収するよう設計されています。本書では、その考え方とコアモジュールの責務分担を説明します。

より深い設計メモは [docs/architecture/architecture-redesign.md](../architecture/architecture-redesign.md) と [docs/architecture/redesign-design-spec.md](../architecture/redesign-design-spec.md) を参照してください。

## 設計の出発点

旧 relay-dev は「2 エージェント（implementer / reviewer）が `queue/status.yaml` を介して baton を渡す」モデルでした。これには次の問題がありました。

- baton が状態を兼ねており、stale な YAML が容易に正本化する
- 同期競合や半端な書き込みを engine 側で検知できない
- 「いまどの phase にいるか」を見るために `outputs/` を grep する文化が生まれる

リファクタ後は、**`runs/<run-id>/run-state.json` を唯一の正本**にし、すべての書き込みを `app/cli.ps1` から行う構成にしました。`queue/status.yaml` と `outputs/` は engine が canonical state から自動生成する**互換投影**であり、source of truth ではありません。

## レイヤ図

```text
┌────────────────────────── User / AI skill ──────────────────────────┐
│  relay-dev-front-door / -seed-author / -operator-launch / etc.      │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
                                   ▼
            ┌───────────────────────────────────────────┐
            │           app/cli.ps1                     │  <- single writer
            │   (new / resume / step / show)            │
            └────────────────┬──────────────────────────┘
                             │
            ┌────────────────┼─────────────────────┐
            ▼                ▼                     ▼
   ┌────────────────┐  ┌────────────────┐ ┌──────────────────────┐
   │ workflow-engine│  │ run-state-store│ │ phase-execution-     │
   │   (next action)│  │ (atomic write) │ │   transaction        │
   └────────┬───────┘  └────────────────┘ └──────────┬───────────┘
            │                                        │
            ▼                                        ▼
   ┌────────────────┐                ┌──────────────────────────────┐
   │ transition-    │                │ artifact-repository          │
   │   resolver     │                │  (canonical + staging)       │
   └────────────────┘                └────────┬─────────────────────┘
                                              ▼
                              ┌───────────────────────────────┐
                              │ artifact-validator            │
                              │ phase-validation-pipeline     │
                              └────────┬──────────────────────┘
                                       ▼
                              ┌───────────────────────────────┐
                              │ phase-completion-committer    │
                              │ artifact-repair-transaction   │
                              └───────────────────────────────┘

execution layer:
   execution-runner.ps1  ──►  provider-adapter.ps1  ──►  codex / gemini / copilot / claude
```

## 正本と互換投影

| パス | 役割 | 書き込み手段 | 直接編集可 |
| --- | --- | --- | --- |
| `runs/<run-id>/run-state.json` | 現在状態の正本 | `app/core/run-state-store.ps1` の atomic write | ✗ |
| `runs/<run-id>/events.jsonl` | append-only event log | `app/core/event-store.ps1` | ✗ |
| `runs/<run-id>/artifacts/...` | canonical artifact store | `app/core/artifact-repository.ps1` | ✗ |
| `runs/<run-id>/jobs/<job-id>/` | provider job IO（prompt / stdout / stderr） | `execution-runner` | 観察のみ |
| `runs/<run-id>/run.lock` | 同一 run の `step` 直列化 | `app/core/run-lock.ps1` | ✗ |
| `runs/current-run.json` | 現在の run ポインタ | `cli.ps1 new` / `resume` | ✗ |
| `queue/status.yaml` | 互換ステータス表示 | engine が再生成 | ✗ |
| `outputs/` | 互換 artifact projection | engine が再生成 | ✗ |
| `tasks/task.md` | 全 phase 共通の external input | 人間 / `relay-dev-seed-author` | ✓ |
| `outputs/phase0_context.{md,json}` | pre-run seed | 人間 / `relay-dev-seed-author` | ✓ |
| `config/settings.yaml` | 実行設定 | 人間 | ✓ |

「正本を読みたい時は必ず `runs/<run-id>/...`、`queue/` と `outputs/` は表示用」というルールを徹底することで、stale state による誤動作を構造的に防いでいます。

## 単一書き込み口（single writer）

すべての state 変更は `app/cli.ps1` の 4 コマンド経由で行われます。

| コマンド | 主な責務 |
| --- | --- |
| `new` | 新しい `run-id` を採番、`run-state.json` を初期化、`runs/current-run.json` を更新 |
| `resume` | `runs/current-run.json` の run-id を再選択し、stale な `active_job_id` を整合化 |
| `step` | `WorkflowEngine` に次 action を問い合わせ、`phase-execution-transaction` で 1 phase 進める |
| `show` | canonical state を読み出して人間向けに整形（read-only） |

外部スクリプト（`start-agents.ps1`、`agent-loop.ps1`）はこの CLI を呼ぶだけの**薄い wrapper** で、独自に `runs/` を書きません。

## コアモジュール責務

### 状態と event

| ファイル | 責務 |
| --- | --- |
| `app/core/run-state-store.ps1` | `run-state.json` の atomic read/write、stale 整合、`active_attempt` ヘルパー |
| `app/core/event-store.ps1` | `events.jsonl` への append-only 書き込み |
| `app/core/run-lock.ps1` | 同一 run への重複 `step` を防ぐファイルロック |

### 進行制御

| ファイル | 責務 |
| --- | --- |
| `app/core/workflow-engine.ps1` | `run-state.json` を読み、次 action（`dispatch_phase` / `request_approval` / `repair` / `complete`）を返す |
| `app/core/transition-resolver.ps1` | phase 遷移ルール（既定値 + per-phase override） |
| `app/phases/phase-registry.ps1` | phase ⇔ role 割り当て、`Get-DefaultTransitionRules` |
| `app/phases/phase*.ps1` | per-phase の入出力 contract、prompt 解決、validator hook |

### Phase 実行 transaction

| ファイル | 責務 |
| --- | --- |
| `app/core/attempt-preparation.ps1` | 既存 artifact の archive、attempt-scoped staging 作成 |
| `app/core/job-context-builder.ps1` | latest archived JSON snapshot を prompt context に組み立てる |
| `app/core/phase-execution-transaction.ps1` | `archive → dispatch → validate → commit` を 1 transaction にまとめる |
| `app/core/phase-validation-pipeline.ps1` | `artifact-validator` を含む validator chain の orchestration |
| `app/core/phase-completion-committer.ps1` | staging から canonical への commit、phase_history への記録 |

### Artifact / 修復

| ファイル | 責務 |
| --- | --- |
| `app/core/artifact-repository.ps1` | canonical artifact store と attempt-scoped staging の管理 |
| `app/core/artifact-validator.ps1` | 各 phase JSON artifact の schema enforcement (~52KB) |
| `app/core/artifact-repair-policy.ps1` | validator failure を repairable / non-repairable に分類 |
| `app/core/artifact-repair-transaction.ps1` | `invalid_artifact → repair → revalidate → commit` のレーン |
| `app/core/repair-prompt-builder.ps1` | repairer 用の prompt 構築 |
| `app/core/repair-diff-guard.ps1` | repairer が触ってはいけない field の機械的検出 |
| `app/core/visual-contract-schema.ps1` | visual contract の JSON schema |

### 実行・承認・UI

| ファイル | 責務 |
| --- | --- |
| `app/execution/execution-runner.ps1` | provider job dispatch、stdout/stderr capture、tee、staging path の prompt 注入 |
| `app/execution/provider-adapter.ps1` | provider CLI 固有の引数組立 |
| `app/approval/approval-manager.ps1` | human approval gate (`y/n/c/s/q`) の状態管理 |
| `app/approval/terminal-adapter.ps1` | 対話入力の取り回し |
| `app/ui/*-renderer.ps1` | dashboard、approval prompt、run summary の表示用 |

## 実行モデル

`step` を 1 回呼ぶと、おおよそ次の流れで 1 phase が進みます。

```text
cli.ps1 step
  └─ run-lock を取得
       └─ workflow-engine: 次 action を決定
            ├─ dispatch_phase の場合
            │    └─ phase-execution-transaction
            │         ├─ attempt-preparation: archive + staging
            │         ├─ job-context-builder: prompt context 組立
            │         ├─ execution-runner: provider CLI を呼ぶ
            │         ├─ phase-validation-pipeline: artifact-validator
            │         │    ├─ pass → phase-completion-committer
            │         │    └─ repairable invalid →
            │         │         artifact-repair-transaction
            │         │              ├─ repair-policy で受理判定
            │         │              ├─ repair-prompt-builder で repairer prompt 作成
            │         │              ├─ provider 再呼び出し
            │         │              ├─ repair-diff-guard で immutable field を検査
            │         │              ├─ revalidate
            │         │              └─ commit
            │         └─ run-state.json / events.jsonl を更新
            ├─ request_approval の場合
            │    └─ approval-manager → terminal-adapter（y/n/c/s/q）
            └─ complete の場合
                 └─ run-state.json.status = completed
```

`agent-loop.ps1` は polling で `cli.ps1 step` を繰り返し呼ぶだけです。`run-state.json` が `completed` / `failed` / `blocked` になったら待機します。

## 障害耐性のポイント

- **half-write 防止**: `run-state-store.ps1` は temp file → atomic rename。途中失敗時は次回 `resume` が `active_job_id` を整合化。
- **stale baton 無視**: `queue/status.yaml` と `outputs/` は read-only な投影。canonical state とずれていれば自動再生成で上書き。
- **invalid artifact からの復旧**: provider job 自体は成功しているが artifact が schema 違反のケースを `repairer` レーンに乗せ、product code を触らずに修復する。詳しくは [repairer.md](./repairer.md)。
- **二重 step 防止**: `run.lock` で同一 run の並列 `step` を直列化。

## 設計上の非交渉制約

| 制約 | 維持手段 |
| --- | --- |
| state 変更は `app/cli.ps1` 経由のみ | レビュー + 慣習 + `tests/regression.ps1` |
| `runs/` の手書き編集を禁止 | 障害時も skill (`troubleshooter`) は read-only で扱う |
| repairer は product code を触らない | `repair-diff-guard.ps1` が違反を検出して reject |
| repairer は review 判断を出さない | `phase-registry` が repairer を review phase に割り当てない |
| 同一 run への二重 step を直列化 | `run.lock` |
