---
name: delegated-implementation
description: Plan and execute substantial implementation work through a parent-managed JSON task list, reviewer subagent validation, bounded worker delegation, and parent-owned final verification. Use when the user explicitly asks for the earlier task-list JSON, agent review, TODO management, multiple workers, and parent build/test flow, asks to use worker/subagent delegation for coding, or asks to repeat that procedure for a broad relay-dev change.
---

# Delegated Implementation

Use this skill to turn broad implementation work into a reviewed, parent-managed set of coding tasks that can be delegated safely.

## Guardrails

- Use subagents only when the user has explicitly requested subagents, delegation, worker agents, parallel agent work, or "the same procedure" referring to this workflow.
- Keep the parent agent responsible for planning, TODO status, integration, final build/test checks, and the final report.
- Give worker agents coding work only. Do not delegate final build, full regression, release decisions, or broad integration judgment.
- Prefer serial execution for tasks with dependency or write-scope conflicts. Parallelize only tasks with disjoint write scopes and no ordering dependency.
- Do not ask two workers to edit the same file unless one task clearly depends on the other and runs later.
- Tell every worker they are not alone in the codebase, must not revert others' edits, and must adapt to existing changes.

## Workflow

1. Inspect the current repo state and relevant files enough to understand scope, dependencies, and risk.
2. Create or update a plan JSON under `docs/plans/` before coding.
3. Ask a reviewer subagent to review the plan for task consistency, dependency conflicts, missing acceptance criteria, and unsafe parallelism.
4. Revise the JSON plan until the reviewer returns PASS or the remaining risk is intentionally accepted by the user.
5. Manage the TODO list in the parent thread. Mark only one parent step as in progress at a time.
6. Delegate coding tasks to worker agents according to the reviewed plan. Use low reasoning for workers unless the user specifies otherwise.
7. Review each worker result, integrate or adjust locally as needed, then update TODO status.
8. Run final verification in the parent agent. Include focused tests for the changed surface and broader regression when the blast radius is high.
9. Summarize what changed, what passed, what was not run, and any remaining risk.

## Plan JSON

Use a concise JSON structure that can be reviewed by another agent and reused as the parent TODO source.

Required top-level fields:

- `objective`: one sentence.
- `scope`: files, modules, commands, or behavior in scope.
- `out_of_scope`: explicit non-goals.
- `constraints`: user constraints and repo safety constraints.
- `assumptions`: assumptions to validate or carry.
- `tasks`: ordered task objects.
- `verification`: parent-owned verification commands or checks.
- `review_status`: `draft`, `blocked`, or `passed`.

Each task should include:

- `id`: stable short id, such as `LCR-01`.
- `title`: short action name.
- `intent`: why this task exists.
- `write_scope`: files or directories the worker may edit.
- `dependencies`: task ids that must complete first.
- `parallel_group`: group id, or `serial` when not parallel-safe.
- `worker_role`: usually `worker`.
- `acceptance`: concrete completion criteria.
- `tests`: focused tests or checks relevant to the task.
- `risks`: likely failure modes, especially merge/recovery/state risks.
- `status`: `pending`, `in_progress`, `completed`, or `blocked`.

## Reviewer Prompt

Ask the reviewer for a blocking consistency review, not implementation. Use medium reasoning unless the user asks otherwise.

Include:

- path to the plan JSON
- relevant architecture or code files
- specific questions:
  - Are task dependencies correct?
  - Are write scopes disjoint where tasks are marked parallel?
  - Are acceptance criteria testable?
  - Are recovery, merge, and failure cases represented when relevant?
  - Should any task be split, merged, or made serial?

Require output as:

```text
Verdict: PASS | BLOCKED
Blocking issues:
- ...
Non-blocking notes:
- ...
```

## Worker Prompt

Give each worker a bounded implementation assignment.

Include:

- task id and title
- exact write scope
- dependencies already completed
- acceptance criteria
- focused tests to add or run
- instruction to edit files directly
- instruction to avoid reverting or overwriting other agents' changes
- instruction to report changed files, tests run, and unresolved issues

Keep worker prompts scoped to coding. If a worker discovers a design conflict, have it stop and report rather than broadening the task.

## Parent Verification

The parent must run final verification after all workers finish.

Use:

- focused tests added for the delegated work
- existing tests around touched behavior
- parse/static checks when scripting files changed
- broader regression when state management, CLI, merge, recovery, scheduler, or workflow behavior changed

If verification fails, diagnose in the parent first. Delegate only a narrow fix when it can proceed without duplicating parent work.
