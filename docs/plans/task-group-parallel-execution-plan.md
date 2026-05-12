# Task Group Parallel Execution Plan

## 1. Purpose

This plan describes the next architecture for relay-dev task parallelization: run multiple task workers in one parent group, where each worker owns one task from Phase5 through Phase6, and the parent group completes only after every worker reaches a successful Phase6 result.

The goal is to move from phase-level parallelism to task-lifecycle parallelism.

Current phase-level model:

```text
parallel-step:
  T-01 Phase5
  T-02 Phase5
  T-03 Phase5
```

Target group model:

```text
task-group:
  worker T-01: Phase5 -> Phase5-1 -> Phase5-2 -> Phase6
  worker T-02: Phase5 -> Phase5-1 -> Phase5-2 -> Phase6
  worker T-03: Phase5 -> Phase5-1 -> Phase5-2 -> Phase6

group completes when all workers finish Phase6 with go or conditional_go semantics accepted by the existing phase contracts.
```

## 2. Current Baseline

Already implemented or recently added:

- Task lane can select multiple task candidates.
- Each parallel job gets an isolated copy workspace.
- Workers execute outside the parent run lock.
- Lease fencing prevents stale worker commits.
- `changed_files[]` are now treated as implicit scheduler locks, so tasks touching the same declared file cannot be selected into the same parallel batch even if Phase4 emits different `resource_locks[]`.
- Existing `parallel-step` still executes one phase per worker and lets each worker mutate the parent run-state directly.

Known problems with the current model:

- A worker failure in Phase5 can fail the parent run while sibling workers are still running.
- Failed job attribution can diverge from the parent `current_task_id`.
- Parent run-state observes partial per-task phase transitions instead of a coherent group result.
- Artifact paths are fragile when a worker writes artifacts inside an isolated workspace but the parent validator expects parent-side staged artifacts.
- Automatic failed-run recovery can retry the parent cursor rather than the actual failed worker task.

## 3. Target Semantics

A task group is a parent-owned execution unit.

- The parent leases a group of safe task candidates.
- Each worker receives exactly one task.
- Each worker runs the full task lifecycle locally: Phase5, Phase5-1, Phase5-2, and Phase6.
- Worker-local artifacts are validated at each phase before the next phase starts.
- Worker product changes remain isolated until the worker reaches Phase6.
- The parent run-state is not advanced through each worker's intermediate Phase5, Phase5-1, or Phase5-2 state.
- The parent records group progress, worker status, and final worker results.
- The parent commits canonical artifacts and product changes only at the group boundary.

Group result rules:

- `succeeded`: every worker reaches an accepted Phase6 result and group merge/commit succeeds.
- `failed`: one or more workers end in provider error, invalid artifacts, invalid transition, timeout, or rejected merge.
- `waiting_approval`: a worker reaches a phase that requires human approval, or the group-level merge/review requires approval.
- `partial_failed`: optional diagnostic status for a group where some workers succeeded and some failed, before recovery or retry policy is applied.

## 4. Non-Goals

- Do not remove the existing sequential `step` path.
- Do not make group execution the only parallel implementation in the first slice.
- Do not bypass Phase5, Phase5-1, Phase5-2, or Phase6 validators.
- Do not allow workers to commit directly to canonical parent artifacts mid-lifecycle.
- Do not auto-resolve merge conflicts.
- Do not let failed group recovery retry the parent cursor without worker/task attribution.
- Do not infer broad directory conflicts beyond exact `changed_files[]` overlap in the first slice.

## 5. First-Slice Decisions

The first implementation slice is intentionally narrower than the full architecture.

