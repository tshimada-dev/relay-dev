# Relay-Dev 再設計 詳細設計書

## 1. 文書の目的

この文書は、relay-dev を次の段階へ移行するための詳細設計書です。

既存の [architecture-redesign.md](./architecture-redesign.md) が
「なぜ再設計が必要か」「どういう方向へ変えるか」を示す提案書であるのに対し、
本書は「どの責務をどう分割し、どのデータ契約を導入し、どう移行するか」を定義します。

この文書をもとに、段階的な実装・レビュー・分割リリースに着手できる状態を目標とします。
実装順と依存関係は [redesign-implementation-tasks.md](./redesign-implementation-tasks.md) を参照してください。

## 2. 対象範囲

本設計の対象は次のとおりです。

- ワークフロー実行方式の再設計
- 状態管理方式の再設計
- AI プロバイダ実行境界の再設計
- 成果物フォーマットの再設計
- 人間承認フローの再設計
- テスト戦略の再設計

本設計の対象外は次のとおりです。

- Phase テンプレート本文の全面刷新
- 既存のレビュー観点そのものの変更
- Web UI の本格実装
- マルチリポジトリ実行機能
- `SandboxAdapter`（実行環境の分離機構）: Phase C で `ProviderAdapter` が安定した後に別途設計する

## 3. 背景と課題認識

現行実装では `agent-loop.ps1` が次を一括で担っています。

- フェーズ判定
- prompt 構築
- CLI 実行
- timeout / retry / escalation
- status 反映
- ガード処理
- 人間承認
- ダッシュボード更新

この構成は初期実装としては十分に機能していますが、次の問題が顕在化しています。

### 3.1 責務集中

`agent-loop.ps1` に制御ロジックと実行ロジックが混在しており、
小さな変更でも全体影響が大きくなっています。

### 3.2 状態表現の脆弱性

`queue/status.yaml` と `feedback` の自然言語規約に依存しているため、
プログラム上の状態遷移が prose parsing に引きずられています。

### 3.3 成果物検証の弱さ

成果物は人が読むには十分ですが、機械検証に使える構造が不足しています。

### 3.4 プロバイダ境界の曖昧さ

Codex / Gemini / その他 CLI を呼び分ける境界が暗黙的であり、
プロバイダ追加や direct API 化に弱い状態です。

### 3.5 テスト粒度の不足

現在のテストはユーティリティ単位が中心で、
「ある状態入力に対して engine がどう判断するか」を直接検証できません。

## 4. 設計目標

再設計の設計目標は次の 7 点です。

1. orchestration policy と provider execution を分離する
2. 状態を型付き JSON 契約で扱う
3. Markdown は人間向け、JSON は機械向けと明確に役割分離する
4. フェーズ遷移を engine の単一責務にする
5. provider 切替時に workflow engine を変更しない
6. event log から状態復元・再実行判断ができるようにする
7. 実プロバイダなしで workflow 挙動をテストできるようにする

## 4.1 リファクタリング前後の比較

以下の表は、現行実装と再設計後の期待値を比較したものです。
性能面はまだ未実装・未計測のため、実測値ではなく設計上の見込みを記載します。

| 観点 | リファクタリング前 | リファクタリング後 | 期待される効果 |
|---|---|---|---|
| 実行モデル | 常駐ループが `status.yaml` を監視し続ける | engine が step ごとに `Job` を dispatch する | 実行単位が明確になり、1 回の故障の影響範囲を限定しやすい |
| 状態管理 | `queue/status.yaml` と `feedback` の自然言語規約に依存 | `run-state.json` と `events.jsonl` を正とする | 状態不整合と prose parsing 依存を削減できる |
| 状態更新の I/O コスト | 単一 YAML の read/write は少ないが、解釈コストと競合リスクが高い | snapshot + append-only event で書き込み回数は増えるが処理は単純化する | 書き込み量はやや増えても、整合性と監査性が改善する見込み |
| フェーズ遷移判定 | `agent-loop.ps1` と feedback 文字列に分散 | `WorkflowEngine` / `TransitionResolver` に集約 | 遷移判断の変更点が一箇所にまとまり、回帰確認がしやすい |
| provider 切替 | CLI 起動ロジックが orchestration と密結合 | `ProviderAdapter` 経由で差し替え | provider 追加時の改修範囲を縮小できる |
| prompt 管理 | 旧 `templates/` / `instructions/` が旧 runtime 前提を内包していた | engine-managed `prompt package` を正本にする | 新 runner で旧 `status.yaml` 前提を引きずらずに済む |
| 成果物管理 | Markdown と `outputs/` 慣習が中心 | canonical artifact store を `runs/<run-id>/artifacts/...` に統一 | validator と engine が正本を一意に参照できる |
| 機械検証 | Markdown と自由文 verdict が中心 | phase ごとの JSON contract / verdict を導入 | 機械判定の再現性が上がる |
| 承認フロー | terminal interaction と状態更新が密結合 | `ApprovalManager` が decision を正規化し、engine が single writer で記録 | approval のチャネル追加がしやすくなる |
| クラッシュリカバリ | 手動で `status.yaml` を確認して再開する前提 | `active_job_id` と event replay で回復判断する | 復旧時間の短縮と判断の一貫化が見込める |
| テスト容易性 | utility 単位のテストが中心 | fake provider を含む engine / scenario test を追加 | 実プロバイダなしでワークフロー回帰を確認できる |
| 可観測性 | `status.yaml` と生成ログの目視確認が中心 | event log, artifact refs, structured verdict を記録 | 監査・原因追跡・ダッシュボード表示がしやすい |
| マルチタスク進行 | `.tasks/` や feedback ヒントに依存 | `task_order`, `task_states`, `current_task_id` で管理 | 次タスク選択と repair task 管理を型付きで扱える |
| 後方互換 | 現行運用に全面依存 | `status.yaml` と `outputs/` は投影として当面維持 | 運用を止めずに内部構造だけ先行で置換できる |

