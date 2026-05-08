function ConvertTo-RelayHashtable {
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string] -or $InputObject -is [System.ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-RelayHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-RelayHashtable -InputObject $item))
        }
        return ,($items.ToArray())
    }

    $properties = @(
        $InputObject.PSObject.Properties |
            Where-Object { $_.MemberType.ToString() -in @("AliasProperty", "NoteProperty", "Property", "ScriptProperty") }
    )
    if ($properties.Count -gt 0) {
        $result = @{}
        foreach ($property in $properties) {
            $result[$property.Name] = ConvertTo-RelayHashtable -InputObject $property.Value
        }
        return $result
    }

    if ($InputObject -is [psobject]) {
        return @{}
    }

    return $InputObject
}

function New-RunId {
    param([datetime]$Now = (Get-Date))
    return "run-{0}" -f $Now.ToString("yyyyMMdd-HHmmss")
}

function Get-RunsRootPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot "runs")
}

function Get-RunRootPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    return (Join-Path (Get-RunsRootPath -ProjectRoot $ProjectRoot) $RunId)
}

function Get-RunStatePath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    return (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "run-state.json")
}

function Get-RunJobsPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    return (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "jobs")
}

function Get-RunJobPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId
    )

    return (Join-Path (Get-RunJobsPath -ProjectRoot $ProjectRoot -RunId $RunId) $JobId)
}

function Get-JobMetadataPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId
    )

    return (Join-Path (Get-RunJobPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId) "job.json")
}

function Write-JobMetadata {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)]$Metadata
    )

    Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $RunId
    $jobDir = Get-RunJobPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId
    if (-not (Test-Path $jobDir)) {
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    }

    $path = Get-JobMetadataPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId
    $json = (ConvertTo-RelayHashtable -InputObject $Metadata) | ConvertTo-Json -Depth 20
    Set-Content -Path $path -Value $json -Encoding UTF8
    return $path
}

function Read-JobMetadata {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId
    )

    $path = Get-JobMetadataPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId
    if (-not (Test-Path $path)) {
        return $null
    }

    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return (ConvertTo-RelayHashtable -InputObject ($raw | ConvertFrom-Json))
}

function Get-CurrentRunPointerPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path (Get-RunsRootPath -ProjectRoot $ProjectRoot) "current-run.json")
}

function Ensure-RunDirectories {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $paths = @(
        (Get-RunsRootPath -ProjectRoot $ProjectRoot),
        (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId),
        (Get-RunJobsPath -ProjectRoot $ProjectRoot -RunId $RunId),
        (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "artifacts"),
        (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "artifacts\run"),
        (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "artifacts\tasks")
    )

    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function ConvertTo-CompatibilityYamlDoubleQuoted {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $escaped = [string]$Value
    $escaped = $escaped -replace '\\', '\\'
    $escaped = $escaped -replace '"', '\"'
    $escaped = $escaped -replace "`r", '\r'
    $escaped = $escaped -replace "`n", '\n'
    return $escaped
}

function Get-CompatibilityStatusPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot "queue\status.yaml")
}

