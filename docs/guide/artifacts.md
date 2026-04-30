# Artifacts and Transactions

relay-dev の品質を支える中核は、**artifact を staging に書いてから validator を通し、すべて成功したら canonical に commit する** という transactional な流れです。本書ではその構造と、retry / repair に耐えるための設計を解説します。

## 用語

| 用語 | 意味 |
| --- | --- |
| canonical artifact | run の正本として `runs/<run-id>/artifacts/` 配下に置かれた成果物 |
| staging artifact | attempt 中に書き出される一時 artifact（commit されるまで canonical ではない） |
| attempt | ある phase 内の 1 回の provider job 実行。retry や repair で attempt 番号が増える |
| commit | staging を canonical に昇格させる atomic 操作 |

## 保存先

### Canonical

```text
runs/<run-id>/artifacts/
├── run/<Phase>/<artifact-id>           # run-scoped
└── tasks/<task-id>/<Phase>/<artifact-id>  # task-scoped (Phase5 系)
```

### Staging（attempt-scoped）

```text
runs/<run-id>/jobs/<job-id>/attempts/attempt-0001/...
```

attempt ごとに新しい staging path が作られるため、retry 時に前 attempt のゴミと混ざりません。`tests/regression.ps1` には「rerun prompt が attempt-scoped staging 配下を指すこと」を assertion で固定する OS 非依存の正規表現テスト（`[/\\]attempts[/\\]attempt-0001`）があります。

### Compatibility projection

```text
outputs/<compatibility-name>/<artifact-id>
outputs/<compatibility-name>/tasks/<task-id>/<artifact-id>
```

`compatibility-name` は次の優先順で決まります。

1. `task_id`（`task-main` 以外）
2. `tasks/task.md` のタイトル由来名
3. `run_id`

`outputs/` は engine が canonical state から再生成する **read-only な投影** です。直接編集しても上書きされます。

## Phase execution transaction

`app/core/phase-execution-transaction.ps1` が、1 phase 進行を以下の手順で 1 transaction にまとめます。

```text
1. attempt-preparation
   ├─ 既存 canonical artifact を archive 領域へ退避
   └─ 新しい attempt 用 staging dir を作る

2. job-context-builder
   └─ archive 後の最新 JSON snapshot を context に組み立てる
       （recovered rerun でも常に最新前段成果を読ませるため）

3. execution-runner → provider CLI
   └─ provider stdout は attempt 内 staging に書かれる

4. phase-validation-pipeline
   └─ artifact-validator を含む validator chain を順に実行
       ├─ pass  → 5a へ
       ├─ repairable invalid_artifact → 5b へ
       └─ non-repairable / job failure → run を blocked へ

5a. phase-completion-committer
    ├─ staging artifact を canonical へ atomic move
    ├─ run-state.json の phase 進行を更新
    ├─ events.jsonl に phase.transitioned を append
    └─ outputs/ / queue/status.yaml を再生成

5b. artifact-repair-transaction
    └─ 詳細は repairer.md を参照
```

このとき `run-state.json` には `active_attempt` ヘルパーが設けられ、`dispatching → running → committing → clear` の 4 ステートを 1 本の流れで管理します。half-write 中の中断は次回 `resume` で整合化されます。

## Validator

`app/core/artifact-validator.ps1` は phase ごとに JSON schema を強制します。

- 主な検査:
  - 必須フィールドの存在
  - enum / 列挙値の整合（例: `verdict ∈ {go, conditional_go, no_go}`）
  - 関連 field の整合（例: `verdict = conditional_go` のとき `security_checks[].status` に矛盾がないか）
  - reviewer 専用項目（`verdict`, `verdict_reason`, `evidence`）の構造
- 設計上の方針:
  - validator は **read-only**。落ちても canonical を上書きしない。
  - validation 結果は staging 上の artifact に対して下し、その判断結果に応じて commit / repair / fail へ振り分ける。

## Repairable と non-repairable の境界

`app/core/artifact-repair-policy.ps1` が validator failure を以下に分類します。

| 種別 | 例 | 扱い |
| --- | --- | --- |
| Repairable | フィールド名の typo、enum 値の不整合、required key 欠落、軽微な type 違い | repairer lane に乗せる |
| Non-repairable | provider job 自体の crash、staging への書き込みすら無い、product code の同時破壊が必要なケース | run を blocked にして人間に escalate |

詳細は [repairer.md](./repairer.md)。

## Recovered rerun

provider job が成功扱いで返ってきたが artifact が invalid_artifact のまま終わった run でも、`resume` で次のように復旧できます。

1. attempt-preparation が前 attempt の archive を作る。
2. job-context-builder が **archive 後の最新 JSON snapshot** を prompt context に載せる。
3. provider に再投入され、validator を通り直す。

これにより、commit 寸前で落ちた run も canonical を破壊せず再開できます。

## 言語ポリシー

- Markdown artifact: 人間向けドキュメントとして日本語が既定。
- JSON artifact: key / schema は機械可読 contract として原文（英語）維持。

両者は同じ「事実の二重表現」とみなし、片方だけ更新する運用を避けます。

## 関連モジュール早見

| ファイル | 役割 |
| --- | --- |
| `app/core/artifact-repository.ps1` | canonical store + attempt-scoped staging の API |
| `app/core/artifact-validator.ps1` | JSON schema enforcement |
| `app/core/attempt-preparation.ps1` | archive + staging dir 準備 |
| `app/core/job-context-builder.ps1` | latest archived snapshot を context 化 |
| `app/core/phase-execution-transaction.ps1` | transaction 全体 |
| `app/core/phase-validation-pipeline.ps1` | validator chain orchestration |
| `app/core/phase-completion-committer.ps1` | staging → canonical commit |
| `app/core/visual-contract-schema.ps1` | visual contract の JSON schema |
