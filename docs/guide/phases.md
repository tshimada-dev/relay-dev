# Phases

relay-dev のフェーズは、**implementer が成果物を生み、reviewer が gate を作る**という非対称な構成になっています。本書では各 phase の役割、入出力 contract、遷移ルールを整理します。

実体は `app/phases/phase-registry.ps1`、`app/phases/phase*.ps1`、`app/prompts/phases/*.md` にあります。

## 全体フロー

```text
Phase0 ──► Phase1 ──► Phase3 ──► Phase3-1
            │
            └──► Phase2 (clarification fallback) ──► Phase0 へ戻る
                                                   │
                                       Phase4 ──► Phase4-1
                                                   │
                                       Phase5 ──► Phase5-1 ──► Phase5-2
                                                   │
                                       (invalid_artifact ──► repairer lane)
                                                   │
                                       Phase6 ──► Phase7 ──► Phase7-1 ──► Phase8
```

## Role 割り当て

| Role | 担当 phase |
| --- | --- |
| `implementer` | Phase0, Phase1, Phase2, Phase3, Phase4, Phase5, Phase7-1, Phase8 |
| `reviewer` | Phase3-1, Phase4-1, Phase5-1, Phase5-2, Phase6, Phase7 |
| `repairer` | （phase 固定ではない）validator が落ちた artifact を持つ任意 phase |

system prompt は `app/prompts/system/{implementer,reviewer,repairer}.md` で role ごとに分離。phase prompt は `app/prompts/phases/phaseX.md` で per-phase に定義し、`phase-execution-transaction` が両者を組み立てて provider に渡します。

## Phase 別サマリー

### Phase0 — 共通前提の整備

- 入力: `tasks/task.md`、optional `DESIGN.md`
- 出力: `phase0_context.md`（人間向け）、`phase0_context.json`（構造化 contract）
- ポイント:
  - run 開始前に `outputs/phase0_context.{md,json}` が validator を通る場合は **import** されて Phase0 はスキップ。再生成を強制しない。
  - JSON には `project_summary` / `constraints` / `non_goals` に加え、UI 案件では `design_inputs` / `visual_constraints` を載せる。
- canonical: `runs/<run-id>/artifacts/run/Phase0/phase0_context.{md,json}`

### Phase1 — Requirements 化

- 入力: Phase0 artifact
- 出力: `phase1_requirements.md` / `.json`（acceptance criteria を含む）
- ポイント:
  - UI 案件では `visual_constraints` から `visual_acceptance_criteria` を生成。
  - `unresolved_questions` が空なら Phase3 へ直接進む。残っていれば Phase2 へ。

### Phase2 — Clarification fallback

- 入力: Phase1 artifact + 既存の `tasks/task.md` / Phase0 seed
- 出力: `phase2_info_gathering.md` / `.json`
- ポイント:
  - `unresolved_blockers` が残るとその場で **human pause**。`relay-dev-phase2-clarifier` で対話回収。
  - 解消後は `tasks/task.md` と Phase0 seed を更新し、`y` で **Phase0 から再開**（要件起点で再ハードニングする思想）。

### Phase3 — Design

- 入力: Phase1 artifact
- 出力: `phase3_design.md` / `.json`、UI 案件では `visual_contract` を含む
- 設計境界 contract: `module_boundaries` / `public_interfaces` / `allowed_dependencies` / `forbidden_dependencies` / `side_effect_boundaries` / `state_ownership`

### Phase3-1 — Design review

- Reviewer が Phase3 の設計境界を点検。
- 出力: `phase3-1_design_review.md` / `phase3-1_verdict.json`
- 出力 verdict: `go` / `conditional_go` / `reject`。`conditional_go` は Phase3 を詰め直し、`reject` は `rollback_phase` に応じて Phase1 または Phase3 に戻る。
- human approval gate（既定有効）。

### Phase4 — Task breakdown

- 入力: Phase3 artifact
- 出力: `phase4_task_breakdown.md` / `phase4_tasks.json`
- 各 task は **`boundary_contract`** を持ち、変更してよい module / interface を絞る。UI task では `visual_contract` も task 単位に落とす。

### Phase4-1 — Task review

- 出力: `phase4-1_task_review.md` / `phase4-1_verdict.json`
- Reviewer が task 分割と `boundary_contract` の妥当性を確認。`go` で Phase5 へ、`conditional_go` は Phase4 の詰め直し、`reject` は Phase3 または Phase4 へ rollback。
- human approval gate（既定有効）。

### Phase5 — Implementation

- 入力: Phase4 task のうち未完了の 1 件
- 出力: 実装変更 + `phase5_implementation.md` / `phase5_result.json`
- ポイント:
  - **task の `boundary_contract` を拘束条件として実装**。
  - `Selected Task.open_requirement_overlay.items[]` がある場合、それを engine が relevant open requirements から蒸留した task-scoped addendum として扱う。
  - `commands_run` は doc-only / infra-only task でも空にできない。最低 1 件の実行コマンドを artifact に残す。
  - artifact には実装サマリ、変更ファイル、テスト結果を構造化して載せる。