function Sync-RunStatePhaseHistory {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $now = (Get-Date).ToString("o")
    $currentTaskId = [string]$state["current_task_id"]
    $history = @($state["phase_history"])

    if ($history.Count -eq 0) {
        $history = @(
            [ordered]@{
                phase = $state["current_phase"]
                agent = $state["current_role"]
                task_id = $currentTaskId
                started = $state["created_at"]
                completed = ""
                result = ""
            }
        )
    }
    else {
        $lastIndex = $history.Count - 1
        $lastEntry = ConvertTo-RelayHashtable -InputObject $history[$lastIndex]
        if (
            $lastEntry["phase"] -ne $state["current_phase"] -or
            $lastEntry["agent"] -ne $state["current_role"] -or
            [string]$lastEntry["task_id"] -ne $currentTaskId
        ) {
            if ([string]::IsNullOrWhiteSpace([string]$lastEntry["completed"])) {
                $lastEntry["completed"] = $now
            }
            if ([string]::IsNullOrWhiteSpace([string]$lastEntry["result"])) {
                $lastEntry["result"] = "transitioned"
            }
            $history[$lastIndex] = $lastEntry
            $history += @(
                [ordered]@{
                    phase = $state["current_phase"]
                    agent = $state["current_role"]
                    task_id = $currentTaskId
                    started = $now
                    completed = ""
                    result = ""
                }
            )
        }
        elseif ($state["status"] -in @("completed", "failed", "blocked")) {
            $lastEntry["task_id"] = $currentTaskId
            if ([string]::IsNullOrWhiteSpace([string]$lastEntry["completed"])) {
                $lastEntry["completed"] = $now
            }
            $lastEntry["result"] = [string]$state["status"]
            $history[$lastIndex] = $lastEntry
        }
        else {
            $lastEntry["task_id"] = $currentTaskId
            $history[$lastIndex] = $lastEntry
        }
    }

    $state["phase_history"] = $history
    return $state
}

function Resolve-CompatibilityFeedback {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $explicitFeedback = [string]$state["feedback"]
    if (-not [string]::IsNullOrWhiteSpace($explicitFeedback)) {
        return $explicitFeedback
    }

    if ($state["pending_approval"]) {
        $pendingApproval = ConvertTo-RelayHashtable -InputObject $state["pending_approval"]
        $promptMessage = [string]$pendingApproval["prompt_message"]
        if (-not [string]::IsNullOrWhiteSpace($promptMessage)) {
            return $promptMessage
        }

        return "Approval pending for $($pendingApproval['requested_phase'])."
    }

    $taskId = [string]$state["current_task_id"]
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        return ""
    }

    switch ([string]$state["current_phase"]) {
        "Phase5" { return "Next task: [$taskId]. Reference phase4_task_breakdown.md for task details." }
        "Phase5-1" { return "[$taskId] implementation completed. Review phase5_implementation.md." }
        "Phase5-2" { return "Phase5-1 completion review passed. Run Phase5-2 security review for [$taskId]." }
        "Phase6" { return "Phase5-2 security review passed. Run Phase6 testing for [$taskId]." }
        default { return "" }
    }
}

function Write-CompatibilityStatusProjection {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState
    )

    $state = Sync-RunStatePhaseHistory -RunState $RunState
    $statusPath = Get-CompatibilityStatusPath -ProjectRoot $ProjectRoot
    $statusDir = Split-Path -Parent $statusPath
    if (-not (Test-Path $statusDir)) {
        New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
    }

    $timestamp = if ($state["updated_at"]) { [string]$state["updated_at"] } else { (Get-Date).ToString("o") }
    $feedback = Resolve-CompatibilityFeedback -RunState $state
    $yaml = @(
        "assigned_to: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$state['current_role'])))`"",
        "current_phase: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$state['current_phase'])))`"",
        "feedback: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value $feedback))`"",
        "timestamp: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value $timestamp))`"",
        "history:"
    )

    foreach ($entry in @($state["phase_history"])) {
        $historyEntry = ConvertTo-RelayHashtable -InputObject $entry
        $yaml += "  - phase: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$historyEntry['phase'])))`""
        $yaml += "    agent: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$historyEntry['agent'])))`""
        $yaml += "    task_id: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$historyEntry['task_id'])))`""
        $yaml += "    started: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$historyEntry['started'])))`""
        $yaml += "    completed: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$historyEntry['completed'])))`""
        $yaml += "    result: `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$historyEntry['result'])))`""
    }

    $tempPath = "${statusPath}.tmp"
    Set-Content -Path $tempPath -Value ($yaml -join "`n") -Encoding UTF8
    if (Test-Path $statusPath) {
        Remove-Item $statusPath -Force
    }
    Move-Item -Path $tempPath -Destination $statusPath -Force
    return $statusPath
}

