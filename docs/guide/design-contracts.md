# Design Contracts

relay-dev の品質維持の柱は、**設計判断と visual 判断を artifact schema として後段に伝搬させる**ことです。「カプセル化を守れ」「デザインを再現しろ」を口頭で繰り返すのではなく、JSON contract と reviewer gate で機械的に拘束します。

## 2 つの contract

| Contract | 抽出元 | 定義 phase | 拘束 phase | 検証 phase |
| --- | --- | --- | --- | --- |
| Boundary contract（設計境界） | Phase1 requirements | Phase3 で `module_boundaries` 系を定義し、Phase4 で task 単位に分割 | Phase5 implementation | Phase5-1 reviewer |
| Visual contract（見た目） | `DESIGN.md` / 画面参照 | Phase3 / Phase4 で UI task ごとに組み立て | Phase5 implementation | Phase5-1 reviewer（整合性チェック） |

## Boundary contract の流れ

### Phase3 — 設計境界の定義

Phase3 artifact (`phase3_design.json`) には以下を載せます。

- `module_boundaries`: モジュール / package の境界定義
- `public_interfaces`: 各モジュールが外に出す API 表面
- `allowed_dependencies`: 依存して **よい** 方向
- `forbidden_dependencies`: 依存しては **ならない** 方向
- `side_effect_boundaries`: I/O や外部システムを触ってよい場所
- `state_ownership`: 状態を保持する責務の所在

### Phase3-1 — 境界 review

Reviewer が固定観点で点検します。

- 境界が曖昧で複数解釈ができないか
- `forbidden_dependencies` が抜けていないか
- 既存コードと矛盾していないか
- 越境を誘発する設計（例: god object、循環依存）になっていないか

Phase3-1 / Phase4-1 の review verdict は `go` / `conditional_go` / `reject` が validator で強制されます。実装境界を直接見る Phase5-1 はより厳格で、`go` / `reject` のみを許可します。

### Phase4 — Task ごとの `boundary_contract`

Phase3 の全体境界から、task が触ってよい範囲だけを抜き出して **`boundary_contract`** を作ります。Phase4 artifact の各 task は次を持ちます。

- `boundary_contract.modules_in_scope`: 触ってよい module
- `boundary_contract.public_interfaces`: 変更してよい / 守る interface
- `boundary_contract.forbidden_dependencies`: この task では特に踏んではいけない依存
- `boundary_contract.acceptance_evidence`: 完了の証拠とする項目

これにより、複数 task の implementation が同じファイルを取り合っても、変更範囲が contract で機械的に区切られます。

### Phase5 — 実装

Phase5 implementer は、自分の task の `boundary_contract` を **拘束条件** として実装します。実装 artifact には次を構造化して残します。

- 変更ファイルと、それぞれが contract のどの module に属するか
- 追加 / 削除した依存関係
- テスト結果（最低でも実行コマンドと結果の引用）

### Phase5-1 — 越境検出

Phase5-1 reviewer は、artifact を読んで次を **証拠付き** で確認します。

- 変更ファイルが `modules_in_scope` の範囲に収まっているか
- 追加された依存が `forbidden_dependencies` を踏んでいないか
- `public_interfaces` の破壊的変更が宣言通りか

越境していれば `reject`。reviewer は推測ではなく、artifact 中の構造化エビデンスを根拠にします。

## Visual contract の流れ

### Phase0 — design_inputs / visual_constraints の抽出

`config/settings.yaml` の `paths.design_file`（既定 `paths.project_dir/DESIGN.md`）から、`Phase0` が次を抽出して `phase0_context.json` に積みます。

- `design_inputs`: 視覚的な手掛かり（layout、typography、color、spacing、interaction）
- `visual_constraints`: 守るべき制約（accessibility、responsive break point など）

### Phase1 — `visual_acceptance_criteria` 化

UI 案件では Phase1 が visual constraints を **acceptance criteria** に変換します。「○○ボタンの hover 状態は△△」「モバイル幅 360px で○○がはみ出ない」のような検証可能な形まで降ろします。

### Phase3 / Phase4 — `visual_contract` の組み立て

`app/core/visual-contract-schema.ps1` が定義する schema に従い、UI task ごとに `visual_contract` を持ちます。フィールド例:

- `layout`: 主要レイアウトの段組
- `typography`: フォント / サイズ / 行間
- `color_tokens`: 色トークン
- `spacing_scale`: spacing の刻み
- `responsive_behavior`: break point ごとの振る舞い
- `interaction_states`: hover / active / disabled
- `acceptance_evidence`: 完了の見え方

### Phase5 — `visual_contract` を守る実装

実装は `visual_contract` を満たすよう書かれ、artifact に screenshot や key style の引用を残します。

### Phase5-1 — 整合性チェック

Phase5-1 reviewer が `visual_contract` と実装成果を突き合わせます。「acceptance_evidence にあるはずの状態が再現されていない」「`color_tokens` 外の値が直書きされている」などを `reject` として検出します。

## 設計判断のメリット

- カプセル化と見た目を **artifact schema として後続に伝える** ため、prompt の言い回しに依存しない。
- reviewer は「気分」ではなく構造化エビデンスを根拠に gate する。
- task 並列実行時も `boundary_contract` が自然な衝突防止になる。
- DESIGN.md を変更すると次 run の Phase0 で seed が再構築され、後段に自動伝搬する。

## 関連ファイル

- `app/prompts/phases/phase3.md` / `phase4.md`: contract 定義の prompt
- `app/prompts/phases/phase3-1.md` / `phase4-1.md`: reviewer 観点
- `app/prompts/phases/phase5.md` / `phase5-1.md`: 実装と review
- `app/core/visual-contract-schema.ps1`: visual contract schema
- `app/core/artifact-validator.ps1`: contract field の存在 / 整合チェック
