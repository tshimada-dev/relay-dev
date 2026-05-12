# relay-dev 技術レビュー 2026-05-12

## 1. 総評（3〜5行）

relay-dev は、trusted local workflow 向けのフェーズ駆動 AI 開発 runner として完成度が高く、重大欠陥は確認していません。設計は canonical state / event log / typed artifact / approval gate に責務が分離されており、単なるプロンプト駆動ではなく運用可能な制御面を持っています。既定設定は `execution.mode: single` で保守的であり、小規模チームのローカル運用なら現実的に運用可能です。並列 task group はよく作り込まれていますが、単発 leased job に比べると未申告 workspace 変更の検出が薄い点は改善余地です。

検証として `pwsh -NoLogo -NoProfile -File tests\regression.ps1` と、`tests/regression.ps1` 以外の全補助テストをローカル実行し、いずれも成功しました。

## 2. リスク評価（確率×影響度で評価）

| 評価対象 | 発生確率 | 影響度 | 総合リスク | 根拠 |
| --- | --- | --- | --- | --- |
| 自律制御 | 低 | 中 | 低 | 完全無人運転ではなく human approval gate 前提で、Phase3-1 / Phase4-1 / Phase7 が承認対象です。`README.md:180-188`、`app/approval/approval-manager.ps1:78-95`。フェーズ遷移も明示ルールで検証され、reject の rollback_phase は許可先に限定されています。`app/phases/phase-registry.ps1:56-74`、`app/core/transition-resolver.ps1:47-81`。 |
| セキュリティ | 中 | 中 | 中 | セキュリティ境界を trusted local execution に限定しているのは妥当です。`SECURITY.md:3-15`。前回懸念だった Claude / Copilot の prompt argv 渡しは stdin 指定になっており改善済みです。`app/execution/providers/claude.ps1:76-89`、`app/execution/providers/copilot.ps1:200-219`。一方、provider stdout/stderr はそのまま保存されるため、secret を prompt や provider 出力に含める運用では露出リスクが残ります。`app/execution/execution-runner.ps1:934-936`。 |
| 状態管理 | 低 | 中 | 低 | `run-state.json` と `events.jsonl` を正本にする設計は一貫しています。`README.md:9-19`。同一 run の `step` は file lock で直列化され、lease token / state_revision / heartbeat もあります。`app/core/run-lock.ps1:11-79`、`app/core/run-state-store.ps1:761-923`、`app/core/parallel-worker.ps1:379-480`。低確率の残余として、`Write-RunState` は temp file 後に既存ファイル削除して move するため、read-only watcher が一瞬 missing を見る可能性はあります。`app/core/run-state-store.ps1:1193-1199`。 |
| テスト戦略 | 中 | 中 | 中 | 回帰テストと補助テストは広く、今回すべて通過しました。ただし CI が標準で実行するのは構文チェック、`tests/regression.ps1`、公開 example 検査のみで、task-group / task-parallelization 系の個別テストは直接 CI に入っていません。`.github/workflows/ci.yml:22-50`、`docs/guide/operations.md:158-172`。並列実行は事故時の影響が大きいため、CI未接続は運用品質上の中リスクです。 |
| デプロイ安全性 | 低 | 中 | 低 | 既定は single mode で、parallel は opt-in です。`config/settings.yaml:21-27`。artifact validation 後 commit、repair budget、timeout recovery、process tree stop、task group の all-or-nothing merge があり、実運用上は堅実です。`app/core/phase-execution-transaction.ps1:312-417`、`app/execution/execution-runner.ps1:315-440`、`app/core/phase-completion-committer.ps1:193-249`。 |

## 3. 改善提案（優先度は実害基準）

### P0

P0なし。重大欠陥なし。

### P1

