# Current Handoff

## Goal
`run-20260508-134053` で Phase5 task lane の auto parallel 実行を実測し、問題が出るたびに原因修正、再開、再確認する。

## Current State
- T-02 / T-03 の Phase5 implementer は `parallel-step` で同時 lease / dispatch / commit 済み。
- T-02 / T-03 の Phase5-1 reviewer、Phase5-2 reviewer も同時 lease / dispatch 済み。空 product changes、loose/job-scoped artifacts、provider probe scratch を扱えるよう修正済み。
- mixed phase lease も確認済み。T-02 Phase6 と T-03 Phase5 が同一 batch に載った。
- T-03 の Phase6 commit rejection (`relay-dev/.git/index`) は nested git metadata exclude で解消し、同じ run で retry 成功済み。
- Phase6 reject lifecycle の bug を修正。`verdict: reject` の Phase6 artifact が task を completed にしてしまう問題を直し、既存 corrupted state は `phase6_reject_rollback` recovery で再開できるようにした。
- 最新の `run-20260508-134053` は T-03 Phase6 が product/task-level reject し、artifact の `rollback_phase: Phase4` に従って Phase4 に戻った状態。T-03 は completed ではなく `in_progress` のまま保持されている。
- 現在残っている blocker は T-03 README task が `examples/parallel_smoke_system/tests/verify-static.ps1` 不在を Phase6 で reject していること。これは parallel 基盤ではなく sample task / task contract 側の問題。

## Fixes Made
- `Sync-PhaseExecutionWorkspaceJobArtifacts` が workspace root の loose contract artifacts を job/attempt artifact storage へ回収するよう拡張。
- workspace boundary が phase output contract files、job-scoped artifact roots、provider probe files、control-plane seed、nested `.git` metadata を product changes と誤判定しないよう調整。
- empty `DeclaredChangedFiles` / `AcceptedChangedFiles` を valid reviewer case として許可。
- scheduler が task-local `phase_cursor` を優先し、global phase と異なる Phase6/Phase5 などの mixed phase candidates を lease できるよう修正。
- mixed-phase active sibling が残っている間に次 task を未 lease のまま `in_progress` へ進めない barrier を追加。
- single-step が completed task の stale `current_task_id` を再 dispatch しないよう防御。
- Phase5-1 verdict validator が non-blocking `warning` / `not_applicable` review checks を受け入れるよう修正。
- Phase6 reject では task を completed にせず、rollback が task-scoped の場合は lane cursor を rollback phase へ戻すよう修正。
- 既に corrupted な `completed + Phase6 reject artifact` 状態を `step` / `parallel-step` 前処理で修復する recovery を追加。

## Verified
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\regression.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\task-parallelization-scheduler.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\task-parallelization-ready-recovery.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\task-group-parallel-artifacts.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\task-group-parallel-merge.ps1`

## Next Step
Parallel substrate の確認としては十分。run を完成まで進めるなら、Phase4 へ戻った task contract を整理し、T-03 の Phase6 reject 理由である `examples/parallel_smoke_system/tests/verify-static.ps1` と companion files を揃える。T-04 は `parallel_safety: cautious` のため default `parallel-step` では起動しない。

## Watch Outs
- `parallel-step` は default では `parallel_safety: parallel` のみ package 化する。T-04 は `cautious` なので候補表示はされるが launchability で rejected になる。
- `tests/regression.ps1` 実行で `outputs/phase0_context.*` など既存 dirty files が触れている。未関連差分を巻き戻さないこと。
