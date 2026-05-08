# Task Parallelization Preparation Plan

## 1. 目的

この計画書の目的は、relay-dev に task 並列実行を入れる前に、既存の直列実行を保ったまま control plane を並列化に耐える構造へ整理することである。

ここで狙うのは `max_parallel_jobs > 1` の即時実装ではない。
まずは `max_parallel_jobs = 1` のまま、次を達成する。

- job lifecycle を `lease -> execute -> commit` に分ける
- `active_job_id` 単数前提を `active_jobs` に寄せる
- task ごとの `phase_cursor` を導入する
- commit を transaction として扱う
- monitor / show が multi-job state を読めるようにする
- 将来の stale job recovery / approval block / workspace 分離の受け皿を作る

## 2. 背景

task 並列実行の構想は [task-parallel-execution-proposal.md](../ideas/task-parallel-execution-proposal.md) に整理されている。

構想上は Phase5 から Phase6 の task lane が並列化対象になる。
ただし、現行実装は次の点で直列前提が強い。

- `run-state.json` が `current_phase` / `current_task_id` / `active_job_id` を単数で持つ
- `Get-NextAction` は 1 件の `DispatchJob` だけを返す
- `cli.ps1 step` が dispatch、provider execution、validation、commit を同期的に持つ
- `run.lock` が step 全体を直列化する
- approval が `pending_approval` 1 件を前提にしている
- monitor / dashboard / summary が current job 1 件を前提にしている

この状態で並列 execution だけを足すと、古い job の後追い commit、approval 待ちの衝突、workspace 競合、monitor 不透明化が起きやすい。
したがって、先に直列互換のリファクタリングを行う。

## 3. 非目標

- `max_parallel_jobs > 1` を正式運用すること
- same-workspace 並列実行を default にすること
- isolated workspace / git worktree merge-back を完成させること
- visible worker terminal を slot 数ぶん起動すること
- `pending_approvals` に完全移行すること
- `current_phase` / `current_task_id` / `active_job_id` 互換 view を即撤去すること

## 4. 設計原則

### 原則 1: 直列動作を保ったまま構造を変える

各段階の完了時点で、既存の `cli.ps1 step` は従来通り 1 job ずつ進む。
外部挙動を大きく変えず、内部境界だけを並列前提に近づける。

### 原則 2: single writer を維持する

`events.jsonl` と `run-state.json` の書き込み主体は引き続き control plane に限定する。
worker / provider は job result を返すだけで、canonical state を直接更新しない。

### 原則 3: commit を正本化の唯一の入口にする

provider execution の完了は phase 完了ではない。
job-scoped / attempt-scoped artifact の validation、canonical artifact への昇格、event append、run-state 更新、lease 解除を commit transaction に集約する。

### 原則 4: 互換 view を明示的に残す

`current_phase` / `current_task_id` / `active_job_id` は既存 UI、compatibility projection、agent-loop、tests で読まれている。
新 state を正本候補にしつつ、古い field は当面 projection として維持する。

### 原則 5: monitor を先に multi-job 対応に慣らす

実際の並列実行より先に、`active_jobs`、task lane summary、wait reason、stale job 候補を表示できるようにする。
これにより、並列化後の運用不透明性を下げる。

## 5. 目標アーキテクチャ

準備完了時点の shape は次のようにする。

```json
{
  "current_phase": "Phase5",
  "current_task_id": "T-01",
  "active_job_id": "job-001",
  "state_revision": 42,
  "active_jobs": {
    "job-001": {
      "job_id": "job-001",
      "task_id": "T-01",
      "phase": "Phase5",
      "role": "implementer",
      "lease_token": "lease-001",
      "leased_at": "2026-05-08T10:00:00+09:00",
      "lease_expires_at": "2026-05-08T10:20:00+09:00",
      "last_heartbeat_at": "2026-05-08T10:05:00+09:00",
      "lease_owner": "single-step",
      "slot_id": "slot-01",
      "workspace_id": "main",
      "state_revision": 42
    }
  },
  "task_lane": {
    "mode": "single",
    "max_parallel_jobs": 1,
    "stop_leasing": false
  },
  "task_states": {
    "T-01": {
      "status": "in_progress",
      "phase_cursor": "Phase5",
      "active_job_id": "job-001",
      "wait_reason": null
    }
  }
}
```

この段階では `active_jobs` の件数は最大 1 のままでよい。
重要なのは、state / event / monitor / commit path が複数 job を表現できる形に寄っていることである。

## 6. 実装タスク分解

## Step 1: RunState schema を並列前提に拡張する

目的:

- `active_jobs` と `task_lane` を追加する
- `state_revision` を追加する
- `task_states[].phase_cursor` / `active_job_id` / `wait_reason` を追加する
- 既存の `active_job_id` は `active_jobs` から導出される互換 view として扱えるようにする

変更候補:

- `app/core/run-state-store.ps1`
- `app/core/workflow-engine.ps1`
- `app/core/event-store.ps1`
- `tests/regression.ps1`

受け入れ条件:

- 新規 run の state に `active_jobs` / `task_lane` / `state_revision` が存在する
- 既存の直列 step が壊れない
- `active_job_id` を読む既存コードが従来通り動く
- `state_revision` が state write ごとに単調増加する

## Step 2: Single-job lease model を導入する

目的:

- dispatch 時に `active_jobs[job_id]` を作る
- `lease_token` / `lease_expires_at` / `last_heartbeat_at` を job metadata に持たせる
- `task_states[task_id].active_job_id` と `active_jobs[job_id]` を同じ lock 内で更新する
- まだ worker pool は作らず、`cli.ps1 step` 内で lease してそのまま execute する

変更候補:

- `app/core/workflow-engine.ps1`
- `app/cli.ps1`
- `app/core/run-lock.ps1`
- `app/core/run-state-store.ps1`

受け入れ条件:

- 1 step につき active job は最大 1 件
- lease 作成後に `job.leased` event が出る
- lease token が job result / commit path に渡る
- 既存の failed recovery が active job 単数だけでなく `active_jobs` も見られる

## Step 3: Execute と commit の境界を分ける

目的:

- provider execution の完了と canonical commit を分離する
- `Invoke-EngineStep` 内の責務を `lease`, `execute`, `commit` の関数境界へ寄せる
- commit 開始時に最新 state を再読込する
- lease fencing を検証してから artifact promotion / state transition を行う

変更候補:

- `app/cli.ps1`
- `app/core/phase-execution-transaction.ps1`
- `app/core/phase-completion-committer.ps1`
- `app/core/phase-validation-pipeline.ps1`
- `app/core/workflow-engine.ps1`

受け入れ条件:

- `execute` が成功しても、commit fencing に失敗した job は canonical artifact を更新しない
- commit 成功時に `job.committed` event が出る
- commit 拒否時に `job.commit_rejected` event が出る
- validation failure / repairer flow が従来通り動く

## Step 4: Task phase cursor を正本候補にする

目的:

- Phase5 から Phase6 の task-scoped phase では `task_states[task_id].phase_cursor` を更新する
- `current_phase` / `current_task_id` は coarse view / compatibility view として残す
- task-local rollback のための状態更新を task state 側へ寄せる

変更候補:

- `app/core/workflow-engine.ps1`
- `app/core/transition-resolver.ps1`
- `app/core/run-state-store.ps1`
- `app/cli.ps1`

受け入れ条件:

- Phase4-1 go 後、選択 task の `phase_cursor` が Phase5 になる
- Phase5 -> Phase5-1 -> Phase5-2 -> Phase6 の進行が task state に反映される
- Phase6 go で task が completed になり、次 task または Phase7 へ従来通り進む
- 既存 dashboard / status projection が従来相当の表示を維持する

## Step 5: Commit transaction を明示化する

目的:

- job-scoped / attempt-scoped artifact の validation
- canonical artifact promotion
- phase transition / task transition
- event append
- run-state write
- active job / lease clear

これらを commit transaction の一連の責務としてまとめる。

変更候補:

- `app/core/phase-completion-committer.ps1`
- `app/core/phase-execution-transaction.ps1`
- `app/core/artifact-repository.ps1`
- `app/core/workflow-engine.ps1`

受け入れ条件:

- commit 中に失敗しても canonical artifact が中途半端に更新されない
- active job clear は event / state update と整合する
- expired lease の commit は拒否される
- stale job artifact は forensic として残せる

## Step 6: Monitor / show の集約ロジックを分離する

目的:

- `run-state.json` と `events.jsonl` から task lane summary を作る helper を追加する
- `cli.ps1 show`、`watch-run.ps1`、`dashboard-renderer.ps1`、`run-summary-renderer.ps1` が同じ summary を使えるようにする
- 実際の並列実行前から `active_jobs` / wait reason / stale job を見える化する

変更候補:

- `app/ui/run-summary-renderer.ps1`
- `app/ui/dashboard-renderer.ps1`
- `watch-run.ps1`
- `app/cli.ps1`
- 新規 `app/ui/task-lane-summary.ps1`

受け入れ条件:

- `show` が active jobs と task lane counts を表示できる
- `watch-run` が current job 単数だけに依存しない
- stale lease / approval wait / dependency wait の表示枠がある
- renderer が独自推論せず summary helper を読む

## Step 7: Approval block の互換設計を入れる

