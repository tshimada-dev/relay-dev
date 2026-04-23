#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# start-agents.sh — Relay-Dev Linux/macOS 起動スクリプト
# tmux セッション "relay-dev" を作成し、worker pane に orchestrator、
# monitor pane に watch-run を起動する。
#
# 使用方法:
#   ./start-agents.sh           # 前回の状態を維持して起動（resume）
#   ./start-agents.sh -f        # 強制リセット（Phase0から再スタート）
#   ./start-agents.sh -h        # ヘルプ
# ═══════════════════════════════════════════════════════════════════════════════

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="config/settings.yaml"
FORCE=false
SESSION_NAME="relay-dev"
ACTIVE_RUN_ID=""
USE_CLI_BOOTSTRAP=false
APP_CLI="$SCRIPT_DIR/app/cli.ps1"
RESUME_SOURCE=""

# ─────────────────────────────────────────────────────────────────────────────
# ヘルパー関数
# ─────────────────────────────────────────────────────────────────────────────
log_info()    { echo -e "\033[1;36m[INFO]\033[0m  $1"; }
log_success() { echo -e "\033[1;32m[OK]\033[0m    $1"; }
log_warn()    { echo -e "\033[1;33m[WARN]\033[0m  $1"; }
log_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

# YAML から値を取り出す（キー: value 形式）
yaml_get() {
    local key="$1" file="$2"
    grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

# ─────────────────────────────────────────────────────────────────────────────
# オプション解析
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force) FORCE=true; shift ;;
        -h|--help)
            echo ""
            echo "Relay-Dev — Linux/macOS 起動スクリプト"
            echo ""
            echo "使用方法: ./start-agents.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  -f, --force   強制リセット（queue/status.yaml を削除して Phase0 から再スタート）"
            echo "  -h, --help    このヘルプを表示"
            echo ""
            echo "アタッチ:"
            echo "  tmux attach-session -t $SESSION_NAME"
            echo ""
            echo "デタッチ（セッションを残したまま離れる）:"
            echo "  Ctrl-b d"
            echo ""
            echo "停止:"
            echo "  tmux kill-session -t $SESSION_NAME"
            echo ""
            exit 0
            ;;
        *) log_error "不明なオプション: $1"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# 設定読み込み
# ─────────────────────────────────────────────────────────────────────────────
CLI_COMMAND=$(yaml_get "command" "$CONFIG_FILE")
CLI_COMMAND="${CLI_COMMAND:-gemini}"

STATUS_FILE=$(yaml_get "status_file" "$CONFIG_FILE")
STATUS_FILE="${STATUS_FILE:-queue/status.yaml}"

LOCK_FILE=$(yaml_get "lock_file" "$CONFIG_FILE")
LOCK_FILE="${LOCK_FILE:-queue/status.lock}"

LOG_DIR=$(yaml_get "directory" "$CONFIG_FILE")
LOG_DIR="${LOG_DIR:-logs}"

PROJECT_DIR_RAW=$(yaml_get "project_dir" "$CONFIG_FILE")
if [[ -n "$PROJECT_DIR_RAW" && "$PROJECT_DIR_RAW" != "." ]]; then
    PROJECT_DIR="$(realpath "$SCRIPT_DIR/$PROJECT_DIR_RAW")"
    if [[ ! -d "$PROJECT_DIR" ]]; then
        log_error "project_dir '$PROJECT_DIR' が存在しません。config/settings.yaml を確認してください。"
        exit 1
    fi
else
    PROJECT_DIR="$SCRIPT_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 依存チェック
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v tmux &>/dev/null; then
    log_error "tmux が見つかりません。インストールしてください。"
    echo "  Ubuntu/Debian: sudo apt-get install tmux"
    echo "  macOS:         brew install tmux"
    exit 1
fi

if ! command -v pwsh &>/dev/null; then
    log_error "PowerShell Core (pwsh) が見つかりません。インストールしてください。"
    echo "  Ubuntu: https://learn.microsoft.com/ja-jp/powershell/scripting/install/installing-powershell-on-linux"
    echo "  macOS:  brew install --cask powershell"
    exit 1
fi

