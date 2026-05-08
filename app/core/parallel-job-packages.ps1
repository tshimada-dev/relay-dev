if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Get-BatchLeaseCandidates -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "workflow-engine.ps1")
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
        $errors.Add("parallel_safety must be parallel") | Out-Null
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
        $test = Test-ParallelStepLaunchableCandidate -Candidate $candidate -AllowNonParallelSafety:$AllowNonParallelSafety -AllowEmptyChangedFiles:$AllowEmptyChangedFiles
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
