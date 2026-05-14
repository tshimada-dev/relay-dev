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

$resyncedArtifact = [ordered]@{
    tasks = @(
        (New-TestTask -TaskId "T-ready" -ResourceLocks @("ui-shell") -ParallelSafety "parallel"),
        (New-TestTask -TaskId "T-dependent" -Dependencies @() -ParallelSafety "parallel")
    )
}
$resyncedState = Register-PlannedTasks -RunState $state -TasksArtifact $resyncedArtifact
$resyncedTask = ConvertTo-RelayHashtable -InputObject $resyncedState["task_states"]["T-dependent"]
Assert-Equal @($resyncedTask["depends_on"]).Count 0 "Planned task dependencies should resync from the current Phase4 task artifact."
Assert-Equal $resyncedTask["status"] "ready" "A task unblocked by Phase4 dependency resync should become ready."

$staleDependencyState = ConvertTo-RelayHashtable -InputObject $state
$staleDependencyTask = ConvertTo-RelayHashtable -InputObject $staleDependencyState["task_states"]["T-dependent"]
$staleDependencyTask["depends_on"] = @()
$staleDependencyTask["status"] = "ready"
$staleDependencyState["task_states"]["T-dependent"] = $staleDependencyTask
$contractDependencyEligibility = Test-TaskDispatchEligibility -RunState $staleDependencyState -ProjectRoot $root -TaskId "T-dependent"
Assert-Equal ([bool]$contractDependencyEligibility["eligible"]) $false "Task contract dependencies should still block dispatch when run-state depends_on is stale."
Assert-ArrayContains $contractDependencyEligibility["blocked_by"] "T-ready" "Contract dependency waits should identify the blocking task id."

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

$completedCursorFixture = New-SchedulerFixture
$completedCursorState = $completedCursorFixture["state"]
$completedCursorTask = ConvertTo-RelayHashtable -InputObject $completedCursorState["task_states"]["T-ready"]
$completedCursorTask["status"] = "completed"
$completedCursorTask["last_completed_phase"] = "Phase6"
$completedCursorTask["phase_cursor"] = "Phase6"
$completedCursorState["task_states"]["T-ready"] = $completedCursorTask
$completedCursorState = Set-RunStateCursor -RunState $completedCursorState -Phase "Phase5" -TaskId "T-ready"
$completedCursorAction = Get-NextAction -RunState $completedCursorState -ProjectRoot ([string]$completedCursorFixture["root"])
Assert-Equal $completedCursorAction["type"] "DispatchJob" "Get-NextAction should recover from a stale completed task cursor."
Assert-Equal $completedCursorAction["task_id"] "T-dependent" "Get-NextAction should dispatch the next ready task instead of rerunning a completed cursor task."

$allEligibility = @(Get-TaskDispatchEligibility -RunState $sequentialFixture["state"] -ProjectRoot ([string]$sequentialFixture["root"]))
Assert-Equal $allEligibility.Count 6 "Scheduler helper should derive one eligibility row per task without persisting ready_queue."

$phaseFixture = New-SchedulerFixture
$phaseState = $phaseFixture["state"]
$phaseState["task_lane"]["mode"] = "parallel"
$phaseState["task_lane"]["max_parallel_jobs"] = 3
$phaseCandidates = @(Get-BatchLeaseCandidates -RunState $phaseState -ProjectRoot ([string]$phaseFixture["root"]))
Assert-True ($phaseCandidates.Count -gt 0) "Ready tasks without a cursor should be launchable in Phase5."

$currentCursorFixture = New-SchedulerFixture
$currentCursorState = $currentCursorFixture["state"]
$currentCursorState["task_lane"]["mode"] = "parallel"
$currentCursorState["task_lane"]["max_parallel_jobs"] = 2
$currentCursorState = Set-RunStateCursor -RunState $currentCursorState -Phase "Phase5" -TaskId "T-ready"
$currentCursorCandidates = @(Get-BatchLeaseCandidates -RunState $currentCursorState -ProjectRoot ([string]$currentCursorFixture["root"]))
$currentCursorTaskIds = @($currentCursorCandidates | ForEach-Object { [string]$_["task_id"] })
Assert-ArrayContains $currentCursorTaskIds "T-ready" "Current task cursor waiting for dispatch should remain launchable in a parallel Phase5 batch."