if ! command -v "$CLI_COMMAND" &>/dev/null; then
    log_error "$CLI_COMMAND が見つかりません。インストールしてください。"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# ディレクトリ作成
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p queue config outputs tasks "$LOG_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# ロックファイルクリア
# ─────────────────────────────────────────────────────────────────────────────
[[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE" && log_info "古いロックファイルを削除しました。"

# ─────────────────────────────────────────────────────────────────────────────
# Resume 検出
# ─────────────────────────────────────────────────────────────────────────────
RESUME_MODE=false

if [[ "$FORCE" == false ]]; then
    if [[ -f "$SCRIPT_DIR/runs/current-run.json" ]]; then
        POINTER_RUN_ID=$(pwsh -NoLogo -NoProfile -Command '$p = Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json; $p.run_id' "$SCRIPT_DIR/runs/current-run.json" 2>/dev/null || true)
        if [[ -n "$POINTER_RUN_ID" && -f "$SCRIPT_DIR/runs/$POINTER_RUN_ID/run-state.json" ]]; then
            EXISTING_PHASE=$(pwsh -NoLogo -NoProfile -Command '$s = Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json; $s.current_phase' "$SCRIPT_DIR/runs/$POINTER_RUN_ID/run-state.json" 2>/dev/null || true)
            EXISTING_AGENT=$(pwsh -NoLogo -NoProfile -Command '$s = Get-Content -Raw -LiteralPath $args[0] | ConvertFrom-Json; $s.current_role' "$SCRIPT_DIR/runs/$POINTER_RUN_ID/run-state.json" 2>/dev/null || true)
            RESUME_SOURCE="runs/current-run.json"
        fi
    fi

    if [[ -z "${EXISTING_PHASE:-}" && -f "$STATUS_FILE" ]]; then
        EXISTING_PHASE=$(grep 'current_phase:' "$STATUS_FILE" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
        EXISTING_AGENT=$(grep 'assigned_to:' "$STATUS_FILE" | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
        RESUME_SOURCE="queue/status.yaml"
    fi

    if [[ -n "$EXISTING_PHASE" && -n "$EXISTING_AGENT" ]]; then
        echo ""
        echo "════════════════════════════════════════════════"
        echo "  EXISTING SESSION DETECTED"
        echo "  Phase : $EXISTING_PHASE"
        echo "  Agent : $EXISTING_AGENT"
        echo "  Source: $RESUME_SOURCE"
        echo "════════════════════════════════════════════════"
        echo ""
        echo "  [r] Resume  - $EXISTING_PHASE から継続"
        echo "  [n] New     - Phase0 から再スタート（進捗破棄）"
        echo "  [q] Quit    - キャンセル"
        echo ""
        read -rp "Your choice [r/n/q]: " choice

        case "${choice,,}" in
            r) log_info "Resuming from $EXISTING_PHASE..."; RESUME_MODE=true ;;
            n) log_warn "Starting fresh from Phase0..."; RESUME_MODE=false ;;
            q) echo "Cancelled."; exit 0 ;;
            *) log_warn "Invalid choice. Defaulting to Resume."; RESUME_MODE=true ;;
        esac
        echo ""
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# run-state / status.yaml の初期化
# ─────────────────────────────────────────────────────────────────────────────
NOW=$(date -u +"%Y-%m-%dT%H:%M:%S")

if [[ -f "$APP_CLI" ]]; then
    if [[ "$RESUME_MODE" == true ]]; then
        if [[ "$RESUME_SOURCE" == "runs/current-run.json" ]]; then
            if ACTIVE_RUN_ID=$(pwsh -NoLogo -NoProfile -File "$APP_CLI" resume -ConfigFile "$CONFIG_FILE" 2>/dev/null | tail -n 1); then
                [[ -n "$ACTIVE_RUN_ID" ]] && USE_CLI_BOOTSTRAP=true
            fi
        else
            RESUME_PHASE="${EXISTING_PHASE:-Phase0}"
            RESUME_AGENT="${EXISTING_AGENT:-implementer}"
            if ACTIVE_RUN_ID=$(pwsh -NoLogo -NoProfile -File "$APP_CLI" resume -ConfigFile "$CONFIG_FILE" -CurrentPhase "$RESUME_PHASE" -CurrentRole "$RESUME_AGENT" 2>/dev/null | tail -n 1); then
                [[ -n "$ACTIVE_RUN_ID" ]] && USE_CLI_BOOTSTRAP=true
            fi
        fi
    else
        if ACTIVE_RUN_ID=$(pwsh -NoLogo -NoProfile -File "$APP_CLI" new -ConfigFile "$CONFIG_FILE" -CurrentPhase "Phase0" -CurrentRole "implementer" 2>/dev/null | tail -n 1); then
            [[ -n "$ACTIVE_RUN_ID" ]] && USE_CLI_BOOTSTRAP=true
        fi
    fi
fi

if [[ "$RESUME_MODE" == false && "$USE_CLI_BOOTSTRAP" == false ]]; then
    cat > "$STATUS_FILE" <<EOF
assigned_to: "implementer"
current_phase: "Phase0"
feedback: ""
timestamp: "$NOW"
history:
  - phase: Phase0
    agent: implementer
    started: "$NOW"
    completed: ""
    result: ""
