# Relay-Dev アーキテクチャ再設計案

## 目的

この文書は、relay-dev の根本的な再設計案を示すものです。

狙いは現在のループ中心実装を少しずつ延命することではなく、
現在の「プロンプト実行 + 共有 YAML ファイル」型の構成を、
より明確な control plane / execution plane 型のアーキテクチャへ置き換えることです。

実装レベルの詳細設計は [redesign-design-spec.md](./redesign-design-spec.md) を参照してください。
実装順とタスク分割は [redesign-implementation-tasks.md](./redesign-implementation-tasks.md) を参照してください。

この再設計で改善したい点は次のとおりです。

- 実装精度
- 状態整合性
- 可搬性
- プロバイダ拡張性
- テスト容易性
- 可観測性

## 現行アーキテクチャの要約

現在の relay-dev は、単一のランタイムループが次の責務をまとめて担うことで動いています。

- フェーズ選択
- プロンプト生成
- AI CLI プロセス起動
- 人間承認ゲート
- タイムアウト時のエスカレーション
- 状態永続化
- 出力バックアップ
- セキュリティチェック
- ダッシュボード更新
- 成果物の部分的な妥当性確認

この設計はコンパクトですが、無関係な責務が同じ実行境界に混在しています。

## 中核的な問題

### 1. control plane と execution plane が混在している

`agent-loop.ps1` は現在、次の役割を同時に持っています。

- ワークフローエンジン
- 状態機械
- プロンプトビルダ
- プロバイダ起動器
- リトライ制御器
- ウォッチドッグ
- 実行後バリデータ

その結果、1つのファイルがオーケストレーション方針とプロバイダ実行の両方を抱えており、
変更コストと破壊リスクが高くなっています。

### 2. 状態がアドホックな YAML と自然言語規約で表現されている

現在のシステムは、次のものに依存しています。

- `queue/status.yaml`
- regex ベースの YAML 解析
- `差し戻し先: PhaseX` のような feedback 文字列規約

これは、機械状態が明示的な型付きフィールドではなく、
人間向けテキストから推測されているため脆い設計です。

### 3. フェーズ成果物は人には豊かだが、機械には弱い

テンプレートは詳細で有用ですが、ほとんどの成果物が Markdown のみです。
これは人間レビューには向いていますが、決定的な機械検証には不向きです。

たとえば次のような問題があります。

- タスク定義が強く型付けされていない
- verdict が強く型付けされていない
- テスト結果がログ中心である
- 差し戻し理由がテキスト先行である

### 4. プロバイダ統合が shell command 中心になっている

現在のシステムは Codex / Gemini / その他の CLI を外部コマンドとして起動しています。
この方針自体は問題ではありませんが、プロバイダ境界が暗黙的です。

次のような要素について、明示的な provider adapter 契約がありません。

- プロンプト受け渡し
- ツール権限
- タイムアウト方針
- リトライ意味論
- quota handling
- 構造化結果の取得

### 5. 成果物保存とワークフロー状態が結合している

`outputs/`, `queue/`, `.tasks/`, `.prev/`, ダッシュボード生成、差し戻し処理が、
明示的なドメインモデルではなくファイルシステム慣習を通じて結びついています。

### 6. テストがユーティリティ中心で、ワークフローモデルを検証していない

現在の回帰テストはヘルパーの挙動を検証していますが、
アーキテクチャとしては、決定的入力と出力を持つ
workflow engine 抽象をまだ露出できていません。

## 再設計の原則

再設計は次の原則に従うべきです。

1. control plane と execution plane を分離する
2. テキスト解析ベースの状態を型付き契約に置き換える
3. 人間向け Markdown は維持するが、機械向け成果物を追加する
4. プロバイダを明示的な adapter interface で差し替え可能にする
5. フェーズロジックを可能な限り宣言的モジュールへ寄せる
6. イベントログからワークフローを再生可能にする
7. ダッシュボードと人間レビューを「状態の所有者」ではなく「状態の利用者」にする

## 目標アーキテクチャ

目標とするシステムは、4つのレイヤで構成します。

### 1. Control Plane