## 5. 全体アーキテクチャ

再設計後の relay-dev は、次の 4 層構成とします。

### 5.1 Control Plane

役割:

- run state を評価する
- 次 action を決定する
- artifact validator の結果を評価する
- approval 要否を判断する
- event を記録する

主要コンポーネント:

- `WorkflowEngine`
- `TransitionResolver`
- `RunStateStore`
- `EventStore`
- `ArtifactValidator`
- `ApprovalManager`

### 5.2 Execution Plane

役割:

- provider へのジョブ投入
- 実行結果の取得
- timeout / retry の適用
- provider 差異の吸収

主要コンポーネント:

- `ExecutionRunner`
- `ProviderAdapter`
- `ProviderResultNormalizer`
- `TimeoutPolicy`

### 5.3 Artifact Plane

役割:

- phase 成果物の保存
- 機械向け契約の保存
- テストレポートの保存
- バックアップと世代管理

主要コンポーネント:

- `ArtifactRepository`
- `ArtifactSerializer`
- `ArtifactBackupService`

### 5.4 Presentation Plane

役割:

- dashboard 表示
- 人間承認用 UI
- 実行サマリ生成

主要コンポーネント:

- `DashboardRenderer`
- `ApprovalPromptRenderer`
- `RunSummaryRenderer`

## 6. 新しい実行モデル

現行は「2つのエージェントが同じ status ファイルを監視し続ける」モデルです。
再設計後は「engine が次 job を決定し、execution runner が 1 job を実行する」モデルに移行します。

### 6.1 実行単位

最小実行単位は `Job` とします。

1 Job = 1 Role + 1 Phase + 1 Attempt

`Role` と `Phase` は別軸です。
`implementer` / `reviewer` は job の担当主体であり、
`Phase3-1` / `Phase4-1` / `Phase5-1` / `Phase5-2` / `Phase7-1` は
独立した workflow phase として扱います。
つまり、review subphase を親 phase の reviewer job に畳み込まず、
`current_phase` や遷移定義にも独立した phase identifier として現れます。

### 6.2 実行フロー

1. `WorkflowEngine` が `RunState` を読む
2. `TransitionResolver` が次 action を決める
3. action が `DispatchJob` であれば `ExecutionRunner` に job を渡す
4. `ProviderAdapter` が provider を起動する
5. 実行結果と生成成果物を `ArtifactRepository` に保存する
6. `ArtifactValidator` が構造化成果物を検証する
7. `WorkflowEngine` が `RunState` を更新する
8. approval が必要なら `ApprovalRequested` event を発行する
9. run 完了または次 job dispatch に進む

### 6.3 常駐監視の扱い

再設計後は `FileSystemWatcher` ベースの status 監視を主経路から外します。
代わりに engine 主導で 1 step ごとに状態を更新します。

必要であれば将来的に以下を追加できます。

- polling runner
- daemon runner
- manual step runner

ただし、中心は常駐監視ではなく `engine step` に置きます。

### 6.4 Prompt / Instruction の扱い

新しい `ExecutionRunner` は、phase module が解決した
engine-managed な `prompt package` を provider に渡します。

`prompt package` は最低限次を持ちます。

- system prompt reference
- phase prompt reference
- optional provider hints

旧 `templates/` と `instructions/` は削除済みです。
新 runner に渡す prompt の正本は `app/prompts/` 配下の engine-managed prompt に統一します。
これにより、`queue/status.yaml` の read/write や baton pass のような
旧 orchestrator 前提を現在の実行経路から切り離します。

## 7. データモデル

## 7.1 RunState

`runs/<run-id>/run-state.json`

```json
{
  "run_id": "run-20260324-001",
  "task_id": "task-main",
  "project_root": "C:/Projects/agent",
  "status": "running",
  "current_phase": "Phase5-1",
  "current_role": "reviewer",
  "current_task_id": "T-02",
  "active_job_id": "job-0007",
  "pending_approval": null,
  "open_requirements": [],
  "task_order": ["T-01", "T-02", "T-03"],
  "task_states": {
    "T-01": {
      "status": "completed",
      "kind": "planned",
      "last_completed_phase": "Phase6",
      "depends_on": [],
      "origin_phase": "Phase4"
    },
    "T-02": {
      "status": "in_progress",
      "kind": "planned",
      "last_completed_phase": "Phase5",
      "depends_on": ["T-01"],
      "origin_phase": "Phase4"
    },
    "T-03": {
      "status": "ready",
      "kind": "planned",
      "last_completed_phase": "Phase4-1",
      "depends_on": ["T-02"],
      "origin_phase": "Phase4"
    }
  },
  "created_at": "2026-03-24T15:00:00+09:00",
  "updated_at": "2026-03-24T15:12:00+09:00"
}
```

### 必須フィールド

- `run_id`
- `status`: `running | waiting_approval | blocked | failed | completed`
- `current_phase`
  - `Phase0`, `Phase1`, `Phase2`, `Phase3`, `Phase3-1`, `Phase4`, `Phase4-1`,
    `Phase5`, `Phase5-1`, `Phase5-2`, `Phase6`, `Phase7`, `Phase7-1`, `Phase8`
    のいずれか