EOF
    log_success "status.yaml を初期化しました（Phase0 新規スタート）。"
elif [[ "$RESUME_MODE" == true && "$USE_CLI_BOOTSTRAP" == false ]]; then
    log_info "既存の status.yaml を使用します（resume モード）。"
fi

if [[ ! -f dashboard.md || "$RESUME_MODE" == false ]]; then
    DASHBOARD_PHASE="Phase0"
    DASHBOARD_AGENT="implementer"
    if [[ "$RESUME_MODE" == true && -n "$EXISTING_PHASE" ]]; then
        DASHBOARD_PHASE="$EXISTING_PHASE"
    fi
    if [[ "$RESUME_MODE" == true && -n "$EXISTING_AGENT" ]]; then
        DASHBOARD_AGENT="$EXISTING_AGENT"
    fi

    cat > dashboard.md <<EOF
# Dashboard

## Current Status
- **Phase**: $DASHBOARD_PHASE
- **Assigned to**: $DASHBOARD_AGENT
- **Updated**: $(date "+%Y-%m-%d %H:%M")

## Phase History
| Phase | Agent | Duration | Result |
|-------|-------|----------|--------|
| $DASHBOARD_PHASE | $DASHBOARD_AGENT | (running) | - |

## Action Required
- (none)
EOF
fi

# ─────────────────────────────────────────────────────────────────────────────
# 既存セッションのクリア
# ─────────────────────────────────────────────────────────────────────────────
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log_warn "既存の tmux セッション '$SESSION_NAME' を破棄します..."
    tmux kill-session -t "$SESSION_NAME"
fi

# ─────────────────────────────────────────────────────────────────────────────
# tmux セッション作成（左: worker / 右: monitor）
# ─────────────────────────────────────────────────────────────────────────────
AGENT_SCRIPT="$SCRIPT_DIR/agent-loop.ps1"
WATCH_SCRIPT="$SCRIPT_DIR/watch-run.ps1"
WORKER_CMD="cd '$SCRIPT_DIR' && pwsh -NoLogo -NoExit -File '$AGENT_SCRIPT' -Role orchestrator -ConfigFile '$CONFIG_FILE' -InteractiveApproval"
MONITOR_CMD="cd '$SCRIPT_DIR' && pwsh -NoLogo -NoExit -File '$WATCH_SCRIPT' -ConfigFile '$CONFIG_FILE'"
if [[ -n "$ACTIVE_RUN_ID" ]]; then
    MONITOR_CMD="$MONITOR_CMD -RunId '$ACTIVE_RUN_ID'"
fi

log_info "tmux セッション '$SESSION_NAME' を作成中..."

# セッション作成（最初のウィンドウ = worker）
tmux new-session -d -s "$SESSION_NAME" -n "agents" -x 220 -y 50

# 左ペイン: worker
tmux send-keys -t "$SESSION_NAME:agents.0" \
    "$WORKER_CMD" Enter

# 右ペインを横分割で作成: monitor
tmux split-window -h -t "$SESSION_NAME:agents"
tmux send-keys -t "$SESSION_NAME:agents.1" \
    "$MONITOR_CMD" Enter

# ペインタイトルを設定
tmux select-pane -t "$SESSION_NAME:agents.0" -T "worker"
tmux select-pane -t "$SESSION_NAME:agents.1" -T "monitor"

# ペインボーダーにタイトルを表示
tmux set-option -t "$SESSION_NAME" pane-border-status top
tmux set-option -t "$SESSION_NAME" pane-border-format " #{pane_title} "

# ─────────────────────────────────────────────────────────────────────────────
# 完了メッセージ
# ─────────────────────────────────────────────────────────────────────────────
echo ""
log_success "エージェントを起動しました。"
echo ""
echo "  セッション名  : $SESSION_NAME"
echo "  CLI           : $CLI_COMMAND"
echo "  ProjectDir    : $PROJECT_DIR"
echo "  status.yaml   : $STATUS_FILE"
if [[ -n "$ACTIVE_RUN_ID" ]]; then
    echo "  RunId         : $ACTIVE_RUN_ID"
fi
echo "  Approval      : worker pane で対話入力"
echo ""
echo "  アタッチ  →  tmux attach-session -t $SESSION_NAME"
echo "  デタッチ  →  Ctrl-b d"
echo "  停止      →  tmux kill-session -t $SESSION_NAME"
echo ""

# 起動後すぐにアタッチする（端末から直接実行した場合）
if [[ -t 0 ]]; then
    read -rp "今すぐアタッチしますか？ [Y/n]: " attach_choice
    if [[ "${attach_choice,,}" != "n" ]]; then
        tmux attach-session -t "$SESSION_NAME"
    fi
fi