この層は「次に何をすべきか」を決めます。

責務:

- ワークフロー状態の維持
- 次フェーズ遷移の解決
- 承認ゲートの強制
- 成果物の検証
- 意思決定の記録
- 実行ジョブのディスパッチ

主要モジュール:

- `WorkflowEngine`
- `RunStateStore`
- `TransitionResolver`
- `ArtifactValidator`
- `ApprovalManager`

### 2. Execution Plane

この層は 1 単位の作業を実行し、構造化結果を返します。

責務:

- プロバイダランタイムの起動
- フェーズジョブのプロバイダへの受け渡し
- 終了状態、ログ、実行時間、成果物の取得
- 失敗の正規化

主要モジュール:

- `ExecutionRunner`
- `ProviderAdapter`
- `ProviderResultNormalizer`
- `TimeoutPolicy`

### 3. Artifact Plane

この層は人間向け成果物と機械向け成果物の両方を保存します。

責務:

- Markdown 成果物の保存
- 構造化契約の保存
- テストレポートの保存
- 実行イベントの保存

主要成果物:

- `run-state.json`
- `events.jsonl`
- `runs/<run-id>/artifacts/run/<phase>/<artifact-id>`
- `runs/<run-id>/artifacts/tasks/<task-id>/<phase>/<artifact-id>`
- `runs/<run-id>/artifacts/tasks/<task-id>/Phase6/test_output.log`
- `runs/<run-id>/artifacts/tasks/<task-id>/Phase6/junit.xml`
- `runs/<run-id>/artifacts/tasks/<task-id>/Phase6/coverage.json`

ここでの `<artifact-id>` は `phase4_tasks.json` や `phase7_verdict.json` のような
phase 固有のファイル名です。
重要なのは canonical location を `runs/<run-id>/artifacts/...` に統一することであり、
`outputs/` は移行期間中の互換投影としてのみ扱います。

### 4. Presentation Plane

この層は状態を人に見せるための層です。

責務:

- ダッシュボード描画
- 承認プロンプト表示
- 実行サマリ生成
- エラー露出

主要モジュール:

- `DashboardRenderer`
- `ApprovalPromptRenderer`
- `RunSummaryRenderer`

## 提案するドメインモデル

現在のファイルシステム慣習は、明示的なドメインオブジェクトに置き換えるべきです。

### Run

Run は、1つのタスクに対するトップレベルのワークフロー実行です。

`phase` と `role` は別概念です。
`phase` は workflow 上の状態を表し、`role` はその phase の job を誰が担当するかを表します。
この再設計では、`Phase3-1` や `Phase5-2` のような review / check subphase も
親 phase の role ではなく、独立した phase として扱います。

フィールド:

- `run_id`
- `task_id`
- `project_root`
- `created_at`
- `current_phase`
- `current_task_id`
- `status`
- `active_job_id`
- `pending_approval`
- `task_order[]`
- `task_states{}`

### Job

Job は、1フェーズ・1役割・1試行の実行単位です。

ここでの `role` は `implementer` / `reviewer` のような実行主体を表します。
review subphase を表すために `role` を流用してはいけません。

フィールド:

- `job_id`
- `run_id`
- `phase`
- `role`
- `task_id`
- `attempt`
- `provider`
- `prompt_ref`
- `started_at`
- `finished_at`
- `exit_code`
- `result_status`

### TaskState

TaskState は、Phase5 以降の task 単位進捗を表します。

フィールド:

- `task_id`
- `status`: `not_started | ready | in_progress | blocked | completed | abandoned`
- `kind`: `planned | repair`
- `last_completed_phase`
- `depends_on[]`
- `origin_phase`
- `task_contract_ref`

これにより `pr_fixes` のような follow-up task も、自然言語ではなく型付き状態で管理できます。
`task_contract_ref` は task contract の正本を指し、
planned task は `phase4_tasks.json`、repair task は
originating verdict artifact の `follow_up_tasks[]` を参照します。

### Verdict

Verdict は、レビューまたは検証の型付き結果です。

フィールド:

- `verdict`: `go | conditional_go | reject`
- `rollback_phase`
- `severity`
- `must_fix[]`
- `warnings[]`
- `evidence[]`

