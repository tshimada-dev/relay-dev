$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\workflow-engine.ps1")

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

function Add-TestLease {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$TaskId
    )

    $result = Add-RunStateActiveJobLease -RunState $RunState -JobSpec @{
        job_id = $JobId
        task_id = $TaskId
        phase = "Phase5"
        role = "implementer"
        parallel_safety = "parallel"
    } -LeaseOwner "ready-recovery-tests"

    return $result["run_state"]
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-ready-recovery-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $runId = "run-ready-recovery"
    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state["task_lane"]["mode"] = "parallel"
    $state["task_lane"]["max_parallel_jobs"] = 3
    $state = Add-TestLease -RunState $state -JobId "job-stale" -TaskId "T-stale"
    $state = Add-TestLease -RunState $state -JobId "job-missing" -TaskId "T-missing"
    $state = Add-TestLease -RunState $state -JobId "job-live" -TaskId "T-live"
    $state["active_jobs"]["job-stale"]["last_heartbeat_at"] = (Get-Date).AddMinutes(-20).ToString("o")
    $state["active_jobs"]["job-stale"]["lease_expires_at"] = (Get-Date).AddMinutes(-10).ToString("o")
    $state["active_jobs"]["job-missing"]["last_heartbeat_at"] = (Get-Date).AddMinutes(-20).ToString("o")
    $state["active_jobs"]["job-missing"]["lease_expires_at"] = (Get-Date).AddMinutes(-10).ToString("o")

    Write-JobMetadata -ProjectRoot $tempRoot -RunId $runId -JobId "job-stale" -Metadata @{
        run_id = $runId
        job_id = "job-stale"
        status = "running"
        pid = 999999
    } | Out-Null
    Write-JobMetadata -ProjectRoot $tempRoot -RunId $runId -JobId "job-live" -Metadata @{
        run_id = $runId
        job_id = "job-live"
        status = "running"
        pid = $PID
    } | Out-Null

    $repaired = Repair-StaleActiveJobState -RunState $state -ProjectRoot $tempRoot
    $repairedState = ConvertTo-RelayHashtable -InputObject $repaired["run_state"]
    $recoveredJobs = @($repaired["recovered_jobs"])
    $recoveredJobIds = @($recoveredJobs | ForEach-Object { [string]$_["job_id"] } | Sort-Object)

    Assert-True ([bool]$repaired["changed"]) "Multi-active recovery should report a change when any active job is stale."
    Assert-Equal $recoveredJobs.Count 2 "Multi-active recovery should report every recovered stale job."
    Assert-Equal ($recoveredJobIds -join ",") "job-missing,job-stale" "Multi-active recovery should clear only stale or missing active jobs."
    Assert-True ($repairedState["active_jobs"].ContainsKey("job-live")) "Live active jobs should remain leased."
    Assert-Equal @($repairedState["active_jobs"].Keys).Count 1 "Only live active jobs should remain after multi-active recovery."
    Assert-Equal $repairedState["active_job_id"] "job-live" "Compatibility active_job_id should move to a remaining live job."

    $reasonByJob = @{}
    foreach ($jobRaw in $recoveredJobs) {
        $job = ConvertTo-RelayHashtable -InputObject $jobRaw
        $reasonByJob[[string]$job["job_id"]] = [string]$job["reason"]
    }
    Assert-Equal $reasonByJob["job-stale"] "stale_active_job" "Recovered stale process should keep a stale_active_job reason."
    Assert-Equal $reasonByJob["job-missing"] "missing_job_metadata" "Recovered missing metadata should keep a missing_job_metadata reason."

    $liveOnly = Repair-StaleActiveJobState -RunState $repairedState -ProjectRoot $tempRoot
    Assert-Equal ([bool]$liveOnly["changed"]) $false "Recovery should be a no-op when every remaining active job is alive."
    Assert-Equal @($liveOnly["recovered_jobs"]).Count 0 "No-op recovery should expose an empty recovered_jobs list."

    $heartbeatRunId = "run-ready-heartbeat"
    $heartbeatState = New-RunState -RunId $heartbeatRunId -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $heartbeatState["task_lane"]["mode"] = "parallel"
    $heartbeatState["task_lane"]["max_parallel_jobs"] = 2
    $heartbeatState = Add-TestLease -RunState $heartbeatState -JobId "job-fresh-missing" -TaskId "T-fresh-missing"
    $heartbeatState = Add-TestLease -RunState $heartbeatState -JobId "job-fresh-dead-pid" -TaskId "T-fresh-dead-pid"
    $freshToken = [string]$heartbeatState["active_jobs"]["job-fresh-missing"]["lease_token"]
    $heartbeatUpdate = Update-RunStateActiveJobHeartbeat -RunState $heartbeatState -JobId "job-fresh-missing" -LeaseToken $freshToken -LeaseDurationMinutes 30
    Assert-True ([bool]$heartbeatUpdate["valid"]) "Heartbeat update should accept a matching active lease token."
    $heartbeatState = ConvertTo-RelayHashtable -InputObject $heartbeatUpdate["run_state"]

    $badHeartbeat = Update-RunStateActiveJobHeartbeat -RunState $heartbeatState -JobId "job-fresh-missing" -LeaseToken "wrong-token"
    Assert-Equal ([bool]$badHeartbeat["valid"]) $false "Heartbeat update should reject a mismatched lease token."
    Assert-True (@($badHeartbeat["errors"]).Count -gt 0) "Rejected heartbeat should return structured errors."

    Write-JobMetadata -ProjectRoot $tempRoot -RunId $heartbeatRunId -JobId "job-fresh-dead-pid" -Metadata @{
        run_id = $heartbeatRunId
        job_id = "job-fresh-dead-pid"
        status = "running"
        pid = 999999
    } | Out-Null

    $freshRecovery = Repair-StaleActiveJobState -RunState $heartbeatState -ProjectRoot $tempRoot
    $freshRecoveryState = ConvertTo-RelayHashtable -InputObject $freshRecovery["run_state"]
    Assert-Equal ([bool]$freshRecovery["changed"]) $false "Fresh active_jobs heartbeats should prevent stale recovery for missing metadata or dead pid."
    Assert-True ($freshRecoveryState["active_jobs"].ContainsKey("job-fresh-missing")) "Fresh heartbeat should preserve a job even when job metadata is missing."
    Assert-True ($freshRecoveryState["active_jobs"].ContainsKey("job-fresh-dead-pid")) "Fresh heartbeat should preserve a job even when pid metadata is dead."

    $compatRunId = "run-ready-compat"
    $compatState = New-RunState -RunId $compatRunId -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $compatState["active_job_id"] = "job-compat-no-heartbeat"
    Write-JobMetadata -ProjectRoot $tempRoot -RunId $compatRunId -JobId "job-compat-no-heartbeat" -Metadata @{
        run_id = $compatRunId
        job_id = "job-compat-no-heartbeat"
        status = "running"
    } | Out-Null
    $compatRecovery = Repair-StaleActiveJobState -RunState $compatState -ProjectRoot $tempRoot
    Assert-True ([bool]$compatRecovery["changed"]) "Compatibility active_job_id without a heartbeat should keep old missing-pid recovery behavior."
    Assert-Equal $compatRecovery["reason"] "job_missing_pid" "Compatibility recovery should keep the old job_missing_pid reason."

    $orphanRunId = "run-ready-orphan-task"
    $orphanState = New-RunState -RunId $orphanRunId -ProjectRoot $tempRoot -CurrentPhase "Phase5-2" -CurrentRole "reviewer" -TaskId "T-current"
    $orphanState["current_task_id"] = "T-current"
    $orphanState["task_order"] = @("T-current", "T-orphan-ready", "T-orphan-blocked", "T-dependency")
    $orphanState["task_states"] = [ordered]@{
        "T-current" = [ordered]@{
            task_id = "T-current"
            status = "in_progress"
            kind = "planned"
            last_completed_phase = "Phase5-1"
            phase_cursor = "Phase5-2"
            active_job_id = $null
            wait_reason = $null
            depends_on = @()
        }
        "T-orphan-ready" = [ordered]@{
            task_id = "T-orphan-ready"
            status = "in_progress"
            kind = "planned"
            last_completed_phase = ""
            phase_cursor = "Phase5"
            active_job_id = $null
            wait_reason = $null
            depends_on = @()
        }
        "T-orphan-blocked" = [ordered]@{
            task_id = "T-orphan-blocked"
            status = "in_progress"
            kind = "planned"
            last_completed_phase = ""
            phase_cursor = "Phase5"
            active_job_id = $null
            wait_reason = $null
            depends_on = @("T-dependency")
        }
        "T-dependency" = [ordered]@{
            task_id = "T-dependency"
            status = "not_started"
            kind = "planned"
            last_completed_phase = ""
            phase_cursor = $null
            active_job_id = $null
            wait_reason = $null
            depends_on = @()
        }
    }

    $orphanRepair = Repair-OrphanedInProgressTaskState -RunState $orphanState
    $orphanRepairedState = ConvertTo-RelayHashtable -InputObject $orphanRepair["run_state"]
    Assert-True ([bool]$orphanRepair["changed"]) "Orphaned in_progress tasks without active leases should be repaired."
    Assert-Equal $orphanRepairedState["task_states"]["T-current"]["status"] "in_progress" "Current task waiting for dispatch should remain in_progress."
    Assert-Equal $orphanRepairedState["task_states"]["T-orphan-ready"]["status"] "ready" "Dependency-free orphan task should become ready again."
    Assert-Equal $orphanRepairedState["task_states"]["T-orphan-ready"]["phase_cursor"] "Phase5" "Recovered orphan task should preserve its phase cursor."
    Assert-Equal $orphanRepairedState["task_states"]["T-orphan-blocked"]["status"] "not_started" "Dependency-blocked orphan task should return to not_started."
    Assert-Equal $orphanRepairedState["task_states"]["T-orphan-blocked"]["wait_reason"] "dependencies" "Dependency-blocked orphan task should carry a dependency wait reason."
    Assert-Equal @($orphanRepair["recovered_tasks"]).Count 2 "Recovery should report every repaired orphan task."

    $phase6RecoveryRunId = "run-ready-phase6-reject"
    $phase6RecoveryState = New-RunState -RunId $phase6RecoveryRunId -ProjectRoot $tempRoot -CurrentPhase "Phase6" -CurrentRole "reviewer" -TaskId "T-reject"
    $phase6RecoveryState["task_order"] = @("T-reject")
    $phase6RecoveryState["task_states"] = [ordered]@{
        "T-reject" = [ordered]@{
            task_id = "T-reject"
            status = "in_progress"
            kind = "planned"
            last_completed_phase = "Phase6"
            phase_cursor = "Phase6"
            active_job_id = $null
            wait_reason = $null
            depends_on = @()
        }
    }
    Save-Artifact -ProjectRoot $tempRoot -RunId $phase6RecoveryRunId -Scope task -TaskId "T-reject" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
        task_id = "T-reject"
        verdict = "reject"
        rollback_phase = "Phase5"
    } -AsJson | Out-Null
    $phase6Recovery = Repair-RejectedPhase6TaskState -RunState $phase6RecoveryState -ProjectRoot $tempRoot
    $phase6RecoveryRepairedState = ConvertTo-RelayHashtable -InputObject $phase6Recovery["run_state"]
    Assert-True ([bool]$phase6Recovery["changed"]) "Rejected Phase6 recovery should repair task-scoped rollback phases."
    Assert-Equal $phase6RecoveryRepairedState["task_states"]["T-reject"]["status"] "in_progress" "Rejected Phase6 recovery should leave the task open for retry."
    Assert-Equal $phase6RecoveryRepairedState["task_states"]["T-reject"]["phase_cursor"] "Phase5" "Rejected Phase6 recovery should restore a task-scoped rollback cursor."
    Assert-Equal $phase6RecoveryRepairedState["current_phase"] "Phase5" "Rejected Phase6 recovery should restore the run cursor when nothing else is active."

    $phase6RunLevelRecoveryRunId = "run-ready-phase6-run-level-reject"
    $phase6RunLevelRecoveryState = New-RunState -RunId $phase6RunLevelRecoveryRunId -ProjectRoot $tempRoot -CurrentPhase "Phase6" -CurrentRole "reviewer" -TaskId "T-reject"
    $phase6RunLevelRecoveryState["task_order"] = @("T-reject")
    $phase6RunLevelRecoveryState["task_states"] = [ordered]@{
        "T-reject" = [ordered]@{
            task_id = "T-reject"
            status = "in_progress"
            kind = "planned"
            last_completed_phase = "Phase6"
            phase_cursor = "Phase6"
            active_job_id = $null
            wait_reason = $null
            depends_on = @()
        }
    }
    Save-Artifact -ProjectRoot $tempRoot -RunId $phase6RunLevelRecoveryRunId -Scope task -TaskId "T-reject" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
        task_id = "T-reject"
        verdict = "reject"
        rollback_phase = "Phase4"
    } -AsJson | Out-Null
    $phase6RunLevelRecovery = Repair-RejectedPhase6TaskState -RunState $phase6RunLevelRecoveryState -ProjectRoot $tempRoot
    $phase6RunLevelRecoveryStateAfter = ConvertTo-RelayHashtable -InputObject $phase6RunLevelRecovery["run_state"]
    Assert-Equal ([bool]$phase6RunLevelRecovery["changed"]) $false "Rejected Phase6 recovery should not auto-repair non-task rollback phases in this slice."
    Assert-Equal $phase6RunLevelRecoveryStateAfter["task_states"]["T-reject"]["phase_cursor"] "Phase6" "Rejected Phase6 recovery should preserve the stale cursor for non-task rollback design follow-up."
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-ready-recovery failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-ready-recovery passed." -ForegroundColor Green
exit 0
