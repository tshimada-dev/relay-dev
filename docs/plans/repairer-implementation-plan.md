# Repairer Implementation Plan

## 1. 目的

この計画書の目的は、relay-dev に `repairer` を追加し、artifact validation 失敗時でも run を即停止させずに
自走継続できる修復レーンを導入することです。

今回のゴールは次の 5 点です。

1. `invalid_artifact` のうち修復可能な失敗を same-phase の自動修復へ落とす
2. `repairer` は current phase の staged artifact だけを修復対象にする
3. `repairer` には product code の修正を絶対にさせない
4. `repairer` には verdict 判定、must-fix 判定、approval 代替などのレビュー行為を絶対にさせない
5. 修復成功時は run を止めず、そのまま commit と次 phase 遷移まで進める

## 2. 非交渉の制約

### C-01. `repairer` は code editor ではない

- `src/`, `app/`, `prisma/`, `tests/`, `package.json` など product code / config / test 資産は編集対象外
- 編集可能なのは current job / current attempt の staged required artifacts のみ
- canonical artifact、archive artifact、run-state、event log は編集対象外

### C-02. `repairer` は reviewer ではない

- `verdict` を新しく判断しない
- `security_checks[].status`、`must_fix`、`open_requirements` の意味内容を再評価しない
- `approve / reject / conditional_go` の判断主体にならない
- approval request の生成や解決に関与しない

### C-03. `repairer` は semantic rewrite をしない

- 許可するのは syntax / materialization / schema 整形の修復まで
- 元 artifact の意味を変える要約、追加調査、再設計、再レビューは禁止
- reviewer artifact に対しては特に、`verdict`、`rollback_phase`、`security_checks[*].status` を immutable field として扱う

## 3. 現状の問題

### F-01. validator failure が即 run failure になる

- `Apply-JobResult` は validation 失敗を即 `FailRun(reason=invalid_artifact)` にしている
- そのため provider job が正常終了しても run 全体は止まる
- 自走性が最も悪化するポイントになっている

### F-02. syntax 系 failure と content 系 failure が同列に扱われている

- `Bad JSON escape sequence`
- trailing comma
- scalar/array mismatch
- known schema normalization

これらは current artifact を少し直せば通ることが多いが、現状は phase rerun か manual resume に落ちる。

### F-03. same-phase rerun は token と時間のコストが高い

- full prompt を再送する
- 既存 artifact を再読する
- phase 出力全体を再生成する

今回のような `\d` escape 失敗に対しては、artifact 局所修復の方が圧倒的に効率がよい。

## 4. 目標挙動

### 4.1 高レベルフロー

1. provider が staged artifact を出力する
2. validation / materialization を行う
3. validation error を `repairable` と `terminal` に分類する
4. `repairable` なら run を failed にせず `repair lane` に入る
5. `repairer` が staged artifact だけを修復する
6. 再 validation を行う
7. valid なら commit して通常の phase 遷移へ戻る
8. budget 超過または terminal error なら初めて `run.failed` に落とす

### 4.2 run-state の扱い

- `status` は `running` のまま維持する
- `current_phase` と `current_task_id` は据え置く
- `current_role` は `repairer` に切り替えるか、少なくとも `active_attempt.stage=repairing` を持たせる
- approval phase の手前で壊れた場合も、修復成功後にのみ approval を出す

## 5. `repairable` の定義

### 5.1 repairable failure

- JSON parse error
- bad escape sequence
- trailing comma
- BOM / encoding 汚染
- schema-required field の shape 揺れ
- known normalizable shape
- materialization failure だが staged raw text は存在するケース

### 5.2 terminal failure

- required artifact 自体が未生成
- phase contract 上の必須項目が内容的に欠落
- `conditional_go` と `failed security_checks` のような semantic invariant 違反
- markdown / json の主張が矛盾
- 証拠不足で field を埋めると意味改変になるケース

原則:
- syntax を直せば通るものだけ `repairable`
- 意味判断が必要なら `repairer` に渡さない

## 6. 役割設計

### 6.1 新しい role

- role 名: `repairer`
- system prompt: `app/prompts/system/repairer.md`
- provider command: 基本は implementer/reviewer と同じ provider を再利用可能
- ただし prompt 契約と出力契約は repair 用に分離する

### 6.2 repairer prompt contract

入力:
- validator error
- materialization error
- current staged artifacts
- immutable fields list
- required output schema の抜粋
- latest archived JSON context
- 直前の phase / task metadata

禁止事項:
- repo code の編集
- new evidence の探索
- review verdict の再判定
- scope 外 artifact の生成

出力:
- 修復済み staged artifact のみ
- optional な `repair_notes.json` 相当の内部メタデータは許可してよいが、canonical output には commit しない

## 7. アーキテクチャ案

### A. `ArtifactRepairPolicy`

責務:
- validation failure を `repairable` / `terminal` に分類する
- immutable fields を決める
- repair budget と error fingerprint を管理する

候補ファイル:
- `app/core/artifact-repair-policy.ps1`

### B. `ArtifactRepairTransaction`

責務:
- repair attempt の job spec を組み立てる
- staged artifact を repair sandbox に渡す
- repair 後の re-validation を実行する
- success 時は元の phase execution transaction に戻す

候補ファイル:
- `app/core/artifact-repair-transaction.ps1`

### C. `RepairPromptBuilder`

責務:
- validator errors
- immutable fields
- exact staged file paths
- archived context refs

これらから repairer 専用 prompt を生成する。

候補ファイル:
- `app/core/repair-prompt-builder.ps1`

### D. `RepairDiffGuard`

