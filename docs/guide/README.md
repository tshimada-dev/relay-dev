# Relay-Dev Guide

このディレクトリは、relay-dev の各レイヤを掘り下げて説明するハンドブックです。  
ルート [README.md](../../README.md) は 1 画面で価値を伝える概観に絞っているので、内部実装・運用の根拠をたどりたい場合はこちらを読んでください。

## 想定読者

- relay-dev を実運用に乗せようとしている開発者
- relay-dev の設計判断を評価したいエンジニアリングマネージャー / 採用担当
- 他プロジェクトに同等の「phase 駆動 + canonical state + repair lane」を持ち込みたい人

## 目次

| ファイル | 概要 |
| --- | --- |
| [architecture.md](./architecture.md) | canonical state、single writer、compatibility projection、コアモジュールの責務分担 |
| [phases.md](./phases.md) | Phase0〜Phase8 のフロー、実際の artifact ID、verdict / rollback / open requirements の扱い |
| [artifacts.md](./artifacts.md) | canonical artifact store、attempt-scoped staging、finalization、validation pipeline、recovery transaction |
| [design-contracts.md](./design-contracts.md) | 設計境界 (`boundary_contract`) と visual design (`visual_contract`) の伝搬モデル |
| [repairer.md](./repairer.md) | artifact-only repair lane、`repairer` role、policy / diff guard / non-negotiables |
| [skills.md](./skills.md) | 同梱 skill の役割分担、ハンドオフ規約、動作確認用 dummy run |
| [providers.md](./providers.md) | provider CLI adapter、stdin prompt transport、設定 YAML、provider 別の起動差異 |
| [operations.md](./operations.md) | `app/cli.ps1` / `start-agents` / `agent-loop`、approval、auto-resume、監視・トラブルシュート、CI |

## 既に整理済みの周辺ドキュメント

- [docs/architecture/](../architecture/): リファクタの設計仕様（より深い設計メモ）
- [docs/plans/](../plans/): 実装計画（phase-transition refactor、repairer plan、machine-owned verdict rollout ほか）
- [docs/evaluations/](../evaluations/): 自己評価メモ
- [docs/prompts/](../prompts/): first-run review prompt などの補助プロンプト
- Ideas: `portfolio-roadmap.md`、`portfolio-improvement-backlog.md` などの将来構想
- [docs/investigations/](../investigations/): 調査メモ
- [docs/worklog/](../worklog/): 日次ログ

## 読む順番（推奨）

1. ルート [README.md](../../README.md): ハイライト・スクリーンショット・一枚図で全体像を掴む
2. [architecture.md](./architecture.md): canonical state モデルを押さえる
3. [phases.md](./phases.md) → [artifacts.md](./artifacts.md): 実行モデルとデータ層
4. [design-contracts.md](./design-contracts.md) → [repairer.md](./repairer.md): 品質を支える 2 つの仕組み
5. [skills.md](./skills.md) → [operations.md](./operations.md) → [providers.md](./providers.md): 実運用面
