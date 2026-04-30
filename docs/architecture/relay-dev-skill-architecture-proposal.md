# relay-dev skill 分割案

## 目的

relay-dev を扱う AI の責務を、より細かい skill に分割する方針を整理する。  
狙いは次の 3 つ。

1. 人間は要件決定とレビュー判断に集中する
2. AI は要件整理から起動、運用、調査までを一貫して担当する
3. `Phase2` のような機械的な質問フェーズを、より自然な対話型 skill に置き換える

## 背景

現在の relay-dev では、operator skill に以下の責務が集まりやすい。

- 要件の聞き取り
- `tasks/task.md` の整形
- `Phase0` seed の作成
- `new` / `resume` / `step` / `start-agents.ps1` の選択
- 進捗確認
- 障害調査

この形でも運用は可能だが、責務が広すぎるため次の問題が出やすい。

- どの場面で何を優先すべきかが曖昧になる
- 対話型の要件整理と run 操作が 1 つの skill に混ざる
- 問題発生時の調査手順が埋もれる
- `Phase2` の質問と skill 側の質問が二重化しやすい

## 基本方針

skill は、relay-dev を「人間が手で動かす道具」にするのではなく、「AI が運用を引き受けるための専門分業」に寄せる。

役割分担の原則:

- 人間:
  - やりたいことを AI に伝える
  - 必要な判断を下す
  - 人間レビューの承認 / 拒否を行う
- AI:
  - 要件を整理する
  - 不足情報を質問する
  - `tasks/task.md` や `Phase0` seed を整える
  - relay-dev を起動する
  - run 状態を監視し、必要なら調査する

## 推奨する導入順

概念上は 5 skill 前後に分ける案がよいが、最初から細かく分けすぎると運用が不安定になりやすい。  
そのため、最初の実装は **4 skill 構成** から始め、必要になったらさらに分割する方針を推奨する。

### 初期推奨の 4 skill

1. `front-door`
2. `seed-author`
3. `operator-launch`
4. `troubleshooter`

この構成では、`requirements-intake` と `requirements-clarifier` を最初は 1 つの `front-door` skill にまとめる。  
理由は、人間から見ると両者はどちらも「AI と会話しながら要件を固める時間」であり、別 skill に分けても UX 上の区切りが見えにくいからである。

### 将来の分割先

`front-door` が大きくなってきたら、次の 2 つに分ける。

- `requirements-intake`
- `requirements-clarifier`

つまり、**概念上は 5 分割、導入上は最初 4 分割** を基本方針とする。

## 提案する skill 構成

### 0. 初期構成でのまとめ方

最初の導入では、次のようにまとめて扱う。

- `requirements-intake` + `requirements-clarifier` → `front-door`
- `seed-author` → 独立
- `operator-launch` → 独立
- `troubleshooter` → 独立

この形なら、人間から見た入口は 1 つに保ちつつ、起動と調査は分離できる。

### 1. 要件定義 skill

仮称:

- `relay-dev-requirements-intake`

主責務:

- ユーザーとの対話で依頼の骨子を決める
- 何を作るか、何を変えるか、何を変えないかを整理する
- 制約、非目標、優先順位、完了条件を明確にする

期待する出力:

- `tasks/task.md` に落とし込める要件メモ
- 未確定事項の一覧

この skill がやらないこと:

- run の起動
- state 調査
- provider トラブルシュート

### 2. 質問生成・要件反映 skill

仮称:

- `relay-dev-requirements-clarifier`

主責務:

- repo と現在の要求を見て、不足している確認事項を作る
- 機械的な羅列ではなく、対話しやすい質問に変換する
- 回答を `tasks/task.md` や `open_questions` に反映する

期待する出力:

- 優先度付きの確認質問
- 反映済みの `tasks/task.md`
- 必要なら `phase0_context.json` の `open_questions`

この skill の意義:

- `Phase2` の質問を run 中の機械処理に任せず、起動前の自然な対話として前倒しできる
- ユーザーは phase に縛られず、AI と普通に要件を詰められる

### 2.5. front-door skill

初期導入時の推奨形として、上の 2 skill をまとめた入口 skill を用意する。

仮称:

- `relay-dev-front-door`

主責務:

- ユーザーの依頼を会話で整理する
- 不足情報を、対話しやすい質問として聞く
- `tasks/task.md` に入るべき内容を固める
- `seed-author` へ handoff できる状態まで持っていく

