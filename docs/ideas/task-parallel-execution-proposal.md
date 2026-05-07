# relay-dev タスク並列実行 構想案

## 1. 背景

relay-dev はかなり整理されてきており、特に Phase4 以降は「task を構造化 contract として定義し、その task-scoped artifact を後段に流す」という形ができている。

実際、

- `phase4_tasks.json` には `dependencies[]` がある
- validator は dependency cycle を検出できる
- Phase5 / Phase5-1 / Phase5-2 / Phase6 の成果物は task-scoped に保存される
- `boundary_contract` / `visual_contract` により task ごとの責務境界も持てている

ので、**task lane を並列化する土台自体は既にある**。

一方で、現行実装は次の理由で実行自体は直列になっている。

- `run-state.json` が `current_phase` / `current_task_id` / `active_job_id` を単数で持つ
- `Get-NextAction` は 1 回に 1 件の `DispatchJob` しか返さない
- `cli.ps1 step` は `dispatch -> execute -> validate -> commit` を 1 本の同期処理として持つ
- `run.lock` は step 全体を直列化する
- provider job は同一 workspace を前提に動く

つまり、**DAG はあるが scheduler と workspace model がまだ直列前提**というのが現在地である。

## 2. 先に結論

relay-dev の並列化は可能だが、単に `dependencies[]` を見るだけでは足りない。

実現方針としては次がよい。

1. **run-scoped phase は直列のまま維持**する
2. **Phase5 から Phase6 までの task lane だけを並列化**する
3. **single writer の原則は維持**し、`run-state.json` の更新は引き続き `app/cli.ps1` 経由に限定する
4. job 実行は lock 外へ出し、**lease / execute / commit** に分離する
5. 初期版は conservative に始め、最終的には **workspace 分離**まで視野に入れる

この方針なら、relay-dev の長所である監査性・recoverability・typed state を崩さずに、fan-out しやすい task 群だけを速くできる。

## 3. 並列化の対象範囲

### 直列のままにするもの

- Phase0
- Phase1
- Phase2
- Phase3
- Phase3-1
- Phase4
- Phase4-1
- Phase7
- Phase7-1
- Phase8

これらは run 全体の合意形成や最終判定であり、並列化の旨味よりも制御複雑性の増加が大きい。

### 並列化するもの

- Phase5
- Phase5-1
- Phase5-2
- Phase6

ここは既に task-scoped artifact を持っているため、task ごとの phase cursor を持たせれば自然に並列化できる。

## 4. 目標像

Phase4-1 が `go` になったら、run は task lane に入る。

- dependency が満たされた task は `ready`
- scheduler が `ready` task から同時実行可能なものを選ぶ
- worker は task ごとに job を lease して実行する
- task はそれぞれ `Phase5 -> Phase5-1 -> Phase5-2 -> Phase6` を独立に進む
- すべての planned / repair task が terminal になったら Phase7 へ進む

イメージ:

```text
Phase4-1 go
   └─ Task lane start
        ├─ T-01: Phase5 -> Phase5-1 -> Phase5-2 -> Phase6 -> completed
        ├─ T-02: Phase5 -> Phase5-1 -> Phase5-2 -> Phase6 -> completed
        ├─ T-03: wait (depends_on T-01)
        └─ T-04: wait (depends_on T-02)

T-01 / T-02 完了後
   └─ T-03 / T-04 が ready になり同様に進行

全 task 完了
   └─ Phase7
```

## 5. 現行設計を活かせる点

この案はゼロからの作り直しではない。既存実装の強みをそのまま使える。

- `phase4_tasks.json` の `dependencies[]` は DAG scheduler の入力になる
- `task_states` はそのまま task 単位の状態管理の器になる
- task-scoped artifact path は既に `runs/<run-id>/artifacts/tasks/<task-id>/...` で分離されている
- `boundary_contract` は task の責務境界として使える
- `changed_files[]` は衝突検知の初期材料になる
- `run.lock` は single writer の commit guard として引き続き使える