### Artifact Contract

各フェーズは Markdown と構造化成果物の両方を出力すべきです。

例:

- `phase0_context.md` + `phase0_context.json`
- `phase1_requirements.md` + `phase1_requirements.json`
- `phase2_info_gathering.md` + `phase2_info_gathering.json`
- `phase3_design.md` + `phase3_design.json`
- `phase3-1_design_review.md` + `phase3-1_verdict.json`
- `phase4_task_breakdown.md` + `phase4_tasks.json`
- `phase4-1_task_review.md` + `phase4-1_verdict.json`
- `phase5_implementation.md` + `phase5_result.json`
- `phase5-1_completion_check.md` + `phase5-1_verdict.json`
- `phase5-2_security_check.md` + `phase5-2_verdict.json`
- `phase6_testing.md` + `phase6_result.json`
- `phase7_pr_review.md` + `phase7_verdict.json`
- `phase7-1_pr_summary.md` + `phase7-1_summary.json`
- `phase8_release.md` + `phase8_release.json`

ルール:

- phase 固有のファイル名は `<artifact-id>` として維持してよい
- canonical path は常に `runs/<run-id>/artifacts/...` 配下に置く
- `outputs/` への書き出しは互換投影であり、validator や engine の入力にしてはいけない
- `jobSpec` や validator は raw path ではなく typed `artifact_ref` で成果物を参照する
- planned task の context は `phase4_tasks.json` から、repair task の context は
  originating verdict artifact の `follow_up_tasks[]` から解決する

## 新しいファイルシステム構成

リポジトリは次のような構成に寄せていくべきです。

```text
relay-dev/
├── app/
│   ├── cli.ps1
│   ├── core/
│   │   ├── workflow-engine.ps1
│   │   ├── run-state-store.ps1
│   │   ├── event-store.ps1
│   │   ├── transition-resolver.ps1
│   │   └── artifact-validator.ps1
│   ├── execution/
│   │   ├── execution-runner.ps1
│   │   ├── provider-adapter.ps1
│   │   ├── providers/
│   │   │   ├── codex.ps1
│   │   │   ├── gemini.ps1
│   │   │   └── generic-cli.ps1
│   ├── prompts/
│   │   ├── system/
│   │   ├── phases/
│   │   └── providers/
│   ├── phases/
│   │   ├── phase-registry.ps1
│   │   ├── phase0.ps1
│   │   ├── phase1.ps1
│   │   ├── phase2.ps1
│   │   ├── phase3.ps1
│   │   ├── phase3-1.ps1
│   │   ├── phase4.ps1
│   │   ├── phase4-1.ps1
│   │   ├── phase5.ps1
│   │   ├── phase5-1.ps1
│   │   ├── phase5-2.ps1
│   │   ├── phase6.ps1
│   │   ├── phase7.ps1
│   │   ├── phase7-1.ps1
│   │   └── phase8.ps1
│   ├── approval/
│   │   ├── approval-manager.ps1
│   │   └── terminal-adapter.ps1
│   └── ui/
│       ├── dashboard-renderer.ps1
│       ├── approval-prompt-renderer.ps1
│       └── run-summary-renderer.ps1
├── docs/
├── runs/
│   └── <run-id>/
│       ├── run-state.json
│       ├── events.jsonl
│       ├── jobs/
│       └── artifacts/
└── tests/
```

## Workflow Engine 設計

workflow engine は、遷移を決める唯一の場所であるべきです。

### Engine Input

engine が受け取るもの:

- 現在の run state
- 最新 job result
- validator result
- 必要なら approval decision

### Engine Output

engine が返すものは次のいずれかです。

- 次の job dispatch
- approval request
- rollback
- run completion
- manual intervention required

### Engine Behavior

engine は次のことをしてはいけません。

- プロバイダ向けプロンプトをその場で組み立てる
- 外部 CLI を直接 shell out する
- 任意パスから成果物をアドホックに読む

engine は、型付き状態と型付き job result だけを見て判断するべきです。

## Provider Adapter 設計