function Initialize-RunStateActiveAttempt {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    if (-not $state.ContainsKey("active_attempt")) {
        $state["active_attempt"] = $null
    }

    return $state
}

function Initialize-RunStateParallelFields {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState

    if (-not $state.ContainsKey("state_revision")) {
        $state["state_revision"] = 0
    }
    else {
        $parsedRevision = 0
        if ([int]::TryParse([string]$state["state_revision"], [ref]$parsedRevision)) {
            $state["state_revision"] = $parsedRevision
        }
        else {
            $state["state_revision"] = 0
        }
    }

    if (-not $state.ContainsKey("active_jobs") -or $null -eq $state["active_jobs"]) {
        $state["active_jobs"] = @{}
    }
    else {
        $state["active_jobs"] = ConvertTo-RelayHashtable -InputObject $state["active_jobs"]
    }

    if (-not $state.ContainsKey("task_lane") -or $null -eq $state["task_lane"]) {
        $state["task_lane"] = [ordered]@{
            mode = "single"
            max_parallel_jobs = 1
            stop_leasing = $false
        }
    }
    else {
        $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
        if (-not $taskLane.ContainsKey("mode") -or [string]::IsNullOrWhiteSpace([string]$taskLane["mode"])) {
            $taskLane["mode"] = "single"
        }
        if (-not $taskLane.ContainsKey("max_parallel_jobs") -or $null -eq $taskLane["max_parallel_jobs"]) {
            $taskLane["max_parallel_jobs"] = 1
        }
        else {
            $parsedMaxParallelJobs = 1
            if ([int]::TryParse([string]$taskLane["max_parallel_jobs"], [ref]$parsedMaxParallelJobs) -and $parsedMaxParallelJobs -ge 1) {
                $taskLane["max_parallel_jobs"] = $parsedMaxParallelJobs
            }
            else {
                $taskLane["max_parallel_jobs"] = 1
            }
        }
        if (-not $taskLane.ContainsKey("stop_leasing") -or $null -eq $taskLane["stop_leasing"]) {
            $taskLane["stop_leasing"] = $false
        }
        $state["task_lane"] = $taskLane
    }

    if (-not $state.ContainsKey("task_states") -or $null -eq $state["task_states"]) {
        $state["task_states"] = @{}
    }
    else {
        $taskStates = ConvertTo-RelayHashtable -InputObject $state["task_states"]
        foreach ($taskId in @($taskStates.Keys)) {
            $taskState = ConvertTo-RelayHashtable -InputObject $taskStates[$taskId]
            if (-not $taskState.ContainsKey("phase_cursor")) {
                $taskState["phase_cursor"] = $null
            }
            if (-not $taskState.ContainsKey("active_job_id")) {
                $taskState["active_job_id"] = $null
            }
            if (-not $taskState.ContainsKey("wait_reason")) {
                $taskState["wait_reason"] = $null
            }
            $taskStates[$taskId] = $taskState
        }
        $state["task_states"] = $taskStates
    }

    return $state
}

function Initialize-RunStateCompatibilityFields {
    param([Parameter(Mandatory)]$RunState)

    $state = Initialize-RunStateActiveAttempt -RunState $RunState
    $state = Initialize-RunStateParallelFields -RunState $state
    return $state
}

function New-RunStateLeaseToken {
    return "lease-{0}" -f ([guid]::NewGuid().ToString("N"))
}

function Get-RunStateActiveJobIds {
    param([Parameter(Mandatory)]$RunState)

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $activeJobIds = New-Object System.Collections.Generic.List[string]
    foreach ($jobId in @($state["active_jobs"].Keys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$jobId)) {
            $activeJobIds.Add([string]$jobId)
        }
    }

    $compatJobId = [string]$state["active_job_id"]
    if (-not [string]::IsNullOrWhiteSpace($compatJobId) -and $compatJobId -notin @($activeJobIds.ToArray())) {
        $activeJobIds.Add($compatJobId)
    }

    return @($activeJobIds.ToArray())
}