責務:
- repair 前後の artifact diff を比較する
- immutable field 変更や意味改変の疑いを検出する
- 許容差分だけを通す

候補ファイル:
- `app/core/repair-diff-guard.ps1`

## 8. 実装方針

### WS-01. validation failure の分類レイヤを追加する

変更対象:
- `app/core/workflow-engine.ps1`
- `app/core/phase-validation-pipeline.ps1`
- `app/core/artifact-validator.ps1`

内容:
- `invalid_artifact` をすぐ `FailRun` しない
- error object に `repairability`, `error_fingerprint`, `artifact_paths`, `immutable_fields` を付与する

完了条件:
- validator 結果だけで `repairable` 判定が返る

### WS-02. repairer role と prompt を追加する

変更対象:
- `app/phases/phase-registry.ps1`
- `app/prompts/system/repairer.md`
- `app/cli.ps1`

内容:
- `Resolve-PhaseRole` とは別に、repair lane で `repairer` を明示的に選べるようにする
- provider command / flags の role ルーティングに `repairer` を追加する
- repair prompt は phase prompt の代わりに repair contract を使う

完了条件:
- `repairer` job spec を生成できる
- `repairer` prompt に code edit / review 禁止が固定で入る

### WS-03. repair transaction を phase execution transaction に統合する

変更対象:
- `app/core/phase-execution-transaction.ps1`
- `app/core/job-context-builder.ps1`
- `app/core/run-state-store.ps1`

内容:
- `validation.valid=false && repairable=true` のとき `Invoke-ArtifactRepairTransaction` に分岐
- `active_attempt.stage` に `repairing` を追加
- repair success 時は同一 attempt の commit 手順へ戻す

完了条件:
- repair 成功で `run.failed` を経由せずに commit できる

### WS-04. immutable field guard を入れる

変更対象:
- `app/core/repair-diff-guard.ps1`
- `app/core/artifact-validator.ps1`
- `tests/regression.ps1`

内容:
- reviewer artifact の `verdict`, `rollback_phase`, `security_checks[*].status` 変更を拒否
- implementer artifact でも top-level semantic keys の wholesale rewrite を検出

完了条件:
- `repairer` が意味を書き換えた場合は repair failure になる

### WS-05. deterministic pre-fix を先に行う

変更対象:
- `app/core/artifact-validator.ps1`
- `app/core/artifact-repair-policy.ps1`

内容:
- common escape / BOM / newline / trailing comma は LLM を呼ぶ前に deterministic fix を試す
- deterministic fix で通れば `repairer` を起動しない

完了条件:
- 低コストで直る failure は agent 呼び出しなしで解消される

### WS-06. repair budget と circuit breaker を追加する

変更対象:
- `app/core/run-state-store.ps1`
- `app/core/artifact-repair-policy.ps1`
- `app/cli.ps1`

内容:
- 同一 phase / task / fingerprint ごとに repair budget を持つ
- 例: `max_repair_attempts_per_phase = 2`
- 同一 fingerprint が続いたら fail-fast

完了条件:
- repair loop が無限化しない

## 9. 変更対象ファイル

- `app/cli.ps1`
- `app/core/workflow-engine.ps1`
- `app/core/phase-execution-transaction.ps1`
- `app/core/phase-validation-pipeline.ps1`
- `app/core/artifact-validator.ps1`
- `app/core/job-context-builder.ps1`
- `app/core/run-state-store.ps1`
- `app/phases/phase-registry.ps1`
- `app/prompts/system/repairer.md`
- `tests/regression.ps1`

新規追加候補:
- `app/core/artifact-repair-policy.ps1`
- `app/core/artifact-repair-transaction.ps1`
- `app/core/repair-prompt-builder.ps1`
- `app/core/repair-diff-guard.ps1`

## 10. テスト計画

### T-01. repairable JSON parse error

- 条件: bad escape sequence
- 期待: `repairer` or deterministic pre-fix で修復
- 結果: run は `failed` にならず next phase へ進む

### T-02. immutable field change attempt

- 条件: `repairer` が `verdict` を変える
- 期待: diff guard が reject
- 結果: run は repair budget 消費後に fail

### T-03. terminal semantic invariant violation

- 条件: `conditional_go` + failed security check
- 期待: repair lane に入らず terminal failure
- 結果: 既存の invalid artifact failure と同様に止まる

### T-04. reviewer artifact syntax-only repair

- 条件: `security_checks[].notes` の escape 崩れ
- 期待: status / verdict は保持したまま syntax だけ直る

### T-05. implementer artifact schema repair

- 条件: known scalar/array mismatch
- 期待: shape だけ直し、要約や設計内容を増減させない

### T-06. budget exhaustion

- 条件: 同一 fingerprint が連続
- 期待: budget 到達で `run.failed`

## 11. 段階導入

### Phase A

- deterministic pre-fix のみ
- repairer なし

### Phase B

- JSON / schema repair 専用 repairer
- reviewer / implementer 両方の artifact に適用
- immutable field guard 必須

### Phase C

- dashboard / event の見え方改善
- repair metrics 収集

## 12. 成功指標

- syntax 系 `invalid_artifact` の大半が manual resume なしで解消される
- `run.failed reason=invalid_artifact` 件数が明確に減る
- same-phase full rerun の発生率が下がる
- reviewer artifact の semantic drift 事故が 0 件

## 13. 結論

`repairer` は有効だが、第三の汎用 agent として入れるのではなく、artifact 修復専用の狭い lane として実装するのが正しい。
特に「code を触らない」「review をしない」「immutable field を変えない」を engine 側で強制することが、この設計の成立条件になる。