つまり足りないのは「task lane の multi-job state」と「job 実行を同期 step から切り離す仕組み」である。

## 6. 必要な設計変更

### 6.1 RunState を単一カーソルから task-lane 管理へ広げる

現行の `current_phase` / `current_task_id` / `active_job_id` だけでは、複数 task が異なる subphase にいる状態を表せない。

そのため少なくとも次を追加したい。

- `active_jobs`
  - job_id ごとの実行中情報
- `task_states[].phase_cursor`
  - その task が今どの phase にいるか
- `task_states[].active_job_id`
  - その task を今実行中の job
- `task_states[].attempt`
  - task 単位の retry 回数
- `task_states[].workspace_id`
  - job が使う workspace 識別子
- `task_lane`
  - task lane 全体の mode や capacity

イメージ:

```json
{
  "current_phase": "Phase5",
  "active_jobs": {
    "job-101": { "task_id": "T-01", "phase": "Phase5", "role": "implementer" },
    "job-102": { "task_id": "T-02", "phase": "Phase5-1", "role": "reviewer" }
  },
  "task_lane": {
    "mode": "parallel",
    "max_parallel_jobs": 2,
    "stop_leasing": false
  },
  "task_states": {
    "T-01": {
      "status": "in_progress",
      "phase_cursor": "Phase5",
      "active_job_id": "job-101"
    },
    "T-02": {
      "status": "in_progress",
      "phase_cursor": "Phase5-1",
      "active_job_id": "job-102"
    },
    "T-03": {
      "status": "ready",
      "phase_cursor": "Phase5",
      "active_job_id": null
    }
  }
}
```

`current_phase` は「run が今どの大域フェーズ帯にいるか」の coarse な指標として残し、task の実 phase は `task_states[].phase_cursor` を正本にするのがよい。

### 6.2 `step` を lease / execute / commit に分ける

現行の `cli.ps1 step` は lock を取り、job を実行し、commit まで終えてから返る。
このままでは複数 worker を走らせられない。

並列化では次の 3 段階に分けたい。

1. `lease`
   - lock を取り、dispatch 可能 task を選ぶ
   - `active_jobs` と task lease を書く
   - jobSpec を返す
2. `execute`
   - worker が lock 外で provider job を実行する
3. `commit`
   - lock を取り、job result を validate / commit して state を進める

重要なのは、**single writer を捨てるのではなく、書き込み区間だけを短くする**こと。

## 7. Scheduler の考え方

### 7.1 ready 条件

task が dispatch 可能なのは次を満たすとき。

- `depends_on` がすべて completed
- 当該 task に active job がない
- task が blocked / abandoned ではない
- task lane が `stop_leasing` になっていない
- 衝突する resource lock を他 job が保持していない

### 7.2 phase 遷移

task ごとの基本遷移は今と同じでよい。

- Phase5 `go` -> Phase5-1
- Phase5-1 `go` -> Phase5-2
- Phase5-1 `reject` -> Phase5
- Phase5-2 `go|conditional_go` -> Phase6
- Phase5-2 `reject` -> Phase5
- Phase6 `go|conditional_go`
  - 次の ready task があれば task は completed
  - run 全体としては task lane 継続
- Phase6 `reject`
  - task を指定 rollback phase に戻す

つまり rollback は **run 全体ではなく task 単位** で発生する。

### 7.3 Phase7 への昇格条件

run が Phase7 に進めるのは次を満たしたとき。

- planned task がすべて completed
- repair task が残っていない
- `active_jobs` が空
- pending approval がない
- stop 中でない

## 8. 衝突制御

並列化の本当の難所は DAG ではなく workspace 競合である。

`dependencies[]` は「順序依存」は表せるが、次は表せない。

- 同じファイルを別 task が触る
- `package-lock.json` / `pnpm-lock.yaml` / `Cargo.lock` のような shared file
- DB migration や codegen のような global side effect
- 同じ外部 API mock / test fixture を更新する task

したがって、scheduler には dependency 以外の mutex 情報が必要になる。

