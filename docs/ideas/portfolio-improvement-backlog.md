# Portfolio Improvement Backlog

`docs/ideas/portfolio-roadmap.md` の Phase A/B/C 計画と並走する、**転職用ポートフォリオとしての説得力を底上げするための backlog** を 1 ファイルにまとめる。本書は「やればポートフォリオの評価が上がる」改善を、優先度・所要規模・狙う印象で並べる。

評価の前提（外部レビュー所見の要約）:

- 設計判断の言語化、abstraction の選び方、worklog 運用、prompt → schema/gate への逃がし方は 2 年目水準を超えている。
- 一方、**「動いた証拠」「自分の関与の見え方」「テスト階層化」「リリース運用」「言語選択の説明」が弱い**。
- これらは技術力の問題ではなく **見せ方と運用** の問題なので、短いタスクで大きく印象が動く。

## Priority 1: 公開化のクリティカルパス

### P1-1. flagship example を 1 本仕上げる

- 場所: `examples/<flagship>/`
- 概要: relay-dev で実 UI 機能を Phase0 → Phase8 まで通し、`runs/<run-id>/artifacts/...` から sanitize して `examples/` に出す。題材は dashboard / 管理画面 / portfolio 用ケーススタディ画面など `DESIGN.md` の効果が見えるもの。
- 必須成果物:
  - `task.md`、`DESIGN.md`、run summary、主要 Markdown / JSON artifacts、Phase5 / 5-1 / 7 の証拠、最終成果のスクリーンショット
  - `example-manifest.json`（`source_run_id` / `sanitized_at` / `included_artifacts` / `redaction_notes` / `validator_status`）
  - 「一度 NG が出て修正した痕跡」を含める（差し戻しとリカバリ）
  - 成果指標（差し戻し回数、修正前後の差分、validator pass、生成物数、approval gate 履歴）
- gate: `scripts/check-public-examples.ps1` が green
- 印象: **「で、何作ったの？」に即答できる**。これが無い限り他の改善は半減する。
- 関連: `docs/ideas/portfolio-roadmap.md` Phase A Stage 4

### P1-2. 旧 `examples/gemini_video_plugin` の扱いを片付ける

- 選択肢:
  - 削除して README から参照を消す
  - `examples/legacy/` に移し、`README.md` で「リファクタ前の旧成果物。portfolio 証拠ではない」と明記
- 印象: **「これは何の証拠？」と読み手を迷わせない**。
- 規模: 30 分

### P1-3. 30 秒〜2 分のデモ GIF / 動画

- 場所: `docs/images/demo.gif`（or external link）
- 流れ: `要件整理 → run 状態確認 → approval gate → artifact 出力 → 完成した成果物`
- README ヒーロー直下に貼る。
- 印象: **静止画より圧倒的に「動いている」が伝わる**。
- 規模: 半日（収録 + トリミング）

## Priority 2: 信頼シグナル

### P2-1. GitHub Actions バッジを README に追加

- 例: `![CI](https://github.com/tshimada-dev/relay-dev/actions/workflows/<workflow>/badge.svg)`
- ついでに license バッジ、PowerShell version バッジも検討。
- 印象: **「常に green」が 1 行で伝わる**。
- 規模: 30 分

### P2-2. リリースタグと release notes の運用開始

- `v0.1.0` 相当の初回タグを切り、`CHANGELOG.md` の Unreleased を確定セクションに移す。
- GitHub Releases に短い release note（ハイライト + acknowledgments）。
- 印象: **「これは継続運用されているプロジェクト」**シグナル。
- 規模: 2〜3 時間

### P2-3. 「設計判断 5 選」を一人称で書く

- 場所案: `docs/decisions/` (ADR 形式) か README 内の「設計判断ハイライト」節
- 候補トピック:
  1. canonical state を `runs/<run-id>/run-state.json` に集約した理由（旧 baton モデルとの比較）
  2. `repairer` を専用 role にし、product code への変更を構造的に禁止した理由
  3. attempt-scoped staging を導入し、retry / repair の境界を physical に分けた理由
  4. `boundary_contract` を artifact schema に載せて越境検出の根拠にした理由
  5. `DESIGN.md` を `visual_contract` として後段に伝搬させた理由
- 文体: **「私はこの問題に対しこう判断した」一人称**で短く（各 200〜400 字）
- 印象: **作品紹介ではなく「判断の見本市」**として読ませる。AI 代筆疑念への対策にもなる。
- 規模: 半日

### P2-4. README に「なぜ PowerShell か」段落

- 30 秒で読める分量で、先回りして潰す:
  - Windows ローカル運用と `wt.exe` 上の visible worker 前提
  - tmux 互換でホスト OS を選ばない
  - Codex CLI / Copilot CLI との親和性（pwsh が前提環境になっている）
  - 単一実行系で `cli.ps1` を single writer に保つのに向く
- 印象: **「JavaScript / Python ではなぜダメか」を面接で聞かれる前に答える**。
- 規模: 30 分

