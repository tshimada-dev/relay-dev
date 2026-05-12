$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\artifact-validator.ps1")
. (Join-Path $repoRoot "app\core\workflow-engine.ps1")
. (Join-Path $repoRoot "app\core\parallel-job-packages.ps1")
. (Join-Path $repoRoot "app\core\parallel-workspace.ps1")
. (Join-Path $repoRoot "app\core\phase-completion-committer.ps1")

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
    param([Parameter(Mandatory)][string]$ModuleName)

    return [ordered]@{
        module_boundaries = @($ModuleName)
        public_interfaces = @("$ModuleName public API")
        allowed_dependencies = @("$ModuleName -> domain")
        forbidden_dependencies = @("$ModuleName -> storage direct")
        side_effect_boundaries = @("$ModuleName owns local side effects")
        state_ownership = @("$ModuleName owns local state")
    }
}

function New-TestTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string[]]$DependsOn = @(),
        [string]$ParallelSafety = "parallel"
    )

    return [ordered]@{
        task_id = $TaskId
        purpose = "Exercise task-group sequencing for $TaskId"
        changed_files = @("src/$TaskId.txt")
        acceptance_criteria = @("Task group sequencing is respected")
        boundary_contract = (New-TestBoundaryContract -ModuleName "application/$TaskId")
        visual_contract = [ordered]@{
            mode = "not_applicable"
            design_sources = @()
            visual_constraints = @()
            component_patterns = @()
            responsive_expectations = @()
            interaction_guidelines = @()
        }
        dependencies = @($DependsOn)
        tests = @("pwsh -NoProfile -File tests/task-group-parallel-sequencing.ps1")
        complexity = "small"
        resource_locks = @("lock-$TaskId")
        parallel_safety = $ParallelSafety
    }
}

function New-SequencingFixture {
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [int]$MaxParallelJobs = 2,
        [string]$Name = "sequence"
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-sequencing-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "src") -Force | Out-Null
    $runId = "run-sequencing-$Name"
    $tasksArtifact = [ordered]@{ tasks = @($Tasks) }

    Save-Artifact -ProjectRoot $root -RunId $runId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $tasksArtifact -AsJson | Out-Null
    $state = New-RunState -RunId $runId -ProjectRoot $root -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state = Register-PlannedTasks -RunState $state -TasksArtifact $tasksArtifact
    $state = Update-TaskReadiness -RunState $state
    $state["task_lane"]["mode"] = "parallel"
    $state["task_lane"]["max_parallel_jobs"] = $MaxParallelJobs
    Write-RunState -ProjectRoot $root -RunState $state | Out-Null

    return [ordered]@{
        root = $root
        run_id = $runId
        state = $state
    }
}

function Complete-TestTaskGroup {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$PackageResult
    )

    $state = ConvertTo-RelayHashtable -InputObject $PackageResult["run_state"]
    $runId = [string]$state["run_id"]
    $groupId = [string]$PackageResult["group_id"]
    $group = ConvertTo-RelayHashtable -InputObject $state["task_groups"][$groupId]
    $workerResults = New-Object System.Collections.Generic.List[object]

    foreach ($workerRaw in @($PackageResult["package"]["workers"])) {
        $workerPackage = ConvertTo-RelayHashtable -InputObject $workerRaw
        $workerId = [string]$workerPackage["worker_id"]
        $taskId = [string]$workerPackage["task_id"]
        $changedFile = [string]@($workerPackage["declared_changed_files"])[0]
        $workspacePath = [string]$workerPackage["workspace_path"]
        $workspaceFile = Join-Path $workspacePath ($changedFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $workspaceFile) -Force | Out-Null

        $baseline = ConvertTo-RelayHashtable -InputObject $workerPackage["baseline_snapshot"]
        Set-Content -Path $workspaceFile -Value "product from $taskId" -Encoding UTF8

        $artifactPath = Get-JobArtifactPath -ProjectRoot $ProjectRoot -RunId $runId -JobId $workerId -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId $taskId
        New-Item -ItemType Directory -Path (Split-Path -Parent $artifactPath) -Force | Out-Null
        Set-Content -Path $artifactPath -Value (([ordered]@{ task_id = $taskId; verdict = "go"; worker_id = $workerId } | ConvertTo-Json -Depth 10) + "`n") -Encoding UTF8

        $artifactRef = [ordered]@{
            artifact_id = "phase6_result.json"
            scope = "task"
            phase = "Phase6"
            task_id = $taskId
            storage_scope = "job"
            job_id = $workerId
            path = $artifactPath
            as_json = $true
        }
        $workerResult = [ordered]@{
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            status = "succeeded"
            final_phase = "Phase6"
            errors = @()
            artifact_refs = @($artifactRef)
            declared_changed_files = @($changedFile)
            changed_files = @($changedFile)
            workspace_path = $workspacePath
            baseline_snapshot = $baseline
        }
        $workerResults.Add($workerResult) | Out-Null

        $workerState = ConvertTo-RelayHashtable -InputObject $state["task_group_workers"][$workerId]
        $workerState["status"] = "succeeded"
        $workerState["current_phase"] = "Phase6"
        $workerState["final_phase"] = "Phase6"
        $workerState["artifact_refs"] = @($artifactRef)
        $workerState["baseline_snapshot"] = $baseline
        $workerState["worker_result"] = $workerResult
        $state["task_group_workers"][$workerId] = $workerState
    }

    $group["status"] = "succeeded"
    $group["worker_results"] = @($workerResults.ToArray())
    $state["task_groups"][$groupId] = $group
    Write-RunState -ProjectRoot $ProjectRoot -RunState $state | Out-Null

    $mergeResult = ConvertTo-RelayHashtable -InputObject (Invoke-TaskGroupMergeAndCommit -ProjectRoot $ProjectRoot -RunId $runId -GroupId $groupId)
    Assert-True ([bool]$mergeResult["ok"]) "Synthetic successful group '$groupId' should merge and commit."

    return (Read-RunState -ProjectRoot $ProjectRoot -RunId $runId)
}

