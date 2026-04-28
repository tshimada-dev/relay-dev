# Relay-Dev

Relay-Dev is a phase-driven AI development runner that turns `task.md` / `DESIGN.md` inputs into reviewable design, implementation, test, approval, and release artifacts.

Relay-Dev は、`runs/<run-id>/run-state.json` と `runs/<run-id>/events.jsonl` を正本に持つ、フェーズ駆動の自律開発ランナーです。  
AI は provider CLI として差し替え可能で、Control Plane は `app/cli.ps1` が一元管理します。
主な用途は「曖昧な開発依頼を、設計・実装・レビュー・検証 artifacts と approval 履歴を持つ成果物へ進めること」です。

## 5分で見る relay-dev

- 何をするものか: `tasks/task.md` と任意の `DESIGN.md` を入力に、Phase0 から Phase8 までの typed artifacts を生成する AI 開発ランナーです。
- どこが難しいか: AI 出力を散文だけで流さず、`run-state.json`、`events.jsonl`、JSON artifact、approval gate、validator で追跡可能にしている点です。
- 何が証拠か: CI、`tests/regression.ps1`、canonical artifact store、公開用に sanitize する examples、approval / review artifacts です。
- まず見る順番: README -> `examples/README.md` -> `docs/architecture-redesign.md` -> `docs/portfolio-roadmap.md`

## 非対象

relay-dev は汎用 AGI や完全無人の自律運転基盤ではありません。
本番 SaaS として提供するものでもなく、人間承認を前提にした開発 runner です。安全性は runtime enforcement と prompt / 運用規律を分けて扱います。

現在の relay-dev は、旧来の「2エージェントが `queue/status.yaml` を受け渡しながら進む仕組み」からリファクタされ、次の考え方に寄せています。

- 正本は `runs/` 配下の構造化 state / event / artifact
- `app/cli.ps1` が single writer として run を進行
- `queue/status.yaml` と `outputs/` は互換投影
- provider は `codex` / `gemini` / `copilot` などの CLI を差し替え可能
- Markdown artifact は人間向けドキュメントとして日本語、JSON artifact は機械可読 contract として扱う

詳細な設計メモは [docs/architecture-redesign.md](./docs/architecture-redesign.md) と [docs/redesign-design-spec.md](./docs/redesign-design-spec.md) を参照してください。

## 概要

relay-dev は、1 run を 1 step ずつ前進させる orchestrator 型の実行基盤です。  
各フェーズの prompt、入出力 contract、validator、遷移規則を engine が解決し、必要な job だけを provider CLI に委譲します。

### 主な特徴

- `app/cli.ps1` が `new` / `resume` / `step` / `show` を提供
- run の正本は `runs/<run-id>/run-state.json` と `runs/<run-id>/events.jsonl`
- artifact は canonical location に保存され、`outputs/` に互換投影される
- `Phase0` は `tasks/task.md` から生成できるほか、妥当な seed があれば import してスキップできる
- `Phase3` で設計境界を構造化 contract として定義し、`Phase4` / `Phase5` 以降で拘束条件として引き回せる
- UI 作業では `DESIGN.md` を design input として取り込み、後続フェーズの `visual_contract` に落とし込める
- 重要ゲートでは人間レビューを挟める
- provider 固有実装は adapter 層に閉じ込められている
- CI では PowerShell 構文チェックと最小回帰テストを実行

### 設計契約の考え方

relay-dev は、実装時に毎回「カプセル化を守ること」「責務を混ぜないこと」を口頭で言い直すのではなく、上流フェーズで決めた設計境界を contract として後続に引き回す考え方を取ります。

- `Phase3` では `module_boundaries` / `public_interfaces` / `allowed_dependencies` / `forbidden_dependencies` / `side_effect_boundaries` / `state_ownership` を設計 contract として定義する
- `Phase3-1` では reviewer がその設計 contract の妥当性を固定観点で確認する
- `Phase4` では各 task が `boundary_contract` を持ち、変更してよい境界を task 単位に絞り込む
- `Phase5-1` では実装が task contract にない越境をしていないかを証拠付きで確認する

これにより、カプセル化は「実装者の気分次第の作法」ではなく、artifact と reviewer の両方で確認される拘束条件になります。