function Add-RunStateActiveJobLease {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$JobSpec,
        [string]$LeaseOwner = "single-step",
        [string]$SlotId = "slot-01",
        [string]$WorkspaceId = "main",
        [int]$LeaseDurationMinutes = 120
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $jobId = [string]$job["job_id"]
    if ([string]::IsNullOrWhiteSpace($jobId)) {
        throw "job_id is required to create an active job lease."
    }

    $existingActiveJobIds = @(Get-RunStateActiveJobIds -RunState $state)
    $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
    $taskLaneMode = ([string]$taskLane["mode"]).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($taskLaneMode)) {
        $taskLaneMode = "single"
    }
    $maxParallelJobs = 1
    if (-not [int]::TryParse([string]$taskLane["max_parallel_jobs"], [ref]$maxParallelJobs) -or $maxParallelJobs -lt 1) {
        $maxParallelJobs = 1
    }
    $capacityLimit = if ($taskLaneMode -eq "parallel") { $maxParallelJobs } else { 1 }

    $taskId = if ([string]::IsNullOrWhiteSpace([string]$job["task_id"])) { $null } else { [string]$job["task_id"] }
    foreach ($existingJobId in $existingActiveJobIds) {
        if (-not $state["active_jobs"].ContainsKey($existingJobId)) {
            continue
        }

        $existingLease = ConvertTo-RelayHashtable -InputObject $state["active_jobs"][$existingJobId]
        if (
            -not [string]::IsNullOrWhiteSpace($taskId) -and
            [string]$existingLease["task_id"] -eq $taskId -and
            [string]$existingJobId -ne $jobId
        ) {
            throw "Cannot lease job '$jobId' for task '$taskId' because task is already leased by job '$existingJobId'."
        }
    }

    if ($jobId -notin $existingActiveJobIds -and $existingActiveJobIds.Count -ge $capacityLimit) {
        if ($taskLaneMode -eq "parallel") {
            throw "Cannot lease job '$jobId' because task lane capacity is full ($($existingActiveJobIds.Count)/$capacityLimit)."
        }

        throw "Cannot lease job '$jobId' because active job(s) already exist: $($existingActiveJobIds -join ', ')."
    }

    $now = Get-Date
    $leaseToken = if (-not [string]::IsNullOrWhiteSpace([string]$job["lease_token"])) { [string]$job["lease_token"] } else { New-RunStateLeaseToken }
    $resolvedSlotId = if (-not [string]::IsNullOrWhiteSpace([string]$job["slot_id"])) { [string]$job["slot_id"] } else { $SlotId }
    $resolvedWorkspaceId = if (-not [string]::IsNullOrWhiteSpace([string]$job["workspace_id"])) { [string]$job["workspace_id"] } else { $WorkspaceId }
    $lease = [ordered]@{
        job_id = $jobId
        task_id = $taskId
        phase = [string]$job["phase"]
        role = [string]$job["role"]
        lease_token = $leaseToken
        leased_at = $now.ToString("o")
        lease_expires_at = $now.AddMinutes($LeaseDurationMinutes).ToString("o")
        last_heartbeat_at = $now.ToString("o")
        lease_owner = $LeaseOwner
        slot_id = $resolvedSlotId
        workspace_id = $resolvedWorkspaceId
        state_revision = [int]$state["state_revision"]
    }
    if ($job.ContainsKey("resource_locks")) {
        $lease["resource_locks"] = @($job["resource_locks"])
    }
    if ($job.ContainsKey("parallel_safety")) {
        $lease["parallel_safety"] = [string]$job["parallel_safety"]
    }

    $state["active_jobs"][$jobId] = $lease
    if ([string]::IsNullOrWhiteSpace([string]$state["active_job_id"]) -or -not $state["active_jobs"].ContainsKey([string]$state["active_job_id"])) {
        $state["active_job_id"] = $jobId
    }

    $taskId = [string]$lease["task_id"]
    if (-not [string]::IsNullOrWhiteSpace($taskId) -and $state["task_states"].ContainsKey($taskId)) {
        $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
        $taskState["active_job_id"] = $jobId
        $taskState["phase_cursor"] = [string]$lease["phase"]
        $taskState["status"] = "in_progress"
        $taskState["wait_reason"] = $null
        $state["task_states"][$taskId] = $taskState
    }

    return [ordered]@{
        run_state = $state
        lease = $lease
    }
}

