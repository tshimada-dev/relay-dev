# Phase5並列ラン監視 調査メモ

- 調査日: 2026-05-12
- 監視対象期間: 2026-05-11
- 対象ラン: `run-20260508-134053`
- ブランチ: `feature/task-parallelization-prep`
- 確認コミット: `c8e89f5`
- 追加対応: `delegated-implementation` 計画 `docs/plans/investigation-residuals-delegated-implementation.json` に基づく未コミット差分

## 概要

Phase5並列化は一部動作確認できている。完了済みタスクレーンはPhase5/Phase6まで進められ、スケジューラ側もタスクごとのphase cursorを見て混在フェーズの候補を扱うための土台が入っている。

一方で、実際のworker実行を監視したことで、lifecycle、merge、recovery、task contractまわりの問題が複数見つかった。制御系の不具合の多くはブランチ上で対応済みで、追加対応により `parallel_safety: cautious` は明示opt-inで起動できるようになり、`show` のblocked理由表示も改善された。Phase6 reject時の非task-scoped rollback、サンプルタスクグラフの依存関係不整合、task contract lint/preflight は未対応として残っている。

## 現在のラン状態

最後に確認した時点で、`run-20260508-134053` は `running` のままだが、active jobもpending approvalも無い状態だった。

- 現在フェーズ: `Phase4`
- 現在ロール: `implementer`
- task lane mode: `parallel`
- max parallel jobs: `2`
- 完了済みタスク:
  - `T-01-storage-contract`
  - `T-02-styles-contract`
- 実行中扱いのタスク:
  - `T-03-readme-usage`
- readyタスク:
  - `T-04-board-shell-and-interactions`
- 未開始タスク:
  - `T-05-static-verification`

現在の実質的な詰まりどころは、`T-03-readme-usage` のcanonical `phase6_result.json` が `verdict: reject` / `rollback_phase: Phase4` を示す一方、`run-state.json` 上では task cursor が `Phase6` に残っていることと、`T-04-board-shell-and-interactions` が `parallel_safety: cautious` のため、デフォルトの `parallel-step` では起動対象にならないこと。追加対応後は、cautious lane は `-AllowCautiousParallelJob` を明示した場合に限り起動できる。

## 確認済み・対応済み

| 問題 | 観測された症状 | 対応内容 | 確認状況 |
| --- | --- | --- | --- |
| worker workspaceにPhase contract artifactが裸で残る | worker jobがworkspace rootやネストした`relay-dev/`配下にcontract fileを出し、親側のartifact syncが拾えなかった | `Sync-PhaseExecutionWorkspaceJobArtifacts`で、裸のartifactやrepo prefix付きartifactを期待されるstaged artifact pathへ回収するようにした | regression test通過 |
| workspace boundary checkの誤検知 | 本来許容すべきcontract artifact、job artifact root、provider probe file、control seed file、ネストした`.git`でmergeが失敗した | `parallel-worker.ps1`と`parallel-workspace.ps1`のboundary除外条件を拡張した | regression / task parallelization系test通過 |
| reviewer-only / product変更なしのtaskでmerge失敗 | `DeclaredChangedFiles` / `AcceptedChangedFiles` が空配列だと拒否された | parallel workspace mergeで空のchanged-file setを許可した | regression / task group merge test通過 |
| Phase5-1 validatorがprovider出力より厳しすぎた | `review_checks.status` の `warning` や `not_applicable` がvalidation failureになった | Phase5-1 validatorで `pass` / `warning` / `fail` / `not_applicable` を許可し、実際の`fail`だけをfail verdict扱いにした | regression test通過 |
| schedulerがglobal phase cursorだけを見ていた | 片方のtaskがPhase6、別taskがPhase5 readyのような混在laneがleaseされなかった | batch leasingで各taskの`phase_cursor`を見るようにした | scheduler regression test通過 |
| active sibling barrierが無かった | 並列jobが残っている間に親が次taskを予約・進行できる可能性があった | `Apply-JobResult`とnext-action logicで、active sibling jobがある間は進行しないようにした | scheduler / ready-recovery test通過 |
| 完了済みtask cursorが再実行される可能性 | stale state後のsingle-step pathで完了済みtask scoped workに再突入し得た | `Get-NextAction`でstale completed cursor rerunを避けるようにした | regression test通過 |
| Phase6 rejectでもtaskがcompletedになる | rejected Phase6 outputにより、taskがcompletedかつrejectedという矛盾状態になった | Phase6 rejectではtaskをcompletedにせず、dispatch前にrejected Phase6 stateをrepairするようにした | recovery test通過 |
| recoverable failed runが一貫してretryされない | commit rejectionやworkspace boundary failure後に手動cleanupが必要だった | `parallel-step` / `step`のdispatch前にstale/orphan/rejected-Phase6 recoveryを走らせ、failed recovery対象にcommit rejected / workspace boundary系を含めた | regression test通過 |
| orphaned in-progress taskでstallする | active jobが無いのにtaskが`in_progress`のまま残ることがあった | orphaned in-progress task repairを追加した | ready-recovery test通過 |
| cautious laneを明示起動できない | `parallel_safety: cautious` taskがdefault `parallel-step`ではpackage化されず、operatorに安全なoverride手段が無かった | `parallel-step` / auto `step` に `-AllowCautiousParallelJob` を追加し、defaultはstrictのままcautiousのみ明示opt-inで許可するようにした。`serial` は引き続き拒否する | package / headless execution test通過 |
| candidate rejection reasonの表示が弱い | cautious / serial / dependency / capacity / non-task phase などの理由が `show` から分かりづらかった | lane summaryに `launch_block_reason` と `operator_hint` を追加し、cautious opt-in、serial、dependency、capacity、active job、non-task-scoped phaseを説明するようにした | ready-ui / task-group-ui test通過 |