UI を含む案件では、見た目も同様に contract として扱います。  
`DESIGN.md` がある場合、relay-dev はそこから `design_inputs` と `visual_constraints` を抽出し、`Phase1` の `visual_acceptance_criteria`、`Phase3` / `Phase4` の `visual_contract`、`Phase5-1` の整合性チェックへ引き継ぎます。

## 推奨の使い方

### 目指す運用

relay-dev の推奨運用は、`task.md` や `Phase0` を人間が手で埋めてから起動する形ではありません。  
基本は、relay-dev を扱う skill 群を読んだ AI と対話しながら要件を決め、その AI が起動準備と起動コマンドの実行まで担当する流れです。

役割分担は次のイメージです。

- 人間: やりたいこと、制約、優先順位を AI と対話して決める
- AI: repo を読み、`tasks/task.md` を整え、必要なら `outputs/phase0_context.*` を作り、適切な起動コマンドを選んで実行する

### 同梱 skill

現在の relay-dev には、役割ごとに次の skill を同梱しています。

- `relay-dev-front-door`: 要件整理と clarification を行う入口
- `relay-dev-phase2-clarifier`: `Phase2` で止まった質問事項を要約し、対話で決めて seed に反映する
- `relay-dev-seed-author`: `tasks/task.md` と `outputs/phase0_context.*` を整える
- `relay-dev-operator-launch`: `new` / `resume` / `step` / `show` / `start-agents.ps1` を選んで実行し、停止後の再開も扱う
- `relay-dev-troubleshooter`: run 異常や provider 失敗を調査する
- `relay-dev-course-corrector`: 戻す、止める、方針を変えるを安全に扱う

### skill の配置

この repo では、relay-dev 用 skill を `skills/` 配下に同梱しています。  
これは「repo で管理する元ファイル置き場」です。

例:

```text
relay-dev/
└── skills/
    ├── relay-dev-front-door/
    │   ├── SKILL.md
    │   ├── agents/
    │   └── references/
    ├── relay-dev-phase2-clarifier/
    ├── relay-dev-seed-author/
    ├── relay-dev-operator-launch/
    ├── relay-dev-troubleshooter/
    └── relay-dev-course-corrector/
```

一方、Codex が通常 skill として参照する本来の配置は `$CODEX_HOME/skills/` 配下です。

代表例:

```text
Windows: %USERPROFILE%\\.codex\\skills\\<skill-name>\\
Linux/macOS: ~/.codex/skills/<skill-name>/
```

つまり、relay-dev の `skills/` は「配布・バージョン管理用」、`$CODEX_HOME/skills/` は「実際に Codex が読む配置」です。  
ローカルで使うときは、必要に応じてこの repo の各 skill ディレクトリを `$CODEX_HOME/skills/` にコピーするか、symlink で参照させてください。

配置ルール:

- 1 skill = 1 ディレクトリ
- ルートに `SKILL.md` を置く
- UI 用設定は `agents/openai.yaml`
- 詳細な補助資料は `references/`
- 実行スクリプトが必要なら `scripts/`
- 出力に使う素材があれば `assets/`

`runs/`、`outputs/`、`queue/` のような runtime 領域には skill を置かないでください。

### skill の考え方

skill は「AI が relay-dev を安全に扱うための作業手順書」です。  
1 つの skill が全部を抱え込むのではなく、`要件整理`、`Phase2 質問回収`、`seed 作成`、`起動判断`、`障害調査`、`方針変更` を分担させています。

この分担にしている理由は次の通りです。

- 要件整理の会話と、CLI 操作や state 調査は求められる振る舞いが違う
- `tasks/task.md` や `Phase0` seed は生成責任を分離した方が再利用しやすい
- `Phase2` で止まったあとの対話は、通常 intake と分けた方が会話の目的がぶれにくい
- 障害調査や仕様変更を通常起動フローと分けた方が誤操作を減らせる
- 人間は「何を作るか」と「どこで止めるか」の判断に集中しやすい

### 各 skill の役割

#### `relay-dev-front-door`

対話型の要件整理 skill です。  
単に質問票を埋めるのではなく、AI が壁打ち相手になって要件を具体化します。

- 向いている場面:
  - 要件がまだ曖昧
  - 何を先に決めるべきか分からない
  - 選択肢を比較しながら方向性を決めたい
  - 成功条件や非目標を対話で詰めたい