function Test-RunStateActiveJobLease {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$LeaseToken,
        [string]$Phase,
        [string]$TaskId,
        [datetime]$Now = (Get-Date)
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $errors = New-Object System.Collections.Generic.List[string]
    $lease = $null
    if (-not $state["active_jobs"].ContainsKey($JobId)) {
        $errors.Add("active job '$JobId' is not leased")
    }
    else {
        $lease = ConvertTo-RelayHashtable -InputObject $state["active_jobs"][$JobId]
        if ([string]$lease["lease_token"] -ne $LeaseToken) {
            $errors.Add("lease token mismatch for job '$JobId'")
        }
        if (-not [string]::IsNullOrWhiteSpace($Phase) -and [string]$lease["phase"] -ne $Phase) {
            $errors.Add("phase mismatch for job '$JobId'")
        }
        if (-not [string]::IsNullOrWhiteSpace($TaskId) -and [string]$lease["task_id"] -ne $TaskId) {
            $errors.Add("task mismatch for job '$JobId'")
        }

        $leaseExpiresAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$lease["lease_expires_at"], [ref]$leaseExpiresAt)) {
            if ($leaseExpiresAt -lt $Now) {
                $errors.Add("lease expired for job '$JobId'")
            }
        }
    }

    return [ordered]@{
        valid = ($errors.Count -eq 0)
        errors = @($errors.ToArray())
        lease = $lease
    }
}

function Update-RunStateActiveJobHeartbeat {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$LeaseToken,
        [datetime]$Now = (Get-Date),
        [int]$LeaseDurationMinutes = 120
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $errors = New-Object System.Collections.Generic.List[string]
    $lease = $null

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        $errors.Add("job_id is required")
    }
    elseif (-not $state["active_jobs"].ContainsKey($JobId)) {
        $errors.Add("active job '$JobId' is not leased")
    }
    else {
        $lease = ConvertTo-RelayHashtable -InputObject $state["active_jobs"][$JobId]
        if ([string]::IsNullOrWhiteSpace($LeaseToken)) {
            $errors.Add("lease_token is required for job '$JobId'")
        }
        elseif ([string]$lease["lease_token"] -ne $LeaseToken) {
            $errors.Add("lease token mismatch for job '$JobId'")
        }
    }

    if ($LeaseDurationMinutes -lt 1) {
        $errors.Add("LeaseDurationMinutes must be at least 1")
    }

    if ($errors.Count -eq 0) {
        $lease["last_heartbeat_at"] = $Now.ToString("o")
        $lease["lease_expires_at"] = $Now.AddMinutes($LeaseDurationMinutes).ToString("o")
        $state["active_jobs"][$JobId] = $lease
        $state["updated_at"] = $Now.ToString("o")
    }

    return [ordered]@{
        valid = ($errors.Count -eq 0)
        errors = @($errors.ToArray())
        run_state = $state
        lease = $lease
    }
}

