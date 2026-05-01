# Phase5-1 完了チェック テンプレート

このフェーズでは、Phase5 の実装が task contract を満たしているかを reviewer として検証する。

## 実行原則

- `Selected Task` と `phase5_result.json` を正本として照合すること
- `Selected Task.boundary_contract` がある場合、それにない越境を不適合として扱うこと
- `Selected Task.visual_contract.mode` が `not_applicable` 以外の場合、それに反するUI変更を不適合として扱うこと
- `Selected Task.open_requirement_overlay.items[]` がある場合、それを relevant open requirements の task-scoped overlay として照合すること
- 実装ログだけでなく、必要に応じて実ファイルと差分も確認すること
- Required Outputs に書かれた `phase5-1_completion_check.md` と `phase5-1_verdict.json` のみを作成すること

## 許可される verdict

- `go`: task contract を満たしている
- `reject`: Phase5 に差し戻す。`rollback_phase` は `Phase5`

このフェーズでは `conditional_go` を使わないこと。`reject` 以外では `rollback_phase` は空文字でよい。

## Markdown 出力に含める内容

- 概要
- Criterion-by-Criterion Check
- Review Checklist
- Defects
- Verdict Rationale

## JSON 出力

`phase5-1_verdict.json` には以下のキーを必ず含めること。

- `task_id`
- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `acceptance_criteria_checks`
- `review_checks`

`must_fix` は Phase5 で直せる具体的な修正項目にすること。`evidence` には参照したファイル、コマンド、差分の根拠を入れること。`evidence` は 1 件だけでも文字列ではなく JSON 配列にすること。

`acceptance_criteria_checks[]` は各 acceptance criterion ごとの固定チェック配列で、各要素は以下のキーを持つこと。

- `criterion`
- `status`: `pass` または `fail`
- `notes`
- `evidence`

`acceptance_criteria_checks[].evidence` は必ず JSON 配列にすること。

`review_checks[]` は以下の `check_id` をすべて含む固定チェック配列で、各要素は `check_id`、`status`、`notes`、`evidence` を持つこと。`review_checks[].evidence` も必ず JSON 配列にすること。

- `selected_task_alignment`
- `acceptance_criteria_coverage`
- `changed_files_audit`
- `test_evidence_review`
- `design_boundary_alignment`
- `visual_contract_alignment`

## 品質基準

- すべての acceptance criteria を個別に確認している
- `review_checks` の 6 項目を省略していない
- reject の場合は修正項目が具体的で再実装可能である
- task_id が現在の task と一致している

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたは外部から招聘されたQA監査官です。
あなたはこのコードの実装には一切関与していません。
このコードは経験1年目のジュニアエンジニアが書いたものと仮定し、懐疑的な目で検査してください。

## 入力（参照）

Input Artifacts と `Selected Task` を読み込むこと。

- planned task / repair task を問わず、検証対象の正本は `Selected Task` に含まれる `acceptance_criteria`、`changed_files`、`boundary_contract`、`visual_contract` である
- `Selected Task.open_requirement_overlay.items[]` がある場合は、その `additional_acceptance_criteria`、`verification`、`suggested_changed_files` を使って、in-scope carry-forward requirement の取りこぼしがないか追加確認すること
- `phase4_task_breakdown.md` は背景説明の補助として参照してよいが、repair task のために別の raw contract file を探さないこと
- 対象 task は engine がすでに選択済みである。task artifact directory を走査して自分で選び直さないこと

### 機能要件

- [ ] Acceptance Criteriaをすべて満たしているか
- [ ] `Selected Task.changed_files` と実際の変更ファイルが一致するか
- [ ] `Selected Task.boundary_contract` にない越境（モジュール境界、公開I/F、依存、副作用、状態所有変更）が入っていないか
- [ ] `Selected Task.visual_contract` に反する色・タイポグラフィ・コンポーネント状態・レスポンシブ挙動の逸脱がないか

### 品質

- [ ] テストが失敗しないか
- [ ] Lint/Formatが通るか
- [ ] 未使用コードを追加していないか

### 安全性

