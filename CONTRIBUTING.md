# Contributing

relay-dev is currently maintained as a portfolio-oriented development runner. Contributions should keep the control plane, artifact contracts, and public documentation aligned.

Before opening a change:

- Use PowerShell 7 (`pwsh`) for local checks.
- Run `pwsh -NoLogo -NoProfile -File tests/regression.ps1`.
- Run `pwsh -NoLogo -NoProfile -File scripts/check-public-examples.ps1` when touching `examples/`.
- Do not commit raw `runs/`, provider job logs, secrets, or local absolute paths in public examples.

For larger changes, prefer small slices that preserve `run-state.json` / `events.jsonl` as the canonical source of truth.