### 8.1 初期版で使う情報

- `changed_files[]`
- `complexity`
- `boundary_contract`

これだけでも、

- 同じ file を触る task は同時実行しない
- `package.json` / lockfile / migration を含む task は serial 扱い
- complexity `L` は初期版では直列優先

という conservative な運用は可能。

### 8.2 追加したい canonical field

`phase4_tasks.json` に optional field として次を足す案がよい。

- `resource_locks[]`
  - 例: `db-schema`, `package-lock`, `codegen-openapi`, `routes-registry`
- `parallel_safety`
  - `serial | cautious | parallel`

なお、`parallel_batches[]` のような top-level batch 一覧を canonical source of truth にするのは推奨しない。

理由:

- 既に `dependencies[]` があるため、順序 source of truth が二重化する
- batch は scheduler policy であり、task contract そのものではない
- task-level の `resource_locks[]` と `parallel_safety` から runtime に導出した方が保守しやすい

現在の Phase4 prompt が Markdown に出している「並列実行可能グループ」は、そのまま人間向けサマリとして残してよいが、machine の正本は task-level constraint に寄せるのがよい。

例:

```json
{
  "task_id": "T-02",
  "dependencies": ["T-01"],
  "changed_files": ["src/api/users.ts", "tests/api/users.test.ts"],
  "resource_locks": ["routes-registry"],
  "parallel_safety": "cautious"
}
```

これにより、並列可否を prompt の prose ではなく canonical contract に寄せられる。

### 8.3 Phase4-1 reviewer の役割追加

Phase4-1 は task 分割だけでなく、**parallel safety review** も見るようにしたい。

確認項目:

- dependency が不足していないか
- `changed_files[]` が粗すぎないか
- shared file を触る task に `resource_locks[]` が付いているか
- `parallel_safety: parallel` の task が本当に独立しているか

## 9. Workspace 戦略

ここは短期案と本命案を分けて考えるのがよい。

### 9.1 短期案: same-workspace conservative mode

同じ workspace のまま並列に走らせる。

許可条件:

- `changed_files[]` が互いに交差しない
- shared lock を持たない
- DB migration / codegen / lockfile 更新を含まない
- complexity `S` と一部の `M` に限定

利点:

- 実装が軽い
- 今の runner を大きく崩さずに試せる

弱点:

- formatter や test で想定外の file が触られる可能性がある
- provider が boundary 外の編集をすると守り切れない
- 大きい repo では accidental conflict を完全には防げない

したがって、これは **実験的モード** として始めるのがよい。

### 9.2 本命案: isolated workspace mode

task ごとに独立 workspace を持たせる。

候補:

- `git worktree`
- run 開始時 snapshot からのコピー
- hardlink / reflink ベースの軽量 clone

利点:

- task 同士の file race を構造的に避けられる
- implementer / reviewer / repairer の job を安全に同時実行しやすい
- retry や forensic が楽になる

弱点:

- merge-back 設計が必要
- dirty worktree を起点にした run への対応が難しい
- disk 使用量と setup コストが増える

最終的にはこちらを default にしたいが、初手から入れるとスコープが大きい。

## 10. Monitor / 可観測性

並列化では scheduler や worker 自体よりも、**今なぜ進んでいるか / 止まっているかを monitor で説明できるか** が重要になる。

現行 monitor はこの点で単数前提が強い。

- `watch-run.ps1` は `Active Job` と `Current Task` を 1 件ずつしか出さない
- `dashboard-renderer.ps1` は run-level summary だけで task lane の状態を持たない
- `run-summary-renderer.ps1` も `current_phase` 1 本で終わる
- `run.status_changed` event も `current_task_id` / `active_job_id` の単数 view を前提にしている

このまま並列化すると、「run は running だが何が動いているのか分からない」「止まっている理由が dependency なのか resource lock なのか approval なのか見えない」という運用上の不透明性が出る。

### 10.1 monitor の原則

monitor は次を守るべき。

