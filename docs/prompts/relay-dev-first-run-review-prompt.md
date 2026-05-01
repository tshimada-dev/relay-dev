# relay-dev 初運用完了後レビュー用プロンプト

初運用 run の完了後レビューに使うプロンプト。レビュー実施日、run-id、終端 state を必要に応じて更新して使う。

---

あなたは principal engineer 兼 delivery / process auditor です。
relay-dev 初運用 run の完了後レビューを実施してください。

今回のレビュー目的は 2 つです。

1. relay-dev が生成・更新した `kintai` 成果物の出来を評価すること
2. relay-dev システム自体の開発効率、手法、手順、レビュー運用が実務的にどこまで有効だったかを評価すること

# レビュー対象

- プロダクト本体: `C:\Projects\kintai`
- relay-dev システム: `C:\Projects\kintai\relay-dev`
- canonical run: `C:\Projects\kintai\relay-dev\runs\run-20260427-102252`
- convenience projection: `C:\Projects\kintai\relay-dev\outputs\Current-Task`
- scope boundary worklog: `C:\Projects\kintai\relay-dev\docs\worklog\2026-05-01.md`
- scope boundary entry: `## 10:31 JST - Phase5 promptにopen requirements回収方針を追加`

# レビュー時の前提

- 正本は必ず `runs/<run-id>/...` を優先し、`outputs/` や `queue/` は補助として扱うこと
- レビューは run が終端状態に達した後にのみ行うこと。`run-state.json` の最終状態をもとに評価し、進行中の中間レビューは行わないこと
- 完了済み task 数、終端 phase、終端 task、open requirements 件数などの現在地は、レビュー時点で固定文言を使わず final `run-state.json` から取り直すこと
- この run の実挙動評価では、`docs/worklog/2026-05-01.md` の `## 10:31 JST - Phase5 promptにopen requirements回収方針を追加` より後に入った追加改善は「今回の run に未反映」として扱うこと
- 特に `10:31 JST - Phase5 / Phase5-1にopen requirements付きfew-shotを追加`、`10:56 JST - task-scoped open requirement overlayをengine生成`、`11:04 JST - open requirements改善案をdocsへ追加`、`11:12 JST - Copilot native path regressionをcross-platform化` は、repo 上に存在していても今回の run の成果やプロセス改善としてはカウントしないこと
- したがって、「レビュー対象の relay-dev」は 2 層に分けて扱うこと: 1) この run が実際に使った仕組み 2) run 後または未反映の改善。両者を混同しないこと
- `open_requirements` は既知の持ち越し課題を含むため、「既知の保留課題」と「新たに見つかった欠陥」を分けて記述すること
- 欠陥を誇張しないこと。重大指摘は、実害・発生確率・証拠が揃っているものだけに限定すること
- 良い設計、良い運用判断、良いレビュー運用は明確に評価すること

# 必ず確認する証跡

- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\run-state.json`
- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\events.jsonl`
- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\artifacts\run\Phase*\*`
- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\artifacts\tasks\T-*\Phase*\*`
- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\jobs\*\job.json`
- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\jobs\*\stdout.log`
- `C:\Projects\kintai\relay-dev\runs\run-20260427-102252\jobs\*\stderr.log`
- `C:\Projects\kintai\relay-dev\app\prompts\system\*`
- `C:\Projects\kintai\relay-dev\app\prompts\phases\*`
- `C:\Projects\kintai\relay-dev\app\phases\*`
- `C:\Projects\kintai\relay-dev\tasks\task.md`
- `C:\Projects\kintai\relay-dev\docs\worklog\2026-05-01.md`
- `C:\Projects\kintai\DESIGN.md`
- `C:\Projects\kintai\package.json`
- `C:\Projects\kintai\vitest.config.ts`
- `C:\Projects\kintai\prisma\*`
- `C:\Projects\kintai\src\*`

必要なら次も参照してよいです。

- 作業前後差分の比較（git repo がある場合は `git diff` を利用）
- `npm test`
- `npm run build`
- `npm run lint`
- coverage 出力

