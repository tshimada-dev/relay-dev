# Phase4 タスク分解テンプレート

このフェーズでは、設計を実装可能な task contract に分解する。

## 実行原則

- Input Artifacts と既存コード構成を見て、実装単位として自然な task に分けること
- Required Outputs に書かれた `phase4_task_breakdown.md` と `phase4_tasks.json` のみを作成すること
- タスク選択や完了管理は engine が行う。ここでは task contract の定義だけを行うこと

## Markdown 出力に含める内容

- タスク分解の方針
- 各 task の目的
- 変更対象ファイル
- acceptance criteria
- boundary_contract
- visual_contract
- dependencies
- tests
- complexity

## JSON 出力

`phase4_tasks.json` には `tasks` 配列を必ず含め、各要素は次のキーを持つこと。

- `task_id`
- `purpose`
- `changed_files`
- `acceptance_criteria`
- `boundary_contract`
- `visual_contract`
- `dependencies`
- `tests`
- `complexity`

`task_id` は安定した識別子にすること。`changed_files` と `acceptance_criteria` は空にしないこと。
`boundary_contract` は各 task が守るべき設計境界の task-scoped 正本であり、以下のキーを必ず持つこと。

- `module_boundaries`
- `public_interfaces`
- `allowed_dependencies`
- `forbidden_dependencies`
- `side_effect_boundaries`
- `state_ownership`

`visual_contract` は各 task が守るべき視覚設計の task-scoped 正本であり、以下のキーを必ず持つこと。

- `mode`
- `design_sources`
- `visual_constraints`
- `component_patterns`
- `responsive_expectations`
- `interaction_guidelines`

## 品質基準

- task_id が重複しない
- dependencies が既知の task_id のみを参照する
- dependency cycle を作らない
- 1 task が広すぎず、Phase5 で 1 回の実装単位として扱える
- 各 task の `boundary_contract` が Phase3 の設計境界を task 単位に投影している
- `boundary_contract` を見れば「この task にない越境」が判断できる
- 各 task の `visual_contract` が Phase3 の `visual_contract` を task 単位に投影している
- UI変更がある task で `visual_contract.mode` を `not_applicable` にしない

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはテックリード兼タスク分解AIです。
以下のPhase3設計書を元に、実装タスクを作成してください。

## 入力

以下のファイルを読み込むこと：
- `<run artifact directory>/phase3_design.md`（フル参照 — レビュー通過済み設計書）

特に以下のセクションを重点参照：
- Phase3の「機能間依存関係グラフ」「実装優先順位」

## 分解ルール

### 基本方針

**1タスク = 独立してデプロイ・検証できる最小機能単位**

これは「単体で動作確認でき、ユーザーや開発者が価値を確認できる最小の機能」を基準とする。
細かすぎる分割はオーバーヘッドを生むため、**レイヤーを縦串に貫く実装**を推奨する。

#### タスク分割の必須条件
- ✅ 単体でデプロイして動作確認できる
- ✅ 他機能への影響なくロールバック可能
- ✅ エンドツーエンドでテスト可能（DB → API → レスポンスまで）
- ✅ レビュー時に「動くものを見せられる」状態

### タスク分割の判定基準

**機能の完結性**を最優先とし、以下の観点で1タスクの範囲を決定する：

#### 機能完結性チェックリスト

- ✅ この機能だけで「何かが動く」状態になるか？
- ✅ 他の未実装機能がなくてもデプロイして確認できるか？
- ✅ ロールバックしても他機能に影響がないか？
- ✅ エンドツーエンドでテストできるか？(入力 → 処理 → 出力まで)

#### 複雑度の判定基準

| 複雑度 | 判定条件 | 例 |
|--------|----------|-----|
| **S** | 単一エンティティ / 外部依存なし / 既存パターンの再利用 | ユーザー登録API（フルスタック）、設定項目追加 |
| **M** | 2〜3エンティティ連携 / 外部API連携1箇所 / 条件分岐・エラー処理が複数 | 商品検索API + キャッシュ、メール通知機能 |
| **L** | 4エンティティ以上連携 / 複数システム連携 / 新規アーキテクチャ導入 / トランザクション制御複雑 | 決済フロー（決済代行+DB+通知）、リアルタイムチャット |

