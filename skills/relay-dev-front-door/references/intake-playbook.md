# Intake Playbook

Use this reference when the user wants a detailed workshop rather than a quick clarification pass.

## Table Of Contents

1. Turn loop
2. Decision axes
3. Question patterns
4. Option framing
5. Working draft format
6. Exit criteria

## 1. Turn loop

Run a repeating loop:

1. summarize the current understanding in `2-6` lines
2. choose the single highest-value uncertainty
3. ask `1-3` focused questions
4. absorb the answer into the working draft
5. decide whether to deepen, narrow, or close

Use this loop until the request is ready for `relay-dev-seed-author`.

## 2. Decision axes

When deciding what to ask next, scan these axes in order.

### Outcome

- what does "done" look like
- what concrete deliverable is expected
- what problem becomes easier after this work

### User and operator

- who uses the system
- who operates it
- who approves success

### Scope boundary

- what must be included now
- what can wait
- what should explicitly stay out

### Priority

- what matters most: speed, safety, flexibility, cost, UX, maintainability
- if tradeoffs appear, which side wins

### Constraints

- technical environment
- tooling or provider restrictions
- schedule or staffing limits
- policy, compliance, or security boundaries

### Existing reality

- what already exists in the repo
- what cannot be broken
- what must stay compatible

### Acceptance criteria

- how we will know the work succeeded
- what evidence or tests will count
- what failure would look like

### Rollout

- greenfield vs migration
- phased rollout vs one-shot release
- can there be temporary inconsistency

Ask about the highest axis that is still blurry and will change downstream decisions.

## 3. Question patterns

Use the smallest pattern that moves the conversation.

### Clarify a vague request

- "いま一番達成したい結果は何ですか"
- "今回まず解きたい問題を一文で言うと何ですか"
- "最終的に何ができれば成功ですか"

### Split must-have vs nice-to-have

- "今回の必須要件と、できれば欲しい要件を分けるとどうなりますか"
- "時間が足りなければ何を先に切れますか"

### Surface non-goals

- "今回はやらないことを先に決めるとしたら何ですか"
- "誤って広げたくない範囲はありますか"

### Reveal hidden constraints

- "既存システムや運用で壊せない前提はありますか"
- "使える技術や使えない技術に制約はありますか"

### Force observable success

- "出来上がったとき、何を見て成功と言いますか"
- "どのテストや確認が通れば安心できますか"

### Pressure-test assumptions

- "この前提が外れたら計画はどこから崩れますか"
- "一番起きそうな現実的な失敗は何ですか"

## 4. Option framing

When the user is unsure, propose options instead of asking for a blank decision.

Good option framing looks like this:

- Option A: fastest path, narrower scope, lower coordination cost
- Option B: more flexible design, higher upfront design cost
- Option C: safest rollout, slower delivery, easiest to review

For each option, include:

- what it optimizes for
- what it sacrifices
- when you would choose it

If one option is your recommendation, say so and explain why in one sentence.

## 5. Working draft format

Keep an internal working draft and refresh it after every meaningful answer.

Suggested structure:

- `request_summary`
- `requirements`
- `constraints`
- `non_goals`
- `open_questions`
- `candidate_decisions`

`candidate_decisions` are useful during discussion even though they do not belong in the final handoff.
Use them to keep track of options currently being considered.

## 6. Exit criteria

Close the conversation when most of these are true:

- the main outcome is concrete
- the core scope boundary is visible
- hard constraints are known
- non-goals prevent obvious scope creep
- success criteria are testable enough
- remaining uncertainty is captured in `open_questions`

Do not keep questioning forever.
If the user says the direction is good enough, stop and hand off.
