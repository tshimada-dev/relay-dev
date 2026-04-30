# Phase7 PRレビュー テンプレート

このフェーズでは、run 全体の変更を reviewer として批判的にレビューし、最終 verdict を出す。

## 実行原則

- Input Artifacts と利用可能な task artifact を読むこと
- `phase6_result.json`、`phase5_result.json`、必要に応じて実コードと差分を突き合わせること
- Required Outputs に書かれた `phase7_pr_review.md` と `phase7_verdict.json` のみを作成すること
- repair task の生成は `phase7_verdict.json` の `follow_up_tasks[]` で表現する。追加の制御ファイルは作らないこと
- 前段 review を鵜呑みにせず、盲点を補うこと

## 許可される verdict

- `go`: run 全体としてマージ可能
- `conditional_go`: 修正タスクを作れば進行可能。`follow_up_tasks` を 1 件以上必須
- `reject`: より早い phase に戻す必要がある。`rollback_phase` は `Phase1`、`Phase3`、`Phase4`、`Phase5`、`Phase6` のいずれか

`reject` 以外では `rollback_phase` は空文字でよい。

## Markdown 出力に含める内容

- 概要要約
- Review Checklist
- Critical Issues
- Warnings
- Info
- Verdict Rationale
- Human Review Recommendation

## JSON 出力

`phase7_verdict.json` には以下のキーを必ず含めること。

- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `follow_up_tasks`
- `review_checks`
- `human_review`
- `resolved_requirement_ids`

`must_fix`、`warnings`、`evidence`、`resolved_requirement_ids` はすべて JSON 配列にすること。

`review_checks[]` は以下の `check_id` をすべて含む固定チェック配列で、各要素は `check_id`、`status`、`notes`、`evidence` を持つこと。`review_checks[].evidence` も必ず JSON 配列にすること。

- `requirements_alignment`
- `correctness_and_edge_cases`
- `security_and_privacy`
- `test_quality`
- `maintainability`
- `performance_and_operations`

`status` は `pass`、`warning`、`fail` のいずれかにすること。

`human_review` は以下のキーを持つ object にすること。

- `recommendation`: `required` / `recommended` / `not_needed`
- `reasons`
- `focus_points`

`human_review.reasons` と `human_review.focus_points` は JSON 配列にすること。

`resolved_requirement_ids[]` には、`Open Requirements` に出てきた未解決条件のうち、今回の PR review で解消済みと判断した `item_id` を列挙すること。`go` を選ぶ場合は、未解決条件を残さないこと。

`conditional_go` の場合、`follow_up_tasks` は 1 件以上必須で、各要素は次のキーを持つこと。

- `task_id`
- `purpose`
- `changed_files`
- `acceptance_criteria`
- `depends_on`
- `verification`
- `source_evidence`

`follow_up_tasks[]` は repair task の正本になる。人が読んで実装できる粒度で書くこと。`changed_files`、`acceptance_criteria`、`depends_on`、`verification`、`source_evidence` はすべて JSON 配列にすること。

## 品質基準

- `review_checks` の 6 項目を省略していない
- outstanding open requirements を確認し、解消済みなら `resolved_requirement_ids`、未解決なら `conditional_go` または `reject` で扱っている
- critical issue と `must_fix` が対応している
- conditional_go の場合は follow_up task が修正単位として成立している
- reject の場合は rollback_phase の選択理由が明確である

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはこのプロジェクトに初めて参加する外部のシニアコードレビュアーです。
あなたはこのコードの設計にも実装にも関与していません。
このPRは「マージすべきでない理由がある」と仮定して、その理由を探してください。
理由が本当に見つからない場合のみGoとしてください。

## 入力（自動参照）

Input Artifacts、利用可能な task artifact、`Open Requirements` を読み込むこと。

- `phase3_design.md`、`phase4_task_breakdown.md`、task-scoped の `phase5_implementation.md` / `phase5-2_security_check.md` / `phase6_testing.md` を必要に応じて突き合わせること
- review の正本は canonical artifact と実コード・差分・実行結果である。追加の legacy control file を source of truth にしないこと
- 未解決条件の確認は `Open Requirements` と関連 artifact を使って行い、解消済みなら `resolved_requirement_ids[]`、未解決なら `conditional_go` または `reject` で扱うこと
- `follow_up_tasks[]` だけが repair task の canonical contract である。追加の制御ファイルや補助 task file を作らないこと

※ Phase3設計書はフル参照するとコンテキスト長を超える可能性があるため、
  「## 要約」セクションのみ参照すること。詳細確認が必要な場合のみフル参照する。

## レビュー観点

### 1. 仕様逸脱

- Phase3設計・Phase4タスクから逸脱していないか

### 2. バグリスク

- Null例外
- 境界条件漏れ
- 並列処理問題
- リソースリーク

### 3. セキュリティ

- 入力検証不足
- 認証漏れ
- ログへの機密情報出力

### 4. 保守性

- 可読性
- 責務分離
- 命名

### 5. パフォーマンス

- N+1
- 不要な再計算

## 出力形式

