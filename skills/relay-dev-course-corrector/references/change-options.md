# Relay-Dev Change Options

Use this guide when the user wants to change direction rather than fix a failure.

## Classify the request

| Request type | Typical user wording | Prefer first |
|---|---|---|
| rollback | "違ったので戻したい" | identify what should be preserved before suggesting action |
| pause | "いったん止めたい" | summarize current state and leave artifacts untouched |
| pivot | "途中で方針を変えたい" | update requirements and seed before touching control-plane commands |
| restart | "最初からやり直したい" | keep the old run for traceability and start a fresh run if needed |

## Impact guide

| Surface | Questions to answer |
|---|---|
| `tasks/task.md` | Does the request itself change? |
| `outputs/phase0_context.*` | Is the shared context still valid after the pivot? |
| current run | Would continuing this run hide or mix two intents? |
| generated artifacts | Should they be kept as history, reused, or ignored? |

## Conservative defaults

- keep history unless there is a clear reason not to
- prefer updating requirements before launching commands
- prefer a new run when the request meaningfully changes after work has already progressed
- hand off to `relay-dev-troubleshooter` only when the problem is operational rather than directional