#### その他の制約

- **新規概念の導入**: 1タスクにつき1つまで（例: 新しいDB構造 **または** 新しい認証方式）
- **テスト範囲**: ユニットテスト + 統合テストを含む（機能が動作することをエンドツーエンドで検証）
- **レイヤー分割の禁止**: Repository層だけ、Controller層だけ、といった横分割はしない
- **依存関係**: 外部システムへの依存は明確に文書化し、モック化の方針を決める
- **変更の範囲**: 機能完結に必要なら複数ファイル・複数レイヤーにまたがってもOK

### 分割判断の具体例

#### ✅ 適切な粒度（1タスクでOK）

- **ユーザー登録API実装（フルスタック）**: マイグレーション + Repository + Service + Controller + バリデーション + テスト
- **商品検索機能（インデックス+API+キャッシュ）**: GINインデックス + 検索API + Redisキャッシュ層 + テスト
- **メール通知機能**: 通知テーブル作成 + 送信ロジック + キュー連携 + リトライ処理 + テスト

#### ❌ 粒度が大きすぎる（分割すべき）

- 「ユーザー管理機能」 → 登録 / 編集 / 削除 / 一覧を個別タスクに（各CRUD操作は独立した機能）
- 「決済フロー + ポイント管理 + クーポン適用」 → 各機能を別タスクに分離
- 「フロントエンド + バックエンド同時実装」 → 別タスクに分離（技術スタックが異なる）

#### ❌ 粒度が細かすぎる（統合すべき）

- 「DBマイグレーションのみ」「Repositoryのみ」「Controllerのみ」 → 1つの機能タスクに統合
- 「ユニットテストだけ別タスク」 → 実装タスクに含める
- 「設定ファイル更新だけ」 → 関連する機能実装に含める

### その他のルール

- 各タスクは **1〜2コミット**（実装コミット + テスト追加コミットの分離はOK）
- **並列実行可能なものは分離**（データベーススキーマ変更は直列化すること）
- **テスト作成は必ず含める**（ユニット + 統合テスト）
- **動作確認手順を明記**（「どうやって動いたことを確認するか」を書く）
- 設定・環境変数・マイグレーションも同一タスクに含める

### 並行実装可能タスク（複雑度S）の明示

**複雑度Sのタスク同士で依存関係がない場合**、Phase5で同時に実装できるよう明示すること：

```
並行実装可能（複雑度S）:
  Batch S1: T-02, T-04, T-08（依存関係なし、同時実装可）
  Batch S2: T-10, T-12（T-09完了後に実装可）
並行実装可能（複雑度M・条件付き）:
  Batch M1: T-05, T-07（依存関係なし、技術スタック異なる、2タスクまで）
```

**複雑度Sの条件**:
- すべて複雑度S（単一エンティティ、外部依存なし）
- 相互に依存関係がない
- 同じファイルを変更しない
- データベーススキーマ変更を含まない（スキーマ変更は必ず直列化）

**複雑度Mの条件（より厳格）**:
- すべて複雑度M（2〜3エンティティ連携、外部API連携1箇所程度）
- **最大2〜3タスクまで**（Sより少なく）
- 相互に依存関係が**完全に**ない
- 同じファイルを変更しない
- **異なる技術スタック・レイヤー**（例: フロントエンド機能 + バックエンド機能）
- データベーススキーマ変更を含まない
- **同じ外部サービスに依存しない**（例: 決済API + メールAPI は OK、決済API + 決済API は NG）
- テスト環境で独立して検証可能

**推奨しないケース（Mは直列化すべき）**:
- 同じドメインの機能（例: 注文作成 + 注文キャンセル）
- 同じエンティティに影響（例: User更新 + User削除）
- 複雑なビジネスロジックが絡む
- トランザクション境界が不明確

