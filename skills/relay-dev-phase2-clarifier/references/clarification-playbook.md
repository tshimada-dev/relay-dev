# Phase2 Clarification Playbook

Use this reference when `Phase2` has paused the run and the user wants to decide the blockers interactively.

## 1. Detect The Pause

Check three things first:

- the current run is really waiting after `Phase2`, or the latest `phase2_info_gathering.json` still has meaningful `unresolved_blockers`
- the blocker text is not just a placeholder like `none`
- the issue is still about clarification, not a larger scope change

If the conversation turns into "we should change the whole direction", switch to `relay-dev-course-corrector`.

## 2. Normalize The Questions

Rewrite each blocker into an answerable question.

Good normalization looks like:

- blocker: "Need rollout strategy decision"
- question: "今回は本番切替を一括で行いますか、それとも段階リリースにしますか"

For each question, keep:

- why it matters to `Phase3`
- the safest default
- whether the answer belongs in `task.md`, `phase0_context.*`, or both

## 3. Turn Loop

Use this loop until the blockers are resolved enough:

1. summarize the current decisions in `2-5` lines
2. pick the highest-impact remaining blocker
3. ask `1-3` focused questions
4. offer `2-4` options with short tradeoffs if the user is unsure
5. restate the chosen answer in concrete wording
6. update the working draft

## 4. Update Matrix

Use this rule of thumb when applying the answers:

- requirement, scope boundary, success condition, rollout expectation:
  update `tasks/task.md`
- shared repo assumption, architecture boundary, environment fact, reusable risk:
  update `outputs/phase0_context.*`
- clarification that changes both product intent and shared context:
  update both

Default to updating upstream inputs, not current run artifacts.

## 5. Close-Out

You are ready to close when:

- every material blocker is resolved enough for design
- `task.md` and seed inputs reflect the answers
- the user can clearly see what changed

Then return a concise close-out:

- `clarification_summary`
- `resolved_decisions`
- `updated_files`
- `safe_to_resume=true`

If not, return:

- `remaining_questions`
- why they still block `Phase3`
- `safe_to_resume=false`