- 主な振る舞い:
  - repo を軽く読んで、既知情報を踏まえて会話する
  - UI 作業では `DESIGN.md`、画面参照、style direction の有無も intake する
  - 1 ターンに 1〜3 個の高レバレッジな質問だけを行う
  - 各ターンで「いま何が決まっていて、何が未決か」を要約する
  - ユーザーが迷っている場合は、選択肢と短い tradeoff を提示する
  - 最後に `request_summary` / `requirements` / `constraints` / `non_goals` / `open_questions` と、必要なら `design_inputs` / `visual_constraints` へ正規化する
- ここではやらないこと:
  - `new` / `resume` / `step` の実行
  - `tasks/task.md` や `Phase0` seed の書き込み
  - `runs/` を見た障害調査

#### `relay-dev-phase2-clarifier`

`Phase2` の clarification fallback で止まったとき専用の skill です。  
未解決の質問を短く要約し、ユーザーと対話で決め、その結果を upstream input に反映します。

- 向いている場面:
  - `Phase2` の `unresolved_blockers` が残って pause した
  - 「質問事項を要約して、一緒に決めたい」
  - 回答を `tasks/task.md` や `outputs/phase0_context.*` に反映してから再開したい
- 主な振る舞い:
  - current run の `phase2_info_gathering.*` を読んで質問を要約する
  - 1 ターンに 1〜3 問ずつ、選択肢と tradeoff を添えて対話する
  - 決まった内容を `tasks/task.md` と必要な seed に反映する
  - `safe_to_resume=true/false` を明示して、`y` で再開してよいかを返す
- ここではやらないこと:
  - `run-state.json` や `events.jsonl` の直接編集
  - broad な再要件定義を最初からやり直すこと
  - ユーザー確認なしの自動再開

#### `relay-dev-seed-author`

要件整理の結果を、relay-dev が起動できる入力に落とし込む skill です。

- 役割:
  - `tasks/task.md` を今回の依頼に合わせて整形する
  - 必要なら `outputs/phase0_context.md` / `outputs/phase0_context.json` を作る
  - UI 作業では `DESIGN.md` や visual reference を `design_inputs` / `visual_constraints` に要約する
  - 既存の `Phase0` seed が valid で再利用可能なら import 前提で使い回す
- 重要な考え方:
  - `outputs/phase0_context.*` は pre-run seed であり、run 開始後の canonical source ではない
  - valid な seed があるのに、毎回再生成を強制しない
  - `phase0_context.json` は validator を通る機械可読 contract として扱う
  - `DESIGN.md` がある場合は `config/settings.yaml` の `paths.design_file`、未設定なら `paths.project_dir/DESIGN.md` を見に行く
- 向いている場面:
  - `front-door` の会話が固まり、task と seed を作る段階
  - 既存 seed を修正・再利用したい段階

#### `relay-dev-operator-launch`

control plane の安全な起動・再開・確認を担当する skill です。  
「どのコマンドを打つべきか」を canonical state から判断します。

- 役割:
  - `new` / `resume` / `step` / `show` / `start-agents.ps1` のどれを使うか決める
  - `tasks/task.md` と seed の準備状況を見て、まだ足りなければ前段 skill へ戻す
  - visible terminal から再開したい場合は `start-agents.ps1` 系の導線を選ぶ
  - 停止後に stale job recovery を前提としてどの command で戻すかを判断する
- 向いている場面:
  - 新しい run を作りたい
  - 既存 run を再開したい
  - まず現在の正本 state を確認したい
- 重要な考え方:
  - `queue/status.yaml` より `runs/<run-id>/run-state.json` を優先して見る
  - requirements が粗ければ `front-door`、task / seed が未整備なら `seed-author` へ戻す

#### `relay-dev-troubleshooter`

run の不整合や provider 失敗を、正本 state から read-only で調べる skill です。

- 役割:
  - `run-state.json`、`events.jsonl`、job metadata、stdout/stderr を読み、何が止まっているかを説明する
  - `show` と artifact の見え方が食い違うときの原因を絞る
  - approval 待ち、phase 不整合、provider エラーを切り分ける
- 向いている場面:
  - run が止まった
  - provider 出力が失敗した
  - state と `outputs/` の見え方が噛み合わない
