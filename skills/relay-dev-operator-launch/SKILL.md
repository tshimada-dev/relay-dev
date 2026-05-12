---
name: relay-dev-operator-launch
description: Inspect canonical relay-dev state and choose or execute the safest next control-plane command. Use when `tasks/task.md` and any needed Phase0 seed are ready enough, when a run must be started, paused, or resumed, or when deciding between `new`, `resume`, `step`, `show`, `start-agents.ps1`, and visible Windows launch/resume flows.
---

# Relay Dev Operator Launch

## Overview

この skill は、relay-dev の control plane を安全に動かす。  
`tasks/task.md` と seed の準備状況、現在の canonical state、ユーザーの意図を見て、`new` / `resume` / `step` / `show` / `start-agents.ps1` と visible launch 補助コマンドのどれを使うか決めて実行する。停止後の再開や stale job recovery の起点もここで扱う。

## Read Canonical State First

必ず次の順で見る。

1. `runs/current-run.json`
2. `runs/<run-id>/run-state.json`
3. `runs/<run-id>/events.jsonl`
4. `.\app\cli.ps1 show`

以下は compatibility projection であり、source of truth ではない。

- `queue/status.yaml`
- `outputs/`
- `dashboard.md`

## Decide Whether Launch Is Allowed

起動前に、少なくとも次を確認する。

- `tasks/task.md` が今回の依頼に合っている
- Phase0 seed が必要なときは `outputs/phase0_context.*` が使える状態にある
- 既存 run を続けるべきか、新規 run にすべきかが説明できる

requirements がまだ粗い場合は `relay-dev-front-door` へ戻す。  
task / seed が未整備なら `relay-dev-seed-author` へ戻す。

## Choose The Smallest Safe Command

使うコマンドは最小のものを選ぶ。

- run がまだ無い: `.\app\cli.ps1 new`
- 既存 run を続けたい: `.\app\cli.ps1 resume`
- `failed` run だが最新 failure が retriable な provider/job failure: `.\app\cli.ps1 resume`
- 1 step だけ進めたい: `.\app\cli.ps1 step`
- 状態確認だけしたい: `.\app\cli.ps1 show`
- Windows で通常運用を始めたい: `.\start-agents.ps1`
- Windows で task group 並列化を有効にして visible 起動したい: `.\start-agents.ps1 -ConfigFile config/settings.local.yaml`
- Windows で current run を visible terminal から再開したい: `.\start-agents.ps1 -ResumeCurrent`
- Windows で task group 並列化を有効にして visible 再開したい: `.\start-agents.ps1 -ResumeCurrent -ConfigFile config/settings.local.yaml`
- visible worker を直接起動したい: `pwsh -NoLogo -NoProfile -File .\agent-loop.ps1 -Role orchestrator -ConfigFile config/settings.yaml -InteractiveApproval`
- visible monitor だけ開きたい: `pwsh -NoLogo -NoProfile -File .\watch-run.ps1 -ConfigFile config/settings.yaml`

詳細な判断は `references/run-decision-table.md` を使う。

並列モードで起動する場合は、tracked な `config/settings.yaml` を書き換えず、Git 管理外の local config を使う。最小例:

```yaml
execution:
  mode: auto
  max_parallel_jobs: 3
  allow_single_parallel_job: false
```

この override を `config/settings.local.yaml` のような名前で用意し、`-ConfigFile` で明示する。

## Handle Recoverable Failed Runs

`status=failed` を見たら即座に `new` を勧めない。  
まず最新の `run.failed` と `job.finished` を見て、retriable failure かを切り分ける。

safe retry として扱ってよい既定:

- `run.failed.reason = job_failed`
- `failure_class = provider_error` または `timeout`
- `active_job_id = null`
- `pending_approval = null`

この条件を満たす場合:

- `.\app\cli.ps1 resume` で same phase / same role に戻す
- visible terminal が欲しい場合は `.\start-agents.ps1 -ResumeCurrent`
- 「open requirements は維持したまま、同じ phase を再試行する recovery」だと説明する

この条件を満たさない場合:

- 自動 recovery を前提にしない
- `relay-dev-troubleshooter` または `relay-dev-course-corrector` に渡す

## Handle Stop / Pause Safely

