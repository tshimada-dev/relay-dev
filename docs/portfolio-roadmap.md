# relay-dev ポートフォリオ化ロードマップ

## Summary

- 目的は、`relay-dev` 本体とそれで生まれた成果物を、GitHub 中心で評価されるポートフォリオに変えること。
- 主対象は日本の採用担当・面接官、次点で GitHub を読む技術者とする。
- 言語方針は固定する。agent-facing instruction は英語、few-shot / output examples / Markdown artifact の文体サンプルは日本語、JSON keys / schema fields / phase names / task IDs / paths / commands / code identifiers は英語または原文維持とする。README、事例、運用ガイド、ポートフォリオ説明は日本語中心。README 冒頭だけ短い英語要約を付ける。
- 公開方針は、`relay-dev` は公開、成果物は秘匿情報を落とした一部のみ公開とする。
- 完了条件は「5分で価値が伝わる」「技術的な裏付けを辿れる」「実運用の証拠がある」の3点とする。
- 初回公開の最低ラインは「1画面目で価値が伝わる」「強い flagship example 1本で裏付けられる」「最低限のハードニングと検証が通っている」とする。2本目の事例、動画、release 運用は初回公開後に追加してよい。
- 既存の `examples/gemini_video_plugin` はリファクタ前の旧成果物なので、ポートフォリオ証拠としては使わず削除して置換する。
- 新しい代表事例は、現行の `runs/<run-id>/artifacts/...` から作った post-refactor examples にする。

## Release Slicing

### Phase A: 公開最低ライン

- Stage 1 の主メッセージと非対象を固定する。
- Stage 2 の必須ハードニングだけを完了する。対象は `pwsh` 明文化、Phase0 seed 鮮度保証、canonical-first wrapper、最低限の safety 表現整理。
- Stage 3 は README 1画面目、用語統一、`LICENSE`、最小限の contribution / security guidance に絞る。
- Stage 4 は現行 run 由来の強い flagship example 1本に絞る。
- Stage 6 は quickstart smoke、validator、secret / absolute path scan の最低限を通す。

### Phase B: 見栄え強化

- README の `5分で見る relay-dev` 導線、examples index、静止画スクリーンショット、採用担当向け要約面を整える。
- `task -> seed -> phases -> approval -> artifacts -> final deliverable` の一枚図を README または Start Here doc に追加する。

### Phase C: 拡張

- 2本目の公開 example、dogfooding 事例、デモ動画 / GIF、release tag / release note 運用、継続運用ルールを追加する。
- portfolio site を作る場合も、この段階で GitHub 上の説明と assets を再利用する。

## Stage 1: 見せ方の軸を固定する

- ポートフォリオの主メッセージを1文で固定する。例: 「`task.md` / `DESIGN.md` を入力に、設計・実装・レビュー・検証 artifacts と approval 履歴を出力する、人間承認前提の AI 開発ランナー」。
- 評価軸を3つに固定する。`設計の深さ`、`運用の現実味`、`証拠付きの品質管理`。
- GitHub 上の読む順番を固定する。`README.md` -> デモ -> 代表事例 -> 技術詳細 docs。
- 強調しないものも固定する。過度な AGI 的表現、未検証の本番運用主張、秘匿前提の raw run ログは避ける。
- README 冒頭で非対象も明示する。汎用 AGI ではない、自律運転そのものを売りにしない、本番 SaaS ではない、人間承認を前提にした開発ランナーである、という線引きを置く。

## Stage 2: 公開前の実装ハードニング

- 既存の評価メモにある P1/P2 を先に潰す。特に `pwsh` 前提の明文化、Phase0 seed の鮮度保証、canonical-first と wrapper の整合を優先する。
- `pwsh` を正式サポート runtime に固定し、README、起動導線、CLI の失敗メッセージをそれに揃える。
- Windows PowerShell 5.1 は非対応として fail fast するか、少なくとも README の手動コマンドを `pwsh -NoLogo -NoProfile -File ...` に統一する。
- `tasks/task.md` と `outputs/phase0_context.*` の不整合を検知する fingerprint/metadata を導入し、古い seed を静かに再利用できないようにする。
- `phase0_context.json` には seed origin metadata として `task_fingerprint`、`task_path`、`seed_created_at` を持たせ、CLI の `SeedPhase0` import 前に現在の `tasks/task.md` と照合する。
- `start-agents.ps1` 系の挙動を `runs/current-run.json` / `run-state.json` 優先に寄せ、README と skill の説明と実装の物語を一致させる。
- stale な `queue/status.yaml` と valid な `runs/current-run.json` / `run-state.json` が食い違う場合に canonical state が優先される regression を追加する。
- safety については「runtime で強制しているもの」と「prompt/運用規律で守るもの」を分けて書き直す。
- クリーン clone から README の quickstart が通る smoke test を、この段階の gate として追加する。