- 重要な考え方:
  - まず canonical state を読む
  - reflex 的に `runs/` や artifact を書き換えない

#### `relay-dev-course-corrector`

「仕様変更」「やっぱり戻したい」「いったん止めたい」のような change management を扱う skill です。

- 役割:
  - 変更要求を `rollback` / `pause` / `pivot` / `restart` に分類する
  - `tasks/task.md`、`outputs/phase0_context.*`、current run、既存 artifact への影響を整理する
  - 同じ run を続けるか、新しい run に切るか、どの skill に渡すべきかを判断する
  - `pause` のときは stop-now / stop-at-boundary / hold-and-decide を切り分ける
- 向いている場面:
  - 途中で仕様変更が入った
  - 現在の run を止めたいが履歴は残したい
  - 要件を維持したまま rollback したい
- 重要な考え方:
  - 障害調査と方針変更を混同しない
  - old run を reflex 的に消さず、traceability を優先する

### 停止・再開の基本ルール

- 「何が壊れたか」を調べるのは `relay-dev-troubleshooter`
- 「いったん止めたい」を整理するのは `relay-dev-course-corrector`
- 実際に止めた後で `resume` / `step` / `start-agents.ps1 -ResumeCurrent` を選ぶのは `relay-dev-operator-launch`
- visible worker を止めても `run-state.json` に `active_job_id` が一時的に残ることがある
- この stale state は次回の `resume` / `step` で recovery される前提で扱い、run file を手で直さない

### どう使い分けるか

- まだ何を作るか曖昧: `relay-dev-front-door`
- `Phase2` で質問が止まったので、要約して一緒に決めたい: `relay-dev-phase2-clarifier`
- 何を作るかは決まったので task / seed にしたい: `relay-dev-seed-author`
- いま何を実行すべきか決めたい: `relay-dev-operator-launch`
- run が変だ、止まった、壊れた: `relay-dev-troubleshooter`
- 途中で方針を変えたい、止めたい、やり直したい: `relay-dev-course-corrector`

### 推奨フロー

1. 人間が AI に「relay-dev を使ってこのタスクを進めたい」と伝える
2. AI が `relay-dev-front-door` に従って、要件の不足分だけを質問する
3. AI が `relay-dev-seed-author` に従って `tasks/task.md` を記入する
4. AI が必要なら `relay-dev-seed-author` に従って `outputs/phase0_context.md` / `outputs/phase0_context.json` を作る
5. AI が `relay-dev-operator-launch` に従って `new` / `resume` / `start-agents.ps1` のどれを使うか判断する
6. AI が起動コマンドを実行し、`run_id` と現在 phase を人間に返す
7. `Phase2` で質問 pause に入った場合は、AI が `relay-dev-phase2-clarifier` に従って質問を要約し、回答を input に反映してから `y` で再開する

### 人間にやらせない前提

この運用では、次の作業は原則として AI が行います。

- `tasks/task.md` の整形
- `Phase0` seed の生成
- `app/cli.ps1 new` / `resume` / `step` の選択
- `start-agents.ps1` の起動
- 正本 state の確認と要約

人間は、要件決定と判断だけに集中します。

## フェーズ構成

現在の標準フローは以下です。

```text
Phase0  -> Phase1 -> Phase3 -> Phase3-1
                \-> Phase2 (clarification fallback only) -> Phase3
        -> Phase4 -> Phase4-1
        -> Phase5 -> Phase5-1 -> Phase5-2
        -> Phase6 -> Phase7 -> Phase7-1 -> Phase8
```

役割の割り当ては phase 単位で固定されています。

- `implementer`: `Phase0`, `Phase1`, `Phase2`, `Phase3`, `Phase4`, `Phase5`, `Phase7-1`, `Phase8`
- `reviewer`: `Phase3-1`, `Phase4-1`, `Phase5-1`, `Phase5-2`, `Phase6`, `Phase7`

通常運用では `Phase1` の `unresolved_questions` が空なら `Phase3` に直接進みます。  
`Phase2` は、requirements / seed / repo 調査だけでは吸収しきれなかった clarification debt が残る場合にだけ入る fallback です。
`Phase2` の `unresolved_blockers` が残った場合は、その場で human clarification pause に入り、回答を反映したあと `y` で `Phase0` から再開します。
このときの対話回収は `relay-dev-phase2-clarifier` を使う想定です。