期待する出力:

- 整理済み requirements
- constraints / non-goals
- unresolved questions
- `task.md` 草案、またはその材料

この skill の利点:

- ユーザーは最初に 1 つの skill だけ呼べばよい
- `intake` と `clarifier` の境界を意識しなくてよい
- 将来的に 2 skill に分離しても、入口 UX を保ちやすい

### 3. ドキュメント生成 skill

仮称:

- `relay-dev-seed-author`

主責務:

- `tasks/task.md` を最終形に整える
- `outputs/phase0_context.md`
- `outputs/phase0_context.json`
  を生成または更新する
- valid な seed かどうかを確認し、import 可能な状態まで持っていく

期待する出力:

- 起動可能な `tasks/task.md`
- validator を通す `phase0_context.json`
- 人間が読める `phase0_context.md`

この skill がやらないこと:

- run の常時監視
- 調査ログの詳細解析

### 4. コマンド実行・運用 skill

仮称:

- `relay-dev-operator-launch`

主責務:

- canonical state を見て `new` / `resume` / `step` / `show` / `start-agents.ps1` を選ぶ
- 実際にコマンドを実行する
- 現在の `run_id`、phase、role、blocker を要約して返す

主に扱うコマンド:

- `.\app\cli.ps1 new`
- `.\app\cli.ps1 resume`
- `.\app\cli.ps1 step`
- `.\app\cli.ps1 show`
- `.\start-agents.ps1`

この skill の前提:

- `tasks/task.md` はある程度整っている
- 必要なら `Phase0` seed も準備済み

### 5. トラブルシューティング skill

仮称:

- `relay-dev-troubleshooter`

主責務:

- run が止まった、想定外の phase にいる、approval 待ちが崩れた、provider が失敗した、などの調査
- `run-state.json`, `events.jsonl`, `jobs/`, prompt package, provider 出力を確認する
- 原因仮説と安全な対処を提案する

優先的に見るもの:

1. `runs/current-run.json`
2. `runs/<run-id>/run-state.json`
3. `runs/<run-id>/events.jsonl`
4. `runs/<run-id>/jobs/`
5. `.\app\cli.ps1 show`

この skill の注意点:

- `queue/status.yaml` を正本として扱わない
- run file を手で書き換えて無理に進めない
- まず「読む」、次に「説明する」、最後に「必要なら安全に操作する」

### 5.5. 変更管理・方針転換 skill

必須ではないが、`troubleshooter` とは別に「戻す」「止める」「方針を変える」を安全に扱う skill を置く価値が高い。

仮称:

- `relay-dev-course-corrector`
- `relay-dev-change-manager`

主責務:

- 「違ったので戻したい」「途中で方針を変えたい」「この run はいったん止めたい」を分類する
- 現在の run、`task.md`、seed、生成済み artifact のどこに影響するかを要約する
- 破壊的に巻き戻す前に、安全な選択肢を提案する
- 必要なら、方針変更後の `task.md` 更新や再開方法の案を示す

この skill が主に扱う判断:

- いまの run を継続する
- `task.md` を更新して同じ run を続ける
- 現在の run は残し、新しい run としてやり直す
- 生成済み artifact は保持しつつ、要件だけ切り替える
- 単純な障害ではなく、変更要求として扱う

この skill の意義:

- `troubleshooter` が「壊れた理由を調べる」役だとすると、こちらは「決め直したいときに安全に方向転換する」役になる
- 障害対応と変更管理を分けることで、ユーザーが「困っている」のか「変えたい」のかを自然に扱い分けられる
- 方針転換時に run file を直接いじるような危険な近道を避けやすくなる

導入方針:

- 最初は `troubleshooter` の一部として試作してもよい
- 利用頻度が高ければ独立 skill として分離する

### 6. 読み取り専用の observer skill

必須ではないが、将来的には「読むだけ」の skill を独立させる余地がある。

仮称:

- `relay-dev-run-observer`

主責務:

- `show`
- `run-state.json`
- `events.jsonl`
  を読んで current state を要約する
- run を変更せず、人間に現状把握だけを返す

この skill を分ける利点:

- launch skill から「読むだけ」責務を外せる
- 監視や日次確認を軽く行える
- run を誤って進める危険を下げられる

## skill 間の想定フロー

