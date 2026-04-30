# run-analyst アイデアメモ

## 1. 概要

run 完了後に実行される新しいロール `run-analyst` の構想。
run のメカニクス（詰まりポイント、repair 回数、failure パターン）を観察し、
システム改善提案を人間に提出する。

## 2. 動機

### 現状の問題

- artifact validation 失敗の修復は `repairer` で対応できる
- しかし「なぜ繰り返し同じ場所で詰まるのか」を観察・学習するレーンがない
- Phase8 の retrospective セクションが改善提案に近いが、run 内容（artifact の品質）しか見ておらず、run のメカニクスを観察できていない

### やりたいこと

run ごとに「何が起きたか」を定量的に観察し、構造的な改善提案を人間に届ける。
人間が判断・実装するので、システムが自分自身を書き換えるリスクがない。

## 3. 設計原則

### 権限設計

- **読み取り**: run-state、event log、全 artifact 履歴、repair attempt 記録、複数 run の統計
- **書き込み**: なし（read-only）
- **出力先**: 人間向けの proposals キュー（engine には流さない）

write がゼロであることが安全性の構造的根拠。diff guard も immutable field guard も不要。

### repairer との対比

| | repairer | run-analyst |
|---|---|---|
| タイミング | validation 失敗時（run 内） | run 完了後 |
| 読み取り範囲 | staged artifact のみ | run 全体 + 複数 run 統計 |
| 書き込み | staged artifact（syntax のみ） | なし |
| 出力 | 修復済み artifact | 改善提案ドキュメント |
| 用途 | run の継続 | システムの改善 |

## 4. 観察対象

run のコンテンツ（artifact の内容）ではなく、run のメカニクスを見る。

- repair が何回発生したか
- どの failure fingerprint が多いか
- terminal failure に落ちた箇所
- full rerun になった回数・理由
- approval で詰まった時間
- phase ごとの所要時間の偏り

## 5. 出力の形式

LLM に「改善案を出して」と聞くだけでは抽象的な提案になりやすい。
出力を構造化して、実装に繋がりやすくする。

```
## 観察

- bad_escape fingerprint が直近 30 run 中 18 run で発生
- そのうち 15 run は deterministic pre-fix で解消
- 3 run は repairer を呼び出した

## 提案

- 対象: ArtifactRepairPolicy の deterministic fix パターン
- 内容: \d エスケープパターンを pre-fix に追加
- 変更候補: app/core/artifact-repair-policy.ps1:42
- 優先度: 高（発生頻度が高く、fix が単純）
```

## 6. トリガー設計

毎 run ごとに出すと提案過多になり、人間が読まなくなる（proposal fatigue）。

候補:
- 同一 failure fingerprint が N run 連続したとき
- repair budget を消費した run が発生したとき
- run.failed になったとき（terminal failure）
- 定期バッチ（例: 週次で直近 run を集計）

## 7. Phase8 との関係

Phase8 は二つの責務を持っている。

| 責務 | 性質 | 適切なロール |
|---|---|---|
| リリース判定（Go/Conditional Go/Reject） | 判断・verdict | Phase8（reviewer 系）のまま |
| 振り返り・改善提案 | 分析・提案 | run-analyst に移管 |

### 方針

- Phase8 はリリース判定に集中させる
- Phase8 の retrospective セクションは削除または簡略化
- run-analyst が run 完了後に発火し、Phase8 の出力も入力として読む
- 改善提案は run-analyst が担う

```
Phase8（run 内・最終 phase）
  └── final_verdict, release_decision を出力
      └── run ends

run-analyst（run 完了後に発火）
  ├── Phase8 の出力を読む（リリース判定の結果も観察対象）
  ├── repair 記録、failure fingerprint、event log を読む
  └── 構造化された改善提案を出力
```

## 8. 自律進化との関係

run-analyst は「提案するだけ」であり、実装の判断と実行は人間が持つ。
これは repairer の権限拡張による自律進化とは根本的に異なる。

- repairer に自分のルール（artifact-repair-policy.ps1 等）を編集させると、guardrail の無効化パスが開く
- run-analyst は読むだけなので、そのパスが構造的に存在しない

フィードバックループは存在するが、LLM がシステムを直接書き換えるパスがない。
これが許容できる自律改善の範囲と考える。

## 9. 段階導入案

### Step 1

Phase8 の retrospective セクションを拡張し、run mechanics の観察も含める。
run-analyst の独立 role は作らず、Phase8 の出力を充実させる。

### Step 2

Phase8 から retrospective を分離し、run 完了後に発火する独立 role として切り出す。
単一 run の観察のみ。

### Step 3

複数 run にまたがる集計・パターン検出を追加。
定期バッチトリガーを導入。

## 10. 未決事項

- proposals をどこに出力するか（ファイル、GitHub Issue、Slack 等）
- トリガー条件の具体的な閾値
- Phase8 retrospective セクションの削除タイミング（run-analyst が安定してから）
- 複数 run の統計をどの粒度で保持するか