- **read-only** である
- `run-state.json` と `events.jsonl` を正本として読む
- renderer 側で prose 推論しない
- operator が 5 秒で次の問いに答えられるようにする

monitor が即答すべき問い:

- 今、何件の job が動いているか
- どの task が ready / in_progress / blocked / completed か
- 止まっている task は dependency 待ちか、resource lock 待ちか、approval 待ちか
- lane 全体として前進しているか、スタックしているか
- 人間が介入すべきか、待てばよいか

### 10.2 state / event に追加したい monitor 向け情報

monitor のために別の source of truth を増やす必要はないが、render しやすい field は増やしたい。

候補:

- `active_jobs`
  - job_id, task_id, phase, role, started_at, workspace_id, lease_owner
- `task_states[].phase_cursor`
- `task_states[].wait_reason`
  - `dependencies`, `resource_lock`, `approval`, `retry_backoff`, `workspace_prepare`, `manual_pause`
- `task_states[].blocked_by`
  - task ids や resource lock ids
- `task_lane.summary`
  - ready / in_progress / blocked / completed counts
- `task_lane.capacity`
  - configured / used parallel slots

event も monitor 向けにはもう少し細かい方がよい。

候補 event:

- `job.leased`
- `job.lease_rejected`
- `job.committed`
- `task.phase_changed`
- `task.ready`
- `task.waiting`
- `task.unblocked`
- `task.resource_locked`
- `task.resource_released`
- `task.lane_completed`

重要なのは、monitor が `Recent events` を見ただけで「dispatch されていない」のではなく「dispatch 候補だったが lock 競合で見送られた」と分かること。

### 10.3 `watch-run.ps1` の役割変更

`watch-run.ps1` は parallel mode では単なる current phase 表示では足りず、**task lane monitor** に変える必要がある。

最低限ほしいセクション:

1. Run overview
   - run id, status, coarse phase, updated_at
2. Lane summary
   - total tasks, ready, running, blocked, completed, repair tasks
3. Active jobs
   - job_id, task_id, phase, role, elapsed, workspace
4. Ready queue
   - 次に lease 可能な task
5. Waiting / blocked tasks
   - wait_reason, blocked_by, depends_on
6. Approval
   - pending approval の対象 task / phase / carry-forward count
7. Recent events
   - lease / commit / reject / stall の流れ

イメージ:

```text
Status: running
Run Phase: Phase5 task-lane
Slots: 2 / 3 used
Tasks: total=8 ready=2 running=2 blocked=3 completed=1 repair=0

Active Jobs
- job-101  T-01  Phase5    implementer  00:02:14  ws=ws-T-01
- job-102  T-02  Phase5-1  reviewer     00:00:41  ws=ws-T-02

Ready Queue
- T-03  Phase5   safety=parallel  deps=[]
- T-04  Phase5   safety=cautious  deps=[T-02]

Waiting / Blocked
- T-05  wait=dependencies   blocked_by=[T-01]
- T-06  wait=resource_lock  blocked_by=[db-schema]
- T-07  wait=approval       blocked_by=[approval-0008]
```

### 10.4 `cli.ps1 show` / `dashboard.md` / run summary の変更

`cli.ps1 show` も今の 1 行 summary から拡張する必要がある。

追加したい内容:

- lane summary counts
- active jobs 一覧
- ready queue 上位 N 件
- blocked tasks 上位 N 件
- longest-running jobs
- unresolved approvals / open requirements

`dashboard.md` は latest run snapshot なので、少なくとも次を出したい。

- run overview
- task progress bar
- active job table
- blocked reason 集計
- critical path 候補

`run-summary-renderer.ps1` も、

- `Run X is running at Phase5`

だけではなく、

- `Run X is running in Phase5 task-lane: 3/8 tasks completed, 2 jobs active, 1 task blocked on db-schema`

のような summary に寄せた方が、通知やログで使いやすい。

### 10.5 operator が見るべき stall の分類