- [ ] 破壊的変更をしていないか
- [ ] 影響範囲を明示したか
- [ ] 入力検証が適切か（ユーザー入力・外部API入力）
- [ ] 認証・認可の考慮漏れがないか
- [ ] ログ出力に機密情報（パスワード、トークン等）が含まれていないか
- [ ] **API層の入力制限と内部ロジック層の制約が整合しているか**
  - API層で `max_length=N` や `min/max` などを定義した場合、サービス・パイプライン・リポジトリ等の内部ロジックでも同一の上限値・下限値を使用しているか確認すること
  - 不一致の例（NG）: `POST /themes` → `max_length=200` だが、ジェネレーター側でテーマ長 `> 100` で拒否する→ API的には正常入力でも内部エラー
  - 確認方法: Phase3設計書のAPI設計セクションと実ファイルの制約定義を照合する
  - **No の場合**: どちらを正とするかを実装コメントで明記するか、共通定数として一元化すること


### エラーハンドリング

- [ ] 想定外の入力に対してシステムエラー(500)ではなく適切なエラーレスポンス(400/404等)を返すか
- [ ] エラーメッセージが技術的詳細（SQL、スタックトレース等）を露出していないか
- [ ] リトライ可能なエラーと致命的なエラーが区別されているか
- [ ] 例外処理が適切にハンドリングされているか（未キャッチの例外がないか）
- [ ] エラー時のリソース解放（DB接続、ファイルハンドル等）が適切か

### 保守性

- [ ] 命名が既存コードの規約に従っているか
- [ ] マジックナンバーや埋め込み文字列がないか
- [ ] 設計された境界を壊していないか（task contract にない越境がないか）
- [ ] 視覚設計契約を壊していないか（task contract にない visual deviation がないか）

## 出力

各項目を Yes / No / N/A で回答し、Noの項目には修正案を付記すること。
全項目Yesの場合のみPhase6に進行可能。

## 出力例（Few-shot）

以下はタスク「T-02: 検索APIエンドポイント実装」の完了チェック出力例。

