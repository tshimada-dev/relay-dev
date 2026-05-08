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
. (Join-Path $script:ProjectRoot "app/ui/task-lane-summary.ps1")

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
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$LaneSummary
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $lane = ConvertTo-RelayHashtable -InputObject $LaneSummary
    $openRequirementsCount = @($state["open_requirements"]).Count

    Write-Host "Status:            $($state['status'])" -ForegroundColor White
    Write-Host "Phase:             $($state['current_phase'])" -ForegroundColor White
    Write-Host "Role:              $($state['current_role'])" -ForegroundColor White
    Write-Host "Active Job:        $(if ($state['active_job_id']) { $state['active_job_id'] } else { '-' })" -ForegroundColor White
    Write-Host "Current Task:      $(if ($state['current_task_id']) { $state['current_task_id'] } else { '-' })" -ForegroundColor White
    Write-Host "Open Requirements: $openRequirementsCount" -ForegroundColor White
    Write-Host "Task Lane:         $($lane['mode']) slots $($lane['used_slots'])/$($lane['max_parallel_jobs']) stop_leasing=$($lane['stop_leasing'])" -ForegroundColor White
    Write-Host "Tasks:             total=$($lane['total_tasks']) ready=$($lane['ready_count']) running=$($lane['running_count']) blocked=$($lane['blocked_count']) completed=$($lane['completed_count']) repair=$($lane['repair_count'])" -ForegroundColor White
    Write-Host "Updated At:        $($state['updated_at'])" -ForegroundColor White
}

function Write-MonitorLaneDetails {
    param([Parameter(Mandatory)]$LaneSummary)

    $lane = ConvertTo-RelayHashtable -InputObject $LaneSummary
    $activeJobs = @($lane["active_jobs"])
    $waitingTasks = @($lane["waiting_tasks"])

    Write-Host ""
    Write-Host "Active jobs:" -ForegroundColor Cyan
    if ($activeJobs.Count -eq 0) {
        Write-Host "- none" -ForegroundColor DarkGray
    }
    foreach ($jobRaw in $activeJobs) {
        $job = ConvertTo-RelayHashtable -InputObject $jobRaw
        $owner = if ($job["lease_owner"]) { " owner=$($job['lease_owner'])" } else { "" }
        $slot = if ($job["slot"]) { " slot=$($job['slot'])" } elseif ($job["slot_id"]) { " slot=$($job['slot_id'])" } else { "" }
        $workspace = if ($job["workspace"]) { " workspace=$($job['workspace'])" } elseif ($job["workspace_id"]) { " workspace=$($job['workspace_id'])" } else { "" }
        $stale = if ([bool]$job["stale"]) { " stale=$($job['stale_reason'])" } else { "" }
        Write-Host "- $($job['job_id']) task=$($job['task_id']) phase=$($job['phase']) role=$($job['role'])$owner$slot$workspace$stale"
    }

    if ($waitingTasks.Count -gt 0) {
        Write-Host "Waiting tasks:" -ForegroundColor Cyan
        foreach ($taskRaw in ($waitingTasks | Select-Object -First 5)) {
            $task = ConvertTo-RelayHashtable -InputObject $taskRaw
            $reason = if ($task["wait_reason"]) { " reason=$($task['wait_reason'])" } else { "" }
            $dependsOn = if ($task["depends_on"]) { " depends_on=$(@($task['depends_on']) -join ',')" } else { "" }
            $blockedBy = if ($task["blocked_by"]) { " blocked_by=$(@($task['blocked_by']) -join ',')" } else { "" }
            Write-Host "- $($task['task_id']) status=$($task['status'])$reason$dependsOn$blockedBy"
        }
    }
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

    $events = @(Get-Events -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId)
    $laneSummary = New-TaskLaneSummary -RunState $runState -Events $events

    Write-MonitorSummary -RunState $runState -LaneSummary $laneSummary
    Write-MonitorLaneDetails -LaneSummary $laneSummary

    if ($runState["pending_approval"]) {
        Write-ApprovalGuidance -PendingApproval $runState["pending_approval"] -ResolvedRunId $resolvedRunId
    }

    Write-Host ""
    Write-Host "Recent events:" -ForegroundColor Cyan
    foreach ($event in @($events | Select-Object -Last $RecentEvents)) {
        $type = [string]$event["type"]
        $at = [string]$event["at"]
        $phase = [string]$event["phase"]
        $phaseLabel = if ([string]::IsNullOrWhiteSpace($phase)) { "" } else { " [$phase]" }
        Write-Host "- $at $type$phaseLabel"
    }

    Start-Sleep -Seconds $RefreshSeconds
}
