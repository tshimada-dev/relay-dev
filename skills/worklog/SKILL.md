---
name: worklog
description: Record relay-dev work state and completed work. Use during substantive multi-step work to maintain docs/worklog/current.md for compaction recovery, and before the final response after any substantive code, documentation, test, configuration, planning, or repository change to append a concise entry under docs/worklog/YYYY-MM-DD.md.
---

# Worklog

Use this skill to keep repo-local work handoff and daily worklogs consistent.

## Current Handoff

Use `docs/worklog/current.md` as an active, overwrite-style recovery note for in-progress work.

Update it:

- after the goal and approach are clear
- before risky or broad edits
- after failed or surprising verification
- when the next step changes
- before a long-running command if interruption would be costly

Do not treat `current.md` as a polished audit log. It is a small handoff for fast recovery after compaction or interruption.

Use this format:

```markdown
# Current Handoff

## Goal
One or two sentences about the active task.

## Current State
What is already done and what is still in progress.

## Active Files
- `path/to/file`: why it matters right now

## Next Step
The next concrete action.

## Watch Outs
Risks, failed checks, user decisions, or `None`.
```

When the task is done, either delete `current.md` or replace its body with:

```markdown
# Current Handoff

No active work.
```

## When To Write

Append a worklog entry before the final response after any substantive:

- code change
- documentation change
- test or CI change
- configuration change
- planning or roadmap change
- file creation, deletion, rename, or repo organization change

Skip only for pure Q&A, exploration with no material outcome, or if the user explicitly asks not to write a worklog.

## Path

- Use `docs/worklog/YYYY-MM-DD.md`.
- Use the current local date.
- Create `docs/worklog/` if missing.
- Create the daily file if missing.
- Append to the daily file if it already exists.

## Daily File Header

If creating a new file, start with:

```markdown
# Worklog YYYY-MM-DD
```

## Entry Format

Append entries in this format:

```markdown
## HH:mm JST - Short Title

- Summary: What changed and why.
- Changed: Main files, directories, or areas touched.
- Verified: Commands run and result, or `Not run` with reason.
- Remaining: Follow-up work, risk, or `None`.
```

Keep entries concise. Prefer 3 to 6 bullets total. Do not paste long command output.

## Style Rules

- Write in Japanese by default.
- Keep commands, file paths, identifiers, and phase names as-is.
- Mention failed or skipped verification honestly.
- Do not rewrite old entries unless the user asks.
- If an existing daily file uses an older format, append the new entry using this skill's format and leave earlier content intact.

## Final Response

In the final response, briefly mention whether the worklog was updated and link the file.
