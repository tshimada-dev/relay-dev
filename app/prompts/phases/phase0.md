# Phase0 コンテキストセットアップ

`tasks/task.md` を、今回ユーザーが実現したいことの一次情報として読むこと。

このフェーズでは、後続の全フェーズで再利用するための `phase0_context.md` と `phase0_context.json` を作成する。
安定した事実、制約、利用可能なツール、主要なリスク、未確定事項を整理すること。
外部 input artifact として `DESIGN.md` が存在する場合は、後続の設計・実装で再利用できる視覚設計情報もここに固定すること。

## 言語ルール

- `phase0_context.md` は人間向けドキュメントとして日本語で記述すること
- 見出し、要約、箇条書き、補足説明も日本語を優先すること
- `phase0_context.json` のキー名は契約どおり固定し、パス・識別子・コード片は必要に応じて原文のまま保持してよい

## JSON 必須キー

`phase0_context.json` には以下のキーを必ず含めること。

- `project_summary`
- `project_root`
- `framework_root`
- `constraints`
- `available_tools`
- `risks`
- `open_questions`
- `design_inputs`
- `visual_constraints`

`constraints`、`available_tools`、`risks`、`open_questions`、`design_inputs`、`visual_constraints` は配列で表現すること。
`project_root` と `framework_root` は、prompt context から判明している場合は絶対パスで保持すること。
`design_inputs` と `visual_constraints` は、`DESIGN.md` や明示されたデザイン参照がない場合は空配列でよい。

## 実行ルール

- Phase0 を飛ばして要件定義や設計に進まないこと
- `tasks/task.md` が不完全でも、勝手に補完せず未確定事項は `open_questions` に明示すること
- 以降のフェーズで参照しやすいよう、安定情報と今回タスク固有の情報を混同しないこと
- `DESIGN.md` がある場合は、色・タイポグラフィ・コンポーネント傾向・レスポンシブ指針などの安定した視覚ルールだけを抽出し、ページ固有コピーや一時的なキャンペーン文言は固定しないこと
