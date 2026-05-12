if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Get-BatchLeaseCandidates -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "workflow-engine.ps1")
}
if (-not (Get-Command New-IsolatedJobWorkspace -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "parallel-workspace.ps1")
}

function Normalize-ParallelStepChangedFiles {
    param(
        [AllowNull()]$ChangedFiles,
        [string]$WorkspacePath
    )

    $seen = @{}
    $declared = New-Object System.Collections.Generic.List[string]
    $allowed = New-Object System.Collections.Generic.List[string]

    foreach ($rawPath in @($ChangedFiles)) {
        $value = ([string]$rawPath).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $normalized = $value -replace '\\', '/'
        while ($normalized.StartsWith("./")) {
            $normalized = $normalized.Substring(2)
        }
        $normalized = $normalized.Trim("/")
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }
        if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '(^|/)\.\.(/|$)') {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $declared.Add($normalized) | Out-Null

        if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
            $allowed.Add($normalized) | Out-Null
        }
        else {
            $allowed.Add((Join-Path $WorkspacePath ($normalized -replace '/', [System.IO.Path]::DirectorySeparatorChar))) | Out-Null
        }
    }

    return [ordered]@{
        declared_changed_files = @($declared.ToArray())
        allowed_product_paths = @($allowed.ToArray())
    }
}

function Get-ParallelStepCandidateContract {
    param([Parameter(Mandatory)]$Candidate)

    $candidateObject = ConvertTo-RelayHashtable -InputObject $Candidate
    foreach ($field in @("selected_task", "task_contract", "contract")) {
        if ($candidateObject.ContainsKey($field) -and $candidateObject[$field]) {
            return (ConvertTo-RelayHashtable -InputObject $candidateObject[$field])
        }
    }

    return $candidateObject
}

function Test-ParallelStepLaunchableCandidate {
    param(
        [Parameter(Mandatory)]$Candidate,
        [switch]$AllowNonParallelSafety,
        [switch]$AllowCautiousSafety,
        [switch]$AllowEmptyChangedFiles
    )

    $candidateObject = ConvertTo-RelayHashtable -InputObject $Candidate
    $contract = Get-ParallelStepCandidateContract -Candidate $candidateObject
    $errors = New-Object System.Collections.Generic.List[string]

    $taskId = [string]$candidateObject["task_id"]
    if ([string]::IsNullOrWhiteSpace($taskId) -and $contract) {
        $taskId = [string]$contract["task_id"]
    }
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        $errors.Add("candidate is missing task_id") | Out-Null
    }

    $parallelSafety = [string]$candidateObject["parallel_safety"]
    if ([string]::IsNullOrWhiteSpace($parallelSafety) -and $contract) {
        $parallelSafety = [string]$contract["parallel_safety"]
    }
    $parallelSafety = $parallelSafety.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($parallelSafety)) {
        $parallelSafety = "cautious"
    }
    if (-not $AllowNonParallelSafety -and $parallelSafety -ne "parallel") {
        if ($parallelSafety -eq "cautious") {
            if (-not $AllowCautiousSafety) {
                $errors.Add("parallel_safety cautious requires explicit cautious opt-in") | Out-Null
            }
        }
        elseif ($parallelSafety -eq "serial") {
            $errors.Add("parallel_safety serial requires non-parallel execution") | Out-Null
        }
        else {
            $errors.Add("parallel_safety must be parallel") | Out-Null
        }
    }

    $changedFilesSource = $null
    if ($candidateObject.ContainsKey("changed_files")) {
        $changedFilesSource = $candidateObject["changed_files"]
    }
    elseif ($contract -and $contract.ContainsKey("changed_files")) {
        $changedFilesSource = $contract["changed_files"]
    }

    $normalized = Normalize-ParallelStepChangedFiles -ChangedFiles $changedFilesSource
    if (-not $AllowEmptyChangedFiles -and @($normalized["declared_changed_files"]).Count -eq 0) {
        $errors.Add("changed_files must declare at least one product path") | Out-Null
    }

    $reason = if ($errors.Count -eq 0) { "launchable" } else { ($errors.ToArray() -join "; ") }
    return [ordered]@{
        launchable = ($errors.Count -eq 0)
        reason = $reason
        errors = @($errors.ToArray())
        task_id = $taskId
        parallel_safety = $parallelSafety
        changed_files = @($normalized["declared_changed_files"])
    }
}

