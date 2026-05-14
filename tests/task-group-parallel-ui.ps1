$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\ui\task-lane-summary.ps1")
. (Join-Path $repoRoot "app\ui\run-summary-renderer.ps1")

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

function New-TaskGroupUiState {
    return [ordered]@{
        run_id = "run-task-group-ui"
        project_root = $repoRoot
        status = "running"
        current_phase = "Phase5"
        current_role = "implementer"
        current_task_id = $null
        active_job_id = $null
        active_jobs = [ordered]@{}
        task_lane = [ordered]@{
            mode = "parallel"
            max_parallel_jobs = 2
            stop_leasing = $false
        }
        task_states = [ordered]@{
            "T-01" = [ordered]@{
                status = "running"
                kind = "planned"
                active_job_id = $null
                phase_cursor = "Phase5"
            }
            "T-02" = [ordered]@{
                status = "running"
                kind = "planned"
                active_job_id = $null
                phase_cursor = "Phase5"
            }
        }
        task_groups = [ordered]@{
            "group-001" = [ordered]@{
                id = "group-001"
                status = "running"
                phase = "Phase5..Phase6"
                phase_range = "Phase5..Phase6"
                task_ids = @("T-01", "T-02")
                worker_ids = @("worker-001", "worker-002")
                failure_summary = $null
            }
            "group-002" = [ordered]@{
                id = "group-002"
                status = "succeeded"
                phase = "Phase5..Phase6"
                phase_range = "Phase5..Phase6"
                task_ids = @("T-03")
                worker_ids = @("worker-003")
            }
            "group-003" = [ordered]@{
                id = "group-003"
                status = "partial_failed"
                phase = "Phase5..Phase6"
                phase_range = "Phase5..Phase6"
                task_ids = @("T-04", "T-05")
                worker_ids = @("worker-004", "worker-005")
                failure_summary = "archived failed group"
            }
        }
        task_group_workers = [ordered]@{
            "worker-001" = [ordered]@{
                id = "worker-001"
                group_id = "group-001"
                task_id = "T-01"
                status = "running"
                phase = "Phase5"
                current_phase = "Phase5-1"
                workspace_path = "C:\tmp\worker-001"
                lease_token = "lease-001"
                declared_changed_files = @("app/a.ps1")
                resource_locks = @("file:app/a.ps1")
            }
            "worker-002" = [ordered]@{
                id = "worker-002"
                group_id = "group-001"
                task_id = "T-02"
                status = "queued"
                current_phase = "Phase5"
                declared_changed_files = @("app/b.ps1")
                resource_locks = @("file:app/b.ps1")
            }
            "worker-003" = [ordered]@{
                id = "worker-003"
                group_id = "group-002"
                task_id = "T-03"
                status = "succeeded"
                current_phase = "Phase6"
                result_summary = "done"
            }
        }
    }
}

function New-LegacyUiState {
    return [ordered]@{
        run_id = "run-legacy-ui"
        project_root = $repoRoot
        status = "running"
        current_phase = "Phase5"
        current_role = "implementer"
        current_task_id = $null
        active_job_id = $null
        active_jobs = [ordered]@{}
        task_lane = [ordered]@{
            mode = "single"
            max_parallel_jobs = 1
            stop_leasing = $false
        }
        task_states = [ordered]@{}
    }
}

$summary = New-TaskLaneSummary -RunState (New-TaskGroupUiState) -Events @(@{ type = "seeded" })
Assert-Equal @($summary["task_groups"]).Count 3 "Summary should include task group rows."
Assert-Equal @($summary["task_group_workers"]).Count 3 "Summary should include task group worker rows."
Assert-Equal $summary["task_groups"][0]["group_id"] "group-001" "Group row should expose normalized group id."
Assert-Equal $summary["task_groups"][0]["status"] "running" "Group row should expose status."
Assert-Equal $summary["task_groups"][0]["phase"] "Phase5..Phase6" "Group row should expose phase."
Assert-Equal $summary["task_groups"][0]["current_phase"] "Phase5..Phase6" "Group row should expose normalized current phase."
Assert-Equal $summary["task_groups"][0]["task_ids"][1] "T-02" "Group row should expose task ids."
Assert-Equal $summary["task_groups"][0]["worker_ids"][0] "worker-001" "Group row should expose worker ids."
Assert-Equal $summary["task_group_workers"][0]["worker_id"] "worker-001" "Worker row should expose normalized worker id."
Assert-Equal $summary["task_group_workers"][0]["group_id"] "group-001" "Worker row should expose group id."
Assert-Equal $summary["task_group_workers"][0]["task_id"] "T-01" "Worker row should expose task id."
Assert-Equal $summary["task_group_workers"][0]["phase"] "Phase5-1" "Worker row should prefer current_phase for display."
Assert-Equal $summary["task_group_workers"][0]["declared_changed_files"][0] "app/a.ps1" "Worker row should expose declared changed files."
Assert-Equal $summary["task_group_workers"][0]["resource_locks"][0] "file:app/a.ps1" "Worker row should expose resource locks."
Assert-Equal ([int]$summary["active_task_group_count"]) 1 "Summary should count active task groups."
Assert-Equal ([int]$summary["running_task_group_count"]) 1 "Summary should count running task groups."
Assert-Equal ([int]$summary["running_task_group_worker_count"]) 1 "Summary should count running task group workers."
$idleRunningTask = @($summary["waiting_tasks"] | Where-Object { $_["task_id"] -eq "T-01" })[0]
Assert-Equal $idleRunningTask["launch_block_reason"] "running_without_active_job" "Running task rows without active jobs should explain the idle state."

$summaryText = New-RunSummaryText -RunState (New-TaskGroupUiState) -Events @()
Assert-True ($summaryText.Contains("Groups: 1 active, 1 running, 1 workers running.")) "Run summary should render task group status."

$legacySummary = New-TaskLaneSummary -RunState (New-LegacyUiState) -Events @()
Assert-Equal @($legacySummary["task_groups"]).Count 0 "Legacy summary should expose empty task_groups."
Assert-Equal @($legacySummary["task_group_workers"]).Count 0 "Legacy summary should expose empty task_group_workers."
Assert-Equal ([int]$legacySummary["active_task_group_count"]) 0 "Legacy summary should expose zero active task groups."

$legacySummaryText = New-RunSummaryText -RunState (New-LegacyUiState) -Events @()
Assert-True ($legacySummaryText.Contains("Run run-legacy-ui is running at Phase5")) "Legacy run summary should still render."
Assert-True (-not $legacySummaryText.Contains("Groups:")) "Legacy run summary should not add group text."

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-ui failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-ui passed." -ForegroundColor Green
exit 0