### Phase5-1 — Implementation review

- 出力: `phase5-1_completion_check.md` / `phase5-1_verdict.json`
- Reviewer が `boundary_contract` と `visual_contract` への準拠を **証拠付き** で確認。越境（forbidden dependency 追加など）を検出すると `reject`。
- この phase の verdict は `go` / `reject` のみで、`conditional_go` は validator が受け付けない。

### Phase5-2 — Quality reviewer

- 出力: `phase5-2_security_check.md` / `phase5-2_verdict.json`
- 静的に拾える品質指標（test、security_check、style 等）を構造化 verdict として確定する。
- `go` は `security_checks` が `pass` / `not_applicable` のみのときに限る。`conditional_go` は warning を含むが fail を含まない場合にだけ許可され、`must_fix` と `open_requirements` を 1 件以上伴う。

### Phase6 — Holistic testing

- 入力: 全 task の Phase5 系成果
- 出力: `phase6_testing.md` / `phase6_result.json` / `test_output.log`
- optional 出力: `junit.xml` / `coverage.json`
- reviewer は `verification_checks`、`tests_failed`、`open_requirements`、`resolved_requirement_ids` を正直に書く。top-level `verdict` は最終的に `verdict-finalizer.ps1` が canonical に寄せる。
- canonical verdict の規則は実装準拠で、`tests_failed > 0` または verification の `fail` を含めば `reject`、warning または `open_requirements` が残れば `conditional_go`、それ以外は `go`。
- `go` / `conditional_go` のあと、未完了 task が残っていれば次の ready task で Phase5 に戻り、全 task 完了後に Phase7 へ進む。`reject` は Phase3 / Phase4 / Phase5 のいずれかへ rollback。

### Phase7 — Pre-PR review

- 入力: Phase5/6 成果
- 出力: `phase7_pr_review.md` / `phase7_verdict.json`
- `conditional_go` の場合は `must_fix[]` と `follow_up_tasks[]` が 1 件以上必須。`follow_up_tasks[]` が canonical な repair task source になり、workflow engine が Phase5 向けの repair task として登録する。
- `go` を選ぶ場合、run-state 上の `open_requirements` を残せない。残っていると workflow engine が run を `failed` に倒して `unresolved_open_requirements` として止める。
- human approval gate（既定有効）。

### Phase7-1 — PR summary

- 出力: `phase7-1_pr_summary.md` / `phase7-1_summary.json`
- Implementer が Phase7 verdict を踏まえて PR description を構築する。

### Phase8 — Release

- 出力: `phase8_release.md` / `.json`
- run を `completed` 状態へ遷移させ、`runs/<run-id>/` 全体を sealed として扱う。

## Artifact contract のかたち

すべての phase で `*.md`（人間向け要約）と `*.json`（schema-enforced contract）の **2 種ペア** で出力します。JSON は `app/core/artifact-validator.ps1` の schema を通り、後段 phase / reviewer / repairer の入力になります。

```text
runs/<run-id>/artifacts/
├── run/
│   ├── Phase0/phase0_context.{md,json}
│   ├── Phase1/phase1_requirements.{md,json}
│   ├── Phase3/phase3_design.{md,json}
│   ├── Phase3-1/phase3-1_design_review.md
│   ├── Phase3-1/phase3-1_verdict.json
│   ├── Phase4/phase4_task_breakdown.md
│   ├── Phase4/phase4_tasks.json
│   ├── Phase4-1/phase4-1_task_review.md
│   ├── Phase4-1/phase4-1_verdict.json
│   ├── Phase7/phase7_pr_review.md
│   ├── Phase7/phase7_verdict.json
│   ├── Phase7-1/phase7-1_pr_summary.md
│   ├── Phase7-1/phase7-1_summary.json
│   └── Phase8/phase8_release.{md,json}
└── tasks/<task-id>/
    ├── Phase5/phase5_implementation.md
    ├── Phase5/phase5_result.json
    ├── Phase5-1/phase5-1_completion_check.md
    ├── Phase5-1/phase5-1_verdict.json
    ├── Phase5-2/phase5-2_security_check.md
    ├── Phase5-2/phase5-2_verdict.json
    ├── Phase6/phase6_testing.md
    ├── Phase6/phase6_result.json
    └── Phase6/test_output.log
```

## 遷移とゲートの組み合わせ

- `unresolved_questions` / `unresolved_blockers` の有無で Phase1 → Phase3 か Phase2 か分岐。
- reviewer の verdict は原則 `go` / `conditional_go` / `reject` で、Phase5-1 だけは `go` / `reject` のみ。
- Phase5 / Phase5-2 / Phase6 / Phase7 では `open_requirements` / `resolved_requirement_ids` が run-state に反映され、carry-forward 条件の closure authority は最終的に Phase7 が持つ。
- `human_review.phases` に列挙された phase では追加で対話 gate が走る。

詳細な遷移ルールは `app/core/transition-resolver.ps1` と各 `phase*.ps1` を参照してください。
