---
name: relay-dev-seed-author
description: Prepare and normalize `tasks/task.md` plus `outputs/phase0_context.*` so relay-dev can start from a valid pre-run seed, including DESIGN.md-derived design inputs and visual constraints when UI work is in scope. Use when requirements are clarified enough to write task and Phase0 context files, when an existing seed must be repaired or validated, or when deciding whether a good seed should be imported instead of regenerating Phase0.
---

# Relay Dev Seed Author

## Overview

この skill は、`front-door` で整理した依頼を `tasks/task.md` と `outputs/phase0_context.*` に落とし込む。  
目的は、relay-dev を起動できるだけの task / seed を作り、`relay-dev-operator-launch` へ渡すこと。

UI 変更やデザイン追従が絡む場合は、`DESIGN.md` や visual reference を `design_inputs` / `visual_constraints` として seed に固定し、後続の `visual_acceptance_criteria` / `visual_contract` へ渡しやすくする。

## Keep The Artifacts Straight

役割を混同しない。

- `tasks/task.md`: 今回の依頼、成果物、制約
- `outputs/phase0_context.md`: 人間向けの pre-run seed
- `outputs/phase0_context.json`: validator を通す機械可読 seed
- `DESIGN.md`: optional external design source。run artifact ではない
- `runs/<run-id>/artifacts/run/Phase0/...`: run 開始後の canonical artifact

`outputs/phase0_context.*` は pre-run bootstrap として使える。  
ただし run 開始後の source of truth ではない。

## Run The Authoring Workflow

### 1. Start from the handoff

`front-door` から、最低限次を受け取る前提で進める。

- `request_summary`
- `requirements`
- `constraints`
- `non_goals`
- `open_questions`
- `design_inputs`
- `visual_constraints`

不足が大きい場合は無理に埋めず、`front-door` に戻して clarification を増やす。

### 2. Normalize `tasks/task.md`

`tasks/task.md` には少なくとも次が入っている状態を目指す。

- what: 何を作るか、何を直すか
- why: 何のためか
- requirements: 必須要件
- constraints: 制約、非目標、禁止事項
- verification: どう確認するか

UI が絡む依頼では、task.md にも visual verification の種を残す。

- どの surface が `DESIGN.md` 準拠か
- どの visual constraint が必須か
- 何を「見た目が合っている」とみなすか

今回の依頼を優先し、プロジェクト全体の一般論で埋めないこと。

### 3. Inspect the existing seed before rewriting it

次を読んで、既存 seed の再利用可否を先に判断する。

- `outputs/phase0_context.md`
- `outputs/phase0_context.json`
- `DESIGN.md`（存在する場合）
- `config/settings.yaml`
- `app/prompts/phases/phase0.md`
- `app/core/artifact-validator.ps1`
- `references/seed-checklist.md`

valid で具体的な seed があるなら、再生成より import を優先する。

### 4. Decide import vs refresh

import を優先する条件:

- JSON が required key を満たしている
- required array が空でない
- 現在の repo と task に整合している
- `design_inputs` / `visual_constraints` が current task の visual source と矛盾しない

更新または再作成が必要な条件:

- JSON の必須項目が欠けている
- path や summary が古い
- 別プロジェクトの文脈が混ざっている
- 今回の task とズレている
- `DESIGN.md` の要点が未反映、または別の visual source が混ざっている

### 5. Resolve the design source before summarizing it

`DESIGN.md` の path はまず設定から解決する。

- `config/settings.yaml` の `paths.design_file`
- 未設定なら `paths.project_dir` 配下の `DESIGN.md`

UI タスクで外部の visual reference が必要なのに local `DESIGN.md` がない場合は、`awesome-design-md` を source catalog として使ってよい。

- 優先する checkout 位置は `relay-dev` の sibling repo `..\awesome-design-md`
- checkout がなければ、repo root から次で clone してよい

```powershell
git clone https://github.com/VoltAgent/awesome-design-md.git ..\awesome-design-md
```

ただし、これは candidate を探すための catalog として扱う。  
clone 後に選んだ site 配下が redirect README だけなら、そこから `DESIGN.md` が既に取得できた前提で seed を埋めない。ユーザー提供の visual reference、既存画面、または確認済みの design note だけを `design_inputs` / `visual_constraints` に落とす。

存在する場合は全文を丸ごと seed にコピーせず、後続フェーズで再利用する stable facts だけを抽出する。

- `design_inputs`: 出典の列挙。例: `DESIGN.md`, existing admin dashboard, marketing homepage
- `visual_constraints`: 色、タイポ、密度、トーン、コンポーネント傾向、responsive rule などの短い箇条書き

UI が無関係なら両方とも空配列でよい。

### 6. Write for the next phase, not for elegance

`phase0_context.md` には、後続フェーズが再利用しやすい事実だけを書く。

- tech stack
- 主要ディレクトリ構成
- coding conventions
- 再利用できる既存資産
- 重要制約
- 未確定事項
- visual source と stable visual constraints（ある場合）

不明点は捏造せず、`open_questions` に残す。

`phase0_context.json` では、少なくとも次を埋める前提で考える。

- `design_inputs`
- `visual_constraints`
- `task_fingerprint`
- `task_path`
- `seed_created_at`

UI タスクで design source があるなら空のままにしない。  
非 UI タスクなら空配列でよい。
`task_fingerprint` は現在の `tasks/task.md` から SHA-256 を計算して入れる。古い seed をコピーした値で済ませない。

### 7. Validate before handoff

最低限、`phase0_context.json` が Phase0 contract を満たすか確認する。  
必要なら `app/core/artifact-validator.ps1` の `Test-ArtifactContract` を使って deterministic に検証する。

## Finish With A Launch Handoff

完了条件は「seed を書いた」で終わりではない。  
次の状態まで整える。

- `tasks/task.md` が更新済み
- `outputs/phase0_context.*` が valid、または不足理由が明示済み
- `task_md_ready=true`
- `phase0_seed_ready=true|false`
- `design_seed_ready=true|false`
- `recommended_command` の候補が言える

## What Not To Do

- `outputs/phase0_context.*` を canonical source と扱わない
- 不明な repo 事情を想像で埋めない
- required array を空のままにしない
- 起動や run 監視まで抱え込まない
- valid な seed があるのに再生成を強要しない
- `DESIGN.md` を長文転載して token を浪費しない
- visual rule が未確定なのに、見た目の好みで `visual_constraints` を埋めない
- `awesome-design-md` を clone しただけで、取得できていない `DESIGN.md` の内容を推測しない

## Useful References

- `references/seed-checklist.md`
- `README.md`
- `config/settings.yaml`
- `app/core/artifact-validator.ps1`
- `app/prompts/phases/phase0.md`
