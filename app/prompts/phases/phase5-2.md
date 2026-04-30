# Phase5-2 セキュリティチェック テンプレート

このフェーズでは、Phase5 の変更に対してセキュリティと安全性の観点から reviewer として判定する。

## 実行原則

- `Selected Task`、`phase5_result.json`、`phase5-1_verdict.json` を正本として読むこと
- 入力検証、認証認可、機密情報、権限境界、危険な副作用を優先的に確認すること
- Required Outputs に書かれた `phase5-2_security_check.md` と `phase5-2_verdict.json` のみを作成すること

## 許可される verdict

- `go`: 重大なセキュリティ懸念なし
- `conditional_go`: 実装は継続可能だが、Phase6 と Phase7 で追跡すべき残課題がある
- `reject`: Phase5 に差し戻す。`rollback_phase` は `Phase5`

`reject` 以外では `rollback_phase` は空文字でよい。`conditional_go` を使う場合は `must_fix` に残課題を具体的に書くこと。

重要:

- `security_checks[].status` に `fail` が 1 件でもある場合、verdict は `reject` にすること
- `conditional_go` は `security_checks[].status` が `pass` / `warning` / `not_applicable` のみで、かつ `warning` が 1 件以上ある場合に限る
- `conditional_go` の `must_fix` / `open_requirements` は「実装を継続できるが後続 phase で必ず追跡する条件」に限定すること

## Markdown 出力に含める内容

- 概要
- Security Checklist
- Critical Findings
- Warnings
- Residual Risks
- Verdict Rationale

## JSON 出力

`phase5-2_verdict.json` には以下のキーを必ず含めること。

- `task_id`
- `verdict`
- `rollback_phase`
- `must_fix`
- `warnings`
- `evidence`
- `security_checks`
- `open_requirements`
- `resolved_requirement_ids`

`security_checks[]` は以下の `check_id` をすべて含む固定チェック配列で、各要素は `check_id`、`status`、`notes`、`evidence` を持つこと。`security_checks[].evidence` は 1 件だけでも文字列ではなく JSON 配列にすること。

- `input_validation`
- `authentication_authorization`
- `secret_handling_and_logging`
- `dangerous_side_effects`
- `dependency_surface`

`status` は `pass`、`warning`、`fail`、`not_applicable` のいずれかにすること。`not_applicable` の場合でも `notes` で理由を書くこと。

`open_requirements[]` は `conditional_go` で後続 phase に持ち越す未解決条件の配列とし、各要素は以下のキーを持つこと。

- `item_id`
- `description`
- `source_phase`
- `source_task_id`
- `verify_in_phase`
- `required_artifacts`

`source_phase` は `Phase5-2`、`source_task_id` は現在の task id を入れること。`verify_in_phase` には、この条件を再確認すべき phase を書くこと。`required_artifacts` には確認に使う artifact id を列挙すること。`required_artifacts` も JSON 配列にすること。

`resolved_requirement_ids[]` には、過去の `open_requirements` のうち今回の review で解消済みと判断した `item_id` を列挙すること。新規 review で該当がなければ空配列にすること。

## 品質基準

- `security_checks` の 5 項目を省略していない
- reject は本当に Phase5 の実装修正が必要な場合に限る
- conditional_go の場合は、`must_fix` と対応する `open_requirements` を 1 件以上入れ、後続 review で追跡できる
- conditional_go の場合は `security_checks[].status = fail` を含めない
- security_checks に `fail` がある場合は `reject` を選び、Phase5 へ差し戻す
- go / reject の場合は `open_requirements` を空配列にする
- evidence に確認したコード箇所や実行根拠が入っている

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたは外部から招聘されたペネトレーションテスターです。
あなたはこのコードの実装には一切関与していません。
このコードは「攻撃可能な脆弱性を含んでいる」と仮定して検査を開始してください。

## 入力（参照）

以下のファイルを読み込むこと：
- `<task artifact directory>/phase5_implementation.md`（フル参照 — 変更ログ）
- `<task artifact directory>/phase5-1_completion_check.md`（フル参照 — チェック結果）
- `<repair task artifact directory>/fix_contract.yaml`（`pr_fixes` タスク時は必須。修正スコープ定義）

対象タスク（人間が指定）：
- `<task artifact directory>/`

### ⚠️ `pr_fixes` タスクの場合の特別対応

**タスクIDが `pr_fixes` の場合は、検査スコープの起点が異なる。**

