# Relay-Dev Run Decision Table

Use this when deciding which relay-dev command to run next.

| Situation | Check first | Preferred action | Notes |
|---|---|---|---|
| Brand-new task | `tasks/task.md`, `runs/current-run.json` | `.\app\cli.ps1 new` | Make sure the task file matches the new request. |
| Existing run should continue | `runs/current-run.json`, `run-state.json` | `.\app\cli.ps1 resume` | Best default when the user wants to continue normally. |
| Existing run is `failed` but latest `run.failed` came from retriable provider/job failure | `run-state.json`, latest `run.failed`, latest `job.finished` | `.\app\cli.ps1 resume` | `resume` should recover the run back to the same phase only for safe retry cases such as `job_failed` with `provider_error` or `timeout`. |
| Existing run should continue in a visible Windows terminal | `runs/current-run.json`, `run-state.json`, current worker state | `.\start-agents.ps1 -ResumeCurrent` | Prefer this over hidden background resumes when the user wants to watch progress. |
| Only advance one orchestration step | `run-state.json`, `events.jsonl` | `.\app\cli.ps1 step` | Useful for debugging or controlled progress. |
| Only inspect status | `.\app\cli.ps1 show`, `run-state.json` | no state change | Prefer this before touching anything. |
| Dual-agent wrapper requested | `run-state.json`, CLI config | `.\start-agents.ps1` | Wrapper flow should sit on top of the canonical run state. |
| User wants to watch auto-progress on Windows | `run-state.json`, `wt.exe`, current worker state | launch a visible terminal via `.\start-agents.ps1` or `.\start-agents.ps1 -ResumeCurrent` | Avoid hidden background workers unless the user explicitly asks for them. |
| User wants approval in the same visible terminal | `run-state.json`, current worker state | `pwsh -NoLogo -NoProfile -File .\agent-loop.ps1 -Role orchestrator -ConfigFile config/settings.yaml -InteractiveApproval` | Use when a direct interactive worker is preferable to the wrapper. |
| User wants a read-only visible progress window | `run-state.json`, `events.jsonl` | `pwsh -NoLogo -NoProfile -File .\watch-run.ps1 -ConfigFile config/settings.yaml` | Shows canonical status, recent events, approval guidance, and the current approve target without mutating state. |
| Approval meaning looks ambiguous | `pending_approval.proposed_action`, `requested_phase`, recent reviewer verdict | explain the proposed action before asking for input | `approve` and `skip` accept the current `proposed_action`; they do not always mean numeric forward progress. |
| Status looks inconsistent | `run-state.json`, `events.jsonl` | inspect first | `queue/status.yaml` may lag because it is only a projection. |
| Existing run is `failed` for a non-retriable reason | `run-state.json`, latest `run.failed`, job stderr | inspect first | Do not force `resume`; investigate or course-correct instead. |
| Phase0 seed already exists | `outputs/phase0_context.*` and validator rules | import/seed Phase0, continue with Phase1 | Do not regenerate Phase0 if the seed is already good enough. |
| Waiting on a person | `run-state.json`, approval fields, recent events | summarize blocker | Report the exact gate, the approve target, and the next human action. |

Canonical files:

- `runs/current-run.json`
- `runs/<run-id>/run-state.json`
- `runs/<run-id>/events.jsonl`

Compatibility views:

- `queue/status.yaml`
- `outputs/`
- `dashboard.md`
