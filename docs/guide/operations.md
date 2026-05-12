# Operations

relay-dev を実運用するときの起動・確認・停止・再開・監視・トラブルシュートをまとめます。前提として、運用上の **正本は常に `runs/<run-id>/...`** であり、`queue/status.yaml` や `outputs/` は確認用の投影に過ぎません。

## 必須要件

- PowerShell 7 (`pwsh`) — Windows PowerShell 5.1 は非対応
- AI provider CLI（[providers.md](./providers.md) 参照）
- Windows: `wt.exe`（Windows Terminal）
- Linux / macOS: `tmux`

## CLI 入口

`app/cli.ps1` がすべての state 変更の **single writer** です。

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 new      # 新しい run を作成
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 resume   # 既存 run を再開
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 step     # 1 step 進める
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 show     # 現在の run-state を表示（read-only）
```

| コマンド | 主な責務 |
| --- | --- |
| `new` | run-id 採番、`run-state.json` 初期化、`runs/current-run.json` 更新 |
| `resume` | `runs/current-run.json` の run を選び、stale `active_job_id` を整合化し、safe な `failed` state は `retry_same_phase` に戻す |
| `step` | 次 action を `WorkflowEngine` に問い合わせ、1 phase 進める |
| `group-step` | task-scoped parallel lane で task group を明示実行し、worker 完了後に merge / artifact commit まで進める |
| `parallel-step` | 旧 headless batch。互換・比較用に 1 phase 単位の並列 worker を起動する |
| `show` | canonical state を整形表示 |

`step` は `runs/<run-id>/run.lock` で直列化されます。同じ run に重ねた場合、後発は lock エラーで停止します。

`execution.mode: auto` または `parallel` では、Phase5 以降の task-scoped lane で `step` が task group を優先します。詳細は [parallelization.md](./parallelization.md) を参照してください。

## Worker wrapper

`start-agents.*` と `agent-loop.ps1` は CLI を呼ぶ薄い wrapper で、独自に `runs/` を書きません。

### Windows

```powershell
pwsh -NoLogo -NoProfile -File .\start-agents.ps1
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ResumeCurrent
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-claude.yaml.example
```

`start-agents.ps1` の流れ:

1. `app/cli.ps1 new` または `resume` で run を初期化
2. stale な relay-dev worker を停止
3. Windows Terminal を 1 タブ起動
4. `agent-loop.ps1 -Role orchestrator` を実行

### Linux / macOS

`start-agents.sh` が tmux session を作り、次の 2 pane を起動します。

- `agent-loop.ps1 -Role orchestrator -InteractiveApproval`
- `watch-run.ps1`

承認は worker pane で対話入力し、monitor pane では current run と推奨コマンドを確認します。

### `agent-loop.ps1`

- `orchestrator`: 常に `cli.ps1 step` を試みる
- `implementer` / `reviewer` ロール: `run-state.json.current_role` が一致するときだけ `step`
- `failed` の場合、現在 role か orchestrator が `resume` を 1 state fingerprint につき 1 回だけ試す
- run が `completed` / `blocked` なら待機

## 推奨運用（人間にやらせない前提）

人間が要件決定とレビューに集中できるよう、次は AI（skill ベース）に任せる構成を推奨します。

| 担当 | 内容 |
| --- | --- |
| 人間 | やりたいこと、制約、優先順位の判断、approval gate の応答 |
| AI | repo を読み、`tasks/task.md` を整え、必要なら Phase0 seed を作り、`start-agents.ps1` を起動し、現在 phase と次の確認ポイントを返す |

詳しくは [skills.md](./skills.md) と [docs/guide/README.md](./README.md) の推奨フローを参照。

## 人間レビュー

`config/settings.yaml`:

```yaml
human_review:
  enabled: true
  phases: [Phase3-1, Phase4-1, Phase7]
```

approval gate の選択肢:

| キー | 意味 |
| --- | --- |
| `y` | 承認 |
| `n` | 拒否（前 phase へ retry を要求） |
| `c` | 条件付き承認 |
| `s` | 今回のみスキップ |
| `q` | 中断 |

高リスクな変更ではこの gate を有効のまま運用することを推奨します。

## 監視と確認

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 show
Get-Content .\runs\<run-id>\events.jsonl
Get-Content .\dashboard.md
```