1. `<repair task artifact directory>/fix_contract.yaml` を開き、`must_fix` / `acceptance_criteria` / `out_of_scope` を確認する
2. `<run artifact directory>/phase7_pr_review.md` の `## Critical Issues` を開き、修正対象を確認する
3. `phase5_implementation.md` の変更ファイル一覧を確認する（修正された実ファイルのみが検査対象）
4. **OWASPチェックは修正ファイルに絞って実施する**（プロジェクト全体ではなく差分のみ）
5. Phase7で既に指摘・承認済みの WARNING は「既知・承認済み」として扱い、NG にしない
   - 例: Phase7で「本番前修正」として先送りされたCORSは、pr_fixesのスコープ外

> **【重要】検査対象は「実装タスクの変更ファイル全体」とする。**
> バックエンドのみ、フロントエンドのみ、と限定せず、phase5_implementation.md の変更対象ファイルに含まれるすべてのファイルを検査すること。
> フロントエンドコード（TypeScript/JavaScript）が含まれる場合は、後述の「6. フロントエンド固有のチェック」を**必ず**実施する。

### 根拠の出し方

セキュリティ指摘は「攻撃シナリオ → 成立/不成立の根拠」を**再現可能**に示すこと。

## 検査観点（OWASP Top 10ベース）

### 1. インジェクション

- SQLインジェクション
- コマンドインジェクション
- XSS（クロスサイトスクリプティング）

### 2. 認証・認可

- 認証バイパスの可能性
- 権限昇格の可能性
- セッション管理の妥当性

### 3. データ保護

- 機密データの平文保存
- ログへの機密情報出力
- 不要なデータ露出（APIレスポンス等）

### 4. 設定・構成

- デフォルト資格情報の使用
- デバッグモードの残存
- 不要なエンドポイントの露出

### 5. 依存関係

- 既知の脆弱性を持つライブラリの使用
- ライセンス互換性（商用利用可否、GPL等のコピーレフト確認）

### 6. フロントエンド固有のチェック（変更ファイルにTS/JS/TSXが含まれる場合）

> **実施条件**: phase5_implementation.md の変更対象ファイルにフロントエンドコード（.ts / .tsx / .js / .jsx）が含まれる場合は**必須**。含まれない場合は「N/A（フロントエンド変更なし）」と記載して省略可。

#### 6-1. XHR/fetch のエラーハンドリング・無限ループリスク

- **再帰呼び出しに深度制限があるか**: fetchラッパー・リトライ処理が self-call や相互再帰を行う場合、スタックオーバーフロー／無限ループに至る経路がないか確認する。
  - 攻撃シナリオ例: JWT失効 → 401 → トークン削除 → 再発行API → 再発行後も401 → 再帰がループ
  - チェック箇所: `retried` フラグ・再試行カウンタ・再帰の終端条件の有無
- **エラー時の状態整合性**: fetch が例外 or 非2xx を返したとき、ローカルストレージ・Cookieなどのクライアント側状態が中途半端な更新になっていないか確認する。

#### 6-2. クライアントサイドの認証情報管理

- **localStorage / sessionStorage への機密情報保存**: JWTやAPIキーを localStorage に保存している場合、XSSによる盗取リスクがあることを確認・指摘する。
- **Cookie の HttpOnly / SameSite 設定**: 管理者用トークンを Cookie で管理している場合、`httpOnly` および `sameSite` が適切に設定されているか確認する。
- **トークンの漏洩経路**: エラーメッセージ・URLパラメータ・ログへのトークン混入がないか確認する。

#### 6-3. クライアントサイドの入力検証

- サーバー側バリデーションと一致しているかを確認する（例: API側 max_length=100 なのにフロントは 200 まで送れるなど）。
- 不一致がある場合は NG とし、整合性の確認を修正案として記載する。

## 出力フォーマット

| 項目 | 判定 | 攻撃シナリオの検討 → 判定根拠 | 修正案 |
|------|------|------|--------|
| （検査項目） | OK / NG / N/A | （想定した攻撃手法 → なぜ成立する/しないか、具体的なコード箇所） | （修正方法） |

## 出力例（Few-shot）

以下はタスク「T-02: 検索APIエンドポイント実装」のセキュリティチェック出力例。