$reviewPhaseState = Set-RunStateCursor -RunState $phaseState -Phase "Phase5-1" -TaskId $null
$reviewPhaseCandidates = @(Get-BatchLeaseCandidates -RunState $reviewPhaseState -ProjectRoot ([string]$phaseFixture["root"]))
$reviewPhaseCandidateIds = @($reviewPhaseCandidates | ForEach-Object { [string]$_["task_id"] })
$reviewPhaseCandidatePhases = @($reviewPhaseCandidates | ForEach-Object { [string]$_["phase"] })
Assert-True ($reviewPhaseCandidates.Count -gt 0) "Ready tasks without a cursor should still be launchable as Phase5 while another lane is in a reviewer phase."
Assert-ArrayContains $reviewPhaseCandidateIds "T-ready" "Mixed-phase batches should include ready tasks as fresh Phase5 work."
Assert-ArrayContains $reviewPhaseCandidatePhases "Phase5" "Ready tasks launched during a reviewer phase should keep their own Phase5 cursor."

$reviewCursorFixture = New-SchedulerFixture
$reviewCursorState = $reviewCursorFixture["state"]
$reviewCursorState["task_lane"]["mode"] = "parallel"
$reviewCursorState["task_lane"]["max_parallel_jobs"] = 2
$reviewCursorTask = ConvertTo-RelayHashtable -InputObject $reviewCursorState["task_states"]["T-ready"]
$reviewCursorTask["status"] = "in_progress"
$reviewCursorTask["last_completed_phase"] = "Phase5"
$reviewCursorTask["phase_cursor"] = "Phase5-1"
$reviewCursorState["task_states"]["T-ready"] = $reviewCursorTask
$reviewCursorState = Set-RunStateCursor -RunState $reviewCursorState -Phase "Phase5-1" -TaskId $null
$reviewCursorCandidates = @(Get-BatchLeaseCandidates -RunState $reviewCursorState -ProjectRoot ([string]$reviewCursorFixture["root"]))
$reviewCursorTaskIds = @($reviewCursorCandidates | ForEach-Object { [string]$_["task_id"] })
Assert-ArrayContains $reviewCursorTaskIds "T-ready" "Task lanes that already advanced to a reviewer phase should be launchable when the global cursor reaches that phase."

$mixedPhaseFixture = New-SchedulerFixture
$mixedPhaseState = $mixedPhaseFixture["state"]
$mixedPhaseState["task_lane"]["mode"] = "parallel"
$mixedPhaseState["task_lane"]["max_parallel_jobs"] = 3
$mixedPhaseDoneTask = ConvertTo-RelayHashtable -InputObject $mixedPhaseState["task_states"]["T-ready"]
$mixedPhaseDoneTask["status"] = "in_progress"
$mixedPhaseDoneTask["last_completed_phase"] = "Phase5-2"
$mixedPhaseDoneTask["phase_cursor"] = "Phase6"
$mixedPhaseState["task_states"]["T-ready"] = $mixedPhaseDoneTask
$mixedPhaseNewTask = ConvertTo-RelayHashtable -InputObject $mixedPhaseState["task_states"]["T-api"]
$mixedPhaseNewTask["status"] = "ready"
$mixedPhaseNewTask["phase_cursor"] = $null
$mixedPhaseState["task_states"]["T-api"] = $mixedPhaseNewTask
$mixedPhaseState = Set-RunStateCursor -RunState $mixedPhaseState -Phase "Phase5" -TaskId "T-api"
$mixedPhaseCandidates = @(Get-BatchLeaseCandidates -RunState $mixedPhaseState -ProjectRoot ([string]$mixedPhaseFixture["root"]))
$mixedPhaseRows = @{}
foreach ($candidate in $mixedPhaseCandidates) {
    $mixedPhaseRows[[string]$candidate["task_id"]] = $candidate
}
Assert-True ($mixedPhaseRows.ContainsKey("T-ready")) "A lane waiting on Phase6 should remain launchable while another task is back in Phase5."
Assert-Equal $mixedPhaseRows["T-ready"]["phase"] "Phase6" "Mixed-phase scheduler should lease the task's own phase cursor."
Assert-Equal $mixedPhaseRows["T-ready"]["role"] "reviewer" "Mixed-phase scheduler should resolve role from the candidate phase."
Assert-True ($mixedPhaseRows.ContainsKey("T-api")) "A fresh ready task should still be launchable in the same mixed-phase batch."
Assert-Equal $mixedPhaseRows["T-api"]["phase"] "Phase5" "Fresh ready tasks should launch at Phase5 in a mixed-phase batch."