## Stage 3: ドキュメントと用語を整理する

- `README.md` を採用向けの構成に再編する。冒頭で「何ができるか」「なぜ難しいか」「どんな証拠があるか」を先に見せる。
- README 冒頭に `5分で見る relay-dev` 導線を置く。リンク先は `デモ`、`代表事例`、`技術詳細` の3つに固定する。
- 深い設計書は今の `docs/` を活かしつつ、入口として短い `Start Here` 系ドキュメントを追加する。
- 人間向け用語を統一する。最低でも `run`、`seed`、`canonical state`、`approval`、`artifact` の説明をぶらさないようにする。
- ルートに実ファイルとして `LICENSE` を追加する。加えて `CONTRIBUTING.md`、`SECURITY.md`、`CHANGELOG.md` は初回公開では最小構成でよく、作り込みは Phase C に回してよい。
- 同じ読者向けの面で日英が混在している箇所は解消する。混在を残すのは固定技術用語だけにする。
- `app/prompts/phases/*` は agent-facing instruction を英語へ寄せる。ただし few-shot examples、Markdown artifact の見出し例、出力文体サンプルは日本語にする。
- `skills/*/SKILL.md` は運用手順書として扱い、frontmatter metadata は英語、本文は日本語を許容する。

## Stage 4: 公開事例を作り直す

- 既存の `examples/gemini_video_plugin` は削除し、README の旧リンクと説明も削除する。
- `examples/README.md` を新設し、「ここに置く examples は現行アーキテクチャで生成した公開用成果物のみ」と明記する。
- 最初の flagship example は、`DESIGN.md` 連携が伝わる別プロダクトの UI/GUI 機能にする。
- 初回公開の必須事例は強い flagship example 1本に絞る。2本目は Phase C とし、relay-dev 自身の dogfooding または実運用ベースの sanitized example にする。
- 題材例は dashboard、管理画面、ポートフォリオ用ケーススタディ画面など、`DESIGN.md` の効果が見えるものを選ぶ。
- 対象プロダクトには `DESIGN.md` を用意し、visual direction、layout、typography、color、responsive behavior、interaction を明文化する。
- relay-dev で実 run を実行し、`Phase0` から `Phase8` までの成果物を現行 canonical artifact store に出す。
- 公開用に `task.md`、`DESIGN.md`、run summary、主要 Markdown artifacts、主要 JSON artifacts、代表 task の Phase5/6/7 証拠、最終成果スクリーンショットを抽出する。
- 公開用 example には raw `runs/` をそのまま置かず、秘匿情報・ローカル絶対パス・不要ログを落とした sanitized 版だけを置く。
- 各 example に `example-manifest.json` を置き、`source_run_id`、`sanitized_at`、`included_artifacts`、`redaction_notes`、`validator_status` を記録する。
- sanitizer / scanner を用意し、絶対パス、API key、secret、顧客情報、raw provider logs、`runs/` 丸ごと混入を検出できるようにする。
- 各公開事例には「一度 NG/差し戻しが起きて、それを修正して品質を上げた痕跡」をできるだけ含める。
- 各公開事例には成果指標を明示する。候補は差し戻し回数、修正前後の差分、validator pass、quickstart 成功、生成物数、完走 phase、approval gate の履歴。
- relay-dev 自身の改善 run は、後続の Phase C dogfooding 補助事例として追加する。

## Stage 5: デモ面を作る