```
| 項目 | 判定 | 攻撃シナリオの検討 → 判定根拠 | 修正案 |
|------|------|------|--------|
| SQLインジェクション | OK | 攻撃: qパラメータに `'; DROP TABLE--` を注入 → search.py:32 で to_tsquery にパラメータバインド（`%s`）で渡しており、文字列結合なし。ORMのexecute経由で実行されるため注入不可 | — |
| コマンドインジェクション | N/A | search.py 全体を走査し subprocess / os.system / exec 等の呼び出しなし。OS コマンド実行パスが存在しない | — |
| XSS | N/A | 本エンドポイントはJSON APIのみ（Content-Type: application/json）。HTMLレンダリングパスなし。ただしレスポンスの商品名がフロント側でinnerHTMLに渡される場合はフロント側の責務 | — |
| 認証バイパス | N/A | 公開API（Phase3設計書 セクション3で「認証: 不要」と確定済み）。__init__.py のルーティングに認証ミドルウェアが付与されていないことを確認 | — |
| 権限昇格 | N/A | 認可制御なし（公開API）。他ユーザーのデータにアクセスするパスなし（検索結果は全ユーザー共通） | — |
| セッション管理 | N/A | セッション・Cookie操作のコードなし | — |
| 機密データの平文保存 | N/A | DB読み取りのみ。書き込み・保存処理なし | — |
| ログへの機密情報出力 | OK | 攻撃: ユーザーがクエリに個人情報を入力した場合 → search.py:40 で `logger.info(f"search query: {q}")` としてログ出力。検索クエリは商品名の断片であり通常PIIを含まないが、ユーザーが氏名等を検索する可能性はゼロではない。現時点ではOKとするが、アクセスログのPII取扱いポリシーがあれば再確認を推奨 | — |
| 不要なデータ露出 | OK | 攻撃: レスポンスに内部IDやDB構造が漏洩していないか → レスポンスは商品ID・名前・説明・スコアのみ。内部の主キー以外の技術的情報（created_at等）は含まれていない | — |
| デフォルト資格情報 | N/A | 本エンドポイントで資格情報の使用なし | — |
| デバッグモード残存 | OK | 設定ファイルでDEBUG=Falseを確認。search.py内にpdb/breakpoint/print文なし | — |
| 不要なエンドポイント露出 | OK | __init__.py を確認し、本タスクで追加されたルートは `/api/products/search` のみ。設計書記載と一致 | — |
| 既知脆弱性ライブラリ | OK | `pip-audit` 実行結果: 0 vulnerabilities found。requirements.txt の追加パッケージなし | — |
| ライセンス互換性 | OK | 新規追加パッケージなし。既存依存関係のライセンス確認済み（MIT, Apache 2.0のみ、GPL系なし） | — |
| **入力値の長さ制限** | **NG** | 攻撃: qパラメータに10万文字の文字列を送信 → search.py:22 で長さチェックなし。to_tsvector('japanese', ...) に長大な入力が渡りCPU負荷が急増。レートリミットもエンドポイント単位では未設定。DoS攻撃が成立する | `q` に max_length=200 のバリデーション追加。可能であればレートリミットも検討 |

### 総合判定

**Conditional Go**

NG 1件: 入力値の長さ制限が未実装。DoSリスクはあるが、WAFのリクエストサイズ制限で
一定の緩和が期待できるため、Rejectではなく Conditional Go とする。
ただし、次タスク着手前にPhase5で修正することを強く推奨する。

## 要約（200字以内）

T-02セキュリティチェック：Conditional Go。NG 1件は検索クエリqの最大長制限未実装によるDoSリスク。SQLインジェクションはto_tsqueryのパラメータバインドで対策済み。公開APIのため認証・認可関連はN/A。既知脆弱性ライブラリなし。WAFで部分緩和されるがアプリ層での制限追加を推奨。
```

### 悪い出力例（このように書かないこと）

```
❌ 全項目「OK」で詳細が空欄 → 攻撃シナリオと防御根拠を具体的に記載すること
❌ 「問題なし」だけの判定 → 「なぜ攻撃が成立しないか」をコード箇所で説明すること
❌ N/Aの根拠がない → 攻撃面が本当に存在しないことを確認した過程を示すこと
❌ NGなのに修正案がない → 修正案の記載は必須
❌ OWASP項目の一部しかチェックしていない → 全5カテゴリを網羅すること
❌ 攻撃シナリオの検討なしにOK判定 → まず「どう攻撃できるか」を考えてから判定すること
❌ 変更対象にフロントエンドコードがあるのにセクション6を省略 → フロント変更がある場合は必ず6を実施すること
❌ fetchラッパーの再帰呼び出しを確認せずにOK → 401リトライループの終端条件を必ず確認すること
```

## 総合判定

- Go: セキュリティ問題なし
- Conditional Go: 軽微な問題あり（修正推奨）
- Reject: 重大な脆弱性あり（修正必須）

### Reject詳細（Reject判定時のみ出力）

```
- 原因分類: 設計不備 / タスク分解不備 / 実装不備
- 差し戻し先: Phase3 / Phase4 / Phase5
- 根拠: （なぜその分類か1文で説明）
- 修正指示: （差し戻し先で何を修正すべきか具体的に記載）
```

出力の最後に `## 要約（200字以内）` セクションを付与すること。
総合判定・検出された脆弱性の有無と概要を簡潔にまとめる。

出力は `<task artifact directory>/phase5-2_security_check.md` に保存すること。
