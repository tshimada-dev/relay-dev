# Phase0 コンテキスト

## プロジェクト概要

relay-dev は、`tasks/task.md` と optional な `DESIGN.md` を入力に、Phase0 から Phase8 までの reviewable artifact を生成する PowerShell ベースの AI 開発 runner である。今回の run は、task lane 並列化の実地確認を目的に、`examples/parallel_smoke_system/` 配下へ小さな browser-only 業務システムを作る。

## 今回の依頼

- `examples/parallel_smoke_system/` に、設備や備品の修理依頼を登録・確認できる「メンテナンス受付ボード」を作る。
- HTML / CSS / vanilla JavaScript / PowerShell のみを使い、外部 package manager、server、database は使わない。
- `index.html`、`src/storage.js`、`src/app.js`、`styles.css`、`tests/verify-static.ps1`、`README.md` を中心に新規作成する。
- Phase4 では、`storage.js`、`styles.css`、`verify-static.ps1` など同一ファイルを共有しない独立 task を明示し、並列実装できる範囲を見えるようにする。
- 並列実行可能な task には `parallel_safety: parallel` と重複しない `resource_locks[]` を付ける。

## ルートと主要構成

- project_root: `C:/Projects/testrun/relay-dev`
- framework_root: `C:/Projects/testrun/relay-dev`
- task file: `tasks/task.md`
- 実行設定: `config/settings.yaml`
- example target: `examples/parallel_smoke_system/`
- canonical run state: `runs/<run-id>/run-state.json`
- event log: `runs/<run-id>/events.jsonl`
- provider job IO: `runs/<run-id>/jobs/<job-id>/`

## 技術スタックと利用可能ツール

- PowerShell 7 (`pwsh`)
- Codex CLI (`codex`)
- Git
- relay-dev control plane (`app/cli.ps1`)
- parallel-step (`app/cli.ps1 parallel-step`)
- regression harness (`tests/regression.ps1`)
- static verification script (`examples/parallel_smoke_system/tests/verify-static.ps1`)

## 制約

- 既存 relay-dev 本体 (`app/`, `config/`, `tests/regression.ps1`, `docs/guide/`) は実装対象に含めない。
- 変更対象は原則として `examples/parallel_smoke_system/` 配下に限定する。
- オフラインで `index.html` を直接開いて動く browser-only system にする。
- 同じファイルを複数 task で編集しない。
- localStorage のキー名は `parallelSmokeMaintenanceRequests` とする。
- UI はこの task 内の要件に従い、業務ツールらしい読みやすさ、状態表示、モバイル対応を重視する。

## リスク

- 小さいシステムでも、`index.html` と `app.js` の結合点を曖昧にすると Phase5 で手戻りになりやすい。
- 同じファイルを複数 task へ割り当てると並列化 smoke test としての観察価値が下がる。
- 静的検証は軽量なので、実際のブラウザ操作確認は別途人間が行う可能性がある。

## 未確定事項

- タスク要件としての未確定事項はない。実行時の観察項目として、run-state / events / jobs に複数 task lane の lease、job、commit がどう記録されるかを確認する。

## デザイン入力

`DESIGN.md` は使用しない。UI は `tasks/task.md` の制約に従い、静かな業務ツール調、明確な状態ラベル、モバイルでも崩れないレイアウトを目指す。



