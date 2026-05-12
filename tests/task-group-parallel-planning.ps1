$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\artifact-validator.ps1")
. (Join-Path $repoRoot "app\core\workflow-engine.ps1")
. (Join-Path $repoRoot "app\core\parallel-job-packages.ps1")

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
        [string[]]$ResourceLocks = @(),
        [string[]]$ChangedFiles = @()
    )

    $effectiveChangedFiles = if (@($ChangedFiles).Count -gt 0) { @($ChangedFiles) } else { @("src/$TaskId.txt") }
    return [ordered]@{
        task_id = $TaskId
        purpose = "Exercise task-group dry-run planner for $TaskId"
        changed_files = @($effectiveChangedFiles)
        acceptance_criteria = @("Planner policy is respected")
        boundary_contract = (New-TestBoundaryContract -ModuleName "application/$TaskId")
        visual_contract = (New-TestVisualContract)
        dependencies = @()
        tests = @("pwsh -NoProfile -File tests/task-group-parallel-planning.ps1")
        complexity = "small"
        resource_locks = @($ResourceLocks)
        parallel_safety = "parallel"
    }
}

function New-PlanningFixture {
    param([object[]]$Tasks, [int]$MaxParallelJobs = 3)

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-planning-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = "run-task-group-planning"
    $tasksArtifact = [ordered]@{ tasks = @($Tasks) }

    Save-Artifact -ProjectRoot $tempRoot -RunId $runId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $tasksArtifact -AsJson | Out-Null
    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state = Register-PlannedTasks -RunState $state -TasksArtifact $tasksArtifact
    $state["task_lane"]["mode"] = "parallel"
    $state["task_lane"]["max_parallel_jobs"] = $MaxParallelJobs

    return [ordered]@{
        root = $tempRoot
        run_id = $runId
        state = $state
    }
}

$independentFixture = New-PlanningFixture -Tasks @(
    (New-TestTask -TaskId "T-a" -ResourceLocks @("ui")),
    (New-TestTask -TaskId "T-b" -ResourceLocks @("api")),
    (New-TestTask -TaskId "T-c" -ResourceLocks @("worker"))
) -MaxParallelJobs 2
$independentState = $independentFixture["state"]
$independentPlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$independentFixture["root"]) -RunState $independentState
$repeatPlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$independentFixture["root"]) -RunState $independentState
Assert-Equal $independentPlan["status"] "planned" "Independent launchable tasks should produce a group plan."
Assert-Equal @($independentPlan["workers"]).Count 2 "Group plan should include one worker per launchable candidate up to capacity."
Assert-Equal $independentPlan["group"]["id"] $repeatPlan["group"]["id"] "Dry-run group id should be deterministic."
Assert-Equal $independentPlan["workers"][0]["id"] $repeatPlan["workers"][0]["id"] "Dry-run worker ids should be deterministic."
Assert-Equal $independentPlan["workers"][0]["task_id"] "T-a" "Worker plan should preserve scheduler order."
Assert-Equal $independentPlan["workers"][1]["task_id"] "T-b" "Worker plan should preserve scheduler order for the second candidate."

$lockFixture = New-PlanningFixture -Tasks @(
    (New-TestTask -TaskId "T-file-a" -ResourceLocks @("alpha") -ChangedFiles @("src/shared.js")),
    (New-TestTask -TaskId "T-file-b" -ResourceLocks @("beta") -ChangedFiles @(".\src\shared.js")),
    (New-TestTask -TaskId "T-lock-a" -ResourceLocks @("db") -ChangedFiles @("src/db-a.js")),
    (New-TestTask -TaskId "T-lock-b" -ResourceLocks @("db") -ChangedFiles @("src/db-b.js")),
    (New-TestTask -TaskId "T-free" -ResourceLocks @("free") -ChangedFiles @("src/free.js"))
) -MaxParallelJobs 5
$lockPlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$lockFixture["root"]) -RunState $lockFixture["state"]
$lockTaskIds = @($lockPlan["workers"] | ForEach-Object { [string]$_["task_id"] })
Assert-Equal $lockPlan["status"] "planned" "Non-conflicting candidates should still produce a group plan."
Assert-ArrayContains $lockTaskIds "T-file-a" "The first changed-file lock holder should be included."
Assert-ArrayNotContains $lockTaskIds "T-file-b" "A candidate touching the same changed file should not be included in the same group."
Assert-ArrayContains $lockTaskIds "T-lock-a" "The first explicit resource lock holder should be included."
Assert-ArrayNotContains $lockTaskIds "T-lock-b" "A candidate sharing an explicit resource lock should not be included in the same group."
Assert-ArrayContains $lockTaskIds "T-free" "Independent candidate should fill remaining group capacity."

$dryRunFixture = New-PlanningFixture -Tasks @(
    (New-TestTask -TaskId "T-dry-a" -ResourceLocks @("dry-a")),
    (New-TestTask -TaskId "T-dry-b" -ResourceLocks @("dry-b"))
) -MaxParallelJobs 2
$dryRunState = $dryRunFixture["state"]
$activeBefore = @($dryRunState["active_jobs"].Keys).Count
$groupsBefore = @($dryRunState["task_groups"].Keys).Count
$workersBefore = @($dryRunState["task_group_workers"].Keys).Count
$dryRunPlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$dryRunFixture["root"]) -RunState $dryRunState
Assert-Equal $dryRunPlan["status"] "planned" "Dry-run fixture should produce a plan."
Assert-Equal @($dryRunState["active_jobs"].Keys).Count $activeBefore "Dry-run planning should not add active job leases."
Assert-Equal @($dryRunState["task_groups"].Keys).Count $groupsBefore "Dry-run planning should not add task groups."
Assert-Equal @($dryRunState["task_group_workers"].Keys).Count $workersBefore "Dry-run planning should not add task group workers."
Assert-Equal @($dryRunPlan["run_state"]["active_jobs"].Keys).Count $activeBefore "Returned run_state should not contain new active job leases."
Assert-Equal @($dryRunPlan["run_state"]["task_groups"].Keys).Count $groupsBefore "Returned run_state should not contain new task groups."
Assert-Equal @($dryRunPlan["run_state"]["task_group_workers"].Keys).Count $workersBefore "Returned run_state should not contain new task group workers."

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-planning failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-planning passed." -ForegroundColor Green
exit 0