$barrierFixture = New-SchedulerFixture
$barrierState = $barrierFixture["state"]
$barrierState["task_lane"]["mode"] = "parallel"
$barrierState["task_lane"]["max_parallel_jobs"] = 2
$barrierState = Add-RunStateActiveJobLease -RunState $barrierState -JobSpec @{
    job_id = "job-ready"
    task_id = "T-ready"
    phase = "Phase5"
    role = "implementer"
    resource_locks = @("ui-shell")
    parallel_safety = "parallel"
} | ForEach-Object { $_["run_state"] }
$barrierState = Add-RunStateActiveJobLease -RunState $barrierState -JobSpec @{
    job_id = "job-api"
    task_id = "T-api"
    phase = "Phase5"
    role = "implementer"
    resource_locks = @("api")
    parallel_safety = "parallel"
} | ForEach-Object { $_["run_state"] }
$barrierMutation = Apply-JobResult -RunState $barrierState -JobResult @{
    job_id = "job-ready"
    task_id = "T-ready"
    phase = "Phase5"
    result_status = "succeeded"
    exit_code = 0
} -ValidationResult @{ valid = $true; errors = @(); warnings = @() } -Artifact @{ task_id = "T-ready" } -ProjectRoot ([string]$barrierFixture["root"])
$barrierNextState = ConvertTo-RelayHashtable -InputObject $barrierMutation["run_state"]
$barrierAction = ConvertTo-RelayHashtable -InputObject $barrierMutation["action"]
Assert-Equal $barrierAction["type"] "WaitForParallelSiblings" "A completed Phase5 lane should not advance the global cursor while sibling Phase5 jobs are still active."
Assert-Equal $barrierNextState["current_phase"] "Phase5" "Parallel phase barrier should keep the global cursor on the current phase."
Assert-Equal $barrierNextState["task_states"]["T-ready"]["phase_cursor"] "Phase5-1" "Completed worker lane should keep its own next phase cursor."
Assert-Equal $barrierNextState["task_states"]["T-api"]["active_job_id"] "job-api" "Sibling active job should remain leased after another lane commits."

$mixedBarrierFixture = New-SchedulerFixture
$mixedBarrierState = $mixedBarrierFixture["state"]
$mixedBarrierState["task_lane"]["mode"] = "parallel"
$mixedBarrierState["task_lane"]["max_parallel_jobs"] = 2
$mixedBarrierPhase6Task = ConvertTo-RelayHashtable -InputObject $mixedBarrierState["task_states"]["T-ready"]
$mixedBarrierPhase6Task["status"] = "in_progress"
$mixedBarrierPhase6Task["last_completed_phase"] = "Phase5-2"
$mixedBarrierPhase6Task["phase_cursor"] = "Phase6"
$mixedBarrierState["task_states"]["T-ready"] = $mixedBarrierPhase6Task
$mixedBarrierPhase5Task = ConvertTo-RelayHashtable -InputObject $mixedBarrierState["task_states"]["T-api"]
$mixedBarrierPhase5Task["status"] = "in_progress"
$mixedBarrierPhase5Task["phase_cursor"] = "Phase5"
$mixedBarrierState["task_states"]["T-api"] = $mixedBarrierPhase5Task
$mixedBarrierState = Set-RunStateCursor -RunState $mixedBarrierState -Phase "Phase5" -TaskId "T-api"
$mixedBarrierState = Add-RunStateActiveJobLease -RunState $mixedBarrierState -JobSpec @{
    job_id = "job-phase6"
    task_id = "T-ready"
    phase = "Phase6"
    role = "reviewer"
    resource_locks = @("ui-shell")
    parallel_safety = "parallel"
} | ForEach-Object { $_["run_state"] }
$mixedBarrierState = Add-RunStateActiveJobLease -RunState $mixedBarrierState -JobSpec @{
    job_id = "job-phase5"
    task_id = "T-api"
    phase = "Phase5"
    role = "implementer"
    resource_locks = @("api-client")
    parallel_safety = "parallel"
} | ForEach-Object { $_["run_state"] }
$mixedBarrierMutation = Apply-JobResult -RunState $mixedBarrierState -JobResult @{
    job_id = "job-phase6"
    task_id = "T-ready"
    phase = "Phase6"
    result_status = "succeeded"
    exit_code = 0
} -ValidationResult @{ valid = $true; errors = @(); warnings = @() } -Artifact @{ task_id = "T-ready"; verdict = "go" } -ProjectRoot ([string]$mixedBarrierFixture["root"])
$mixedBarrierNextState = ConvertTo-RelayHashtable -InputObject $mixedBarrierMutation["run_state"]
$mixedBarrierAction = ConvertTo-RelayHashtable -InputObject $mixedBarrierMutation["action"]
Assert-Equal $mixedBarrierAction["type"] "WaitForParallelSiblings" "A completed Phase6 lane should not reserve a next task while another mixed-phase job is active."
Assert-Equal $mixedBarrierNextState["current_phase"] "Phase5" "Mixed-phase barrier should preserve the active sibling cursor."
Assert-Equal $mixedBarrierNextState["current_task_id"] "T-api" "Mixed-phase barrier should preserve the active sibling task cursor."
Assert-Equal $mixedBarrierNextState["task_states"]["T-ready"]["status"] "completed" "The finished Phase6 lane should still complete its own task."
Assert-Equal $mixedBarrierNextState["task_states"]["T-api"]["active_job_id"] "job-phase5" "The mixed-phase active sibling should remain leased."
Assert-Equal $mixedBarrierNextState["task_states"]["T-db"]["status"] "ready" "The next ready task should not be marked in_progress before it is leased."