- 初回公開では動画をブロッカーにしない。まずは README 上の静止画、テキストスナップショット、一枚図で価値を伝える。
- 2〜5分の短いデモ動画か GIF は Phase C の見栄え強化として用意する。
- デモの流れは `要件整理` -> `run 状態確認` -> `approval gate` -> `artifact 出力` -> `完成した成果物` で固定する。
- README に静止画かテキストスナップショットを載せ、clone 前でも `show`、approval 待ち、artifact 構造が分かるようにする。
- README または Start Here doc に、`task -> seed -> phases -> approval -> artifacts -> final deliverable` の一枚図を置く。
- 採用担当向けの要約ページを1つ作る。場所は README 冒頭か別 Markdown で十分とする。
- 要約ページでは専門用語を減らし、「何が評価ポイントか」を先に書く。
- 将来ポートフォリオサイトを作る場合も、GitHub 上の説明と assets をそのまま再利用し、二重管理しない方針にする。

## Stage 6: 検証と信頼シグナルを作る

- 現在の CI と `tests/regression.ps1` は土台として維持し、公開後も常にグリーンを保つ。
- クリーン clone から README だけで辿れる quickstart smoke test を CI または手順化された検証として維持する。
- 新 example の JSON artifacts が現行 validator contract に沿っていることを確認する。
- README から旧 `gemini_video_plugin` への参照が残っていないことを `rg` で確認する。
- 公開 example に secrets、API key、顧客情報、環境依存パス、不要な raw provider logs が含まれないことを確認する。
- 公開 example の sanitize / validator / secret scan / absolute path scan を CI で確認する。
- 公開事例の再現確認手順を1本追加し、説明したコマンドと成果物がずれていないことを保証する。
- 5分レビューの模擬評価を行い、「何のプロジェクトか」「どこが難しいか」「何が証拠か」に第三者が答えられるか確認する。

## Stage 7: 継続運用に乗せる

- 今後の run は `非公開の実験用` と `公開候補` を分けて扱う。後から公開可否を迷わない運用にする。
- notable な run ごとに `非公開`、`sanitize して公開`、`そのまま公開` の3区分で判定するルールを作る。
- 低頻度でもよいので、portfolio-ready な節目で release tag と短い release note を出す。ただし初回公開のブロッカーにはしない。
- backlog に `portfolio impact` ラベルを作り、説明力・証拠・信頼性を上げる改善が埋もれないようにする。

## Acceptance / Test Scenarios

- GitHub の1画面目だけで、プロジェクトの目的・強み・証拠が伝わること。
- 2クリック以内で、代表事例1本と技術詳細1本に到達できること。
- `pwsh` サポート方針が明確で、README のコマンドと実装が一致していること。
- `tasks/task.md` を変えたのに古い Phase0 seed が使われるケースを拒否できること。
- stale な `queue/status.yaml` があっても、`runs/current-run.json` / `run-state.json` が正しく優先されること。
- 初回公開では、現行 run 由来の flagship example 1本があり、manifest、成果指標、主要 artifacts、スクリーンショットまたは最終成果物が揃っていること。
- Phase C 完了時点では、公開事例が最低2本あり、そのうち1本は実運用または dogfooding ベースであること。
- `DESIGN.md` が `visual_contract` や review に引き継がれたことを、代表事例から確認できること。
- 公開 example は manifest を持ち、sanitizer と validator が CI で green になること。
- `LICENSE` 実ファイル、最低限の contribution/security guidance、release note が揃っていること。
- 第三者が clone・README・CI・examples だけで「動く」「考えて設計されている」「実際に使われている」と判断できること。

## Assumptions / Defaults

- 主戦場は GitHub で、別サイトを作るとしても GitHub の説明を要約した派生面にする。
- 英語化の対象は agent-facing instruction と machine contract であり、人間向け説明や few-shot を全面英語化する計画にはしない。
- 既存の `examples/gemini_video_plugin` はリファクタ前の旧成果物なので、削除して現行 run 由来の examples に置換する。
- 既存の評価 docs は捨てず、公開前のハードニング根拠として活かす。
- 最初の代表事例は、relay-dev 自身の改造ではなく、`DESIGN.md` 連携が映える別プロダクト UI 機能にする。
- relay-dev 自身の改善 run は、後から `dogfooding` 事例として追加する。
- examples は「動いた証拠」として扱うため、現行 run から再生成したもの以外は portfolio の主証拠にしない。
- 公開に先立ち、既知の運用上の弱点を塞ぐことを優先し、見た目だけ整える順番にはしない。
