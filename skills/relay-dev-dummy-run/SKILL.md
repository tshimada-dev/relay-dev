---
name: relay-dev-dummy-run
description: Generate disposable relay-dev runs with plausible run-state and phase artifacts for manual verification, UI debugging, recovery testing, task-lane scheduling checks, Phase5/Phase6 artifact checks, and task-group worker scenarios. Use when Codex needs to create a dummy run instead of running the full relay-dev pipeline, or when the user asks for a fake/test run for a specific phase or scenario.
---

# Relay Dev Dummy Run

Use this skill to create disposable relay-dev runs that look real enough for `show`, UI summaries, recovery logic, task-lane scheduling, and artifact validators.

## Quick Start

Run the bundled script from a relay-dev checkout:

```powershell
pwsh -NoLogo -NoProfile -File .\skills\relay-dev-dummy-run\scripts\new-relay-dev-dummy-run.ps1 `
  -ProjectRoot . `
  -Scenario phase6-reject
```

The script prints JSON with `run_id`, `run_root`, `run_state_path`, generated artifact paths, and `next_commands`.

## Scenarios

- `phase5-ready`: creates Phase0 and Phase4 prerequisites plus a task lane ready to inspect or package Phase5 work.
- `phase6-reject`: creates a task with Phase5/Phase5-1/Phase5-2 history and a rejecting `phase6_result.json` with `rollback_phase=Phase5`.
- `task-group`: creates a parallel task group with isolated worker workspaces/artifact roots and mixed worker statuses.
- `ready-ui`: creates ready, blocked, cautious, serial, and active-job rows for task-lane summary/UI checks.
- `approval`: creates a run with a pending approval object and task cursor context.

Prefer these canned scenarios over hand-writing `run-state.json`. If a scenario is not close enough, generate the closest one and patch the resulting run artifacts or extend the script.

## Workflow

1. Resolve the relay-dev checkout path. Use the user's workspace when available.
2. Choose the narrowest scenario that exercises the target behavior.
3. Run `scripts/new-relay-dev-dummy-run.ps1`.
4. Inspect the emitted JSON and use its `next_commands`.
5. When validating artifact contracts, dot-source relay-dev core files or use existing tests after the dummy run is generated.

## Safety

Dummy runs are created under `<ProjectRoot>\runs\<run_id>`. The script refuses to overwrite an existing run unless `-Force` is passed. It does not delete existing runs.