parallel mode では「進んでいない」の中身が複数ある。
monitor は少なくとも次を分類して出すべき。

- `no_ready_tasks`
  - dependency が未解消
- `capacity_full`
  - ready task はあるが slot が埋まっている
- `resource_locked`
  - shared resource 待ち
- `approval_pending`
  - 人間待ち
- `job_in_progress`
  - 実行中 job の完了待ち
- `workspace_prepare`
  - worktree / clone 生成待ち
- `stop_leasing`
  - failure により新規 dispatch 停止中

これが見えないと、operator は「worker が壊れた」のか「正常に待っている」のか区別できない。

### 10.6 worker wrapper / monitor の関係

`agent-loop.ps1` も単に `current_role == role` を見るだけでは弱くなる。

parallel mode では worker の責務を次のいずれかに分ける方がよい。

- orchestrator
  - lease / commit を担当
- worker
  - execute を担当
- monitor
  - read-only で lane を可視化

このとき monitor は worker 数と 1:1 でなくてよい。むしろ **1 run 1 monitor** で十分で、すべての active job を一覧できることが重要。

### 10.7 monitor 実装方針

monitor のために canonical state を二重化しないため、実装順としては次がよい。

1. `run-state.json` と event に multi-job 情報を入れる
2. `cli.ps1 show` を先に強化する
3. `watch-run.ps1` は `show` と同じ集約ロジックを使う
4. `dashboard-renderer.ps1` / `run-summary-renderer.ps1` に横展開する

つまり、monitor は独自ロジックを持たず、**state aggregation helper の薄い表示層** に留めるべきである。

## 11. Visible Terminal / Launcher

ユーザー体験としては、並列化しているのに visible terminal が 1 枚しかないとかなり弱い。

現行 launcher は次の前提で作られている。

- Windows では `start-agents.ps1` が `wt.exe` で worker tab 1 つと monitor tab 1 つを開く
- Linux/macOS では `start-agents.sh` が tmux で worker pane 1 つと monitor pane 1 つを作る
- `agent-loop.ps1` は orchestrator 1 本を常駐させる前提

これは single-worker 運用には合っているが、parallel mode では

- どの job がどの visible terminal に対応しているか分からない
- provider stdout/stderr が 1 つの画面に混ざる
- slot ごとの履歴が追えない
- 実行中 3 task のうち 1 task しか「見える」状態にならない

という問題が出る。

### 11.1 基本方針

parallel mode では **parallel slot と visible worker terminal を 1:1 で対応**させるのがよい。

つまり `max_parallel_jobs = N` なら、少なくとも

- control / orchestrator 用 1 画面
- monitor 用 1 画面
- execution worker 用 `N` 画面

を持つ。

実 execution の見える画面数は **parallel count と同数**にする。

### 11.2 long-lived slot 方式

画面は job ごとに増減させるより、**slot ごとに固定で持つ**方がよい。

理由:

- ターミナルが増えたり消えたりすると operator が追いにくい
- slot ごとの履歴が残る
- title / color / tab order を安定させられる
- stale job recovery のときも「どの slot が何をしていたか」を追跡しやすい

例:

- `slot-01`
- `slot-02`
- `slot-03`

各 slot は idle 時は待機し、lease が来たらその task を引き受ける。

### 11.3 Windows Terminal の推奨レイアウト

Windows では `wt.exe` の `new-tab` を使う現在の方向性をそのまま伸ばすのがよい。

推奨:

- tab 1: `monitor`
- tab 2: `control`
- tab 3..: `slot-01` 〜 `slot-N`

理由:

- pane で 4 つ以上を並べると provider stdout が読みにくくなる
- tab の方が task ごとのログを長く保持しやすい
- title 更新で現在 task を見せやすい

tab title 例:

- `monitor | run-20260507-001`
- `control | lease/commit`
- `slot-01 | idle`
- `slot-02 | T-07 | Phase5`
- `slot-03 | T-04 | Phase5-1`

必要なら `Start-Process wt.exe` の引数組み立てを次の方向へ広げる。