function New-ParallelStepPackageMetadata {
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$JobSpec,
        [string]$WorkspacePath
    )

    $candidateObject = ConvertTo-RelayHashtable -InputObject $Candidate
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $contract = Get-ParallelStepCandidateContract -Candidate $candidateObject
    $changedFilesSource = if ($job.ContainsKey("changed_files")) {
        $job["changed_files"]
    }
    elseif ($candidateObject.ContainsKey("changed_files")) {
        $candidateObject["changed_files"]
    }
    elseif ($contract -and $contract.ContainsKey("changed_files")) {
        $contract["changed_files"]
    }
    else {
        @()
    }
    $normalized = Normalize-ParallelStepChangedFiles -ChangedFiles $changedFilesSource -WorkspacePath $WorkspacePath

    return [ordered]@{
        task_id = if (-not [string]::IsNullOrWhiteSpace([string]$job["task_id"])) { [string]$job["task_id"] } else { [string]$candidateObject["task_id"] }
        phase = if (-not [string]::IsNullOrWhiteSpace([string]$job["phase"])) { [string]$job["phase"] } else { [string]$candidateObject["phase"] }
        role = if (-not [string]::IsNullOrWhiteSpace([string]$job["role"])) { [string]$job["role"] } else { [string]$candidateObject["role"] }
        parallel_safety = if (-not [string]::IsNullOrWhiteSpace([string]$job["parallel_safety"])) { [string]$job["parallel_safety"] } else { [string]$candidateObject["parallel_safety"] }
        resource_locks = if ($job.ContainsKey("resource_locks")) { @($job["resource_locks"]) } else { @($candidateObject["resource_locks"]) }
        slot_id = if (-not [string]::IsNullOrWhiteSpace([string]$job["slot_id"])) { [string]$job["slot_id"] } else { [string]$candidateObject["slot_id"] }
        workspace_id = if (-not [string]::IsNullOrWhiteSpace([string]$job["workspace_id"])) { [string]$job["workspace_id"] } else { [string]$candidateObject["workspace_id"] }
        declared_changed_files = @($normalized["declared_changed_files"])
        allowed_product_paths = @($normalized["allowed_product_paths"])
    }
}

function New-ParallelStepJobPackageContent {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$JobSpec,
        [AllowNull()][string]$PromptText,
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [AllowNull()]$Baseline,
        [AllowNull()]$ProviderSpec
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $candidateObject = ConvertTo-RelayHashtable -InputObject $Candidate
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $metadata = New-ParallelStepPackageMetadata -Candidate $candidateObject -JobSpec $job -WorkspacePath $WorkspacePath
    $phaseHistory = @($state["phase_history"])
    $phaseStartedAt = $null
    for ($index = $phaseHistory.Count - 1; $index -ge 0; $index--) {
        $entry = ConvertTo-RelayHashtable -InputObject $phaseHistory[$index]
        if ([string]$entry["phase"] -eq [string]$metadata["phase"] -and [string]$entry["agent"] -eq [string]$metadata["role"]) {
            $phaseStartedAt = [string]$entry["started"]
            break
        }
    }

    return [ordered]@{
        schema_version = 1
        package_kind = "parallel-step-leased-job"
        workspace_mode = "isolated-copy-experimental"
        created_at = (Get-Date).ToString("o")
        run_id = $RunId
        run_state_revision = [int]$state["state_revision"]
        phase = [string]$metadata["phase"]
        role = [string]$metadata["role"]
        task_id = [string]$metadata["task_id"]
        phase_started_at = $phaseStartedAt
        job_id = [string]$job["job_id"]
        lease_token = [string]$job["lease_token"]
        lease_expires_at = [string]$job["lease_expires_at"]
        job_spec = $job
        provider_spec = (ConvertTo-RelayHashtable -InputObject $ProviderSpec)
        phase_definition = (ConvertTo-RelayHashtable -InputObject $PhaseDefinition)
        candidate = $candidateObject
        prompt_text = $PromptText
        workspace = [ordered]@{
            path = $WorkspacePath
            baseline = (ConvertTo-RelayHashtable -InputObject $Baseline)
            declared_changed_files = @($metadata["declared_changed_files"])
            allowed_product_paths = @($metadata["allowed_product_paths"])
        }
        resource_locks = @($metadata["resource_locks"])
        parallel_safety = [string]$metadata["parallel_safety"]
        slot_id = [string]$metadata["slot_id"]
        workspace_id = [string]$metadata["workspace_id"]
    }
}

