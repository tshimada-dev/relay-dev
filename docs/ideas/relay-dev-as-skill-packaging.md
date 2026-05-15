# relay-dev 完全スキル化アイデアメモ

## 1. 概要

`relay-dev` の実行本体を Codex skill として同梱し、各プロジェクトで毎回 `relay-dev` を clone しなくても使えるようにする案。

現在は `relay-dev-front-door`、`relay-dev-seed-author`、`relay-dev-operator-launch` などで運用手順は skill 化されているが、実行本体は別途 checkout された `relay-dev` に依存している。
この依存を skill 側に寄せることで、ユーザー体験を「relay-dev は最初から Codex の能力として存在する」に近づける。

## 2. 動機

### 現状の問題

- 新しい作業ディレクトリごとに `relay-dev` の clone や配置が必要になる
- Codex が実行本体の場所を探す必要があり、運用導線が環境依存になりやすい
- skill 群はあるのに、最終的な起動だけローカル checkout に戻るため体験が分断される
- 複数プロジェクトで使うほど、runtime と project state の境界が曖昧になりやすい

### やりたいこと

`relay-dev` の安定した実行 runtime を skill に同梱し、プロジェクト側には task、outputs、run state だけを生成する。

これにより、Codex は「現在の project root に対して relay-dev を走らせる」だけを考えればよくなる。

## 3. 基本方針

### `SKILL.md` は薄く保つ

`SKILL.md` に relay-dev の実装や詳細仕様をすべて書くのではなく、使い方と判断手順だけを置く。
実行ロジックは `scripts/` や vendored runtime に分離する。

想定構成:

```text
relay-dev/
  SKILL.md
  scripts/
    relay-dev.ps1
    seed.ps1
    show.ps1
  runtime/
    relay-dev-core/
  references/
    operator.md
    state-schema.md
```

`SKILL.md` の責務:

- いつこの skill を使うか
- project root をどう決めるか
- `new` / `resume` / `step` / `show` をどう選ぶか
- canonical state として何を見るか
- 失敗時にどの troubleshooting skill へ渡すか

### runtime と project state を分離する

skill 側:

- relay-dev runtime
- launcher
- 共通 reference
- validation helper

project root 側:

- `tasks/task.md`
- `outputs/phase0_context.md`
- `outputs/phase0_context.json`
- `.relay-dev/` または `runs/` 配下の run state
- project-local config

重要なのは、skill は toolchain であり、run の状態や成果物の正本ではないこと。
状態を skill directory に書くと、複数プロジェクトや複数 run で混線する。

## 4. 出力先の案

project root を git root または現在の作業ディレクトリから決め、生成物は project root に置く。

候補:

```text
<project-root>/
  tasks/task.md
  outputs/phase0_context.md
  outputs/phase0_context.json
  .relay-dev/
    current-run.json
    runs/
      <run-id>/
        run-state.json
        events.jsonl
        jobs/
```

既存互換を優先するなら、当面は `runs/` を維持してもよい。
ただし skill 化後は「relay-dev 自体の checkout」と「run state の保存先」を見分けやすくするため、将来的には `.relay-dev/` 配下に寄せる案も検討できる。

## 5. launcher の責務

skill 化の成否は launcher の安定性に寄る。

launcher が担当すること:

- project root の解決
- skill runtime path の解決
- project-local config の読み込み
- `tasks/task.md` と Phase0 入力の存在確認
- 既存 run の有無による `new` / `resume` 判定
- run state と event log の出力先決定
- provider や model 設定の引き渡し
- 実行後の要約表示

launcher が担当しないこと:

- phase の意味を再実装する
- engine の代わりに state transition を判断する
- project output を skill directory に保存する
- ユーザーの未確定 requirements を勝手に補完する

## 6. 更新方式の課題

毎回 clone しなくてよくなる一方で、runtime 更新の導線が必要になる。

検討案:

1. skill 自体を更新する
2. runtime を skill に vendoring し、バージョンを `runtime/VERSION` に記録する
3. launcher が runtime version と project state schema version を確認する
4. 破壊的変更がある場合は migration を明示的に要求する

特に state schema は project 側に残るため、runtime だけ更新されると古い run state と新しい engine が衝突する可能性がある。
`state_schema_version` と migration guard は早めに設計したい。

## 7. 既存 skill 群との関係

既存の分割は残した方が扱いやすい。

- `relay-dev-front-door`: 要件整理
- `relay-dev-seed-author`: `tasks/task.md` と Phase0 seed 作成
- `relay-dev-operator-launch`: 起動、再開、状態確認
- `relay-dev-troubleshooter`: 詰まり調査
- 新しい runtime skill: 実行本体と launcher

完全スキル化といっても、すべてを 1 つの巨大 skill にまとめる必要はない。
むしろ runtime skill を追加し、operator skill がその launcher を呼ぶ構成が安全そう。

## 8. 懸念

- skill の配布サイズが大きくなる
- runtime 更新が skill 更新に依存する
- 複数プロジェクト同時実行時の state 分離が必要
- 既存の `runs/` 前提の tooling と互換性を保つ必要がある
- checkout 版 relay-dev と skill 同梱版が混在すると、どちらを使った run か分かりにくくなる

## 9. 最初の実装候補

いきなり完全内蔵にせず、まずは薄い `relay-dev-runner` skill として試す。

最小スコープ:

1. skill 内 launcher から project root の `tasks/task.md` を読む
2. skill 同梱 runtime、または設定された runtime path を使って `show` / `new` / `resume` を起動する
3. run state は project root 側にだけ保存する
4. 実行後に runtime version と state path を表示する

この段階で clone 不要の手触りを確認できる。
問題が少なければ runtime を vendoring し、operator skill から常用導線にする。

## 10. 結論

方向性としてはかなり有望。

`relay-dev` を project ごとに clone する運用から、Codex skill として提供される runtime を project root に適用する運用へ移すと、導入摩擦が下がり、Codex からも扱いやすくなる。

ただし、状態と成果物は必ず project root に置く。
skill は実行環境であり、project の正本ではない。
