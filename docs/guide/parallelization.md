# Parallelization

relay-dev の並列化は、Phase5 以降の task-scoped phase を対象に、互いに干渉しない task を **task group** としてまとめて実行する仕組みです。通常の `step` から自動的に使えることを主動線にしつつ、旧 `parallel-step` は比較・互換用の低レベルコマンドとして残しています。

## 位置づけ

並列化の目的は「速くすること」だけではありません。AI worker が同じ作業ツリーや同じ artifact を同時に触ると、結果の速さよりも再現性と調査性が失われます。そのため relay-dev では、次の制約を満たす task だけを同じ group に入れます。

- task は `parallel_safety: parallel` である
- `dependencies` がすべて完了している
- `resource_locks` が同一 group 内で衝突しない
- `changed_files` が同一 group 内で重ならない
- 現在 phase が Phase5 / Phase5-1 / Phase5-2 / Phase6 のような task-scoped phase である
- `task_lane.mode = parallel` かつ `task_lane.max_parallel_jobs > 1`

`parallel_safety: cautious` は既定では起動しません。運用者が `-AllowCautiousParallelJob` を明示した場合だけ許可されます。`serial` は group には入りません。

## 主動線

`config/settings.yaml` の tracked default は conservative に `execution.mode: single` です。ローカルで並列化を試す場合は `config/settings.local.yaml` のような Git 管理外 config を作り、`-ConfigFile` で指定します。

```yaml
execution:
  mode: auto
  restart_after_sec: 6000
  max_retries: 1
  max_parallel_jobs: 3
  allow_single_parallel_job: false
```

実行は通常どおり `step` です。

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 step -ConfigFile config/settings.local.yaml
```

`execution.mode: auto` または `parallel` のとき、`step` は task-scoped parallel lane で task group を優先します。group を作れない場合は wait reason を残し、通常の single dispatch に fallback します。

## コマンド

| コマンド | 位置づけ |
| --- | --- |
| `step` | 主動線。task group を優先し、作れないときは通常の 1 phase 実行へ戻る |
| `group-step` | task group を明示実行する。package 作成、worker 起動、coordinator、merge / artifact commit まで行う |
| `parallel-step` | 旧 headless batch。1 worker が 1 phase だけ実行する互換・比較用コマンド |
| `run-task-group` | task group package を coordinator で実行する内部寄りコマンド |
| `run-task-group-worker` | coordinator から呼ばれる worker 実行コマンド |

`group-step` は plan-only ではありません。現在は、実行可能な task group があれば最後の merge まで進めます。group が作れない場合は JSON の `status: wait` と `reason` を確認します。

## 実行モデル

task group は、親 run-state と worker の作業を分けて扱います。

```text
cli.ps1 step / group-step
  └─ New-TaskGroupJobPackage
       ├─ candidate selection
       ├─ isolated workspace 作成
       ├─ worker artifact root 作成
       ├─ baseline snapshot 保存
       └─ task_group / task_group_workers を planned / queued として run-state に保存
  └─ Invoke-TaskGroupCoordinator
       ├─ worker process を並列起動
       ├─ 各 worker が Phase5 -> Phase5-1 -> Phase5-2 -> Phase6 を独立実行
       └─ worker_result を集約
  └─ Complete-TaskGroupMergeCommit
       ├─ 全 worker succeeded を確認
       ├─ workspace baseline と changed_files で merge conflict を検出
       ├─ product files を main workspace へ copy
       ├─ worker job artifacts を canonical artifact store に commit
       └─ 各 task_state を completed / Phase6 に更新
```

worker は parent run の canonical artifact を直接 commit しません。worker の出力はまず `runs/<run-id>/jobs/<worker-id>/artifacts/...` に置かれ、group 全体が成功したあとに親が canonical store へ commit します。

## State

task group 関連の正本は `runs/<run-id>/run-state.json` です。

| フィールド | 役割 |
| --- | --- |
| `task_lane.mode` | `single` / `parallel` の lane mode |
| `task_lane.max_parallel_jobs` | 同時 worker 数の上限 |
| `task_groups` | group 単位の状態。`planned` / `running` / `succeeded` / `partial_failed` / `failed` |
| `task_group_workers` | worker 単位の状態。task id、workspace、artifact root、phase、result を持つ |
| `task_states.<id>.status` | task の状態。group package 時に `in_progress`、merge 成功後に `completed` |
| `task_states.<id>.task_group_id` | どの group に属しているか |

同時に active な task group は 1 つに制限しています。`planned` または `running` の group がある間、次の group planning は `task group already active` で wait します。これにより `group A` の merge 前に `group B` が同じ main workspace を前提に走り始める事故を避けます。

## Worker Isolation

各 worker は個別の isolated workspace と artifact root を持ちます。

```text
runs/<run-id>/
├── workspaces/
│   ├── task-worker-.../
│   └── task-worker-.../
└── jobs/
    ├── task-group-.../task-group-package.json
    ├── task-worker-.../artifacts/
    └── task-worker-.../artifacts/
