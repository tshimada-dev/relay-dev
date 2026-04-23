# Phase3 設計テンプレート

このフェーズでは、要件と調査結果をもとに実装可能な設計を作る。

## 実行原則

- Input Artifacts を正本として、既存コードへの適合性も確認すること
- Required Outputs に書かれた `phase3_design.md` と `phase3_design.json` のみを作成すること
- 未確定事項は設計上の前提として明示し、暗黙の決め打ちはしないこと
- 次フェーズの遷移やレビュー判定は engine が扱う。設計書内で制御しないこと
- top-level `examples/**` 配下の sample artifact は current run の入力ではない。既存コード調査や設計根拠に使わないこと

## Markdown 出力に含める内容

- 設計の要約
- feature_list
- api_definitions
- entities
- constraints
- state_transitions
- reuse_decisions
- module_boundaries
- public_interfaces
- allowed_dependencies
- forbidden_dependencies
- side_effect_boundaries
- state_ownership
- visual_contract
- 設計上のリスクと保留事項

## JSON 出力

`phase3_design.json` には以下のキーを必ず含めること。

- `feature_list`
- `api_definitions`
- `entities`
- `constraints`
- `state_transitions`
- `reuse_decisions`
- `module_boundaries`
- `public_interfaces`
- `allowed_dependencies`
- `forbidden_dependencies`
- `side_effect_boundaries`
- `state_ownership`
- `visual_contract`

各フィールドは空にしないこと。配列またはオブジェクトのどちらでもよいが、後続のタスク分解で参照できる粒度まで具体化すること。
特に設計境界系のキーは、Phase4 で task contract に投影できるよう、対象モジュール名・責務・許可された依存・禁止依存・副作用の入口/出口・状態の所有者を追跡可能な粒度で書くこと。
`visual_contract` はオブジェクトで、少なくとも `mode`、`design_sources`、`visual_constraints`、`component_patterns`、`responsive_expectations`、`interaction_guidelines` を含めること。UI変更がない場合は `mode: not_applicable` とし、他の配列は空でよい。

## 品質基準

- 要件の acceptance criteria と設計内容が対応している
- 既存コードの再利用方針が `reuse_decisions` に明示されている
- API、状態遷移、データ構造のどれかが欠けていない
- カプセル化境界が `module_boundaries` / `public_interfaces` / `allowed_dependencies` / `forbidden_dependencies` / `side_effect_boundaries` / `state_ownership` に明示されている
- 後続の task contract が「どこまでは触ってよく、どこから先は越境か」を判定できる
- UI変更がある場合、`visual_contract` だけで主要な見た目・レスポンシブ・インタラクションの制約が追跡できる

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはシニアシステムアーキテクトです。
以下の確定要件をもとに、実装レベルまで構造化してください。

## 入力

以下のファイルを読み込んで前提情報とすること：
- `<run artifact directory>/phase1_requirements.md`（フル参照 — 目的・成功条件・制約条件・スコープ・リスク要因）
- `<run artifact directory>/phase2_info_gathering.md`（存在する場合のみ参照 — clarification fallback で確定した意思決定と残存 blocker）

> **【Phase2 の読み方】**
> Phase2 は通常フローではスキップされることがある。
> artifact が存在する場合は `decisions` を優先して設計へ反映し、`unresolved_blockers` が残っている場合は都合よく補完せず、制約・前提・リスクとして明示すること。


## 前提条件（前フェーズから自動取得）

- 開発環境：Phase0「技術スタック」「インフラ」から取得
- 想定ユーザー：Phase1「前提条件」から取得
- 制約条件（納期/コスト/技術制約）：Phase1「制約条件」から取得

## 既存コード資産の調査（設計前に必ず実施）

新規設計の前に、Phase0「再利用可能な既存資産」および既存コードベースを調査し、
再利用可能なモジュール・パターンを特定すること。

### 調査手順

1. Phase0の「再利用可能な既存資産」セクションを確認する
2. 要件に関連する既存コード（共通モジュール、ユーティリティ、類似機能）をリポジトリ内で探索する
3. 以下の判定基準で再利用 / 拡張 / 新規作成を決定する

### 再利用判定基準

| 判定 | 条件 | 対応 |
|------|------|------|
| そのまま再利用 | 既存モジュールが要件を満たす | 設計書に「既存利用: {パス}」と明記 |
| 拡張して利用 | 既存モジュールの改修で対応可能 | 設計書に「拡張: {パス} → 変更内容」と明記 |
| 新規作成 | 該当する既存資産なし | 通常どおり新規設計する |

### 出力セクション（成果物の先頭に配置）

```
### 0. 既存資産の再利用判定

| 機能/モジュール | 判定 | 既存パス | 対応内容 |
|----------------|------|----------|----------|
| （例: キャッシュ処理） | そのまま再利用 | src/services/cache.ts | 既存のRedisラッパーを使用 |
| （例: バリデーション） | 拡張して利用 | src/utils/validation.ts | 検索クエリ用バリデーションルールを追加 |
| （例: 検索API） | 新規作成 | — | 新規エンドポイントを設計 |
```

> **原則**: 既存資産で対応できるものを新規作成してはならない。
> 再利用判定で「新規作成」とした項目については、既存に類似機能がない根拠を明記すること。

## 成果物フォーマット指定

