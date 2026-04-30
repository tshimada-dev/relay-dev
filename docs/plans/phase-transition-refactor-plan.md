# Phase Transition Refactor Plan

## 1. 目的

この計画書の目的は、relay-dev の phase 遷移制御を「provider の終了状態」ではなく
「その attempt が生成した required artifact の妥当性」に基づいて進められるように再設計することです。

今回のゴールは次の 4 点です。

1. required な `md` と `json` が出力され、validator を通過したら次 phase に強制遷移する
2. 差し戻しまたは same-phase rerun の前に、既存の active artifact を必ず退避する
3. rerun 時に、最新の退避 `json` を agent の構造化コンテキストとして渡す
4. provider の成否や approval を含めて、phase 遷移が一貫した state machine で正常に進む

## 2. 現状レビューと根本問題

### F-01. `app/cli.ps1` に control plane の責務が集中しすぎている

- `Invoke-EngineStep` が stale repair、failed recovery、archive、prompt 組み立て、runner 実行、validation、event append、run-state 更新まで持っている
- `Resolve-StepValidation`、`Test-PhaseArtifactCompletion`、`New-EnginePromptText`、`Sync-RunStateFromCanonicalArtifacts` も同一ファイル内にあり、責務境界が曖昧
- 結果として「遷移の仕様変更」と「artifact の入出力変更」と「provider 起動方式変更」が同じ修正面に衝突する

### F-02. phase 成功判定が二重化しており、成功条件が一貫していない

- 実行中の成功検知は `Test-PhaseArtifactCompletion` が行う
- 実行後の妥当性確認は `Resolve-StepValidation` が canonical artifact を再読して行う
- 最終的な phase 成否は `Apply-JobResult` が `job.result_status` と `validation.valid` を見て決める
- そのため「artifact は valid だが provider exit は failed」「probe は間に合わず、post-run validation だけ成功」のようなケースで整合性が崩れる

### F-03. canonical active artifact が work-in-progress と source of truth を兼ねている

- 現在の active phase directory は provider の書き込み先であり、そのまま validator の読取元でもある
- `Archive-PhaseArtifacts` は rerun 前の汚染を減らせるが、attempt 単位の staging が無いため partial write と正本が分離されていない
- `Sync-PhaseOutputArtifacts` や `Resolve-StepValidation` も active artifact を前提に動くため、attempt の境界が曖昧

### F-04. validator が read-only ではなく、validation 中に canonical artifact を書き換える

- `Resolve-StepValidation` は `Normalize-ArtifactForValidation` の結果を `Save-Artifact` で canonical に書き戻す
- これは validator と normalizer と committer の責務が混ざっている状態
- 結果として「provider が壊れた出力を出したが validator が直した」ことが run history 上で見えにくくなる

### F-05. rerun context が prompt 文面に埋め込まれた path 情報に留まっている

- `Format-ArchivedPhaseJsonContextLines` は archived JSON の file path を prompt に列挙している
- しかし run-state や job-spec 上では「この rerun がどの snapshot を参照したか」が first-class な構造で保持されていない
- agent は prompt の文面を読んで path を解釈する必要があり、provider ごとの差で壊れやすい

### F-06. provider transport が capability-based ではなく、文字列連結ベースで壊れやすい

- `execution-runner.ps1` は `ProcessStartInfo.Arguments` に単一文字列を渡している
- `copilot` provider は `prompt_mode = "argv"` を返し、prompt を `-p "<long prompt>"` として連結する
- 実際に `copilot` 再開時は `error: too many arguments. Expected 0 arguments but got 66.` が発生しており、prompt transport が phase 遷移の blocker になっている
- 現行の回帰テストも「Copilot は argv transport を使う」こと自体を前提に固定している

### F-07. run-state の cursor 更新が commit ではなく dispatch 時点に寄っている

- `Apply-ApprovalDecision` は `DispatchJob` を採用した時点で `current_phase` を戻り先へ更新する
- `Invoke-EngineStep` も dispatch 前に `status=running` と `active_job_id` を run-state に書く
- `Sync-RunStatePhaseHistory` はこの cursor を見て phase history を生成するため、「job が成功した phase」と「今から走る phase」の境界が event / state 上で曖昧になる

### F-08. compatibility projection が commit path に強く結合している

- `Save-Artifact` は canonical write と同時に `outputs/` へ projection する
- `Sync-PhaseOutputArtifacts` も canonical artifact を読み直して projection する
- これにより canonical commit と legacy projection が分離されず、将来の atomic commit 設計の障害になる

## 3. 目標アーキテクチャ

### 3.1 基本原則

1. phase 成功の source of truth は `validated attempt artifacts`
2. provider exit は success condition ではなく `transport signal` として扱う
3. canonical active artifact は commit 済み成果物だけを置く
4. rerun / rollback 前の退避は attempt 開始時の deterministic な前処理にする
5. archived JSON context は prompt 文字列ではなく structured context source として job にぶら下げる

