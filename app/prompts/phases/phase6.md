# Phase6 テスト テンプレート

このフェーズでは、対象 task に対して実際の検証コマンドを走らせ、結果を task artifact として残す。

## 実行原則

- `Selected Task` と `phase5_result.json` を正本として、必要な lint・型チェック・テストを実行すること
- 推測ではなく実測値を書くこと
- Required Outputs に書かれた `phase6_testing.md`、`phase6_result.json`、`test_output.log` を必ず作成すること
- `junit.xml` と `coverage.json` はツールが出せる場合のみ追加すること
- 次 task の選択、completion marker の作成、制御ファイル更新は engine が行う。自分では行わないこと

## 実施内容

- 実行した lint コマンドを記録する
- 実行した test コマンドを記録する
- 標準出力と標準エラーを `test_output.log` に保存する
- 取得できる場合は line / branch coverage を測定する
- テスト不能な項目があれば markdown に理由を書く

## Markdown 出力に含める内容

- 概要
- Commands
- Verification Checklist
- Test Results
- Coverage
- Failures or Residual Issues
- Verdict Rationale

## JSON 出力

`phase6_result.json` には以下のキーを必ず含めること。

- `task_id`
- `test_command`
- `lint_command`
- `tests_passed`
- `tests_failed`
- `coverage_line`
- `coverage_branch`
- `verdict`
- `conditional_go_reasons`
- `verification_checks`
- `open_requirements`
- `resolved_requirement_ids`

`tests_passed`、`tests_failed`、`coverage_line`、`coverage_branch` は数値にすること。coverage を取得できない場合でも数値を入れ、markdown で理由を補足すること。

`verification_checks[]` は以下の `check_id` をすべて含む固定チェック配列で、各要素は `check_id`、`status`、`notes`、`evidence` を持つこと。

- `lint_static_analysis`
- `automated_tests`
- `regression_scope`
- `error_path_coverage`
- `coverage_assessment`

`status` は `pass`、`warning`、`fail`、`not_applicable` のいずれかにすること。`conditional_go` の場合は `verification_checks` に少なくとも 1 件 `warning` を含めること。

`open_requirements[]` は `conditional_go` で後続 phase に持ち越す未解決条件の配列とし、各要素は以下のキーを持つこと。

- `item_id`
- `description`
- `source_phase`
- `source_task_id`
- `verify_in_phase`
- `required_artifacts`

`source_phase` は `Phase6`、`source_task_id` は現在の task id を入れること。`verify_in_phase` には、この条件を再確認すべき phase を書くこと。`required_artifacts` には確認に使う artifact id を列挙すること。

`resolved_requirement_ids[]` には、過去の `open_requirements` のうち今回の test/review で解消済みと判断した `item_id` を列挙すること。該当がなければ空配列にすること。

## 許可される verdict

- `go`: 検証通過
- `conditional_go`: テストは進行可能だが残課題あり。`conditional_go_reasons` を 1 件以上必須
- `reject`: Phase3 / Phase4 / Phase5 のいずれかへ差し戻し。実際に必要な戻り先を選ぶこと

## 品質基準

- `verification_checks` の 5 項目を省略していない
- `test_command` と `lint_command` は実際に使ったコマンドである
- `test_output.log` と markdown の要約が矛盾しない
- conditional_go の場合は、`conditional_go_reasons` と対応する `open_requirements` を 1 件以上入れる
- go / reject の場合は `open_requirements` を空配列にする
- 既存の open requirement を解消した場合は `resolved_requirement_ids` に明示する

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはシニアQAエンジニア兼CI品質ゲート担当です。
以下の変更（差分）に対して、テスト設計・テスト実行・品質判定を実施してください。

> **重要**: テスト結果は必ず実際のコマンド出力に基づくこと。
> LLMが推測した「見込み」値を実測値として記載してはならない。

## 入力（参照）

Input Artifacts と `Selected Task` を読み込むこと。

- `phase5_implementation.md`、`phase5-1_completion_check.md`、`phase5-2_security_check.md` のような task artifact を参照しつつ、必ず実リポジトリの状態と実コマンド出力で裏取りすること
- 対象 task は engine がすでに選択済みである。task artifact directory や marker file を走査して自分で選び直さないこと
- repair task であっても検証粒度や後続遷移を自己判断で軽量化しないこと。`Selected Task` に対して通常どおり検証すること

## 目的

- AI実装コードを人間レビュー前に機械検証でふるいにかける
- 「テストが実際にpassする」ことを確認し、推測に基づく品質判定を排除する