1. task group merge 前に、worker ごとの workspace boundary delta を必ず評価する。単発 leased job は `Test-WorkspaceBoundaryDelta` で未申告変更を拒否してから merge します。`app/core/parallel-worker.ps1:789-843`。一方、task group worker は各 phase を isolated workspace で実行し、親 canonical artifact への commit を無効化したまま成功結果を返します。`app/core/parallel-worker.ps1:243-249`、`app/core/parallel-worker.ps1:269-280`。最終 merge は worker result / row の `changed_files` をそのまま `accepted_changed_files` として扱います。`app/core/phase-completion-committer.ps1:181-190`、`app/core/parallel-workspace.ps1:536-577`。理論上の最悪ケースは未申告変更まで main に混入することですが、現実的には未申告ファイルはコピーされにくく、むしろ worker 内テストだけ通って main workspace では必要ファイルが欠けるリスクです。発生確率は中、影響度は中です。

2. 補助テスト群をCIの標準ゲートに追加する。今回ローカルでは `task-group-parallel-*` と `task-parallelization-*` は全て通過しましたが、CI定義上は直接実行されていません。`.github/workflows/ci.yml:44-50`。並列 lane は `config/settings.yaml` の既定では無効とはいえ、`docs/guide/operations.md:28-34` で運用コマンドとして扱われているため、少なくとも並列系の短時間テストをCIに入れる価値があります。

3. provider stdout/stderr と job metadata に redact 層を追加する。現状は診断性を優先して raw log を保存します。`app/execution/execution-runner.ps1:934-936`。`SECURITY.md:5-11` で公開禁止は明記されていますが、実運用で customer data や token を prompt に混ぜる可能性がある場合、保存前 redaction または secret pattern warning があると事故確率を下げられます。

### P2

1. `Write-RunState` を `File.Replace` 相当の atomic replace に寄せる。現状でも run lock があるため実害は低確率ですが、read-only monitor が `run-state.json` の削除と move の間を読む可能性を消せます。`app/core/run-state-store.ps1:1193-1199`。

2. `events.jsonl` の tail read / rotation を追加する。現状 `Get-Events` は全件読み込みです。`app/core/event-store.ps1:30-48`。長寿命 run や監視頻度が高い運用で効いてくる将来拡張です。

3. 実 provider CLI の opt-in smoke test を用意する。通常CIで外部CLIを叩けない判断は妥当ですが、Codex / Gemini / Claude / Copilot CLI の引数互換は外部更新で変わり得るため、ローカルまたは手動CIで確認できる小さなテストがあると保守性が上がります。provider adapter 自体は stdin 経路へ整理されています。`app/execution/providers/generic-cli.ps1:36-50`。

## 4. 強み

- canonical state と互換投影を明確に分け、調査順序も文書化されています。`README.md:81-92`、`docs/guide/operations.md:112-122`。
- approval gate が単なるUIではなく、reject target と conditional approval の正規化を持っています。`app/approval/approval-manager.ps1:39-95`。
- Phase6 verdict は artifact 側の自己申告に依存せず、テスト失敗や warning / open requirements から機械的に正規化されます。`app/core/verdict-finalizer.ps1:52-131`。
- Phase4 task schema が changed_files / boundary_contract / visual_contract / dependencies を要求し、依存サイクルも検出します。`app/core/artifact-validator.ps1:583-704`。
- 並列実行は resource lock、isolated workspace、sibling overlap 検出、all-or-nothing merge を持ち、無理な並列化を避ける方向に倒れています。`app/core/workflow-engine.ps1:349-536`、`app/core/task-group-worker-isolation.ps1:100-142`、`app/core/parallel-workspace.ps1:453-577`。
- 公開 example の secret / raw log / local path 検査があり、公開事故に対する現実的なガードがあります。`scripts/check-public-examples.ps1:41-100`。

## 5. 技術成熟度評価

84 / 100

小規模本番相当の trusted local 開発 runner としては十分に運用可能な水準です。前回の明確なセキュリティ懸念だった prompt argv 渡しは改善され、状態管理・承認・validator・repair・並列制御はいずれも成熟しています。90点台に届かない理由は、task group 経路の未申告変更検出が単発 leased job より弱いこと、補助テスト群がCI標準ゲートに入っていないこと、raw provider log の秘匿が運用規律に寄っていることです。
