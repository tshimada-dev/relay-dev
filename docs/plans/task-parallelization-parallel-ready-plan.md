# Task Parallelization Parallel-Ready Plan

## 1. Purpose

This plan lists the remaining implementation tasks needed before relay-dev can safely attempt task-lane parallelization.

The previous slices added single-job lease state and conservative scheduler explanations. This slice makes the control plane parallel-ready while keeping production execution gated. After this plan, relay-dev should be able to derive multiple safe lease candidates and represent multiple active leases in state. Actual provider worker pool execution remains an explicit follow-up gate.

## 2. Current Baseline

Already done:

- RunState has `active_jobs`, `task_lane`, `state_revision`, task `phase_cursor`, and task-local `active_job_id`.
- Single-job lease metadata has `lease_token`, expiry, owner, slot, and workspace.
- Commit fencing rejects stale or mismatched lease tokens.
- Phase4 task contracts can include `resource_locks[]` and `parallel_safety`.
- Scheduler helpers can explain dependency, resource-lock, stop-leasing, and serial-safety waits.
- Task-lane summary can display ready queue and waiting reasons.

Remaining blocker:

- State and scheduler still behave as if one active job is the hard maximum.
- `Get-NextAction` is still intentionally single-dispatch.
- No helper returns a batch of safe lease candidates.
- No lane-level capacity helper makes `max_parallel_jobs > 1` testable.

## 3. Non-Goals

- Do not make `max_parallel_jobs > 1` the default.
- Do not start a provider worker pool.
- Do not run provider execution concurrently.
- Do not implement isolated workspace or merge-back.
- Do not infer same-workspace safety from `changed_files[]` alone.
- Do not bypass lease fencing or single-writer commit.
- Do not remove compatibility fields such as `current_phase`, `current_task_id`, or `active_job_id`.
- Do not rewrite `cli.ps1 step`; it remains a one-job synchronous path.

## 4. Implementation Tasks

### PRP-01: Multi-Lease Capacity Model

Allow run-state to represent more than one active job when task-lane configuration explicitly permits it.

Acceptance:

- `task_lane.max_parallel_jobs` is normalized to an integer >= 1.
- `task_lane.mode` remains `single` by default.
- `Add-RunStateActiveJobLease` rejects additional jobs in `single` mode.
- `Add-RunStateActiveJobLease` allows additional jobs in `parallel` mode up to `max_parallel_jobs`.
- Duplicate leasing of the same task is rejected.
- Compatibility `active_job_id` remains set to a stable active job id for older readers.
- Multi-lease allowance is limited to explicit test/helper/control-plane paths; no production execution path creates more than one active lease in this slice.

Candidate files:

- `app/core/run-state-store.ps1`
- `tests/task-parallelization-ready-runstate.ps1`

### PRP-02: Batch Lease Candidate Planner

Add a scheduler helper that derives a deterministic batch of safe dispatch candidates without executing them.

Acceptance:

- Helper returns up to remaining lane capacity candidates.
- Candidates come from task contract state, not Phase4 prose batch summaries.
- Dependency, `stop_leasing`, resource-lock, active-job, and serial-safety constraints are respected.
- Candidate rows include `task_id`, `phase`, `role`, `selected_task`, `resource_locks`, `parallel_safety`, and `slot_id`.
- Existing `Get-NextAction` behavior remains unchanged.

Candidate files:

- `app/core/workflow-engine.ps1`
- `tests/task-parallelization-ready-scheduler.ps1`

### PRP-03: Lease Metadata Propagation

Make lease specs carry the scheduler constraint metadata needed by later worker slots.

Acceptance:

- Planned job specs can carry `resource_locks`, `parallel_safety`, `slot_id`, and `workspace_id`.
- `active_jobs[job_id]` preserves those fields when provided.
- Lease events can include resource locks and parallel safety where available.
- No existing single-step caller needs to provide the new fields.
- `workspace_id` is metadata only in this slice; it does not switch provider working directories, imply workspace isolation, or provide merge-back safety.

Candidate files:

- `app/core/run-state-store.ps1`
- `app/cli.ps1`
- `tests/task-parallelization-ready-runstate.ps1`

### PRP-04: Parallel-Ready Observability

Expose remaining capacity and batch-candidate information in read-only summaries.

Acceptance:

- `New-TaskLaneSummary` exposes `capacity_remaining`.
- Summary distinguishes `capacity_full` from `job_in_progress` when slots are full.
- Summary can include derived `lease_candidates` without persisting them.
- `watch-run` and dashboard surfaces can display capacity remaining.

Candidate files:

- `app/ui/task-lane-summary.ps1`
- `app/ui/dashboard-renderer.ps1`
- `app/ui/run-summary-renderer.ps1`
- `watch-run.ps1`
- `tests/task-parallelization-ready-ui.ps1`

### PRP-05: Parallel-Ready Regression Coverage

Add focused tests proving the system is parallel-ready but not yet running providers concurrently.

Acceptance:

- Two independent ready tasks can both be selected as lease candidates when `mode=parallel` and capacity is 2.
- Two leases can coexist in run-state under parallel mode.
- Same task cannot be leased twice.
- Resource-lock conflicts are excluded from the candidate batch.
- Serial tasks block co-dispatch.
- `Get-NextAction` still returns one dispatch action.
- Even with `task_lane.mode=parallel`, the existing `cli.ps1 step` production path cannot dispatch or execute more than one provider job.
- `workspace_id` metadata does not invoke isolated workspace or merge-back behavior.

Candidate files:

- `tests/task-parallelization-ready-runstate.ps1`
- `tests/task-parallelization-ready-scheduler.ps1`
- `tests/task-parallelization-ready-ui.ps1`
- `tests/regression.ps1`

## 5. Worker Split

- Worker A owns PRP-01 and PRP-03 run-state parts.
- Worker B owns PRP-02 and scheduler tests.
- Worker C owns PRP-04 and UI summary tests.
- Parent owns final regression integration and any small `cli.ps1` event projection adjustment if needed.
- Parent owns any `cli.ps1` edits so worker scopes stay disjoint.

## 6. Global Acceptance

- Plans exist as Markdown and JSON under `docs/plans`.
- The middle reviewer passes the task list before implementation.
- Targeted parallel-ready tests pass.
- Existing prep and conservative scheduler tests pass.
- Existing regression suite passes.
- The repo can represent and plan multiple concurrent task-lane leases under explicit `task_lane.mode=parallel`, but production provider execution remains gated.
- Existing `cli.ps1 step` cannot dispatch or execute more than one provider job even when fixture state uses `task_lane.mode=parallel`.
- Batch lease candidates are derived read-only and are not persisted as `ready_queue` or auto-leased by production paths.
