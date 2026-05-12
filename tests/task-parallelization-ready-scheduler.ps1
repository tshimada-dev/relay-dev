$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\artifact-validator.ps1")
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

function Assert-CandidateShape {
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$Message
    )

    foreach ($key in @("task_id", "phase", "role", "selected_task", "resource_locks", "parallel_safety", "slot_id")) {
        Assert-True ($Candidate.Contains($key)) "$Message should include '$key'."
    }
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
        [string]$ParallelSafety = "parallel"
    )

    return [ordered]@{
        task_id = $TaskId
        purpose = "Exercise batch lease planner for $TaskId"
        changed_files = @("src/$TaskId.txt")
        acceptance_criteria = @("Planner policy is respected")
        boundary_contract = (New-TestBoundaryContract -ModuleName "application/$TaskId")
        visual_contract = (New-TestVisualContract)
        dependencies = @($Dependencies)
        tests = @("pwsh -NoProfile -File tests/task-parallelization-ready-scheduler.ps1")
        complexity = "small"
        resource_locks = @($ResourceLocks)
        parallel_safety = $ParallelSafety
    }
}

function New-ReadySchedulerFixture {
    param([object[]]$Tasks)

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-ready-scheduler-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = "run-ready-scheduler"
    $tasksArtifact = [ordered]@{ tasks = @($Tasks) }

    Save-Artifact -ProjectRoot $tempRoot -RunId $runId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $tasksArtifact -AsJson | Out-Null
    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state = Register-PlannedTasks -RunState $state -TasksArtifact $tasksArtifact
    $state["task_lane"]["mode"] = "parallel"
    $state["task_lane"]["max_parallel_jobs"] = 2

    return [ordered]@{
        root = $tempRoot
        state = $state
    }
}

$independentFixture = New-ReadySchedulerFixture -Tasks @(
    (New-TestTask -TaskId "T-a" -ResourceLocks @("ui") -ParallelSafety "parallel"),
    (New-TestTask -TaskId "T-b" -ResourceLocks @("api") -ParallelSafety "parallel"),
    (New-TestTask -TaskId "T-c" -ResourceLocks @("worker") -ParallelSafety "parallel")
)
$independentState = $independentFixture["state"]
$independentBefore = @($independentState["active_jobs"].Keys).Count
$independentCandidates = @(Get-BatchLeaseCandidates -RunState $independentState -ProjectRoot ([string]$independentFixture["root"]))
Assert-Equal $independentCandidates.Count 2 "Planner should return up to remaining lane capacity."
Assert-Equal $independentCandidates[0]["task_id"] "T-a" "Planner should preserve task_order determinism for first candidate."
Assert-Equal $independentCandidates[1]["task_id"] "T-b" "Planner should preserve task_order determinism for second candidate."
Assert-Equal $independentCandidates[0]["slot_id"] "slot-01" "First derived candidate should use the first deterministic slot."
Assert-Equal $independentCandidates[1]["slot_id"] "slot-02" "Second derived candidate should use the next deterministic slot."
Assert-Equal @($independentState["active_jobs"].Keys).Count $independentBefore "Planner should not persist or create leases."
Assert-CandidateShape -Candidate $independentCandidates[0] -Message "Lease candidate row"
Assert-Equal $independentCandidates[0]["selected_task"]["task_id"] "T-a" "Planner should resolve selected_task from task contracts."

$dependencyFixture = New-ReadySchedulerFixture -Tasks @(
    (New-TestTask -TaskId "T-ready" -ResourceLocks @("ui")),
    (New-TestTask -TaskId "T-dependent" -Dependencies @("T-ready") -ResourceLocks @("api")),
    (New-TestTask -TaskId "T-other" -ResourceLocks @("worker"))
)
$dependencyCandidates = @(Get-BatchLeaseCandidates -RunState $dependencyFixture["state"] -ProjectRoot ([string]$dependencyFixture["root"]))
Assert-Equal $dependencyCandidates.Count 2 "Planner should skip dependency-blocked tasks and keep filling capacity."
Assert-Equal $dependencyCandidates[0]["task_id"] "T-ready" "Dependency fixture should keep ready task first."
Assert-Equal $dependencyCandidates[1]["task_id"] "T-other" "Dependency-blocked task should not be selected."

