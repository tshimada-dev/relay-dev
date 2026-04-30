# Relay-Dev Token 膨張調査メモ

- 調査日: 2026-04-08
- 対象: `run-20260408-110342`
- 主な観測対象:
  - `runs/run-20260408-110342/jobs/*phase3-1-reviewer*/stderr.log`
  - `app/cli.ps1`
  - `app/execution/execution-runner.ps1`
  - `app/execution/providers/generic-cli.ps1`
  - `app/phases/phase-registry.ps1`
  - `app/prompts/system/reviewer.md`
  - `app/prompts/phases/phase3-1.md`

## 1. 症状

`Phase3-1` の設計レビュー 1 回あたりの token 使用量が大きく、安定しない。

観測できた値:

| job | tokens used |
|------|-------------|
| `job-20260408115825-phase3-1-reviewer` | `376,216` |
| `job-20260408131014-phase3-1-reviewer` | `101,197` |
| `job-20260408141540-phase3-1-reviewer` | `190,179` |
| `job-20260408144834-phase3-1-reviewer` | `348,407` |

少なくとも `Phase3-1` reviewer は「1 回 10 万 token 超」が常態化しており、30 万 token 超の run も再現している。

## 2. 先に否定できた仮説

### relay-dev が prompt を二重送信している

現時点では、その証拠は見つかっていない。

- `app/execution/execution-runner.ps1` では provider process の stdin を有効にし、`StandardInput.Write($PromptText)` で 1 回だけ prompt を渡している。
- `app/execution/providers/generic-cli.ps1` では `--prompt` / `-p` を除去しており、CLI 引数経由の再注入は抑制している。
- provider hint も `app/prompts/providers/codex-cli.md` で「prompt arrives on stdin」を前提にしている。

結論:

- transport レベルの「同じ prompt を relay-dev が 2 回送っている」可能性は低い。

### latest `Phase3-1` reviewer が example の中身を実際に読んでいる

`job-20260408144834-phase3-1-reviewer` では、`app/prompts/phases/` の一覧を取得して `examples/phase3_example.md` と `examples/phase6_example.md` を見つけているが、`Get-Content -Raw` で example 本文を読んだ痕跡は確認できなかった。

結論:

- latest run では「example の存在を見つけた」までは確認できる。
- ただし「example 本文の読込が token 膨張の主因」とまではまだ言えない。

## 3. 根本原因として有力なもの

### 3.1 reviewer が同じ入力を何度も読み直している

これが最も大きい原因候補。

`job-20260408144834-phase3-1-reviewer/stderr.log` では、reviewer が shell 経由で同じ artifact を複数回読む様子が残っている。

代表例:

- `task.md`: 2 回
- `phase1_requirements.md`: 2 回
- `phase2_info_gathering.md`: 2 回
- `phase3_design.md`: 5 回
- `phase3_design.json`: 1 回

読み直しのパターン:

1. 最初に `Get-Content -Raw` で artifact 全文を読む
2. 次に JSON を追加で読む
3. さらに `phase3_design.md` を 4 分割して行番号付きで再読する
4. 最後に `task.md` / `Phase1` / `Phase2` を再度読み、review artifact の根拠として使う

Codex provider では、こうした shell 出力自体が再び model context に戻るため、同じ内容を読むたびに token を再消費しやすい。

### 3.2 formal input contract と phase prompt がずれている

`Phase3-1` の formal input contract は比較的小さい。

- `app/phases/phase3-1.ps1` では `phase3_design.json` を input contract に持つ

しかし実際の phase prompt はかなり広く読むよう要求している。

- `app/prompts/phases/phase3-1.md` では `phase1_requirements.md`、`phase2_info_gathering.md`、`phase3_design.md` のフル参照を明示している
- 旧テンプレート移植の詳細ガイダンスと few-shot も残っている

結果として、engine が渡している formal contract よりも広い探索が reviewer に促されている。

### 3.3 shared input contract が review phase にも広く乗っている

`app/phases/phase-registry.ps1` の shared input contract により、`Phase0` 以外の全 phase で次が自動的に prompt に入る。

- `task.md`
- `phase0_context.md`
- `phase0_context.json`

これは実装 phase だけでなく review phase にも固定コストとして乗る。

`Phase3-1` ではさらに `phase3_design.json` が載るため、prompt 冒頭で必ず読むべき artifact 群がすでに多い。

### 3.4 prompt の整形不良で一覧が読みにくくなっている

