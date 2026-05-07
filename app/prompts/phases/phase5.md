# Phase5 実装テンプレート

このフェーズでは、engine が選んだ 1 件の task を実装し、変更内容を task artifact として記録する。

## 実行原則

- `Selected Task` をこのフェーズの正本として扱うこと
- 選ばれた task が planned task でも repair task でも、そこで定義された `changed_files` と `acceptance_criteria` に従うこと
- `Selected Task` に `boundary_contract` がある場合、それを task-scoped の設計境界として守ること
- `Selected Task` に `visual_contract` があり `mode` が `not_applicable` 以外の場合、それを task-scoped の視覚設計契約として守ること
- `Selected Task.open_requirement_overlay.items[]` がある場合、それを relevant open requirements から engine が蒸留した task-scoped addendum として扱うこと
- `Relevant Open Requirements` または `Open Requirements` が渡されている場合、現在 task の境界内で解消可能な項目は可能な限り今回の実装で回収すること
- 他の task を自分で選ばないこと
- Required Outputs に書かれた `phase5_implementation.md` と `phase5_result.json` のみを作成すること
- 次フェーズの判定、completion marker の作成、制御ファイルの更新は engine が行う。自分で行わないこと

## 実装時の注意

- 実ファイルを編集し、変更に必要なテストも更新すること
- 既存コードの流儀に合わせること
- 仕様不明点は勝手に拡張せず、`known_issues` に明示すること
- `Selected Task.open_requirement_overlay.items[]` がある場合は、その `additional_acceptance_criteria` と `verification` を現在 task の追加契約として扱うこと
- 既存の open requirement を解消できる変更が現在 task の `changed_files`、`acceptance_criteria`、`boundary_contract` の範囲で成立するなら、後続 task 任せにせずこのフェーズで取り込むこと
- open requirement を見ても現在 task の境界を越える場合だけ、無理に広げず `known_issues` に「今回見送った理由」を残すこと
- `boundary_contract` にないモジュール越境、公開インターフェース追加、依存追加、副作用追加、状態所有変更は勝手に行わないこと
- `visual_contract` にない新しい見た目ルール、コンポーネント状態、レスポンシブ挙動を勝手に足さないこと

## Markdown 出力に含める内容

- Task Summary
- Changed Files
- Implementation Details
- Commands Run
- Acceptance Criteria Status
- Known Issues / Residual Risks

## JSON 出力

`phase5_result.json` には以下のキーを必ず含めること。

- `task_id`
- `changed_files`
- `commands_run`
- `implementation_summary`
- `acceptance_criteria_status`
- `known_issues`

`acceptance_criteria_status` は配列で、各要件に対して達成状況と根拠が分かるように記録すること。
`commands_run` は配列で、最低 1 件以上の実行コマンドを含めること。doc-only task や repo 外インフラ設定 task でも空配列にしてはいけない。

## 品質基準

- `task_id` が Selected Task と一致する
- `changed_files` が実際の変更内容と一致する
- `commands_run` には実際に試したコマンドのみを書く
- doc-only / infra-only task でも `commands_run` を空にしない。build / test / lint が不要な場合は、実際に実行した確認コマンドを 1 件以上残すこと
- doc-only / infra-only task の確認コマンドには、たとえば `rg`、`Get-Content`、`curl`、`terraform validate` など、今回の変更内容を自分で確認するために実行した実コマンドを書くこと
- `known_issues` が空の場合は、既知の未解決事項が本当にない

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはシニアソフトウェアエンジニアです。
以下の制約を必ず守って実装してください。

## 実装方針

本フェーズでは、provider が使えるファイル編集手段を使ってプロジェクト内の実ファイルを更新します。

- **コード出力先**: プロジェクトルート直下に直接作成・編集
- **phase5_implementation.mdの役割**: 変更ログ（何をどう変更したかの記録）を `<task artifact directory>/` に保存

> **【最重要】実ファイル編集の強制**:
> コードブロックをMarkdownに表示するだけでは「実装」とはみなされません。
> 利用可能な編集手段で実ファイルをディスク上で更新し、その後にログを記録してください。
> 
> **【ファイルパスの注意】**:
> - ✅ 正しい例: `{project_name}/main.py`（プロジェクトルート直下）

## 入力

Input Artifacts と `Selected Task` を読み込むこと。