- `current_role`
- `current_task_id`
  - `Phase5`, `Phase5-1`, `Phase5-2`, `Phase6` および task-scoped repair flow では必須
  - run-scoped phase では `null`
- `pending_approval`
  - `null` または typed object
- `open_requirements`
  - `conditional_approve` により持ち越された未解決条件
- `task_order`
- `task_states`
- `updated_at`

### 7.1a TaskState

`RunState.task_states` は task ごとの進捗を保持します。

最低限のフィールド:

- `task_id`
- `status`: `not_started | ready | in_progress | blocked | completed | abandoned`
- `kind`: `planned | repair`
- `last_completed_phase`
- `depends_on[]`
- `origin_phase`
- `task_contract_ref`: `{ phase, artifact_id, item_id }`

`pr_fixes` のような差し戻し対応タスクは `kind: repair` とし、
Phase7 などの後段フェーズが follow-up task を生成したことを明示できるようにします。
`task_contract_ref` は task contract の正本を指す typed reference です。
`kind: planned` の task は `phase4_tasks.json` の `tasks[]` を指し、
`kind: repair` の task は originating verdict artifact
（例: `phase7_verdict.json` の `follow_up_tasks[]`）を指します。

### 7.1b PendingApproval / OpenRequirement

`pending_approval` は approval 待ちの間だけ保持される control-plane state です。

- `approval_id`
- `requested_phase`
- `requested_role`
- `requested_task_id`
- `proposed_action`
- `requested_at`

`open_requirements[]` は `conditional_approve` と
`Phase5-2 / Phase6` の `conditional_go` で発生した
未解決条件を保持します。各要素は最低限次を持ちます。

- `item_id`
- `description`
- `source_phase`
- `source_task_id`
- `verify_in_phase`
- `required_artifacts[]`

engine は `verify_in_phase` と `required_artifacts` を用いて、
後続 artifact の `resolved_requirement_ids[]` と照合し、
該当条件が満たされた時点でこの配列から解消します。

## 7.2 Event

`runs/<run-id>/events.jsonl`

1 行 1 event の JSON Lines とします。

例:

```json
{"type":"run.created","at":"2026-03-24T15:00:00+09:00","run_id":"run-20260324-001"}
{"type":"tasks.registered","at":"2026-03-24T15:00:10+09:00","run_id":"run-20260324-001","task_order":["T-01","T-02","T-03"]}
{"type":"job.dispatched","at":"2026-03-24T15:01:00+09:00","job_id":"job-0001","phase":"Phase1","role":"implementer","attempt":1}
{"type":"job.finished","at":"2026-03-24T15:05:00+09:00","job_id":"job-0001","exit_code":0,"result_status":"succeeded"}
{"type":"artifact.validated","at":"2026-03-24T15:05:03+09:00","job_id":"job-0001","valid":true}
{"type":"run.status_changed","at":"2026-03-24T15:05:04+09:00","status":"running","current_role":"implementer"}
{"type":"phase.transitioned","at":"2026-03-24T15:05:05+09:00","from_phase":"Phase1","to_phase":"Phase2"}
{"type":"task.selected","at":"2026-03-24T15:20:00+09:00","task_id":"T-02","phase":"Phase5"}
{"type":"task.completed","at":"2026-03-24T15:45:00+09:00","task_id":"T-01","last_completed_phase":"Phase6"}
{"type":"task.spawned","at":"2026-03-24T16:10:00+09:00","task_id":"pr_fixes","kind":"repair","origin_phase":"Phase7","task_contract_ref":{"phase":"Phase7","artifact_id":"phase7_verdict.json","item_id":"fix-null-guard"}}
{"type":"approval.requested","at":"2026-03-24T16:20:00+09:00","approval_id":"approval-0003","requested_phase":"Phase7","requested_task_id":null,"proposed_action":{"type":"DispatchJob","phase":"Phase7-1","role":"implementer","task_id":null}}
{"type":"approval.resolved","at":"2026-03-24T16:25:00+09:00","approval_id":"approval-0003","decision":"approve","applied_action":{"type":"DispatchJob","phase":"Phase7-1","role":"implementer","task_id":null},"pending_approval":false}
```

### event の原則

- append-only
- 過去 event の更新禁止
- `run-state.json` は event から再構成可能であること
- `events.jsonl` と `run-state.json` の書き込み主体は control plane の single writer に限定すること
- `task_order`, `current_role`, `pending_approval`, `open_requirements`, `task_contract_ref`, retry 回数のような `RunState` 復元に必要な情報を event に含めること

## 7.3 JobSpec

`ExecutionRunner` に渡す仕様です。

```json
{
  "job_id": "job-0007",
  "run_id": "run-20260324-001",
  "phase": "Phase5",
  "role": "implementer",
  "task_id": "T-02",
  "attempt": 1,
  "provider": "codex-cli",
  "prompt_package": {
    "system_prompt_ref": "app/prompts/system/implementer.md",
    "phase_prompt_ref": "app/prompts/phases/phase5.md",
    "provider_hints_ref": "app/prompts/providers/codex-cli.md"
  },
  "artifact_refs": {
    "phase4_tasks": {
      "scope": "run",
      "phase": "Phase4",
      "artifact_id": "phase4_tasks.json"
    },
    "phase0_context": {
      "scope": "run",
      "phase": "Phase0",
      "artifact_id": "phase0_context.json"
    }
  },
  "selected_task": {
    "task_id": "T-02",
    "purpose": "null 入力時の API 呼び出し防止",
    "depends_on": ["T-01"],
    "changed_files": ["src/api/client.ts"],
    "acceptance_criteria": ["null 入力時に API 呼び出しを行わない"]
  },
  "permissions": {
    "project_root": "C:/Projects/agent",
    "framework_root": "C:/Projects/agent/relay-dev"
  },
  "timeout_policy": {
    "warn_after_sec": 300,
    "retry_after_sec": 3600,
    "abort_after_sec": 5400,
    "max_retries": 1
  }
}
```