# レビュー方針

- 抽象論ではなく、この run の実データと成果物に基づいて評価すること
- 「成果物の品質」と「relay-dev の運用プロセス」を混同しないこと
- 「今回の run で実際に反映された仕組み」と「review 時点の repo に存在するが今回未反映の改善」を混同しないこと
- 「設計の問題」「実装の問題」「レビューゲートの問題」「運用手順の問題」を分けて書くこと
- 「各エージェントに渡すコンテキスト設計の問題」は独立観点として扱い、必要な情報不足と情報重複の両面を見ること
- run 完了後でも、未到達 phase・未実施テスト・未反映改善に関する部分は推測で断定せず、未確定または別枠評価と明記すること
- source code や markdown への言及は、可能な限りファイルパスと行番号を示すこと
- `json` / `jsonl` / log について行番号が実用的でない場合は、ファイルパスと field 名または event 名を明示すること
- 改善提案は、次回 run の効率改善に効くものを優先すること
- 一般的な Agile / DevOps 論の焼き直しは禁止。必ず今回の run の証拠に結びつけること

# 特に見てほしい観点

## 1. 成果物レビュー

- `tasks/task.md` と `DESIGN.md` に対して、現時点の `kintai` 実装はどこまで要件を満たしているか
- 実装済み部分の完成度はどうか
- アーキテクチャや責務分離に破綻はないか
- テスト、検証、coverage、ビルド観点の信頼性は十分か
- open requirement として積み残している内容は妥当な持ち越しか、それともレビュー段階で止めるべきものか
- セキュリティ、入力バリデーション、整合性、保守性の観点で重大な見落としはないか

## 2. relay-dev のプロセスレビュー

- Phase 分割は有効だったか、それとも不要な往復や再作業を増やしていたか
- `Phase3-1` / `Phase4-1` / `Phase5-1` / `Phase5-2` / `Phase6` のレビューゲートは、品質向上に見合う価値を出していたか
- `Phase3-1` / `Phase4-1` / `Phase5-1` / `Phase5-2` / `Phase6` / `Phase7` それぞれのレビューが、レビュー対象・タイミング・判定基準・差し戻し基準の面で適切だったか
- 各レビュー phase が、実際に不具合検出・carry-forward 抽出・品質向上・無駄な差し戻し抑制のどれに効いていたか
- retry / failed transition / carry-forward requirement は、どこで発生し、何が根本原因だったか
- artifacts、events、jobs が「後から検証可能な証跡」として十分機能しているか
- 人間が介入すべきポイントは適切だったか
- 次回 run で短縮できそうな待ち時間、重複レビュー、再説明、やり直しがどこにあるか
- relay-dev の思想や手順は、初運用として現実的に回ったと言えるか
- `2026-05-01 10:31 JST` 以降に入った open requirements 改善群が今回 run に未反映だったことで、どの取りこぼしや非効率が残ったか
- implementer / reviewer / repairer に渡すコンテキストが適切だったか。必要情報の欠落、同一情報の二重注入、長すぎる prompt、artifact と prompt の責務重複がなかったか

## 3. 効率の定量評価

可能な範囲で、以下を数値または概算で整理してください。

- run 開始からレビュー時点までの経過時間
- 完了済み task 数 / 総 task 数
- failed または retry した phase / task の件数
- 同じ task での再実装・再レビュー回数
- open requirement 件数と、そのうち Phase7 持ち越しの件数
- 「品質向上に効いた再作業」と「無駄寄りの再作業」の区別
- scope boundary 以降に追加されたが今回 run では未反映だった改善項目数
- context 重複または context 不足が疑われる job / phase の件数または代表例
- review phase ごとの指摘件数、差し戻し件数、carry-forward 追加件数、実際に有効だった指摘の代表例

数値を正確に出せない場合は、無理に断定せず概算または未算出と明記すること。

# 出力フォーマット

## 1. エグゼクティブサマリー（5〜8行）

