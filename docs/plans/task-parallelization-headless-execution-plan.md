# Task Parallelization Headless Execution Plan

## 1. Purpose

This plan turns the parallel-ready control plane into an actually runnable headless parallel execution MVP for relay-dev.

The target is a guarded experimental path where task-lane jobs can be leased as a batch, executed concurrently by headless worker processes in isolated copy workspaces, and merged/committed back through the existing single-writer run lock.

## 2. Current Baseline

Already implemented:

- RunState can represent multiple `active_jobs`.
- Task lane can run in explicit `task_lane.mode = parallel` with `max_parallel_jobs > 1`.
- `resource_locks[]` and `parallel_safety` are accepted and reviewed in Phase4 contracts.
- `Get-BatchLeaseCandidates` derives multiple safe read-only candidates.
- `New-TaskLaneSummary`, `show`, dashboard, and `watch-run` expose active jobs, ready queue, capacity, and lease candidates.
- Lease fencing rejects stale or mismatched commits.
- Stale recovery can clear multiple stale active jobs while preserving live jobs.

Remaining blocker:

- Production `cli.ps1 step` still holds the run lock across provider execution and dispatches only one job.
- No command can lease a batch and run worker jobs concurrently.
- No worker command can execute a pre-leased job in an isolated workspace and commit it under a short run lock.

## 3. Scope

Implement a headless experimental parallel path:

- Add a new CLI command for parallel task-lane stepping.
- Lease a safe batch under the run lock.
- Persist one job package per leased job.
- Start one headless worker process per package.
- Workers execute providers outside the run lock.
- Workers acquire the run lock only at pre-commit/commit/state-update time.
- Parent waits for workers and returns a combined JSON result.
- Keep ordinary `step` sequential and unchanged as the safe default.

## 4. Non-Goals

- Do not make parallel mode the default.
- Do not remove or weaken existing sequential `step`.
- Do not implement git worktree as the isolation mechanism.
- Do not implement automatic conflict resolution for merge-back.
- Do not open visible worker terminals.
- Do not allow run-scoped phases to execute in parallel.
- Do not infer safety from `changed_files[]` alone.
- Do not support parallel repairer jobs in this MVP unless the existing transaction naturally repairs a job inside that worker.

## 5. Implementation Tasks

### HPE-01: CLI command surface and gating

Add explicit commands:

- `parallel-step`: parent command that leases and launches a headless batch.
- `run-leased-job`: internal worker command that executes one persisted package.

Acceptance:

- `step` remains sequential.
- `parallel-step` only dispatches when `current_phase` is task-scoped.
- `parallel-step` requires `task_lane.mode = parallel` and `max_parallel_jobs > 1`.
- `parallel-step` exits with a clear wait result when no candidates are available.
- `run-leased-job` requires a `-JobPackageFile` path.

Candidate files:

- `app/cli.ps1`
- `tests/task-parallelization-headless-execution.ps1`

Helper boundary:

- Add `Test-ParallelStepLaunchableCandidate` for parent/worker shared launchability rules.
- Do not put launcher or commit behavior in this helper.

### HPE-02: Batch lease and job package creation

Under one run lock, derive candidates and create active leases.

Acceptance:

- Candidate selection uses `Get-BatchLeaseCandidates`.
- Each leased job preserves `resource_locks`, `parallel_safety`, `slot_id`, and `workspace_id`.
- Each leased job emits `job.leased` and task selection events.
- Each leased job package includes job spec, prompt text, phase definition data needed by the worker, task id, phase, run id, and phase started timestamp.
- Job packages are written under the run's job directory and are forensic artifacts.
- Each job package records an isolated workspace baseline before provider execution starts.
- Each job package records declared task `changed_files[]` and the normalized allowed product paths.
- Each job package records the isolated workspace path assigned to the job.

Candidate files:

- `app/cli.ps1`
- `app/core/run-state-store.ps1` if a small helper is needed
- `tests/task-parallelization-headless-execution.ps1`

Helper boundary:

- Add `New-ParallelStepJobPackages` for candidate filtering, lease creation, prompt rendering, isolated workspace preparation, baseline capture, and package persistence.
- This helper must not launch provider processes.

### HPE-03: Worker execution command

`run-leased-job` executes one package.

Acceptance:

- Provider execution happens before acquiring the commit lock.
- The worker acquires the run lock in the pre-commit guard and holds it through artifact commit, state mutation, event append, and lease clear.
- Commit fencing rereads latest state under the run lock and validates `job_id`, `lease_token`, `phase`, `task_id`, lease expiry, lease presence, and `state_revision` compatibility.
- Commit rejection emits `job.commit_rejected` and exits nonzero.
- Successful worker completion emits the same essential events as sequential `step`: validation, committed artifacts, transition/approval/failure/completion, and status change.
- Before commit, the worker compares actual workspace changes against the package baseline and declared `changed_files[]`. Boundary drift rejects the commit.
- Under the run lock, worker merge-back copies only accepted changed files from isolated workspace to the main project workspace before canonical artifact/state commit.
- Merge-back rejects if the main workspace version of any target file changed since package baseline.
- When a worker result requests approval, it sets `task_lane.stop_leasing = true`. If another approval is already pending, the worker must reject/block the second approval commit with a clear `approval.commit_rejected` or `job.commit_rejected` event and leave the lease recoverable.

Candidate files:

- `app/cli.ps1`
- `tests/task-parallelization-headless-execution.ps1`

Helper boundary:

- Add `Invoke-LeasedJobPackage` for worker execution and commit.
- Add a small post-transaction helper only if it is shared with sequential `Invoke-EngineStep`; do not rewrite sequential flow.

### HPE-04: Parent worker launcher

`parallel-step` starts one worker process per package and waits for all workers.

Acceptance:

- Parent launches workers with hidden windows on Windows.
- Each worker has separate stdout/stderr log files.
- Parent waits for all workers and returns JSON summarizing job ids, task ids, package paths, exit codes, and log paths.
- Parent does not hold the run lock while workers execute.
- Worker failures stop new leasing on the next invocation by setting `task_lane.stop_leasing = true` or by leaving failed state through existing mutation rules.
- Parent emits/returns enough timing data to prove workers overlapped in focused tests.

Candidate files:

- `app/cli.ps1`
- `tests/task-parallelization-headless-execution.ps1`

Helper boundary:

- Add `Invoke-ParallelStepWorkers` for process launch/wait/result aggregation only.
- This helper consumes packages from `New-ParallelStepJobPackages` and never mutates run state directly.

### HPE-05: Isolated workspace and serial merge-back guard

Provider execution happens in a per-job isolated copy workspace. Repository mutation in the main project workspace happens only during merge-back under the run lock.

Acceptance:

- `parallel-step` only launches candidates whose `parallel_safety` is `parallel`.
- Candidates with empty declared `changed_files[]` are not launched by this MVP.
- Candidates with empty or conflicting `resource_locks` can still be handled by scheduler rules, but serial/cautious tasks are not launched concurrently by this MVP.
- If fewer than two launchable candidates remain, `parallel-step` returns a wait result unless `-AllowSingleParallelJob` is explicitly passed.
- The command output clearly labels workspace mode as `isolated-copy-experimental`.
- Workspace preparation copies the configured project workspace to a per-job directory under `runs/<run-id>/workspaces/<job-id>` while excluding heavy/runtime paths such as `.git`, `node_modules`, `.next`, `coverage`, and relay-dev runtime outputs.
- Provider `WorkingDirectory` is the isolated workspace. Relay-dev control-plane artifact paths remain the canonical main run paths from the prompt package.
- Baseline capture and actual diff detection run inside the isolated workspace, so sibling worker edits cannot appear in a job's diff.
- Actual isolated workspace changes outside declared task `changed_files[]` reject merge-back and commit.
- Main workspace target files are compared against the package baseline immediately before merge-back. If any target changed, merge-back is rejected with a clear conflict event.
- Merge-back copies only declared/accepted changed files from isolated workspace to main workspace under the run lock.
- Actual product changes to known shared files (`package.json`, lockfiles, migration directories, config shared by multiple tasks) reject merge-back unless protected by a matching `resource_locks[]` policy.
- Focused tests prove boundary drift prevents commit.

Candidate files:

- `app/cli.ps1`
- `tests/task-parallelization-headless-execution.ps1`

Helper boundary:

- Add `New-IsolatedJobWorkspace`, `New-WorkspaceBaselineSnapshot`, `Test-WorkspaceBoundaryDelta`, and `Invoke-IsolatedWorkspaceMergeBack`.
- These helpers must be usable by `Invoke-LeasedJobPackage` without depending on launcher behavior.

### HPE-06: Lease heartbeat and expiry policy

Workers running outside the run lock must keep their lease fresh.

