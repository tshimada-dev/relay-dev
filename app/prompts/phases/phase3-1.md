# Phase3-1 設計レビュー テンプレート

このフェーズでは、Phase3 の設計を reviewer として批判的に読み、設計の妥当性を判定する。

## 実行原則

- Input Artifacts を正本として読むこと
- 自分の仕事は設計を通すことではなく、通すべきでない理由がないかを確かめること
- Required Outputs に書かれた `phase3-1_design_review.md` と `phase3-1_verdict.json` のみを作成すること
- verdict はこのフェーズで許可された値だけを使うこと

## 許可される verdict

- `go`: 設計レビュー通過
- `conditional_go`: 小さな修正で進行可能。修正事項は `must_fix` に列挙する
- `reject`: 設計を差し戻す。`rollback_phase` は `Phase1` または `Phase3`

`reject` 以外では `rollback_phase` は空文字でよい。

## Markdown 出力に含める内容

- 概要
- Critical Findings
- Warnings
- Verdict Rationale

指摘は可能な限り具体的に書き、どの設計要素に問題があるのか分かるようにすること。

## JSON 出力

`phase3-1_verdict.json` には以下のキーを必ず含めること。

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `review_checks`

`must_fix` と `warnings` は配列で、各要素は具体的な修正指示または懸念事項にすること。`evidence` には参照した設計項目や確認根拠を入れること。

`review_checks[]` は以下の `check_id` をすべて含む固定チェック配列で、各要素は `check_id`、`status`、`notes`、`evidence` を持つこと。
`status` は `pass`、`warning`、`fail` のいずれかにすること。

- `module_boundaries`
- `public_interfaces`
- `dependency_rules`
- `side_effect_boundaries`
- `state_ownership`
- `encapsulation_consistency`
- `visual_contract_readiness`

## 品質基準

- reject の場合は rollback 先が妥当である
- conditional_go の場合は `must_fix` が空でない
- 設計の穴を抽象論で済ませず、後続が修正できる形で書く
- `review_checks` の固定項目を省略しない
- `go` は設計契約チェックがすべて `pass` の場合に限る

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはシニアテックリード兼アーキテクトレビュアーです。
以下のPhase3設計書をレビューしてください。

## 入力（自動参照）

以下のファイルを読み込むこと：
- `<run artifact directory>/phase1_requirements.md`（フル参照 — 要件照合用）
- `<run artifact directory>/phase2_info_gathering.md`（存在する場合のみ参照 — clarification fallback で確定した判断と残存 blocker の反映確認用）
- `<run artifact directory>/phase3_design.md`（フル参照 — レビュー対象）
- `<run artifact directory>/phase3_design.json`（設計境界と構造化契約の正本）

## レビュー観点

### 1. 要件整合性

- Phase1の要件と設計が食い違っていないか
- Phase2 が存在する場合、そこで確定した意思決定が反映されているか
- Phase2 が存在する場合、残存 blocker が都合よく握りつぶされていないか
- 未反映要件がないか

### 2. 実装可能性

- 現実的に実装できる構成か
- 技術スタックとの矛盾がないか

### 3. 粒度妥当性

- 粗すぎる／細かすぎる箇所

### 3b. カプセル化境界

- `module_boundaries` が責務境界として十分に具体化されているか
- `public_interfaces` が後続実装で触ってよい公開面を明示しているか
- `allowed_dependencies` / `forbidden_dependencies` が越境判定に使えるか
- `side_effect_boundaries` が副作用の置き場と禁止された直アクセスを明示しているか
- `state_ownership` が状態の所有者と参照境界を明示しているか
- これらの設計境界どうしが矛盾せず、カプセル化を崩していないか

### 3c. ビジュアル契約

- `visual_contract.mode` が UI スコープに対して妥当か
- `design_sources` に `DESIGN.md` や既存画面などの参照元が明示されているか
- `visual_constraints` / `component_patterns` が後続 task の visual contract に落とせる粒度か
- `responsive_expectations` / `interaction_guidelines` が空状態・エラー状態・レスポンシブ崩れを防げる粒度か

### 4. 既存資産の再利用

- Phase0「再利用可能な既存資産」に記載されたモジュールが活用されているか
- 「新規作成」と判定された項目に、既存に類似機能がない根拠があるか
- 既存モジュールと同等の機能を重複して新規設計していないか

### 5. 過剰設計

- MVPに不要な機能や構造

### 6. 曖昧点

- 判断不能な仕様箇所

### 7. セキュリティ

- 認証・認可設計の妥当性
- データ保護（暗号化、マスキング）の考慮
- 入力検証ポイントの網羅性
- OWASP Top 10への対応状況

### 8. リスク

- 後戻りコストが高い設計判断

## 出力フォーマット

- 致命的問題（Must Fix）
- 修正推奨（Should Fix）
- 改善提案（Nice to Have）
- 問題なし項目
- 総合評価（Go / Conditional Go / Reject）
- Reject時の差し戻し詳細（Rejectの場合のみ、以下を必須出力）

### Reject詳細（Reject判定時のみ出力）

```
- 原因分類: 要件不備 / 設計不備
- 差し戻し先: Phase1 / Phase3
- 根拠: （なぜその分類か1文で説明）
- 修正指示: （差し戻し先で何を修正すべきか具体的に記載）
```

## 出力例（Few-shot）

以下は「商品検索レスポンス改善」の設計書に対するレビュー出力例。

```
### 致命的問題（Must Fix）

1. API設計（GET /api/products/search）で検索クエリ `q` の最大長が未定義。
   極端に長い入力でto_tsvectorの処理コストが増大し、DoSリスクがある。
   → 設計書に入力値の上限（例: 200文字）を明記すること

### 修正推奨（Should Fix）

1. キャッシュキー設計で `search:{hash(q)}:{page}:{per_page}` としているが、
   クエリ文字列の正規化（lowercase、trim、連続スペース除去）が未定義。
   → 正規化ルールを設計書に追加すること
2. 非機能要件にRedis障害時のフォールバック動作が未記載。
   → キャッシュ障害時はDB直接問い合わせにフォールバックする旨を明記すること

### 改善提案（Nice to Have）

1. 監視機能（F-03）のダッシュボード仕様が未定義。Phase3では不要だが、
   将来的にインデックスサイズ・キャッシュヒット率の可視化を検討するとよい

### 問題なし項目

- 要件整合性: Phase1の目的・成功条件・スコープと設計が一致
- 実装可能性: PostgreSQL GINインデックス + Redisキャッシュは既存技術スタック内
- 粒度妥当性: API仕様・データ構造・シーケンス図いずれも実装粒度に落ちている
- 既存資産の再利用: src/services/cache.ts（Redisラッパー）の再利用が明記されている
- 過剰設計: MVP範囲が適切、不要な機能なし

### 総合評価

**Conditional Go**

致命的問題1件（入力値上限の未定義）の修正後に通過可。
修正推奨2件はPhase4以降で対応可能だが、設計書に反映が望ましい。
```

### 悪い出力例（このように書かないこと）

```
❌ 「設計は全体的によくできている」→ 具体的なレビュー観点の評価がない
❌ 致命的問題にセキュリティ観点が含まれていない → レビュー観点7を確認すること
❌ 「問題なし」のみで各観点への言及がない → 問題なし項目も列挙すること
❌ Conditional Goなのに修正すべき内容が不明確 → Must Fixの修正指示を具体的に
```

## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
総合評価・致命的問題の有無・主要な指摘事項を簡潔にまとめる。

出力は `<run artifact directory>/phase3-1_design_review.md` に保存すること。