標準フローは次のように分ける。

1. `requirements-intake`
   - ユーザーの依頼を整理する
2. `requirements-clarifier`
   - 足りない点だけ質問する
3. `seed-author`
   - `task.md` と `Phase0` seed を整える
4. `operator-launch`
   - relay-dev を起動または再開する
5. `troubleshooter`
   - 問題が起きたときだけ呼ぶ
6. `course-corrector`
   - 戻したい、止めたい、方針を変えたいときに安全な進め方を決める

この分割により、

- 対話
- 文書化
- 実行
- 変更管理
- 調査

の責務を分離できる。

### 初期導入時の実務フロー

初期の 4 skill 構成では、実務上は次の流れを推奨する。

1. `front-door`
   - 要件整理と質問をまとめて行う
2. `seed-author`
   - `task.md` と `Phase0` seed を整える
3. `operator-launch`
   - `new` / `resume` / `start-agents.ps1` を選んで起動する
4. `troubleshooter`
   - 問題発生時だけ呼ぶ

必要ならこの途中または後段で、

- `course-corrector`
  - やり直し、巻き戻し、方針転換を安全に扱う

を追加する

## skill 間の handoff contract

skill を分けるなら、引き渡しの最小 contract を先に決めておくべきである。  
これがないと、責務を分けても曖昧さが別の場所へ移るだけになる。

最低限そろえたい handoff 項目:

- `request_summary`
- `requirements`
- `constraints`
- `non_goals`
- `open_questions`
- `task_md_ready`
- `phase0_seed_ready`
- `recommended_command`

変更管理まで視野に入れるなら、次もあると便利:

- `change_request`
- `impact_summary`
- `supersedes_run_id`
- `recommended_recovery_action`

### 例

- `front-door` → `seed-author`
  - requirements と open questions を渡す
- `seed-author` → `operator-launch`
  - `task_md_ready=true`
  - `phase0_seed_ready=true|false`
  - `recommended_command=start-agents.ps1|new|resume`
- `operator-launch` → `troubleshooter`
  - `run_id`
  - current phase
  - observed blocker
- `operator-launch` or `troubleshooter` → `course-corrector`
  - `run_id`
  - current phase
  - change_request
  - impact_summary

## 開始条件と完了条件

各 skill に、少なくとも開始条件と完了条件を持たせるべきである。

### 例: `front-door`

- 開始条件:
  - ユーザーの依頼がある
- 完了条件:
  - 要件、制約、非目標、未確定事項が整理されている

### 例: `seed-author`

- 開始条件:
  - `front-door` から requirements が渡されている
- 完了条件:
  - `tasks/task.md` が更新済み
  - `phase0_context.json` が validator を通る、または不足理由が明示されている

### 例: `operator-launch`

- 開始条件:
  - `task.md` が整っている
- 完了条件:
  - relay-dev が起動または再開されている
  - `run_id` と current phase を返している

### 例: `troubleshooter`

- 開始条件:
  - run の異常、停止、迷子状態がある
- 完了条件:
  - 原因仮説と安全な次アクションを提示している

### 例: `course-corrector`

- 開始条件:
  - ユーザーが「戻したい」「止めたい」「別案で進めたい」などの変更要求を出している
- 完了条件:
  - 変更要求の種類が整理されている
  - 影響範囲と安全な選択肢が提示されている
  - 続行、停止、再起動、別 run 化のどれを選ぶべきか提案されている

## `Phase2` 廃止案

### 問題意識

現在の `Phase2` は「不足情報回収」のフェーズとして存在するが、要件の不足分を機械的に質問する役割は、skill 側の対話で吸収できる可能性が高い。

特に次の点で、phase より skill の方が自然である。

- ユーザーは phase 名を意識せず普通に会話したい
- AI は repo を読んだうえで文脈のある質問を作れる
- run 開始後に質問が出るより、起動前に聞けた方がスムーズ
- `task.md` と `Phase0` seed の品質を、run 前に上げられる

### 廃止案の方向性

#### 案 A: 段階的廃止

- まずは skill 側で対話質問を前倒しする
- `Phase2` は互換目的で残す
- 実運用では、`Phase2` に到達するケースを減らす

利点:

- 既存の engine や phase 定義を大きく壊さない
- 実績を見ながら廃止判断ができる

#### 案 A' : fallback 化

