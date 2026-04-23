# Phase2 clarification fallback

Phase2 is not the default requirements interview.
Use it only when Phase1 still left meaningful `unresolved_questions`.

The purpose of this phase is to reduce clarification debt before Phase3 design starts.

## Execution principles

- Treat `phase1_requirements.md` and `phase1_requirements.json` as the source of unresolved questions.
- Read repo files and existing documents to resolve as many unresolved questions as possible before leaving anything blocked.
- Convert questions that can be answered from repo context or explicit requirements into `decisions`.
- Leave items in `unresolved_blockers` only when they still materially affect Phase3 design and cannot be resolved safely from available evidence.
- Do not generate a new questionnaire for the user unless an item truly remains blocked.
- If `unresolved_blockers` remains non-empty, the workflow will pause for human clarification before design continues.
- Create only `phase2_info_gathering.md` and `phase2_info_gathering.json`.

## What good output looks like

Phase2 output should answer:

- What did we clarify from Phase1?
- What evidence supports those clarifications?
- What decisions are now safe to carry into Phase3?
- What blockers still remain, if any?
- What should Phase3 do next?

## Markdown output

Include these sections:

- clarification summary
- collected_evidence
- decisions
- unresolved_blockers
- source_refs
- next_actions

If helpful, add a short "resolved from Phase1 unresolved_questions" subsection, but keep the required sections above.

## JSON output

`phase2_info_gathering.json` must contain these arrays:

- `collected_evidence`
- `decisions`
- `unresolved_blockers`
- `source_refs`
- `next_actions`

## Quality bar

- `decisions` must be grounded in explicit evidence or explicit requirements.
- `unresolved_blockers` should be rare and concise.
- `unresolved_blockers` must describe only issues that still matter to Phase3 design.
- `unresolved_blockers` should be phrased so a human can answer them directly.
- `next_actions` should help Phase3 proceed, not just restate the problem.
- If a safe conservative default is already implied by repo context, record it as a decision instead of leaving it unresolved.

## What not to do

- Do not produce a numbered interview sheet as the main artifact.
- Do not emit `Q1 / A / B / C` style questionnaires unless a blocker genuinely still needs a human choice.
- Do not copy Phase1 unresolved questions verbatim without trying to resolve them.
- Do not invent answers that are not supported by evidence.
- Do not update orchestration state yourself.

## Suggested mindset

Think of this phase as:

- "close the remaining clarification debt"

not:

- "run a second requirements interview"