Acceptance:

- Worker package execution starts a lightweight heartbeat loop or periodic heartbeat update process that updates `active_jobs[job_id].last_heartbeat_at` and extends `lease_expires_at` under short run locks.
- Heartbeat updates validate the current lease token before writing.
- Stale recovery must not clear a job whose heartbeat is fresh.
- If heartbeat cannot update, the worker continues to execution completion but commit fencing may reject the job; this emits a clear event.
- Focused tests cover fresh heartbeat preservation and expired lease commit rejection.

Candidate files:

- `app/core/run-state-store.ps1`
- `app/core/workflow-engine.ps1`
- `app/cli.ps1`
- `tests/task-parallelization-headless-execution.ps1`

### HPE-07: Focused regression coverage

Add tests with fake-provider or deterministic provider stubs.

Acceptance:

- Two independent `parallel_safety: parallel` tasks are leased and workers are launched.
- Parent does not keep `run.lock` held while workers execute.
- Worker commit clears its own lease and preserves other live leases until they commit.
- Sequential `step` still dispatches only one job.
- `parallel-step` refuses non-parallel lane mode.
- `parallel-step` refuses cautious/serial co-dispatch by default.
- Stale lease recovery still works after partial worker failure.
- Isolated workspace boundary drift rejects merge-back and commit.
- Main workspace drift on a declared target rejects merge-back.
- Heartbeat keeps live long-running workers from being recovered as stale.
- A second approval request is rejected or blocked when one approval is already pending.

Candidate files:

- `tests/task-parallelization-headless-execution.ps1`
- Existing targeted test files only if small shared fixtures are needed.

## 6. Worker Split

- Worker A owns HPE-01 and HPE-02: CLI surface, candidate gating, lease/package creation.
- Worker B owns HPE-03: worker package execution, pre-commit lock holding, state/event commit path.
- Worker C owns HPE-04 and HPE-05: parent process launcher, worker summaries, isolated workspace preparation, and serial merge-back guard.
- Worker D owns HPE-06: heartbeat state helpers and stale recovery integration.
- Parent owns HPE-07 integration tests, final conflict resolution, and all build/regression verification.

Workers should coordinate around helper boundaries:

- Worker A: `Test-ParallelStepLaunchableCandidate`, `New-ParallelStepJobPackages`.
- Worker B: `Invoke-LeasedJobPackage`.
- Worker C: `Invoke-ParallelStepWorkers`, isolated workspace and merge-back helpers.
- Worker D: heartbeat helpers in run-state/workflow code, plus CLI call sites.

All workers must avoid rewriting existing sequential `Invoke-EngineStep`.

## 7. Global Acceptance

- `parallel-step` can actually run at least two fake-provider task-lane jobs concurrently.
- The run lock is not held during provider execution.
- Commits are still single-writer and lease-fenced.
- Isolated copy workspace execution is used for provider concurrency.
- Serial merge-back rejects undeclared isolated changes and main workspace target drift.
- Heartbeat prevents live long-running workers from being stale-recovered.
- Single `pending_approval` safety is preserved by lane stop and second-approval rejection/blocking.
- `step` remains sequential and all existing tests pass.
- New focused headless execution tests pass.
- Full regression suite passes.
- Worklog records that provider parallel execution is available only through explicit experimental `parallel-step`.

## 8. Risks

### R-01: Workspace merge-back conflicts

This MVP avoids same-workspace provider races by using isolated copy workspaces. Merge-back can still conflict if main target files changed; MVP rejects those conflicts rather than resolving them.

### R-02: Duplicate commit or stale commit

Workers must acquire the run lock before commit and hold it through state mutation. Lease fencing must run against the latest state under that lock.

### R-03: Event/state divergence

The worker commit path should reuse or closely mirror the sequential post-transaction event and mutation path. Do not invent a second transition model.

### R-04: Repair flow writes while unlocked

If repair is triggered inside a parallel worker, repair status events must either be emitted under the commit lock or remain job-scoped only. Avoid broadening parallel repair semantics in this MVP.

### R-05: Approval collision

The current repository has one `pending_approval`. Parallel workers can race into approval. MVP behavior is lane stop plus second approval commit rejection/blocking, not multi-approval.

## 9. Follow-Up After MVP

- Git worktree-based isolation.
- Smarter merge-back conflict repair/rebase.
- Visible worker slot launcher.
- Task-local approval scopes and `pending_approvals`.
