#requires -Version 7.0

param(
    [string]$ConfigFile = "config/settings.yaml",
    [switch]$Force,  # Force fresh start even if status.yaml exists
    [switch]$ResumeCurrent,
    [switch]$NoMonitor
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot
$existingPhase = ""
$existingAgent = ""
$ActiveRunId = ""
$UseCliBootstrap = $false
$AppCli = Join-Path $ProjectRoot "app/cli.ps1"

# ============================================================
# Config Loading (shared with agent-loop.ps1)
# ============================================================
. (Join-Path $ProjectRoot "config/common.ps1")
. (Join-Path $ProjectRoot "app/core/run-state-store.ps1")

$Config = Read-Config -Path $ConfigFile

$CliCommand = Get-DefaultValue $Config["cli.command"]          "gemini-cli"
$TerminalType = Get-DefaultValue $Config["terminal.type"]        "wt"
$StatusFile = Get-DefaultValue $Config["paths.status_file"]    "queue/status.yaml"
$LockFile = Get-DefaultValue $Config["paths.lock_file"]      "queue/status.lock"
$DashboardFile = Get-DefaultValue $Config["paths.dashboard_file"] "dashboard.md"
$TaskFile = Get-DefaultValue $Config["paths.task_file"]      "tasks/task.md"
$LogDirectory = Get-DefaultValue $Config["log.directory"]        "logs"

function Get-CanonicalRunSummary {
    $runId = Resolve-ActiveRunId -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($runId)) {
        return $null
    }

    $runState = Read-RunState -ProjectRoot $ProjectRoot -RunId $runId
    if (-not $runState) {
        return $null
    }

    return @{
        run_id = $runId
        phase = [string]$runState["current_phase"]
        agent = [string]$runState["current_role"]
        status = [string]$runState["status"]
        source = "runs/current-run.json"
    }
}

function Get-LegacyStatusSummary {
    if (-not (Test-Path $StatusFile)) {
        return $null
    }

    $existingContent = Get-Content -Path $StatusFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $hasValidPhase = $existingContent -match 'current_phase:\s*"Phase\d'
    $hasValidAgent = $existingContent -match 'assigned_to:\s*"(implementer|reviewer|orchestrator)"'
    if (-not $hasValidPhase -or -not $hasValidAgent) {
        return $null
    }

    return @{
        run_id = ""
        phase = if ($existingContent -match 'current_phase:\s*"([^"]+)"') { $Matches[1] } else { '?' }
        agent = if ($existingContent -match 'assigned_to:\s*"([^"]+)"') { $Matches[1] } else { '?' }
        status = "legacy"
        source = "queue/status.yaml"
    }
}

function Stop-RelayDevProcessTreeById {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)]$ChildrenByParent
    )

    foreach ($child in @($ChildrenByParent[$ProcessId])) {
        Stop-RelayDevProcessTreeById -ProcessId ([int]$child.ProcessId) -ChildrenByParent $ChildrenByParent
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    }
    catch {
    }
}

function Stop-RelayDevManagedProcesses {
    param([Parameter(Mandatory)][string]$ProjectRootPath)

    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $childrenByParent = @{}
    foreach ($process in $allProcesses) {
        $parentId = [int]$process.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = @()
        }
        $childrenByParent[$parentId] = @($childrenByParent[$parentId]) + $process
    }

    $rootPattern = [regex]::Escape($ProjectRootPath)
    $managedRoots = @(
        $allProcesses |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -and
                $_.CommandLine -match $rootPattern -and
                $_.CommandLine -match 'agent-loop\.ps1|app[\\/]+cli\.ps1'
            }
    )

    foreach ($managedRoot in $managedRoots) {
        Stop-RelayDevProcessTreeById -ProcessId ([int]$managedRoot.ProcessId) -ChildrenByParent $childrenByParent
    }

    return @($managedRoots)
}

# Resolve project directory (where code is generated)
$ProjectDirRaw = Get-DefaultValue $Config["paths.project_dir"] ""
if ($ProjectDirRaw -and $ProjectDirRaw -ne "" -and $ProjectDirRaw -ne ".") {
    $ProjectDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $ProjectDirRaw))
    if (-not (Test-Path $ProjectDir)) {
        Write-Error "project_dir '$ProjectDir' does not exist. Please create it or fix paths.project_dir in config/settings.yaml"
        exit 1
    }
}
else {
    $ProjectDir = $ProjectRoot
}

