# open requirements carry-forward 改善案

## 1. 背景

現在の relay-dev では、未解決条件は `open_requirements[]` として run-state に蓄積され、
後続 verdict artifact の `resolved_requirement_ids[]` によって解消される。

この構造自体は健全で、最終的には `Phase7` が「未解決条件を残したまま `go` にしない」最後のゲートになっている。

一方で、実装フェーズ側から見ると次のギャップがある。

- `Phase7` は最終ゲートとしては強いが、「今の task でどの carry-forward を拾うべきか」を前段に明示する仕組みではない
- `Relevant Open Requirements` は raw な backlog としては有用だが、実装やレビューの task-scoped contract としては粗い
- そのギャップを埋めるため、現行では `app/cli.ps1` が `Selected Task.open_requirement_overlay` を生成している

この doc は、その overlay 実装を踏まえつつ、より canonical で長持ちする改善方針を整理する。

## 2. 現状評価

### 良い点

- 未解決条件の正本が run-state に一元化されている
- 実際の解消は `resolved_requirement_ids[]` で明示されるため、曖昧な「直したつもり」で state が消えない
- `Phase7` に未解決条件の最終ゲートがあり、残件を抱えたまま完了しにくい

### 現行 overlay が解決したこと

- implementer / reviewer が「この task の境界内で拾えそうな carry-forward」を `Selected Task` の中で読める
- `Relevant Open Requirements` の raw backlog をそのまま読ませるより、task に近い粒度で判断しやすい
- `Phase5` / `Phase5-1` の prompt に carry-forward 回収の視点を導入できた

### 現行 overlay の弱さ

- 生成場所が `app/cli.ps1` であり、canonical state ではなく prompt assembly 側の派生物になっている
- `suggested_changed_files` が requirement の説明文と `Selected Task.changed_files` の文字列マッチに依存している
- `additional_acceptance_criteria` / `verification` が source artifact に元からある情報ではなく、dispatch 時に推論される
- 正本の解消判定は依然として `resolved_requirement_ids[]` 依存であり、overlay 自体は advisory に留まる

要するに、現行 overlay は短期運用としては有効だが、長期的には「情報不足を CLI 側の推論で補う」構造になっている。

## 3. 判断

「`Phase7` があるなら前段の改善は不要か」という問いに対する結論は次の通り。

- `Phase7` だけでも最終品質ゲートとしては成立する
- ただし `Phase7` だけでは carry-forward の回収が最後に偏りやすく、task 実装中に自然回収できるものを早く拾いにくい
- したがって、前段への配布は必要
- ただし、その配布は heuristic な overlay ではなく、`open_requirements` 側を構造化して行うほうがよい

つまり、

- 最終 closure の canonical authority は引き続き `Phase6` / `Phase7` の `resolved_requirement_ids[]`
- 前段の実装支援は engine が canonical data を task-scoped に投影する

という二層構造が良い落とし所になる。

## 4. 改善方針

### 原則 1: 解消の正本は変えない

未解決条件の消し込みは、引き続き verdict artifact の `resolved_requirement_ids[]` だけで行う。

- `Phase6` / `Phase7` が closure authority
- implementer prompt は「何を拾うべきか」を知るための補助
- implementer が直接 state を消す仕組みは入れない

### 原則 2: 情報は source で構造化する

carry-forward に必要な情報は、dispatch 時の推論ではなく、
`open_requirements[]` を生成する reviewer artifact 側で持たせる。

少なくとも次の情報は source 側に載せたい。

- `item_id`
- `description`
- `verify_in_phase`
- `required_artifacts`
- `acceptance_criteria`
- `verification`
- `suggested_changed_files`
- `candidate_task_ids`

### 原則 3: engine は推論ではなく投影に寄せる

engine がやることは、

- current task に関係する requirement を filter する
- `Selected Task` に task-scoped addendum として添付する

までに留める。

`changed_files` の文字列マッチや説明文からの半推論は、できるだけ source artifact で明示された情報に置き換える。

## 5. 提案モデル

別の `requirements.json` を増やすのではなく、既存の `open_requirements[]` を拡張する。

理由:

- source of truth を増やさない
- `Phase6` / `Phase7` の生成責務と自然につながる
- 最終的な closure と carry-forward contract を同じ item_id で追跡できる

### 提案スキーマ

`open_requirements[]` の各要素に、以下の任意フィールドを追加する。

```json
{
  "item_id": "sec-input-validation-T-07-date",
  "description": "src/app/api/corrections/route.ts の newClockIn/newClockOut に Invalid Date の 400 ガードを追加すること。",
  "source_phase": "Phase6",
  "source_task_id": "T-07",
  "verify_in_phase": "Phase7",
  "required_artifacts": ["phase7_pr_review.md", "phase5-2_verdict.json"],
  "acceptance_criteria": [
    "Invalid Date 入力時に 500 ではなく 400 を返す",
    "正常系の既存入力処理を壊さない"
  ],
  "verification": [
    "route.ts の入力検証ガードを確認する",
    "Invalid Date ケースのテストを確認する"
  ],
  "suggested_changed_files": [
    "src/app/api/corrections/route.ts",
    "src/__tests__/app/api/corrections/route.test.ts"
  ],
  "candidate_task_ids": ["T-07", "pr_fixes"]
}
```

