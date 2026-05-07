# machine-owned verdict 実装計画

## 1. 背景

現在の relay-dev では、`Phase5-1` / `Phase5-2` / `Phase6` / `Phase7` の reviewer artifact が
`verdict` を直接出力し、その値を validator と workflow-engine がそのまま信頼している。

この構造には次の弱さがある。

- AI が `verdict` と checklist status の整合を崩すと `invalid_artifact` で run が停止する
- repairer を広げても、「AI が top-level decision を誤る」構造自体は残る
- prompt と validator に同じ判定ロジックが二重化しやすい
- run recovery はできても、同じ phase を再実行すると同じ top-level mistake を再生産しやすい

最近の停止例はこのパターンに一致している。

- `Phase5-2`: `go` なのに `warning` security check を含めた
- `Phase6`: `reject` なのに `tests_failed = 0` かつ `verification_checks.fail = 0`
- `Phase7`: `conditional_go` なのに `must_fix` が空

これらは「修復対象を増やせばよい」というより、
「AI に verdict を決めさせ過ぎている」ことが本質原因である。

## 2. 提案の核

### 結論

AI は `pass / warning / fail` や根拠・carry-forward 情報のような
**判定材料（assessment primitives）** だけを出し、
`go / conditional_go / reject` の **canonical verdict は engine が決める** 方式へ寄せる。

### 重要な補足

ここで machine-owned にするのは **top-level verdict** が中心であり、
すべてを機械判定するわけではない。

特に次は当面 AI に残す。

- `must_fix`
- `open_requirements`
- `resolved_requirement_ids`
- `follow_up_tasks`
- `rollback_recommendation` または `rollback_phase` の推薦

理由は、これらは単なる集計ではなく、文脈理解や修正方針の表現を含むためである。

## 3. 目標

### 主目標

- reviewer artifact の `verdict` と checklist status の食い違いで run が止まる頻度を大幅に減らす
- prompt 側の「判定ルールの写経」を減らし、validator / engine を正本に寄せる
- repairer が `verdict` の辻褄合わせではなく、check status や supporting fields の修復に集中できるようにする

### 副目標

- `Phase6` のようなルールが明確な phase から先に安定化する
- canonical artifact schema はできるだけ維持し、既存 engine との互換を保つ

### 非目標

- すべての reviewer phase を一度に機械判定へ移すこと
- `Phase7` の follow-up task 生成まで完全に機械化すること
- `validator` 自体に mutation 責務を持たせること

## 4. 設計原則

### 原則 1: canonical artifact には引き続き `verdict` を残す

`workflow-engine.ps1`、`transition-resolver.ps1`、互換 marker 生成など、
既存 engine は canonical artifact の `verdict` を読んでいる。

したがって最終保存される artifact から `verdict` を消すのではなく、
**AI 出力からは外し、engine が注入する** 方式を採る。

これにより、次の互換が保てる。

- `workflow-engine.ps1` の phase 遷移
- `artifact-repository.ps1` の compatibility marker
- 既存の run-state / legacy consumer

### 原則 2: validator は「判定器」ではなく「完成 artifact の検査器」に留める

validator 自体に「verdict を推論して書き戻す」責務を持たせると、
検証と mutation が混ざって責務がぼやける。

そのため、新しい責務は validator の前段に置く。

推奨構造:

1. AI が raw assessment artifact を出す
2. engine が finalizer で verdict を補完・正規化する
3. validator が finalized artifact を検査する
4. workflow-engine がその finalized artifact を使って遷移する

### 原則 3: machine-owned verdict は phase ごとに段階導入する

`Phase6` は機械判定しやすいが、`Phase7` はそうではない。
そのため一括導入ではなく、phase ごとに適用範囲を分ける。

## 5. 現状の verdict 依存箇所

### 既存の正本ロジック

- `app/core/artifact-validator.ps1`
  - `Phase5-1`: completion checks から `go/reject` の整合を検査
  - `Phase5-2`: security checks から `go/conditional_go/reject` の整合を検査
  - `Phase6`: verification checks と `tests_failed` から `go/conditional_go/reject` の整合を検査
  - `Phase7`: review checks・`must_fix`・`follow_up_tasks` の整合を検査

### 現在 `verdict` を読む主な層

- `app/core/workflow-engine.ps1`
  - phase 遷移
  - `Phase7 conditional_go` 時の repair task 生成
  - approval payload 生成
- `app/core/artifact-repository.ps1`
  - `phase6_result.json` から compatibility task marker を生成
- `app/core/transition-resolver.ps1`
  - `verdict` + `rollback_phase` から next phase を決定

このため、最終 artifact から verdict を完全削除する案は影響が大きい。

## 6. target architecture

## 6.1 追加する責務

新しく `app/core/verdict-finalizer.ps1` のような層を追加する。

責務は次の通り。