> **重要**: phase5_implementation.mdの内容（変更ログ）ではなく、実リポジトリの状態（実ファイル + `git diff` + 実際のテスト実行結果）を根拠として判定すること。

## テスト種別選択基準

| 種別 | 対象 | 使用場面 |
|------|------|----------|
| 単体テスト | 個別関数・メソッド | 全タスクで必須 |
| 結合テスト | モジュール間連携 | API・DB連携がある場合 |
| E2Eテスト | ユーザーフロー全体 | 画面操作を伴う場合 |

- 対象タスクの性質に応じて適切な種別を選択すること

## 検証ルール

1. 実装仕様とは独立した観点でテスト設計
2. 正常系・異常系・境界値を必ず含める
3. 外部依存（DB/API）はモック化
4. 破壊的テスト禁止（実DB書換禁止）
5. テスト不足は即Reject

## カバレッジ目標

- 行カバレッジ: 80%以上
- 分岐カバレッジ: 70%以上

### カバレッジ未達時の判定

未達の場合は、以下の**許容条件**を満たす場合のみ Conditional Go とする。
**それ以外は Reject。**

| 許容条件 | 説明 | 判定 |
|---------|------|------|
| 外部API・外部サービス依存でMock化が技術的に不可能なコードパス | SDKや外部ライブラリの内部実装に起因し、テストダブルの作成が不可能な場合。「面倒なため省略」は不可 | Conditional Go |
| UIレンダリング専用コード（ビジネスロジックを含まない） | CSSクラス付与・アニメーション等、ロジックを持たない純粋なView層のみ | Conditional Go |
| 上記いずれにも該当しない | 実装コードのカバレッジ不足・テストケースの網羅漏れ | **Reject** |

> **「理由を書けばConditional Go」は不可。** 必ず上記許容条件のいずれかに該当することを
> コード箇所・技術的根拠とともに明示すること。根拠を示せない場合は Reject とする。

## 実行手順

以下の手順を順番に実施すること。

## Step 1: テスト設計

Phase5の実装コードに対して、テスト観点を洗い出しテストコードを作成する。
テストコードは実際のテストファイルとしてプロジェクト内の適切なパスに保存する。

### Step 1-E: エラーパスカバレッジ確認（必須）

> **重要**: 正常系テストだけで Go 判定することを禁止する。
> 以下のエラーパスを**タスクの変更ファイルに合わせて**テストに含めること。

#### バックエンド（FastAPI / Python 等）のエラーパス

| 確認項目 | テスト実施 | 備考 |
|----------|-----------|------|
| 401 Unauthorized — 認証トークン不正・期限切れ | ☐ 実施 / ☐ N/A | 認証が関係するエンドポイントは必須 |
| 403 Forbidden — 権限不足 | ☐ 実施 / ☐ N/A | 認可チェックがあるエンドポイントは必須 |
| 404 Not Found — 存在しないリソース | ☐ 実施 / ☐ N/A | IDを受け取るエンドポイントは必須 |
| 422 Unprocessable Entity — バリデーション失敗 | ☐ 実施 / ☐ N/A | 入力受け付けるエンドポイントは必須 |
| 外部API（LLM等）タイムアウト / エラー時のフォールバック | ☐ 実施 / ☐ N/A | 外部依存がある場合は必須 |
| DB接続失敗・トランザクション失敗 | ☐ 実施 / ☐ N/A | DBアクセスがある場合は必須 |

#### フロントエンド（TypeScript / React 等）のエラーパス — 変更ファイルにTS/JSが含まれる場合

| 確認項目 | テスト実施 | 備考 |
|----------|-----------|------|
| 401 レスポンス時のUI挙動（リダイレクト・エラー表示・トークン削除など） | ☐ 実施 / ☐ N/A | fetchラッパーがあれば必須 |
| 403 レスポンス時のUI挙動（権限エラー表示） | ☐ 実施 / ☐ N/A | |
| 503 / ネットワークエラー時のUI挙動（接続失敗メッセージ等） | ☐ 実施 / ☐ N/A | |
| リトライロジックが存在する場合、無限リトライ・無限再帰が起きないこと | ☐ 実施 / ☐ N/A | fetchラッパーがある場合は**必須** |
| ローディング中のUI状態（スピナー表示・ボタン無効化） | ☐ 実施 / ☐ N/A | |

> **N/Aにする場合**: 「なぜそのエラーパスが発生しえないか」をコード箇所で説明すること。
> 単に「実装が簡単だから」「時間がないから」はN/Aの根拠にならない。

上記チェックリストをテスト実施後に `phase6_testing.md` に記載すること。
N/Aとした場合はその根拠も記載すること。

