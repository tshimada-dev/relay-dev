# relay-dev 技術レビュー 2026-04-30

## 1. 総評

relay-dev は、trusted local workflow を前提にしたフェーズ駆動の開発ランナーとして、かなり高い完成度に達しています。正本 state と append-only event log、approval gate、artifact validator の責務分離は一貫しており、設計の成熟度は高いです。特に reviewer must_fix を open requirements として持ち越し、未解決のまま Phase7 を go させない制御は実運用上有効です。[README.md](../README.md#L24) [README.md](../README.md#L39) [README.md](../README.md#L52-L55) [app/core/workflow-engine.ps1](../app/core/workflow-engine.ps1#L843-L967)

現時点で重大欠陥は確認していません。2026-04-30 時点で [tests/regression.ps1](../tests/regression.ps1#L1305-L1407) [tests/regression.ps1](../tests/regression.ps1#L1886-L2025) [tests/regression.ps1](../tests/regression.ps1#L2482-L2528) を含む回帰テストは通過しており、ローカル運用可能性は高いです。ただし、セキュリティ面では一部 provider adapter が prompt を argv で渡しており、secret を含む入力を扱う運用では改善余地があります。[app/execution/providers/claude.ps1](../app/execution/providers/claude.ps1#L76-L85) [app/execution/providers/copilot.ps1](../app/execution/providers/copilot.ps1#L54-L65)

## 2. リスク評価

| 評価対象 | 発生確率 | 影響度 | 総合リスク | 根拠 |
| --- | --- | --- | --- | --- |
| 自律制御 | 低 | 中 | 低 | フェーズ遷移と reject 先が明示され、承認待ちと carry-forward requirement も state に保持されます。[app/phases/phase-registry.ps1](../app/phases/phase-registry.ps1#L63-L70) [app/core/transition-resolver.ps1](../app/core/transition-resolver.ps1#L47-L67) [app/core/workflow-engine.ps1](../app/core/workflow-engine.ps1#L843-L967) [tests/regression.ps1](../tests/regression.ps1#L1490-L1745) |
| セキュリティ | 中 | 中 | 中 | スコープは trusted local execution に限定されており、その前提は妥当です。一方で Claude/Copilot adapter は prompt を argv で渡し、execution runner は stderr を保存するため、secret を prompt に含めた場合の露出余地があります。[SECURITY.md](../SECURITY.md#L3-L15) [app/execution/providers/claude.ps1](../app/execution/providers/claude.ps1#L76-L85) [app/execution/providers/copilot.ps1](../app/execution/providers/copilot.ps1#L54-L65) [app/execution/execution-runner.ps1](../app/execution/execution-runner.ps1#L552-L589) |
| 状態管理 | 低 | 中 | 低 | single-writer モデル、run lock、temp file 経由の state 書き込み、append-only event log が揃っています。長期的なスケール余地はありますが、現行用途では十分堅実です。[README.md](../README.md#L24) [app/core/run-lock.ps1](../app/core/run-lock.ps1#L11-L79) [app/core/run-state-store.ps1](../app/core/run-state-store.ps1#L496-L519) [app/core/event-store.ps1](../app/core/event-store.ps1#L10-L42) |
| テスト戦略 | 中 | 中 | 中 | テストは想定より広く、execution runner、approval 解決、CLI の step/resume、lock contention までカバーしています。ただし実プロバイダ CLI との接続確認ではなく、fake-provider / generic-cli 中心です。[CONTRIBUTING.md](../CONTRIBUTING.md#L8) [tests/regression.ps1](../tests/regression.ps1#L1305-L1407) [tests/regression.ps1](../tests/regression.ps1#L1886-L2025) [tests/regression.ps1](../tests/regression.ps1#L2482-L2528) |
| デプロイ安全性 | 低 | 中 | 低 | timeout recovery、artifact validation 後 commit、repair budget 1 など実行面のガードは現実的です。残る論点は強制 kill が best-effort であることですが、trusted local runner の範囲では致命傷ではありません。[app/core/phase-execution-transaction.ps1](../app/core/phase-execution-transaction.ps1#L57-L84) [app/core/phase-execution-transaction.ps1](../app/core/phase-execution-transaction.ps1#L202-L225) [app/execution/execution-runner.ps1](../app/execution/execution-runner.ps1#L326-L433) [app/execution/execution-runner.ps1](../app/execution/execution-runner.ps1#L521-L589) |

## 3. 改善提案

### P0

P0なし。重大欠陥なし。

### P1

1. Claude/Copilot adapter の prompt 受け渡しを argv から stdin か一時ファイル方式へ寄せるべきです。現状でも trusted local 前提なら許容範囲ですが、secret 混入時の露出面として最も具体的な改善ポイントです。[app/execution/providers/claude.ps1](../app/execution/providers/claude.ps1#L76-L85) [app/execution/providers/copilot.ps1](../app/execution/providers/copilot.ps1#L54-L65) [app/execution/providers/generic-cli.ps1](../app/execution/providers/generic-cli.ps1#L28-L39)

2. provider stderr と job metadata に対する redact ルールを追加した方がよいです。現在はエラー解析に必要な情報を確保できていますが、秘密情報が provider 側から出力された場合にそのまま残ります。[app/execution/execution-runner.ps1](../app/execution/execution-runner.ps1#L552-L589)

3. 実プロバイダ接続の opt-in smoke test を追加すると、adapter の引数差異や provider CLI 更新に対する検知力が上がります。現行テストは強いものの、実接続面は fake-provider / generic-cli ベースです。[tests/regression.ps1](../tests/regression.ps1#L483-L510) [tests/regression.ps1](../tests/regression.ps1#L1305-L1407) [tests/regression.ps1](../tests/regression.ps1#L1886-L2025)

### P2

1. approval の prompt_message 依存を少し減らし、must_fix や clarification を UI 表示しやすい typed field に寄せると、将来の operator UX と自動解析が楽になります。今の実装でも動作は妥当ですが、構造化の余地があります。[app/approval/approval-manager.ps1](../app/approval/approval-manager.ps1#L10-L35) [app/core/workflow-engine.ps1](../app/core/workflow-engine.ps1#L923-L967)

2. events.jsonl の取得は毎回全件読込なので、長寿命 run を増やすなら tail read か archive/rotation を追加するとよいです。現状の単一ローカル運用では緊急度は低いです。[app/core/event-store.ps1](../app/core/event-store.ps1#L30-L42)

## 4. 強み

- canonical state と互換投影を明確に分けており、正本がぶれにくいです。[README.md](../README.md#L39) [app/core/run-state-store.ps1](../app/core/run-state-store.ps1#L338-L364)
- reviewer の must_fix と open requirements を state machine に組み込み、未解決のまま最終 go できない設計は実務的に良い判断です。[app/core/workflow-engine.ps1](../app/core/workflow-engine.ps1#L843-L967) [tests/regression.ps1](../tests/regression.ps1#L1638-L1745)
- validation 後 commit、失敗時の repair、timeout recovery の流れが一貫しており、AI 出力の不安定さに対する守りが入っています。[app/core/phase-execution-transaction.ps1](../app/core/phase-execution-transaction.ps1#L57-L84) [app/core/phase-execution-transaction.ps1](../app/core/phase-execution-transaction.ps1#L202-L225)
- テストは artifact shape だけでなく、CLI の承認遷移、resume、lock contention まで押さえており、運用品質への意識が高いです。[tests/regression.ps1](../tests/regression.ps1#L1886-L2025) [tests/regression.ps1](../tests/regression.ps1#L2482-L2528)
- セキュリティ前提を過剰に盛らず、trusted local workflow に限定している点は誠実です。[SECURITY.md](../SECURITY.md#L3-L15)

## 5. 技術成熟度評価

82 / 100

小規模チームの trusted local 開発 runner としては十分に運用可能な水準です。90 点台に届かない理由は、実プロバイダ接続の smoke coverage が未整備なことと、一部 adapter の prompt 受け渡しが運用依存のセキュリティリスクを残しているためです。一方で、状態管理、approval gate、テストの厚み、実行回復性はすでに商用利用を意識した作りになっています。