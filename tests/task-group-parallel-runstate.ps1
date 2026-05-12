$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        Add-Failure "$Message (expected='$Expected', actual='$Actual')"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-runstate-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $newState = New-RunState -RunId "run-new" -ProjectRoot $tempRoot
    Assert-True ($newState.Keys -contains "task_groups") "New run-state should include task_groups."
    Assert-True ($newState.Keys -contains "task_group_workers") "New run-state should include task_group_workers."
    Assert-Equal @($newState["task_groups"].Keys).Count 0 "New run-state should default task_groups to empty."
    Assert-Equal @($newState["task_group_workers"].Keys).Count 0 "New run-state should default task_group_workers to empty."
    Assert-True ($newState.Keys -contains "active_jobs") "New run-state should still include active_jobs."
    Assert-True ($newState.Keys -contains "task_lane") "New run-state should still include task_lane."
    Assert-True ($newState.Keys -contains "task_states") "New run-state should still include task_states."

    $legacyState = @{
        run_id = "run-legacy"
        project_root = $tempRoot
        status = "running"
        current_phase = "Phase5"
        current_role = "implementer"
        current_task_id = $null
        active_job_id = $null
        active_jobs = @{}
        task_lane = @{
            mode = "single"
            max_parallel_jobs = 1
            stop_leasing = $false
        }
        task_states = @{}
        phase_history = @()
        open_requirements = @()
        created_at = (Get-Date).ToString("o")
        updated_at = (Get-Date).ToString("o")
    }
    $normalizedLegacyState = Initialize-RunStateCompatibilityFields -RunState $legacyState
    Assert-True ($normalizedLegacyState.Keys -contains "task_groups") "Compatibility initializer should add missing task_groups."
    Assert-True ($normalizedLegacyState.Keys -contains "task_group_workers") "Compatibility initializer should add missing task_group_workers."
    Assert-Equal @($normalizedLegacyState["task_groups"].Keys).Count 0 "Compatibility initializer should default missing task_groups to empty."
    Assert-Equal @($normalizedLegacyState["task_group_workers"].Keys).Count 0 "Compatibility initializer should default missing task_group_workers to empty."
    Assert-True ($normalizedLegacyState.Keys -contains "active_jobs") "Compatibility initializer should preserve active_jobs."

    $group = New-RunStateTaskGroup -GroupId "group-001" -TaskIds @("T-01", "T-02") -WorkerIds @("worker-001", "worker-002")
    Assert-Equal $group["id"] "group-001" "Group helper should set id."
    Assert-Equal $group["status"] "running" "Group helper should default status to running."
    Assert-Equal $group["phase"] "Phase5..Phase6" "Group helper should default phase range for first slice readers."
    Assert-Equal $group["phase_range"] "Phase5..Phase6" "Group helper should include phase_range from the plan model."
    Assert-Equal @($group["task_ids"]).Count 2 "Group helper should preserve task ids."
    Assert-Equal @($group["worker_ids"]).Count 2 "Group helper should preserve worker ids."
    Assert-True ($group.Keys -contains "created_at") "Group helper should set created_at."
    Assert-True ($group.Keys -contains "updated_at") "Group helper should set updated_at."

    $worker = New-RunStateTaskGroupWorker -WorkerId "worker-001" -GroupId "group-001" -TaskId "T-01" -Status "running" -Phase "Phase5-1"
    Assert-Equal $worker["id"] "worker-001" "Worker helper should set id."
    Assert-Equal $worker["group_id"] "group-001" "Worker helper should set group_id."
    Assert-Equal $worker["task_id"] "T-01" "Worker helper should set task_id."
    Assert-Equal $worker["status"] "running" "Worker helper should preserve status."
    Assert-Equal $worker["phase"] "Phase5-1" "Worker helper should preserve phase."
    Assert-Equal $worker["current_phase"] "Phase5-1" "Worker helper should mirror current_phase for UI readers."

    $partialShapeState = @{
        run_id = "run-partial"
        project_root = $tempRoot
        status = "running"
        current_phase = "Phase5"
        current_role = "implementer"
        current_task_id = $null
        task_groups = @{
            "group-old" = @{
                status = "running"
                worker_ids = @("worker-old")
            }
        }
        task_group_workers = @{
            "worker-old" = @{
                group_id = "group-old"
                task_id = "T-old"
                current_phase = "Phase6"
            }
        }
    }
    $normalizedPartialShapeState = Initialize-RunStateCompatibilityFields -RunState $partialShapeState
    $normalizedGroup = $normalizedPartialShapeState["task_groups"]["group-old"]
    $normalizedWorker = $normalizedPartialShapeState["task_group_workers"]["worker-old"]
    Assert-Equal $normalizedGroup["id"] "group-old" "Initializer should derive missing group id from map key."
    Assert-Equal $normalizedGroup["phase"] "Phase5..Phase6" "Initializer should add missing group phase."
    Assert-Equal $normalizedGroup["phase_range"] "Phase5..Phase6" "Initializer should add missing group phase_range."
    Assert-Equal @($normalizedGroup["task_ids"]).Count 0 "Initializer should add missing group task_ids."
    Assert-Equal @($normalizedGroup["worker_ids"]).Count 1 "Initializer should preserve group worker_ids."
    Assert-True ($normalizedGroup.Keys -contains "failure_summary") "Initializer should add group failure_summary."
    Assert-Equal $normalizedWorker["id"] "worker-old" "Initializer should derive missing worker id from map key."
    Assert-Equal $normalizedWorker["status"] "queued" "Initializer should add missing worker status."
    Assert-Equal $normalizedWorker["phase"] "Phase6" "Initializer should derive worker phase from current_phase."
    Assert-Equal $normalizedWorker["current_phase"] "Phase6" "Initializer should preserve worker current_phase."
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-runstate failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-runstate passed." -ForegroundColor Green
exit 0