ただし、現在の実行モデルは「常駐 implementer / reviewer が baton を受け渡すこと」自体を正本にはしていません。  
実際の進行は `WorkflowEngine` が `run-state.json` を見て次 action を決め、必要な job を dispatch する形です。

## 正本と互換投影

リファクタ後の relay-dev でいちばん重要なのはここです。

| 種別 | 役割 | 扱い |
|---|---|---|
| `runs/<run-id>/run-state.json` | 現在状態の正本 | engine が更新 |
| `runs/<run-id>/events.jsonl` | append-only event log | engine が追記 |
| `runs/<run-id>/artifacts/...` | canonical artifact store | validator / transition の入力 |
| `runs/current-run.json` | 現在の run ポインタ | `new` / `resume` で更新 |
| `queue/status.yaml` | 互換ステータス表示 | 正本から自動生成 |
| `outputs/` | 互換 artifact projection | 正本から自動生成 |

注意点:

- `queue/status.yaml` は直接編集しない
- `outputs/` は source of truth ではない
- 状態確認や障害調査では常に `runs/<run-id>/...` を優先する
- 同一 run への二重 `step` は `runs/<run-id>/run.lock` により直列化される

## Phase0 の扱い

`Phase0` は「今回の run に必要な共通前提を整えるフェーズ」です。  
`tasks/task.md` は全フェーズ共通の external input として必須で、`Phase0` はそこから `phase0_context.md` / `phase0_context.json` を作ります。

UI 作業では、`DESIGN.md` も optional な external input として扱えます。  
`DESIGN.md` の探索順は、`config/settings.yaml` の `paths.design_file` があればその値、未設定なら `paths.project_dir/DESIGN.md` です。

### 役割分担

- `tasks/task.md`: 今回やること
- `phase0_context.md`: 人間向けの共通前提まとめ
- `phase0_context.json`: 後続フェーズで使う構造化 contract

`phase0_context.json` には、通常の `project_summary` や `constraints` に加えて、必要に応じて次の visual seed も入ります。

- `design_inputs`: `DESIGN.md` や reference から抽出した設計上の手掛かり
- `visual_constraints`: 守るべき見た目や UI 上の制約

### Seed import

リファクタ後は、`Phase0` を毎回 AI に再生成させる必要はありません。  
run 開始前に以下の 2 ファイルが揃っていて、`phase0_context.json` が validator を通る場合、`app/cli.ps1 step` はそれを import して `SeedPhase0` として扱い、そのまま `Phase1` へ進みます。

- `outputs/phase0_context.md`
- `outputs/phase0_context.json`

つまり、

- seed がない場合: AI が `Phase0` を生成
- seed が妥当な場合: `Phase0` は import され、再生成しない

という動きです。

生成後の canonical artifact は以下に保存されます。

- `runs/<run-id>/artifacts/run/Phase0/phase0_context.md`
- `runs/<run-id>/artifacts/run/Phase0/phase0_context.json`

## 設計境界とデザインの流れ

設計境界と visual design は、どちらも後続フェーズで使い回せる contract として扱います。

### カプセル化の流れ

1. `Phase3` が `module_boundaries`、`public_interfaces`、`allowed_dependencies`、`forbidden_dependencies`、`side_effect_boundaries`、`state_ownership` を定義する
2. `Phase3-1` が「境界が曖昧ではないか」「越境を誘発する設計になっていないか」を reviewer 観点で確認する
3. `Phase4` が各 task の `boundary_contract` に必要部分だけを落とし込む
4. `Phase5` がその `boundary_contract` を拘束条件として実装する
5. `Phase5-1` が task contract にない越境をしていないかを証拠付きで確認する

これにより、カプセル化は README 上の方針ではなく、artifact schema と reviewer gate によって維持されます。

### デザインの流れ

1. `DESIGN.md` や visual reference があれば、`Phase0` が `design_inputs` と `visual_constraints` に要約する
2. `Phase1` がそれを `visual_acceptance_criteria` に変換する
3. `Phase3` / `Phase4` が UI task ごとの `visual_contract` を組み立てる
4. `Phase5` が `visual_contract` を守って実装する
5. `Phase5-1` が見た目の整合性を reviewer 観点で確認する