- この初運用は総合的に成功だったか
- 何が一番良く、何が一番ボトルネックだったか
- 現時点で「この方式を次回も使う価値があるか」を先に結論づける

## 2. 現在地のスナップショット

以下を簡潔に整理すること。

- レビュー日時
- run-id
- terminal status
- terminal phase / terminal task
- completed_at（取得できる場合）
- 完了済み task 数 / 総 task 数
- 未完了 task の扱い
- open requirements の概況
- 進捗率のざっくり評価

## 3. 評価スコープ境界

- `2026-05-01 10:31 JST - Phase5 promptにopen requirements回収方針を追加` を今回 run の評価境界として明記すること
- その後に repo へ追加された改善のうち、今回 run に未反映なものを列挙すること
- 「今回の run の欠点」と「run 後に既に手当て済みの改善余地」を分けて整理すること

## 4. 成果物レビュー

以下の 4 観点で評価し、重要な指摘から順に並べること。

- 要件適合性
- 実装品質
- テスト / 検証品質
- セキュリティ / 運用品質

各指摘には以下を含めること。

- 重要度: `Blocker` / `High` / `Medium` / `Low`
- 種別: `成果物` / `設計` / `実装` / `テスト` / `セキュリティ`
- 根拠
- それが「即時に止めるべき問題」か「既知の持ち越しで妥当」か

重大指摘が無い場合は、明確に「重大欠陥なし」と書くこと。

## 5. プロセス / 効率レビュー

以下を評価すること。

- phase 設計の妥当性
- reviewer gate の費用対効果
- 各 review phase の妥当性と有効性
- retry / rework の発生箇所と根本原因
- artifact と event log の監査性
- エージェント別コンテキスト設計の妥当性
- 人間の認知負荷の大きさ
- 次回 run で改善余地が大きい箇所

ここでは単なる感想ではなく、必ず run artifact / event / job evidence に紐づけること。

少なくとも以下の phase ごとに、`適切だった / 過剰だった / 不足だった` を判定すること。

- `Phase3-1`
- `Phase4-1`
- `Phase5-1`
- `Phase5-2`
- `Phase6`
- `Phase7`（未到達なら未到達と明記）

各 phase について、次の 4 点を短く整理すること。

- 何をレビューする phase だったか
- 実際にどんな指摘や効果があったか
- コストに見合っていたか
- 次回も同じ形で維持すべきか、軽量化・強化すべきか

## 6. うまく機能していた点

- relay-dev の仕組みとして良かった点
- 今回の `kintai` 開発に実際に効いていた点
- 「この運用を続ける理由」になる強み

## 7. 改善提案

優先度ごとに整理すること。

- `P0`: 継続運用や Phase7 判定の前に対処すべきもの
- `P1`: 次回 run の効率や品質を大きく改善するもの
- `P2`: 将来の洗練や可観測性向上に効くもの

各提案には「期待効果」を 1 行で添えること。

改善提案は次の 2 種類を分けること。

- 今回の run 自体から得られた改善提案
- すでに repo に入っているが今回 run では未反映だった改善の扱いに関する提案

## 8. 最終評価

以下を 1〜100 で採点すること。

- 成果物品質
- relay-dev の開発効率
- レビュー可能性 / トレーサビリティ
- 次回運用への再利用価値

最後に 3 行以内で総括すること。

# 重要

- 未完了部分を過剰にマイナス評価しないこと
- P0 は乱発しないこと
- 良い点と悪い点の両方を同じ熱量で書くこと
- 「relay-dev が存在したことで得られた利点」と「relay-dev を使ったことで増えたコスト」の両方を比較すること
- 改善提案は、次回の運用にそのまま反映できる具体性で書くこと
- review 時点の repo の最新状態を、そのまま今回 run の挙動として誤認しないこと

出力先は `C:\Projects\kintai\relay-dev\docs\evaluations\relay-dev-first-run-review-{レビュー実施日をYYYY-MM-DD形式で}.md`