## 一部緩和済み

| 問題 | 現在の状態 | 残るリスク |
| --- | --- | --- |
| run state側のdependency情報が古くなる | dispatch eligibilityでtask state dependencyとtask contract artifactから読んだdependencyを統合するようになった | 既存runではrun stateとcontractの不整合が残り得るため、`show`やoperator guidanceでどちらを根拠にしているか見えづらい |
| worker commit / recovery挙動 | run statusが`running`でない場合はcommit fenceが拒否し、cleanupでlease解除とfailed state書き込みを行うようになった | cancelやworker中断時のend-to-end観測はまだ不足している |
| Phase6 reject recoveryの扱い | task-scoped rollback (`Phase5`など) は stale `in_progress` / `Phase6` cursor からrepairされることをテストで明確化した | `Phase4` のような非task-scoped rollbackはrun-level設計課題として残る |

## 未対応・改善候補

| 問題 | 根拠 | 次の対応案 | 優先度 |
| --- | --- | --- | --- |
| Phase6 reject時のrollback粒度が粗い | `T-03-readme-usage` はmissing companion scriptによりPhase6 rejectされ、canonical artifactは `rollback_phase: Phase4` を示す | README-onlyやmissing companion fileのようなケースでは、task-localかつphase-specificなrollbackにする。非task-scoped rollbackを自動repairする場合は別途run-level recovery設計が必要 | 高 |
| task contractの依存関係表現が不足 | `T-03-readme-usage` が `examples/parallel_smoke_system/tests/verify-static.ps1` を参照しているが、Phase6時点で存在しなかった | task contract lint/preflightを追加し、参照する検証fileがtask自身のchanged_filesにも依存taskの成果物にも無い場合に検出する | 高 |
| `T-04` dependency情報が不整合 | current run state上では`T-04`の依存が`T-01`のみだが、open requirementでは`T-02`も必要 | Phase3/Phase4のtask contractとrun-state dependencyを再整合する | 高 |
| `T-05` dependencyとparallel policyが過剰に直列化されている可能性 | `T-05-static-verification` は `T-01`から`T-04`までに依存し、まだ`not_started` | `T-05`をfinal serial verification taskとして扱うのか、明示依存付きのparallel-safe laneにするのか再検討する | 中 |
| `show`がrunning-but-idle rollback状態を完全には説明しきれない | runは`running`、active jobなし、Phase4、task lane側は非task-scoped rollback artifactを持つ、という状態になり得る | `launch_block_reason` / `operator_hint` は追加済み。残るrollback artifact由来の説明や推奨command表示を強化する | 中 |
| worklogや調査文脈がprovider jobに上書き・混線される可能性 | 親の調査文脈とprovider生成artifactが近い場所にある | human/control-plane docsをworker出力から保護するか、人間用worklogと生成artifactをより明確に分ける | 中 |
| phase historyが読みにくい | Phase6 reject後にPhase4 startedが残り、taskには`last_completed_phase: Phase6`が残るように見える | display側で正規化するか、明示的なrejected/rollback metadataを出す | 低 |

## 確認できた並列動作

現時点のブランチでは、group型の並列実行に向けた制御系の土台は確認できている。

- worker jobがtask scopedなPhase5/Phase6を独立して実行できる。
- 親側merge logicが、期待されるrelay-dev artifactをboundary violationとして扱わずに取り込める。
- schedulerがglobal phaseではなく、task laneごとのcursorを見て候補判定できる。
- active sibling jobが残っている間、親が依存taskや後続taskへ進みすぎないようbarrierできる。

ただし、ユーザー図のworker-lane architectureが完全に実装済みという状態ではない。残る差分は、task grouping semantics、eligible lane判定、cautious laneの扱い、そして「全workerがPhase6 passするまでをgroupの一処理とみなす」完了判定の明確化にある。

## 推奨される次の作業

1. 次の長時間監視前に、現在のサンプルタスクグラフを修正する。
   - missingしている`verify-static.ps1`の担当taskを追加または再割当する。
   - `T-04`のdependencyに`T-02`を反映する。
   - `T-05`をserial final verificationにするかparallel-safe laneにするか決める。
2. task contract preflight/lintを追加する。
   - 参照file missing。
   - run stateとcontract artifactのdependency不一致。
   - 具体理由のない`parallel_safety: cautious`。
3. operator visibilityをさらに改善する。
   - rollback artifact由来の原因を表示する。
   - `running`だがidleのときに次の有効commandを表示する。
4. cautious lane policyの運用を固める。
   - 実装済みのstrict default + `-AllowCautiousParallelJob` を使う。
   - 併せて、自動分類を改善して本当に危険なlaneだけcautiousにする。
5. タスクグラフと表示改善後、再度runを起動して監視する。

## 参照先

- Run state: `runs/run-20260508-134053/run-state.json`
- Events: `runs/run-20260508-134053/events.jsonl`
- Jobs: `runs/run-20260508-134053/jobs/`
- Artifacts: `runs/run-20260508-134053/artifacts/`
- 関連テスト:
  - `tests/regression.ps1`
  - `tests/task-parallelization-scheduler.ps1`
  - `tests/task-parallelization-ready-recovery.ps1`
  - `tests/task-parallelization-ready-ui.ps1`
  - `tests/task-parallelization-headless-execution.ps1`
  - `tests/task-group-parallel-artifacts.ps1`
  - `tests/task-group-parallel-merge.ps1`
  - `tests/task-group-parallel-package.ps1`
  - `tests/task-group-parallel-ui.ps1`