$provider = [ordered]@{ provider = "fake"; command = "pwsh"; flags = "-NoProfile" }
$createdRoots = New-Object System.Collections.Generic.List[string]

try {
    $singleCapacity = New-SequencingFixture -Name "single-capacity" -MaxParallelJobs 1 -Tasks @(
        (New-TestTask -TaskId "T-01"),
        (New-TestTask -TaskId "T-02")
    )
    $createdRoots.Add([string]$singleCapacity["root"]) | Out-Null
    $singlePlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$singleCapacity["root"]) -RunState $singleCapacity["state"]
    Assert-Equal $singlePlan["status"] "wait" "Task group planning should not launch when max_parallel_jobs is 1."

    $tripleCapacity = New-SequencingFixture -Name "triple-capacity" -MaxParallelJobs 3 -Tasks @(
        (New-TestTask -TaskId "T-01"),
        (New-TestTask -TaskId "T-02"),
        (New-TestTask -TaskId "T-03"),
        (New-TestTask -TaskId "T-04")
    )
    $createdRoots.Add([string]$tripleCapacity["root"]) | Out-Null
    $triplePackage = New-TaskGroupJobPackage -ProjectRoot ([string]$tripleCapacity["root"]) -RunState $tripleCapacity["state"] -ProviderSpec $provider
    $tripleTaskIds = @($triplePackage["package"]["workers"] | ForEach-Object { [string](ConvertTo-RelayHashtable -InputObject $_)["task_id"] })
    Assert-Equal @($triplePackage["package"]["workers"]).Count 3 "Task group package should respect max_parallel_jobs=3."
    Assert-True ("T-01" -in $tripleTaskIds -and "T-02" -in $tripleTaskIds -and "T-03" -in $tripleTaskIds) "First group should preserve scheduler order up to capacity."
    Assert-Equal $triplePackage["run_state"]["task_states"]["T-01"]["status"] "in_progress" "Packaged task should become in_progress."
    Assert-Equal $triplePackage["run_state"]["task_states"]["T-04"]["status"] "ready" "Unpackaged ready task should remain ready."
    $blockedSecondGroup = New-TaskGroupParallelPlan -ProjectRoot ([string]$tripleCapacity["root"]) -RunState $triplePackage["run_state"]
    Assert-Equal $blockedSecondGroup["status"] "wait" "A planned task group should block another group from being planned before completion."
    Assert-Equal $blockedSecondGroup["reason"] "task group already active" "Active group wait reason should be explicit."

    $alternating = New-SequencingFixture -Name "alternating" -MaxParallelJobs 2 -Tasks @(
        (New-TestTask -TaskId "T-01"),
        (New-TestTask -TaskId "T-02"),
        (New-TestTask -TaskId "T-03" -DependsOn @("T-01", "T-02") -ParallelSafety "serial"),
        (New-TestTask -TaskId "T-04" -DependsOn @("T-03")),
        (New-TestTask -TaskId "T-05" -DependsOn @("T-03"))
    )
    $createdRoots.Add([string]$alternating["root"]) | Out-Null
    $firstGroup = New-TaskGroupJobPackage -ProjectRoot ([string]$alternating["root"]) -RunState $alternating["state"] -ProviderSpec $provider
    $firstGroupTasks = @($firstGroup["package"]["workers"] | ForEach-Object { [string](ConvertTo-RelayHashtable -InputObject $_)["task_id"] })
    Assert-Equal ($firstGroupTasks -join ",") "T-01,T-02" "First group should select the first two independent tasks."
    $afterFirstGroup = Complete-TestTaskGroup -ProjectRoot ([string]$alternating["root"]) -PackageResult $firstGroup
    $afterFirstReadiness = Update-TaskReadiness -RunState $afterFirstGroup
    Assert-Equal $afterFirstReadiness["task_states"]["T-01"]["status"] "completed" "First grouped task should be completed after merge."
    Assert-Equal $afterFirstReadiness["task_states"]["T-02"]["status"] "completed" "Second grouped task should be completed after merge."
    Assert-Equal $afterFirstReadiness["current_phase"] "Phase5" "Group merge should leave the cursor at Phase5 when another task is ready."
    Assert-Equal $afterFirstReadiness["current_task_id"] "T-03" "Group merge should select the intervening serial task as the next cursor."
    Assert-Equal $afterFirstReadiness["task_states"]["T-03"]["status"] "in_progress" "Serial task should become the next in-progress cursor after group dependencies complete."

    $serialOnlyPlan = New-TaskGroupParallelPlan -ProjectRoot ([string]$alternating["root"]) -RunState $afterFirstReadiness
    Assert-Equal $serialOnlyPlan["status"] "wait" "Group planner should not launch a serial-only ordinary task."

    $singleTaskState = ConvertTo-RelayHashtable -InputObject $afterFirstReadiness["task_states"]["T-03"]
    $singleTaskState["status"] = "completed"
    $singleTaskState["last_completed_phase"] = "Phase6"
    $singleTaskState["phase_cursor"] = $null
    $singleTaskState["wait_reason"] = $null
    $afterFirstReadiness["task_states"]["T-03"] = $singleTaskState
    $afterSingle = Update-TaskReadiness -RunState $afterFirstReadiness
    Assert-Equal $afterSingle["task_states"]["T-04"]["status"] "ready" "First post-serial task should become ready."
    Assert-Equal $afterSingle["task_states"]["T-05"]["status"] "ready" "Second post-serial task should become ready."
    $secondGroup = New-TaskGroupJobPackage -ProjectRoot ([string]$alternating["root"]) -RunState $afterSingle -ProviderSpec $provider
    $secondGroupTasks = @($secondGroup["package"]["workers"] | ForEach-Object { [string](ConvertTo-RelayHashtable -InputObject $_)["task_id"] })
    Assert-Equal ($secondGroupTasks -join ",") "T-04,T-05" "Second group should launch after an intervening completed serial task."
    $afterSecondGroup = Complete-TestTaskGroup -ProjectRoot ([string]$alternating["root"]) -PackageResult $secondGroup
    Assert-Equal $afterSecondGroup["task_states"]["T-04"]["status"] "completed" "Second group first task should complete."
    Assert-Equal $afterSecondGroup["task_states"]["T-05"]["status"] "completed" "Second group second task should complete."
    Assert-Equal $afterSecondGroup["current_phase"] "Phase7" "Completed task groups should advance to Phase7 when no ready tasks remain."
    Assert-True ([string]::IsNullOrWhiteSpace([string]$afterSecondGroup["current_task_id"])) "Phase7 cursor should not retain a task id."

    $allComplete = New-SequencingFixture -Name "all-complete" -MaxParallelJobs 2 -Tasks @(
        (New-TestTask -TaskId "T-01"),
        (New-TestTask -TaskId "T-02")
    )
    $createdRoots.Add([string]$allComplete["root"]) | Out-Null
    $allCompleteGroup = New-TaskGroupJobPackage -ProjectRoot ([string]$allComplete["root"]) -RunState $allComplete["state"] -ProviderSpec $provider
    $afterAllComplete = Complete-TestTaskGroup -ProjectRoot ([string]$allComplete["root"]) -PackageResult $allCompleteGroup
    Assert-Equal $afterAllComplete["current_phase"] "Phase7" "A group that completes the remaining tasks should advance the run cursor to Phase7."
    Assert-True ([string]::IsNullOrWhiteSpace([string]$afterAllComplete["current_task_id"])) "Phase7 cursor should clear the current task after the final group."

    $consecutive = New-SequencingFixture -Name "consecutive" -MaxParallelJobs 2 -Tasks @(
        (New-TestTask -TaskId "T-01"),
        (New-TestTask -TaskId "T-02"),
        (New-TestTask -TaskId "T-03"),
        (New-TestTask -TaskId "T-04")
    )
    $createdRoots.Add([string]$consecutive["root"]) | Out-Null
    $groupA = New-TaskGroupJobPackage -ProjectRoot ([string]$consecutive["root"]) -RunState $consecutive["state"] -ProviderSpec $provider
    $afterGroupA = Complete-TestTaskGroup -ProjectRoot ([string]$consecutive["root"]) -PackageResult $groupA
    $groupB = New-TaskGroupJobPackage -ProjectRoot ([string]$consecutive["root"]) -RunState (Update-TaskReadiness -RunState $afterGroupA) -ProviderSpec $provider
    $groupBTasks = @($groupB["package"]["workers"] | ForEach-Object { [string](ConvertTo-RelayHashtable -InputObject $_)["task_id"] })
    Assert-Equal ($groupBTasks -join ",") "T-03,T-04" "A second group should launch the remaining ready tasks after group A completes."
}
finally {
    foreach ($root in @($createdRoots.ToArray())) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-sequencing failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-sequencing passed." -ForegroundColor Green
exit 0