- 概要要約（5行以内）
- Critical Issues（必須修正）
- Warnings（修正推奨）
- Info（参考）
- マージ判定（Go / Conditional Go / Reject）
- Reject時の差し戻し詳細（Rejectの場合のみ、以下を必須出力）

### Reject詳細（Reject判定時のみ出力）

差し戻し判定前に、以下の手順でフォルダ内を走査し、現在が差し戻し先であるかを自動判定すること：

1. `<run artifact directory>/` フォルダ内のファイル一覧を確認
2. 差し戻し先Phase1の場合: `phase1_requirements.md` が既に存在するか確認
3. 差し戻し先Phase3の場合: `phase3_design.md` が既に存在するか確認
4. 差し戻し先Phase4の場合: `phase4_task_breakdown.md` が既に存在するか確認
5. 差し戻し先Phase5の場合: `<task artifact directory>/phase5_implementation.md` が既に存在するか確認
6. 差し戻し先Phase6の場合: `<task artifact directory>/phase6_testing.md` が既に存在するか確認
7. 該当ファイルが存在する場合 → 差し戻し先として適切（修正指示を出力）
8. 該当ファイルが存在しない場合 → まだその段階に到達していない（差し戻し先として不適切なため、判定を再検討）

```
- 原因分類: 要件不備 / 設計不備 / タスク分解不備 / 実装不備 / テスト不備
- 差し戻し先: Phase1 / Phase3 / Phase4 / Phase5 / Phase6
- 差し戻し先存在確認: 該当ファイル存在 / 該当ファイル未存在
- 根拠: （なぜその分類か1文で説明）
- 修正指示: （差し戻し先で何を修正すべきか具体的に記載）
```

## コメントフォーマット

指摘は以下の形式で記載すること：
```
[severity] ファイル名:行番号
指摘内容
修正案（あれば）
```
severity: CRITICAL / WARNING / INFO

## 出力例（Few-shot）

以下はタスク「T-02: 検索APIエンドポイント実装」に対するレビュー出力例。

```
### 概要要約

商品検索APIエンドポイント（GET /api/products/search）の実装。
GINインデックスを活用した全文検索とRedisキャッシュを実装。
全体として設計書に沿った実装だが、入力検証に1件のCriticalがある。

### Critical Issues

[CRITICAL] src/api/products/search.py:28
検索クエリ `q` パラメータの長さ制限がない。
極端に長い入力でto_tsvectorの処理コストが増大し、DoSリスクがある。
修正案: `q` の最大長を200文字に制限するバリデーションを追加

### Warnings

[WARNING] src/api/products/search.py:45
キャッシュキー生成でクエリ文字列をそのまま使用している。
大文字小文字やスペースの違いで同一検索意図のキャッシュが分散する。
修正案: キー生成前に正規化（lowercase, strip, 連続スペース除去）を適用

[WARNING] src/api/products/search.py:62
per_pageの上限チェック（max=100）がAPI層のみ。
直接DBアクセスする内部呼び出しでは制限が効かない。
修正案: リポジトリ層にもper_pageの上限ガードを追加

### Info

[INFO] src/api/products/search.py:15
検索結果のスコア（relevance score）を返却しているが、Phase3設計書で
スコアの用途（ソート以外）が未定義。現時点では問題ないが、将来の仕様確認を推奨。

### マージ判定

**Conditional Go**

Critical Issues 1件（入力長制限）の修正後にマージ可。
Warningsは修正推奨だがブロッカーではない。

## 要約（200字以内）

検索APIの実装は設計書に概ね準拠。Critical1件：検索クエリの長さ制限がなくDoSリスクあり（修正必須）。Warning2件：キャッシュキー正規化不足、per_page上限の層不足。Info1件。Conditional Go判定、Critical修正後にマージ可。
```


## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
マージ判定・Critical Issues数・主要な指摘を簡潔にまとめる。

## 人間レビュー推奨の判定

AIレビュー完了後、以下の条件に該当する場合は **人間による追加レビューを推奨** すること。
出力末尾にこの判定結果を必ず含める。

### 判定基準

| 条件 | 判定 |
|------|------|
| 認証・認可ロジックの変更を含む | 人間レビュー必須 |
| 課金・決済ロジックの変更を含む | 人間レビュー必須 |
| 個人情報・機密データの取り扱い変更を含む | 人間レビュー必須 |
| 外部API連携の新規追加・変更を含む | 人間レビュー推奨 |
| DBスキーマ変更を含む | 人間レビュー推奨 |
| 上記いずれにも該当しない | AIレビューのみで可 |

### 出力フォーマット

```
## 人間レビュー判定

- 判定: 必須 / 推奨 / 不要
- 該当条件: （上記のどの条件に該当するか）
- 確認してほしいポイント: （人間が特に注目すべき箇所。不要の場合は省略）
```

> **なぜ人間レビューが必要か**: AIは実装とレビューの両方を担うため、
> 同一の盲点を共有する構造的リスクがある。特にセキュリティ・金銭・法的影響がある変更は、
> AIが「問題なし」と判定しても人間の目による最終確認を推奨する。