function Clear-RunStateActiveJobLease {
    param(
        [Parameter(Mandatory)]$RunState,
        [string]$JobId
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $resolvedJobId = if (-not [string]::IsNullOrWhiteSpace($JobId)) { $JobId } else { [string]$state["active_job_id"] }

    if (-not [string]::IsNullOrWhiteSpace($resolvedJobId) -and $state["active_jobs"].ContainsKey($resolvedJobId)) {
        $state["active_jobs"].Remove($resolvedJobId)
    }

    if ([string]$state["active_job_id"] -eq $resolvedJobId) {
        $remainingJobIds = @(
            @($state["active_jobs"].Keys) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Sort-Object
        )
        $state["active_job_id"] = if ($remainingJobIds.Count -gt 0) { $remainingJobIds[0] } else { $null }
    }

    foreach ($taskId in @($state["task_states"].Keys)) {
        $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
        if ([string]$taskState["active_job_id"] -eq $resolvedJobId) {
            $taskState["active_job_id"] = $null
            $state["task_states"][$taskId] = $taskState
        }
    }

    return $state
}

function New-RunState {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$TaskId = "task-main",
        [string]$CurrentPhase = "Phase0",
        [string]$CurrentRole = "implementer",
        [string]$Status = "running"
    )

    $now = (Get-Date).ToString("o")
    return [ordered]@{
        run_id = $RunId
        task_id = $TaskId
        project_root = $ProjectRoot
        status = $Status
        current_phase = $CurrentPhase
        current_role = $CurrentRole
        current_task_id = $null
        active_job_id = $null
        active_jobs = @{}
        active_attempt = $null
        pending_approval = $null
        open_requirements = @()
        task_order = @()
        task_states = @{}
        task_lane = [ordered]@{
            mode = "single"
            max_parallel_jobs = 1
            stop_leasing = $false
        }
        state_revision = 0
        feedback = ""
        phase_history = @(
            [ordered]@{
                phase = $CurrentPhase
                agent = $CurrentRole
                task_id = $null
                started = $now
                completed = ""
                result = ""
            }
        )
        created_at = $now
        updated_at = $now
    }
}

function Start-RunStateActiveAttempt {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$AttemptId,
        [string]$Phase,
        [string]$Stage,
        [string]$Status = "running",
        [string]$TaskId,
        [string]$JobId,
        [string]$ArchivePath
    )

    $state = Initialize-RunStateActiveAttempt -RunState $RunState
    $now = (Get-Date).ToString("o")
    $state["active_attempt"] = [ordered]@{
        attempt_id = $AttemptId
        phase = if ($PSBoundParameters.ContainsKey("Phase")) { $Phase } else { [string]$state["current_phase"] }
        stage = $Stage
        status = $Status
        task_id = $TaskId
        job_id = $JobId
        archive_path = $ArchivePath
        started_at = $now
        updated_at = $now
        completed_at = $null
        result = $null
    }

    return $state
}

function Update-RunStateActiveAttempt {
    param(
        [Parameter(Mandatory)]$RunState,
        [string]$AttemptId,
        [string]$Phase,
        [string]$Stage,
        [string]$Status,
        [string]$TaskId,
        [string]$JobId,
        [string]$ArchivePath,
        [string]$Result
    )

    $state = Initialize-RunStateActiveAttempt -RunState $RunState
    $attempt = ConvertTo-RelayHashtable -InputObject $state["active_attempt"]
    if ($null -eq $attempt) {
        throw "Cannot update active_attempt because no attempt is active."
    }

    if ($PSBoundParameters.ContainsKey("Phase")) {
        $attempt["phase"] = $Phase
    }
    if ($PSBoundParameters.ContainsKey("AttemptId")) {
        $attempt["attempt_id"] = $AttemptId
    }
    if ($PSBoundParameters.ContainsKey("Stage")) {
        $attempt["stage"] = $Stage
    }
    if ($PSBoundParameters.ContainsKey("Status")) {
        $attempt["status"] = $Status
    }
    if ($PSBoundParameters.ContainsKey("TaskId")) {
        $attempt["task_id"] = $TaskId
    }
    if ($PSBoundParameters.ContainsKey("JobId")) {
        $attempt["job_id"] = $JobId
    }
    if ($PSBoundParameters.ContainsKey("ArchivePath")) {
        $attempt["archive_path"] = $ArchivePath
    }
    if ($PSBoundParameters.ContainsKey("Result")) {
        $attempt["result"] = $Result
    }

    $attempt["updated_at"] = (Get-Date).ToString("o")
    $state["active_attempt"] = $attempt
    return $state
}