- raw reviewer artifact を受け取る
- phase ごとの deterministic rule で canonical `verdict` を決める
- 必要なら `rollback_phase` / field cleanup を正規化する
- finalized artifact を validator に渡す

### phase-execution 上の流れ

```text
AI artifact materialized
  -> reviewer artifact finalizer
  -> validator
  -> commit
  -> workflow transition
```

### 実装位置

`app/core/phase-execution-transaction.ps1` の
`Get-PhaseMaterializedArtifacts` と `Invoke-PhaseValidationPipeline` の間が第一候補。

理由:

- repairer と同じ artifact lifecycle 上に置ける
- validator には finalized artifact だけを見せられる
- `workflow-engine` や `artifact-repository` を大きく崩さずに済む

## 6.2 canonical schema は維持

raw prompt から `verdict` を外しても、
finalized artifact では従来どおり次を保持する。

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`

つまり schema migration ではなく、
**artifact production responsibility の変更** とみなす。

## 6.3 raw field と final field の分離

必要に応じて以下の raw-only field を導入する。

- `rollback_recommendation`
- `decision_notes`

ただし最初の段階では新 field を増やし過ぎない。
既存 `rollback_phase` を「AI の recommendation」としてそのまま受け、
engine が最終 `verdict` に合わせて採用可否を判断する形でもよい。

## 7. phase 別の適用方針

## 7.1 Phase6 を first rollout にする

### 理由

- いま最も run 停止を起こしている
- 機械判定ルールが明快
- `Phase7` より follow-up task 依存が少ない

### Phase6 verdict rule

AI が出す primary signal:

- `tests_failed`
- `verification_checks[].status`
- `conditional_go_reasons`
- `open_requirements`
- `rollback_phase` または `rollback_recommendation`

engine の判定:

- `tests_failed > 0` または `verification_checks.fail >= 1` -> `reject`
- それ以外で `verification_checks.warning >= 1` または `open_requirements >= 1` -> `conditional_go`
- それ以外 -> `go`

### Phase6 で機械化しないもの

- どの issue を `must_fix` に書くか
- `rollback_phase` を `Phase3/4/5` のどれにするかの意味判断

### Phase6 で追加する engine-side consistency rule

- `reject` が推論されたのに `rollback_phase` が空なら finalization error
- `go` が推論されたのに `open_requirements` が残っていれば finalization error
- `conditional_go` が推論されたのに `conditional_go_reasons` が空なら finalization error

ここは「機械が勝手に補う」のではなく、
**AI が出すべき supporting fields が欠けていたら止める** 方針にする。

## 7.2 Phase5-2 を second rollout にする

### Phase5-2 verdict rule

AI が出す primary signal:

- `security_checks[].status`
- `open_requirements`
- `must_fix`

engine の判定:

- `security_checks.fail >= 1` -> `reject`
- fail はなく `warning >= 1` または `open_requirements >= 1` -> `conditional_go`
- それ以外 -> `go`

### 注意点

`conditional_go` と `open_requirements` の関係が強い phase なので、
`warning` があるのに `open_requirements` が空、のような場合は
verdict 推論後に validator で明確に落とす。

## 7.3 Phase5-1 は third rollout にする

`Phase5-1` は `conditional_go` を許容しておらず、
実質 `all pass -> go / anything failed -> reject` の 2 値に近い。

機械判定は容易だが、
現在の停止パターンは `Phase6` / `Phase5-2` より少ないため優先度は一段下げる。

### Phase5-1 verdict rule

- acceptance criteria fail >= 1 または review_checks.fail >= 1 -> `reject`
- それ以外 -> `go`

## 7.4 Phase7 は first rollout に入れない

### 理由

`Phase7` の `conditional_go` と `reject` の差は、
単純な fail/warning 集計では決まりにくい。

例:

- review check fail があっても、follow-up task 化で許容できるケース
- 同じ fail でも release blocker か post-merge repair かの判断が分かれる

### Phase7 の扱い

第一段階では現状維持とし、
`Phase6` / `Phase5-2` の machine-owned verdict が安定した後に別設計する。

そのときは、単なる checklist ではなく、
AI に `release_recommendation` のような中間表現を持たせる案を検討する。

## 8. 実装タスク分解

## Step 1: finalizer 基盤を追加

対象候補:

- `app/core/verdict-finalizer.ps1` 新規
- `app/core/phase-execution-transaction.ps1`

内容:

- phase 名と artifact id を受けて finalizer を呼ぶフック追加
- 非対象 phase は no-op
- finalized artifact を validator に渡す

## Step 2: Phase6 finalizer を実装

対象候補:

- `app/core/verdict-finalizer.ps1`
- `app/core/artifact-validator.ps1`
- `app/phases/phase6.ps1`

内容:

- `Phase6` 専用の verdict inference rule 実装
- supporting fields が不足する場合の finalization error 定義
- finalized artifact が従来 validator を通ることを確認

## Step 3: Phase6 prompt を slim 化

対象候補:

- `app/prompts/phases/phase6.md`

内容:

- `verdict` を AI の primary responsibility から外す
- `verification_checks` の status を正しく付けることに集中させる
- `reject` 時は `rollback_phase recommendation` と `must_fix` を必須化
- `conditional_go` 時は `conditional_go_reasons` と `open_requirements` を必須化

注記:

移行中は `verdict` が出てきても engine が無視または warning 化する後方互換モードを持たせる。

## Step 4: Phase5-2 finalizer を追加

対象候補:

- `app/core/verdict-finalizer.ps1`
- `app/prompts/phases/phase5-2.md`

内容:

- security check 集計から `go/conditional_go/reject` を推論
- `open_requirements` / `must_fix` の整合要件を継続

## Step 5: Phase5-1 finalizer を追加

対象候補:

- `app/core/verdict-finalizer.ps1`
- `app/prompts/phases/phase5-1.md`

内容:

- simple 2-state inference を追加
- `conditional_go` を prompt/engine 双方で排除

## Step 6: Phase7 の separate design

この doc の範囲では設計準備までに留める。
`Phase7` は follow-up task 生成・approval・release gating と結びつくため、
別 doc で設計を切るのが安全。

## 9. validator と repairer の関係整理

machine-owned verdict にしても repairer は不要にならない。

### 変わること

- repairer は `verdict` そのものではなく、supporting fields の修正を主に担当する
- 例:
  - `verification_checks.status` の誤り
  - `conditional_go_reasons` の欠落
  - `open_requirements` の欠落
  - `must_fix` の欠落

### 変わらないこと

- finalizer 後に validator が落ちる場合は repairer 対象になり得る
- run-level auto-resume は引き続き最後の保険として残る

### 重要な設計判断

「verdict mismatch を repairer で直す」のではなく、
「raw assessment の supporting fields を repairer で直す」構造へ寄せる。

これにより、repairer が構造的な二重管理の尻拭いをする必要が減る。

## 10. テスト計画

## Unit / contract tests

`tests/regression.ps1` に少なくとも次を追加する。

- `Phase6`: all pass -> final verdict `go`
- `Phase6`: warning only -> final verdict `conditional_go`
- `Phase6`: fail check -> final verdict `reject`
- `Phase6`: reject inferredだが rollback recommendation なし -> finalization error
- `Phase5-2`: warning security check -> final verdict `conditional_go`
- `Phase5-2`: fail security check -> final verdict `reject`
- `Phase5-1`: failed acceptance check -> final verdict `reject`

## migration compatibility tests

- raw artifact が legacy `verdict` を含んでも engine が canonical verdict を再計算する
- canonical 保存 artifact は従来どおり `verdict` を保持する
- `workflow-engine` が変更なしで finalized artifact を読める

## E2E stability tests

- `invalid_artifact` だった既知サンプルを raw artifact fixture として再投入
- finalizer 導入後に run が停止しないことを確認

## 11. rollout strategy

### Rollout 1

- `Phase6` のみ有効化
- 他 phase は legacy path 維持
- まず現在の停止パターンを潰す

### Rollout 2

- `Phase5-2` を有効化
- security review phase の top-level mismatch を削減

### Rollout 3

- `Phase5-1` を有効化

### Rollout 4

- `Phase7` の separate design 後に判断

この順番にすることで、
impact の大きい phase から先に安定化しつつ、
`Phase7` の複雑性を早まって抱え込まないで済む。

## 12. open questions

### Q1. finalizer は raw artifact を書き換えるべきか、別 object を作るべきか

推奨は **別 object を作ってから canonical save**。

理由:

- raw AI output と finalized artifact を概念上分けられる
- 将来 diff や debug を取りやすい

ただし実装コストを抑える第一段階では、
in-memory mutation で finalized object を validator に渡すだけでもよい。

### Q2. `Phase6` の `rollback_phase` は完全自動化すべきか

現時点では **しない**。

`Phase3/4/5` のどこに戻すかは、
失敗の起点が task 分解なのか実装なのか設計なのかを含み、
単なる checklist 集計では決めにくい。

したがって AI recommendation を受け、
engine は「空ではない」「許可集合内である」ことだけを強く保証する。

### Q3. `Phase7` も同じ方式に乗せられるか

最終的には可能性があるが、
その場合も `go/conditional_go/reject` を単純集計で決めるのは避けたい。

`Phase7` は release recommendation の中間表現を別途設計するのが安全。

## 13. 推奨結論

推奨する実装順は次の通り。

1. `Phase6` に machine-owned verdict finalizer を導入する
2. `Phase5-2` に拡張する
3. `Phase5-1` に拡張する
4. `Phase7` は別設計として切り出す

この方針なら、
「AI に pass/warning/fail の評価をさせ、top-level verdict は機械で決める」
という狙いを、既存 engine との互換を壊さずに段階導入できる。

また、repairer を単に広げ続けるより、
停止原因そのものを upstream で減らす改善として筋が良い。