$phase6RejectFixture = New-SchedulerFixture
$phase6RejectState = $phase6RejectFixture["state"]
$phase6RejectTask = ConvertTo-RelayHashtable -InputObject $phase6RejectState["task_states"]["T-ready"]
$phase6RejectTask["status"] = "in_progress"
$phase6RejectTask["last_completed_phase"] = "Phase5-2"
$phase6RejectTask["phase_cursor"] = "Phase6"
$phase6RejectState["task_states"]["T-ready"] = $phase6RejectTask
$phase6RejectState = Set-RunStateCursor -RunState $phase6RejectState -Phase "Phase6" -TaskId "T-ready"
$phase6RejectMutation = Apply-JobResult -RunState $phase6RejectState -JobResult @{
    job_id = "job-phase6-reject"
    task_id = "T-ready"
    phase = "Phase6"
    result_status = "succeeded"
    exit_code = 0
} -ValidationResult @{ valid = $true; errors = @(); warnings = @() } -Artifact @{ task_id = "T-ready"; verdict = "reject"; rollback_phase = "Phase5" } -ProjectRoot ([string]$phase6RejectFixture["root"])
$phase6RejectNextState = ConvertTo-RelayHashtable -InputObject $phase6RejectMutation["run_state"]
$phase6RejectAction = ConvertTo-RelayHashtable -InputObject $phase6RejectMutation["action"]
Assert-Equal $phase6RejectAction["type"] "Continue" "A Phase6 reject should be a rollback transition, not a task completion."
Assert-Equal $phase6RejectAction["next_phase"] "Phase5" "A Phase6 reject should honor rollback_phase."
Assert-Equal $phase6RejectAction["next_task_id"] "T-ready" "A Phase6 reject should retry the same task."
Assert-Equal $phase6RejectNextState["task_states"]["T-ready"]["status"] "in_progress" "A rejected Phase6 task should not be marked completed."
Assert-Equal $phase6RejectNextState["task_states"]["T-ready"]["phase_cursor"] "Phase5" "A rejected Phase6 task should move its lane cursor to the rollback phase."

