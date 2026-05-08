$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
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

function New-GroupMergeFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$WorkerIds = @("worker-a", "worker-b"),
        [string[]]$FailedWorkers = @(),
        [switch]$Conflict,
        [switch]$MissingArtifact
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-merge-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "src") -Force | Out-Null
    $runId = "run-merge-$Name"
    $groupId = "group-$Name"
    $state = New-RunState -RunId $runId -ProjectRoot $root -TaskId "task-main" -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state["task_groups"][$groupId] = [ordered]@{
        id = $groupId
        group_id = $groupId
        status = "succeeded"
        worker_ids = @($WorkerIds)
        worker_results = @()
    }

    $workerResults = New-Object System.Collections.Generic.List[object]
    foreach ($workerId in $WorkerIds) {
        $taskId = "T-$workerId"
        $changedFile = "src/$taskId.txt"
        $baseline = New-WorkspaceBaselineSnapshot -WorkspaceRoot $root -Paths @($changedFile)
        $workspace = Join-Path $root "workspace-$workerId"
        New-Item -ItemType Directory -Path (Join-Path $workspace "src") -Force | Out-Null
        Set-Content -Path (Join-Path $workspace ($changedFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -Value "product from $workerId" -Encoding UTF8

        $artifactPath = Get-JobArtifactPath -ProjectRoot $root -RunId $runId -JobId $workerId -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId $taskId
        New-Item -ItemType Directory -Path (Split-Path -Parent $artifactPath) -Force | Out-Null
        $artifactContent = [ordered]@{ task_id = $taskId; verdict = "go"; worker_id = $workerId }
        Set-Content -Path $artifactPath -Value (($artifactContent | ConvertTo-Json -Depth 10) + "`n") -Encoding UTF8
        if ($MissingArtifact -and $workerId -eq "worker-b") {
            Remove-Item -LiteralPath $artifactPath -Force
        }
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
        $status = if ($workerId -in $FailedWorkers) { "failed" } else { "succeeded" }
        $workerResult = [ordered]@{
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            status = $status
            final_phase = if ($status -eq "succeeded") { "Phase6" } else { "Phase5" }
            errors = if ($status -eq "succeeded") { @() } else { @("planned failure") }
            artifact_refs = if ($status -eq "succeeded") { @($artifactRef) } else { @() }
            declared_changed_files = @($changedFile)
            changed_files = @($changedFile)
            workspace_path = $workspace
            baseline_snapshot = $baseline
        }
        $workerResults.Add($workerResult) | Out-Null
        $state["task_group_workers"][$workerId] = [ordered]@{
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            status = $status
            declared_changed_files = @($changedFile)
            workspace_path = $workspace
            baseline_snapshot = $baseline
            worker_result = $workerResult
        }
    }
    $state["task_groups"][$groupId]["worker_results"] = @($workerResults.ToArray())
    Write-RunState -ProjectRoot $root -RunState $state | Out-Null

    if ($Conflict) {
        Set-Content -Path (Join-Path $root "src\T-worker-a.txt") -Value "parent drift" -Encoding UTF8
    }

    return [ordered]@{ root = $root; run_id = $runId; group_id = $groupId }
}

$success = New-GroupMergeFixture -Name "success"
$successResult = ConvertTo-RelayHashtable -InputObject (Invoke-TaskGroupMergeAndCommit -ProjectRoot $success["root"] -RunId $success["run_id"] -GroupId $success["group_id"])
Assert-True ([bool]$successResult["ok"]) "Two successful non-conflicting workers should merge and commit."
Assert-Equal (Get-Content -Path (Join-Path $success["root"] "src\T-worker-a.txt") -Raw -Encoding UTF8).Trim() "product from worker-a" "First worker product file should be copied."
Assert-Equal (Get-Content -Path (Join-Path $success["root"] "src\T-worker-b.txt") -Raw -Encoding UTF8).Trim() "product from worker-b" "Second worker product file should be copied."
Assert-True (Test-Path -LiteralPath (Get-ArtifactPath -ProjectRoot $success["root"] -RunId $success["run_id"] -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId "T-worker-a")) "First canonical artifact should be committed."
Assert-True (Test-Path -LiteralPath (Get-ArtifactPath -ProjectRoot $success["root"] -RunId $success["run_id"] -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId "T-worker-b")) "Second canonical artifact should be committed."

$conflict = New-GroupMergeFixture -Name "conflict" -Conflict
$conflictResult = ConvertTo-RelayHashtable -InputObject (Invoke-TaskGroupMergeAndCommit -ProjectRoot $conflict["root"] -RunId $conflict["run_id"] -GroupId $conflict["group_id"])
Assert-True (-not [bool]$conflictResult["ok"]) "Merge conflict should fail the group commit."
Assert-Equal ([string]$conflictResult["status"]) "merge_failed" "Merge conflict should return merge_failed status."
Assert-True (@($conflictResult["conflicts"]).Count -gt 0) "Merge conflict should include conflict details."
Assert-Equal (Get-Content -Path (Join-Path $conflict["root"] "src\T-worker-a.txt") -Raw -Encoding UTF8).Trim() "parent drift" "Conflicting worker product file should not be overwritten."
Assert-True (-not (Test-Path -LiteralPath (Join-Path $conflict["root"] "src\T-worker-b.txt"))) "Non-conflicting sibling product file should not be copied after group conflict."
Assert-True (-not (Test-Path -LiteralPath (Get-ArtifactPath -ProjectRoot $conflict["root"] -RunId $conflict["run_id"] -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId "T-worker-a"))) "Canonical artifact should not be committed after merge conflict."

$failed = New-GroupMergeFixture -Name "failed-worker" -FailedWorkers @("worker-b")
$failedResult = ConvertTo-RelayHashtable -InputObject (Invoke-TaskGroupMergeAndCommit -ProjectRoot $failed["root"] -RunId $failed["run_id"] -GroupId $failed["group_id"])
Assert-True (-not [bool]$failedResult["ok"]) "Group with failed worker should be blocked from commit."
Assert-Equal ([string]$failedResult["status"]) "commit_blocked" "Failed worker should return commit_blocked status."
Assert-True (-not (Test-Path -LiteralPath (Join-Path $failed["root"] "src\T-worker-a.txt"))) "No product file should be copied when a worker failed."
Assert-True (-not (Test-Path -LiteralPath (Get-ArtifactPath -ProjectRoot $failed["root"] -RunId $failed["run_id"] -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId "T-worker-a"))) "No canonical artifact should be committed when a worker failed."

$missingArtifact = New-GroupMergeFixture -Name "missing-artifact" -MissingArtifact
$missingArtifactResult = ConvertTo-RelayHashtable -InputObject (Invoke-TaskGroupMergeAndCommit -ProjectRoot $missingArtifact["root"] -RunId $missingArtifact["run_id"] -GroupId $missingArtifact["group_id"])
Assert-True (-not [bool]$missingArtifactResult["ok"]) "Missing worker artifact should fail before product merge."
Assert-Equal ([string]$missingArtifactResult["status"]) "artifact_commit_failed" "Missing worker artifact should return artifact_commit_failed status."
Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingArtifact["root"] "src\T-worker-a.txt"))) "No product file should be copied when artifact materialization fails."
Assert-True (-not (Test-Path -LiteralPath (Get-ArtifactPath -ProjectRoot $missingArtifact["root"] -RunId $missingArtifact["run_id"] -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId "T-worker-a"))) "No canonical artifact should be committed when artifact materialization fails."

foreach ($fixture in @($success, $conflict, $failed, $missingArtifact)) {
    if (Test-Path -LiteralPath $fixture["root"]) {
        Remove-Item -LiteralPath $fixture["root"] -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-merge failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-merge passed." -ForegroundColor Green
exit 0