provider 層は次のような安定インターフェースを持つべきです。

```text
Invoke-ProviderJob(jobSpec) -> providerResult
```

`jobSpec` が持つもの:

- phase
- role
- task_id
- task context
- prompt package reference
- structured inputs
- permissions
- timeout policy

`providerResult` が持つもの:

- exit code
- stdout/stderr reference
- elapsed time
- structured metadata
- failure class

これにより relay-dev は、オーケストレーションロジックを変えずに
次を扱えるようになります。

- Codex CLI
- Gemini CLI
- Claude CLI
- 将来の直接 API 統合

## Prompt / Instruction Strategy

新しい execution path では、phase module が `prompt package` を解決して
`jobSpec` に埋め込むべきです。

`prompt package` が持つもの:

- system prompt reference
- phase prompt reference
- optional provider hints

旧 `templates/` と `instructions/` は削除済みです。
新 runner では `app/prompts/` 配下の engine-managed prompt package だけを正本にします。
これにより、`queue/status.yaml` の read/write のような旧 runtime 前提を引きずらずに運用できます。

## Phase Module 設計

各フェーズは、次の 5 要素を持つモジュールとして扱うべきです。

ここでの「各フェーズ」には review / check subphase も含みます。
つまり `Phase3` と `Phase3-1`、`Phase5` と `Phase5-1` / `Phase5-2` は
別々の phase module として定義します。

また、`phase-registry.ps1` は phase module の lookup を担うだけで、
prompt package や validator ルールの正本を別の場所へ重複定義してはいけません。
job dispatch 時には phase module の定義から `prompt package reference` を解決し、
`jobSpec` に展開します。

1. input contract
2. prompt package reference
3. output contract
4. validator
5. transition rules

例:

### Phase4 Module

- input:
  - 承認済み設計契約
- output:
  - task list markdown
  - task list json
- validator:
  - task ID が一意
  - dependency が DAG を成す
  - 各 task が acceptance criteria を持つ
  - 各 task が変更ファイルを宣言する
- transition:
  - `go -> phase4-1`
  - `reject -> phase3`

### Phase4-1 Module

- input:
  - `phase4_task_breakdown.md`
  - `phase4_tasks.json`
- output:
  - task review markdown
  - verdict json
- validator:
  - `phase4_tasks.json` と review verdict の整合性確認
- transition:
  - `go -> phase5`
  - `conditional_go -> phase5`
  - `reject -> phase4`

### Phase7 Module

- input:
  - task 単位成果物一式
  - phase6 test result
  - prior verdict artifacts
- output:
  - PR review markdown
  - verdict json
- validator:
- `rollback_phase` と `follow_up_tasks` が verdict と矛盾しない
- repair task を出す場合、task contract が空でない
- transition:
  - `go -> phase7-1`
  - `conditional_go -> follow_up_tasks[] を canonical task contract として repair task を spawn して phase5`
  - `reject -> verdict.rollback_phase`

これは、すべてのフェーズ挙動を 1 本のランタイムループに埋め込むより健全です。

## Artifact 戦略

Markdown は残すべきですが、source of truth にはすべきではありません。

### 人間向け成果物

- 読みやすいレビュー
- 設計書
- サマリ
- 承認メモ

### 機械向け成果物

- JSON 契約
- verdict object
- test report file
- event log record
- approval decision object

### 重要ルール

状態遷移は、散文ではなく機械向け成果物に依存すべきです。

特に、`Phase7` の `conditional_go` と `reject` は別物として扱うべきです。

- `conditional_go`: 問題が task 局所であり、repair task を生成して `Phase5` に戻す
- `reject`: workflow レベルの差し戻しであり、`rollback_phase` に従って `Phase1/3/4/5/6` へ戻す

現行の広い rollback 能力を維持し、すべての Phase7 指摘を repair task へ畳み込んではいけません。

## Status File ではなく Event Log へ

`queue/status.yaml` は次の構成へ置き換えるべきです。

- 追記専用の `events.jsonl`
- 具体化済みの `run-state.json`

ただし、`events.jsonl` / `run-state.json` の書き込み主体は single writer に限定すべきです。
provider や UI が直接書くのではなく、control plane が排他的に更新します。

