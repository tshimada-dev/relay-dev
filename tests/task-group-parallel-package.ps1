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

function New-TestBoundaryContract {
    param([string]$ModuleName)

    return [ordered]@{
        module_boundaries = @($ModuleName)
        public_interfaces = @("$ModuleName public API")
        allowed_dependencies = @("$ModuleName -> domain")
        forbidden_dependencies = @("$ModuleName -> infra/db direct")
        side_effect_boundaries = @("$ModuleName owns its side-effect adapter")
        state_ownership = @("$ModuleName owns local state")
    }
}

function New-TestTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string]$ParallelSafety = "parallel"
    )

    return [ordered]@{
        task_id = $TaskId
        purpose = "Exercise executable task-group package for $TaskId"
        changed_files = @("src/$TaskId.txt")
        acceptance_criteria = @("Package contract is persisted")
        boundary_contract = (New-TestBoundaryContract -ModuleName "application/$TaskId")
        visual_contract = [ordered]@{
            mode = "not_applicable"
            design_sources = @()
            visual_constraints = @()
            component_patterns = @()
            responsive_expectations = @()
            interaction_guidelines = @()
        }
        dependencies = @()
        tests = @("pwsh -NoProfile -File tests/task-group-parallel-package.ps1")
        complexity = "small"
        resource_locks = @("lock-$TaskId")
        parallel_safety = $ParallelSafety
    }
}