## Priority 3: テスト戦略の階層化

### P3-1. `tests/regression.ps1` を分割

- 現状: 単一ファイル ~3,000 行 / ~160KB。
- 提案分割（例）:
  - `tests/unit/` 各 core モジュールの API レベルテスト
  - `tests/integration/` `phase-execution-transaction` 単位の合成テスト
  - `tests/e2e/` 既存の最小回帰相当
  - `tests/run-tests.ps1` で全体を呼び出す
- 中堅レビュアーが即指摘する点。**「壊れたとき切り分けやすい」シグナル**になる。
- 規模: 1〜2 日（規模が大きいので段階的に）
- 注意: 既存 assertion を消さず移すだけにする。

### P3-2. テストカバレッジ可視化（最小）

- PowerShell 用カバレッジは難しいが、`tests/` 各カテゴリの assertion 件数と対象モジュールを `tests/COVERAGE.md` に手動で書くだけでも印象が変わる。
- 規模: 半日

## Priority 4: 一人称の語りと自己評価

### P4-1. README ヒーローに「作者の問題提起」を 1 段落

- 「AI 開発ランナーで何を悩んでいて、relay-dev でどう解いたか」を 4〜6 行で。技術詳細ではなく動機。
- 規模: 30 分

### P4-2. `docs/evaluations/` に最新の self-evaluation を追記

- 直近の自己評価メモ (2026-04-30) は worklog ベース。次は **「ポートフォリオ視点で何が弱いか」** を自分で書く回を 1 本入れる。
- 印象: **自己評価できるエンジニアという最重要シグナル**。
- 規模: 半日

### P4-3. dogfooding 事例の記録

- relay-dev 自身の改善 run（attempt-scoped staging 導入、repairer 導入、UTF-8 fix など）から 1〜2 本を sanitized example に昇格。
- 印象: **「自分の道具で自分を改善した」物語**は強い。
- 規模: 1 日（既存 run の sanitize）
- 関連: `portfolio-roadmap.md` Phase C

## Priority 5: 読み手のフリクション削減

### P5-1. README に「30 秒で何ができるか」のスニペット

- ヒーロー直下に 1 ブロックだけ:
  ```powershell
  pwsh -NoLogo -NoProfile -File .\start-agents.ps1
  # → tasks/task.md と DESIGN.md から Phase0〜Phase8 の artifacts を生成
  ```
- 規模: 30 分

### P5-2. quickstart smoke test の存在を明示

- 既に `tests/regression.ps1` でクリーン clone から通るはずだが、README で「`pwsh tests/regression.ps1` 1 コマンドで動作確認できる」と明記する。
- 規模: 30 分

### P5-3. screenshot に注釈レイヤを追加

- 現在の `docs/images/screenshot01.png` / `02.png` は raw な terminal キャプチャ。**矢印 + 短いラベル**で「ここが approval gate」「ここが canonical state」を可視化。
- 印象: **5 秒で価値が伝わる**。
- 規模: 半日

## Priority 6: マーケット適合性

### P6-1. Linux / macOS で動作する公開デモ

- 現在の visible worker は `wt.exe` / tmux 両対応のはずだが、**「Mac で試せる」**と明示するだけで読み手の母数が増える。
- README の Quickstart に Linux / macOS 用コマンドを併記。
- 規模: 半日（実機検証含む）

### P6-2. provider 別の動作確認マトリクス

- `docs/providers-matrix.md` 程度で、Codex / Gemini / Copilot / Claude のうちどれで実 run まで通したかを表で残す。
- 印象: **「絵に描いた provider 抽象ではない」**シグナル。
- 規模: 半日

## やらない / 後回しでよいもの

- 自前 Web ダッシュボード化: GitHub 上の説明と assets を二重管理しない方針。`portfolio-roadmap.md` でも no-go。
- 多言語化（README の英語版）: 採用先が日本市場主体ならコスパ低。1 段落の英語要約だけで十分。
- npm / pip パッケージ化: PowerShell 単体スクリプト前提のため過剰投資。

## 実行順の目安

最短で「見せられる状態」にするなら次の順:

1. **P1-1 flagship example**（これが無い限り他は半減）
2. P1-2 旧 example の整理
3. P5-3 screenshot 注釈、P5-1 quickstart スニペット（半日で印象大）
4. P2-3 設計判断 5 選（半日、AI 代筆疑念への保険）
5. P2-1 CI バッジ、P2-2 v0.1 タグ
6. P1-3 デモ GIF
7. P2-4 「なぜ PowerShell か」、P4-1 作者の問題提起
8. P4-2 self-evaluation 更新
9. P3-1 テスト分割（規模大、ここまでで面接準備としては十分）
10. P4-3 dogfooding、P6-x マーケット適合

## SQL todos

backlog 項目は SQL の `todos` テーブルにも反映しておく。Markdown は人間向けの「作戦書」、SQL は実行用のキューとして使い分ける。