- `new-tab` for monitor
- `new-tab` for control
- `new-tab` x `max_parallel_jobs` for worker slots

つまり、今の固定 2 tab 起動を **config-driven な multi-tab 起動**へ変える。

### 11.4 tmux の推奨レイアウト

tmux では pane 数を parallel count と同数に増やすより、**window を分ける**方がよい。

推奨:

- window 1: `monitor`
- window 2: `control`
- window 3..: `slot-01` 〜 `slot-N`

pane 分割は monitor だけ、または 2 分割程度に留める。

理由:

- pane 数が増えるとログが読めなくなる
- worker ごとに window title を固定した方が切替しやすい
- `tmux list-windows` で slot の occupied / idle を見せやすい

### 11.5 worker role の分離

visible worker tab を増やすなら、`agent-loop.ps1` の role も今の

- `orchestrator`
- `implementer`
- `reviewer`

だけでは足りない。

parallel mode では概念的に次へ分けたい。

- `control`
  - lease / commit / approval handling
- `worker-slot`
  - 1 slot を専有し、leased job を execute
- `monitor`
  - read-only で run 全体を表示

ここでは `implementer` / `reviewer` は長寿命 process の role ではなく、**leased job の role** に寄せた方が自然である。

つまり visible terminal の本数を増やすなら、worker process も「role 別」ではなく **slot 別** に再設計する必要がある。

### 11.6 slot と job の紐付け

monitor と terminal title を自然にするため、job metadata には少なくとも次を持たせたい。

- `slot_id`
- `workspace_id`
- `leased_at`
- `worker_pid`
- `terminal_label`

例:

```json
{
  "job_id": "job-20260507-phase5-T-07",
  "task_id": "T-07",
  "phase": "Phase5",
  "role": "implementer",
  "slot_id": "slot-02",
  "workspace_id": "ws-T-07",
  "terminal_label": "slot-02 | T-07 | Phase5"
}
```

これがあると

- monitor に slot 列を出せる
- `wt.exe` / tmux の title 更新元にできる
- `jobs/<job-id>/` を見たときにどの visible terminal に対応していたか分かる

### 11.7 画面数と parallel count の関係

基本ルールは単純でよい。

- visible execution terminals = `max_parallel_jobs`

ただし total terminal 数は

- `1 monitor + 1 control + max_parallel_jobs workers`

になる。

たとえば `max_parallel_jobs = 3` なら、

- monitor 1
- control 1
- worker 3
- 合計 5 タブ / window

になる。

これは少し多く見えるが、「並列 3 本を本当に見える化したい」なら妥当なコストである。

### 11.8 layout 設定案

設定で持つなら次のような shape がよい。

```yaml
parallel:
  enabled: true
  max_parallel_jobs: 3

visible_workers:
  enabled: true
  layout: per_slot
  include_monitor: true
  include_control: true
  terminal_backend:
    windows: wt
    posix: tmux
```

将来的な選択肢:

- `layout: single`
  - 今の単一 worker 方式
- `layout: per_slot`
  - slot 数ぶん開く推奨方式
- `layout: hybrid`
  - worker 2 までは pane、3 以上は tab/window

ただし初期実装は `per_slot` のみで十分。

### 11.9 operator 体験としての要件

terminal を増やす目的は単なる派手さではなく、operator を不安にさせないことにある。

最低限ほしい体験:

- 各 slot が idle / busy をタイトルで即座に判断できる
- busy な slot は task_id と phase が見える
- approval は control か monitor だけで扱い、worker slot に混ぜない
- worker が落ちたとき、どの slot が死んだかが分かる
- restart / resume 時に同じ slot 数で再生成される

### 11.10 launcher 実装順

実装順としては次がよい。

1. state 側に `slot_id` と `active_jobs` を入れる
2. `start-agents.ps1` / `.sh` に `max_parallel_jobs` を読ませる
3. monitor + control + worker-slot x N を起動できるようにする
4. worker-slot process が leased job を execute する方式へ寄せる
5. title 更新と slot occupancy 表示を入れる

