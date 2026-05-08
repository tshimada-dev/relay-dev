$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\artifact-validator.ps1")
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

function Assert-ArrayContains {
    param(
        [AllowNull()]$Items,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True ($Expected -in @($Items)) $Message
}

function Assert-ArrayNotContains {
    param(
        [AllowNull()]$Items,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True ($Expected -notin @($Items)) $Message
}

function New-TestBoundaryContract {
    param([string]$ModuleName)

    return [ordered]@{
        module_boundaries = @($ModuleName)
        public_interfaces = @("$ModuleName public API")
        allowed_dependencies = @("$ModuleName -> domain")
        forbidden_dependencies = @("$ModuleName -> infra/db direct")
        side_effect_boundaries = @("$ModuleName owns its side-effect adapter")
        state_ownership = @("$ModuleName owns its local state")
    }
}

function New-TestVisualContract {
    return [ordered]@{
        mode = "not_applicable"
        design_sources = @()
        visual_constraints = @()
        component_patterns = @()
        responsive_expectations = @()
        interaction_guidelines = @()
    }
}

function New-TestTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string[]]$Dependencies = @(),
        [string[]]$ResourceLocks = @(),
        [string]$ParallelSafety = "cautious",
        [string[]]$ChangedFiles = @()
    )

    $effectiveChangedFiles = if (@($ChangedFiles).Count -gt 0) { @($ChangedFiles) } else { @("src/$TaskId.txt") }

    return [ordered]@{
        task_id = $TaskId
        purpose = "Exercise scheduler policy for $TaskId"
        changed_files = @($effectiveChangedFiles)
        acceptance_criteria = @("Policy is explained")
        boundary_contract = (New-TestBoundaryContract -ModuleName "application/$TaskId")
        visual_contract = (New-TestVisualContract)
        dependencies = @($Dependencies)
        tests = @("pwsh -NoProfile -File tests/task-parallelization-scheduler.ps1")
        complexity = "small"
        resource_locks = @($ResourceLocks)
        parallel_safety = $ParallelSafety
    }
}

function New-SchedulerFixture {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-scheduler-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = "run-scheduler"
    $tasksArtifact = [ordered]@{
        tasks = @(
            (New-TestTask -TaskId "T-ready" -ResourceLocks @("ui-shell") -ParallelSafety "parallel"),
            (New-TestTask -TaskId "T-dependent" -Dependencies @("T-ready")),
            (New-TestTask -TaskId "T-db" -ResourceLocks @("db-schema") -ParallelSafety "cautious"),
            (New-TestTask -TaskId "T-db-other" -ResourceLocks @("db-schema") -ParallelSafety "parallel"),
            (New-TestTask -TaskId "T-serial" -ParallelSafety "serial"),
            (New-TestTask -TaskId "T-api" -ResourceLocks @("api-client") -ParallelSafety "parallel")
        )
    }

    Save-Artifact -ProjectRoot $tempRoot -RunId $runId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $tasksArtifact -AsJson | Out-Null
    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state = Register-PlannedTasks -RunState $state -TasksArtifact $tasksArtifact

    return [ordered]@{
        root = $tempRoot
        run_id = $runId
        state = $state
    }
}

# CPS-01 contract validation assertions.
$validSafetyArtifact = [ordered]@{
    tasks = @(
        (New-TestTask -TaskId "T-valid-safety" -ResourceLocks @("db-schema") -ParallelSafety "serial")
    )
}
$validSafetyResult = Test-ArtifactContract -ArtifactId "phase4_tasks.json" -Artifact $validSafetyArtifact -Phase "Phase4"
Assert-Equal ([bool]$validSafetyResult["valid"]) $true "Phase4 task safety fields should validate when resource_locks and parallel_safety are valid."

$legacySafetyArtifact = [ordered]@{
    tasks = @(
        (New-TestTask -TaskId "T-legacy-safety")
    )
}
$legacySafetyArtifact["tasks"][0].Remove("resource_locks")
$legacySafetyArtifact["tasks"][0].Remove("parallel_safety")
$legacySafetyResult = Test-ArtifactContract -ArtifactId "phase4_tasks.json" -Artifact $legacySafetyArtifact -Phase "Phase4"
Assert-Equal ([bool]$legacySafetyResult["valid"]) $true "Phase4 tasks should remain backwards compatible when optional safety fields are missing."

$invalidParallelSafetyArtifact = [ordered]@{
    tasks = @(
        (New-TestTask -TaskId "T-invalid-safety" -ParallelSafety "reckless")
    )
}
$invalidParallelSafetyResult = Test-ArtifactContract -ArtifactId "phase4_tasks.json" -Artifact $invalidParallelSafetyArtifact -Phase "Phase4"
Assert-Equal ([bool]$invalidParallelSafetyResult["valid"]) $false "Invalid parallel_safety should fail Phase4 task validation."