利点:

- 再生可能性
- 監査性
- デバッグ容易性
- より安全な同時実行制御
- brittle parsing の削減

イベント種別の例:

- `run.created`
- `tasks.registered`
- `run.status_changed`
- `job.dispatched`
- `job.started`
- `job.finished`
- `artifact.validated`
- `task.selected`
- `task.completed`
- `task.spawned`
- `approval.requested`
- `approval.resolved`
- `phase.transitioned`
- `run.failed`
- `run.completed`

`run-state.json` を event から再構成すると決めるなら、
`task_order`, `current_role`, `pending_approval`, `open_requirements`,
`task_contract_ref`, `attempt` を
復元できるだけの event schema を最初から持つべきです。

## Approval 設計

人間レビューは、第一級の workflow event にすべきです。

現状では承認処理が terminal interaction と dashboard 書き込みに混ざっています。
代わりに次の流れにします。

- engine が `approval.requested` を発行する
- UI が保留中の承認を表示する
- UI / adapter が typed approval decision object を engine に返す
- engine が `approval.resolved` を記録し、run-state を更新する
- engine がその状態から再開する

`approval.resolved` の payload は `decision` だけでなく
`target_phase`, `target_task_id`, `must_fix[]` のような構造化フィールドを持つべきで、
自由文コメントを source of truth にしてはいけません。

少なくとも次の適用ルールを先に固定すべきです。

- `approve`: engine が approval request 時に保持していた `proposed_action` をそのまま再開する
- `conditional_approve`: `proposed_action` で再開しつつ、`must_fix[]` を run state の未解決条件として保持する
- `reject`: `target_phase` と必要なら `target_task_id` に従って巻き戻す
- `skip`: 監査上は別 decision として記録するが、遷移自体は `approve` と同じ
- `abort`: run を `blocked` にし、manual intervention required として停止する

これにより将来的に次の承認チャネルを追加できます。

- terminal
- web UI
- GitHub issue comment
- Slack notification

しかも workflow logic を変更せずに済みます。

## テストアーキテクチャ

再設計では、テストの重心をヘルパー検証から挙動検証へ移すべきです。

### 維持するもの

- 低レベル utility test

### 追加すべきもの

- workflow engine transition test
- provider adapter contract test
- artifact validator test
- event log replay test
- end-to-end run simulation test

### 最小のテスト単位

最小単位は次であるべきです。

```text
given run state + job result -> expected next action
```

これは regex 解析や緩いファイル慣習だけをテストするより安定します。

## 推奨する技術的方向性

大きく 2 つの道があります。

### Path A: PowerShell を維持しつつ強くモジュール化する

PowerShell をメインランタイムとして維持しつつ、次を導入します。

- 型付き JSON 契約
- 明示的な engine module
- provider adapter
- event log

これは移行コストが最も低い道です。

### Path B: コアエンジンを Python へ移し、PowerShell は薄い shell にする

relay-dev を今後も拡張していくなら、こちらの方が長期的には良い設計です。

推奨分担:

- Python:
  - workflow engine
  - state store
  - validator
  - provider adapter
  - test
- PowerShell:
  - Windows 向け launcher
  - terminal UX glue

理由:

- データモデル化がしやすい
- テスト記述性が高い
- YAML/JSON の取り扱いが安定する
- 可搬性が高い
- subprocess 制御が整理しやすい

Windows-first の小規模ツールとして留めるなら Path A で十分です。
長期運用する orchestration framework にしたいなら、Path B の方が投資対効果は高いです。

## 推奨判断

推奨する方針は次のとおりです。

1. `agent-loop.ps1` を今後も中心に育て続けない
2. 当面は PowerShell を維持して書き換えリスクを抑える
3. まず typed workflow engine と provider adapter の境界を導入する
4. 状態を `status.yaml` から `events.jsonl + run-state.json` に移す
5. legacy prompt を新 runner へ流用せず、engine 管理の prompt package を正本にする
6. テンプレート拡張より先に structured phase artifact を導入する
7. engine 境界ができた段階で Python core を再評価する

