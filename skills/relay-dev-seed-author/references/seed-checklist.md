# Phase0 Seed Checklist

Use this checklist before treating `outputs/phase0_context.*` as a valid pre-run seed.

## `tasks/task.md`

Confirm that it states:

- the current request
- concrete requirements
- constraints or non-goals
- any known delivery expectation

## `outputs/phase0_context.md`

Prefer these sections:

- project summary
- tech stack
- repository or framework roots
- directory layout
- conventions
- reusable modules or assets
- risks
- open questions

## `outputs/phase0_context.json`

Required keys:

```json
{
  "project_summary": "Short summary of the project",
  "project_root": "C:/path/to/project",
  "framework_root": "C:/path/to/project",
  "constraints": [
    "Do not rewrite generated files without approval"
  ],
  "available_tools": [
    "PowerShell 7",
    "git",
    "codex"
  ],
  "risks": [
    "Some runtime prompts still assume compatibility files"
  ],
  "open_questions": [
    "Should existing outputs be reused or regenerated?"
  ]
}
```

Validation-minded reminders:

- required string fields must be non-empty
- required array fields must exist
- required arrays should contain at least one meaningful item
- when something is unknown, add it to `open_questions`

Decision rule:

- valid and specific seed: import it and continue from Phase1
- invalid or stale seed: repair it or let Phase0 regenerate it