### 3.2 導入すべき新しい責務

#### A. `PhaseAttemptStore`

- 新規 attempt ごとに `attempt_id` を払い出す
- 書き込み先を `runs/<run-id>/attempts/<attempt-id>/artifacts/...` に分離する
- provider は active canonical ではなく attempt staging にだけ書く

#### B. `PhaseArchiveService`

- rerun 対象 phase の active artifact を `runs/<run-id>/artifacts/archive/.../<phase>/<snapshot-id>/` に移動する
- `metadata.json` に `run_id`, `phase`, `task_id`, `archived_at`, `reason`, `previous_job_id`, `previous_attempt_id` を残す
- 同時に「最新 archived JSON refs」を生成し、job context に渡す

#### C. `PhaseValidationPipeline`

- staging artifact を対象に required artifact presence と schema validation を行う
- normalizer は canonical を直接書き換えず、staging artifact を正規化した結果を返す
- `validation_result`, `normalized_artifacts`, `warnings`, `resolved_requirement_ids` を返す

#### D. `PhaseCompletionCommitter`

- validation が通ったら staging から canonical active path へ promote する
- commit は phase 単位の単一処理にし、成功時にだけ compatibility projection を行う
- `phase.completed` と `artifact.committed` 相当の event を append する

#### E. `JobContextBuilder`

- input artifact refs
- selected task
- open requirements
- latest archived JSON refs
- attempt metadata

これらを構造化して job-spec に埋め込む。prompt はこの構造化 context を render したものに過ぎない状態にする。

#### F. `ProviderTransportAdapter`

- provider ごとに `prompt_transport = stdin | argv | temp_file | protocol`
- `argument_list` を token 配列で保持し、単一文字列連結をやめる
- Copilot は短期的には `argument_list` 化、長期的には ACP など command-line 長制限に依存しない transport へ移行する

## 4. 目標フロー

1. engine が `DispatchJob` を決定する
2. `AttemptPreparationService` が rerun 判定を行う
3. rerun の場合は active canonical artifact を archive する
4. `PhaseAttemptStore` が空の staging directory を払い出す
5. `JobContextBuilder` が latest archived JSON refs を含む job context を作る
6. provider は staging に対してのみ `md/json` を出力する
7. `PhaseValidationPipeline` が staging を検証する
8. valid なら `PhaseCompletionCommitter` が staging を canonical に promote する
9. promote 成功後にだけ `Apply-JobResult` 相当の state transition を行う
10. provider exit が non-zero でも、commit 済みなら next phase へ進む

## 5. リファクタリング計画

### WS-01. `cli.ps1` から phase orchestration を分離する

目的:
- `cli.ps1` を entrypoint のみに戻す

分離対象:
- failed recovery
- stale active job recovery
- archive-before-rerun
- prompt / context 組み立て
- output sync / validation / commit

新規候補:
- `app/core/engine-step-runner.ps1`
- `app/core/attempt-preparation.ps1`
- `app/core/job-context-builder.ps1`
- `app/core/phase-validation-pipeline.ps1`
- `app/core/phase-completion-committer.ps1`

完了条件:
- `cli.ps1` は `new/resume/step/show` の引数解決と entrypoint 呼び出しだけを持つ

### WS-02. attempt-scoped staging と atomic commit を導入する

目的:
- active canonical artifact を WIP から切り離す

変更内容:
- provider の出力先を `runs/<run-id>/attempts/<attempt-id>/artifacts/...` に変更
- `Read-Artifact` / `Save-Artifact` とは別に `Read-AttemptArtifact` / `Commit-AttemptArtifacts` を導入
- `Sync-PhaseOutputArtifacts` を canonical projection ではなく attempt materialization へ置換

完了条件:
- validation は canonical active path を直接読まない
- phase success は staging validation + commit 成功でのみ決まる

### WS-03. archive-before-rerun を first-class workflow にする

目的:
- rerun / rollback 時の artifact 汚染をゼロにする

変更内容:
- archive 判定を `phase history` と `run.recovered` の heuristics ではなく `attempt creation policy` に移す
- active artifact の有無、rerun 理由、target phase をもとに deterministic に archive する
- archive snapshot metadata に `source_attempt_id` を追加する

完了条件:
- rerun では provider 起動前に active directory が必ず空になる
- task-scoped / run-scoped の全 phase で同じルールが適用される

### WS-04. archived JSON context を structured context 化する

目的:
- agent への引き継ぎを prompt 文字列依存から外す

変更内容:
- `jobSpec.archived_context_refs[]` を追加する
- 各要素は `{ scope, phase, task_id, snapshot_id, artifact_id, path }` を持つ
- `New-EnginePromptText` はこの構造を render するだけにする
- provider / reviewer prompt は path 解釈を前提にしない

