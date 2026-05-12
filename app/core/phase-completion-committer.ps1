if (-not (Get-Command Commit-PhaseOutputArtifacts -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repository.ps1")
}
if (-not (Get-Command Invoke-TaskGroupProductMerge -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "parallel-workspace.ps1")
}
if (-not (Get-Command Write-RunState -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Resolve-NextReadyTaskId -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "workflow-engine.ps1")
}

function Complete-PhaseOutputCommit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$MaterializedArtifacts
    )

    $commitResult = ConvertTo-RelayHashtable -InputObject (Commit-PhaseOutputArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -MaterializedArtifacts $MaterializedArtifacts)
    $committedArtifacts = @($commitResult["committed"])

    $artifactIds = New-Object System.Collections.Generic.List[string]
    foreach ($committedRaw in $committedArtifacts) {
        $committedArtifact = ConvertTo-RelayHashtable -InputObject $committedRaw
        $artifactId = [string]$committedArtifact["artifact_id"]
        if (-not [string]::IsNullOrWhiteSpace($artifactId)) {
            $artifactIds.Add($artifactId) | Out-Null
        }
    }

    return [ordered]@{
        committed = $committedArtifacts
        summary = [ordered]@{
            committed_count = $committedArtifacts.Count
            artifact_ids = @($artifactIds.ToArray())
        }
    }
}

function ConvertTo-TaskGroupMaterializedArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$WorkerResults
    )

    $materialized = New-Object System.Collections.Generic.List[object]
    foreach ($workerResultRaw in @($WorkerResults)) {
        $workerResult = ConvertTo-RelayHashtable -InputObject $workerResultRaw
        $workerId = [string]$workerResult["worker_id"]
        foreach ($artifactRefRaw in @($workerResult["artifact_refs"])) {
            $artifactRef = ConvertTo-RelayHashtable -InputObject $artifactRefRaw
            if (-not $artifactRef) {
                continue
            }
            $content = Read-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -ArtifactRef $artifactRef
            if ($null -eq $content) {
                throw "Unable to read artifact '$($artifactRef["artifact_id"])' for task group worker '$workerId'."
            }
            $path = Resolve-ArtifactRef -ProjectRoot $ProjectRoot -RunId $RunId -ArtifactRef $artifactRef
            $scope = if ($artifactRef["scope"]) { [string]$artifactRef["scope"] } else { "run" }
            $materialized.Add([ordered]@{
                artifact_id = [string]$artifactRef["artifact_id"]
                scope = $scope
                phase = [string]$artifactRef["phase"]
                task_id = if ($scope -eq "task") { [string]$artifactRef["task_id"] } else { $null }
                content = $content
                path = $path
                as_json = if ($artifactRef.ContainsKey("as_json")) { [bool]$artifactRef["as_json"] } else { $path.ToLowerInvariant().EndsWith(".json") }
                worker_id = $workerId
            }) | Out-Null
        }
    }

    return @($materialized.ToArray())
}

function Complete-TaskGroupTaskStates {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][object[]]$WorkerResults
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $now = (Get-Date).ToString("o")
    $completedTaskIds = New-Object System.Collections.Generic.List[string]

    foreach ($resultRaw in @($WorkerResults)) {
        $result = ConvertTo-RelayHashtable -InputObject $resultRaw
        $taskId = [string]$result["task_id"]
        if ([string]::IsNullOrWhiteSpace($taskId) -or -not $state["task_states"].ContainsKey($taskId)) {
            continue
        }

        $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
        $taskState["status"] = "completed"
        $taskState["last_completed_phase"] = "Phase6"
        $taskState["phase_cursor"] = $null
        $taskState["active_job_id"] = $null
        $taskState["wait_reason"] = $null
        $taskState["task_group_id"] = $GroupId
        $taskState["completed_at"] = $now
        $state["task_states"][$taskId] = $taskState
        $completedTaskIds.Add($taskId) | Out-Null
    }

    $state = Update-TaskReadiness -RunState $state
    $nextTaskId = Resolve-NextReadyTaskId -RunState $state
    $nextPhase = if ([string]::IsNullOrWhiteSpace($nextTaskId)) { "Phase7" } else { "Phase5" }
    $state = Set-RunStateCursor -RunState $state -Phase $nextPhase -TaskId $nextTaskId
    $state["status"] = "running"
    $state["updated_at"] = $now

    return [ordered]@{
        run_state = $state
        completed_task_ids = @($completedTaskIds.ToArray())
        next_phase = $nextPhase
        next_task_id = $nextTaskId
    }
}