- `Phase2` は標準フローの中心ではなくす
- 通常は skill 側の対話質問で不足情報を埋める
- それでも重大な `open_questions` が残った場合だけ、`Phase2` を clarification fallback として使う

利点:

- UX を悪化させず安全弁を残せる
- いきなり phase 定義を壊さずに済む
- 「質問フェーズ」ではなく「clarification debt の回収フェーズ」として再定義できる

#### 案 B: 標準フローから外す

- 標準遷移を `Phase1 -> Phase3` に変更
- 不足情報回収は skill 側の対話へ移す
- `Phase2` は legacy compatibility としてのみ残す

利点:

- フェーズ構造がシンプルになる
- 起動前対話の思想ときれいに一致する

懸念:

- 既存テストや prompt 設計の見直しが必要
- `Phase2` を前提にしている artifact や説明の整理が必要

### 推奨方針

現時点では、まず **案 A' : fallback 化** が現実的。  
通常運用では skill 側の対話で不足情報を回収し、`Phase2` は未解決の clarification debt が残ったときの安全弁として扱う。  
その運用が安定したあとで、`Phase2` を標準フローから外す判断をする。

## この分割で期待する効果

### 1. 人間の負担が減る

人間はファイル編集や起動コマンド選択をしなくてよくなる。  
会話で要求を決め、レビュー判断を返すことに集中できる。

### 2. AI の振る舞いが安定する

「今は要件整理の時間なのか」「run を動かす時間なのか」「方針転換を扱う時間なのか」「障害調査の時間なのか」が skill 単位で明確になる。

### 3. `task.md` と Phase0 の品質が上がる

run 開始前に、対話型の確認と文書化を終えやすくなる。

### 4. phase と skill の責務が整理される

- phase: run 中に engine が制御する内部進行
- skill: run の外側で AI が人間と協調する運用能力

という分担が明確になる。

## 評価指標

この案が良かったかを判断するため、次の指標を観察対象にする。

- `Phase2` 到達率
- 起動前に AI が行った質問数
- `open_questions` の残件数
- review 差し戻し率
- 起動後の手戻り率
- 方針転換後の再起動率
- トラブルシュート発火率

これらを見ることで、

- skill 側の対話で十分に要件が詰められているか
- `Phase2` を弱めても問題ないか
- skill 分割が実際に運用改善につながっているか

を判断しやすくなる。

## 導入ステップ案

### Step 1

- この文書を方針メモとして保存する
- 既存 operator skill を、より小さい skill 群へ分割する前提を合意する

### Step 2

- `front-door`
- `seed-author`
- `operator-launch`
- `troubleshooter`

の 4 skill を先に試作する

必要なら次段階で、

- `requirements-intake`
- `requirements-clarifier`

へ分割する

### Step 3

- README を「AI が対話から起動まで担う」前提でさらに揃える
- skill ごとの trigger と handoff を明記する

### Step 4

- `Phase2` を実運用でどれくらい使わなくなるか観察する
- 利用頻度、質問品質、手戻り率を見る

### Step 5

- 必要なら phase registry と prompt を見直し、`Phase2` の縮退または廃止を進める

## open questions

- skill 間の handoff をファイルで持つか、会話上の約束に留めるか
- `requirements-clarifier` と `seed-author` を分けるべきか、1 skill にまとめるべきか
- `operator-launch` と `troubleshooter` を分けた方が運用上どこまで安定するか
- `course-corrector` を `troubleshooter` から独立させる閾値はどこか
- `Phase2` を完全廃止したとき、既存 artifact contract をどう整理するか

## 結論

relay-dev は、1 つの operator skill に全部を詰め込むより、

- 要件整理
- 質問生成と反映
- 文書生成
- コマンド実行
- 変更管理 / 方針転換
- トラブルシューティング

の 6 つ前後に分けた方が、AI がより自然に人間を支援できる。  
ただし導入時は、`front-door` を含む 4 skill 構成から始める方が現実的である。  
とくに不足情報回収は、`Phase2` の機械的な質問よりも、skill による対話型の質問へ移した方が UX がよい可能性が高い。  
また、実運用では「壊れた」ケースだけでなく「変えたい」ケースも多いため、`course-corrector` のような変更管理 skill を `troubleshooter` とは別軸で検討する価値がある。  
`Phase2` はすぐに消すのではなく、まず clarification fallback として位置づけるのが安全である。