function New-StableTaskGroupPlanId {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()]$StateRevision,
        [Parameter(Mandatory)][string]$CurrentPhase,
        [Parameter(Mandatory)][string[]]$TaskIds,
        [string]$WorkerTaskId
    )

    $revisionText = if ($null -ne $StateRevision -and -not [string]::IsNullOrWhiteSpace([string]$StateRevision)) { [string]$StateRevision } else { "0" }
    $basisParts = @($RunId, $revisionText, $CurrentPhase) + @($TaskIds)
    if (-not [string]::IsNullOrWhiteSpace($WorkerTaskId)) {
        $basisParts += $WorkerTaskId
    }
    $basis = ($basisParts -join "|")
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($basis)
        $hashBytes = $sha256.ComputeHash($bytes)
        $hash = ([System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()).Substring(0, 16)
        return "$Prefix-$hash"
    }
    finally {
        $sha256.Dispose()
    }
}

function New-TaskGroupParallelPlan {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState,
        [switch]$AllowSingleParallelJob,
        [switch]$AllowCautiousSafety,
        [switch]$AllowNonParallelSafety,
        [switch]$AllowEmptyChangedFiles
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $runId = [string]$state["run_id"]
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw "run_id is required to create a task group plan."
    }

    $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
    if ([string]$taskLane["mode"] -ne "parallel") {
        return [ordered]@{ status = "wait"; reason = "task_lane.mode must be parallel"; group = $null; workers = @(); rejected_candidates = @(); run_state = $state }
    }
    if ([int]$taskLane["max_parallel_jobs"] -le 1) {
        return [ordered]@{ status = "wait"; reason = "task_lane.max_parallel_jobs must be greater than 1"; group = $null; workers = @(); rejected_candidates = @(); run_state = $state }
    }
    if (-not (Test-TaskScopedPhase -Phase ([string]$state["current_phase"]))) {
        return [ordered]@{ status = "wait"; reason = "current_phase is not task-scoped"; group = $null; workers = @(); rejected_candidates = @(); run_state = $state }
    }
    foreach ($groupId in @($state["task_groups"].Keys)) {
        $existingGroup = ConvertTo-RelayHashtable -InputObject $state["task_groups"][$groupId]
        $existingStatus = [string]$existingGroup["status"]
        if ($existingStatus -in @("planned", "running")) {
            return [ordered]@{ status = "wait"; reason = "task group already active"; group = $null; workers = @(); rejected_candidates = @(); run_state = $state }
        }
    }

    $candidates = @(Get-BatchLeaseCandidates -RunState $state -ProjectRoot $ProjectRoot)
    $launchable = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        $test = Test-ParallelStepLaunchableCandidate -Candidate $candidate -AllowCautiousSafety:$AllowCautiousSafety -AllowNonParallelSafety:$AllowNonParallelSafety -AllowEmptyChangedFiles:$AllowEmptyChangedFiles
        if ([bool]$test["launchable"]) {
            $launchable.Add((ConvertTo-RelayHashtable -InputObject $candidate)) | Out-Null
        }
        else {
            $rejected.Add([ordered]@{ candidate = (ConvertTo-RelayHashtable -InputObject $candidate); launchability = $test }) | Out-Null
        }
    }

    if ($launchable.Count -eq 0) {
        return [ordered]@{ status = "wait"; reason = "no launchable candidates"; group = $null; workers = @(); rejected_candidates = @($rejected.ToArray()); run_state = $state }
    }
    if (-not $AllowSingleParallelJob -and $launchable.Count -lt 2) {
        return [ordered]@{ status = "wait"; reason = "fewer than two launchable candidates"; group = $null; workers = @(); rejected_candidates = @($rejected.ToArray()); run_state = $state }
    }

    $taskIds = @($launchable.ToArray() | ForEach-Object { [string]$_["task_id"] })
    $groupId = New-StableTaskGroupPlanId -Prefix "task-group" -RunId $runId -StateRevision $state["state_revision"] -CurrentPhase ([string]$state["current_phase"]) -TaskIds $taskIds
    $workers = New-Object System.Collections.Generic.List[object]
    $workerIds = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($launchable.ToArray())) {
        $taskId = [string]$candidate["task_id"]
        $workerId = New-StableTaskGroupPlanId -Prefix "task-worker" -RunId $runId -StateRevision $state["state_revision"] -CurrentPhase ([string]$state["current_phase"]) -TaskIds $taskIds -WorkerTaskId $taskId
        $metadata = New-ParallelStepPackageMetadata -Candidate $candidate -JobSpec $candidate
        $workerIds.Add($workerId) | Out-Null
        $workers.Add([ordered]@{
            id = $workerId
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            status = "queued"
            phase = "Phase5"
            current_phase = "Phase5"
            phase_range = "Phase5..Phase6"
            selected_task = (ConvertTo-RelayHashtable -InputObject $candidate["selected_task"])
            declared_changed_files = @($metadata["declared_changed_files"])
            resource_locks = @($metadata["resource_locks"])
            parallel_safety = [string]$metadata["parallel_safety"]
            slot_id = [string]$metadata["slot_id"]
            workspace_id = if ([string]::IsNullOrWhiteSpace([string]$metadata["workspace_id"])) { "workspace-$workerId" } else { [string]$metadata["workspace_id"] }
        }) | Out-Null
    }

    $group = [ordered]@{
        id = $groupId
        group_id = $groupId
        status = "planned"
        phase = "Phase5..Phase6"
        phase_range = "Phase5..Phase6"
        task_ids = @($taskIds)
        worker_ids = @($workerIds.ToArray())
        policy = "wait_for_siblings"
        dry_run = $true
    }

    return [ordered]@{
        status = "planned"
        reason = "planned $($workers.Count) task group worker(s)"
        group = $group
        workers = @($workers.ToArray())
        rejected_candidates = @($rejected.ToArray())
        run_state = $state
    }
}