目的:

- 初期版では approval 発生時に `task_lane.stop_leasing = true` を立てる
- `pending_approval` 単数は維持しつつ、将来の `pending_approvals` への移行先を state に用意する
- approval 待ち task に `wait_reason: approval` を出せるようにする

変更候補:

- `app/approval/approval-manager.ps1`
- `app/approval/terminal-adapter.ps1`
- `app/core/workflow-engine.ps1`
- `app/core/run-state-store.ps1`

受け入れ条件:

- approval requested 時に新規 lease が止まる
- approval resolved 後に `stop_leasing` が解除される
- approval 対象 task / phase が monitor に表示される
- 既存 terminal approval flow が壊れない

## Step 8: Regression coverage を並列準備観点へ拡張する

目的:

- 実際には single job でも、multi-job state に耐える回帰を追加する
- lease fencing / commit rejection / stale recovery / monitor summary をテストする

テスト候補:

- 新規 run state に `active_jobs` / `task_lane` がある
- 2 回 lease を試みても同じ task を二重 lease しない
- lease token 不一致の commit が拒否される
- expired lease の commit が拒否される
- commit 成功後に `active_jobs` が空になる
- task `phase_cursor` が Phase5-6 の遷移に追随する
- approval 中に `stop_leasing` が有効になる
- `show` / `watch-run` summary が active job を表示する

変更候補:

- `tests/regression.ps1`
- fake provider fixtures
- temporary run-state fixtures

## 7. 推奨実装順

最初の実装スライスは次の順で小さく切る。

1. `RunState` に `active_jobs` / `task_lane` / `state_revision` を追加する
2. `active_job_id` を `active_jobs` 由来の互換 view に寄せる
3. single-job lease metadata を作り、`job.leased` event を出す
4. commit path に lease token 検証を追加する
5. `task_states[].phase_cursor` を Phase5-6 に導入する
6. `show` に active jobs / task lane summary を出す
7. approval 時の `stop_leasing` を導入する
8. regression を追加してから `lease -> execute -> commit` の関数境界をさらに細くする

この順なら、途中で止めても直列実行の品質改善として価値が残る。

## 8. 受け入れ条件

P0:

- `cli.ps1 step` の既存直列フローがすべて通る
- `run-state.json` が future-proof field を持つ
- `active_jobs` と `active_job_id` の整合が取れている
- commit は lease token を検証する
- stale / expired job の commit が canonical artifact を更新しない

P1:

- Phase5-6 の task cursor が task state に反映される
- `show` / `watch-run` が active jobs と task lane summary を表示できる
- approval 待ちで `stop_leasing` を表現できる
- regression tests が lease / commit / monitor の主要ケースを覆う

P2:

- `Invoke-EngineStep` の内部責務が `lease`, `execute`, `commit` へ分かれている
- worker pool を後から差し込める関数境界がある
- same-workspace 並列や isolated workspace を実装しなくても、設計上の置き場が明確になっている

## 9. リスクと注意点

### R-01. 互換 field の二重正本化

`active_jobs` と `active_job_id`、`phase_cursor` と `current_phase` が同時に存在すると二重正本になりやすい。
互換 field は projection として扱い、どちらからどちらを導出するかを関数に閉じ込める。

### R-02. commit transaction の肥大化

commit に責務を集めすぎると、巨大な関数になる。
transaction の外形は一箇所に置き、validation、artifact promotion、state transition、event append は小さな helper に分ける。

### R-03. approval scope の過早な一般化

最初から複数 approval を完全サポートしようとすると大きくなる。
準備段階では `pending_approval` 単数 + `stop_leasing` に留め、`pending_approvals` は schema 予約または別計画に分ける。

### R-04. same-workspace 並列への早すぎる移行

この計画の完了は same-workspace 並列の解禁を意味しない。
実際の並列 execution は、actual diff guard、resource lock、workspace isolation の設計が揃ってから判断する。

## 10. 次の計画への接続

この準備プランが完了した後に、次の計画へ進む。

1. Conservative parallel scheduler plan
   - `max_parallel_jobs > 1`
   - ready queue
   - resource lock
   - same-workspace 実験 mode

2. Isolated workspace execution plan
   - per-task workspace
   - serial merge-back
   - merge conflict / rebase queue

3. Visible worker slot launcher plan
   - monitor + control + worker slot tabs
   - slot title update
   - worker slot lifecycle

## 11. 結論

優先すべきは、並列実行そのものではなく **single-job lease/commit model** への整理である。

この整理により、直列運用のままでも recovery、monitor、state の明瞭さが上がる。
さらに、後続の task lane parallel、workspace isolation、visible worker slot を入れる時に、危険な大改造を避けられる。