- `task_id` は run-scoped phase では `null`、task-scoped phase では必須
- `prompt_package` は `phase-registry.ps1` が phase module から解決して `JobSpec` に展開する
- `artifact_refs` は canonical artifact store を指し、`outputs/` の legacy path を直接参照しない
- `selected_task` は `TaskState.task_contract_ref` と `current_task_id` から engine が導出する typed context である
- `kind: planned` の task は `phase4_tasks.json`、`kind: repair` の task は originating verdict artifact の `follow_up_tasks[]` から解決する

## 7.4 ProviderResult

```json
{
  "job_id": "job-0007",
  "attempt": 1,
  "exit_code": 0,
  "result_status": "succeeded",
  "started_at": "2026-03-24T15:10:00+09:00",
  "finished_at": "2026-03-24T15:14:10+09:00",
  "stdout_path": "runs/run-20260324-001/jobs/job-0007/stdout.log",
  "stderr_path": "runs/run-20260324-001/jobs/job-0007/stderr.log",
  "failure_class": null,
  "provider_metadata": {
    "provider": "codex-cli"
  }
}
```

`failure_class` は最低限次を持ちます。

- `timeout`
- `quota_exceeded`
- `provider_error`
- `invalid_artifact`
- `manual_abort`

## 7.5 ApprovalDecision

`approval.resolved` event に格納する構造化オブジェクトです。

```json
{
  "approval_id": "approval-0003",
  "decision": "conditional_approve",
  "target_phase": "Phase5",
  "target_task_id": "T-02",
  "must_fix": [
    {
      "item_id": "AP-01",
      "description": "null 入力時に API 呼び出しを行わないこと",
      "verify_in_phase": "Phase5-1",
      "required_artifacts": ["phase5-1_verdict.json"]
    }
  ],
  "comment": "追加の null guard を確認したい",
  "decided_by": "human",
  "decided_at": "2026-03-24T16:00:00+09:00"
}
```

原則:

- `comment` は補足情報であり source of truth ではない
- `conditional_approve` では `must_fix[]` を 1 件以上必須にする
- engine は `comment` ではなく `must_fix[]` の `verify_in_phase` と `required_artifacts` を見て `open_requirements[]` を更新する
- `ApprovalManager` は decision を検証・正規化して engine に返すだけで、`approval.resolved` event の永続化は engine が行う

engine への適用ルール:

- `approve`: `pending_approval.proposed_action` をそのまま採用して再開する
- `conditional_approve`: `proposed_action` を採用しつつ、`must_fix[]` を `open_requirements[]` に積む
- `reject`: `target_phase` を必須とし、必要なら `target_task_id` へ巻き戻す
- `skip`: 遷移は `approve` と同じだが、監査上 `decision: skip` を保持する
- `abort`: run を `blocked` とし、manual intervention required として停止する

## 8. 成果物契約

Markdown は維持しますが、全 phase に機械向け契約を定義します。

### 8.0 Canonical Rule

- canonical path は `runs/<run-id>/artifacts/run/<phase>/<artifact-id>` または
  `runs/<run-id>/artifacts/tasks/<task-id>/<phase>/<artifact-id>` とする
- `phase4_tasks.json` や `phase7_verdict.json` のような既存ファイル名は `<artifact-id>` として維持してよい
- `outputs/` は互換投影であり、engine と validator の入力にしてはいけない
- `JobSpec` は raw path ではなく `artifact_refs` で成果物を参照する
- `tasks/task.md` は external input として扱い、全 phase の prompt に自動注入する
- `phase0_context.md` / `phase0_context.json` は Phase0 の canonical output であり、Phase1 以降の全 phase が共通入力として参照する
- `kind: planned` の task-scoped context は `phase4_tasks.json` と `current_task_id` から導出する
- `kind: repair` の task-scoped context は `TaskState.task_contract_ref` が指す originating verdict artifact の `follow_up_tasks[]` から導出する
- repair task のためだけに別の raw task file を source of truth として増やさない

### 8.1 Phase0

入力:

- external `tasks/task.md`

出力:

- `phase0_context.md`
- `phase0_context.json`

`phase0_context.json` に最低限含めるもの:

- project summary
- `project_root`
- `framework_root`
- constraints
- available tools
- risks
- open questions

### 8.2 Phase1

出力:

- `phase1_requirements.md`
- `phase1_requirements.json`

`phase1_requirements.json` に最低限含めるもの:

- goals
- non_goals
- user_stories
- acceptance_criteria
- assumptions
- unresolved_questions

### 8.3 Phase2

出力:

- `phase2_info_gathering.md`
- `phase2_info_gathering.json`

`phase2_info_gathering.json` に最低限含めるもの:

- collected_evidence
- decisions
- unresolved_blockers
- source_refs
- next_actions

### 8.4 Phase3

出力:

- `phase3_design.md`
- `phase3_design.json`

`phase3_design.json` に最低限含めるもの:

- feature list
- API definitions
- entities
- constraints
- state transitions
- reuse decisions