```
### 機能要件

- [x] Acceptance Criteriaをすべて満たしているか: **Yes**
  - GET /api/products/search?q=テスト でJSON応答が返る → search.py:35 でJSONResponseを返却、テストtest_search_returns_matching_productsで検証済み
  - page, per_pageパラメータが正しく動作する → search.py:22-24 でクエリパラメータ取得、test_search_paginationで検証済み
  - 不正なパラメータに対して400エラーを返す → search.py:26-30 でバリデーション、test_search_missing_query / test_search_invalid_pageで検証済み
  - **Noの可能性を検討**: per_page=0 の場合の挙動が未定義。AC上は「不正なパラメータ」に該当するが、テストケースになく、search.py:28 のバリデーションが `page < 1` のみで per_page < 1 を検証していない。ただしAC原文は「不正なパラメータに対して400エラー」であり per_page=0 は暗黙に含まれるため **境界値の網羅不足** として指摘する
- [x] Phase4の変更対象ファイルと実際の変更ファイルが一致するか: **Yes**
  - src/api/products/search.py（新規） → 一致
  - src/api/products/__init__.py（修正: L45にルーティング追加） → 一致
  - tests/api/products/test_search.py（新規） → 一致

### 品質

- [x] テストが失敗しないか: **Yes** — pytest 12 passed, 0 failed（実行コマンド: `pytest tests/api/products/test_search.py -v`）
- [x] Lint/Formatが通るか: **Yes** — ruff check + black --check 通過
- [x] 未使用コードを追加していないか: **Yes** — 全関数・インポートが使用されていることを確認

### 安全性

- [x] 破壊的変更をしていないか: **Yes** — 新規エンドポイント追加のみ。既存の /api/products/ 配下のルートと競合しないことを __init__.py で確認
- [x] 影響範囲を明示したか: **Yes** — 実装概要セクションに記載
- [ ] 入力検証が適切か: **No** — search.py:22 で検索クエリ `q` を受け取っているが最大長制限がない。
  to_tsvector('japanese', ...) に数万文字の入力が渡るとCPU負荷が急増し、DoSリスクがある。
  修正案: search.py:26 のバリデーションブロックに `if len(q) > 200: return 400` を追加
- [x] 認証・認可の考慮漏れがないか: **N/A** — 公開APIのため認証不要（Phase3設計書 セクション3「認証: 不要」で確定済み）
- [x] ログ出力に機密情報が含まれていないか: **Yes** — search.py:40 のログ出力は検索クエリのみ。PII含まず

### エラーハンドリング

- [x] 想定外の入力に対してシステムエラー(500)ではなく適切なエラーレスポンス(400/404等)を返すか: **Yes** — search.py:26-30 のバリデーションで400エラーを返却。500エラーは真の内部エラーのみ
- [x] エラーメッセージが技術的詳細を露出していないか: **Yes** — エラーレスポンスは `{"error": {"code": "E_VALIDATION", "message": "パラメータqは必須です"}}` で汎用メッセージのみ。スタックトレースなし
- [x] リトライ可能なエラーと致命的なエラーが区別されているか: **N/A** — 本エンドポイントはステートレスで全エラーがリトライ不可（400系）。503エラーは実装なし
- [x] 例外処理が適切にハンドリングされているか: **Yes** — search.py:50-52 でDB例外をキャッチし500エラーに変換。未キャッチ例外なし
- [x] エラー時のリソース解放が適切か: **Yes** — DB接続はコンテキストマネージャ（with文）で管理。例外発生時も自動解放される

### 保守性

- [x] 命名が既存コードの規約に従っているか: **Yes** — snake_case統一、既存の /api/products/ 配下と同一パターン
- [x] マジックナンバーや埋め込み文字列がないか: **Yes** — DEFAULT_PER_PAGE=20, MAX_PER_PAGE=100 を定数定義済み（search.py:8-9）

### 判定

**判定結果の表記**:
- 全項目Yes → **Go — Phase5-2へ進行可能**
- No項目あり → **Reject — Phase5に差し戻し**

出力例：

**Reject — Phase5に差し戻し**

No項目:
1. 入力検証（検索クエリの最大長制限が未実装）— DoSリスク
2. （WARNING）per_page=0 の境界値テストが不足 — 機能的なバグリスク

## 要約（200字以内）

T-02完了チェック：11項目中10項目Yes、1項目No。No項目は検索クエリqの最大長制限が未実装でDoSリスクあり。追加指摘としてper_page=0の境界値テスト不足。修正案：max_length=200バリデーション追加＋per_page<1のバリデーション追加。機能要件は概ね充足、品質・保守性は問題なし。
```

追加例として、`Relevant Open Requirements` が渡されている task の完了チェックイメージも示す。

````markdown
### 概要

`Relevant Open Requirements` として `auth-rate-limiting-T-02` と `login-ui-error-path-tests-T-02` を受領。
今回 task の `changed_files` は `src/app/api/auth/signin/route.ts`、`src/middleware.ts`、`src/lib/rate-limit.ts` を含むため、
`auth-rate-limiting-T-02` は in-scope の完了条件として追加照合した。
一方 `login-ui-error-path-tests-T-02` は `login/page.tsx` と jsdom 設定変更が必要で、今回 task の changed_files / boundary_contract 外と判断したため補助的 warning に留めた。

### Criterion-by-Criterion Check

- [x] サインイン成功時に既存フローを壊していないか: **Yes**
  - 根拠: `src/__tests__/api/auth/signin.test.ts:18-42` の正常系が通過
- [ ] ブルートフォース抑止のため、短時間の連続失敗時に 429 を返すか: **No**
  - 根拠: `src/app/api/auth/signin/route.ts:21-39` にレート制限呼び出しがなく、`src/lib/rate-limit.ts` も新規追加されていない
  - open requirement `auth-rate-limiting-T-02` は今回 task の changed_files と一致するため、後続 task に送らず今回の不適合として扱う

### Review Checklist

- `Selected Task.changed_files` と実変更の整合: **No**
  - `src/lib/rate-limit.ts` が作成されておらず、`phase5_result.json` の `changed_files` とも不一致