$invalidResourceLockArtifact = [ordered]@{
    tasks = @(
        (New-TestTask -TaskId "T-invalid-lock" -ResourceLocks @("db-schema", ""))
    )
}
$invalidResourceLockResult = Test-ArtifactContract -ArtifactId "phase4_tasks.json" -Artifact $invalidResourceLockArtifact -Phase "Phase4"
Assert-Equal ([bool]$invalidResourceLockResult["valid"]) $false "Empty resource_locks entries should fail Phase4 task validation."

# Scheduler policy assertions for CPS-02.

$fixture = New-SchedulerFixture
$root = [string]$fixture["root"]
$state = $fixture["state"]

$dependencyEligibility = Test-TaskDispatchEligibility -RunState $state -ProjectRoot $root -TaskId "T-dependent"
Assert-Equal ([bool]$dependencyEligibility["eligible"]) $false "Unmet dependencies should make a task ineligible."
Assert-Equal $dependencyEligibility["wait_reason"] "dependencies" "Unmet dependencies should report wait_reason dependencies."
Assert-ArrayContains $dependencyEligibility["blocked_by"] "T-ready" "Dependency waits should identify blocking task ids."

$resourceLease = Add-RunStateActiveJobLease -RunState $state -JobSpec @{
    job_id = "job-db"
    task_id = "T-db"
    phase = "Phase5"
    role = "implementer"
    resource_locks = @("db-schema")
    parallel_safety = "cautious"
}
$resourceState = $resourceLease["run_state"]
$resourceEligibility = Test-TaskDispatchEligibility -RunState $resourceState -ProjectRoot $root -TaskId "T-db-other"
Assert-Equal ([bool]$resourceEligibility["eligible"]) $false "A task should be ineligible when an active job holds the same resource lock."
Assert-Equal $resourceEligibility["wait_reason"] "resource_lock" "Resource conflicts should report wait_reason resource_lock."
Assert-ArrayContains $resourceEligibility["blocked_by"] "db-schema" "Resource lock waits should put lock ids in blocked_by."
Assert-ArrayContains $resourceEligibility["blocked_by_jobs"] "job-db" "Resource lock waits may include blocking job attribution."
Assert-ArrayContains $resourceEligibility["blocked_by_tasks"] "T-db" "Resource lock waits may include blocking task attribution."

$fileOverlapRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-scheduler-file-lock-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fileOverlapRoot -Force | Out-Null
$fileOverlapRunId = "run-file-lock"
$fileOverlapTasksArtifact = [ordered]@{
    tasks = @(
        (New-TestTask -TaskId "T-file-a" -ResourceLocks @("alpha") -ParallelSafety "parallel" -ChangedFiles @("src/shared.js")),
        (New-TestTask -TaskId "T-file-b" -ResourceLocks @("beta") -ParallelSafety "parallel" -ChangedFiles @(".\src\shared.js")),
        (New-TestTask -TaskId "T-file-c" -ResourceLocks @("gamma") -ParallelSafety "parallel" -ChangedFiles @("src/independent.js"))
    )
}
Save-Artifact -ProjectRoot $fileOverlapRoot -RunId $fileOverlapRunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $fileOverlapTasksArtifact -AsJson | Out-Null
$fileOverlapState = New-RunState -RunId $fileOverlapRunId -ProjectRoot $fileOverlapRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
$fileOverlapState = Register-PlannedTasks -RunState $fileOverlapState -TasksArtifact $fileOverlapTasksArtifact
$fileOverlapState["task_lane"]["mode"] = "parallel"
$fileOverlapState["task_lane"]["max_parallel_jobs"] = 3
$fileOverlapCandidates = @(Get-BatchLeaseCandidates -RunState $fileOverlapState -ProjectRoot $fileOverlapRoot)
$fileOverlapCandidateIds = @($fileOverlapCandidates | ForEach-Object { [string]$_["task_id"] })
Assert-Equal $fileOverlapCandidates.Count 2 "Changed file overlap should reduce the batch to non-conflicting tasks."
Assert-ArrayContains $fileOverlapCandidateIds "T-file-a" "The first task touching a file should remain launchable."
Assert-ArrayNotContains $fileOverlapCandidateIds "T-file-b" "A second task touching the same changed file should not be selected in the same batch."
Assert-ArrayContains $fileOverlapCandidateIds "T-file-c" "A task touching an independent file should remain launchable."

