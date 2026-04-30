# Changelog

## Unreleased

- README をポートフォリオ向けに再編し、ハイライト・スクリーンショット・一枚図・docs 索引・コアモジュール早見表を追加した。続いて肥大化（781 行）を解消するため再推敲し、6 個の skill 節を 1 表に集約・重複セクションを統合して 202 行（約 74% 削減）に圧縮した。
- `docs/guide/` 配下に詳細ドキュメントを 8 ファイル構成で新設した（README、architecture、phases、artifacts、design-contracts、repairer、skills、providers、operations）。
- 旧 README から実体パスと食い違っていた `docs/architecture-redesign.md` / `docs/redesign-design-spec.md` / `docs/portfolio-roadmap.md` のリンクを `docs/architecture/`、`docs/ideas/` 配下の正しい位置に修正した。
- 直近の `repairer` artifact-only repair lane、attempt-scoped staging、phase-execution-transaction、複数 provider 対応 (codex/gemini/copilot/claude) を README の「主な特徴」と Tech stack に反映した。
- Added the portfolio roadmap and Phase A public-readiness direction.
- Documented PowerShell 7 (`pwsh`) as the supported runtime.
- Added Phase0 seed freshness metadata requirements.
- Added public example manifest and sanitize-check expectations.