### 8.5 Phase3-1

出力:

- `phase3-1_design_review.md`
- `phase3-1_verdict.json`

`phase3-1_verdict.json` に最低限含めるもの:

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`

### 8.6 Phase4

出力:

- `phase4_task_breakdown.md`
- `phase4_tasks.json`

`phase4_tasks.json` に最低限含めるもの:

- tasks[]
- task_id
- purpose
- changed_files[]
- acceptance_criteria[]
- dependencies[]
- tests[]
- complexity

validator 観点:

- `task_id` 重複なし
- dependency が循環しない
- acceptance criteria が空でない
- changed_files が空でない
- task execution 順序に必要な dependency 情報が欠けていない

### 8.7 Phase4-1

出力:

- `phase4-1_task_review.md`
- `phase4-1_verdict.json`

`phase4-1_verdict.json` に最低限含めるもの:

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`

### 8.8 Phase5

出力:

- `phase5_implementation.md`
- `phase5_result.json`

`phase5_result.json` に最低限含めるもの:

- `task_id`
- changed_files[]
- commands_run[]
- implementation_summary
- acceptance_criteria_status[]
- known_issues[]

### 8.9 Phase5-1

出力:

- `phase5-1_completion_check.md`
- `phase5-1_verdict.json`

`phase5-1_verdict.json` に最低限含めるもの:

- `task_id`
- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `acceptance_criteria_checks`
- `review_checks`

`acceptance_criteria_checks[]` に最低限含めるもの:

- `criterion`
- `status` (`pass | fail`)
- `notes`
- `evidence[]`

`review_checks[]` は固定 checklist とし、次の `check_id` を必須にする:

- `selected_task_alignment`
- `acceptance_criteria_coverage`
- `changed_files_audit`
- `test_evidence_review`

`review_checks[].status` は `pass | fail` のみを許可する。

遷移意味論:

- `go`: `acceptance_criteria_checks[]` と `review_checks[]` の全項目が `pass`
- `reject`: 1 件以上の `fail` を必須にし、`must_fix` を 1 件以上要求して `Phase5` に戻る

### 8.10 Phase5-2

出力:

- `phase5-2_security_check.md`
- `phase5-2_verdict.json`

`phase5-2_verdict.json` に最低限含めるもの:

- `task_id`
- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `security_checks`
- `open_requirements`
- `resolved_requirement_ids`

`security_checks[]` は固定 checklist とし、次の `check_id` を必須にする:

- `input_validation`
- `authentication_authorization`
- `secret_handling_and_logging`
- `dangerous_side_effects`
- `dependency_surface`

`security_checks[].status` は `pass | warning | fail | not_applicable` を許可する。

`open_requirements[]` に最低限含めるもの:

- `item_id`
- `description`
- `source_phase` (`Phase5-2`)
- `source_task_id`
- `verify_in_phase`
- `required_artifacts[]`

`resolved_requirement_ids[]` は既存の `open_requirements[]` のうち、
今回の security review で解消済みと判断した `item_id` を列挙する配列とする。

遷移意味論:

- `go`: `security_checks[]` に `warning` / `fail` を含めず、`open_requirements[]` は空
- `conditional_go`: `warning` を 1 件以上含み、`fail` は含めず、`must_fix` を 1 件以上要求し、`open_requirements[]` を 1 件以上含めて `Phase6` に進む
- `reject`: `fail` を 1 件以上必須にし、`must_fix` を 1 件以上要求し、`open_requirements[]` は空のまま `Phase5` に戻る

### 8.11 Phase6

出力:

- `phase6_testing.md`
- `phase6_result.json`
- `test_output.log`
- 可能なら `junit.xml`
- 可能なら `coverage.json`

これらの test artifact はすべて
`runs/<run-id>/artifacts/tasks/<task-id>/Phase6/` 配下に置きます。

`phase6_result.json` に最低限含めるもの:

- `task_id`
- test command
- lint command
- tests passed / failed
- coverage line / branch
- verdict
- conditional_go reasons
- `verification_checks`
- `open_requirements`
- `resolved_requirement_ids`

`verification_checks[]` は固定 checklist とし、次の `check_id` を必須にする:

- `lint_static_analysis`
- `automated_tests`
- `regression_scope`
- `error_path_coverage`
- `coverage_assessment`

`verification_checks[].status` は `pass | warning | fail | not_applicable` を許可する。

`open_requirements[]` に最低限含めるもの:

- `item_id`
- `description`
- `source_phase` (`Phase6`)
- `source_task_id`
- `verify_in_phase`
- `required_artifacts[]`

`resolved_requirement_ids[]` は既存の `open_requirements[]` のうち、
今回の検証で解消済みと判断した `item_id` を列挙する配列とする。

validator 観点:

- `coverage_line` / `coverage_branch` は `0..100`
- `go`: `tests_failed = 0` かつ `verification_checks[]` に `warning` / `fail` を含めず、`conditional_go_reasons` と `open_requirements[]` は空
- `conditional_go`: `tests_failed = 0` かつ `warning` を 1 件以上含み、`fail` は含めず、`conditional_go_reasons` と `open_requirements[]` を 1 件以上要求
- `reject`: 失敗テスト、または `verification_checks[]` の `fail` を 1 件以上必須とし、`open_requirements[]` は空

### 8.12 Phase7

出力:

- `phase7_pr_review.md`
- `phase7_verdict.json`

`phase7_verdict.json` に最低限含めるもの:

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `follow_up_tasks`
- `review_checks`
- `human_review`
- `resolved_requirement_ids`