$fileOverlapLease = Add-RunStateActiveJobLease -RunState $fileOverlapState -JobSpec @{
    job_id = "job-file-a"
    task_id = "T-file-a"
    phase = "Phase5"
    role = "implementer"
    resource_locks = @("alpha")
    parallel_safety = "parallel"
}
$fileOverlapEligibility = Test-TaskDispatchEligibility -RunState $fileOverlapLease["run_state"] -ProjectRoot $fileOverlapRoot -TaskId "T-file-b"
Assert-Equal ([bool]$fileOverlapEligibility["eligible"]) $false "Changed file overlap with an active job should block dispatch even when explicit resource_locks differ."
Assert-Equal $fileOverlapEligibility["wait_reason"] "resource_lock" "Implicit file lock conflicts should use the resource_lock wait reason."
Assert-ArrayContains $fileOverlapEligibility["blocked_by"] "file:src/shared.js" "Implicit file locks should appear in blocked_by for diagnosis."

$independentEligibility = Test-TaskDispatchEligibility -RunState $resourceState -ProjectRoot $root -TaskId "T-api"
Assert-Equal ([bool]$independentEligibility["eligible"]) $true "Cautious/parallel tasks should stay eligible when dependencies and resource locks allow them."
Assert-True ($null -eq $independentEligibility["wait_reason"]) "Eligible tasks should not have a wait reason."

$serialCandidate = Test-TaskDispatchEligibility -RunState $resourceState -ProjectRoot $root -TaskId "T-serial"
Assert-Equal ([bool]$serialCandidate["eligible"]) $false "A serial task should not be eligible while any job is active."
Assert-Equal $serialCandidate["wait_reason"] "serial_safety" "Serial candidate blocked by active work should report serial_safety."
Assert-ArrayContains $serialCandidate["blocked_by_jobs"] "job-db" "Serial safety waits should identify active jobs."

$serialFixture = New-SchedulerFixture
$serialState = $serialFixture["state"]
$serialRoot = [string]$serialFixture["root"]
$serialLease = Add-RunStateActiveJobLease -RunState $serialState -JobSpec @{
    job_id = "job-serial"
    task_id = "T-serial"
    phase = "Phase5"
    role = "implementer"
    parallel_safety = "serial"
}
$blockedBySerial = Test-TaskDispatchEligibility -RunState $serialLease["run_state"] -ProjectRoot $serialRoot -TaskId "T-ready"
Assert-Equal ([bool]$blockedBySerial["eligible"]) $false "No other task should be eligible while a serial task is active."
Assert-Equal $blockedBySerial["wait_reason"] "serial_safety" "Tasks blocked by an active serial task should report serial_safety."
Assert-ArrayContains $blockedBySerial["blocked_by_jobs"] "job-serial" "Active serial waits should identify the serial job."
Assert-ArrayContains $blockedBySerial["blocked_by_tasks"] "T-serial" "Active serial waits should identify the serial task."

$stopFixture = New-SchedulerFixture
$stopState = $stopFixture["state"]
$stopState["task_lane"]["stop_leasing"] = $true
$stopEligibility = Test-TaskDispatchEligibility -RunState $stopState -ProjectRoot ([string]$stopFixture["root"]) -TaskId "T-ready"
Assert-Equal ([bool]$stopEligibility["eligible"]) $false "stop_leasing should prevent new dispatch."
Assert-Equal $stopEligibility["wait_reason"] "stop_leasing" "stop_leasing should produce a stable wait reason."

$sequentialFixture = New-SchedulerFixture
$nextAction = Get-NextAction -RunState $sequentialFixture["state"] -ProjectRoot ([string]$sequentialFixture["root"])
Assert-Equal $nextAction["type"] "DispatchJob" "Get-NextAction should preserve sequential dispatch when no job is active."
Assert-Equal $nextAction["task_id"] "T-ready" "Get-NextAction should still pick the first ready task."

$allEligibility = @(Get-TaskDispatchEligibility -RunState $sequentialFixture["state"] -ProjectRoot ([string]$sequentialFixture["root"]))
Assert-Equal $allEligibility.Count 6 "Scheduler helper should derive one eligibility row per task without persisting ready_queue."

$phaseFixture = New-SchedulerFixture
$phaseState = $phaseFixture["state"]
$phaseState["task_lane"]["mode"] = "parallel"
$phaseState["task_lane"]["max_parallel_jobs"] = 3
$phaseCandidates = @(Get-BatchLeaseCandidates -RunState $phaseState -ProjectRoot ([string]$phaseFixture["root"]))
Assert-True ($phaseCandidates.Count -gt 0) "Ready tasks without a cursor should be launchable in Phase5."

$reviewPhaseState = Set-RunStateCursor -RunState $phaseState -Phase "Phase5-1" -TaskId "T-ready"
$reviewPhaseCandidates = @(Get-BatchLeaseCandidates -RunState $reviewPhaseState -ProjectRoot ([string]$phaseFixture["root"]))
Assert-Equal $reviewPhaseCandidates.Count 0 "Ready tasks without a cursor should not be promoted into a reviewer phase batch."