以下の構造で出力してください。

0. 既存資産の再利用判定（上記フォーマット）
1. 機能一覧（ユーザーストーリー形式）
2. 画面構成（UI単位）
3. API設計（エンドポイント、入力、出力）

   > **【制約整合性ルール】** API入力制限（`max_length`、範囲、必須/任意等）を定義した場合は、内部ロジック層（サービス・リポジトリ・パイプライン等）でも同じ制約を適用するか、または内部制約が同樹であることを設計書に明記すること。
   > 不一致がある場合（例: API層 `max_length=200` vs 生成ロジック `> 100` で拒否）は、どちらを正とするかを明記するか、共通定数として定義すること。

4. データ構造（テーブル or オブジェクト）
5. 非機能要件（性能、セキュリティ、運用）
6. 実装優先順位（MVP順）
7. 機能間依存関係（テキストベース表形式）
8. 主要処理フロー（ステップ形式）
9. エラーハンドリング設計
10. データ移行計画（既存データがある場合）
11. ロールバック戦略
12. 監視・アラート設計
13. **カプセル化境界設計**
14. **ビジュアル契約設計**
15. **状態遷移図**（エンティティがステータスフィールドを持つ場合は必須）

### 13. カプセル化境界設計（必須）

以下を current run の設計正本として必ず明示すること。

- `module_boundaries`: モジュール/レイヤごとの責務、公開面、内部実装を区別する
- `public_interfaces`: 後続 task が変更してよい公開 API / 型 / エントリポイント
- `allowed_dependencies`: 許可する依存方向と依存先
- `forbidden_dependencies`: 越境とみなす依存方向、直接参照禁止の対象
- `side_effect_boundaries`: DB / network / filesystem / env / clock / process などの副作用をどの境界に閉じ込めるか
- `state_ownership`: どの状態をどのモジュール/層が所有し、どこからは参照のみ許可するか

Phase4 で task contract に分解できるよう、抽象語だけで済ませず、対象パス・責務・依存先の種類・副作用の入口/出口・状態オーナーを追跡可能に書くこと。

### 14. ビジュアル契約設計（`DESIGN.md` 等の視覚入力がある場合は必須）

`visual_contract` を current run の視覚設計正本として明示すること。

- `mode`: `not_applicable` / `design_md` / `reference_only` / `custom`
- `design_sources`: `DESIGN.md`、既存画面、参照URLなどの出典
- `visual_constraints`: 色、タイポグラフィ、余白、密度、トーン、禁止事項
- `component_patterns`: ボタン、カード、フォーム、ナビゲーションなどの見た目・状態
- `responsive_expectations`: breakpoint ごとの詰め替え、 touch target、折り返しルール
- `interaction_guidelines`: hover/focus/loading/empty/error/success などの振る舞い

Phase4 で task-scoped の `visual_contract` に投影できるよう、フロントエンド実装が「どの UI をどこまで合わせるべきか」を判断できる粒度で書くこと。UI変更がない run では `mode: not_applicable` とし、その理由を簡潔に記すこと。

### 15. 状態遷移図

> **【必須条件】** データ構造に enum型のステータスフィールド（例: `status: DRAFT | PUBLISHED | ARCHIVED`）を持つエンティティがある場合は必ず包含すること。持たない場合は「N/A（状態フィールドなし）」と明記する。
>
> 記載内容：各状態の意味・遷移トリガー・双方向の遷移関係
> 記載形式：テキストベース表（Mermaid不可）:
> ```
> | 遷移元 | 遷移先 | トリガー | 小記 |
> |----------|----------|---------|------|
> | DRAFT    | PENDING  | 提出操作 | 管理者のみ可 |
> ```
>
> **定義した全ての状態は必ずどこかから遷移されること。**遷移トリガーなしに定義された状態（⇒実装の到達不可能）は Phase3-1のレビューで CRITICAL 指摘対象となる。

## 制約

- 曖昧な箇所は仮定せず「【未確定】」と明示
- 実装粒度まで落とす
- 冗長な説明は禁止

## 出力例（Few-shot）

> 詳細な出力例は `app/prompts/phases/examples/phase3_example.md` を参照。
> この few-shot は構成の参考専用であり、そこで使われているドメイン、API、SQL、監視設計、命名を current run に流用してはならない。
> 特に repo 直下の `examples/**/phase*.md` は sample artifact であり、今回の設計入力として参照してはならない。

### 悪い出力例（このように書かないこと）

```
❌ 「検索機能を改善する」→ ユーザーストーリー形式になっていない
❌ API設計でレスポンス型を省略 → 実装粒度に落ちていない
❌ 「適切なインデックスを追加する」→ 具体的なSQL/定義がない
❌ Phase2 の `decisions` にあるキャッシュ戦略を無視 → clarification fallback で確定した意思決定が未反映
❌ 依存関係や処理フローがMermaid記法のみ → LLMが解釈できない場合があるためテキストベース表形式を使用
❌ ステータスフィールドを持つエンティティがあるのに状態遷移図がない → デッドコード・到達不能状態の原因となる
❌ API層の入力制限と内部ロジック層の制約が不一致している → 共通定数化するか、どちらを正とするかを設計書に明記すること
```

## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
主要機能・アーキテクチャ構成・最重要な設計判断を簡潔にまとめる。