`review_checks[]` は固定 checklist とし、次の `check_id` を必須にする:

- `requirements_alignment`
- `correctness_and_edge_cases`
- `security_and_privacy`
- `test_quality`
- `maintainability`
- `performance_and_operations`

`review_checks[].status` は `pass | warning | fail` を許可する。

`human_review` に最低限含めるもの:

- `recommendation` (`required | recommended | not_needed`)
- `reasons[]`
- `focus_points[]`

`recommendation != not_needed` の場合は `reasons[]` を 1 件以上必須にする。

`resolved_requirement_ids[]` は `RunState.open_requirements[]` のうち、
今回の PR review で解消済みと判断した `item_id` を列挙する配列とする。

`follow_up_tasks[]` に最低限含めるもの:

- `task_id`
- `purpose`
- `changed_files[]`
- `acceptance_criteria[]`
- `depends_on[]`
- `verification[]`
- `source_evidence[]`

遷移意味論:

- `go`: `review_checks[]` の全項目が `pass` で、`resolved_requirement_ids[]` 適用後の `RunState.open_requirements[]` が空のときのみ `Phase7-1` へ進む
- `conditional_go`: `warning` または `fail` を 1 件以上含む場合のみ許可し、`must_fix` を 1 件以上必須にする。`follow_up_tasks` を 1 件以上含むときは repair task を生成して `Phase5` に戻る
- `reject`: `fail` を 1 件以上必須にし、`rollback_phase` を `Phase1 | Phase3 | Phase4 | Phase5 | Phase6` のいずれかで必須にしてその phase に戻る

control plane は `conditional_go` を受けたら、各 `follow_up_tasks[]` 項目を
repair task の canonical contract として扱い、
`task.spawned` event と `TaskState.task_contract_ref` に反映します。

### 8.13 Phase7-1

出力:

- `phase7-1_pr_summary.md`
- `phase7-1_summary.json`

`phase7-1_summary.json` に最低限含めるもの:

- summary
- merged_changes
- task_results
- residual_risks
- release_notes

### 8.14 Phase8

出力:

- `phase8_release.md`
- `phase8_release.json`

`phase8_release.json` に最低限含めるもの:

- final_verdict
- release_decision
- residual_risks
- follow_up_actions
- evidence_refs

## 9. コンポーネント設計

### 9.1 WorkflowEngine

責務:

- `RunState` と最新 event 群を入力として次 action を決定する
- provider 実行そのものは行わない
- file parsing に依存せず typed input に依存する

公開関数の想定:

```text
Get-NextAction(runState, context) -> EngineAction
Apply-JobResult(runState, jobResult, validationResult) -> RunStateMutation
Apply-ApprovalDecision(runState, approvalDecision) -> RunStateMutation
```

`EngineAction` は次を持ちます。

- `DispatchJob`
- `RequestApproval`
- `Wait`
- `FailRun`
- `CompleteRun`

### 9.2 TransitionResolver

責務:

- フェーズ遷移の定義を保持する
- `go / conditional_go / reject` と現在 phase から次遷移を決める

現行の `lib/phase-validator.ps1` は phase transition validation を担っています。
再設計後はその責務を `TransitionResolver` に吸収し、
artifact の妥当性確認は `ArtifactValidator`、phase 遷移判定は `TransitionResolver`
という分担を明確にします。

### 9.3 ProviderAdapter

責務:

- provider ごとの差異吸収
- prompt の受け渡し
- stdout/stderr 保存
- provider 固有エラーの正規化

最小インターフェース:

```text
Invoke-Provider(jobSpec) -> ProviderResult
```

プロバイダ実装候補:

- `providers/codex.ps1`
- `providers/gemini.ps1`
- `providers/generic-cli.ps1`

### 9.4 ArtifactValidator

責務:

- フェーズごとの構造化成果物を検証する
- Markdown ではなく JSON 契約を主に検証する

戻り値:

```json
{
  "valid": true,
  "errors": [],
  "warnings": []
}
```

### 9.5 EventStore

責務:

- `events.jsonl` への event 追記
- run_id を指定した event 列の読み込み
- `run-state.json` の再構築に必要な event 列を返す

公開関数の想定:

```text
Append-Event(runId, event) -> void
Get-Events(runId) -> Event[]
Get-LastEvent(runId, type) -> Event
```

原則:

- event は追記のみ。既存行の書き換え禁止
- `EventStore` は `WorkflowEngine` step からのみ呼び出す single-writer API とする
- event 追記は run ごとの排他 lock を取得したうえで append stream + flush で行う
- `run-state.json` snapshot の更新は temp write + rename で行う
- provider / approval UI / validator は event を直接書き込まず、typed result を engine に返す
- クラッシュリカバリ時は `recovered: true` フラグ付きの補完 event を追記する

### 9.6 ApprovalManager

責務:

- approval request を生成する
- approval decision を検証・正規化して engine に返す
- terminal 以外の approval source に対応できる形を持つ

初期実装では terminal のままでよいですが、
`approval.resolved` event の永続化は control plane の single writer が行います。
インターフェースは UI 非依存にします。

## 10. ディレクトリ再編