function New-PackageFixture {
    param(
        [string]$FirstSafety = "parallel",
        [string]$SecondSafety = "parallel"
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-package-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = "run-task-group-package"
    $tasksArtifact = [ordered]@{ tasks = @((New-TestTask -TaskId "T-pack-a" -ParallelSafety $FirstSafety), (New-TestTask -TaskId "T-pack-b" -ParallelSafety $SecondSafety)) }

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

$provider = [ordered]@{
    provider = "fake"
    command = "pwsh"
    flags = "-NoProfile"
}

$dryRunFixture = New-PackageFixture
$dryRunState = $dryRunFixture["state"]
$groupsBefore = @($dryRunState["task_groups"].Keys).Count
$workersBefore = @($dryRunState["task_group_workers"].Keys).Count
$dryRunPlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$dryRunFixture["root"]) -RunState $dryRunState
Assert-Equal $dryRunPlan["status"] "planned" "Dry-run planning should still produce a plan."
Assert-Equal @($dryRunState["task_groups"].Keys).Count $groupsBefore "Dry-run planning should not add task groups."
Assert-Equal @($dryRunState["task_group_workers"].Keys).Count $workersBefore "Dry-run planning should not add task group workers."
Assert-Equal @($dryRunPlan["run_state"]["task_groups"].Keys).Count $groupsBefore "Dry-run returned run-state should not add task groups."
Assert-Equal @($dryRunPlan["run_state"]["task_group_workers"].Keys).Count $workersBefore "Dry-run returned run-state should not add task group workers."

$cautiousCandidate = New-TestTask -TaskId "T-cautious" -ParallelSafety "cautious"
$serialCandidate = New-TestTask -TaskId "T-serial" -ParallelSafety "serial"
$defaultCautiousTest = Test-ParallelStepLaunchableCandidate -Candidate $cautiousCandidate
$allowedCautiousTest = Test-ParallelStepLaunchableCandidate -Candidate $cautiousCandidate -AllowCautiousSafety
$defaultSerialTest = Test-ParallelStepLaunchableCandidate -Candidate $serialCandidate
$cautiousSerialTest = Test-ParallelStepLaunchableCandidate -Candidate $serialCandidate -AllowCautiousSafety
Assert-True (-not [bool]$defaultCautiousTest["launchable"]) "Default parallel launchability should reject cautious candidates."
Assert-True ([string]$defaultCautiousTest["reason"] -like "*cautious*") "Cautious rejection should identify cautious safety."
Assert-True ([bool]$allowedCautiousTest["launchable"]) "Cautious opt-in should allow cautious candidates."
Assert-True (-not [bool]$defaultSerialTest["launchable"]) "Default parallel launchability should reject serial candidates."
Assert-True ([string]$defaultSerialTest["reason"] -like "*serial*") "Serial rejection should identify serial safety."
Assert-True (-not [bool]$cautiousSerialTest["launchable"]) "Cautious opt-in should not allow serial candidates."

$cautiousFixture = New-PackageFixture -FirstSafety "cautious" -SecondSafety "parallel"
$cautiousDefault = New-ParallelStepJobPackages -ProjectRoot ([string]$cautiousFixture["root"]) -RunState $cautiousFixture["state"] -ProviderSpec $provider -AllowSingleParallelJob -PackageRoot (Join-Path ([string]$cautiousFixture["root"]) "jobs-default")
Assert-Equal $cautiousDefault["status"] "leased" "Default parallel-step package creation should still lease parallel candidates when cautious candidates are present."
Assert-Equal @($cautiousDefault["packages"]).Count 1 "Default parallel-step package creation should reject cautious candidates."
Assert-Equal @($cautiousDefault["rejected_candidates"]).Count 1 "Default parallel-step package creation should report rejected cautious candidates."
$cautiousAllowedFixture = New-PackageFixture -FirstSafety "cautious" -SecondSafety "parallel"
$cautiousAllowed = New-ParallelStepJobPackages -ProjectRoot ([string]$cautiousAllowedFixture["root"]) -RunState $cautiousAllowedFixture["state"] -ProviderSpec $provider -AllowSingleParallelJob -AllowCautiousSafety -PackageRoot (Join-Path ([string]$cautiousAllowedFixture["root"]) "jobs-cautious")
Assert-Equal $cautiousAllowed["status"] "leased" "Cautious opt-in should lease cautious and parallel candidates."
Assert-Equal @($cautiousAllowed["packages"]).Count 2 "Cautious opt-in should include cautious candidates."

$packageFixture = New-PackageFixture
$packageResult = New-TaskGroupJobPackage -ProjectRoot ([string]$packageFixture["root"]) -RunState $packageFixture["state"] -ProviderSpec $provider
$packageState = $packageResult["run_state"]
$groupId = [string]$packageResult["group_id"]
$groupEntry = $packageState["task_groups"][$groupId]
$workerIds = @($groupEntry["worker_ids"])
$firstWorkerId = [string]$workerIds[0]
$firstWorkerEntry = $packageState["task_group_workers"][$firstWorkerId]
$firstWorkerPackage = $packageResult["package"]["workers"][0]

Assert-Equal $packageResult["status"] "planned" "Package creation should leave the group planned."
Assert-Equal @($packageState["task_groups"].Keys).Count 1 "Package creation should add one task group."
Assert-Equal @($packageState["task_group_workers"].Keys).Count 2 "Package creation should add queued task group workers."
Assert-Equal $groupEntry["status"] "planned" "Group status should be planned after package creation."
Assert-Equal $firstWorkerEntry["status"] "queued" "Worker status should be queued after package creation."
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstWorkerEntry["artifact_root"])) "Worker state should include artifact_root."
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstWorkerEntry["workspace_path"])) "Worker state should include workspace_path."
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstWorkerPackage["artifact_root"])) "Worker package should include artifact_root."
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstWorkerPackage["workspace_path"])) "Worker package should include workspace_path."
Assert-Equal $firstWorkerPackage["artifact_root"] (Get-JobArtifactsRootPath -ProjectRoot ([string]$packageFixture["root"]) -RunId "run-task-group-package" -JobId $firstWorkerId) "Worker artifact_root should use the job artifact root helper."
Assert-True (Test-Path ([string]$packageResult["package_path"])) "Task group package should be persisted."
Assert-Equal $packageResult["package"]["package_kind"] "task-group-leased-package" "Package kind should identify an executable group package."
Assert-Equal $packageResult["package"]["commit_policy"] "all_or_nothing" "Package should include commit policy."
Assert-Equal $packageResult["package"]["workspace_mode"] "isolated-copy-experimental" "Package should include workspace mode."

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-package failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-package passed." -ForegroundColor Green
exit 0
