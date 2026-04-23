# Relay-Dev Troubleshooting Checklist

Use this checklist when a run looks wrong and you need to diagnose before acting.

## Read in this order

1. `runs/current-run.json`
2. `runs/<run-id>/run-state.json`
3. `runs/<run-id>/events.jsonl`
4. `runs/<run-id>/jobs/`
5. `.\app\cli.ps1 show`

## Symptom guide

| Symptom | Read first | Common meaning | Safe next move |
|---|---|---|---|
| Run does not advance | `run-state.json`, latest events | waiting, failed job, or unconsumed gate | summarize blocker, then decide whether `resume` is appropriate |
| `show` disagrees with expected state | `run-state.json`, `events.jsonl` | projection or stale read mismatch | trust canonical files first |
| Approval gate seems broken | `run-state.json`, approval-related events | wrong expectation about human review state | report exact gate and pending action |
| Provider job failed | `jobs/`, recent events | provider or prompt execution problem | explain failure surface before retrying |
| Phase looks unexpected | `run-state.json`, phase registry if needed | normal transition, stale assumption, or bad recovery | verify expected transition before acting |

## Guardrails

- prefer canonical files over projections
- prefer explanation before mutation
- prefer standard entrypoints over direct file edits
- hand off to `relay-dev-course-corrector` if the user wants to change scope rather than fix a failure