これで全面書き換えを避けつつ、アーキテクチャ上の大半の利益を取れます。

## 移行計画

### Phase 0: 現行ループへの新しい複雑性追加を止める

安定性上どうしても必要なものを除き、
`agent-loop.ps1` に大きな新規ポリシーを積み増さないようにします。

### Phase 1: 既存 Markdown の隣に型付き成果物を追加する

次の機械向け成果物を追加します。

- Phase0 context artifact
- Phase1 requirements artifact
- Phase2 info gathering artifact
- Phase3 design artifact
- Phase5 implementation artifact
- Phase3-1 verdict artifact
- Phase4 task artifact
- Phase4-1 verdict artifact
- Phase5-1 verdict artifact
- Phase5-2 verdict artifact
- Phase6 test result artifact
- Phase7 verdict artifact
- Phase7-1 summary artifact
- Phase8 release artifact

既存 Markdown はそのまま維持します。

### Phase 2: provider adapter 境界を導入する

CLI 起動ロジックを `agent-loop.ps1` から provider module へ移します。
この段階で phase module から解決される engine 管理 prompt package を導入し、
`templates/` / `instructions/` の旧 status.yaml 前提を新 runner から切り離します。

### Phase 3: run-state snapshot と event log を導入する

この段階では `status.yaml` を互換レイヤとして残して構いません。
新しい run state から `status.yaml` を生成し、既存呼び出し側との互換を保ちます。
`start-agents.ps1` と運用手順が `cli.ps1 + run-state.json` 前提へ切り替わるまでは、
`status.yaml` 投影を廃止してはいけません。
互換期間中の `start-agents.ps1` / `start-agents.sh` は
legacy watcher の正本ではなく、`cli.ps1 new|resume|step` を呼ぶ wrapper へ縮退させます。
同様に、canonical artifact store から `outputs/` への互換投影が必要なら
artifact repository が担当し、engine は legacy path を読まないようにします。

### Phase 4: workflow engine を抽出する

次の責務を dedicated engine module に移します。

- transition rule
- rollback handling
- approval gating
- timeout reaction

### Phase 5: status file 主導のオーケストレーションを置き換える

`queue/status.yaml` を主たる調停手段から外します。

### Phase 6: terminal に埋め込まれた approval flow を置き換える

approval event + UI adapter 方式へ移行します。

## 変えるべきでないもの

次の部分は現行設計の強みなので維持すべきです。

- 対立的レビュー姿勢
- フェーズ分割型の進め方
- 要件 -> 設計 -> タスク -> 実装 -> レビューの流れ
- 明示的な human approval gate
- 再現可能なテスト証跡を重視する姿勢

再設計では、運用モデルは残しつつ、その下のランタイム構造を置き換えるべきです。

## 最初の具体的なリファクタリング単位

すぐ実装に着手するなら、最初のスライスは次です。

1. `phase3_design.json` を追加する
2. `phase6_result.json` を追加する
3. `phase7_verdict.json` を追加する
4. `provider-adapter.ps1` を追加する
5. engine 管理 prompt package の骨組みを追加する
6. `run-state.json` を追加する
7. `agent-loop.ps1` が CLI 実行を直接持たず、provider adapter を呼ぶ形に変える

この単位は小さく出せますが、正しい境界を強制できます。

## 再設計の成功条件

再設計が成功したといえる条件は次です。

- フェーズ遷移が散文解析に依存しない
- プロバイダ切替のために workflow logic を編集しなくてよい
- 保存されたイベントから 1 job 実行を再生できる
- validator が typed artifact を消費する
- approval を terminal 外で扱える
- 実プロバイダを起動せずに end-to-end workflow 挙動をテストできる

## 最終的な立場

現在のアーキテクチャは強いプロトタイプですが、
最終形として扱うべきではありません。

次世代の relay-dev は次の形で組み立てるべきです。

- workflow engine
- provider adapter を駆動し
- typed artifact の上で動き
- event log に支えられ
- Markdown は review surface として使う

これが、精度・保守性・拡張性を実質的に改善するためのアーキテクチャ上の転換点です。
