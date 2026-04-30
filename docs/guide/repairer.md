# Repairer Lane

`repairer` は relay-dev における **artifact-only repair role** です。validator が落ちた artifact を修復するためだけに存在し、product code への変更や review 判断を構造的に禁止されています。設計判断の経緯と非交渉制約は [docs/plans/repairer-implementation-plan.md](../plans/repairer-implementation-plan.md) に詳しい記録があります。

## なぜ専用 role が必要か

リファクタ前は、validator が落ちた artifact を「同じ implementer / reviewer に作り直させる」運用でした。これには以下の問題がありました。

- 修復のつもりが product code まで触りに行く
- reviewer に修復させると review 判断と作業が混ざる
- 修復で artifact 全体を書き直し、phase の合意済み内容が滑る

そこで、修復だけを担当する **第 3 の role**（`repairer`）を導入し、できることを minimal に絞りました。

## 非交渉制約

| 制約 | 維持手段 |
| --- | --- |
| product code を変更しない | `repair-diff-guard.ps1` がファイル変更を検知して reject |
| review 判断（`verdict` 等）を出さない | `phase-registry` が repairer を review phase に割り当てない |
| 直前 attempt の合意済み内容（immutable field）を勝手に書き換えない | `repair-diff-guard` が field 単位で検出 |
| 同じ artifact を何度も修復し続けない | repair budget（現在は single-pass） |

## レーンの流れ

```text
phase-validation-pipeline で invalid_artifact を検出
  └─ artifact-repair-policy で repairable か判定
       ├─ non-repairable → run を blocked へ
       └─ repairable
            └─ artifact-repair-transaction
                 ├─ repair-prompt-builder
                 │    ├─ system prompt: app/prompts/system/repairer.md
                 │    ├─ failed validator messages
                 │    ├─ immutable field の明示
                 │    └─ staged artifact 内容
                 ├─ execution-runner（provider 再呼び出し）
                 ├─ repair-diff-guard
                 │    ├─ product code への diff があれば reject
                 │    └─ immutable field の改変があれば reject
                 ├─ revalidate（artifact-validator 再実行）
                 │    ├─ pass → commit
                 │    └─ fail → run を blocked へ（repair budget 超過）
                 └─ phase-completion-committer で canonical へ
```

## Repairable failure の例

`artifact-repair-policy.ps1` で repairable と判定されるケース:

- 必須フィールド欠落（例: `verdict_reason` を書き忘れた）
- enum 違反（例: `verdict = "ok"` を書いた）
- type 不整合（例: `evidence` が string で来たが array が必要）
- field 内の論理矛盾（例: `verdict = conditional_go` で `security_checks[].status = fail` が混入）

これらは「provider job 自体は意味のある成果を出したが、構造化が崩れた」ケースです。

## Non-repairable の例

- provider job の stdout 自体が空 / 壊れている
- staging に artifact が書かれていない
- product code を直さないと artifact を成立させられない構造的問題
- repair attempt が単発で通らなかった（budget 超過）

これらは run を `blocked` にし、人間 + `relay-dev-troubleshooter` に escalate します。

## Immutable field と diff guard

`repair-diff-guard.ps1` は、repair attempt の前後で次を比較します。

- **product code** の diff（`app/`, `lib/`, project 配下のソース）→ 変更があれば即 reject。
- **同 artifact の immutable field** → 既に確定した phase 合意（例: Phase4 で確定した task 一覧、reviewer の verdict 文言）に手を入れていないか。

reject されると repair attempt は失敗扱いとなり、run は blocked に倒れます。これにより repairer の暴走は構造的に止まります。

## Repair budget

現在は **single-pass**（1 回の repair で通らなければ blocked）です。これは「壊れた artifact を 1 回直して通らないなら、根本原因が別にある」という割り切りです。

ロードマップ:

- repair 履歴を `run-state.json` に保持して、複数回 attempt の circuit breaker を入れる
- 連続 repair 失敗時に reviewer phase へ自動で戻す経路

## システム prompt の要点

`app/prompts/system/repairer.md` の本質的なルール（要約）:

- あなたは artifact 修復専用です。product code を絶対に touch してはいけません。
- 修復は staged artifact だけを対象にしてください。
- immutable field の改変は禁止です。
- review 判断（`verdict` の決定）はあなたの仕事ではありません。

## 関連ファイル

| ファイル | 役割 |
| --- | --- |
| `app/prompts/system/repairer.md` | repairer 用 system prompt |
| `app/core/artifact-repair-policy.ps1` | repairable / non-repairable の分類 |
| `app/core/artifact-repair-transaction.ps1` | repair lane transaction |
| `app/core/repair-prompt-builder.ps1` | repair prompt の構築 |
| `app/core/repair-diff-guard.ps1` | immutable field / product code 改変の検出 |
| `app/phases/phase-registry.ps1` | repairer の role 割り当て |
| `docs/plans/repairer-implementation-plan.md` | 設計判断と非交渉制約の根拠 |
