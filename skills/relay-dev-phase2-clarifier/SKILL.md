---
name: relay-dev-phase2-clarifier
description: Resolve Phase2 clarification pauses for relay-dev by summarizing unresolved_blockers, talking them through with the user, updating task.md and Phase0 seed inputs, and handing off when it is safe to resume with y. Use when a run is paused after Phase2 or phase2_info_gathering.* still contains unresolved_blockers that need human answers.
---

# Relay Dev Phase2 Clarifier

## Overview

This skill handles the narrow case where relay-dev reached `Phase2` clarification fallback and still has meaningful `unresolved_blockers`.

Its job is to:

- summarize the pending questions in plain language
- talk them through with the user in a short workshop loop
- reflect the answers into `tasks/task.md` and, when needed, `outputs/phase0_context.*`
- tell the operator whether it is safe to resume with `y`

This is not a generic intake skill and it is not a troubleshooting skill.

## Use This Skill When

Use this skill when one or more of these are true:

- the current run is paused after `Phase2`
- `phase2_info_gathering.json` still has meaningful `unresolved_blockers`
- the user wants to "summarize the questions and decide them together"
- the answers need to be reflected before resuming the run

If the work has not started yet, use `relay-dev-front-door` instead.  
If the request becomes a broader rollback, pivot, or restart discussion, hand off to `relay-dev-course-corrector`.

## Start From Canonical Context

Read only the minimum context needed:

- `.\app\cli.ps1 show` or `runs/current-run.json` to confirm the active run and pending approval
- the current run's `phase2_info_gathering.md`
- the current run's `phase2_info_gathering.json`
- `tasks/task.md`
- `outputs/phase0_context.md` and `outputs/phase0_context.json` when they exist

If the user wants a more deliberate workshop loop, read `references/clarification-playbook.md`.

## Workflow

### 1. Confirm that this is really a Phase2 clarification pause

Before starting a conversation:

- confirm that the run is actually waiting after `Phase2`, or that `phase2_info_gathering.json` contains meaningful `unresolved_blockers`
- ignore placeholders like `none` or `特になし`
- do not manufacture questions when the blockers are already resolved enough

### 2. Summarize the blockers

Turn the raw blockers into a short working summary:

- the question that needs an answer
- why it matters to `Phase3`
- the safest default, if one is clearly better

Merge duplicates and rewrite vague blocker text into direct questions without changing the meaning.

### 3. Run a short clarification conversation

Prefer a compact workshop loop:

- ask only `1-3` focused questions in a turn
- prefer yes/no or `2-4` concrete options with tradeoffs
- after each answer, restate what is now decided
- keep the remaining questions visible until they are resolved or explicitly deferred

If the user is unsure, recommend the safest practical default and explain why in one sentence.

### 4. Reflect the answers into upstream inputs

Update `tasks/task.md` when the clarification changes:

- requirements
- constraints
- non-goals
- acceptance criteria
- rollout expectations
- operator choices

Update `outputs/phase0_context.*` when the clarification changes shared assumptions or cross-phase context that later phases should see.

Do not edit:

- `runs/*/run-state.json`
- `runs/*/events.jsonl`
- `queue/status.yaml`

Do not rewrite `runs/<run-id>/artifacts/.../phase2_info_gathering.*` by default.  
The normal path is to fix the upstream inputs and let the rerun regenerate `Phase1` and `Phase2`.

### 5. Decide whether resume is safe

If every blocker is resolved enough for design, report:

- `clarification_summary`
- `resolved_decisions`
- `updated_files`
- `safe_to_resume=true`

Then tell the operator it is safe to answer `y`.

If material blockers still remain, report:

- `remaining_questions`
- why they still block `Phase3`
- `safe_to_resume=false`

Do not advise resuming while material blockers remain.

## Working Draft

Keep a compact working draft while you talk:

- `clarification_summary`
- `resolved_decisions`
- `remaining_questions`
- `updated_files`
- `safe_to_resume`

## What Not To Do

- do not treat this as greenfield discovery
- do not skip updating `task.md` or seed inputs when answers materially change them
- do not edit run state or event logs
- do not auto-resume the run unless the user explicitly asks for operator execution
- do not say "safe to resume" if the answers are still too vague for `Phase3`

## Useful References

- `references/clarification-playbook.md`
- `README.md`
- `tasks/task.md`
- `outputs/phase0_context.*`
- current run `phase2_info_gathering.*`