ユーザーが「いったん止めたい」と言った場合は、いきなり broad な kill を打たず次の順で扱う。

1. canonical state から `active_job_id` と `pending_approval` を確認する
2. `active_job_id` がなく `pending_approval` もないなら、run は idle と説明して停止操作を省く
3. active job 実行中なら、visible worker terminal または対応する `agent-loop.ps1` process を止める
4. child の provider process が残っている場合だけ、それも対象を確認して止める
5. `run-state.json` や job metadata を手で paused / failed に書き換えない
6. 後で `resume` / `step` を実行すると stale recovery が `active_job_id` を回収する前提で扱う

停止後に説明すべきこと:

- 停止時点の `run_id`
- 停止前の `current_phase`
- `active_job_id` が run-state に残っていても直ちに異常とは限らないこと
- 次回 `resume` / `step` で `job.recovered` や stale repair が起こり得ること

Windows visible worker の safe default:

- まず worker terminal を閉じるか、対応する `pwsh` process を止める
- monitor terminal は user が観察を続けたいなら残してよい
- 対象が relay-dev workspace の process であることを確認してから止める

## Prefer A User-Visible Terminal For Long-Running Launches

ユーザーが relay-dev の進行を観察したい、または継続的な自動進行を始める場合は、Windows では user-visible な terminal を既定にする。

- 新規 visible 起動の優先: `.\start-agents.ps1`
- 既存 run の visible 再開の優先: `.\start-agents.ps1 -ResumeCurrent`
- 代替: `agent-loop.ps1 -Role orchestrator -InteractiveApproval`
- monitor 併用: `watch-run.ps1`
- hidden background process は、ユーザーが明示的に望んだときだけ使う

現在の `start-agents.ps1` は次を前提に扱う。

- `-ResumeCurrent` で `runs/current-run.json` の active run を対話なしで resume できる
- visible な worker terminal を開く
- monitor を併用できる
- worker terminal で approval を直接受けられるよう `-InteractiveApproval` を使う

approval の意味は必ず明示する。

- `approve` と `skip` は pending approval の `proposed_action` を受け入れる
- そのため `approve` が常に「次の番号の phase へ進む」とは限らない
- 例: `Phase3-1` の reviewer verdict が `conditional_go` の場合、`approve` の結果は `Phase3` へ戻る
- visible terminal や monitor に proposed action の遷移先が見えているか確認する

すでに hidden worker を起動してしまった場合は、次を明確に説明する。

- その terminal 自体は途中から visible に移せないこと
- 現在進行中の job を壊さないため、即時切替は危険なこと
- 安全策としては、visible な monitoring terminal を開くか、次の安全な区切りで visible worker に切り替えること

## Execute And Report

コマンド実行後は、少なくとも次を人間へ返す。

- active `run_id`
- current phase
- current role
- active job の有無
- pending approval の有無
- pending approval がある場合は `approve` / `skip` の遷移先
- blocker の有無
- 次に AI が取る、または取ったコマンド
- long-running worker を起動した場合は、その terminal が user-visible かどうか
- user-visible でない場合は、なぜそうなっているかと安全な切替手順
- approval が発生した場合、その terminal で直接判断できるかどうか

## Keep Launch And Troubleshooting Separate

この skill は「起動、停止後の再開、通常の再開」を担当する。  
provider 失敗や phase の迷子など、異常調査が必要なら `relay-dev-troubleshooter` へ渡す。  
ユーザーが「戻したい」「方針を変えたい」と言っているなら `relay-dev-course-corrector` へ渡す。

## What Not To Do

- `queue/status.yaml` を authoritative source として扱わない
- phase を飛ばすために run file を直接書き換えない
- valid な Phase0 seed があるのに再生成を強要しない
- 障害調査や変更管理の責務まで 1 つに抱え込まない
- ユーザーの確認が必要な長時間実行を、説明なしに hidden background worker で始めない
- approval を hidden terminal の `Read-Host` に依存する形で残さない
- `approve` を無条件に「前進」と説明しない
- 停止要求に対して、workspace と無関係な `pwsh` / provider process を雑に止めない
- stop 後の stale state を見て、即座に `new` を勧めない

## Useful References

- `references/run-decision-table.md`
- `README.md`
- `app/cli.ps1`
- `runs/current-run.json`
