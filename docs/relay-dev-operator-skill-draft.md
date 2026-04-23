# relay-dev operator skill 草案

## 目的

`relay-dev` を AI が安全に運用するための、オペレーション寄りの skill を定義する。
この skill は実装そのものを担当するものではなく、`relay-dev` の実行準備と進行確認を安定して行うためのガイドに寄せる。

## 想定する責務

この skill の責務は、ひとまず次の 4 つに絞る。

1. `tasks/task.md` の記入支援
2. Phase0 の記入または準備支援
3. 実行スクリプトの起動
4. 進捗確認

## 責務ごとのざっくり方針

### 1. `tasks/task.md` の記入支援

- ユーザーの依頼を `tasks/task.md` に落とし込む
- 目的、要求、制約、非目標を短く整理する
- 情報が足りない場合は、無理に補完せず不足事項を残す
- プロジェクト共通情報ではなく、「今回やること」を優先して書く

`tasks/task.md` の最低限の観点:

- 何をしたいか
- 何をしないか
- 制約は何か
- 完了とみなす条件は何か

### 2. Phase0 の記入または準備支援

- Phase0 を直接書くことも責務候補に入れる
- ただし基本動作は、`task.md` を整えて Phase0 を走らせ、生成物を確認する流れを優先する
- 直接編集が必要な場合も、事実・制約・open questions を分けて扱う

現時点の第一候補:

- 通常時: `task.md` を整える
- 次に: Phase0 を起動する
- その後: `phase0_context.md` / `phase0_context.json` を確認する

## 3. 実行スクリプトの起動

この skill は、`relay-dev` の開始・再開・単発実行の入口を迷わず選べるようにする。

主に扱うコマンド:

- `.\app\cli.ps1 new`
- `.\app\cli.ps1 resume`
- `.\app\cli.ps1 step`
- `.\start-agents.ps1`

期待する振る舞い:

- 既存 run があるかを確認してから `new` / `resume` を選ぶ
- 手元で 1 step ずつ見たい場合は `.\app\cli.ps1 step` を使う
- 常駐監視の運用では `start-agents.ps1` を使う
- どの起動方法でも、正本は `runs/<run-id>/run-state.json` であることを前提にする

## 4. 進捗確認

この skill は、進捗を見るときの「正しい参照先」を固定する。

優先順位:

1. `runs/current-run.json`
2. `runs/<run-id>/run-state.json`
3. `runs/<run-id>/events.jsonl`
4. `.\app\cli.ps1 show`
5. `queue/status.yaml` は互換表示として扱う

進捗確認で見たい項目の例:

- 現在の `run_id`
- 現在の phase
- 現在の role
- active job の有無
- pending approval の有無
- open requirements の有無

## この skill がやらないこと

- Phase1 以降の成果物を代理で作ることを主責務にしない
- engine の代わりに phase 遷移を決めない
- `queue/status.yaml` を正本として扱わない
- `outputs/` を唯一の正本として扱わない
- provider や phase prompt の内容そのものを毎回説明役として抱え込まない

## relay-dev 固有の重要ルール

- source of truth は `runs/<run-id>/run-state.json` と `events.jsonl`
- `queue/status.yaml` は互換投影であり、直接編集対象ではない
- Phase0 は後続フェーズの共通コンテキストなので、雑に埋めない
- 情報不足は無理に補わず、open questions として残す

## 将来の `SKILL.md` に入れたい中身

### 1. Trigger

- `relay-dev` の運用を頼まれたとき
- `task.md` を整えたいとき
- Phase0 を始めたいとき
- run の状態確認や再開をしたいとき

### 2. Core workflow

1. `tasks/task.md` を確認
2. 現在 run があるか確認
3. 必要に応じて `new` / `resume` / `step` / `start-agents.ps1` を選択
4. canonical state を読んで進捗確認
5. 必要なら Phase0 生成物を確認

### 3. Safe defaults

- 迷ったら `task.md` を先に整える
- 迷ったら `queue/status.yaml` ではなく `run-state.json` を見る
- 迷ったら phase を自分で進めず、既存の engine entrypoint を使う

### 4. 参考ファイル

- `README.md`
- `tasks/task.md.example`
- `app/cli.ps1`
- `runs/current-run.json`
- `runs/<run-id>/run-state.json`

## メモ

この skill は「relay-dev を使って開発する skill」ではなく、「relay-dev を回す operator skill」として切り出したほうが扱いやすい。
実装系の skill と分離しておくと、責務が膨らみにくい。
