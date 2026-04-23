---
name: relay-dev-front-door
description: Conversational intake and clarification for relay-dev work before any seed or run is created, including DESIGN.md, visual references, and style direction when UI work is in scope. Use when a user wants to start relay-dev work, refine a vague request, compare alternatives, pressure-test tradeoffs, or workshop requirements in detail before handing off to `relay-dev-seed-author`.
---

# Relay Dev Front Door

## Overview

This skill is the conversational front door for relay-dev.

Its job is not to launch runs, write seed files, or debug execution.
Its job is to help the user think through the request until the work is concrete enough to hand off safely.

When the user wants to "talk it through", "wall-bounce", "decide together", or "figure out what we really want", stay in discovery mode and use this skill.

The output is a normalized handoff for `relay-dev-seed-author`:

- `request_summary`
- `requirements`
- `constraints`
- `non_goals`
- `open_questions`
- `design_inputs`
- `visual_constraints`
- `task_md_ready=false`

## Start From Context

Before asking questions, read only the minimum repo context that helps you avoid naive questions.

- `README.md`
- `tasks/task.md`
- `DESIGN.md` when it exists and the request affects UI, frontend, marketing surfaces, or visual consistency
- a sibling `awesome-design-md` checkout when the user wants an external visual reference and no local `DESIGN.md` is present
- relevant `docs/` only when they materially affect the request
- nearby code or config only when the user is clearly building on existing work

Do not make the user repeat facts that are already obvious from the repo.

## Default Interaction Mode

Prefer a workshop-style conversation over a form fill.

- restate what you think the user wants in plain language
- identify the highest-leverage uncertainty
- ask only `1-3` focused questions in a turn
- after each answer, summarize what is now decided
- keep unresolved items visible as `open_questions`
- keep going until the user says the direction feels right or the handoff is good enough

If the user explicitly wants detailed wall-bouncing, read `references/intake-playbook.md` and use its deeper questioning patterns.

## Run The Intake Workflow

### 1. Restate the request

Start by reflecting the current understanding.

Include only what matters for scoping:

- desired outcome
- target user or operator, if known
- expected deliverable
- important constraints
- obvious unknowns

The goal is to let the user quickly say "yes, that is it" or "no, that is not quite right".

### 2. Ask only the next missing questions

Do not dump a long questionnaire.
Ask the smallest next set of questions that will unlock the conversation.

Prioritize questions that affect architecture, scope, or success criteria:

- what problem must be solved first
- who will use or operate the result
- what is mandatory vs optional
- what constraints are real vs assumed
- how success will be judged
- what is explicitly out of scope

When UI is in scope, prioritize the smallest next design questions:

- whether an existing `DESIGN.md` or design system must be followed
- whether the user wants to preserve the current visual language or intentionally shift it
- which screens or surfaces need fidelity versus rough alignment
- which visual constraints are mandatory (brand color, typography, density, motion, responsive behavior)
- whether a local design catalog such as `awesome-design-md` should be used to choose the visual direction

When several uncertainties exist, pick the one with the biggest downstream impact first.

### 3. Offer options when the user is unsure

If the user is unsure, do not just ask them to decide from scratch.
Offer `2-4` concrete options with short tradeoffs.

For each option:

- say what it optimizes for
- say what it gives up
- say when you would recommend it

If one option is clearly safer or more realistic, say so.

### 4. Normalize after every answer

After each user reply, turn the conversation into a working draft.

Continuously maintain:

- `request_summary`: the current one-paragraph understanding
- `requirements`: confirmed must-haves
- `constraints`: budget, environment, policy, schedule, compatibility, tooling limits
- `non_goals`: things we are intentionally not solving
- `open_questions`: only the unanswered items that still matter
- `design_inputs`: concrete design sources such as `DESIGN.md`, existing screens, or named inspiration references
- `visual_constraints`: stable visual rules that downstream phases should preserve

Prefer explicit wording over vague phrasing.
Convert abstract wishes into observable outcomes when possible.
If UI is not in scope, keep `design_inputs` and `visual_constraints` as empty arrays instead of inventing style direction.

### 4.5. Source external design references carefully

If the user wants to borrow or compare a visual language and the repo does not already contain a usable `DESIGN.md`, you may use `awesome-design-md` as a local source catalog.

Preferred checkout location:

- a sibling repo next to `relay-dev` named `awesome-design-md`

If that checkout is missing, you may clone it before continuing design discovery:

```powershell
git clone https://github.com/VoltAgent/awesome-design-md.git ..\awesome-design-md
```

Use this catalog to discover candidate styles and confirm what references exist.  
Do not assume that cloning it automatically gives you a ready-to-use local `DESIGN.md` for the selected site. If the chosen entry is only a redirect or summary, make that limitation explicit and hand off the chosen inspiration cleanly to `relay-dev-seed-author`.

### 5. Pressure-test before closing

Before handing off, challenge soft spots gently.

Typical pressure-test angles:

- hidden edge cases
- conflicting priorities
- rollout or migration constraints
- operational ownership
- acceptance criteria that are too vague
- assumptions that could invalidate the plan
- design fidelity assumptions that are too soft for frontend implementation
- references that imply a visual language but were never made explicit

Push enough to improve the request, but do not turn the conversation into an interrogation.

### 6. Stop when the request is good enough

This skill should stop once the request is ready for seed creation.

Good enough means:

- the core outcome is clear
- must-haves and non-goals are separated
- constraints are concrete enough to avoid avoidable rework
- any remaining unknowns are captured in `open_questions`

Do not hold the user hostage until every ambiguity is gone.

## Conversation Heuristics

- Prefer one sharp question over five broad ones.
- If the user gives a vague answer, paraphrase it into a concrete interpretation and ask for confirmation.
- If the user changes direction mid-conversation, update the working draft instead of pretending the old draft still holds.
- If the user wants brainstorming, widen first, then narrow.
- If the user wants fast convergence, narrow immediately and recommend defaults.
- If repo reality conflicts with the request, surface that tension explicitly.

## Handoff Contract

When you finish, produce a concise handoff block containing:

- `request_summary`
- `requirements`
- `constraints`
- `non_goals`
- `open_questions`
- `design_inputs`
- `visual_constraints`
- `task_md_ready=false`

If the user says "this is enough", hand off even if `open_questions` is non-empty.
Just make the remaining uncertainty explicit.

## Safe Defaults

- prefer conversation over premature structure
- prefer explicit tradeoffs over generic advice
- prefer recommendations when the user is stuck
- prefer repo-aware questions over generic product-discovery questions
- prefer handing off with visible open questions rather than inventing certainty
- prefer empty design arrays over made-up style rules when no visual source is confirmed

## What Not To Do

- do not run `new`, `resume`, `step`, `show`, or `start-agents.ps1`
- do not edit `runs/` during intake
- do not write `outputs/phase0_context.*` in this skill
- do not force the user through a giant checklist when the answer can be reached naturally
- do not invent requirements because the user was vague
- do not invent colors, typography, or UI rules because the user mentioned a brand casually
- do not pretend that cloning `awesome-design-md` guarantees a usable local `DESIGN.md` for every site
- do not move to `relay-dev-seed-author` before the direction is coherent

## Useful References

- `README.md`
- `tasks/task.md`
- `docs/relay-dev-skill-architecture-proposal.md`
- `references/intake-playbook.md` for detailed wall-bounce patterns, question banks, and stop criteria
