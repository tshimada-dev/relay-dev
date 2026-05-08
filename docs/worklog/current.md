## 2026-05-08 15:21 JST - auto parallel step デフォルト化

- Summary: `execution.mode: auto` を既定にし、`app/cli.ps1 step` が task-scoped parallel lane では `parallel-step` を優先するようにした。run-scoped phase と安全に並列化できない task は single dispatch へ fallback する。
- Changed: `lib/settings.ps1`, `config/settings.yaml`, `app/core/workflow-engine.ps1`, `app/cli.ps1`, `agent-loop.ps1`, `tests/task-parallelization-headless-execution.ps1`, `README.md`, `docs/worklog/current.md`, `docs/worklog/2026-05-08.md`。
- Verified: syntax parse check, `tests/task-parallelization-headless-execution.ps1`, `tests/task-parallelization-ready-runstate.ps1`, `tests/task-parallelization-ready-scheduler.ps1`, `tests/task-parallelization-ready-ui.ps1`, `tests/task-parallelization-scheduler.ps1`, `tests/task-parallelization-prep.ps1`, `tests/regression.ps1` が pass。
- Remaining: 停止中の `run-20260508-134053` は state 上に stale single-step active job が残っているため、再開時は stale recovery 後に auto parallel lane へ同期される想定。

## 2026-05-08 15:43 JST - stale recovery 後の auto lane 確認

- Summary: `run-20260508-134053` を `step` で再開し、stale single-step job の回収後に task lane が `parallel` / `max_parallel_jobs=2` へ同期されることを確認した。併せて heartbeat stale 判定と batch candidate phase の誤昇格を修正した。
- Changed: `app/core/workflow-engine.ps1`, `tests/task-parallelization-scheduler.ps1`, `docs/worklog/current.md`, `docs/worklog/2026-05-08.md`。
- Verified: syntax parse check, `tests/task-parallelization-scheduler.ps1`, `tests/task-parallelization-ready-ui.ps1`, `tests/task-parallelization-ready-recovery.ps1`, `tests/task-parallelization-headless-execution.ps1` が pass。`app/cli.ps1 show -RunId run-20260508-134053` で `task_lane.mode=parallel`, `active_jobs={}`, `lease_candidates=[]` を確認。
- Remaining: 現在の run は `T-01-storage-contract` の `Phase5-1 reviewer` にいるため並列 job は未起動。次に `Phase5 implementer` へ戻った時点で T-02/T-03 が auto parallel lane の対象になる想定。
