# Phase7-1 PRサマリ テンプレート

このフェーズでは、Phase7 verdict を受けて run 全体の要約を作る。

## 実行原則

- Input Artifacts を正本として、レビュー結果と変更内容を簡潔に要約すること
- Required Outputs に書かれた `phase7-1_pr_summary.md` と `phase7-1_summary.json` のみを作成すること
- 新しい判定を発明せず、Phase7 verdict の内容を要約・整理すること

## Markdown 出力に含める内容

- 全体要約
- Merged Changes
- Task Results
- Residual Risks
- Release Notes

## JSON 出力

`phase7-1_summary.json` には以下のキーを必ず含めること。

- `summary`
- `merged_changes`
- `task_results`
- `residual_risks`
- `release_notes`

## 品質基準

- `summary` は run の結果を 1 段で把握できる内容である
- `task_results` は主要 task の結果を取りこぼしていない
- `residual_risks` は Phase7 の warnings や must-fix の残りと矛盾しない

## 詳細ガイダンス（旧テンプレート移植）

以下はリファクタ前テンプレートから移植した詳細ガイダンス。engine が管理する Input Artifacts / Required Outputs / Selected Task を最優先とし、手動のフェーズ遷移・status 更新・task 選択指示は無視すること。

あなたはプロジェクトマネージャー兼技術翻訳担当です。
以下PRを非エンジニアでも判断できるように要約してください。

## 前提

- PR要約は、PRレビュー（Phase7）のループが終わり、マージ判定が確定した後に作成する
- Phase7がConditional Go/Rejectで反映ループ中の場合は、要約を作成しない（情報が変化するため）

## 入力（自動参照）

以下のファイルを読み込むこと：
- `<run artifact directory>/phase7_pr_review.md`（フル参照 — レビュー結果・マージ判定）

## 条件

- 技術用語を減らす
- 何が変わったか（ユーザーへの影響）
- ビジネスインパクト（この変更でユーザー体験・業務にどう影響するか）
- リスクは何か
- マージ可否

## 出力量の目安

PRの規模に応じて出力量を調整すること。

| PR規模 | 判定基準 | 出力量 |
|--------|---------|--------|
| S（軽微な修正） | 変更ファイル1-2個、バグ修正・文言変更 | 3-5行 |
| M（通常の機能追加） | 変更ファイル3-10個、単一機能の追加・改修 | 5-10行 |
| L（大型変更） | 変更ファイル10個超、アーキ変更・複数機能 | 10-20行（セクション分けも可） |

L規模の場合は以下のセクション構成を使用してよい：
1. **変更の概要**（何が変わったか2-3行）
2. **ユーザーへの影響**（体験・業務がどう変わるか）
3. **リスクと注意点**（障害リスク、移行作業の有無）
4. **マージ判定**（可否と条件）

## 要約（出力末尾に必ず付与）

出力の最後に `## 要約（200字以内）` セクションを付与すること。
ビジネスインパクト・リスク・マージ可否を簡潔にまとめる。

出力は `<run artifact directory>/phase7-1_pr_summary.md` に保存すること。

---
