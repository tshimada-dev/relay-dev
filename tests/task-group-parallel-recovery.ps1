$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\event-store.ps1")

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

function New-TestGroupFailureState {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = New-RunState -RunId $RunId -ProjectRoot $ProjectRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state["status"] = "failed"
    $state["current_task_id"] = "parent-task"
    $state["phase_history"] = @(
        [ordered]@{
            phase = "Phase5"
            agent = "implementer"
            task_id = "parent-task"
            started = (Get-Date).AddMinutes(-5).ToString("o")
            completed = (Get-Date).AddMinutes(-1).ToString("o")
            result = "failed"
        }
    )
    $state["task_groups"]["group-001"] = New-RunStateTaskGroup -GroupId "group-001" -Status "partial_failed" -TaskIds @("T-ok", "T-fail") -WorkerIds @("worker-ok", "worker-fail")
    $state["task_group_workers"]["worker-ok"] = New-RunStateTaskGroupWorker -WorkerId "worker-ok" -GroupId "group-001" -TaskId "T-ok" -Status "succeeded" -Phase "Phase6"
    $state["task_group_workers"]["worker-ok"]["worker_result"] = [ordered]@{
        group_id = "group-001"
        worker_id = "worker-ok"
        task_id = "T-ok"
        status = "succeeded"
        final_phase = "Phase6"
        errors = @()
    }
    $state["task_group_workers"]["worker-fail"] = New-RunStateTaskGroupWorker -WorkerId "worker-fail" -GroupId "group-001" -TaskId "T-fail" -Status "failed" -Phase "Phase5-2"
    $state["task_group_workers"]["worker-fail"]["worker_result"] = [ordered]@{
        group_id = "group-001"
        worker_id = "worker-fail"
        task_id = "T-fail"
        status = "failed"
        final_phase = "Phase5-2"
        errors = @("provider timeout")
    }
    $state["task_groups"]["group-001"]["worker_results"] = @(
        $state["task_group_workers"]["worker-ok"]["worker_result"],
        $state["task_group_workers"]["worker-fail"]["worker_result"]
    )
    return $state
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-recovery-" + [guid]::NewGuid().ToString("N"))
$repoRunId = "run-lcr06-" + [guid]::NewGuid().ToString("N")
$repoRunPath = Join-Path (Get-RunsRootPath -ProjectRoot $repoRoot) $repoRunId
$pointerPath = Get-CurrentRunPointerPath -ProjectRoot $repoRoot
$pointerBackup = if (Test-Path $pointerPath) { Get-Content -Path $pointerPath -Raw -Encoding UTF8 } else { $null }
$statusPath = Get-CompatibilityStatusPath -ProjectRoot $repoRoot
$statusBackup = if (Test-Path $statusPath) { Get-Content -Path $statusPath -Raw -Encoding UTF8 } else { $null }
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $state = New-TestGroupFailureState -RunId "run-attribution" -ProjectRoot $tempRoot
    $context = Get-RunStateTaskGroupFailureRecoveryContext -RunState $state
    Assert-Equal $context["group_id"] "group-001" "Failure attribution should include group_id."
    Assert-Equal $context["worker_id"] "worker-fail" "Failure attribution should include worker_id."
    Assert-Equal $context["task_id"] "T-fail" "Failure attribution should include task_id."
    Assert-Equal $context["final_phase"] "Phase5-2" "Failure attribution should include final_phase."

    $repoState = New-TestGroupFailureState -RunId $repoRunId -ProjectRoot $repoRoot
    Write-RunState -ProjectRoot $repoRoot -RunState $repoState | Out-Null
    Append-Event -ProjectRoot $repoRoot -RunId $repoRunId -Event @{
        type = "run.failed"
        reason = "job_failed"
        failure_class = "timeout"
    }
    & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot "app\cli.ps1") resume -RunId $repoRunId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "CLI resume should exit successfully for suppressed group recovery."
    }
    $resumedState = Read-RunState -ProjectRoot $repoRoot -RunId $repoRunId
    Assert-Equal $resumedState["status"] "failed" "Failed group worker resume should not set run status back to running."
    $retryHistory = @($resumedState["phase_history"] | Where-Object { [string]$_["result"] -eq "retry_same_phase" })
    Assert-Equal $retryHistory.Count 0 "Suppressed group recovery should not append retry_same_phase phase_history."
    $suppressed = ConvertTo-RelayHashtable -InputObject (Get-LastEvent -ProjectRoot $repoRoot -RunId $repoRunId -Type "run.recovery_suppressed")
    Assert-True ($null -ne $suppressed) "Suppressed group recovery should append a recovery suppression event."
    Assert-Equal $suppressed["group_id"] "group-001" "Suppression event should include group_id."
    Assert-Equal $suppressed["worker_id"] "worker-fail" "Suppression event should include worker_id."
    Assert-Equal $suppressed["worker_task_id"] "T-fail" "Suppression event should include worker task_id."
    Assert-Equal $suppressed["final_phase"] "Phase5-2" "Suppression event should include final_phase."

    $now = Get-Date
    $staleState = New-RunState -RunId "run-stale" -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $staleState["task_order"] = @("T-stale", "T-done", "T-dependent")
    $staleState["task_states"]["T-stale"] = [ordered]@{
        task_id = "T-stale"
        status = "in_progress"
        wait_reason = "task_group_running"
        active_job_id = $null
        task_group_id = "group-stale"
        depends_on = @()
        phase_cursor = "Phase5"
        kind = "planned"
    }
    $staleState["task_states"]["T-done"] = [ordered]@{
        task_id = "T-done"
        status = "in_progress"
        wait_reason = "task_group_running"
        active_job_id = $null
        task_group_id = "group-stale"
        depends_on = @()
        phase_cursor = "Phase5"
        kind = "planned"
    }
    $staleState["task_states"]["T-dependent"] = [ordered]@{
        task_id = "T-dependent"
        status = "not_started"
        wait_reason = "dependencies"
        active_job_id = $null
        depends_on = @("T-stale")
        phase_cursor = $null
        kind = "planned"
    }
    $staleState["task_groups"]["group-stale"] = New-RunStateTaskGroup -GroupId "group-stale" -Status "running" -TaskIds @("T-stale", "T-done") -WorkerIds @("worker-stale", "worker-done")
    $staleState["task_group_workers"]["worker-stale"] = New-RunStateTaskGroupWorker -WorkerId "worker-stale" -GroupId "group-stale" -TaskId "T-stale" -Status "running" -Phase "Phase5-1" -UpdatedAt $now.AddMinutes(-30).ToString("o")
    $staleState["task_group_workers"]["worker-stale"]["last_heartbeat_at"] = $now.AddMinutes(-30).ToString("o")
    $staleState["task_group_workers"]["worker-done"] = New-RunStateTaskGroupWorker -WorkerId "worker-done" -GroupId "group-stale" -TaskId "T-done" -Status "succeeded" -Phase "Phase6"
    $staleState["task_group_workers"]["worker-done"]["worker_result"] = [ordered]@{
        group_id = "group-stale"
        worker_id = "worker-done"
        task_id = "T-done"
        status = "succeeded"
        final_phase = "Phase6"
        errors = @()
    }
    $staleRepair = Repair-StaleTaskGroupWorkerState -RunState $staleState -Now $now -StaleAfterMinutes 10
    $staleRepairedState = ConvertTo-RelayHashtable -InputObject $staleRepair["run_state"]
    Assert-True ([bool]$staleRepair["changed"]) "Stale worker recovery should report a change."
    Assert-Equal $staleRepairedState["task_group_workers"]["worker-stale"]["status"] "stale" "Stale worker recovery should mark only the affected worker stale."
    Assert-Equal $staleRepairedState["task_group_workers"]["worker-done"]["status"] "succeeded" "Stale worker recovery should preserve succeeded sibling status."
    Assert-Equal $staleRepairedState["task_group_workers"]["worker-done"]["worker_result"]["status"] "succeeded" "Stale worker recovery should preserve succeeded sibling worker_result."
    Assert-Equal $staleRepairedState["task_groups"]["group-stale"]["status"] "partial_failed" "Stale worker recovery should mark mixed group partial_failed."
    Assert-Equal $staleRepairedState["task_states"]["T-stale"]["status"] "ready" "Stale group recovery should return affected task state to the ready queue."
    Assert-Equal $staleRepairedState["task_states"]["T-done"]["status"] "ready" "Stale group recovery should return sibling task state to the ready queue for all-or-nothing retry."
    Assert-Equal $staleRepairedState["task_states"]["T-dependent"]["status"] "not_started" "Stale group recovery should not unblock dependent tasks."

    $suffix = Get-RunStateGroupRecoveryAttemptSuffix -RunState $state
    Assert-True ($suffix.Contains("group=group-001")) "Agent-loop recovery key suffix should include group attribution."
    Assert-True ($suffix.Contains("worker=worker-fail")) "Agent-loop recovery key suffix should include worker attribution."
    Assert-True ($suffix.Contains("task=T-fail")) "Agent-loop recovery key suffix should include worker task attribution."
    Assert-True ($suffix.Contains("final=Phase5-2")) "Agent-loop recovery key suffix should include final phase attribution."
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
    if (Test-Path $repoRunPath) {
        Remove-Item -Path $repoRunPath -Recurse -Force
    }
    if ($null -ne $pointerBackup) {
        Set-Content -Path $pointerPath -Value $pointerBackup -Encoding UTF8
    }
    elseif (Test-Path $pointerPath) {
        Remove-Item -Path $pointerPath -Force
    }
    if ($null -ne $statusBackup) {
        Set-Content -Path $statusPath -Value $statusBackup -Encoding UTF8
    }
    elseif (Test-Path $statusPath) {
        Remove-Item -Path $statusPath -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-recovery failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-recovery passed." -ForegroundColor Green
exit 0