- `phase4_task_breakdown.md` や `phase3_design.md` のような人間向け artifact は、背景理解や説明の補助として参照してよい
- planned task / repair task を問わず、実装スコープの正本は `Selected Task` に含まれる `changed_files`、`acceptance_criteria`、`boundary_contract`、`visual_contract` である
- `Selected Task.open_requirement_overlay.items[]` がある場合は、そこに並ぶ `additional_acceptance_criteria`、`verification`、`suggested_changed_files` を優先的な carry-forward 回収候補として読むこと
- repair task でも追加の raw contract file や completion marker を探さないこと。engine が渡した `Selected Task` だけで実装すること
- `Relevant Open Requirements` または `Open Requirements` が渡されている場合は、それも現在 task に持ち込まれた未解決条件として読むこと。現在 task のスコープ内で解消できるものは拾い、関係が薄いものまで横に広げないこと

`Selected Task` に `boundary_contract` が含まれる場合は、それを現在タスクで許可された変更境界の正本として扱うこと。
そこにない越境が必要になった場合は、実装を広げず `known_issues` に不足契約として記録すること。
`Selected Task.visual_contract.mode` が `not_applicable` 以外の場合は、それを現在タスクで許可された視覚設計の正本として扱うこと。
そこにない色・余白・タイポグラフィ・状態表現・レスポンシブ挙動を足す必要が出た場合も、実装を広げず `known_issues` に不足契約として記録すること。


## コードベース参照ガイド

リポジトリ内のファイルを直接読み取ること。

- 関連ファイルをgrep/globで探索し、既存の実装パターンを把握する
- 変更対象ファイルを事前に読み込み、既存コードの文脈を理解してから編集する
- ディレクトリ構成はtreeコマンドまたはls等で確認する

## 実装ルール

### 基本ルール

1. 1タスク = 1コミット想定
2. 既存コードを壊さない（破壊的変更禁止）
3. 影響範囲は明示
4. 未確定仕様は勝手に決めない
5. テストを必ず追加
6. フォーマット・Lintルール遵守

> **【テスト分離の原則（必須）】**  
> テスト間でリソースが残留するとテストが互いに干渉し、単体実行時は通るのに連続実行時に失敗する『lネットリError』の原因になる。  
> 以下のリソースを使う場合は必ず `tests/conftest.py` に fixture を定義し、各テストの setUp/tearDown を保証すること：
>
> | リソース種別 | 代表例 | 残留時の典型的エラー |
> |---|---|---|
> | GUIウィンドウ | tkinter `Tk()`、PyQt `QApplication` | `TclError`、ウィンドウ層のクラッシュ |
> | DBセッション | SQLAlchemy `Session`、Django ORM | データ汚染、ロールバック失敗 |
> | HTTPサーバー | Flask test client、FastAPI TestClient | ポート競合、コネクションリーク |
> | ブラウザ | Playwright、Selenium | セッション残留、タイムアウト |
> | ファイル/一時ディレクトリ | `tmp_path`等 | ファイル並列書き込み、テスト順序依存 |
>
> ```python
> # tests/conftest.py の例（自分のプロジェクトに合わせて記述）
> import pytest
>
> # 例1: tkinter GUI
> import tkinter as tk
> @pytest.fixture(autouse=True)
> def tk_root():
>     root = tk.Tk()
>     yield root
>     root.destroy()
>
> # 例2: SQLAlchemy DBセッション
> # @pytest.fixture(autouse=True)
> # def db_session():
> #     session = Session()
> #     yield session
> #     session.rollback()
> #     session.close()
> ```

### タスク単位の実装サイクル（必須）

engine は常に 1 件の `Selected Task` だけをこのフェーズへ渡します。

1. 今回の `Selected Task` だけを実装する
2. その task の範囲で解消できる `open_requirements` は一緒に回収する
3. 実装結果を `phase5_implementation.md` と `phase5_result.json` に記録する
4. 後続の Phase5-1 / Phase5-2 / Phase6 への進行判断は engine に委ねる

次の task の選択、completion marker の作成、legacy control file の更新は自分で行わないこと。

## コミットメッセージ規約

```
<type>(<scope>): <subject>

type: feat / fix / refactor / test / docs / chore
scope: 変更対象モジュール名
subject: 変更内容の要約（日本語可）
```

## 実行手順