# CPS-03 UI summary/rendering assertions. Keep this separate from scheduler policy tests.
$uiRunState = [ordered]@{
    run_id = "run-cps-03"
    status = "running"
    current_phase = "Phase5"
    current_role = "implementer"
    current_task_id = $null
    updated_at = "2026-05-08T00:00:00Z"
    open_requirements = @()
    active_job_id = $null
    active_jobs = @{}
    task_lane = [ordered]@{
        mode = "single"
        max_parallel_jobs = 1
        stop_leasing = $false
    }
    pending_approval = $null
    task_states = [ordered]@{
        "T-ready" = [ordered]@{
            status = "ready"
            kind = "planned"
            active_job_id = $null
            wait_reason = $null
            phase_cursor = "Phase5"
            resource_locks = @("ui")
            parallel_safety = "parallel"
            depends_on = @()
        }
        "T-lock" = [ordered]@{
            status = "waiting"
            kind = "planned"
            active_job_id = $null
            wait_reason = "resource_lock"
            blocked_by = @("db-schema")
            blocked_by_jobs = @("job-db")
            blocked_by_tasks = @("T-db")
            parallel_safety = "cautious"
            depends_on = @()
        }
        "T-serial" = [ordered]@{
            status = "waiting"
            kind = "planned"
            active_job_id = $null
            wait_reason = "serial_safety"
            blocked_by = @("job-active")
            parallel_safety = "serial"
            stall_reason = "job_in_progress"
            depends_on = @()
        }
    }
}

$uiSummary = New-TaskLaneSummary -RunState $uiRunState -Events @(@{ type = "test.event" })
Assert-Equal @($uiSummary["ready_queue"]).Count 1 "Summary should expose derived ready_queue."
Assert-Equal $uiSummary["ready_queue"][0]["task_id"] "T-ready" "Ready queue should include the ready task."
Assert-Equal $uiSummary["ready_queue"][0]["resource_locks"][0] "ui" "Ready queue should carry resource lock labels when present."
Assert-Equal @($uiSummary["waiting_tasks"]).Count 3 "Summary should expose waiting rows."

$resourceWait = @($uiSummary["waiting_tasks"] | Where-Object { $_["task_id"] -eq "T-lock" })[0]
Assert-Equal $resourceWait["wait_reason"] "resource_lock" "Waiting row should expose resource_lock wait_reason."
Assert-Equal $resourceWait["blocked_by"][0] "db-schema" "Waiting row should expose blocking resource lock id."
Assert-Equal $resourceWait["blocked_by_jobs"][0] "job-db" "Waiting row should preserve optional blocking job attribution."

$serialWait = @($uiSummary["waiting_tasks"] | Where-Object { $_["task_id"] -eq "T-serial" })[0]
Assert-Equal $serialWait["parallel_safety"] "serial" "Waiting row should expose serial safety explanation."
Assert-Equal $serialWait["stall_reason"] "job_in_progress" "Waiting row should expose lane-local stall explanation when known."
Assert-Equal $uiSummary["stall_reason"] "" "Lane should not stall while ready_queue has dispatchable work."

$lockedRunState = [ordered]@{}
foreach ($key in $uiRunState.Keys) {
    $lockedRunState[$key] = $uiRunState[$key]
}
$lockedRunState["task_states"] = [ordered]@{
    "T-lock" = $uiRunState["task_states"]["T-lock"]
}
$lockedSummary = New-TaskLaneSummary -RunState $lockedRunState
Assert-Equal $lockedSummary["stall_reason"] "resource_locked" "Lane stall should explain resource lock waits when no tasks are ready."

$stoppedRunState = [ordered]@{}
foreach ($key in $lockedRunState.Keys) {
    $stoppedRunState[$key] = $lockedRunState[$key]
}
$stoppedRunState["task_lane"] = [ordered]@{
    mode = "single"
    max_parallel_jobs = 1
    stop_leasing = $true
}
$stoppedSummary = New-TaskLaneSummary -RunState $stoppedRunState
Assert-Equal $stoppedSummary["stall_reason"] "stop_leasing" "Lane stall should prefer stop_leasing."

$dashboard = New-RunDashboardSummary -RunState $uiRunState
Assert-True ($dashboard.Contains("- Ready Queue: 1")) "Dashboard summary should render ready queue count."
Assert-True ($dashboard.Contains("- Lane Stall: -")) "Dashboard summary should render empty stall as a dash."

$summaryText = New-RunSummaryText -RunState $lockedRunState -Events @()
Assert-True ($summaryText.Contains("ready queue 0")) "Run summary should render ready queue count."
Assert-True ($summaryText.Contains("Stall: resource_locked.")) "Run summary should render stall reason."

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-scheduler failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-scheduler passed." -ForegroundColor Green