### Step 2: Lint・型チェック実行

Phase0のプロジェクト設定に記載されたLint/Formatterを実行する。

```
# 実行例（Phase0の設定に従ってコマンドを選択すること）
# Python: ruff check . && mypy .
# TypeScript: eslint . && tsc --noEmit
# Go: golangci-lint run && go vet ./...
```

出力全文を記録する。エラーがあれば修正提案に含める。

### Step 3: テスト実行

テストを実行し、pass/fail結果を取得する。

> **「Watchモード禁止」**: テストは**必ず一回実行モード**で実行すること。Watchモードはエージェントをフリーズさせるため因り禁止。

```
# 実行例（Phase0の設定に従ってコマンドを選択すること）
# Python:     pytest tests/ -v --tb=short 2>&1 | Tee-Object <task artifact directory>/test_output.log
# TypeScript: npx vitest run 2>&1 | Tee-Object <task artifact directory>/test_output.log
# TypeScript(Jest): npx jest --watchAll=false --verbose 2>&1 | Tee-Object <task artifact directory>/test_output.log
# Go:         go test ./... -v 2>&1 | Tee-Object <task artifact directory>/test_output.log
```

**【重要】出力全文を記録すること。** テスト結果は実行ログそのものが根拠となる。

**【必須】テスト実行結果のファイル保存（P1-3）**:
- テスト実行の標準出力・標準エラーを `<task artifact directory>/test_output.log` に保存すること
- このファイルは後続フェーズ（Phase7）での人間レビュー時に検証可能性を担保する
- ファイルが存在しない場合、システムが警告を発行する

### Step 4: カバレッジ計測

カバレッジ付きでテストを再実行し、実測値を取得する。

```
# 実行例（Phase0の設定に従ってコマンドを選択すること）
# Python: pytest tests/ --cov=src --cov-report=term-missing --cov-branch 2>&1
# TypeScript: npx jest --coverage 2>&1
# Go: go test ./... -coverprofile=coverage.out && go tool cover -func=coverage.out
```

**出力全文を記録すること。** カバレッジは推定値ではなく実測値を使用する。

### Step 5: パフォーマンステスト（Phase1で性能要件がある場合）

**実施条件**: Phase1で性能要件（レスポンスタイム、スループット等）が定義されている場合のみ実施

#### 5-1. 負荷テストツールの選定

Phase0のプロジェクト設定、または以下から選択:
- Python: Locust
- TypeScript/JavaScript: k6, Artillery
- 汎用: Apache JMeter

#### 5-2. 負荷シナリオの設計

Phase1の性能要件に基づいてシナリオを作成:
```python
# 例: Locustによる負荷テスト (locustfile.py)
from locust import HttpUser, task, between

class SearchUser(HttpUser):
    wait_time = between(1, 3)
    
    @task
    def search_products(self):
        self.client.get("/api/products/search?q=テスト商品&page=1&per_page=20")
```

#### 5-3. 負荷テストの実行

```bash
# 同時ユーザー数100、目標RPS 50で10分間実行
locust -f locustfile.py --headless -u 100 -r 10 -t 10m --host=http://localhost:3000
```

#### 5-4. パフォーマンス結果の評価

| 指標 | 目標値（Phase1） | 実測値 | 判定 |
|------|----------------|--------|------|
| p50レスポンスタイム | < 300ms | (実測値) | OK / NG |
| p95レスポンスタイム | < 500ms | (実測値) | OK / NG |
| p99レスポンスタイム | < 1000ms | (実測値) | OK / NG |
| エラー率 | < 0.1% | (実測値) | OK / NG |
| スループット | > 50 RPS | (実測値) | OK / NG |

**NG項目がある場合**:
- ボトルネック特定（DB、API、キャッシュ等）
- 修正提案に記載（インデックス追加、クエリ最適化等）
- Conditional Go判定

**パフォーマンステストが実施できない場合**:
- ローカル環境のリソース不足等で実施不可の場合は、その旨を記載しConditional Go
- ステージング環境でのテスト実施を推奨事項として記録

### Step 6: アクセシビリティチェック（UI変更がある場合）

**実施条件**: フロントエンド（HTML/CSS/JS）の変更がある場合のみ実施

#### 6-1. 自動チェックツールの実行

**ツール選択**:
- axe DevTools（ブラウザ拡張）
- Lighthouse（Chrome DevTools）
- pa11y（CLIツール）

```bash
# 例: Lighthouseによるアクセシビリティスコア取得
lighthouse http://localhost:3000/products/search --only-categories=accessibility --output=json

# 例: pa11yによる自動チェック
pa11y http://localhost:3000/products/search
```