function New-TaskGroupJobPackage {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$ProviderSpec,
        [string]$PackageRoot,
        [string]$WorkspaceRoot,
        [string]$SourceWorkspace,
        [string]$WorkspaceMode = "isolated-copy-experimental",
        [string]$CommitPolicy = "all_or_nothing",
        [int]$LeaseDurationMinutes = 120,
        [switch]$AllowSingleParallelJob,
        [switch]$AllowCautiousSafety,
        [switch]$AllowNonParallelSafety,
        [switch]$AllowEmptyChangedFiles
    )

    $plan = New-TaskGroupParallelPlan -ProjectRoot $ProjectRoot -RunState $RunState -AllowSingleParallelJob:$AllowSingleParallelJob -AllowCautiousSafety:$AllowCautiousSafety -AllowNonParallelSafety:$AllowNonParallelSafety -AllowEmptyChangedFiles:$AllowEmptyChangedFiles
    if ([string]$plan["status"] -ne "planned") {
        return [ordered]@{
            status = [string]$plan["status"]
            reason = [string]$plan["reason"]
            package_path = $null
            package = $null
            run_state = $plan["run_state"]
            rejected_candidates = @($plan["rejected_candidates"])
        }
    }

    $state = Initialize-RunStateCompatibilityFields -RunState $plan["run_state"]
    $runId = [string]$state["run_id"]
    $group = ConvertTo-RelayHashtable -InputObject $plan["group"]
    $groupId = [string]$group["group_id"]
    if ([string]::IsNullOrWhiteSpace($groupId)) {
        $groupId = [string]$group["id"]
    }

    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = Get-RunJobPath -ProjectRoot $ProjectRoot -RunId $runId -JobId $groupId
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $runId) "workspaces"
    }
    if ([string]::IsNullOrWhiteSpace($SourceWorkspace)) {
        $SourceWorkspace = $ProjectRoot
    }
    foreach ($path in @($PackageRoot, $WorkspaceRoot)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    $now = (Get-Date).ToString("o")
    $leaseExpiresAt = (Get-Date).AddMinutes($LeaseDurationMinutes).ToString("o")
    $provider = ConvertTo-RelayHashtable -InputObject $ProviderSpec
    $workerPackages = New-Object System.Collections.Generic.List[object]
    $workerIds = New-Object System.Collections.Generic.List[string]
    $taskIds = New-Object System.Collections.Generic.List[string]

    foreach ($workerPlan in @($plan["workers"])) {
        $worker = ConvertTo-RelayHashtable -InputObject $workerPlan
        $workerId = [string]$worker["worker_id"]
        if ([string]::IsNullOrWhiteSpace($workerId)) {
            $workerId = [string]$worker["id"]
        }
        $taskId = [string]$worker["task_id"]
        $workspace = New-IsolatedJobWorkspace -ProjectRoot $ProjectRoot -RunId $runId -JobId $workerId -SourceWorkspace $SourceWorkspace -Force
        $workspacePath = [string]$workspace["workspace_path"]
        $artifactRoot = if (Get-Command Get-JobArtifactsRootPath -ErrorAction SilentlyContinue) {
            Get-JobArtifactsRootPath -ProjectRoot $ProjectRoot -RunId $runId -JobId $workerId
        }
        else {
            Join-Path (Get-RunJobPath -ProjectRoot $ProjectRoot -RunId $runId -JobId $workerId) "artifacts"
        }
        foreach ($path in @($artifactRoot)) {
            if (-not (Test-Path $path)) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }
        }
        $baseline = New-WorkspaceBaselineSnapshot -WorkspaceRoot $workspacePath -Paths @($worker["declared_changed_files"])

        $leaseToken = New-RunStateLeaseToken
        $workerIds.Add($workerId) | Out-Null
        $taskIds.Add($taskId) | Out-Null
        $workerPackage = [ordered]@{
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
            selected_task = (ConvertTo-RelayHashtable -InputObject $worker["selected_task"])
            workspace_path = $workspacePath
            artifact_root = $artifactRoot
            declared_changed_files = @($worker["declared_changed_files"])
            resource_locks = @($worker["resource_locks"])
            baseline_snapshot = $baseline
            lease_token = $leaseToken
        }
        $workerPackages.Add($workerPackage) | Out-Null

        $state["task_group_workers"][$workerId] = [ordered]@{
            id = $workerId
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            status = "queued"
            phase = "Phase5"
            current_phase = "Phase5"
            phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
            workspace_path = $workspacePath
            artifact_root = $artifactRoot
            declared_changed_files = @($worker["declared_changed_files"])
            resource_locks = @($worker["resource_locks"])
            baseline_snapshot = $baseline
            lease_token = $leaseToken
            lease_expires_at = $leaseExpiresAt
            created_at = $now
            updated_at = $now
        }

        if ($state["task_states"] -and $state["task_states"].ContainsKey($taskId)) {
            $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
            if ([string]$taskState["status"] -notin @("completed", "blocked", "abandoned")) {
                $taskState["status"] = "in_progress"
                $taskState["phase_cursor"] = "Phase5"
                $taskState["active_job_id"] = $null
                $taskState["wait_reason"] = "task_group_running"
                $taskState["task_group_id"] = $groupId
                $state["task_states"][$taskId] = $taskState
            }
        }
    }

    $state["task_groups"][$groupId] = [ordered]@{
        id = $groupId
        group_id = $groupId
        status = "planned"
        phase = "Phase5..Phase6"
        phase_range = "Phase5..Phase6"
        task_ids = @($taskIds.ToArray())
        worker_ids = @($workerIds.ToArray())
        package_path = (Join-Path $PackageRoot "task-group-package.json")
        workspace_mode = $WorkspaceMode
        commit_policy = $CommitPolicy
        policy = "wait_for_siblings"
        created_at = $now
        updated_at = $now
        failure_summary = $null
    }

    $content = [ordered]@{
        schema_version = 1
        package_kind = "task-group-leased-package"
        run_id = $runId
        group_id = $groupId
        phase_range = "Phase5..Phase6"
        created_at = $now
        workers = @($workerPackages.ToArray())
        provider_spec = $provider
        workspace_mode = $WorkspaceMode
        commit_policy = $CommitPolicy
    }
    $packagePath = Join-Path $PackageRoot "task-group-package.json"
    Set-Content -Path $packagePath -Value (($content | ConvertTo-Json -Depth 50) + "`n") -Encoding UTF8

    return [ordered]@{
        status = "planned"
        reason = "created task group package with $($workerPackages.Count) queued worker(s)"
        group_id = $groupId
        package_path = $packagePath
        package = $content
        run_state = $state
        rejected_candidates = @($plan["rejected_candidates"])
    }
}

