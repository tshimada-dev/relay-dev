# Skills

relay-dev は AI が canonical state を読み書きせずに安全に運用できるよう、**役割を分割した 6 個の同梱 skill** を `skills/` 配下に持っています（運用記録用の `worklog` を含めて 7 個）。本書では各 skill の責任範囲・ハンドオフ規約・置き場所を説明します。

## 設計思想

- **1 skill = 1 関心事**: 要件整理 / 質問回収 / seed 作成 / 起動判断 / 障害調査 / 方針変更を分離する。
- **read-only と write を分ける**: troubleshooter は `runs/` を絶対に書き換えず、書き換えるのは operator-launch（CLI 経由）と seed-author（pre-run input）に限定する。
- **ハンドオフは Markdown / JSON で正規化**: 各 skill の出力は次 skill の入力として読みやすい形式に揃える。
- **会話の目的を 1 段に絞る**: 1 つの skill が要件整理から障害対応まで持つと、AI は会話のモードを取り違える。

## 配置

repo 内 (`relay-dev/skills/`) はバージョン管理用、Codex が実際に読むのは `$CODEX_HOME/skills/` 配下です。

```text
Windows: %USERPROFILE%\.codex\skills\<skill-name>\
Linux/macOS: ~/.codex/skills/<skill-name>/
```

ローカルで使うときは、必要な skill ディレクトリを Codex 側へコピーまたは symlink してください。skill のディレクトリ構造ルール:

```text
<skill-name>/
├── SKILL.md          # frontmatter (name, description) + 本文
├── agents/           # UI 用設定（例: openai.yaml）
├── references/       # 参照ドキュメント
├── scripts/          # 補助スクリプト（必要な場合）
└── assets/           # 出力素材（必要な場合）
```

`runs/`、`outputs/`、`queue/` のような runtime 領域には skill を置きません。

## 一覧

| Skill | カテゴリ | 入力 | 出力 |
| --- | --- | --- | --- |
| `relay-dev-front-door` | 要件整理 | 自然言語の依頼 | `request_summary` / `requirements` / `constraints` / `non_goals` / `open_questions` / `design_inputs` / `visual_constraints` |
| `relay-dev-phase2-clarifier` | 質問回収 | `phase2_info_gathering.*` の `unresolved_blockers` | 決定事項を反映した `tasks/task.md` / Phase0 seed、`safe_to_resume` |
| `relay-dev-seed-author` | seed 作成 | front-door 出力 / 既存 seed | `tasks/task.md`、`outputs/phase0_context.{md,json}` |
| `relay-dev-operator-launch` | 起動判断 | canonical state | 実行コマンド、`run_id`、現在 phase |
| `relay-dev-troubleshooter` | 障害調査 | `runs/<run-id>/` 全般 | 原因仮説と次手（read-only） |
| `relay-dev-course-corrector` | 方針変更 | 仕様変更要求 | `rollback` / `pause` / `pivot` / `restart` の判定と影響範囲 |
| `worklog` | 運用記録 | 直近の作業内容 | `docs/worklog/YYYY-MM-DD.md` の追記 |

## relay-dev-front-door

### 役割

要件がまだ曖昧な段階で、AI が壁打ち相手になって要件を具体化します。質問票を埋めるのではなく、tradeoff を提示して意思決定を進めます。

### 振る舞い

- repo を軽く読み、既知情報を踏まえて会話する
- UI 案件では `DESIGN.md`、画面参照、style direction の有無も intake する
- 1 ターン 1〜3 個の高レバレッジな質問だけを投げる
- 各ターンの最後に「いま何が決まっていて、何が未決か」を要約する
- 迷いに対しては選択肢と短い tradeoff を提示する

### しないこと

- `new` / `resume` / `step` の実行
- `tasks/task.md` や Phase0 seed の書き込み
- `runs/` を見た障害調査

## relay-dev-phase2-clarifier

### 役割

`Phase2` で `unresolved_blockers` が残ったときに、質問を要約してユーザーと対話で決め、結果を upstream input に反映する専用 skill です。

### 振る舞い

- current run の `phase2_info_gathering.*` を読んで質問を要約する
- 1 ターン 1〜3 問ずつ、選択肢と tradeoff を添えて対話する
- 決定事項を `tasks/task.md` と必要な seed に反映する
- `safe_to_resume=true/false` を明示し、`y` で再開してよいかを返す

### しないこと

- `run-state.json` / `events.jsonl` の直接編集
- 最初から要件を broad に再定義する
- ユーザー確認なしの自動再開

## relay-dev-seed-author

### 役割

front-door の正規化結果（または既存 seed）を、relay-dev が起動できる入力に落とし込みます。