このため、`DESIGN.md` は単なる参考メモではなく、frontend task の acceptance と review に効く入力として扱えます。

## 実行モデル

### CLI が正面入口

日常運用では、まず `app/cli.ps1` を入口として見てください。

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 new
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 resume
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 step
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 show
```

各コマンドの役割:

- `new`: 新しい run を作成して `runs/current-run.json` を更新
- `resume`: 既存 run を再開
- `step`: 現在の state を見て 1 step 進める
- `show`: 現在の run-state を表示

補足:

- `step` は run 単位で排他制御される
- 同じ run に別の `step` が重なると、後続の `step` は lock エラーで停止する
- 排他制御の実体は `runs/<run-id>/run.lock` で、正本 state の書き込み競合を防ぐ

### Wrapper の位置づけ

`start-agents.*` と `agent-loop.ps1` は、今は CLI を呼ぶ薄い wrapper です。

#### Windows

[start-agents.ps1](./start-agents.ps1) は次の順で動きます。

1. `app/cli.ps1 new` または `resume` で run を初期化
2. stale な relay-dev worker を停止
3. Windows Terminal を 1 タブ起動
4. `agent-loop.ps1 -Role orchestrator` を実行

つまり、Windows では現在「単一 orchestrator worker」を起動するのが基本です。  
旧 README にあった「左右 2 画面で implementer / reviewer を常駐させる説明」は実態と一致しません。

#### Linux / macOS

[start-agents.sh](./start-agents.sh) は tmux session を作成し、次の 2 pane を起動します。

- `agent-loop.ps1 -Role orchestrator -InteractiveApproval`
- `watch-run.ps1`

Linux / macOS でも、現在の基本形は visible な単一 orchestrator worker です。  
承認待ちは worker pane で対話入力し、monitor pane では current run と推奨コマンドを確認します。  
設計上の正本はあくまで CLI / engine 側です。

### `agent-loop.ps1`

[agent-loop.ps1](./agent-loop.ps1) は polling loop として動作します。

- `orchestrator` は常に `step` を試みる
- `implementer` / `reviewer` は `run-state.json` の `current_role` が自分に一致するときだけ `step` を呼ぶ
- run が `completed` / `failed` / `blocked` なら待機

## セットアップ

### 必須

- PowerShell 7 以上必須（`pwsh`）
- AI provider CLI
- Windows の場合は `wt.exe`
- Linux / macOS の場合は `tmux`

### provider CLI

デフォルト設定は Codex CLI です。

```yaml
cli:
  command: "codex"
  flags: "--ask-for-approval never exec --skip-git-repo-check --sandbox workspace-write"
```

設定ファイル:

- [config/settings.yaml](./config/settings.yaml): 現在の実行設定
- [config/settings-codex.yaml.example](./config/settings-codex.yaml.example): Codex 用サンプル
- [config/settings-gemini.yaml.example](./config/settings-gemini.yaml.example): Gemini 用サンプル
- [config/settings-claude.yaml.example](./config/settings-claude.yaml.example): Claude Code 用サンプル
- [config/settings-copilot-cli.yaml.example](./config/settings-copilot-cli.yaml.example): Copilot 用サンプル

Windows で visible worker を起動する例:

```powershell
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-claude.yaml.example
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-copilot-cli.yaml.example
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-gemini.yaml.example
```

## 最短の使い方

### Skill ベースで起動する場合

推奨:

1. AI に `relay-dev-front-door` を読ませる
2. 対話で要件を決める
3. AI に `relay-dev-seed-author` を使って `tasks/task.md` と必要な `Phase0` seed を作らせる
4. AI に `relay-dev-operator-launch` を使って `pwsh -NoLogo -NoProfile -File .\start-agents.ps1` を実行させる
5. AI から `run_id`、現在 phase、次の確認ポイントを受け取る

### 手動で確認したい場合

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 show
Get-Content .\runs\<run-id>\events.jsonl
Get-Content .\dashboard.md
```

### 再開する場合

```powershell
pwsh -NoLogo -NoProfile -File .\app\cli.ps1 resume
```

または:

```powershell
pwsh -NoLogo -NoProfile -File .\start-agents.ps1
```

### 止まったり方針が変わった場合