$phase6RepairFixture = New-SchedulerFixture
$phase6RepairRoot = [string]$phase6RepairFixture["root"]
$phase6RepairRunId = [string]$phase6RepairFixture["run_id"]
$phase6RepairState = $phase6RepairFixture["state"]
Save-Artifact -ProjectRoot $phase6RepairRoot -RunId $phase6RepairRunId -Scope task -TaskId "T-ready" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
    task_id = "T-ready"
    verdict = "reject"
    rollback_phase = "Phase5"
} -AsJson | Out-Null
$phase6RepairTask = ConvertTo-RelayHashtable -InputObject $phase6RepairState["task_states"]["T-ready"]
$phase6RepairTask["status"] = "in_progress"
$phase6RepairTask["last_completed_phase"] = "Phase6"
$phase6RepairTask["phase_cursor"] = "Phase6"
$phase6RepairState["task_states"]["T-ready"] = $phase6RepairTask
$phase6RepairState = Set-RunStateCursor -RunState $phase6RepairState -Phase "Phase6" -TaskId "T-ready"
$phase6RepairResult = Repair-RejectedPhase6TaskState -RunState $phase6RepairState -ProjectRoot $phase6RepairRoot
$phase6RepairNextState = ConvertTo-RelayHashtable -InputObject $phase6RepairResult["run_state"]
Assert-Equal ([bool]$phase6RepairResult["changed"]) $true "Recovery should detect a stale in-progress task whose committed Phase6 artifact rejected."
Assert-Equal $phase6RepairNextState["task_states"]["T-ready"]["status"] "in_progress" "Recovery should reopen a task with rejected Phase6 output."
Assert-Equal $phase6RepairNextState["task_states"]["T-ready"]["phase_cursor"] "Phase5" "Recovery should restore the rollback phase cursor."
Assert-Equal $phase6RepairNextState["current_task_id"] "T-ready" "Recovery should restore the task cursor for retry."

$phase6NonTaskRepairFixture = New-SchedulerFixture
$phase6NonTaskRepairRoot = [string]$phase6NonTaskRepairFixture["root"]
$phase6NonTaskRepairRunId = [string]$phase6NonTaskRepairFixture["run_id"]
$phase6NonTaskRepairState = $phase6NonTaskRepairFixture["state"]
Save-Artifact -ProjectRoot $phase6NonTaskRepairRoot -RunId $phase6NonTaskRepairRunId -Scope task -TaskId "T-ready" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
    task_id = "T-ready"
    verdict = "reject"
    rollback_phase = "Phase4"
} -AsJson | Out-Null
$phase6NonTaskRepairTask = ConvertTo-RelayHashtable -InputObject $phase6NonTaskRepairState["task_states"]["T-ready"]
$phase6NonTaskRepairTask["status"] = "in_progress"
$phase6NonTaskRepairTask["last_completed_phase"] = "Phase6"
$phase6NonTaskRepairTask["phase_cursor"] = "Phase6"
$phase6NonTaskRepairState["task_states"]["T-ready"] = $phase6NonTaskRepairTask
$phase6NonTaskRepairResult = Repair-RejectedPhase6TaskState -RunState $phase6NonTaskRepairState -ProjectRoot $phase6NonTaskRepairRoot
$phase6NonTaskRepairNextState = ConvertTo-RelayHashtable -InputObject $phase6NonTaskRepairResult["run_state"]
Assert-Equal ([bool]$phase6NonTaskRepairResult["changed"]) $false "Recovery should leave non-task rollback phases as a design issue outside task-lane repair."
Assert-Equal $phase6NonTaskRepairNextState["task_states"]["T-ready"]["phase_cursor"] "Phase6" "Recovery should not move a task lane to a non-task rollback phase."

