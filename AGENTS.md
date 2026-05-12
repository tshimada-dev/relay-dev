# Agent Instructions

## Current Handoff

For work that may span compaction, interruption, or multiple turns, keep a short active handoff.

- Path: `docs/worklog/current.md`
- Purpose: quick recovery for in-progress work, not a polished worklog.
- Update it after the goal is clear, before risky edits, after failed verification, or when the next step changes.
- Clear it to `No active work` or summarize completion before the final response when the task is done.
- On recovery, read order should be: `AGENTS.md`, `docs/worklog/current.md`, `git status`, `git diff`, then only the relevant files.

## Worklog

After any substantive code, documentation, test, configuration, planning, or repository organization change, use the repo-local worklog skill before the final response.

- Skill: `skills/worklog/SKILL.md`
- Output path: `docs/worklog/YYYY-MM-DD.md`
- Append to the existing daily file when present.
- Mention in the final response whether the worklog was updated.
- If no worklog was updated, explain why in the final response.

This worklog rule is for human-operated repository maintenance and Codex sessions outside relay-dev runtime jobs. relay-dev Implementer, Reviewer, and Repairer provider jobs must follow `app/prompts/system/*.md` instead and must not create or edit `docs/worklog/*` unless the selected task explicitly requires worklog documentation or fixtures.

## Delegated Implementation

For broad implementation work where the user explicitly asks for the task-list JSON, reviewer-agent, parent TODO management, worker delegation, and parent final verification flow, use `skills/delegated-implementation/SKILL.md`.