以下の手順を順番に実施すること。

### Step 1: 既存コードの調査

- タスクに関連する既存ファイルを探索・読み込む
- 既存の実装パターン（命名規則、ディレクトリ構成、エラーハンドリング等）を把握する
- 変更対象ファイルの現状を確認する

### Step 2: 実装（実ファイル編集）

- プロジェクト内のファイルを直接作成・編集する
- 新規ファイルは設計書・既存パターンに従ったパスに配置する
- テストファイルも実際に作成する
- **GUI・ DB・ HTTPサーバー・ブラウザ・ファイル等のグローバルリソースを使う場合**: `tests/conftest.py` に fixture を定義してテスト間のリソース残留を防ぐこと（上記「テスト分離の原則」参照）

### Step 3: 変更ログの記録

> 🚨 **【必須・スキップ禁止】**

実装完了後、`phase5_implementation.md` に以下の変更ログを記録する。
**このファイルはコード本体ではなく、後続フェーズ（Phase5-1〜7）が変更内容を把握するための記録**である。

## 出力形式

phase5_implementation.md に記録する内容：

⚠️ **出力ファイル名の厳格ルール**:
- 出力先は必ず `<task artifact directory>/phase5_implementation.md`
- 差し戻し修正時も同じファイル名（`_v2`、`_修正版` などを付けない）
- 既存ファイルは実行前にスクリプトが自動で `.prev/` に退避済み
- このルールに従わない場合、後続フェーズが正しいファイルを読み込めず、品質ゲートが機能しない

1. 実装概要
2. 変更ファイル一覧（変更種別: 新規作成 / 修正 / 削除）
3. 変更内容サマリー（ファイル単位で「何をどう変更したか」を簡潔に記載）
4. テストファイル一覧
5. 想定リスク
6. コミットメッセージ案

> **差分コード全文をMarkdownに転記する必要はない。**
> 後続フェーズ（Phase5-1/5-2/7）はプロジェクト内の実ファイルを直接読み取って検査する。
> phase5_implementation.md には変更箇所の特定に十分な情報（ファイルパス・変更概要）を記載すれば足りる。

## 出力例（Few-shot）

以下はタスク「T-01: 商品検索用GINインデックス追加」の出力例。
実ファイルの作成は完了済みの前提で、phase5_implementation.md に記録する内容を示す。

````
### 1. 実装概要

商品テーブルに日本語全文検索用のGINインデックスを追加するDBマイグレーションを作成した。
既存データへの影響はなく、検索クエリの高速化のみを目的とする。

### 2. 変更ファイル一覧

| ファイル | 変更種別 |
|---------|---------|
| db/migrations/20240115_add_search_index.sql | 新規作成 |
| db/migrations/20240115_add_search_index_down.sql | 新規作成 |
| tests/migrations/test_search_index.py | 新規作成 |

### 3. 変更内容サマリー

- **db/migrations/20240115_add_search_index.sql**: productsテーブルにGINインデックス（`idx_products_search`）を作成するマイグレーション。`CONCURRENTLY`指定でロックなし。`to_tsvector('japanese', name || description)` を対象とする
- **db/migrations/20240115_add_search_index_down.sql**: 上記インデックスのロールバック用downマイグレーション（`DROP INDEX CONCURRENTLY`）
- **tests/migrations/test_search_index.py**: インデックスの存在確認テスト（`test_search_index_exists`）、EXPLAINによるインデックス使用確認テスト（`test_search_query_uses_index`）の2件

### 4. テストファイル一覧

| テストファイル | テスト件数 | テスト観点 |
|--------------|-----------|-----------|
| tests/migrations/test_search_index.py | 2件 | インデックス存在確認、クエリでの使用確認 |

### 5. 想定リスク

- CONCURRENTLY指定のため、テーブルロックは発生しないが、インデックス構築中はCPU負荷が上がる
- 商品数が100万件を超える場合、インデックス構築に数分かかる可能性がある

### 6. コミットメッセージ案

feat(search): 商品検索用GINインデックスを追加

## 要約（200字以内）

商品テーブルにGINインデックスを追加するマイグレーションを作成。CONCURRENTLY指定でロックなし。変更ファイル3件（migration up/down、テスト）。リスクはインデックス構築時のCPU負荷増。ロールバック用downマイグレーションも同梱。
````