つまり、visible terminal の多重化は単独タスクではなく、**lease/slot model 導入と一体で進めるべき**である。

## 12. 推奨ロードマップ

### Step 1. state model 先行

- `active_jobs` と `task_states[].phase_cursor` を導入
- `task_states[].wait_reason` など monitor に必要な field も同時に導入
- ただし `max_parallel_jobs = 1` のまま動かす

目的:

- 並列化の前に state 表現だけを future-proof にする
- monitor を先に multi-job state に慣らす

### Step 2. lease / commit 分離

- `step` の内部を `lease -> execute -> commit` に分解
- `job.leased` / `job.committed` など monitor 向け event を追加
- sequential mode では従来通り 1 job を同期実行

目的:

- worker pool を後から差し込める形にする
- 進行中 job と書き込み中 job の区別を monitor で見えるようにする

### Step 3. Phase4 contract 拡張

- `resource_locks[]`
- `parallel_safety`

を schema / prompt / reviewer 観点に追加する。

### Step 4. conservative parallel mode

- `max_parallel_jobs > 1` を許可
- same-workspace だが厳しい条件を満たす task だけ co-dispatch
- `watch-run.ps1` / `cli.ps1 show` / `dashboard.md` を task-lane view に更新
- `start-agents.ps1` / `.sh` を worker slot 数ぶん visible terminal を開く launcher に更新
- まずは Phase5 実装 job から始め、問題なければ reviewer lane に広げる

### Step 5. task-lane full parallel

- Phase5 / Phase5-1 / Phase5-2 / Phase6 を task ごとに独立進行
- run は all-tasks-complete barrier で Phase7 へ進む

### Step 6. isolated workspace mode

- per-task workspace を導入
- workspace id / path / merge-back 状態を monitor から見えるようにする
- slot title に workspace 情報や merge-back 状態も出せるようにする
- safe subset 制限を緩め、より一般的な並列化へ進む

## 13. 失敗時の扱い

並列化しても fail-fast の思想は保った方がよい。

提案:

- recoverable な provider failure は task 単位 retry
- non-recoverable failure は `stop_leasing = true`
- 既に走っている job は drain するか、次回 recovery 対象として残す
- run 全体は `failed` か `blocked` に寄せ、勝手に進めない

ここで重要なのは、「1 task が壊れたのに別 task がさらに増殖して状況が悪化する」ことを避けること。

## 14. テスト観点

この機能は concurrency bug を生みやすいので、回帰を先に増やすべき。

最低限ほしいもの:

- 2 worker が同時に lease しても同じ task を取らない
- dependency 解消で次 task が ready になる
- shared `resource_lock` を持つ task は co-dispatch されない
- task-local reject が他 task を巻き戻さない
- stale active job recovery が `active_jobs[]` 全体に対して働く
- all tasks complete でのみ Phase7 へ進む
- same-workspace mode で overlap task が弾かれる
- `watch-run` / `show` が multi-job state を正しく要約する
- stall reason が `dependencies` / `resource_lock` / `approval` で誤分類されない
- `start-agents.ps1` / `.sh` が `max_parallel_jobs = N` に対して worker slot terminal を N 個開く
- slot terminal が task 完了後に次 task へ再利用され、tab/window title が更新される

## 15. 採用判断

この機能は relay-dev にかなり相性がよい。

理由:

- task DAG が既にある
- task-scoped artifact store が既にある
- single writer と event log がある
- Phase4 prompt も「並列実行可能グループ」の発想をすでに持っている

一方で、実際の難所は dependency ではなく **state の単数前提** と **workspace 競合** である。

したがって採用方針としては次を推奨する。

- **採用する**
- ただし一気に full parallel へ行かず、
  - state refactor
  - lease/commit 分離
  - conservative parallel mode
  - isolated workspace mode
  の順で段階導入する

この順序なら、relay-dev の強みである安全性と再現性を落とさず、実用的なスループット改善を狙える。
