# Task Parallelization Conservative Scheduler Plan

## 1. Purpose

This plan turns the task parallelization idea into the next implementable slice after `task-parallelization-prep`.

The goal is not to run multiple provider jobs yet. The goal is to make `phase4_tasks.json` and the scheduler understand conservative parallel-safety constraints so a later worker pool can lease more than one task without guessing.

## 2. Scope

Implement the foundation for conservative task-lane scheduling:

- extend the Phase4 task contract with optional `resource_locks[]` and `parallel_safety`
- validate those fields when present
- preserve them in selected task contracts
- calculate ready/waiting task-lane candidates with dependency, active job, stop-leasing, and resource-lock reasons
- expose those reasons through task-lane summary surfaces

## 3. Non-Goals

- Do not enable official `max_parallel_jobs > 1` execution.
- Do not introduce a headless worker pool.
- Do not run provider execution outside the existing single-step path.
- Do not implement same-workspace actual-diff commit guards.
- Do not implement isolated workspaces or merge-back.
- Do not implement visible worker slot launchers.
- Do not treat Phase4 prose parallel groups as canonical scheduler input.
- Do not infer same-workspace co-dispatch safety from `changed_files[]` alone.
- Do not persist `ready_queue` as a new source of truth; derive it from run-state and task contracts.

## 4. Implementation Tasks

### CPS-01: Phase4 Contract Safety Fields

Add optional `resource_locks[]` and `parallel_safety` to Phase4 task contracts.

Acceptance:

- `phase4_tasks.json tasks[]` accepts optional `resource_locks` as an array of non-empty strings.
- `phase4_tasks.json tasks[]` accepts optional `parallel_safety` as `serial`, `cautious`, or `parallel`.
- Missing `parallel_safety` remains backwards compatible.
- Phase4 prompt asks authors to emit these fields.
- Phase4-1 prompt asks reviewers to check them.

Candidate files:

- `app/core/artifact-validator.ps1`
- `app/prompts/phases/phase4.md`
- `app/prompts/phases/phase4-1.md`
- `tests/regression.ps1`

### CPS-02: Conservative Scheduler Constraint Helpers

Add scheduler helpers that can explain task dispatch eligibility without enabling parallel execution.

For this slice, `parallel_safety` has conservative helper semantics only:

- `serial`: cannot be co-dispatched with any other active job, and if a serial task is active, no other task is dispatchable.
- `cautious`: eligible only when dependencies and resource locks allow it; no extra priority boost.
- `parallel`: eligible when dependencies and resource locks allow it; no `changed_files[]`-only co-dispatch inference in this slice.

For resource-lock waits, `blocked_by` is the list of blocking resource lock ids, such as `["db-schema"]`. If job/task attribution is available, helpers may also expose `blocked_by_jobs[]` and `blocked_by_tasks[]`, but `blocked_by` remains resource-lock oriented for `wait_reason=resource_lock`.

Acceptance:

- A ready task with unmet dependencies is represented as waiting on `dependencies` with `blocked_by` task ids.
- A task holding a resource lock already held by an active job is represented as waiting on `resource_lock`.
- A task with `parallel_safety: serial` is not dispatchable when any other job is active, and no other task is dispatchable while a serial task is active.
- `task_lane.stop_leasing` prevents new dispatch and produces a stable wait reason.
- Existing sequential `Get-NextAction` behavior remains unchanged for single-job mode.

Candidate files:

- `app/core/workflow-engine.ps1`
- `app/core/run-state-store.ps1`
- `tests/task-parallelization-scheduler.ps1`

### CPS-03: Task Lane Observability

Expose scheduler explanations in task-lane monitor data.

This builds on the completed TPP-06 summary foundation. It should add `ready_queue`, resource-lock waits, serial-safety explanation, and stall reasons without reimplementing the existing active job display or basic lane counts.

Acceptance:

- `New-TaskLaneSummary` includes `ready_queue`.
- Waiting rows include `wait_reason` and `blocked_by` when known.
- Summary exposes lane stall reason such as `job_in_progress`, `stop_leasing`, `no_ready_tasks`, or `resource_locked`.
- `watch-run.ps1` can render the ready queue and blocked/waiting reasons.

Candidate files:

- `app/ui/task-lane-summary.ps1`
- `watch-run.ps1`
- `app/ui/dashboard-renderer.ps1`
- `app/ui/run-summary-renderer.ps1`
- `tests/task-parallelization-scheduler.ps1`

### CPS-04: Scheduler Regression Coverage

Add targeted regression coverage for the conservative scheduler foundation.

Acceptance:

- optional Phase4 safety fields validate successfully
- invalid `parallel_safety` fails validation
- resource-lock conflict is visible in scheduler/summary helpers
- stop-leasing produces a wait/stall reason
- sequential `Get-NextAction` still dispatches the first ready task when there are no active jobs

Candidate files:

- `tests/task-parallelization-scheduler.ps1`
- `tests/regression.ps1`

## 5. Recommended Worker Split

- Worker A owns CPS-01 and does not touch scheduler code.
- Worker B owns CPS-02 and `tests/task-parallelization-scheduler.ps1`.
- Worker C owns CPS-03 and UI summary/renderer assertions in `tests/task-parallelization-scheduler.ps1` if the file already exists; coordinate by appending separate test sections only.
- Parent owns any `tests/regression.ps1` edits plus final integration review and final test execution.

## 6. Global Acceptance

- The new plan is represented in both Markdown and JSON under `docs/plans`.
- Existing `task-parallelization-prep` tests still pass.
- Existing regression suite still passes.
- No production path leases more than one job.
- The resulting state and monitor data can explain why a task is ready, waiting on dependencies, waiting on resource locks, stopped by approval/stop-leasing, or blocked by active capacity.