目標構成は次です。

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
│   │   └── providers/
│   │       ├── codex.ps1
│   │       ├── gemini.ps1
│   │       └── generic-cli.ps1
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
├── tests/
└── legacy/
```

### Phase Module の構成

`app/phases/` の各ファイルは、フェーズ固有の次の 5 要素を宣言します。

この「フェーズ」には review / check subphase を含みます。
たとえば `phase3.ps1` と `phase3-1.ps1`、`phase5.ps1` と `phase5-1.ps1` / `phase5-2.ps1`
は別モジュールです。

- **input contract**: このフェーズが必要とする成果物・パス
- **prompt package reference**: `ExecutionRunner` に渡す engine-managed prompt の正本
- **output contract**: このフェーズが生成する Markdown と JSON の定義
- **validator**: `ArtifactValidator` に渡す検証ルール
- **transition rules**: verdict 値と次フェーズのマッピング

`TransitionResolver` は `phase-registry.ps1` を通じて各フェーズ定義を参照し、
遷移ロジックそのものはフェーズ定義から独立して保ちます。
`phase-registry.ps1` は lookup index であり、
prompt package / validator / transition rules の正本を別の場所に重複定義してはいけません。
job dispatch 時には `phase-registry.ps1` が phase module を解決し、
その `prompt package reference` を `JobSpec.prompt_package` に展開します。
必要なら設計メモや履歴から文言を移植しますが、
新 runner の直接入力は `app/prompts/` だけにします。
これにより、フェーズ追加時は対応する `phaseN.ps1` を追加するだけで済みます。

### 再編方針

- 既存 `lib/` は段階的に `app/core` と `app/execution` に移す
- 旧 `agent-loop.ps1` は互換ラッパに縮退させる
- 互換維持期間中は `legacy/` または wrapper として残す

## 11. 互換性方針

全面一括置換ではなく段階移行とします。

### 11.1 当面維持するもの

- 既存 Markdown 成果物名
- 既存 `start-agents.ps1`

prompt の正本は `app/prompts/` 側に置き、
必要なら設計メモや履歴から文言を移植します。

### 11.2 互換レイヤ

移行初期は `run-state.json` を正とし、
`queue/status.yaml` を投影として生成します。

`status.yaml` の生成責務は `RunStateStore` が担います。
`run-state.json` への write が発生するたびに、`RunStateStore` が副作用として
`status.yaml` を上書きします。二重書き込みを防ぐため、
`agent-loop.ps1` 側からの `status.yaml` 直接書き込みは、
`cli.ps1` 経由で `RunStateStore` に集約された後に無効化します。
互換期間中の `start-agents.ps1` / `start-agents.sh` は
watcher ロジックの正本ではなく、`cli.ps1 new|resume|step` を呼ぶ wrapper へ縮退させます。

成果物も同様に、canonical store は `runs/<run-id>/artifacts/...` とし、
必要な場合だけ `ArtifactRepository` が `outputs/` へ投影します。
validator と `JobSpec` は `outputs/` を直接参照しません。

廃止条件:

- `start-agents.ps1` の new / resume フローが `cli.ps1` と `run-state.json` を正として動く
- `agent-loop.ps1` が `status.yaml` を read / write しなくなり、互換ラッパまたは廃止対象になる
- `ExecutionRunner` が legacy `templates/` / `instructions/` を直接入力に使わなくなる
- `ArtifactRepository` が canonical store から `outputs/` 投影を生成できる
- 運用手順と監視導線が `queue/status.yaml` ではなく `run-state.json` と dashboard を参照する
- 上記が揃うまでは `status.yaml` 投影を維持する

これにより、既存の運用手順を壊さずに内部構造だけを先に置き換えられます。

## 12. タイムアウトとリトライの設計

現行は provider 実行ループの中で timeout / restart / manual intervention を扱っています。
再設計後は `TimeoutPolicy` を明示オブジェクトにします。

例:

```json
{
  "warn_after_sec": 300,
  "retry_after_sec": 3600,
  "abort_after_sec": 5400,
  "max_retries": 1
}
```

### 原則

- timeout policy は provider adapter の外に置く
- 実際の kill / retry は execution runner が行う
- timeout の結果は event として記録する

### クラッシュリカバリ

engine 起動時に `run-state.json` の `active_job_id` が non-null のまま
`events.jsonl` に `job.finished` がない場合、そのジョブはクラッシュ扱いとします。

復元ルール:

- `attempt < max_retries` の場合: `failure_class: provider_error` として `job.finished` を補完し、再ディスパッチする
- `attempt >= max_retries` の場合: `FailRun` アクションを発行し、手動介入を要求する

補完した event には `recovered: true` フラグを付けて監査ログで識別できるようにします。

## 13. 人間承認フロー

### 現行課題

- approval が terminal interaction と密結合
- dashboard が状態更新の副作用として使われている

### 新設計

approval は 2 段階に分けます。

1. `approval.requested` event を出す
2. typed `ApprovalDecision` を `ApprovalManager` が受け取り、検証・正規化して engine に返す
3. engine だけが `approval.resolved` event と `run-state.json` を更新し、再開する

approval decision model:

```json
{
  "approval_id": "approval-0003",
  "decision": "conditional_approve",
  "target_phase": "Phase5",
  "target_task_id": "T-02",
  "must_fix": [
    {
      "item_id": "AP-01",
      "description": "null 入力時に API 呼び出しを行わないこと",
      "verify_in_phase": "Phase5-1",
      "required_artifacts": ["phase5-1_verdict.json"]
    }
  ],
  "comment": "",
  "decided_by": "human",
  "decided_at": "2026-03-24T16:00:00+09:00"
}
```

許可値:

- `approve`
- `reject`
- `conditional_approve`
- `skip`
- `abort`

`conditional_approve` と `conditional_go` の使い分け:

- `conditional_go`: 機械判断。`ArtifactValidator` または phase6 テスト結果から自動的に決まる。
  `Phase5-2 / Phase6` では `open_requirements[]` を積んで後続 phase に持ち越し、
  `Phase7` では必要なら `follow_up_tasks[]` に昇格させる。
- `conditional_approve`: 人間判断。人間が「条件付きで承認する」と明示したケース。
  `comment` は補足に留め、engine は `must_fix[]` の
  `verify_in_phase` と `required_artifacts` を用いて対応完了を確認する。

single writer 原則:

- terminal adapter / Web UI / Slack adapter は approval decision を直接 event store へ書き込まない
- `approval.resolved` の append と `pending_approval` の解除は control plane のみが行う

## 14. テスト設計

### 14.1 単体テスト

対象:

- transition resolver
- run state mutation
- task state mutation
- provider result normalization
- artifact validator
- approval decision validation

### 14.2 シナリオテスト

対象:

- Phase1 -> Phase2 の通常遷移
- Phase4-1 go -> 最初の task が選択されて Phase5 が dispatch される
- Phase3-1 reject -> Phase3 rollback
- Phase6 conditional_go -> 次 task or Phase7
- Phase7 conditional_go -> repair task が生成されて Phase5 に戻る
- Phase7 reject -> Phase3 rollback
- approval pending -> resume
- approval resolve は engine だけが event / run-state を更新する

### 14.3 プロバイダモックテスト

Fake provider を使い、
実 CLI を起動せずに job 実行を模擬できるようにします。

これにより確認できること:

- engine の次 action 判定
- event 記録
- retry policy
- invalid artifact の handling

## 15. 実装フェーズ計画

### Phase A: 準備

目的:

- 既存実装を壊さずに新境界を導入する

作業:

- `docs/redesign-design-spec.md` 追加
- `app/` ディレクトリ作成
- `provider-adapter.ps1` 骨組み追加
- `app/prompts/` ディレクトリ作成

### Phase B: 機械向け成果物導入

目的:

- validator を prose 依存から外す

作業:

- `phase0_context.json` 追加
- `phase1_requirements.json` 追加
- `phase2_info_gathering.json` 追加
- `phase3_design.json` 追加
- `phase4_tasks.json` 追加
- `phase5_result.json` 追加
- `phase3-1_verdict.json` 追加
- `phase4-1_verdict.json` 追加
- `phase5-1_verdict.json` 追加
- `phase5-2_verdict.json` 追加
- `phase6_result.json` 追加
- `phase7_verdict.json` 追加
- `phase7-1_summary.json` 追加
- `phase8_release.json` 追加

### Phase C: 実行境界抽出

目的:

- CLI 実行ロジックを `agent-loop.ps1` から分離する

作業:

- `ExecutionRunner`
- `ProviderAdapter`
- provider implementations
- engine-managed prompt package
- legacy template / instruction 依存の分離

### Phase D: 状態管理置換

目的:

- `status.yaml` 依存を減らす

作業:

- `EventStore`
- `RunStateStore`
- `run-state.json`
- `events.jsonl`
- `current_task_id` / `task_states` / task-scoped event 導入
- `tasks.registered` / `run.status_changed` / approval event 導入
- canonical artifact store から `outputs/` への投影導入

### Phase E: Engine 抽出

目的:

- workflow decision を一箇所に集約する

作業:

- `WorkflowEngine`
- `TransitionResolver`
- state mutation tests

### Phase F: approval 分離

目的:

- terminal 依存を局所化する

作業:

- `ApprovalManager`
- terminal adapter
- structured `ApprovalDecision` 導入
- engine の single writer 経由でのみ `approval.resolved` を記録

## 16. リスクと対策

### リスク 1: 互換期間が長引き二重実装になる

対策:

- 旧実装と新実装の境界を明文化する
- 互換レイヤ廃止条件を先に定義する

### リスク 2: JSON 成果物がテンプレート更新に追従しない

対策:

- Markdown と JSON の対応表を phase ごとに定義する
- validator で必須キー不足を即 fail にする

### リスク 3: provider adapter が thin wrapper に留まり設計効果が薄い

対策:

- adapter は `ProviderResult` を返す責務まで持たせる
- shell command 実行だけの関数にしない

### リスク 4: event log のみが増え、run-state 再構築が複雑化する

対策:

- `run-state.json` を materialized snapshot として維持する
- event は audit と replay の役割に分ける

## 17. 採用判断

本設計では、まず PowerShell ベースを維持したままアーキテクチャ境界を導入する方針を採用します。

理由:

- 既存資産を最大限活用できる
- 既存運用を壊しにくい
- 再設計の効果を早く確認できる

ただし、次の条件を満たした時点で Python core 移行を再評価します。

- `WorkflowEngine` が明示モジュールとして抽出された
- provider adapter が安定した
- typed artifact が主要 phase に導入された

## 18. 完了条件

再設計が設計どおり完了したと判断できる条件は次です。

- `status.yaml` が source of truth ではなくなる
- engine が次 action を単独で決定する
- provider 切替で engine を変更しない
- validator が JSON artifact を使って判断する
- approval を event として扱える
- fake provider で workflow テストが通る

## 19. 直近の実装優先順位

最初の 3 ステップは次とします。

1. `ProviderAdapter` と `ExecutionRunner` の骨組み追加
2. engine-managed prompt package と `phase3_design.json` / `phase6_result.json` / `phase7_verdict.json` 導入
3. `run-state.json` / `events.jsonl` / canonical artifact store の導入

この順で進めると、既存挙動を大きく崩さずに、
制御面と実行面の分離を始められます。