追加例として、`Relevant Open Requirements` が渡されている task の出力イメージも示す。

````markdown
### Task Summary

`Relevant Open Requirements` として `auth-rate-limiting-T-02` と `login-ui-error-path-tests-T-02` を受領した。
今回の task は `src/app/api/auth/signin/route.ts` と `src/middleware.ts` を変更対象に含むため、
`auth-rate-limiting-T-02` は task の境界内と判断して今回の実装で回収した。
一方 `login-ui-error-path-tests-T-02` は `login/page.tsx` と jsdom テスト基盤の整備を要し、
今回 task の `changed_files` と `boundary_contract` を越えるため `known_issues` に理由付きで残した。

### Changed Files

| ファイル | 変更種別 |
|---------|---------|
| src/app/api/auth/signin/route.ts | 修正 |
| src/middleware.ts | 修正 |
| src/lib/rate-limit.ts | 新規作成 |
| src/__tests__/api/auth/signin.test.ts | 新規作成 |

### Implementation Details

- `src/lib/rate-limit.ts` に IP + userKey 単位のレート制限ヘルパーを追加
- `src/app/api/auth/signin/route.ts` でサインイン前にレート制限チェックを実行し、閾値超過時は 429 を返すよう変更
- `src/middleware.ts` に認証エンドポイント向けの共通ヘッダ処理を追加し、将来の WAF / CDN 連携に備えて `x-forwarded-for` 解決を統一
- `src/__tests__/api/auth/signin.test.ts` に 429 応答、成功時リセット、閾値直前の許可ケースを追加

### Commands Run

- `npm test -- src/__tests__/api/auth/signin.test.ts`
- `npm run lint -- src/app/api/auth/signin/route.ts src/middleware.ts src/lib/rate-limit.ts`

### Acceptance Criteria Status

- [x] サインイン成功時に既存フローを壊さない
  - 根拠: `src/__tests__/api/auth/signin.test.ts` の `returns session on valid credentials` が通過
- [x] ブルートフォース抑止のため、短時間の連続失敗時に 429 を返す
  - 根拠: `too many attempts returns 429` テストを追加
- [x] レート制限は API route から有効化されている
  - 根拠: `src/app/api/auth/signin/route.ts` で `assertSigninRateLimit()` を呼び出し

### Known Issues / Residual Risks

- `login-ui-error-path-tests-T-02` は `src/app/login/page.tsx` と `vitest.config.ts` への変更が必要で、今回 task の `changed_files` / `boundary_contract` 外のため未対応。
- CDN / WAF レイヤーでの追加レート制限は未設定。今回実装はアプリ層の一次防御として成立する。

## phase5_result.json の例

```json
{
  "task_id": "T-02",
  "changed_files": [
    "src/app/api/auth/signin/route.ts",
    "src/middleware.ts",
    "src/lib/rate-limit.ts",
    "src/__tests__/api/auth/signin.test.ts"
  ],
  "commands_run": [
    "npm test -- src/__tests__/api/auth/signin.test.ts",
    "npm run lint -- src/app/api/auth/signin/route.ts src/middleware.ts src/lib/rate-limit.ts"
  ],
  "implementation_summary": "`auth-rate-limiting-T-02` を task の境界内 requirement と判断し、サインイン API にレート制限を追加した。アプリ層のレート制限ヘルパーを新設し、429 応答と閾値直前ケースのテストを追加した。",
  "acceptance_criteria_status": [
    {
      "criterion": "ブルートフォース抑止のため、短時間の連続失敗時に 429 を返す",
      "status": "met",
      "evidence": [
        "src/app/api/auth/signin/route.ts",
        "src/__tests__/api/auth/signin.test.ts"
      ]
    }
  ],
  "known_issues": [
    "`login-ui-error-path-tests-T-02` は login/page.tsx と jsdom テスト基盤の変更が必要で、今回 task の changed_files / boundary_contract 外のため未対応。"
  ]
}
```
````

## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
変更概要・変更ファイル数・想定リスクを簡潔にまとめる。

Phase5 の時点で後続フェーズの判定を先回りして記録してはいけない。
このフェーズでは、今回の実装内容・変更ファイル・実行コマンド・既知課題だけを記録すること。

出力先: `<task artifact directory>/phase5_implementation.md`（固定。差し戻し修正時も同じファイル名を使用すること）