**効果**: Phase5の実行時に複数タスクをまとめて実装でき、開発効率が向上する

## タスクに必須の項目

- タスクID
- 目的（エンドユーザーまたは開発者が得られる価値を明記）
- 変更対象ファイル（新規作成・修正を明示）
  - **重要**: ファイルパスはプロジェクトルート直下からの相対パスで記載すること
- 実装内容（レイヤーごとの詳細を記載）
- boundary contract
  - この task が触ってよいモジュール境界
  - この task が変更してよい公開インターフェース
  - 許可される依存 / 禁止される依存
  - 副作用を置いてよい境界
  - 状態の所有者と参照のみ許可される境界
- visual contract
  - この task が従う `DESIGN.md` / 参照元
  - 色・タイポグラフィ・余白・コンポーネント状態の制約
  - responsive と interaction の期待値
  - UI変更がない task では `mode: not_applicable`
- 受け入れ条件（Acceptance Criteria — 検証可能な条件）
  - **必須**: 正常系の条件に加え、**エラーシナリオ**（不正入力・不存在リソース・権限不足等）の期待挙動を少なくとも1件含めること。
  - 変更ファイルに**フロントエンドコード（.ts/.tsx/.js/.jsx）**が含まれる場合、以下を含めること:
    - 401/403/503 レスポンス時のUIの挙動（エラー表示・リダイレクト・トークンリフレッシュ等）
    - fetchラッパー・リトライ処理がある場合、無限ループ・無限再帰が発生しないこと
- 動作確認手順（「どうやって動いたことを確認するか」）
- 依存関係（先行タスクID）
- テスト内容（ユニット + 統合テストの範囲）
- 複雑度（S / M / L）と根拠

## 出力形式

```
Phase4 Task List:

[T-01]
目的: （ユーザー/開発者が得られる価値）
変更対象ファイル:
  - path/to/file1.py（新規作成）
  - path/to/file2.py（修正: 〇〇を追加）
boundary_contract:
  module_boundaries:
    - application/search
  public_interfaces:
    - GET /api/search
  allowed_dependencies:
    - application/search -> domain/search
  forbidden_dependencies:
    - application/search -> infra/db direct
  side_effect_boundaries:
    - DB access must stay behind SearchRepository
  state_ownership:
    - SearchQuery state is owned by application/search
visual_contract:
  mode: design_md
  design_sources:
    - DESIGN.md
  visual_constraints:
    - Keep the existing monochrome canvas and Geist-like density
  component_patterns:
    - Search results use compact cards with subdued separators
  responsive_expectations:
    - On narrow screens filters collapse above results
  interaction_guidelines:
    - Loading and empty states must match the documented product tone
実装内容:
  [DB層] ...
  [Repository層] ...
  [Service層] ...
  [API層] ...
受け入れ条件:
  - 〇〇を実行すると△△が返る
  - エラーケース××で400エラーが返る
  - **（フロントエンドを含む場合）** 401レスポンス時は〇〇画面へリダイレクトされる
  - **（fetchラッパーがある場合）** トークン失効→再取得後に再度401が来ても無限ループしない
動作確認手順:
  1. マイグレーション実行
  2. curl -X POST ... で動作確認
  3. レスポンスが期待通りか確認
依存関係: なし
テスト内容: ユニットテスト（Repository/Service）+ 統合テスト（API E2E）
複雑度: S（理由: 単一エンティティ、外部依存なし）

[T-02]
...

---
クリティカルパス: T-01 → T-03 → T-05 → ...
並列実行可能グループ:
  Group A: T-02, T-04
  Group B: T-06, T-07
並行実装可能（複雑度S）:
  Batch S1: T-02, T-04, T-08（依存関係なし、同時実装可）
```

## 出力例（Few-shot）

以下は「商品検索レスポンス改善」の設計書に対するタスク分解の出力例（抜粋）。