```

worker 起動前に次を検査します。

- `workspace_path` が必須
- `artifact_root` が必須
- workspace と artifact root が同じ場所や親子関係にならない
- sibling worker の workspace / artifact root と重ならない
- ProjectRoot を worker workspace として使わない

この検査は `app/core/task-group-worker-isolation.ps1` にあります。違反すると worker は実行前に fail し、group は merge されません。

## Merge

group merge は all-or-nothing です。

- worker が 1 件でも failed の場合、product file は main workspace に copy しない
- worker artifact が読めない場合、canonical artifact commit はしない
- main workspace の対象 file が baseline から変わっている場合、merge conflict として止める
- changed file が worker 間で重なる場合、merge conflict として止める

merge 成功後にだけ、worker artifacts が canonical artifact store へ commit されます。これにより「一部 worker だけ product file が入ったが artifact はない」という半端な状態を避けます。

## よくあるシーケンス

### group A -> group B

`max_parallel_jobs = 2` で ready task が 4 件ある場合、最初の `step` は `T-01, T-02` を group A として実行します。merge 成功後、次の `step` は残りの `T-03, T-04` を group B として実行できます。

### group -> serial -> group

`T-03` が `parallel_safety: serial` で、`T-01, T-02` に依存している場合:

1. `T-01, T-02` を group で実行
2. merge 成功後、`T-03` が ready になる
3. `T-03` は group に入らず single dispatch で実行
4. `T-03` 完了後、依存していた `T-04, T-05` が ready になり、次の group として実行

この交互実行は `tests/task-group-parallel-sequencing.ps1` で確認しています。

### max_parallel_jobs の変更

`task_lane.max_parallel_jobs` は group candidate 数の上限です。`1` の場合は group を作らず、`2` なら最大 2 worker、`3` なら最大 3 worker を選びます。候補が上限より多い場合、残りは次の `step` で評価されます。

## 観測ポイント

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 show -RunId <run-id>
Get-Content .\runs\<run-id>\run-state.json
Get-Content .\runs\<run-id>\events.jsonl
Get-ChildItem .\runs\<run-id>\jobs
```

見る順番:

1. `show` の lane summary
2. `task_groups` の `status` / `failure_summary`
3. `task_group_workers` の `status` / `current_phase` / `errors`
4. `jobs/<worker-id>/stdout.log` / `stderr.log`
5. `jobs/<worker-id>/artifacts/...`
6. canonical `runs/<run-id>/artifacts/tasks/<task-id>/Phase6/phase6_result.json`

`outputs/` は互換投影です。調査では `runs/<run-id>/...` を正本として扱います。

## トラブルシュート

| 症状 | 主な原因 | 見る場所 |
| --- | --- | --- |
| `status: wait` / `task_lane.mode must be parallel` | lane が single | `config/settings*.yaml`, `run-state.json.task_lane` |
| `task_lane.max_parallel_jobs must be greater than 1` | 並列上限が 1 | `execution.max_parallel_jobs` |
| `fewer than two launchable candidates` | 既定では 1 worker group を作らない | `-AllowSingleParallelJob` または single dispatch fallback |
| `parallel_safety cautious requires explicit cautious opt-in` | cautious task を既定で拒否 | `-AllowCautiousParallelJob` |
| `parallel_safety serial requires non-parallel execution` | serial task は group 不可 | 通常 `step` による single dispatch |
| `task group already active` | 前 group が planned / running | 既存 group の coordinator / worker / merge を確認 |
| group が `partial_failed` | worker の一部が failed | `task_group_workers.<worker>.errors` |
| `merge_failed` | main workspace drift または changed file overlap | `merge.conflicts` |
| `artifact_commit_failed` | worker artifact 不足または canonical commit 失敗 | worker artifact refs と `jobs/<worker-id>/artifacts` |

## 回帰テスト

並列化の主なテストは次です。

| テスト | 見ていること |
| --- | --- |
| `tests/task-group-parallel-planning.ps1` | group candidate 選定、resource lock / changed file conflict |
| `tests/task-group-parallel-package.ps1` | executable package、worker workspace / artifact root |
| `tests/task-group-parallel-worker-loop.ps1` | worker が Phase5〜Phase6 を独立実行すること |
| `tests/task-group-parallel-coordinator.ps1` | coordinator の成功 / partial failure 集約 |
| `tests/task-group-parallel-merge.ps1` | all-or-nothing merge と canonical artifact commit |
| `tests/task-group-parallel-sequencing.ps1` | `max_parallel_jobs`、`group -> group`、`group -> serial -> group` |
| `tests/task-parallelization-headless-execution.ps1` | CLI 経由の `parallel-step` 互換と `step` の task-group 優先 |
| `tests/regression.ps1` | 既存 single step / approval / artifact / recovery の回帰 |

main に入れる前は、少なくとも上記の task-group 系と `regression.ps1` を通します。実運用前には disposable run で `show`、worker logs、canonical artifacts、merge result を確認すると調査しやすくなります。
