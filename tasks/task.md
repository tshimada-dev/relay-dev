# Current Task

## Title
Add an opt-in human-readable run summary to `app/cli.ps1 show` for safe workflow validation

## Why
relay-dev is still in the development stage, so the first validation task should be a small vertical slice that is easy to review and unlikely to disturb orchestration.

The goal of this task is to confirm that operators can inspect canonical run state quickly during manual testing without changing the workflow engine, provider adapters, or compatibility projections.

## Requested Outcome
Add a human-readable summary mode for the existing `show` entrypoint so an operator can understand the current run at a glance while preserving the current machine-readable JSON path.

## Functional Requirements
- Keep `app/cli.ps1 show` available as the canonical inspection entrypoint.
- Preserve the current JSON output path for scripts and automation; make the human-readable summary opt-in via an additional parameter or equivalent safe mechanism.
- Read canonical state from `runs/current-run.json` and `runs/<run-id>/run-state.json`.
- Do not parse `queue/status.yaml` as the source of truth.
- Show at least: `run_id`, `status`, `current_phase`, `current_role`, `current_task_id` when present, and `active_job_id` when present.
- If `open_requirements` exist, show how many remain unresolved.
- If `pending_approval` exists, show that clearly and include the requested phase.
- Reuse or extend existing UI-side helper code such as `app/ui/run-summary-renderer.ps1` if that keeps the change smaller and clearer.
- Handle the no-active-run case with a clear operator-facing message.

## Constraints
- Keep the implementation in PowerShell.
- Treat `run-state.json` and related canonical state as the source of truth.
- Avoid changes to workflow-engine behavior, phase transition rules, approval semantics, or provider execution.
- Keep compatibility projections such as `queue/status.yaml` and `outputs/` working as they are today.
- Prefer a small, reviewable change set with clear regression evidence.

## Non-Goals
- Do not redesign the dashboard or add a new UI.
- Do not add a new long-running watcher or background process.
- Do not refactor the provider adapter layer.
- Do not change the review gate model.
- Do not replace or remove the existing JSON output path from `show`.

## Acceptance Criteria
- An operator can run one command for a human-readable summary and understand the current run state at a glance.
- Existing automation that expects JSON from `app/cli.ps1 show` continues to work.
- The summary is derived from canonical run state rather than `queue/status.yaml`.
- Pending approval and unresolved open requirements are visible when present.
- The implementation is small enough to serve as a safe first workflow-validation task.
- Regression coverage is added or updated for the summary mode.

## Suggested Verification
- Create or reuse a test run and confirm the summary output reflects the current phase, role, task, and active job.
- Confirm a pending-approval state is rendered clearly.
- Confirm unresolved `open_requirements` are counted and shown.
- Confirm the default JSON mode of `app/cli.ps1 show` still works.
- Run `pwsh -NoLogo -NoProfile -File tests/regression.ps1`.