### 解釈ルール

- `acceptance_criteria`: carry-forward 専用の追加受け入れ条件
- `verification`: reviewer が後続 phase で確認すべき観点
- `suggested_changed_files`: 実装の主対象候補
- `candidate_task_ids`: この requirement を自然に回収できる task 候補

`candidate_task_ids` が空なら global requirement とみなし、`verify_in_phase` ベースで run-scoped に扱う。

## 6. engine の責務

engine は current task dispatch 時に、`open_requirements[]` から
次の条件で task-scoped addendum を作る。

### include 条件

- `candidate_task_ids` に current `task_id` を含む
- または `source_task_id == current task_id`
- または global requirement で、明示的に current task の `changed_files` に `suggested_changed_files` が重なる

### 出力形式

`Selected Task.open_requirement_overlay` ではなく、将来的には
`Selected Task.carry_forward_requirements` のような名前に寄せる。

理由:

- `overlay` は「後から被せた派生物」の印象が強い
- 実体は task-scoped に投影された canonical requirement subset である

例:

```json
{
  "carry_forward_requirements": {
    "artifact_ref": "runs/<run-id>/jobs/<job-id>/.../carry_forward_requirements.json",
    "items": [
      {
        "item_id": "sec-input-validation-T-07-date",
        "acceptance_criteria": [
          "Invalid Date 入力時に 500 ではなく 400 を返す"
        ],
        "verification": [
          "route.ts の入力検証ガードを確認する"
        ],
        "suggested_changed_files": [
          "src/app/api/corrections/route.ts"
        ]
      }
    ]
  }
}
```

ここで重要なのは、
engine が new information を発明せず、
canonical `open_requirements[]` を task 用に投影するだけにすること。

## 7. phase ごとの役割

### Phase5 implementer

- `Selected Task` 本体が primary contract
- `carry_forward_requirements.items[]` は additive contract
- 境界内で回収できるなら今回の task で取り込む
- 境界外なら `known_issues` に「なぜ今回触らないか」を残す

### Phase5-1 / Phase6 reviewer

- additive contract のうち in-scope なものを取りこぼしていないかを見る
- 解消できていれば、その後の verdict artifact で `resolved_requirement_ids[]` に繋げる

### Phase7 reviewer

- 最終的な closure authority
- 未解決なら `conditional_go` + `follow_up_tasks[]`
- 解消済みなら `resolved_requirement_ids[]`

この構造なら、`Phase7` は最後の番人として残しつつ、
前段で拾えるものをより自然に回収できる。

## 8. 段階導入案

### Step 1

`open_requirements[]` schema に optional field として
`acceptance_criteria`、`verification`、`suggested_changed_files`、`candidate_task_ids` を追加する。

- validator は optional として許容
- 既存 run との互換を壊さない

### Step 2

`Phase6` / `Phase7` prompt を更新し、
new open requirement を起票するときは上記フィールドも可能な限り埋めるようにする。

### Step 3

engine 側は CLI の heuristics ではなく、
source 側の structured field から task-scoped addendum を組み立てる。

### Step 4

現行の説明文ベース `suggested_changed_files` 推定を削除または縮退させる。

- fallback としてだけ残す
- 最終的には明示データ優先にする

### Step 5

命名を `open_requirement_overlay` から
`carry_forward_requirements` に寄せることを検討する。

これは必須ではないが、役割の誤解を減らしやすい。

## 9. 代替案

### A. `Phase7` だけに任せる

利点:

- シンプル
- 新しい schema を増やさない

欠点:

- 回収が最後に偏る
- task 実装中に自然回収できるものも見落としやすい
- reviewer が最後に backlog を repair task 化する仕事へ寄りすぎる

### B. 現行 overlay をそのまま維持する

利点:

- すぐ効く
- 実装側の UX は改善する

欠点:

- canonical 情報ではない
- CLI 側の推論が増える
- schema と prompt が乖離しやすい

### C. 別 `requirements.json` を新設する

利点:

- task-scoped contract を強く表現できる

欠点:

- source of truth が増える
- `open_requirements[]` と closure の対応が分かれやすい

このため、本提案では C を採らない。

## 10. 推奨結論

推奨方針は次の 3 点。

1. `Phase7` を最終 closure authority として維持する
2. carry-forward の前段配布は続ける
3. ただし配布元を CLI の heuristic overlay ではなく、structured `open_requirements[]` に寄せる

現行 overlay 実装は短期的には有効だが、長期的には
「source で構造化し、engine は投影するだけ」
という形へ寄せるのが最も筋がよい。