function Clear-RunStateActiveAttempt {
    param(
        [Parameter(Mandatory)]$RunState,
        [string]$Status,
        [string]$Result,
        [string]$ArchivePath,
        [switch]$PassThruAttempt
    )

    $state = Initialize-RunStateActiveAttempt -RunState $RunState
    $attempt = ConvertTo-RelayHashtable -InputObject $state["active_attempt"]
    if ($null -eq $attempt) {
        return $(if ($PassThruAttempt) { $null } else { $state })
    }

    if ($PSBoundParameters.ContainsKey("Status")) {
        $attempt["status"] = $Status
    }
    if ($PSBoundParameters.ContainsKey("Result")) {
        $attempt["result"] = $Result
    }
    if ($PSBoundParameters.ContainsKey("ArchivePath")) {
        $attempt["archive_path"] = $ArchivePath
    }

    $now = (Get-Date).ToString("o")
    $attempt["updated_at"] = $now
    $attempt["completed_at"] = $now
    $state["active_attempt"] = $null

    if ($PassThruAttempt) {
        return $attempt
    }

    return $state
}

function Write-RunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $runId = $state["run_id"]
    if (-not $runId) {
        throw "run_id is required to write run-state.json"
    }

    Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $runId

    $state["updated_at"] = (Get-Date).ToString("o")
    $state["state_revision"] = [int]$state["state_revision"] + 1
    $state = Sync-RunStatePhaseHistory -RunState $state
    $path = Get-RunStatePath -ProjectRoot $ProjectRoot -RunId $runId
    $tempPath = "${path}.tmp"
    $json = $state | ConvertTo-Json -Depth 20
    Set-Content -Path $tempPath -Value $json -Encoding UTF8
    if (Test-Path $path) {
        Remove-Item $path -Force
    }
    Move-Item -Path $tempPath -Destination $path -Force
    Write-CompatibilityStatusProjection -ProjectRoot $ProjectRoot -RunState $state | Out-Null
    return $path
}

function Read-RunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $path = Get-RunStatePath -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not (Test-Path $path)) {
        return $null
    }

    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return (Initialize-RunStateCompatibilityFields -RunState ($raw | ConvertFrom-Json))
}

function Set-CurrentRunPointer {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $runsRoot = Get-RunsRootPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path $runsRoot)) {
        New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null
    }

    $pointer = [ordered]@{
        run_id = $RunId
        updated_at = (Get-Date).ToString("o")
    }
    $path = Get-CurrentRunPointerPath -ProjectRoot $ProjectRoot
    Set-Content -Path $path -Value ($pointer | ConvertTo-Json -Depth 5) -Encoding UTF8
    return $path
}

function Resolve-ActiveRunId {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $pointerPath = Get-CurrentRunPointerPath -ProjectRoot $ProjectRoot
    if (Test-Path $pointerPath) {
        $pointerRaw = Get-Content -Path $pointerPath -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($pointerRaw)) {
            $pointer = ConvertTo-RelayHashtable -InputObject ($pointerRaw | ConvertFrom-Json)
            if ($pointer["run_id"]) {
                return $pointer["run_id"]
            }
        }
    }

    $runsRoot = Get-RunsRootPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path $runsRoot)) {
        return $null
    }

    $latest = Get-ChildItem -Path $runsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "run-state.json") } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latest) {
        return $latest.Name
    }

    return $null
}
