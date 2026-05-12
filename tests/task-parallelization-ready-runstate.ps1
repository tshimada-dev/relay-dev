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

function Assert-Throws {
    param(
        [scriptblock]$Script,
        [Parameter(Mandatory)][string]$Message
    )

    $threw = $false
    try {
        & $Script
    }
    catch {
        $threw = $true
    }

    Assert-True $threw $Message
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-ready-runstate-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $defaultState = New-RunState -RunId "run-default" -ProjectRoot $tempRoot
    Assert-Equal $defaultState["task_lane"]["mode"] "single" "New run-state should keep task_lane.mode single by default."
    Assert-Equal ([int]$defaultState["task_lane"]["max_parallel_jobs"]) 1 "New run-state should default max_parallel_jobs to 1."

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
            mode = "parallel"
            max_parallel_jobs = "0"
        }
        task_states = @{}
        phase_history = @()
        open_requirements = @()
        created_at = (Get-Date).ToString("o")
        updated_at = (Get-Date).ToString("o")
    }
    $normalizedLegacyState = Initialize-RunStateCompatibilityFields -RunState $legacyState
    Assert-Equal ([int]$normalizedLegacyState["task_lane"]["max_parallel_jobs"]) 1 "Initializer should normalize invalid max_parallel_jobs to at least 1."

    $singleState = New-RunState -RunId "run-single" -ProjectRoot $tempRoot
    $singleFirst = Add-RunStateActiveJobLease -RunState $singleState -JobSpec @{
        job_id = "job-single-1"
        task_id = "T-single-1"
        phase = "Phase5"
        role = "implementer"
    }
    Assert-Throws {
        Add-RunStateActiveJobLease -RunState $singleFirst["run_state"] -JobSpec @{
            job_id = "job-single-2"
            task_id = "T-single-2"
            phase = "Phase5"
            role = "implementer"
        } | Out-Null
    } "Single mode should reject an additional active job."

    $parallelState = New-RunState -RunId "run-parallel" -ProjectRoot $tempRoot
    $parallelState["task_lane"]["mode"] = "parallel"
    $parallelState["task_lane"]["max_parallel_jobs"] = 2

    $parallelFirst = Add-RunStateActiveJobLease -RunState $parallelState -JobSpec @{
        job_id = "job-parallel-1"
        task_id = "T-parallel-1"
        phase = "Phase5"
        role = "implementer"
        resource_locks = @("ui-shell", "api-client")
        parallel_safety = "parallel"
        slot_id = "slot-a"
        workspace_id = "workspace-a"
    } -LeaseOwner "ready-tests"
    $afterFirst = $parallelFirst["run_state"]

    Assert-Equal $afterFirst["active_job_id"] "job-parallel-1" "Compatibility active_job_id should point at the first active job."

    $firstLease = ConvertTo-RelayHashtable -InputObject $afterFirst["active_jobs"]["job-parallel-1"]
    Assert-Equal $firstLease["slot_id"] "slot-a" "Lease should preserve slot_id from the job spec."
    Assert-Equal $firstLease["workspace_id"] "workspace-a" "Lease should preserve workspace_id as metadata."
    Assert-Equal $firstLease["parallel_safety"] "parallel" "Lease should preserve parallel_safety metadata."
    Assert-Equal @($firstLease["resource_locks"]).Count 2 "Lease should preserve resource_locks metadata."
    Assert-Equal @($firstLease["resource_locks"])[0] "ui-shell" "Lease should preserve resource_locks order."

    $parallelSecond = Add-RunStateActiveJobLease -RunState $afterFirst -JobSpec @{
        job_id = "job-parallel-2"
        task_id = "T-parallel-2"
        phase = "Phase5"
        role = "implementer"
        resource_locks = @("docs")
        parallel_safety = "cautious"
        slot_id = "slot-b"
        workspace_id = "workspace-b"
    } -LeaseOwner "ready-tests"
    $afterSecond = $parallelSecond["run_state"]

    Assert-Equal @($afterSecond["active_jobs"].Keys).Count 2 "Parallel mode should allow active jobs up to max_parallel_jobs."
    Assert-Equal $afterSecond["active_job_id"] "job-parallel-1" "Compatibility active_job_id should remain stable when a second lease is added."
    Assert-Equal $afterSecond["active_jobs"]["job-parallel-2"]["slot_id"] "slot-b" "Second lease should preserve slot metadata."
    Assert-Equal $afterSecond["active_jobs"]["job-parallel-2"]["workspace_id"] "workspace-b" "Second lease should preserve workspace metadata only."

    Assert-Throws {
        Add-RunStateActiveJobLease -RunState $afterSecond -JobSpec @{
            job_id = "job-parallel-3"
            task_id = "T-parallel-3"
            phase = "Phase5"
            role = "implementer"
        } | Out-Null
    } "Parallel mode should reject active jobs beyond max_parallel_jobs."

    Assert-Throws {
        Add-RunStateActiveJobLease -RunState $afterFirst -JobSpec @{
            job_id = "job-duplicate-task"
            task_id = "T-parallel-1"
            phase = "Phase5"
            role = "implementer"
        } | Out-Null
    } "Run-state should reject a duplicate lease for the same task_id."

    $afterClearFirst = Clear-RunStateActiveJobLease -RunState $afterSecond -JobId "job-parallel-1"
    Assert-Equal @($afterClearFirst["active_jobs"].Keys).Count 1 "Clearing one lease should keep other parallel leases active."
    Assert-Equal $afterClearFirst["active_job_id"] "job-parallel-2" "Compatibility active_job_id should move to a remaining active job when its job is cleared."
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-ready-runstate failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-ready-runstate passed." -ForegroundColor Green
exit 0