`app/cli.ps1` の `New-EnginePromptText` では、`Execution Context` / `Input Artifacts` / `Required Outputs` の行結合が literal の `` `n `` になっている。

その結果、provider 側の見え方は次のようになる。

- `RunId: ...` から `Execute exactly one phase ...` までが 1 行に潰れる
- `Input Artifacts` の複数行も 1 行に潰れる
- `Required Outputs` も 1 行に潰れる

この形だと model にとって contract の一覧性が落ち、必要な artifact を自分で開き直す誘因になっている可能性が高い。

### 3.5 reviewer に探索範囲の上限がない

latest reviewer job では、`app/prompts/phases/` 以下を一覧して phase prompt 一式と example ディレクトリを見に行っていた。

これは「必要な artifact を読む」だけではなく、「framework 側の補助資料を探索してもよい」と model が解釈している兆候である。

現状の `app/prompts/system/reviewer.md` には次のルールはあるが、まだ不足している。

- phase prompt と required input artifact を読む
- framework-owned path を勝手に変更しない

不足している点:

- `Input Artifacts` に出ていない framework prompt/example を探索対象にしない
- 同じ artifact の再読は、行番号確定など明確な必要がある場合だけに限る

## 4. 補助要因

### plugin / featured-plugin 系の warning ノイズ

`stderr.log` には plugin warm-up や `403 Forbidden` HTML などの warning が大量に出ている。

これは log volume を大きくし、調査しづらさを増やしている。ただし、`tokens used` の主因はこれではなく、artifact 再読と広すぎる read scope の方が支配的と考えられる。

### prompt 自体の固定コスト

`Phase3-1` prompt は旧テンプレート移植、長いレビュー観点、few-shot を含んでいる。

これは確かに重いが、latest job の shell ログを見ると、固定 prompt 長だけでは 30 万 token 台の説明として足りず、re-read の寄与が大きい。

## 5. 現時点の診断

今回の token 膨張は、単一の原因ではなく次の複合要因で起きている可能性が高い。

1. reviewer が同じ artifact を何度も shell で読み直す
2. review phase に乗る shared input が広い
3. `Phase3-1` prompt が formal contract より広い読込を要求する
4. prompt の改行崩れで contract 一覧が読みにくい
5. framework prompt / examples の探索が抑制されていない

逆に、現時点で主因とまでは言えないもの:

- relay-dev から provider への prompt 二重送信
- latest `Phase3-1` reviewer における example 本文の実読

## 6. 優先対策

### 優先度 1

- `app/cli.ps1` の prompt 組み立てで literal `` `n `` を使っている箇所を修正し、`Execution Context` / `Input Artifacts` / `Required Outputs` を本当の改行で渡す
- `reviewer.md` に「同じ artifact を繰り返し再読しない」「`Input Artifacts` にない prompt/example を探索しない」を追加する

### 優先度 2

- `Phase3-1` を formal contract ベースに再設計し、デフォルト入力を `phase3_design.json` と最小限の照合根拠に絞る
- `Phase3-1` の旧テンプレ移植セクション、few-shot、full-read 指示を削減する

### 優先度 3

- `phase-registry.ps1` の shared input contract を phase 種別ごとに見直し、review phase では `phase0_context.md/json` を毎回必須にしない案を検討する
- `Phase4-1` / `Phase5-1` / `Phase5-2` / `Phase7` でも同様の re-read パターンがあるかログ観測を追加する

## 7. 次に確認すべきこと

- `Phase3-1` prompt を軽量化した後、token 使用量がどこまで下がるか
- 改行バグ修正だけで artifact 再読回数が減るか
- reviewer system prompt で再読禁止ルールを強めたとき、品質低下なく token が下がるか
- `Phase4-1` と `Phase7` でも `Phase3-1` と同じ再読傾向があるか

## 8. 参考ファイル

- `app/cli.ps1`
- `app/execution/execution-runner.ps1`
- `app/execution/providers/generic-cli.ps1`
- `app/phases/phase-registry.ps1`
- `app/phases/phase3-1.ps1`
- `app/prompts/system/reviewer.md`
- `app/prompts/phases/phase3-1.md`
- `runs/run-20260408-110342/jobs/job-20260408144834-phase3-1-reviewer/stderr.log`
- `runs/run-20260408-110342/jobs/job-20260408141540-phase3-1-reviewer/stderr.log`
- `runs/run-20260408-110342/jobs/job-20260408131014-phase3-1-reviewer/stderr.log`
- `runs/run-20260408-110342/jobs/job-20260408115825-phase3-1-reviewer/stderr.log`