完了条件:
- latest archived JSON を engine が一意に選び、job metadata に残せる
- rerun の検証で「どの snapshot を参照したか」を event / job metadata から追跡できる

### WS-05. provider transport を capability-based に作り直す

目的:
- `copilot` の `too many arguments` 系失敗を phase 遷移から切り離す

変更内容:
- `InvocationSpec` に `argument_list` と `prompt_transport` を追加する
- `execution-runner.ps1` は `ProcessStartInfo.ArgumentList` を優先使用する
- `argv` transport は prompt size に safe limit を設け、超える場合は fail-fast か別 transport を要求する
- Copilot adapter は短期 `argument_list` 化、長期 ACP / protocol adapter を検討する

完了条件:
- prompt 内の改行・引用符・長文で token 分割事故が起きない
- provider ごとの transport 制約が code と test に明文化される

### WS-06. validation を read-only 化し、normalization を pre-commit pipeline に移す

目的:
- validator が正本を書き換えないようにする

変更内容:
- `Resolve-StepValidation` から `Save-Artifact` を除去する
- `Normalize-ArtifactForValidation` は `normalized_artifact` を返すだけにする
- commit 前に `normalized_artifact` を staging に反映する

完了条件:
- validation は純粋関数になる
- provider 出力と engine 補正の境界が job metadata から追える

### WS-07. phase state machine を明示化する

目的:
- dispatch 中、running 中、completed、failed の意味を分ける

変更内容:
- run-state または attempt-state に `dispatching`, `running`, `committing`, `waiting_approval`, `failed`, `completed` を導入
- `current_phase` は commit または approval resolution の意味に限定し、attempt 側で in-flight phase を表現する
- `phase_history` は attempt 起点で確定させる

完了条件:
- `show` と `run-state.json` と `events.jsonl` の説明が一致する
- approval 後の戻り先 phase と、実際に commit 済みの phase が混同されない

### WS-08. regression test を scenario-based に組み替える

目的:
- phase 遷移の正常性を provider 別に守る

最低限追加すべきケース:
- provider exit = failed でも staging artifact valid なら next phase へ進む
- invalid artifact なら archive の有無に関わらず進まない
- `Phase3-1 -> approve -> Phase3 rerun` で archive と archived JSON context が入る
- task-scoped phase (`Phase5`, `Phase6`) でも archive/context が動く
- Copilot provider は token split せず prompt が 1 引数または非 argv transport で渡る

## 6. 実装順

1. WS-05 provider transport の応急修正
2. WS-02 attempt-scoped staging
3. WS-06 validation read-only 化
4. WS-03 archive-before-rerun の deterministic 化
5. WS-04 archived JSON context の structured 化
6. WS-07 phase state machine 明示化
7. WS-01 `cli.ps1` 分割
8. WS-08 scenario test 拡充

理由:
- まず provider transport で run が起動できるようにしないと、後続の phase 遷移検証が進まない
- その後、成功判定の source of truth を attempt staging + validation + commit に置き換える

## 7. 受け入れ条件

### P0

- required `md/json` が staging に揃い validator が `valid=true` なら、provider exit code に関わらず next phase へ遷移する
- rerun / rollback 時は active canonical artifact が provider 起動前に archive される
- rerun job metadata に `archived_context_refs[]` が残る
- `show`, `run-state.json`, `events.jsonl` の phase 表示が一致する

### P1

- validator は canonical artifact を書き換えない
- compatibility projection は canonical commit 後にのみ行われる
- task-scoped phase と run-scoped phase で同じ attempt / archive モデルが使われる

## 8. 対象ファイル

主な改修対象:

- `app/cli.ps1`
- `app/core/workflow-engine.ps1`
- `app/core/artifact-repository.ps1`
- `app/core/artifact-validator.ps1`
- `app/core/job-result-policy.ps1`
- `app/core/run-state-store.ps1`
- `app/execution/execution-runner.ps1`
- `app/execution/provider-adapter.ps1`
- `app/execution/providers/copilot.ps1`
- `tests/regression.ps1`

新規追加候補:

- `app/core/attempt-preparation.ps1`
- `app/core/phase-attempt-store.ps1`
- `app/core/phase-validation-pipeline.ps1`
- `app/core/phase-completion-committer.ps1`
- `app/core/job-context-builder.ps1`
- `app/execution/prompt-transport.ps1`

## 9. 今回のレビュー結論

最も根本的に破綻しているのは「phase の成功条件が provider 終了と artifact 妥当性の二系統に割れており、しかも canonical active artifact が WIP と正本を兼ねていること」です。

この問題に対して archive-before-rerun だけを積み増すのは応急処置としては有効ですが、最終解は次の 3 点の同時導入です。

1. attempt-scoped staging
2. validation 後の atomic commit
3. structured archived context

この 3 点を入れない限り、provider failure、fast exit、approval rollback、task-scoped rerun のどれかで再発し続けます。