### 振る舞い

- `tasks/task.md` を今回の依頼に合わせて整形する
- 必要なら `outputs/phase0_context.md` / `phase0_context.json` を作る
- UI 案件では `DESIGN.md` や visual reference を `design_inputs` / `visual_constraints` に要約する
- 既存 seed が valid なら **再生成せず import 前提で再利用**

### 重要な考え方

- `outputs/phase0_context.*` は pre-run seed であり、run 開始後の正本ではない
- valid な seed があるのに毎回再生成しない
- `phase0_context.json` は validator を通る機械可読 contract として扱う
- `DESIGN.md` の探索は `config/settings.yaml` の `paths.design_file`、未設定なら `paths.project_dir/DESIGN.md`

## relay-dev-operator-launch

### 役割

canonical state を読み、`new` / `resume` / `step` / `show` / `start-agents.ps1` のどれを使うべきかを判断して実行します。

### 振る舞い

- `runs/current-run.json` と `run-state.json` を見て、いま必要なコマンドを 1 つ決める
- `tasks/task.md` と seed の準備状況を見て、足りなければ `front-door` / `seed-author` に戻す
- visible terminal から再開したい場合は `start-agents.ps1 -ResumeCurrent` を選ぶ
- 停止後の stale `active_job_id` は次回 `resume` / `step` の recovery に任せる

### 重要な考え方

- `queue/status.yaml` より `runs/<run-id>/run-state.json` を優先して見る
- requirements が粗ければ `front-door`、task / seed が未整備なら `seed-author` へ戻す

## relay-dev-troubleshooter

### 役割

run の不整合や provider 失敗を、正本 state から **read-only** で調べます。

### 振る舞い

- `run-state.json` / `events.jsonl` / `jobs/<job-id>/` を読み、何が止まっているかを説明する
- `show` と artifact の見え方が食い違うときの原因を絞る
- approval 待ち、phase 不整合、provider エラー、validator failure を切り分ける

### 重要な考え方

- まず canonical state を読む
- reflex 的に `runs/` や artifact を書き換えない
- 修復 / 方針変更が必要と分かったら、`operator-launch` か `course-corrector` に渡す

## relay-dev-course-corrector

### 役割

「仕様変更」「やっぱり戻したい」「いったん止めたい」のような change management を扱います。

### 振る舞い

- 変更要求を `rollback` / `pause` / `pivot` / `restart` に分類する
- `tasks/task.md`、`outputs/phase0_context.*`、current run、既存 artifact への影響を整理する
- 同じ run を続けるか新しい run を切るか、どの skill に渡すべきかを判断する
- `pause` のときは `stop-now` / `stop-at-boundary` / `hold-and-decide` を切り分ける

### 重要な考え方

- 障害調査と方針変更を混同しない
- old run を反射的に消さず、traceability を優先する

## worklog

`docs/worklog/YYYY-MM-DD.md` への追記運用を司る skill です。`AGENTS.md` の指示に従い、substantive な変更のあとに必ず invoke します。記録項目は `Summary` / `Changed` / `Verified` / `Remaining` に正規化されます。

## 推奨フロー

```text
1. 人間: relay-dev でこのタスクを進めたい
2. AI: relay-dev-front-door で対話、要件を正規化
3. AI: relay-dev-seed-author で tasks/task.md と Phase0 seed を作る
4. AI: relay-dev-operator-launch で start-agents.ps1 を起動
5. (Phase2 で pause した場合) relay-dev-phase2-clarifier で対話回収 → y で再開
6. (run が止まった場合) relay-dev-troubleshooter で原因切り分け
7. (方針変更時) relay-dev-course-corrector で rollback / pause / pivot / restart を選定
8. AI: 重要な変更のあとに worklog skill で日次ログを更新
```

## skill 間の依存

```text
front-door ──► seed-author ──► operator-launch ──► (run が走る)
                                       │
                                       ▼
                                 (Phase2 pause)
                                       │
                                       ▼
                              phase2-clarifier ──► operator-launch (再開)

(run 中の異常)              (方針変更)
   troubleshooter             course-corrector
        │                            │
        └────────► operator-launch ──┘
```

## どう使い分けるか（早見表）

| 状況 | 使う skill |
| --- | --- |
| まだ何を作るか曖昧 | `front-door` |
| `Phase2` で質問が止まった | `phase2-clarifier` |
| 何を作るかは決まったので task / seed を作りたい | `seed-author` |
| いま何を実行すべきか決めたい | `operator-launch` |
| run が変だ、止まった、壊れた | `troubleshooter` |
| 方針を変えたい、止めたい、やり直したい | `course-corrector` |
| 作業が終わったので記録を残したい | `worklog` |
