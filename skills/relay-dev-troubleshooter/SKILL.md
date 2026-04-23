---
name: relay-dev-troubleshooter
description: Investigate stalled, inconsistent, or failing relay-dev runs by reading canonical state, events, jobs, and provider output before suggesting recovery. Use when a run stops unexpectedly, `show` disagrees with artifacts, approvals behave oddly, a provider job fails, or relay-dev appears stuck in the wrong phase.
---

# Relay Dev Troubleshooter

## Overview

この skill は、relay-dev の異常時に「まず読む、次に説明する、最後に安全な対処を提案する」を徹底する。  
run が止まった、phase が噛み合わない、approval 待ちが崩れた、provider 出力が失敗した、といったケースを canonical state から調査する。

## Start With Read-Only Inspection

最初に、次をこの順で確認する。

1. `runs/current-run.json`
2. `runs/<run-id>/run-state.json`
3. `runs/<run-id>/events.jsonl`
4. `runs/<run-id>/jobs/`
5. `.\app\cli.ps1 show`

症状別の見方は `references/troubleshooting-checklist.md` を使う。

## Build A Symptom-First Diagnosis

最初から解決策を決め打ちしない。  
まず症状を 1 つの短い文に言い換える。

例:

- run が途中で進まなくなった
- `show` と `run-state.json` の説明が噛み合わない
- approval 待ちのまま次に進んでしまった
- provider job が連続失敗している

そのうえで、どの file / event / job がその症状を裏づけるかを示す。

## Prefer Safe Recovery Options

対処は安全な順に提案する。

1. 状況説明だけで足りる
2. `show` や `resume` のような正規 entrypoint で再確認する
3. user に必要な判断を返す
4. それでも必要なら最小限の操作を行う

run file を直接書き換えるような近道は選ばない。

### Recoverable Failed Run の判断

`status=failed` のときは、最新の `run.failed` と `job.finished` を見て recoverable かを必ず明示する。

safe retry として提案してよい既定:

- `run.failed.reason = job_failed`
- `failure_class = provider_error` または `timeout`
- `active_job_id = null`
- `pending_approval = null`

この場合は:

- `resume` で same phase / same role に戻せる可能性が高い
- `new` や manual file edit より先に、その recovery path を案内する

それ以外の failed は:

- 設計/validator/transition の問題を含み得る
- 自動 recovery を前提にせず、原因説明を優先する

## Separate Failure From Scope Change

障害対応と変更要求を混同しない。

- 壊れた、ズレた、失敗した: `relay-dev-troubleshooter`
- 戻したい、止めたい、別案に変えたい: `relay-dev-course-corrector`

今回の論点が後者なら、調査結果をまとめて `course-corrector` へ handoff する。

## Report A Concrete Recovery Summary

返答には少なくとも次を含める。

- 観測した症状
- 根拠となる file / event / job
- 原因仮説
- 安全な次アクション
- 追加で人間判断が必要かどうか

## What Not To Do

- `queue/status.yaml` を正本として扱わない
- run file を手で書き換えて無理に進めない
- 症状を確認する前に `new` や再起動を勧めない
- scope change を障害扱いして混線させない

## Useful References

- `references/troubleshooting-checklist.md`
- `README.md`
- `app/cli.ps1`
- `runs/current-run.json`