- run が止まった、provider が失敗した、state と表示が噛み合わない: `relay-dev-troubleshooter`
- `Phase2` で質問待ちになったので、内容を要約して対話で決めたい: `relay-dev-phase2-clarifier`
- 途中で仕様変更が入った、いったん止めたい、やり直したい: `relay-dev-course-corrector`

## 人間レビュー

デフォルトでは人間レビューが有効です。

```yaml
human_review:
  enabled: true
  phases:
    - Phase3-1
    - Phase4-1
    - Phase7
```

選択肢:

- `y`: 承認
- `n`: 拒否
- `c`: 条件付き承認
- `s`: 今回のみスキップ
- `q`: 中断

高リスクな変更では有効のまま運用することを推奨します。

## ディレクトリ構成

現在の重要パスだけに絞ると以下です。

```text
relay-dev/
├── app/
│   ├── cli.ps1
│   ├── core/
│   ├── execution/
│   ├── phases/
│   └── prompts/
├── config/
├── docs/
├── examples/
│   ├── README.md
│   └── gemini_video_plugin/  # legacy example; not portfolio proof
├── outputs/
├── queue/
├── runs/
│   ├── current-run.json
│   └── <run-id>/
│       ├── run-state.json
│       ├── events.jsonl
│       ├── jobs/
│       └── artifacts/
├── skills/
├── tasks/
├── agent-loop.ps1
├── watch-run.ps1
├── start-agents.ps1
└── start-agents.sh
```

### 補足

- 旧 `templates/` / `instructions/` は削除済みで、prompt の正本は `app/prompts/` に統一されている
- `outputs/` は compatibility projection
- canonical artifact は `runs/<run-id>/artifacts/...` にある

## artifact の保存先

### Canonical

- run-scoped: `runs/<run-id>/artifacts/run/<Phase>/<artifact-id>`
- task-scoped: `runs/<run-id>/artifacts/tasks/<task-id>/<Phase>/<artifact-id>`

### Compatibility projection

- `outputs/<compatibility-name>/<artifact-id>`
- `outputs/<compatibility-name>/tasks/<task-id>/<artifact-id>`

`compatibility-name` は以下の優先順で決まります。

1. `task_id`（`task-main` 以外）
2. `tasks/task.md` のタイトル由来名
3. `run_id`

### 言語ポリシー

- Markdown artifact: 人間向けドキュメントとして日本語が既定
- JSON artifact: key / schema を維持する機械可読 contract

## ログと調査ポイント

問題が起きたときは、まず次を見ます。

1. `pwsh -NoLogo -NoProfile -File .\app\cli.ps1 show`
2. `runs/<run-id>/run-state.json`
3. `runs/<run-id>/events.jsonl`
4. `runs/<run-id>/jobs/<job-id>/`
5. `dashboard.md`

`queue/status.yaml` は確認用には使えますが、調査の正本ではありません。

## CI と回帰テスト

CI では少なくとも以下を実行します。

- PowerShell スクリプト構文チェック
- [tests/regression.ps1](./tests/regression.ps1) による最小回帰テスト

ローカル実行:

```powershell
pwsh -NoLogo -NoProfile -File tests/regression.ps1
```

## 実例

公開用 examples の方針は [examples/README.md](./examples/README.md) を参照してください。
既存の [examples/gemini_video_plugin](./examples/gemini_video_plugin) はリファクタ前の旧成果物であり、portfolio の主証拠としては扱いません。

## よくある運用上の注意

### `queue/status.yaml` を直接直してよいか

いいえ。互換表示なので、正本は `runs/<run-id>/...` です。

### `outputs/phase0_context.*` は正本か

いいえ。run 前の seed としては使えますが、run 開始後の canonical artifact は `runs/<run-id>/artifacts/run/Phase0/...` です。

### `Phase0` を毎回 AI に再生成させるべきか

いいえ。妥当な seed があるなら import して `Phase1` から始める方が自然です。

### relay-dev の操作を人間が毎回手でやるべきか

いいえ。推奨は relay-dev skill を読んだ AI に起動準備と起動まで任せ、人間は要件の対話とレビュー判断に集中する運用です。

### README の古い説明と食い違うときは何を信じるか

次の順で見てください。

1. `app/cli.ps1`
2. `app/core/*`
3. `app/phases/phase-registry.ps1`
4. `tests/regression.ps1`
5. `docs/architecture-redesign.md`

## ライセンス

MIT License
