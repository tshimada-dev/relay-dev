# Providers

relay-dev は **AI provider を CLI として差し替え可能** な構成になっており、`config/settings.yaml` を切り替えるだけで Codex / Gemini / Copilot / Claude Code を入れ替えられます。本書では provider 統合の仕組みと、設定・prompt overlay の構造を説明します。

## サポート CLI

| Provider | CLI コマンド | サンプル設定 | overlay prompt |
| --- | --- | --- | --- |
| OpenAI Codex CLI | `codex` | `config/settings-codex.yaml.example` | `app/prompts/providers/codex-cli.md` |
| Google Gemini CLI | `gemini` | `config/settings-gemini.yaml.example` | `app/prompts/providers/gemini-cli.md` |
| GitHub Copilot CLI | `copilot` | `config/settings-copilot-cli.yaml.example` | `app/prompts/providers/copilot-cli.md` |
| Anthropic Claude Code | `claude` | `config/settings-claude.yaml.example` | `app/prompts/providers/claude-code.md` |

既定は Codex CLI です。

## 設定ファイル

`config/settings.yaml`（と各 example）には CLI 起動コマンド、フラグ、UTF-8 / encoding 設定、approval 設定などが含まれます。最小例:

```yaml
cli:
  command: "codex"
  flags: "--ask-for-approval never exec --skip-git-repo-check --sandbox workspace-write"

paths:
  project_dir: "."
  design_file: "DESIGN.md"

human_review:
  enabled: true
  phases: [Phase3-1, Phase4-1, Phase7]
```

別 provider を試すときは、対応する `*.example` をコピーして `settings.yaml` として使うか、`-ConfigFile` で明示します。

```powershell
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-claude.yaml.example
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-copilot-cli.yaml.example
pwsh -NoLogo -NoProfile -File .\start-agents.ps1 -ConfigFile config/settings-gemini.yaml.example
```

## Provider adapter 層

`app/execution/provider-adapter.ps1` が provider 固有の引数組立を吸収し、`app/execution/execution-runner.ps1` が CLI 呼び出しを担います。

責務分担:

- `provider-adapter.ps1`: command / flags / 標準入出力 / 環境変数の差異を埋める
- `execution-runner.ps1`: prompt の組立、stdin への投入、stdout / stderr の tee、staging path の prompt 注入、UTF-8 ハンドリング

現在の実装では、generic CLI 系 provider は **prompt を argv に埋め込まず stdin で渡す** のが既定です。これにより Windows のコマンドライン長制限に引っかかりにくくしています。

## Prompt overlay の構造

provider に渡される prompt は次の合成です。

```text
1. system prompt   : app/prompts/system/{implementer,reviewer,repairer}.md
2. provider overlay: app/prompts/providers/<cli>.md
3. phase prompt    : app/prompts/phases/<phase>.md
4. context         : Phase0/前 phase の archived JSON snapshot, task contract, validator hints
5. user request    : tasks/task.md, run metadata
```

provider overlay は短く、CLI 固有の流儀（出力形式、ツール呼び出しの可否、`<thinking>` 表記の扱いなど）を吸収するための差分だけを書きます。phase prompt 自体は provider に依存しません。

## Provider 別の実装メモ

- Codex / Gemini: `generic-cli.ps1` ベースで `prompt_mode = stdin`。Gemini は `GEMINI_CLI_TRUST_WORKSPACE=true` を追加で注入する。
- Claude Code: `claude` を PATH 解決しつつ、Windows では `%LOCALAPPDATA%\AnthropicClaudeCode\bin`、Linux/macOS では `~/.local/bin` も探索する。prompt は stdin。
- GitHub Copilot CLI: wrapper script ではなく現在 OS / arch に対応した native `copilot(.exe)` を `node_modules/@github/...` 配下から解決できる場合はそちらを優先する。あわせて GitHub CLI install dir を PATH に前置し、launch failure を減らす。

## UTF-8 と encoding

PowerShell 7 上での provider 起動は、Windows 環境で encoding が崩れやすいポイントです。relay-dev では次の対策を入れています。

- `execution-runner.ps1` が child process の stdin / stdout / stderr を UTF-8 で固定
- prompt 書き出し時にも UTF-8 (no BOM) で write
- worklog（2026-04 系）に `relay-dev UTF-8 prompt handling` の修正履歴あり（`git log` で `Fix relay-dev UTF-8 prompt handling`）

## Provider 切替時のチェックリスト

新しい provider に切り替えるときに見るポイント:

- `cli.command` / `cli.flags` が CLI 仕様に合っているか
- approval / sandbox 系のフラグが「relay-dev 側で承認 gate を持つ」前提と矛盾しないか
- 標準出力の混入（progress バーや banner）を `execution-runner` の tee が吸収できるか
- provider 固有の rate limit / token limit に対し、phase prompt の長さが収まるか

## 設定上の非交渉前提

- `app/cli.ps1` を経由しない provider 直接呼び出しは行わない
- provider が成功扱いを返しても、artifact が validator を通らなければ commit しない
- provider 出力に環境依存パス / secret が混入しないよう、公開 example では `scripts/check-public-examples.ps1` で sanitize 検査する

## 関連ファイル

| ファイル | 役割 |
| --- | --- |
| `config/settings.yaml` | 現在の provider 設定 |
| `config/settings-*.yaml.example` | 各 provider 用テンプレート |
| `app/execution/provider-adapter.ps1` | provider 引数差異の吸収 |
| `app/execution/execution-runner.ps1` | CLI 呼び出し / IO 制御 |
| `app/prompts/providers/*.md` | provider 別 overlay prompt |
| `app/prompts/system/*.md` | role 別 system prompt |