```
Phase4 Task List:

[T-01]
目的: 商品検索用GINインデックスを追加し、全文検索の基盤を構築する
変更対象ファイル:
  - db/migrations/20240115_add_search_index.sql（新規）
  - db/migrations/20240115_add_search_index_down.sql（新規）
  - tests/migrations/test_search_index.py（新規）
実装内容:
  - PostgreSQLのGINインデックスをproductsテーブルに追加するマイグレーション作成
  - name + description を対象とした日本語全文検索用インデックス
  - CONCURRENTLY指定でロックなし
受け入れ条件:
  - マイグレーション実行後、pg_indexesにidx_products_searchが存在する
  - EXPLAINで検索クエリがインデックスを使用することを確認できる
  - ロールバック用downマイグレーションが動作する
依存関係: なし
テスト内容: インデックス存在確認、EXPLAIN結果の検証
複雑度: S（理由: 単一のDDL文、ビジネスロジックなし）

[T-02]
目的: 検索APIエンドポイントを実装し、GINインデックスを活用した全文検索を提供する
変更対象ファイル:
  - src/api/products/search.py（新規）
  - src/api/products/__init__.py（修正: ルーティング追加）
  - tests/api/products/test_search.py（新規）
実装内容:
  - GET /api/products/search エンドポイント実装
  - クエリパラメータ: q(必須), page(任意), per_page(任意)
  - to_tsvector + to_tsqueryによる全文検索
  - ページネーション対応
受け入れ条件:
  - GET /api/products/search?q=テスト でJSON応答が返る
  - page, per_pageパラメータが正しく動作する
  - 不正なパラメータに対して400エラーを返す
依存関係: T-01
テスト内容: 正常系検索、ページネーション、バリデーションエラー、検索結果0件
複雑度: M（理由: API層・DB層の結合、バリデーション実装あり）

[T-03]
目的: 検索結果のRedisキャッシュ層を導入し、レスポンスタイムを短縮する
変更対象ファイル:
  - src/cache/search_cache.py（新規）
  - src/api/products/search.py（修正: キャッシュ組み込み）
  - tests/cache/test_search_cache.py（新規）
実装内容:
  - Redisベースのキャッシュモジュール作成（TTL 5分）
  - キャッシュキー: search:{hash(正規化済みq)}:{page}:{per_page}
  - キャッシュヒット時はDB問い合わせをスキップ
受け入れ条件:
  - 同一クエリの2回目以降でRedisからキャッシュが返る
  - TTL経過後にキャッシュが無効化される
  - Redis障害時はキャッシュをスキップしてDB直接問い合わせにフォールバック
依存関係: T-02
テスト内容: キャッシュヒット/ミス、TTL期限切れ、Redis障害時フォールバック
複雑度: M（理由: Redis連携、フォールバック処理あり）

---
クリティカルパス: T-01 → T-02 → T-03
並列実行可能グループ:
  なし（3タスクすべてが直列依存）
```

### 悪い出力例（このように書かないこと）

```
❌ [T-01] 目的: 検索機能を実装する → 複雑度が高いのに機能をまとめすぎ（インデックス/API/キャッシュは分割すべき）
❌ 変更対象ファイル: 未定 → 事前に特定すること
❌ 変更対象ファイル: 15ファイル → ファイル数が多すぎ、関連性の低いファイルを含んでいる可能性
❌ 受け入れ条件: 正しく動作すること → 検証可能な条件になっていない
❌ 受け入れ条件: 正常系のみ（エラーケース・エラー時のUI挙動が含まれていない） → 異常系を最低1件含めること
❌ 依存関係の記載なし → 実行順序が不明になる
❌ 複雑度の根拠なし → S/M/Lの判断基準が不透明
❌ 複数の新規概念を1タスクに詰め込む → 新規アーキテクチャ+新規API+新規DB構造など
❌ フロントエンドコードを変更するのに401/503時のUI挙動が受け入れ条件にない → 変更ファイルにTS/JSが含まれる場合は必須
```

## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
総タスク数・クリティカルパス・最大リスクのタスクを簡潔にまとめる。

出力は `<run artifact directory>/phase4_task_breakdown.md` に保存すること。