function Invoke-TaskGroupMergeAndCommit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [string]$GroupId,
        [AllowNull()]$Group,
        [AllowNull()]$RunState,
        [string]$MainWorkspace
    )

    if ([string]::IsNullOrWhiteSpace($MainWorkspace)) {
        $MainWorkspace = $ProjectRoot
    }

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    if (-not $state) {
        $state = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
    }
    if (-not $state) {
        throw "Run '$RunId' does not exist."
    }
    $state = Initialize-RunStateCompatibilityFields -RunState $state
    $groups = ConvertTo-RelayHashtable -InputObject $state["task_groups"]
    $workers = ConvertTo-RelayHashtable -InputObject $state["task_group_workers"]
    $group = ConvertTo-RelayHashtable -InputObject $Group
    if (-not $group) {
        $group = ConvertTo-RelayHashtable -InputObject $groups[$GroupId]
    }
    if (-not $group) {
        throw "Task group '$GroupId' does not exist in run-state."
    }
    if ([string]::IsNullOrWhiteSpace($GroupId)) {
        $GroupId = if ($group["group_id"]) { [string]$group["group_id"] } else { [string]$group["id"] }
    }

    $workerResultsById = @{}
    foreach ($resultRaw in @($group["worker_results"])) {
        $result = ConvertTo-RelayHashtable -InputObject $resultRaw
        if ($result -and -not [string]::IsNullOrWhiteSpace([string]$result["worker_id"])) {
            $workerResultsById[[string]$result["worker_id"]] = $result
        }
    }

    $ineligible = New-Object System.Collections.Generic.List[object]
    $eligibleResults = New-Object System.Collections.Generic.List[object]
    $mergeSpecs = New-Object System.Collections.Generic.List[object]
    foreach ($workerIdRaw in @($group["worker_ids"])) {
        $workerId = [string]$workerIdRaw
        $worker = ConvertTo-RelayHashtable -InputObject $workers[$workerId]
        $result = if ($workerResultsById.ContainsKey($workerId)) { ConvertTo-RelayHashtable -InputObject $workerResultsById[$workerId] } elseif ($worker -and $worker["worker_result"]) { ConvertTo-RelayHashtable -InputObject $worker["worker_result"] } else { $null }
        $status = if ($result -and $result["status"]) { [string]$result["status"] } elseif ($worker) { [string]$worker["status"] } else { "missing" }
        if ($status -ne "succeeded") {
            $ineligible.Add([ordered]@{ worker_id = $workerId; status = $status; reason = "worker_not_succeeded" }) | Out-Null
            continue
        }

        $eligibleResults.Add($result) | Out-Null
        $changedFiles = Get-TaskGroupWorkerChangedFiles -WorkerResult $result -WorkerRow $worker
        $baseline = Get-TaskGroupWorkerMergeBaseline -WorkerResult $result -WorkerRow $worker
        $workspacePath = if ($result -and $result["workspace_path"]) { [string]$result["workspace_path"] } elseif ($worker) { [string]$worker["workspace_path"] } else { "" }
        $mergeSpecs.Add([ordered]@{
            worker_id = $workerId
            workspace_path = $workspacePath
            baseline = $baseline
            accepted_changed_files = @($changedFiles)
        }) | Out-Null
    }

    if ($ineligible.Count -gt 0) {
        return [ordered]@{
            ok = $false
            status = "commit_blocked"
            reason = "task_group_has_ineligible_workers"
            group_id = $GroupId
            ineligible_workers = @($ineligible.ToArray())
            merge = [ordered]@{ ok = $false; conflicts = @(); copied_files = @(); deleted_files = @() }
            commit = [ordered]@{ committed = @(); summary = [ordered]@{ committed_count = 0; artifact_ids = @() }; skipped = $true }
            conflicts = @()
        }
    }

    try {
        $materialized = ConvertTo-TaskGroupMaterializedArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -WorkerResults @($eligibleResults.ToArray())
    }
    catch {
        return [ordered]@{
            ok = $false
            status = "artifact_commit_failed"
            reason = $_.Exception.Message
            group_id = $GroupId
            ineligible_workers = @()
            merge = [ordered]@{ ok = $false; conflicts = @(); copied_files = @(); deleted_files = @(); skipped = $true; reason = "artifact_materialization_failed" }
            commit = [ordered]@{ committed = @(); summary = [ordered]@{ committed_count = 0; artifact_ids = @() }; error = $_.Exception.Message }
            conflicts = @()
        }
    }

    $merge = ConvertTo-RelayHashtable -InputObject (Invoke-TaskGroupProductMerge -MainWorkspace $MainWorkspace -WorkerMergeSpecs @($mergeSpecs.ToArray()))
    if (-not [bool]$merge["ok"]) {
        return [ordered]@{
            ok = $false
            status = "merge_failed"
            reason = [string]$merge["reason"]
            group_id = $GroupId
            ineligible_workers = @()
            merge = $merge
            commit = [ordered]@{ committed = @(); summary = [ordered]@{ committed_count = 0; artifact_ids = @() }; skipped = $true; reason = "product_merge_failed" }
            conflicts = @($merge["conflicts"])
        }
    }

    try {
        $commit = ConvertTo-RelayHashtable -InputObject (Complete-PhaseOutputCommit -ProjectRoot $ProjectRoot -RunId $RunId -MaterializedArtifacts @($materialized))
        $now = (Get-Date).ToString("o")
        $completion = ConvertTo-RelayHashtable -InputObject (Complete-TaskGroupTaskStates -RunState $state -GroupId $GroupId -WorkerResults @($eligibleResults.ToArray()))
        $state = ConvertTo-RelayHashtable -InputObject $completion["run_state"]
        $groups = ConvertTo-RelayHashtable -InputObject $state["task_groups"]
        $group = ConvertTo-RelayHashtable -InputObject $groups[$GroupId]

        $group["merge_status"] = "succeeded"
        $group["merged_at"] = $now
        $groups[$GroupId] = $group
        $state["task_groups"] = $groups
        $state["updated_at"] = $now
        Write-RunState -ProjectRoot $ProjectRoot -RunState $state | Out-Null

        return [ordered]@{
            ok = $true
            status = "succeeded"
            reason = "task_group_merged_and_committed"
            group_id = $GroupId
            ineligible_workers = @()
            merge = $merge
            commit = $commit
            conflicts = @()
            summary = [ordered]@{
                workers_merged = @($eligibleResults.ToArray()).Count
                product_copied_count = @($merge["copied_files"]).Count
                product_deleted_count = @($merge["deleted_files"]).Count
                artifacts_committed = [int]$commit["summary"]["committed_count"]
                next_phase = [string]$completion["next_phase"]
                next_task_id = [string]$completion["next_task_id"]
            }
        }
    }
    catch {
        return [ordered]@{
            ok = $false
            status = "artifact_commit_failed"
            reason = $_.Exception.Message
            group_id = $GroupId
            ineligible_workers = @()
            merge = $merge
            commit = [ordered]@{ committed = @(); summary = [ordered]@{ committed_count = 0; artifact_ids = @() }; error = $_.Exception.Message }
            conflicts = @()
        }
    }
}

function Complete-TaskGroupMergeCommit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$GroupId,
        [AllowNull()]$RunState,
        [string]$MainWorkspace
    )

    return Invoke-TaskGroupMergeAndCommit -ProjectRoot $ProjectRoot -RunId $RunId -GroupId $GroupId -RunState $RunState -MainWorkspace $MainWorkspace
}