#### 6-2. 手動チェック項目

| 項目 | 確認内容 | 判定 |
|------|---------|------|
| キーボード操作 | Tab/Enter/Escキーのみで全機能が利用可能か | OK / NG |
| フォーカス表示 | フォーカス位置が視覚的に明確か | OK / NG |
| ARIA属性 | ボタン、リンク、フォームに適切なrole/aria-label設定があるか | OK / NG |
| カラーコントラスト | WCAG AA基準（4.5:1以上）を満たすか | OK / NG |
| 代替テキスト | 画像・アイコンにalt属性があるか | OK / NG |

#### 6-3. アクセシビリティスコア

- **目標スコア**: Lighthouse Accessibility 90点以上（WCAG AA準拠）
- **実測値**: (実行結果を記載)
- **判定**: OK（90点以上） / Conditional Go（80-89点） / NG（80点未満）

**90点未満の場合**:
- Lighthouseの指摘事項を確認
- 修正提案に具体的な改善策を記載（例: ボタンにaria-labelを追加、コントラスト比を改善）

**アクセシビリティチェックが実施できない場合**:
- UIに変更がない場合は「対象外」
- ツールが利用できない場合は「手動チェックのみ実施」と記載

## 出力フォーマット

1. テスト種別（単体 / 結合 / E2E）
2. テスト観点一覧（箇条書き）
3. テストコード（実行可能形式）
4. Lint・型チェック結果（コマンドと出力を記載）
5. テスト実行結果（コマンドと出力全文を記載）
6. カバレッジ（実測値）
7. 失敗テストの分析（あれば）
8. 修正提案（最小変更）
9. CI判定（Go / Conditional Go / Reject）

## 出力例（Few-shot）

> 詳細な出力例は `app/prompts/phases/examples/phase6_example.md` を参照。

## 判定基準

| 条件 | 判定 |
|------|------|
| テスト全pass + カバレッジ目標達成 | **Go** |
| テスト全pass + カバレッジ未達 + 許容条件（外部API依存Not-Mockable / UIのみ）を**根拠付きで**明示 | **Conditional Go** |
| テスト全pass + カバレッジ未達 + 許容条件を明示できない | **Reject** |
| テスト失敗あり（テストコード起因） | 修正ループ後に再判定 |
| テスト失敗あり（実装バグ起因） | **Reject** |
| テスト網羅が不足（正常系のみ等） | **Reject** |
| **エラーパス（401/403/503等）が未テストで根拠なし** | **Reject** |
| Lint・型チェックエラーあり | **Reject**（修正提案を付記） |

> **Conditional Go にするには許容条件の根拠が必須。**
> 「測定が困難」「時間不足」等の理由は許容条件に該当しない。

### Reject詳細（Reject判定時のみ出力）

```
- 原因分類: 設計不備 / タスク分解不備 / 実装不備 / テスト不備
- 差し戻し先: Phase3 / Phase4 / Phase5
- 根拠: （なぜその分類か1文で説明）
- 修正指示: （差し戻し先で何を修正すべきか具体的に記載）
```

## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
CI判定・実行モード・テスト種別・カバレッジ（実測/推定を明記）・主要な懸念を簡潔にまとめる。

## → 次のアクション

次 task の選択、completion marker の作成、legacy log の追記、フェーズ遷移の実行はすべて engine が担当する。

- `phase6_result.json` に今回の verdict、`conditional_go_reasons`、`open_requirements`、`resolved_requirement_ids` を正確に書くこと
- `conditional_go` の残課題は `open_requirements[]` に構造化して残すこと
- 追加の制御ファイルや task marker を作らないこと
- verdict を書いたら停止し、次の action は engine に任せること

出力は `<task artifact directory>/phase6_testing.md` に保存すること。

> - [ ] `<task artifact directory>/phase6_testing.md` をディスクに書き込んだ（コードブロック表示のみは不可）
> - [ ] `<task artifact directory>/test_output.log` を保存した
> - [ ] CI判定（Go / Conditional Go / Reject）とカバレッジ実測値が記載されている
> - [ ] **Step 1-E エラーパスカバレッジ確認チェックリスト**が記載されており、N/Aとした項目には根拠が記載されている
> - [ ] フロントエンドコードの変更がある場合、**401/503などのHTTPエラー時のUI挙動テスト**が実施またはN/Aが根拠付きで記載されている
> - [ ] Conditional Go 判定の場合、残課題を `open_requirements[]` に構造化して記録した