function New-TaskGroupJobPackages {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$ProviderSpec,
        [string]$PackageRoot,
        [string]$WorkspaceRoot,
        [string]$SourceWorkspace,
        [string]$WorkspaceMode = "isolated-copy-experimental",
        [string]$CommitPolicy = "all_or_nothing",
        [int]$LeaseDurationMinutes = 120,
        [switch]$AllowSingleParallelJob,
        [switch]$AllowCautiousSafety,
        [switch]$AllowNonParallelSafety,
        [switch]$AllowEmptyChangedFiles
    )

    return New-TaskGroupJobPackage -ProjectRoot $ProjectRoot -RunState $RunState -ProviderSpec $ProviderSpec -PackageRoot $PackageRoot -WorkspaceRoot $WorkspaceRoot -SourceWorkspace $SourceWorkspace -WorkspaceMode $WorkspaceMode -CommitPolicy $CommitPolicy -LeaseDurationMinutes $LeaseDurationMinutes -AllowSingleParallelJob:$AllowSingleParallelJob -AllowCautiousSafety:$AllowCautiousSafety -AllowNonParallelSafety:$AllowNonParallelSafety -AllowEmptyChangedFiles:$AllowEmptyChangedFiles
}

function New-ParallelStepJobPackages {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$ProviderSpec,
        [scriptblock]$PhaseDefinitionFactory,
        [scriptblock]$PromptFactory,
        [scriptblock]$WorkspacePathFactory,
        [scriptblock]$BaselineFactory,
        [string]$PackageRoot,
        [string]$LeaseOwner = "parallel-step",
        [int]$LeaseDurationMinutes = 120,
        [switch]$AllowSingleParallelJob,
        [switch]$AllowNonParallelSafety,
        [switch]$AllowCautiousSafety,
        [switch]$AllowEmptyChangedFiles
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $runId = [string]$state["run_id"]
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw "run_id is required to create parallel job packages."
    }

    $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
    if ([string]$taskLane["mode"] -ne "parallel") {
        return [ordered]@{ status = "wait"; reason = "task_lane.mode must be parallel"; packages = @(); run_state = $state; rejected_candidates = @() }
    }
    if ([int]$taskLane["max_parallel_jobs"] -le 1) {
        return [ordered]@{ status = "wait"; reason = "task_lane.max_parallel_jobs must be greater than 1"; packages = @(); run_state = $state; rejected_candidates = @() }
    }
    if (-not (Test-TaskScopedPhase -Phase ([string]$state["current_phase"]))) {
        return [ordered]@{ status = "wait"; reason = "current_phase is not task-scoped"; packages = @(); run_state = $state; rejected_candidates = @() }
    }

    $candidates = @(Get-BatchLeaseCandidates -RunState $state -ProjectRoot $ProjectRoot)
    $launchable = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        $test = Test-ParallelStepLaunchableCandidate -Candidate $candidate -AllowNonParallelSafety:$AllowNonParallelSafety -AllowCautiousSafety:$AllowCautiousSafety -AllowEmptyChangedFiles:$AllowEmptyChangedFiles
        if ([bool]$test["launchable"]) {
            $launchable.Add((ConvertTo-RelayHashtable -InputObject $candidate)) | Out-Null
        }
        else {
            $rejected.Add([ordered]@{ candidate = (ConvertTo-RelayHashtable -InputObject $candidate); launchability = $test }) | Out-Null
        }
    }

    if ($launchable.Count -eq 0) {
        return [ordered]@{ status = "wait"; reason = "no launchable candidates"; packages = @(); run_state = $state; rejected_candidates = @($rejected.ToArray()) }
    }
    if (-not $AllowSingleParallelJob -and $launchable.Count -lt 2) {
        return [ordered]@{ status = "wait"; reason = "fewer than two launchable candidates"; packages = @(); run_state = $state; rejected_candidates = @($rejected.ToArray()) }
    }

    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = Get-RunJobsPath -ProjectRoot $ProjectRoot -RunId $runId
    }
    if (-not (Test-Path $PackageRoot)) {
        New-Item -ItemType Directory -Path $PackageRoot -Force | Out-Null
    }

    $provider = ConvertTo-RelayHashtable -InputObject $ProviderSpec
    $packages = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($launchable.ToArray())) {
        $taskId = [string]$candidate["task_id"]
        $phase = [string]$candidate["phase"]
        $role = [string]$candidate["role"]
        $jobId = if (Get-Command New-ExecutionJobId -ErrorAction SilentlyContinue) {
            "$(New-ExecutionJobId -Phase $phase -Role $role)-$(([guid]::NewGuid().ToString('N')).Substring(0, 8))"
        }
        else {
            "job-$((Get-Date).ToString('yyyyMMddHHmmss'))-$(([guid]::NewGuid().ToString('N')).Substring(0, 8))"
        }

        $jobSpec = [ordered]@{
            run_id = $runId
            job_id = $jobId
            phase = $phase
            role = $role
            task_id = $taskId
            attempt = 1
            attempt_id = "__RELAY_ATTEMPT_ID__"
            provider = [string]$provider["provider"]
            command = [string]$provider["command"]
            flags = [string]$provider["flags"]
            selected_task = (ConvertTo-RelayHashtable -InputObject $candidate["selected_task"])
            resource_locks = @($candidate["resource_locks"])
            parallel_safety = [string]$candidate["parallel_safety"]
            slot_id = [string]$candidate["slot_id"]
            workspace_id = if ([string]::IsNullOrWhiteSpace([string]$candidate["workspace_id"])) { "workspace-$jobId" } else { [string]$candidate["workspace_id"] }
        }

        $leaseResult = ConvertTo-RelayHashtable -InputObject (Add-RunStateActiveJobLease -RunState $state -JobSpec $jobSpec -LeaseOwner $LeaseOwner -SlotId ([string]$jobSpec["slot_id"]) -WorkspaceId ([string]$jobSpec["workspace_id"]) -LeaseDurationMinutes $LeaseDurationMinutes)
        $state = ConvertTo-RelayHashtable -InputObject $leaseResult["run_state"]
        $lease = ConvertTo-RelayHashtable -InputObject $leaseResult["lease"]
        foreach ($field in @("lease_token", "lease_expires_at", "lease_owner", "slot_id", "workspace_id", "state_revision")) {
            $jobSpec[$field] = $lease[$field]
        }

        $phaseDefinition = if ($PhaseDefinitionFactory) {
            & $PhaseDefinitionFactory $phase $role $provider $candidate $jobSpec $state
        }
        else {
            @{}
        }
        $phaseDefinitionObject = ConvertTo-RelayHashtable -InputObject $phaseDefinition
        if ($phaseDefinitionObject -and $phaseDefinitionObject.ContainsKey("prompt_package")) {
            $jobSpec["prompt_package"] = $phaseDefinitionObject["prompt_package"]
        }
        $workspacePath = if ($WorkspacePathFactory) {
            [string](& $WorkspacePathFactory $state $candidate $jobSpec)
        }
        else {
            Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $runId) "workspaces\$jobId"
        }
        $jobSpec["workspace_path"] = $workspacePath
        $promptText = if ($PromptFactory) {
            [string](& $PromptFactory $state $candidate $jobSpec $phaseDefinitionObject)
        }
        else {
            ""
        }
        $baseline = if ($BaselineFactory) {
            & $BaselineFactory $workspacePath $candidate $jobSpec
        }
        else {
            $null
        }

        $content = New-ParallelStepJobPackageContent -RunId $runId -RunState $state -Candidate $candidate -JobSpec $jobSpec -PromptText $promptText -PhaseDefinition $phaseDefinitionObject -WorkspacePath $workspacePath -Baseline $baseline -ProviderSpec $provider
        $jobDir = Join-Path $PackageRoot $jobId
        if (-not (Test-Path $jobDir)) {
            New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        }
        $packagePath = Join-Path $jobDir "parallel-job-package.json"
        Set-Content -Path $packagePath -Value (($content | ConvertTo-Json -Depth 50) + "`n") -Encoding UTF8

        $events = @(
            [ordered]@{
                type = "job.leased"
                job_id = [string]$jobSpec["job_id"]
                phase = $phase
                role = $role
                task_id = $taskId
                lease_token = [string]$jobSpec["lease_token"]
                lease_owner = [string]$jobSpec["lease_owner"]
                slot_id = [string]$jobSpec["slot_id"]
                workspace_id = [string]$jobSpec["workspace_id"]
                lease_expires_at = [string]$jobSpec["lease_expires_at"]
                resource_locks = @($jobSpec["resource_locks"])
                parallel_safety = [string]$jobSpec["parallel_safety"]
            },
            [ordered]@{
                type = "task.selected"
                task_id = $taskId
                phase = $phase
            }
        )

        $packages.Add([ordered]@{
            job_id = [string]$jobSpec["job_id"]
            task_id = $taskId
            phase = $phase
            package_path = $packagePath
            package = $content
            job_spec = $jobSpec
            events = $events
        }) | Out-Null
    }

    return [ordered]@{
        status = "leased"
        reason = "leased $($packages.Count) parallel job package(s)"
        workspace_mode = "isolated-copy-experimental"
        run_state = $state
        packages = @($packages.ToArray())
        rejected_candidates = @($rejected.ToArray())
    }
}