確認の優先順位:

1. `cli.ps1 show`（state の人間向けサマリ）
2. `runs/<run-id>/run-state.json`（正本）
3. `runs/<run-id>/events.jsonl`（時系列）
4. `runs/<run-id>/jobs/<job-id>/`（provider stdout/stderr/prompt）
5. `dashboard.md`（latest run のスナップショット）

`queue/status.yaml` は確認用には使えますが、調査の正本ではありません。

recoverable failed-state の調査では、`events.jsonl` に `run.recovered` が出ているかも先に確認すると経路を追いやすいです。

## トラブルシュート（よくあるケース）

| 症状 | 起きていること | 取るべき手 |
| --- | --- | --- |
| `step` が `lock` エラーで止まる | 同 run への重複 `step` | 既存 worker の終了を待つ。永続化していたら `troubleshooter` で原因切り分け |
| `show` と `outputs/` の表示がずれる | compatibility projection の再生成タイミング差 | `runs/<run-id>/run-state.json` を信じる |
| `Phase2` で永遠に進まない | `unresolved_blockers` が残った human pause | `relay-dev-phase2-clarifier` で対話回収 → `y` |
| `failed` になったのにすぐ `running` に戻る | `resume` / `agent-loop` が recoverable failed state を auto-resume した | `events.jsonl` の `run.failed` → `run.recovered` を見て、同じ phase の再試行結果を追う |
| `invalid_artifact` で停止したまま戻らない | validator が落ち、repair / auto-resume でも回復しなかった | `troubleshooter` で validation errors と job artifacts を確認し、必要なら `course-corrector` で pivot |
| visible worker を閉じても `active_job_id` が残る | stale state | 次回 `resume` / `step` で recovery される。手で run file を編集しない |
| provider が成功扱いだが artifact が空 | provider stdout に出力が乗らなかった | `jobs/<job-id>/stdout.log` を確認、provider 側 flag を見直す |

## 仕様変更 / 中断

途中で方針が変わったり、いったん止めたい場合は `relay-dev-course-corrector` を使い、次のいずれかに分類します。

- `rollback`: 直前の phase / commit に戻す
- `pause`: 一時停止（`stop-now` / `stop-at-boundary` / `hold-and-decide`）
- `pivot`: 同じ run の中で要件側を更新する
- `restart`: 新しい run を切る

old run は反射的に消さず、traceability のために保持します。

## 設定切替

別 provider 設定で動かすとき:

```powershell
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-gemini.yaml.example
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-copilot-cli.yaml.example
```

詳細は [providers.md](./providers.md) を参照。

## CI と回帰テスト

ローカル実行:

```powershell
pwsh -NoLogo -NoProfile -File tests/regression.ps1
```

CI が走らせる項目:

- PowerShell スクリプト構文チェック
- `tests/regression.ps1`（~3,000 行 / ~160KB の最小回帰）
- `scripts/check-public-examples.ps1`（公開 example の sanitize / validator / secret scan）

公開 example が無い段階では `check-public-examples.ps1` は `No manifest-backed public examples found; skipping public example checks.` を返して通過します。

## ディレクトリ早見

```text
relay-dev/
├── app/                     # cli + core / execution / phases / prompts / approval / ui
├── config/                  # settings.yaml + provider examples
├── docs/                    # architecture / plans / evaluations / ideas / guide / worklog
├── examples/                # 公開 sanitized examples（manifest 必須）
├── outputs/                 # 互換投影（auto-generated）
├── queue/                   # 互換ステータス（auto-generated）
├── runs/                    # canonical state / events / artifacts
├── skills/                  # 同梱 skill（front-door / seed-author / operator-launch / ...）
├── tasks/                   # tasks/task.md（external input）
├── tests/regression.ps1     # 回帰テスト
├── scripts/                 # 補助 (check-public-examples.ps1 等)
├── agent-loop.ps1           # polling wrapper
├── watch-run.ps1            # monitor pane
└── start-agents.ps1 / .sh   # visible worker launcher
```

README と実装が食い違うときは、`app/cli.ps1` → `app/core/*` → `app/phases/phase-registry.ps1` → `tests/regression.ps1` → `docs/architecture/architecture-redesign.md` の順を信じてください。