- `Relevant Open Requirements` の in-scope 照合: **No**
  - `auth-rate-limiting-T-02` が未解消
- `Relevant Open Requirements` の out-of-scope 切り分け: **Yes**
  - `login-ui-error-path-tests-T-02` は今回 task の reject 根拠に含めず、継続課題として扱う判断は妥当

### Defects

1. `auth-rate-limiting-T-02` が未実装。`signin` route にレート制限がなく、ブルートフォース抑止の要件を満たしていない
2. `phase5_result.json` では open requirement を回収した前提の要約になっているが、実ファイルと一致しない

### Verdict Rationale

**Reject — Phase5に差し戻し**

今回の task は `auth-rate-limiting-T-02` を実装できる changed_files / boundary_contract を持っているにもかかわらず、
実コードで未解消のままである。in-scope open requirement の取りこぼしは Phase5 の未完了として扱う。

## phase5-1_verdict.json の抜粋例

```json
{
  "task_id": "T-02",
  "verdict": "reject",
  "rollback_phase": "Phase5",
  "must_fix": [
    "`auth-rate-limiting-T-02` を in-scope requirement として実装し、src/app/api/auth/signin/route.ts または src/middleware.ts で実際にレート制限を有効化すること",
    "phase5_result.json の implementation_summary / changed_files を実コードと一致させること"
  ],
  "warnings": [
    "`login-ui-error-path-tests-T-02` は今回 task の changed_files / boundary_contract 外であり、reject 根拠ではなく継続課題として扱った"
  ],
  "evidence": [
    "src/app/api/auth/signin/route.ts:21-39",
    "phase5_result.json",
    "Selected Task.changed_files"
  ],
  "acceptance_criteria_checks": [
    {
      "criterion": "ブルートフォース抑止のため、短時間の連続失敗時に 429 を返す",
      "status": "fail",
      "notes": "Relevant Open Requirement `auth-rate-limiting-T-02` が未解消",
      "evidence": [
        "src/app/api/auth/signin/route.ts:21-39"
      ]
    }
  ],
  "review_checks": [
    {
      "check_id": "selected_task_alignment",
      "status": "fail",
      "notes": "in-scope open requirement を changed_files 内で回収できていない",
      "evidence": [
        "Selected Task.changed_files",
        "src/app/api/auth/signin/route.ts:21-39"
      ]
    },
    {
      "check_id": "acceptance_criteria_coverage",
      "status": "fail",
      "notes": "429 応答の要件が未達",
      "evidence": [
        "src/__tests__/api/auth/signin.test.ts"
      ]
    },
    {
      "check_id": "changed_files_audit",
      "status": "fail",
      "notes": "phase5_result.json の changed_files と実ファイルが一致しない",
      "evidence": [
        "phase5_result.json",
        "Selected Task.changed_files"
      ]
    },
    {
      "check_id": "test_evidence_review",
      "status": "pass",
      "notes": "正常系テストの実行証跡は存在するが、レート制限の失敗系証跡が不足する",
      "evidence": [
        "src/__tests__/api/auth/signin.test.ts:18-42"
      ]
    },
    {
      "check_id": "design_boundary_alignment",
      "status": "pass",
      "notes": "今回の defect は設計境界逸脱ではなく、境界内 requirement の未実装",
      "evidence": [
        "Selected Task.boundary_contract"
      ]
    },
    {
      "check_id": "visual_contract_alignment",
      "status": "pass",
      "notes": "今回 task は UI 視覚変更を含まず、visual contract 逸脱は確認されない",
      "evidence": [
        "Selected Task.visual_contract"
      ]
    }
  ]
}
```
````

### Reject詳細（No項目がある場合は必須出力）

```
- 原因分類: 実装不備 / テスト不備
- 差し戻し先: Phase5
- 根拠: （なぜ Phase5 に戻すべきか1文で説明）
- 修正指示: （Phase5 で何を修正すべきか具体的に記載）
```

出力の最後に `## 要約（200字以内）` セクションを付与すること。
全項目Yesか否か・No項目の概要を簡潔にまとめる。

出力は `<task artifact directory>/phase5-1_completion_check.md` に保存すること。
