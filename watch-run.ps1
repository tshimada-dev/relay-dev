#requires -Version 7.0

param(
    [string]$ConfigFile = "config/settings.yaml",
    [string]$RunId,
    [int]$RefreshSeconds = 3,
    [int]$RecentEvents = 8
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $script:ProjectRoot

. (Join-Path $script:ProjectRoot "config/common.ps1")
. (Join-Path $script:ProjectRoot "app/core/run-state-store.ps1")
. (Join-Path $script:ProjectRoot "app/core/event-store.ps1")
. (Join-Path $script:ProjectRoot "app/approval/approval-manager.ps1")

function Resolve-MonitorRunId {
    param([string]$RequestedRunId)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRunId)) {
        return $RequestedRunId
    }

    return (Resolve-ActiveRunId -ProjectRoot $script:ProjectRoot)
}

function Get-ApprovalActionSummary {
    param([AllowNull()]$Action)

    $actionObject = ConvertTo-RelayHashtable -InputObject $Action
    if (-not $actionObject) {
        return "no action"
    }

    $actionType = [string]$actionObject["type"]
    switch ($actionType) {
        "DispatchJob" {
            $phase = [string]$actionObject["phase"]
            $role = [string]$actionObject["role"]
            $taskId = [string]$actionObject["task_id"]
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                return "DispatchJob -> $phase [$role] task=$taskId"
            }

            return "DispatchJob -> $phase [$role]"
        }
        "Wait" {
            $reason = [string]$actionObject["reason"]
            if (-not [string]::IsNullOrWhiteSpace($reason)) {
                return "Wait ($reason)"
            }

            return "Wait"
        }
        "CompleteRun" { return "CompleteRun" }
        "FailRun" { return "FailRun" }
        default {
            if (-not [string]::IsNullOrWhiteSpace($actionType)) {
                return $actionType
            }

            return "unknown"
        }
    }
}

function Write-MonitorHeader {
    param([string]$ResolvedRunId)

    Write-Host "relay-dev monitor" -ForegroundColor Cyan
    Write-Host "time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace($ResolvedRunId)) {
        Write-Host "run:  $ResolvedRunId" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Write-MonitorSummary {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $openRequirementsCount = @($state["open_requirements"]).Count

    Write-Host "Status:            $($state['status'])" -ForegroundColor White
    Write-Host "Phase:             $($state['current_phase'])" -ForegroundColor White
    Write-Host "Role:              $($state['current_role'])" -ForegroundColor White
    Write-Host "Active Job:        $(if ($state['active_job_id']) { $state['active_job_id'] } else { '-' })" -ForegroundColor White
    Write-Host "Current Task:      $(if ($state['current_task_id']) { $state['current_task_id'] } else { '-' })" -ForegroundColor White
    Write-Host "Open Requirements: $openRequirementsCount" -ForegroundColor White
    Write-Host "Updated At:        $($state['updated_at'])" -ForegroundColor White
}

function Write-ApprovalGuidance {
    param(
        [Parameter(Mandatory)]$PendingApproval,
        [Parameter(Mandatory)][string]$ResolvedRunId
    )

    $approval = ConvertTo-RelayHashtable -InputObject $PendingApproval
    $requestedPhase = [string]$approval["requested_phase"]
    $approveActionSummary = Get-ApprovalActionSummary -Action $approval["proposed_action"]
    $allowedRejectTargets = @(Resolve-ApprovalRejectTargetPhases -ApprovalRequest $approval)
    $rejectTargetPhase = Resolve-DefaultApprovalRejectTargetPhase -ApprovalRequest $approval
    $promptMessage = [string]$approval["prompt_message"]
    $blockingItems = @($approval["blocking_items"])
    $carryForwardCount = @($approval["carry_forward_requirements"]).Count

    Write-Host ""
    Write-Host "APPROVAL REQUIRED" -ForegroundColor Yellow
    Write-Host "Requested Phase:      $requestedPhase" -ForegroundColor Yellow
    Write-Host "Approval Id:          $($approval['approval_id'])" -ForegroundColor Yellow
    Write-Host "Approve/Skip result:  $approveActionSummary" -ForegroundColor DarkYellow
    if (-not [string]::IsNullOrWhiteSpace($promptMessage)) {
        Write-Host "Prompt:               $promptMessage" -ForegroundColor DarkYellow
    }
    if ($carryForwardCount -gt 0) {
        Write-Host "Carry-forward reqs:   $carryForwardCount" -ForegroundColor DarkYellow
    }
    if ($blockingItems.Count -gt 0) {
        Write-Host "Blocking items:" -ForegroundColor DarkYellow
        foreach ($item in $blockingItems) {
            Write-Host "  - $item" -ForegroundColor White
        }
    }
    if ($allowedRejectTargets.Count -gt 0) {
        Write-Host "Reject targets:       $($allowedRejectTargets -join ', ')" -ForegroundColor DarkYellow
        Write-Host "Reject default phase: $rejectTargetPhase" -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "Approve current proposed action:" -ForegroundColor Green
    Write-Host "  pwsh -NoLogo -NoProfile -File .\app\cli.ps1 step -ConfigFile $ConfigFile -RunId $ResolvedRunId -ApprovalDecisionJson '{""decision"":""approve""}'"
    Write-Host "Reject example:" -ForegroundColor Red
    Write-Host "  pwsh -NoLogo -NoProfile -File .\app\cli.ps1 step -ConfigFile $ConfigFile -RunId $ResolvedRunId -ApprovalDecisionJson '{""decision"":""reject"",""comment"":""reason"",""target_phase"":""$rejectTargetPhase""}'"
    if ($allowedRejectTargets.Count -gt 1) {
        Write-Host "  target_phase には上記のいずれかを指定してください。" -ForegroundColor DarkYellow
    }
}

while ($true) {
    Clear-Host

    $resolvedRunId = Resolve-MonitorRunId -RequestedRunId $RunId
    Write-MonitorHeader -ResolvedRunId $resolvedRunId

    if (-not $resolvedRunId) {
        Write-Host "No active run" -ForegroundColor Yellow
        Start-Sleep -Seconds $RefreshSeconds
        continue
    }

    $runState = Read-RunState -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId
    if (-not $runState) {
        Write-Host "Run '$resolvedRunId' has no readable run-state." -ForegroundColor Red
        Start-Sleep -Seconds $RefreshSeconds
        continue
    }

    Write-MonitorSummary -RunState $runState

    if ($runState["pending_approval"]) {
        Write-ApprovalGuidance -PendingApproval $runState["pending_approval"] -ResolvedRunId $resolvedRunId
    }

    Write-Host ""
    Write-Host "Recent events:" -ForegroundColor Cyan
    foreach ($event in @(Get-Events -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId | Select-Object -Last $RecentEvents)) {
        $type = [string]$event["type"]
        $at = [string]$event["at"]
        $phase = [string]$event["phase"]
        $phaseLabel = if ([string]::IsNullOrWhiteSpace($phase)) { "" } else { " [$phase]" }
        Write-Host "- $at $type$phaseLabel"
    }

    Start-Sleep -Seconds $RefreshSeconds
}
