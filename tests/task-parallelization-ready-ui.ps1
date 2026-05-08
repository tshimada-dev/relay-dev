$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\workflow-engine.ps1")
. (Join-Path $repoRoot "app\ui\task-lane-summary.ps1")
. (Join-Path $repoRoot "app\ui\dashboard-renderer.ps1")
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

function New-ParallelUiState {
    return [ordered]@{
        run_id = "run-prp-04"
        project_root = $repoRoot
        status = "running"
        current_phase = "Phase5"
        current_role = "implementer"
        current_task_id = $null
        updated_at = "2026-05-08T00:00:00Z"
        open_requirements = @()
        active_job_id = "job-active"
        active_jobs = [ordered]@{
            "job-active" = [ordered]@{
                job_id = "job-active"
                task_id = "T-active"
                phase = "Phase5"
                role = "implementer"
                resource_locks = @("docs")
                parallel_safety = "parallel"
                slot_id = "slot-1"
            }
        }
        task_lane = [ordered]@{
            mode = "parallel"
            max_parallel_jobs = 3
            stop_leasing = $false
        }
        task_order = @("T-active", "T-ready-a", "T-ready-b")
        pending_approval = $null
        task_states = [ordered]@{
            "T-active" = [ordered]@{
                status = "running"
                kind = "planned"
                active_job_id = "job-active"
                wait_reason = $null
                phase_cursor = "Phase5"
                depends_on = @()
            }
            "T-ready-a" = [ordered]@{
                status = "ready"
                kind = "planned"
                active_job_id = $null
                wait_reason = $null
                phase_cursor = "Phase5"
                resource_locks = @("ui")
                parallel_safety = "parallel"
                depends_on = @()
            }
            "T-ready-b" = [ordered]@{
                status = "ready"
                kind = "planned"
                active_job_id = $null
                wait_reason = $null
                phase_cursor = "Phase5"
                resource_locks = @("api")
                parallel_safety = "cautious"
                depends_on = @()
            }
        }
    }
}

$summary = New-TaskLaneSummary -RunState (New-ParallelUiState) -Events @(@{ type = "test" })
Assert-Equal ([int]$summary["used_slots"]) 1 "Summary should count active slots."
Assert-Equal ([int]$summary["max_parallel_jobs"]) 3 "Summary should expose normalized max parallel jobs."
Assert-Equal ([int]$summary["capacity_remaining"]) 2 "Summary should expose remaining lane capacity."
Assert-Equal ([bool]$summary["capacity_full"]) $false "Summary should report capacity_full=false while capacity remains."
Assert-Equal @($summary["lease_candidates"]).Count 2 "Summary should derive lease candidates up to remaining capacity."
Assert-Equal $summary["lease_candidates"][0]["task_id"] "T-ready-a" "First lease candidate should preserve task order."
Assert-Equal $summary["lease_candidates"][0]["slot_id"] "slot-02" "First derived candidate should use the next slot."
Assert-Equal $summary["lease_candidates"][1]["resource_locks"][0] "api" "Lease candidates should include resource locks."

$fullState = New-ParallelUiState
$fullState["task_lane"]["max_parallel_jobs"] = 1
$fullSummary = New-TaskLaneSummary -RunState $fullState
Assert-Equal ([int]$fullSummary["capacity_remaining"]) 0 "Full summary should expose zero remaining capacity."
Assert-Equal ([bool]$fullSummary["capacity_full"]) $true "Full summary should expose capacity_full=true."
Assert-Equal $fullSummary["stall_reason"] "capacity_full" "Full slots should use capacity_full rather than job_in_progress."
Assert-Equal @($fullSummary["lease_candidates"]).Count 0 "Full summary should not derive lease candidates."

$dashboard = New-RunDashboardSummary -RunState (New-ParallelUiState)
Assert-True ($dashboard.Contains("remaining=2")) "Dashboard should render capacity remaining."
Assert-True ($dashboard.Contains("- Lease Candidates: 2")) "Dashboard should render lease candidate count."

$summaryText = New-RunSummaryText -RunState (New-ParallelUiState) -Events @()
Assert-True ($summaryText.Contains("capacity remaining 2")) "Run summary should render capacity remaining."
Assert-True ($summaryText.Contains("lease candidates 2")) "Run summary should render lease candidate count."

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-ready-ui failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-ready-ui passed." -ForegroundColor Green
