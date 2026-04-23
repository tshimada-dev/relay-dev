# Phase4-1 タスクレビュー テンプレート

このフェーズでは、Phase4 の task breakdown が実装順序と受け入れ条件の両面で成立しているかを reviewer として確認する。

## 実行原則

- Input Artifacts を正本として読むこと
- カバレッジ不足、依存関係不整合、タスク粒度の破綻を優先的に探すこと
- Required Outputs に書かれた `phase4-1_task_review.md` と `phase4-1_verdict.json` のみを作成すること

## 許可される verdict

- `go`: タスク分解レビュー通過
- `conditional_go`: Phase4 の修正を前提に進行可能。修正事項は `must_fix` に列挙する
- `reject`: タスク分解または設計に戻す。`rollback_phase` は `Phase3` または `Phase4`

`reject` 以外では `rollback_phase` は空文字でよい。

## Markdown 出力に含める内容

- 概要
- Coverage Gaps
- Dependency Issues
- Task Granularity Issues
- Verdict Rationale

## JSON 出力

`phase4-1_verdict.json` には以下のキーを必ず含めること。

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`

## 品質基準

- conditional_go の場合は、Phase4 で直すべき内容が `must_fix` に具体化されている
- reject の場合は、Phase3 に戻すべきか Phase4 に戻すべきかの理由が明確である
- 指摘は task_id や受け入れ条件を参照して追跡可能にする

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはシニアテックリード兼タスクレビュアーです。
以下のPhase4タスクリストをレビューしてください。

## 入力（自動参照）

以下のファイルを読み込むこと：
- `<run artifact directory>/phase3_design.md`（フル参照 — 照合用）
- `<run artifact directory>/phase4_task_breakdown.md`（フル参照 — レビュー対象）

## レビュー観点

- 粒度が大きすぎないか（2時間超のタスクがないか）
- **タスク数が多すぎないか（最大20件以内か）**
- **1タスクの工数が1日を超えていないか**
- 抜けタスクはないか（設計書の全機能がカバーされているか）
- 各 task の `boundary_contract` が Phase3 の `module_boundaries` / `public_interfaces` / 依存制約 / 副作用境界 / 状態所有に対応しているか
- `boundary_contract` を見れば「この task にない越境」が判定できるか
- 各 task の `visual_contract` が Phase3 の `visual_contract` を task 単位に投影しているか
- UI変更がある task で `visual_contract.mode` が `not_applicable` のまま残っていないか
- 並列化余地（不要な直列依存がないか）
- テスト不足（各タスクにテスト内容があるか）
- 依存関係の矛盾（循環依存、存在しないタスクIDへの参照）
- クリティカルパスの妥当性

## 出力

- Must Fix
- Should Fix
- Nice to Have
- 総合評価（Go / Conditional Go / Reject）
- Reject時の差し戻し詳細（Rejectの場合のみ、以下を必須出力）

### Reject詳細（Reject判定時のみ出力）

```
- 原因分類: 設計不備 / タスク分解不備
- 差し戻し先: Phase3 / Phase4
- 根拠: （なぜその分類か1文で説明）
- 修正指示: （差し戻し先で何を修正すべきか具体的に記載）
```

## 出力例（Few-shot）

以下は「商品検索レスポンス改善」のタスクリスト（T-01〜T-03）に対するレビュー出力例。

```
### Must Fix

1. T-02（検索APIエンドポイント実装）の受け入れ条件に性能要件が含まれていない。
   Phase3設計書で「p95 500ms以下」と定義されているが、T-02の受け入れ条件に
   レスポンスタイム計測が含まれていない。
   → 受け入れ条件に「p95レスポンスタイム500ms以下をEXPLAIN ANALYZEまたは負荷テストで確認」を追加

### Should Fix

1. T-03（Redisキャッシュ層導入）のテスト内容に「Redis障害時フォールバック」が
   含まれているが、複雑度がM（理由: Redis連携、フォールバック処理あり）のまま。
   フォールバック処理のテスト（モック化含む）を考慮するとLが妥当。
   → 複雑度をL（理由: Redis連携 + フォールバック処理 + モック化テスト）に変更

### Nice to Have

1. T-01〜T-03がすべて直列依存だが、T-01（インデックス追加）のテスト作成と
   T-02のAPI実装（インデックスなしでも動作するコード部分）は並列化可能。
   → T-02を「API実装（インデックス非依存部分）」と「インデックス統合」に分割すれば
   並列化できるが、タスク数増加とのトレードオフ

### 総合評価

**Conditional Go**

Must Fix 1件（性能要件の受け入れ条件追加）を反映すること。
Should Fix 1件は反映推奨。Nice to Haveは現状の3タスク直列で問題ない。
タスク数3件は設計書の機能数に対して適切。抜けタスクなし。

## 要約（200字以内）

Conditional Go。Must Fix 1件：T-02の受け入れ条件にp95レスポンス計測が欠落。Should Fix 1件：T-03の複雑度をM→Lに変更推奨。タスク数3件は設計書の全機能をカバーしており過不足なし。クリティカルパスT-01→T-02→T-03は妥当。並列化余地はあるがタスク数増加とのトレードオフで現状維持を推奨。
```

### 悪い出力例（このように書かないこと）

```
❌ 「タスク分解は適切です」→ 各レビュー観点への具体的な言及がない
❌ 粒度の評価なしにGoを出す → 2時間超のタスクがないか確認すること
❌ 設計書との照合なしに「抜けなし」→ Phase3の機能一覧と突合すること
❌ 依存関係の矛盾チェックに言及なし → 循環依存がないか確認すること
```

出力の最後に `## 要約（200字以内）` セクションを付与すること。
総合評価・主要な指摘事項・タスク数の過不足を簡潔にまとめる。

出力は `<run artifact directory>/phase4-1_task_review.md` に保存すること。
