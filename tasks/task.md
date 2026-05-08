# Current Task

## 概要

relay-dev の task lane 並列化を実環境で確認するため、`examples/parallel_smoke_system/` に小さな browser-only の「メンテナンス受付ボード」を作る。設備や備品の修理依頼を登録し、状態別に確認できる簡易業務システムとして完成させる。

狙いは「簡単だがシステムらしいもの」を作らせること。Phase4 では、データモデル / UI 挙動 / 見た目 / 検証スクリプトをできるだけ別ファイルの独立タスクに分け、同時実装しやすい task contract を作ること。

## 要件

- `examples/parallel_smoke_system/index.html` を作り、メンテナンス依頼一覧、状態別サマリ、登録フォーム、フィルタ操作の入口がある画面を表示できる。
- `examples/parallel_smoke_system/src/storage.js` を作り、依頼データの初期値、localStorage 永続化、追加、状態更新、フィルタ用の取得処理を提供できる。
- `examples/parallel_smoke_system/src/app.js` を作り、画面描画、フォーム送信、状態変更、状態 / 優先度フィルタ、空状態表示を実装できる。
- `examples/parallel_smoke_system/styles.css` を作り、業務ツールとして読みやすい密度、明確な状態表示、モバイルでも崩れないレイアウトにできる。
- `examples/parallel_smoke_system/tests/verify-static.ps1` を作り、HTML が必要な JS/CSS を参照していること、主要 UI ラベルと storage API 名が存在することを静的に検証できる。
- `examples/parallel_smoke_system/README.md` を作り、ローカルでの開き方、データ保存の挙動、検証コマンドを短く説明できる。
- Phase4 では、少なくとも3件以上の task に分割し、同時実装可能な task と依存する task を明示する。特に `storage.js`、`styles.css`、`verify-static.ps1` は同一ファイルを共有しない独立タスク候補として扱う。
- 並列実行の確認に使うため、並列化可能な task には `parallel_safety: parallel` と重複しない `resource_locks[]` を付ける。
- run 全体の最終確認では、`pwsh -NoLogo -NoProfile -File examples/parallel_smoke_system/tests/verify-static.ps1` と `pwsh -NoLogo -NoProfile -File tests/regression.ps1` が成功することを確認する。

## 制約条件

- 既存の relay-dev 本体 (`app/`, `config/`, `tests/regression.ps1`, `docs/guide/`) は変更しない。
- 変更対象は原則として `examples/parallel_smoke_system/` 配下の新規ファイルに限定する。
- 外部 package manager、bundler、server、database は使わない。HTML / CSS / vanilla JavaScript / PowerShell のみで作る。
- 画像や外部 CDN は使わない。オフラインで `index.html` を直接開いて動くようにする。
- 同じファイルを複数タスクで編集しない。共有ファイルが必要な場合は、依存関係を明示して直列化する。
- localStorage のキー名は `parallelSmokeMaintenanceRequests` とする。
- デザインは既存 `DESIGN.md` ではなく、この task 内の UI 要件に従う。
- human review の有効/無効は現在の `config/settings.yaml` に従い、この task の実装では変更しない。

## 検証

- Phase4 artifact で、ミニシステム実装が3件以上の task に分かれ、同時実装可能な task と依存関係が説明されている。
- Phase5 以降の run-state / events / jobs で、並列化実装がある場合は複数 task lane の lease / job / commit が観察できる。
- `examples/parallel_smoke_system/index.html` をブラウザで直接開くと、初期データの依頼カード、状態別サマリ、登録フォーム、フィルタ UI が表示される。
- 新しい依頼を追加すると一覧とサマリが更新され、リロード後も localStorage から復元される。
- `pwsh -NoLogo -NoProfile -File examples/parallel_smoke_system/tests/verify-static.ps1` が成功する。
- `pwsh -NoLogo -NoProfile -File tests/regression.ps1` が成功する。