$stoppedProcesses = @(Stop-RelayDevManagedProcesses -ProjectRootPath $ProjectRoot)
if ($stoppedProcesses.Count -gt 0) {
    Write-Host "Stopped stale relay-dev worker processes: $($stoppedProcesses.Count)" -ForegroundColor Yellow
}

# ============================================================
# Pre-flight checks
# ============================================================
if ($TerminalType -eq "wt" -and -not (Get-Command "wt.exe" -ErrorAction SilentlyContinue)) {
    Write-Error "Windows Terminal (wt.exe) is not installed or not in PATH."
    exit 1
}
if (-not (Get-Command "pwsh" -ErrorAction SilentlyContinue)) {
    Write-Error "pwsh is not installed or not in PATH."
    exit 1
}
if (-not (Get-Command $CliCommand -ErrorAction SilentlyContinue)) {
    Write-Error "$CliCommand is not installed or not in PATH."
    exit 1
}

# ============================================================
# Directory setup
# ============================================================
if (-not (Test-Path "queue")) { New-Item -ItemType Directory -Path "queue"       | Out-Null }
if (-not (Test-Path "config")) { New-Item -ItemType Directory -Path "config"      | Out-Null }
if (-not (Test-Path "outputs")) { New-Item -ItemType Directory -Path "outputs"     | Out-Null }
if (-not (Test-Path "tasks")) { New-Item -ItemType Directory -Path "tasks"       | Out-Null }
if (-not (Test-Path $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory | Out-Null }

# ============================================================
# Resume Detection
# ============================================================

# Remove stale lock file first (safe regardless of mode)
if (Test-Path $LockFile) { Remove-Item $LockFile -Force }

$resumeMode = [bool]$ResumeCurrent
$resumeSource = ""
if ($ResumeCurrent) {
    Write-Host "Resuming current run without interactive prompt..." -ForegroundColor Green
}
elseif (-not $Force) {
    $existingSummary = Get-CanonicalRunSummary
    if (-not $existingSummary) {
        $existingSummary = Get-LegacyStatusSummary
    }

    if ($existingSummary) {
        # Extract current state for display
        $existingPhase = [string]$existingSummary["phase"]
        $existingAgent = [string]$existingSummary["agent"]
        $resumeSource = [string]$existingSummary["source"]

        Write-Host ""
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host "  EXISTING SESSION DETECTED" -ForegroundColor Yellow
        Write-Host "  Phase : $existingPhase" -ForegroundColor White
        Write-Host "  Agent : $existingAgent" -ForegroundColor White
        Write-Host "  Source: $resumeSource" -ForegroundColor White
        Write-Host "===============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [r] Resume  - Continue from $existingPhase" -ForegroundColor Green
        Write-Host "  [n] New     - Start over from Phase0 (discards progress)" -ForegroundColor Red
        Write-Host "  [q] Quit    - Cancel" -ForegroundColor Gray
        Write-Host ""
        $choice = Read-Host "Your choice [r/n/q]"

        switch ($choice.ToLower()) {
            "r" {
                Write-Host "Resuming from $existingPhase..." -ForegroundColor Green
                $resumeMode = $true
            }
            "n" {
                Write-Host "Starting fresh from Phase0..." -ForegroundColor Yellow
                $resumeMode = $false
            }
            "q" {
                Write-Host "Cancelled." -ForegroundColor Gray
                exit 0
            }
            default {
                Write-Host "Invalid choice. Defaulting to Resume." -ForegroundColor Yellow
                $resumeMode = $true
            }
        }
        Write-Host ""
    }
}

# ============================================================
# Initialize or Resume run-state / status.yaml
# ============================================================
$now = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

if (Test-Path $AppCli) {
    try {
        if ($resumeMode) {
            if ($ResumeCurrent -or $resumeSource -eq "runs/current-run.json") {
                $ActiveRunId = & $AppCli resume -ConfigFile $ConfigFile
            }
            else {
                $resumePhase = if ($existingPhase) { $existingPhase } else { "Phase0" }
                $resumeAgent = if ($existingAgent) { $existingAgent } else { "implementer" }
                $ActiveRunId = & $AppCli resume -ConfigFile $ConfigFile -CurrentPhase $resumePhase -CurrentRole $resumeAgent
            }
        }
        else {
            $ActiveRunId = & $AppCli new -ConfigFile $ConfigFile -CurrentPhase "Phase0" -CurrentRole "implementer"
        }

        if ($ActiveRunId -is [System.Array]) {
            $ActiveRunId = ($ActiveRunId | Select-Object -Last 1)
        }
        if ($ActiveRunId) {
            $UseCliBootstrap = $true
        }
    }
    catch {
        Write-Warning "Failed to initialize run-state via app/cli.ps1. Falling back to legacy bootstrap: $_"
    }
}

if (-not $resumeMode -and -not $UseCliBootstrap) {
    # Fresh start: initialize status.yaml
    $InitialStatus = @"
assigned_to: "implementer"
current_phase: "Phase0"
feedback: ""
timestamp: "$now"
history:
  - phase: Phase0
    agent: implementer
    started: "$now"
    completed: ""
    result: ""
"@
    Set-Content -Path $StatusFile -Value $InitialStatus -Encoding UTF8
    Write-Host "Initialized status.yaml (Phase0 fresh start)." -ForegroundColor Gray
}
elseif ($resumeMode -and -not $UseCliBootstrap) {
    Write-Host "Using existing status.yaml (resume mode)." -ForegroundColor Gray
}

# ============================================================
# Initialize dashboard.md
# ============================================================
if (-not (Test-Path $DashboardFile) -or -not $resumeMode) {
    $dashboardPhase = if ($resumeMode -and $existingPhase) { $existingPhase } else { "Phase0" }
    $dashboardAgent = if ($resumeMode -and $existingAgent) { $existingAgent } else { "implementer" }
    $dashboard = @"
# Dashboard

## Current Status
- **Phase**: $dashboardPhase
- **Assigned to**: $dashboardAgent
- **Updated**: $(Get-Date -Format "yyyy-MM-dd HH:mm")

## Phase History
| Phase | Agent | Duration | Result |
|-------|-------|----------|--------|
| $dashboardPhase | $dashboardAgent | (running) | - |

## Action Required
- (none)
"@
    Set-Content -Path $DashboardFile -Value $dashboard -Encoding UTF8
}

# ============================================================
# Launch worker
# ============================================================
Write-Host "Starting engine worker..." -ForegroundColor Cyan
Write-Host "  CLI:        $CliCommand"
Write-Host "  Task:       $TaskFile"
Write-Host "  ProjectDir: $ProjectDir"
if ($ActiveRunId) {
    Write-Host "  RunId:      $ActiveRunId"
}
Write-Host ""

$AgentScript = Join-Path $ProjectRoot "agent-loop.ps1"
$MonitorScript = Join-Path $ProjectRoot "watch-run.ps1"
$WorkerCmd = "& '$AgentScript' -Role orchestrator -ConfigFile '$ConfigFile' -InteractiveApproval"
$MonitorCmd = if ($ActiveRunId) {
    "& '$MonitorScript' -ConfigFile '$ConfigFile' -RunId '$ActiveRunId'"
}
else {
    "& '$MonitorScript' -ConfigFile '$ConfigFile'"
}

Write-Host "Launching visible terminal..." -ForegroundColor Green

$WtArgs = "new-tab -d `"$ProjectDir`" pwsh -NoLogo -NoProfile -NoExit -Command `"$WorkerCmd`""
if (-not $NoMonitor) {
    $WtArgs += " ; new-tab -d `"$ProjectDir`" pwsh -NoLogo -NoProfile -NoExit -Command `"$MonitorCmd`""
}
Start-Process -FilePath "wt.exe" -ArgumentList $WtArgs

Write-Host "Worker launched successfully." -ForegroundColor Green
if (-not $NoMonitor) {
    Write-Host "A monitor tab was opened for current run visibility and approval guidance." -ForegroundColor Green
}
Write-Host "Canonical progress is in runs/<run-id>/run-state.json and events.jsonl."