$lockFixture = New-ReadySchedulerFixture -Tasks @(
    (New-TestTask -TaskId "T-db-a" -ResourceLocks @("db")),
    (New-TestTask -TaskId "T-db-b" -ResourceLocks @("db")),
    (New-TestTask -TaskId "T-api" -ResourceLocks @("api"))
)
$lockCandidates = @(Get-BatchLeaseCandidates -RunState $lockFixture["state"] -ProjectRoot ([string]$lockFixture["root"]))
Assert-Equal $lockCandidates.Count 2 "Planner should skip same-batch resource-lock conflicts and keep filling capacity."
Assert-Equal $lockCandidates[0]["task_id"] "T-db-a" "First lock holder should be selected."
Assert-Equal $lockCandidates[1]["task_id"] "T-api" "Conflicting lock candidate should be excluded."

$activeFixture = New-ReadySchedulerFixture -Tasks @(
    (New-TestTask -TaskId "T-active" -ResourceLocks @("ui")),
    (New-TestTask -TaskId "T-ui" -ResourceLocks @("ui")),
    (New-TestTask -TaskId "T-api" -ResourceLocks @("api"))
)
$activeState = $activeFixture["state"]
$activeState["active_jobs"]["job-active"] = [ordered]@{
    job_id = "job-active"
    task_id = "T-active"
    phase = "Phase5"
    role = "implementer"
    resource_locks = @("ui")
    parallel_safety = "parallel"
    slot_id = "slot-01"
}
$activeCandidates = @(Get-BatchLeaseCandidates -RunState $activeState -ProjectRoot ([string]$activeFixture["root"]))
Assert-Equal $activeCandidates.Count 1 "Planner should only use remaining capacity when an active job exists."
Assert-Equal $activeCandidates[0]["task_id"] "T-api" "Planner should skip active task and active resource lock conflicts."
Assert-Equal $activeCandidates[0]["slot_id"] "slot-02" "Planner should avoid an active job slot."

$serialFixture = New-ReadySchedulerFixture -Tasks @(
    (New-TestTask -TaskId "T-serial" -ParallelSafety "serial"),
    (New-TestTask -TaskId "T-api" -ResourceLocks @("api"))
)
$serialCandidates = @(Get-BatchLeaseCandidates -RunState $serialFixture["state"] -ProjectRoot ([string]$serialFixture["root"]))
Assert-Equal $serialCandidates.Count 1 "A serial candidate should block co-dispatch."
Assert-Equal $serialCandidates[0]["task_id"] "T-serial" "Serial task may be selected when no work is active or already selected."

$stoppedFixture = New-ReadySchedulerFixture -Tasks @(
    (New-TestTask -TaskId "T-a")
)
$stoppedFixture["state"]["task_lane"]["stop_leasing"] = $true
$stoppedCandidates = @(Get-BatchLeaseCandidates -RunState $stoppedFixture["state"] -ProjectRoot ([string]$stoppedFixture["root"]))
Assert-Equal $stoppedCandidates.Count 0 "stop_leasing should suppress batch lease candidates."

$singleDispatchAction = Get-NextAction -RunState $independentFixture["state"] -ProjectRoot ([string]$independentFixture["root"])
Assert-Equal $singleDispatchAction["type"] "DispatchJob" "Get-NextAction should preserve single-dispatch behavior."
Assert-Equal $singleDispatchAction["task_id"] "T-a" "Get-NextAction should still return only the first ready task."

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-ready-scheduler failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-ready-scheduler passed." -ForegroundColor Green
