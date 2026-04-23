---
name: relay-dev-course-corrector
description: Safely change direction for relay-dev work by classifying rollback, pause, restart, and scope-change requests before proposing the lowest-risk next step. Use when the user wants to undo or stop current work, revise the request mid-run, restart from a cleaner point, keep artifacts while changing requirements, or otherwise needs change management rather than troubleshooting.
---

# Relay Dev Course Corrector

## Overview

この skill は、relay-dev の変更管理と方針転換を扱う。  
「違ったので戻したい」「途中で方針を変えたい」「この run はいったん止めたい」を、障害対応とは分けて整理し、安全な次アクションへ落とし込む。

## Classify The Change Request

最初に、要求の種類を分類する。

- rollback: 直前の方針や成果を戻したい
- pause: いったん止めて現状維持したい
- pivot: 要件や優先順位を変えたい
- restart: 履歴を残したまま、新しい run としてやり直したい

分類が曖昧なまま操作に入らないこと。

## Make Pause Requests Concrete

`pause` は曖昧になりやすいので、次のどれを望んでいるかを明確にする。

- stop-now: いま走っている worker / provider を止めたい
- stop-at-boundary: 現在の phase/job の区切りで止めたい
- hold-and-decide: 実行は止めたいが、artifact と run はそのまま保持したい

最低限、次を short summary で確定してから進める。

- active `run_id`
- `current_phase`
- `active_job_id` の有無
- `pending_approval` の有無
- visible worker か hidden worker か
- 停止後に同じ run を再開するのか、新しい run に切るのか

## Assess Impact Before Acting

次のどこに影響するかを要約する。

- `tasks/task.md`
- `outputs/phase0_context.*`
- 現在の `run_id`
- 生成済み artifact
- 人間レビューの判断履歴

影響範囲の見立てには `references/change-options.md` を使う。

## Prefer Traceable Options

提案は、履歴を消さない順に考える。

1. 何も壊れていないので説明だけする
2. `task.md` や seed を更新して同じ run を続ける
3. 現在の run を残し、新しい run としてやり直す
4. 一時停止して判断待ちにする

既存 run や artifact を reflex 的に削除しない。

## Pause / Stop SOP

停止要求を扱うときは、次の順で考える。

1. まず canonical state を読んで、run が idle なのか active job 実行中なのかを確認する
2. `active_job_id` がなく `pending_approval` もないなら、run は実質 idle と説明し、追加の停止操作は不要とする
3. active job 実行中で visible worker があるなら、その worker terminal または対応する `agent-loop.ps1` / provider process を止める
4. `run-state.json`、`events.jsonl`、job metadata を手で paused 扱いに書き換えない
5. 停止直後は `active_job_id` が残ることがある、と明示する
6. 後で再開するときは `relay-dev-operator-launch` に渡し、`resume` / `step` による stale recovery を使う

停止済みとして扱える目安:

- worker process が終了している
- 以後の job 出力が増えていない
- 次回 `resume` / `step` 時に `job.recovered` または同等の stale repair が期待できる

止め方そのものが論点ではなく、停止後にどう扱うかが論点であることを明示する。

## Route To The Right Next Skill

変更要求を整理したら、次に何へ handoff するか決める。

- 要件の言い換えや未確定事項の整理が必要: `relay-dev-front-door`
- `task.md` / seed の更新が必要: `relay-dev-seed-author`
- 停止後の再開、または新しい command 実行が必要: `relay-dev-operator-launch`
- 実は障害調査だった: `relay-dev-troubleshooter`

## Report A Change-Management Summary

返答には少なくとも次を含める。

- change request の分類
- 影響範囲
- 保持するもの / 捨てるもの
- 推奨アクション
- 必要なら `supersedes_run_id`
- `pause` の場合は stop method と resume path

## What Not To Do

- 障害対応と方針転換を混同しない
- run file を直接書き換えて巻き戻した気にならない
- 古い run や artifact を無断で削除しない
- 要件変更後も同じ seed や run を無批判に再利用しない
- 停止要求に対して、process が止まったことを確認せず「paused」と説明しない
- `active_job_id` が残っているだけで run が壊れたと決めつけず、stale recovery の余地を残す

## Useful References

- `references/change-options.md`
- `README.md`
- `runs/current-run.json`
- `tasks/task.md`