$phase6SiblingFixture = New-SchedulerFixture
$phase6SiblingRoot = [string]$phase6SiblingFixture["root"]
$phase6SiblingRunId = [string]$phase6SiblingFixture["run_id"]
$phase6SiblingState = $phase6SiblingFixture["state"]
Save-Artifact -ProjectRoot $phase6SiblingRoot -RunId $phase6SiblingRunId -Scope task -TaskId "T-ready" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
    task_id = "T-ready"
    verdict = "reject"
    rollback_phase = "Phase5"
} -AsJson | Out-Null
$phase6SiblingReadyTask = ConvertTo-RelayHashtable -InputObject $phase6SiblingState["task_states"]["T-ready"]
$phase6SiblingReadyTask["status"] = "in_progress"
$phase6SiblingReadyTask["last_completed_phase"] = "Phase6"
$phase6SiblingReadyTask["phase_cursor"] = "Phase6"
$phase6SiblingState["task_states"]["T-ready"] = $phase6SiblingReadyTask
$phase6SiblingApiTask = ConvertTo-RelayHashtable -InputObject $phase6SiblingState["task_states"]["T-api"]
$phase6SiblingApiTask["status"] = "in_progress"
$phase6SiblingApiTask["phase_cursor"] = "Phase5"
$phase6SiblingApiTask["active_job_id"] = "job-active-sibling"
$phase6SiblingState["task_states"]["T-api"] = $phase6SiblingApiTask
$phase6SiblingState["active_jobs"] = @{
    "job-active-sibling" = @{
        job_id = "job-active-sibling"
        task_id = "T-api"
        phase = "Phase5"
        status = "running"
        lease_token = "token-active-sibling"
        lease_owner = "scheduler-test"
        lease_expires_at = (Get-Date).AddMinutes(10).ToString("o")
        last_heartbeat_at = (Get-Date).ToString("o")
    }
}
$phase6SiblingState["active_job_id"] = "job-active-sibling"
$phase6SiblingState = Set-RunStateCursor -RunState $phase6SiblingState -Phase "Phase5" -TaskId "T-api"
$phase6SiblingResult = Repair-RejectedPhase6TaskState -RunState $phase6SiblingState -ProjectRoot $phase6SiblingRoot
$phase6SiblingNextState = ConvertTo-RelayHashtable -InputObject $phase6SiblingResult["run_state"]
Assert-Equal ([bool]$phase6SiblingResult["changed"]) $true "Recovery should still repair the rejected task lane while a sibling job is active."
Assert-Equal $phase6SiblingNextState["task_states"]["T-ready"]["phase_cursor"] "Phase5" "Recovery should repair the rejected task lane cursor."
Assert-Equal $phase6SiblingNextState["active_job_id"] "job-active-sibling" "Recovery should not override an active sibling job."
Assert-Equal $phase6SiblingNextState["current_task_id"] "T-api" "Recovery should preserve the active sibling task cursor."
Assert-Equal $phase6SiblingNextState["current_phase"] "Phase5" "Recovery should preserve the active sibling phase cursor."

$phase6ApprovalFixture = New-SchedulerFixture
$phase6ApprovalRoot = [string]$phase6ApprovalFixture["root"]
$phase6ApprovalRunId = [string]$phase6ApprovalFixture["run_id"]
$phase6ApprovalState = $phase6ApprovalFixture["state"]
Save-Artifact -ProjectRoot $phase6ApprovalRoot -RunId $phase6ApprovalRunId -Scope task -TaskId "T-ready" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
    task_id = "T-ready"
    verdict = "reject"
    rollback_phase = "Phase5"
} -AsJson | Out-Null
$phase6ApprovalTask = ConvertTo-RelayHashtable -InputObject $phase6ApprovalState["task_states"]["T-ready"]
$phase6ApprovalTask["status"] = "in_progress"
$phase6ApprovalTask["last_completed_phase"] = "Phase6"
$phase6ApprovalTask["phase_cursor"] = "Phase6"
$phase6ApprovalState["task_states"]["T-ready"] = $phase6ApprovalTask
$phase6ApprovalState["pending_approval"] = @{
    id = "approval-existing"
    phase = "Phase5"
    task_id = "T-api"
}
$phase6ApprovalState = Set-RunStateCursor -RunState $phase6ApprovalState -Phase "Phase5" -TaskId "T-api"
$phase6ApprovalResult = Repair-RejectedPhase6TaskState -RunState $phase6ApprovalState -ProjectRoot $phase6ApprovalRoot
$phase6ApprovalNextState = ConvertTo-RelayHashtable -InputObject $phase6ApprovalResult["run_state"]
Assert-Equal ([bool]$phase6ApprovalResult["changed"]) $true "Recovery should still repair the rejected task lane while an approval is pending."
Assert-Equal $phase6ApprovalNextState["task_states"]["T-ready"]["phase_cursor"] "Phase5" "Recovery should repair the rejected task lane with pending approval present."
Assert-Equal $phase6ApprovalNextState["pending_approval"]["id"] "approval-existing" "Recovery should not override a pending approval."
Assert-Equal $phase6ApprovalNextState["current_task_id"] "T-api" "Recovery should preserve the pending approval task cursor."

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