- Implement only group data model, deterministic group dry-run planning, read-only `show` rendering, and scheduler/file-lock tests.
- Do not run worker lifecycles in the first slice.
- Do not merge product changes or commit group artifacts in the first slice.
- Default group policy is `wait_for_siblings`: no fail-fast unless explicitly configured later.
- Future group commit policy starts as all-or-nothing: if any worker fails or merge fails, the group does not partially commit canonical outputs.
- Approval-capable worker execution is deferred. Until worker lifecycle exists, group planning must not imply approval handling is implemented.
- Recovery implementation is deferred. The first slice may add data fields needed for attribution, but it must not auto-retry groups.

## 6. Proposed Data Model

Add group state alongside existing job state.

```text
task_groups:
  <group_id>:
    status: running | succeeded | failed | waiting_approval | partial_failed
    phase_range: Phase5..Phase6
    worker_ids: [...]
    created_at
    updated_at
    failure_summary

task_group_workers:
  <worker_id>:
    group_id
    task_id
    status: queued | running | succeeded | failed | waiting_approval
    current_phase: Phase5 | Phase5-1 | Phase5-2 | Phase6
    workspace_path
    lease_token
    declared_changed_files
    resource_locks
    result_summary
```

Compatibility fields such as `active_job_id`, `active_jobs`, `current_phase`, and `current_task_id` should remain for existing readers. During group execution, they should describe the parent group or remain stable enough for `show` and recovery to avoid misleading cursor-based retries.

## 7. Implementation Tasks

### TGP-01: Group Planning And Leasing

Add a group planner that uses the existing batch scheduler but produces one group package instead of independent phase jobs.

Acceptance:

- Group candidates respect dependencies, `parallel_safety`, explicit `resource_locks[]`, and implicit `file:<changed_file>` locks.
- The planner emits a deterministic `group_id`.
- Each worker package includes task contract, declared files, phase range, workspace path, and initial lease metadata.
- Parent run-state records the group as active before worker processes launch.
- Existing `parallel-step` behavior remains available for comparison until the group path is validated.
- First-slice test coverage includes dry-run group planning, deterministic group ids, and explicit plus implicit lock conflicts.

Candidate files:

- `app/cli.ps1`
- `app/core/workflow-engine.ps1`
- `app/core/parallel-job-packages.ps1`
- `app/core/run-state-store.ps1`

### TGP-02: Worker-Local Phase Loop

Add a worker command that runs the task lifecycle loop locally.

Acceptance:

- A worker starts at Phase5 for its assigned task.
- After each phase, the worker validates required artifacts before moving to the next phase.
- Phase5-1 and Phase5-2 consume worker-local Phase5 artifacts, not parent canonical artifacts.
- Phase6 consumes worker-local validated outputs.
- Worker status is heartbeated to the parent group state.
- A worker stops on invalid artifact, provider error, timeout, approval pause, or invalid transition.
- Test coverage includes a fake-provider worker loop through Phase5 to Phase6 and invalid-artifact stop behavior.

Candidate files:

- `app/cli.ps1`
- `app/core/parallel-worker.ps1`
- `app/core/phase-execution-transaction.ps1`
- `app/core/phase-validation-pipeline.ps1`

### TGP-03: Worker Artifact Repository Boundary

Make artifact storage explicit for group workers.

Acceptance:

- Worker output paths resolve inside the worker package artifact root.
- Worker validators read the same artifact root that prompts tell providers to write.
- Parent canonical artifacts are not touched until group commit.
- Artifact paths are recorded with enough metadata for debugging and replay.
- The old isolated-workspace path mismatch is covered by a regression test.
- Test coverage proves worker prompts and validators resolve the same artifact root.

Candidate files:

- `app/core/artifact-repository.ps1`
- `app/core/phase-validation-pipeline.ps1`
- `app/core/phase-completion-committer.ps1`
- `app/core/parallel-worker.ps1`

### TGP-04: Group Coordinator And Result Aggregation

Add a parent coordinator that launches workers, waits for them, and aggregates results before mutating the parent workflow.

Acceptance:

- Parent does not mark the run failed while sibling workers are still running unless the configured policy is fail-fast.
- Default policy should let running siblings finish, then report a group-level result.
- Group result includes one row per worker with task id, final phase, status, errors, artifact refs, and changed files.
- Parent JSON output exposes group status and worker summaries.
- `show` renders active group state without pretending the parent cursor is a single worker task.
- Test coverage includes one worker failing while sibling workers finish and parent reports a group-level failure.

Candidate files:

- `app/core/parallel-launcher.ps1`
- `app/core/workflow-engine.ps1`
- `app/ui/task-lane-summary.ps1`
- `app/ui/run-summary-renderer.ps1`

### TGP-05: Group Merge And Commit

Move product merge and canonical artifact commit to the group boundary.

Acceptance:

- Only workers that reached accepted Phase6 are eligible for merge.
- Merge checks parent workspace drift before copying worker changes.
- Exact `changed_files[]` overlap should already be prevented by scheduling, but merge still detects conflicts.
- Canonical artifacts for Phase5 through Phase6 are committed after successful worker validation and group merge.
- If merge fails, the group fails with conflict details and no partial canonical commit.
- Optional later enhancement: commit successful non-conflicting workers while marking failed workers for retry. This is not required for the first slice.
- Test coverage includes successful all-or-nothing commit and rejected conflict with no partial canonical commit.

Candidate files:

- `app/core/parallel-workspace.ps1`
- `app/core/phase-completion-committer.ps1`
- `app/core/artifact-repository.ps1`
- `app/core/workflow-engine.ps1`

### TGP-06: Recovery And Retry Semantics

Make recovery group-aware.

Acceptance:

- Failed group recovery keys include `group_id`, `worker_id`, `task_id`, and final phase.
- Automatic failed-run resume must not retry the parent cursor when a worker-specific failure caused the group failure.
- Retrying a failed worker should preserve successful sibling outputs unless the group policy chooses full group retry.
- Stale worker recovery uses heartbeat plus process liveness and can clear or mark only the affected worker.
- Manual stop leaves the group in a state that resumes predictably.
- Test coverage includes failed-worker attribution and no parent-cursor retry on worker-specific failures.

Candidate files:

- `agent-loop.ps1`
- `app/cli.ps1`
- `app/core/workflow-engine.ps1`
- `app/core/run-state-store.ps1`

Dependencies:

- TGP-01
- TGP-04
- TGP-05

### TGP-07: Tests And Rollout

Add cross-slice tests before making group execution the default path. Per-slice tests are listed on each implementation task above.

Acceptance:

- Unit tests cover group planning with explicit and implicit file locks.
- Headless group execution test runs at least two workers through Phase5 to Phase6 using a fake provider.
- Regression test covers worker-local artifacts being found and validated.
- Regression test covers one worker failing while siblings finish and parent reports a group-level failure.
- Recovery test covers failed worker retry attribution.
- Existing sequential `step` and current `parallel-step` tests continue to pass.

Candidate files:

- `tests/task-group-parallel-execution.ps1`
- `tests/task-parallelization-headless-execution.ps1`
- `tests/task-parallelization-scheduler.ps1`
- `tests/regression.ps1`

## 8. Suggested Rollout

1. Add data model and read-only `show` rendering for active groups.
2. Add `group-step --dry-run` to produce candidate groups without launching workers.
3. Add fake-provider headless group execution.
4. Add worker-local artifact root and validation.
5. Add group boundary merge/commit.
6. Add recovery and retry behavior.
7. Gate default `step` to prefer group execution only after the above tests pass with a real provider smoke run.

## 9. Deferred Questions

- Should a later group merge require an explicit group-level review phase after all worker Phase6 results pass?
- Should a later version support partial successful-worker commit after all-or-nothing group commit is stable?
- Should `Phase5-1` and `Phase5-2` reviewers run as separate provider invocations inside the same worker process, or as child worker commands with the same worker artifact root?
- How should group execution interact with human approval phases once approval-capable workers are implemented?
