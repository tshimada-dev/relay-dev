function Test-TaskLaneTimestampInPast {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [ref]$parsed)) {
        return $false
    }

    return ($parsed.ToUniversalTime() -lt (Get-Date).ToUniversalTime())
}

function Test-TaskLaneTimestampOlderThan {
    param(
        [AllowNull()][string]$Value,
        [int]$Minutes = 15
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [ref]$parsed)) {
        return $false
    }

    return ($parsed.ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddMinutes(-1 * $Minutes))
}

function Copy-TaskLaneFieldIfPresent {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$FieldName
    )

    if ($Source.ContainsKey($FieldName) -and $null -ne $Source[$FieldName]) {
        $value = [string]$Source[$FieldName]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $Target[$FieldName] = $value
        }
    }
}

function ConvertTo-TaskLaneBoolean {
    param(
        [AllowNull()]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }
    if ($Value -is [bool]) {
        return $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    $parsed = $false
    if ([bool]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function ConvertTo-TaskLaneStringArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @(
        @($Value) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
}

function Copy-TaskLaneArrayFieldIfPresent {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$FieldName
    )

    if ($Source.ContainsKey($FieldName) -and $null -ne $Source[$FieldName]) {
        $Target[$FieldName] = @(ConvertTo-TaskLaneStringArray -Value $Source[$FieldName])
    }
}

function Test-TaskLaneTaskScopedPhase {
    param([AllowNull()][string]$Phase)

    if ([string]::IsNullOrWhiteSpace($Phase)) {
        return $false
    }
    if (Get-Command Test-TaskScopedPhase -ErrorAction SilentlyContinue) {
        return [bool](Test-TaskScopedPhase -Phase $Phase)
    }

    return ($Phase -in @("Phase5", "Phase5-1", "Phase5-2", "Phase6"))
}

function New-TaskLaneLaunchBlockDetail {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Hint
    )

    return [ordered]@{
        launch_block_reason = $Reason
        operator_hint = $Hint
    }
}

function Test-TaskLaneActiveTaskGroupStatus {
    param([AllowNull()][string]$Status)

    return ($Status -in @("running", "waiting_approval", "partial_failed"))
}

function Resolve-TaskLaneStallReason {
    param(
        [Parameter(Mandatory)]$Lane,
        [Parameter(Mandatory)]$ActiveJobs,
        [Parameter(Mandatory)]$ReadyQueue,
        [Parameter(Mandatory)]$WaitingTasks,
        [int]$CapacityRemaining = 0
    )

    if ($Lane.ContainsKey("stop_leasing") -and (ConvertTo-TaskLaneBoolean -Value $Lane["stop_leasing"])) {
        return "stop_leasing"
    }

    if (@($ActiveJobs).Count -gt 0) {
        if ($CapacityRemaining -le 0) {
            return "capacity_full"
        }
        return "job_in_progress"
    }

    if (@($ReadyQueue).Count -gt 0) {
        return ""
    }

    $resourceLockWaits = @(
        @($WaitingTasks) |
            ForEach-Object { ConvertTo-RelayHashtable -InputObject $_ } |
            Where-Object { $_ -and [string]$_["wait_reason"] -eq "resource_lock" }
    )
    if ($resourceLockWaits.Count -gt 0) {
        return "resource_locked"
    }

    return "no_ready_tasks"
}

function Resolve-TaskLaneLeaseCandidates {
    param(
        [Parameter(Mandatory)]$RunState,
        [AllowNull()][string]$ProjectRoot,
        [Parameter(Mandatory)]$ReadyQueue,
        [int]$CapacityRemaining = 0
    )

    if ($CapacityRemaining -le 0) {
        return @()
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        foreach ($commandName in @("Get-BatchLeaseCandidates", "Get-TaskLeaseCandidates", "Get-TaskLeaseCandidateBatch", "Get-TaskDispatchCandidates")) {
            $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue
            if (-not $command) {
                continue
            }

            $parameters = @{}
            foreach ($name in @($command.Parameters.Keys)) {
                switch ($name) {
                    "RunState" { $parameters[$name] = $RunState }
                    "ProjectRoot" { $parameters[$name] = $ProjectRoot }
                    "Limit" { $parameters[$name] = $CapacityRemaining }
                    "MaxCandidates" { $parameters[$name] = $CapacityRemaining }
                    "CapacityRemaining" { $parameters[$name] = $CapacityRemaining }
                }
            }

            try {
                return @(& $command @parameters)
            }
            catch {
                return @()
            }
        }
    }

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $items = New-Object System.Collections.Generic.List[object]
    $activeJobs = ConvertTo-RelayHashtable -InputObject $state["active_jobs"]
    if (-not $activeJobs) {
        $activeJobs = @{}
    }
    $slotNumber = @($activeJobs.Keys).Count + 1
    foreach ($taskRaw in (@($ReadyQueue) | Select-Object -First $CapacityRemaining)) {
        $task = ConvertTo-RelayHashtable -InputObject $taskRaw
        if (-not $task) {
            continue
        }

        $row = [ordered]@{
            task_id = [string]$task["task_id"]
            phase = if ($task["phase_cursor"]) { [string]$task["phase_cursor"] } else { [string]$state["current_phase"] }
            role = [string]$state["current_role"]
            selected_task = [string]$task["task_id"]
            resource_locks = @(ConvertTo-TaskLaneStringArray -Value $task["resource_locks"])
            parallel_safety = [string]$task["parallel_safety"]
            slot_id = "slot-$slotNumber"
        }
        $items.Add($row) | Out-Null
        $slotNumber++
    }

    return @($items.ToArray())
}

function Resolve-TaskLaneEffectiveField {
    param(
        [Parameter(Mandatory)]$Task,
        [AllowNull()]$Eligibility,
        [Parameter(Mandatory)][string]$FieldName
    )

    $eligibilityRow = ConvertTo-RelayHashtable -InputObject $Eligibility
    if ($eligibilityRow -and -not [string]::IsNullOrWhiteSpace([string]$eligibilityRow[$FieldName])) {
        return [string]$eligibilityRow[$FieldName]
    }

    $taskRow = ConvertTo-RelayHashtable -InputObject $Task
    return [string]$taskRow[$FieldName]
}

function Get-TaskLaneLaunchBlockDetail {
    param(
        [Parameter(Mandatory)]$Task,
        [AllowNull()]$Eligibility = $null,
        [bool]$IsLeaseCandidate = $false,
        [int]$CapacityRemaining = 0,
        [AllowNull()][string]$CurrentPhase = "",
        [Parameter(Mandatory)]$ActiveJobs
    )

    $taskRow = ConvertTo-RelayHashtable -InputObject $Task
    if (-not $taskRow) {
        $taskRow = @{}
    }
    $activeJobCount = @($ActiveJobs).Count
    $status = [string]$taskRow["status"]
    $waitReason = Resolve-TaskLaneEffectiveField -Task $taskRow -Eligibility $Eligibility -FieldName "wait_reason"
    $parallelSafety = Resolve-TaskLaneEffectiveField -Task $taskRow -Eligibility $Eligibility -FieldName "parallel_safety"

    if ($waitReason -in @("dependency", "dependencies", "blocked_dependency", "depends_on", "blocked_by_task")) {
        return New-TaskLaneLaunchBlockDetail -Reason "dependency" -Hint "Waiting for dependency tasks to complete or dependency repair to clear this task."
    }
    if (@(ConvertTo-TaskLaneStringArray -Value $taskRow["depends_on"]).Count -gt 0 -and $status -in @("blocked", "waiting")) {
        return New-TaskLaneLaunchBlockDetail -Reason "dependency" -Hint "Waiting for dependency tasks to complete or dependency repair to clear this task."
    }
    if ($waitReason -in @("resource_lock", "serial_safety", "stop_leasing")) {
        $hint = switch ($waitReason) {
            "resource_lock" { "Waiting for the active job holding the listed resource lock to finish." }
            "serial_safety" { "Serial safety requires this task or the active serial task to run alone." }
            default { "Task leasing is paused for this lane." }
        }
        return New-TaskLaneLaunchBlockDetail -Reason $waitReason -Hint $hint
    }
    if ($activeJobCount -gt 0 -and [string]::IsNullOrWhiteSpace($waitReason) -and $status -in @("running", "waiting")) {
        return New-TaskLaneLaunchBlockDetail -Reason "active_job" -Hint "A task is already running; wait for an active job to finish before this row can launch."
    }
    if ($status -eq "running" -and [string]::IsNullOrWhiteSpace($waitReason)) {
        return New-TaskLaneLaunchBlockDetail -Reason "running_without_active_job" -Hint "Task state says running, but no active job is attached; inspect recovery state before launching more work."
    }

    if ($parallelSafety -eq "cautious") {
        return New-TaskLaneLaunchBlockDetail -Reason "cautious_parallel_safety" -Hint "Requires the operator to opt in with -AllowCautiousParallelJob before packaging a cautious parallel job."
    }
    if ($parallelSafety -eq "serial") {
        return New-TaskLaneLaunchBlockDetail -Reason "serial_parallel_safety" -Hint "Serial tasks are not launchable as parallel jobs; run them through the normal single-task path."
    }

    if (-not $IsLeaseCandidate) {
        if ($CapacityRemaining -le 0) {
            return New-TaskLaneLaunchBlockDetail -Reason "capacity_full" -Hint "All parallel job slots are currently in use."
        }
        if (-not [string]::IsNullOrWhiteSpace($CurrentPhase) -and -not (Test-TaskLaneTaskScopedPhase -Phase $CurrentPhase)) {
            return New-TaskLaneLaunchBlockDetail -Reason "non_task_scoped_current_phase" -Hint "The run is in a non task-scoped phase; task leases resume in a task-scoped phase."
        }
        if ($activeJobCount -gt 0) {
            return New-TaskLaneLaunchBlockDetail -Reason "active_job" -Hint "Another active job is constraining this task; wait for it to finish or inspect blocking details."
        }
    }

    return $null
}

function Add-TaskLaneLaunchBlockDetail {
    param(
        [Parameter(Mandatory)]$Row,
        [AllowNull()]$Detail
    )

    $detailRow = ConvertTo-RelayHashtable -InputObject $Detail
    if (-not $detailRow) {
        return
    }
    foreach ($field in @("launch_block_reason", "operator_hint")) {
        if ($detailRow.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace([string]$detailRow[$field])) {
            $Row[$field] = [string]$detailRow[$field]
        }
    }
}

function New-TaskLaneLeaseCandidateSet {
    param([AllowNull()]$LeaseCandidates)

    $taskIds = @{}
    foreach ($candidateRaw in @($LeaseCandidates)) {
        $candidate = ConvertTo-RelayHashtable -InputObject $candidateRaw
        if ($candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate["task_id"])) {
            $taskIds[[string]$candidate["task_id"]] = $true
        }
    }

    return $taskIds
}

function Add-TaskLaneLaunchBlockDetails {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)]$TaskStates,
        [Parameter(Mandatory)]$EligibilityByTaskId,
        [Parameter(Mandatory)]$LeaseCandidateTaskIds,
        [int]$CapacityRemaining = 0,
        [AllowNull()][string]$CurrentPhase = "",
        [Parameter(Mandatory)]$ActiveJobs
    )

    foreach ($rowRaw in @($Rows)) {
        $row = if ($rowRaw -is [System.Collections.IDictionary]) { $rowRaw } else { ConvertTo-RelayHashtable -InputObject $rowRaw }
        if (-not $row -or [string]::IsNullOrWhiteSpace([string]$row["task_id"])) {
            continue
        }

        $taskId = [string]$row["task_id"]
        $task = if ($TaskStates.ContainsKey($taskId)) { ConvertTo-RelayHashtable -InputObject $TaskStates[$taskId] } else { $row }
        $eligibility = if ($EligibilityByTaskId.ContainsKey($taskId)) { ConvertTo-RelayHashtable -InputObject $EligibilityByTaskId[$taskId] } else { $null }
        $detail = Get-TaskLaneLaunchBlockDetail -Task $task -Eligibility $eligibility -IsLeaseCandidate:$LeaseCandidateTaskIds.ContainsKey($taskId) -CapacityRemaining $CapacityRemaining -CurrentPhase $CurrentPhase -ActiveJobs @($ActiveJobs)
        Add-TaskLaneLaunchBlockDetail -Row $row -Detail $detail
    }
}

function New-TaskLaneSummary {
    param(
        [Parameter(Mandatory)]$RunState,
        [AllowNull()]$Events = $null
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $taskStates = ConvertTo-RelayHashtable -InputObject $state["task_states"]
    if (-not $taskStates) {
        $taskStates = @{}
    }

    $activeJobs = ConvertTo-RelayHashtable -InputObject $state["active_jobs"]
    if (-not $activeJobs) {
        $activeJobs = @{}
    }

    $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
    if (-not $taskLane) {
        $taskLane = @{}
    }

    $eligibilityByTaskId = @{}
    $projectRoot = [string]$state["project_root"]
    if ((Get-Command Get-TaskDispatchEligibility -ErrorAction SilentlyContinue) -and -not [string]::IsNullOrWhiteSpace($projectRoot)) {
        try {
            foreach ($eligibilityRaw in @(Get-TaskDispatchEligibility -RunState $state -ProjectRoot $projectRoot)) {
                $eligibility = ConvertTo-RelayHashtable -InputObject $eligibilityRaw
                if ($eligibility -and -not [string]::IsNullOrWhiteSpace([string]$eligibility["task_id"])) {
                    $eligibilityByTaskId[[string]$eligibility["task_id"]] = $eligibility
                }
            }
        }
        catch {
            $eligibilityByTaskId = @{}
        }
    }

    $activeJobRows = New-Object System.Collections.Generic.List[object]
    foreach ($jobId in @($activeJobs.Keys | Sort-Object)) {
        $job = ConvertTo-RelayHashtable -InputObject $activeJobs[$jobId]
        if (-not $job) {
            $job = @{}
        }

        $row = [ordered]@{
            job_id = if ($job.ContainsKey("job_id") -and -not [string]::IsNullOrWhiteSpace([string]$job["job_id"])) { [string]$job["job_id"] } else { [string]$jobId }
            task_id = [string]$job["task_id"]
            phase = [string]$job["phase"]
            role = [string]$job["role"]
            stale = $false
            stale_reason = ""
        }

        foreach ($field in @("lease_owner", "slot", "slot_id", "workspace", "workspace_id")) {
            Copy-TaskLaneFieldIfPresent -Source $job -Target $row -FieldName $field
        }

        $staleReasons = New-Object System.Collections.Generic.List[string]
        if (Test-TaskLaneTimestampInPast -Value ([string]$job["lease_expires_at"])) {
            $staleReasons.Add("lease_expired") | Out-Null
        }
        if (Test-TaskLaneTimestampOlderThan -Value ([string]$job["last_heartbeat_at"]) -Minutes 15) {
            $staleReasons.Add("heartbeat_stale") | Out-Null
        }
        if ($staleReasons.Count -gt 0) {
            $row["stale"] = $true
            $row["stale_reason"] = ($staleReasons.ToArray() -join ",")
        }

        $activeJobRows.Add($row) | Out-Null
    }

    $taskGroups = ConvertTo-RelayHashtable -InputObject $state["task_groups"]
    if (-not $taskGroups) {
        $taskGroups = @{}
    }

    $taskGroupWorkers = ConvertTo-RelayHashtable -InputObject $state["task_group_workers"]
    if (-not $taskGroupWorkers) {
        $taskGroupWorkers = @{}
    }

    $taskGroupRows = New-Object System.Collections.Generic.List[object]
    $taskGroupWorkerRows = New-Object System.Collections.Generic.List[object]
    $activeTaskGroupCount = 0
    $runningTaskGroupCount = 0
    $runningTaskGroupWorkerCount = 0

    foreach ($groupId in @($taskGroups.Keys | Sort-Object)) {
        $group = ConvertTo-RelayHashtable -InputObject $taskGroups[$groupId]
        if (-not $group) {
            $group = @{}
        }

        $resolvedGroupId = if ($group.ContainsKey("id") -and -not [string]::IsNullOrWhiteSpace([string]$group["id"])) { [string]$group["id"] } else { [string]$groupId }
        $phase = if (-not [string]::IsNullOrWhiteSpace([string]$group["phase"])) { [string]$group["phase"] } else { [string]$group["phase_range"] }
        $phaseRange = if (-not [string]::IsNullOrWhiteSpace([string]$group["phase_range"])) { [string]$group["phase_range"] } else { $phase }
        if ([string]::IsNullOrWhiteSpace($phase)) {
            $phase = "Phase5..Phase6"
        }
        if ([string]::IsNullOrWhiteSpace($phaseRange)) {
            $phaseRange = $phase
        }

        $status = if (-not [string]::IsNullOrWhiteSpace([string]$group["status"])) { [string]$group["status"] } else { "running" }
        if (Test-TaskLaneActiveTaskGroupStatus -Status $status) {
            $activeTaskGroupCount++
        }
        if ($status -eq "running") {
            $runningTaskGroupCount++
        }

        $row = [ordered]@{
            group_id = $resolvedGroupId
            status = $status
            phase = $phase
            current_phase = $phase
            phase_range = $phaseRange
            task_ids = @(ConvertTo-TaskLaneStringArray -Value $group["task_ids"])
            worker_ids = @(ConvertTo-TaskLaneStringArray -Value $group["worker_ids"])
        }
        foreach ($field in @("created_at", "updated_at", "failure_summary")) {
            Copy-TaskLaneFieldIfPresent -Source $group -Target $row -FieldName $field
        }
        $taskGroupRows.Add($row) | Out-Null
    }

    foreach ($workerId in @($taskGroupWorkers.Keys | Sort-Object)) {
        $worker = ConvertTo-RelayHashtable -InputObject $taskGroupWorkers[$workerId]
        if (-not $worker) {
            $worker = @{}
        }

        $resolvedWorkerId = if ($worker.ContainsKey("id") -and -not [string]::IsNullOrWhiteSpace([string]$worker["id"])) { [string]$worker["id"] } else { [string]$workerId }
        $phase = if (-not [string]::IsNullOrWhiteSpace([string]$worker["current_phase"])) { [string]$worker["current_phase"] } else { [string]$worker["phase"] }
        if ([string]::IsNullOrWhiteSpace($phase)) {
            $phase = "Phase5"
        }
        $status = if (-not [string]::IsNullOrWhiteSpace([string]$worker["status"])) { [string]$worker["status"] } else { "queued" }
        if ($status -eq "running") {
            $runningTaskGroupWorkerCount++
        }

        $row = [ordered]@{
            worker_id = $resolvedWorkerId
            group_id = [string]$worker["group_id"]
            task_id = [string]$worker["task_id"]
            status = $status
            phase = $phase
            current_phase = $phase
        }
        foreach ($field in @("workspace_path", "lease_token", "result_summary", "created_at", "updated_at")) {
            Copy-TaskLaneFieldIfPresent -Source $worker -Target $row -FieldName $field
        }
        foreach ($field in @("declared_changed_files", "resource_locks")) {
            Copy-TaskLaneArrayFieldIfPresent -Source $worker -Target $row -FieldName $field
        }
        $taskGroupWorkerRows.Add($row) | Out-Null
    }

    $waitingTaskRows = New-Object System.Collections.Generic.List[object]
    $readyQueueRows = New-Object System.Collections.Generic.List[object]
    $readyCount = 0
    $runningCount = $activeJobRows.Count
    $blockedCount = 0
    $completedCount = 0
    $repairCount = 0

    foreach ($taskId in @($taskStates.Keys | Sort-Object)) {
        $task = ConvertTo-RelayHashtable -InputObject $taskStates[$taskId]
        if (-not $task) {
            $task = @{}
        }

        $status = [string]$task["status"]
        $kind = [string]$task["kind"]
        $activeJobId = [string]$task["active_job_id"]
        $waitReason = [string]$task["wait_reason"]
        $eligibility = if ($eligibilityByTaskId.ContainsKey([string]$taskId)) { ConvertTo-RelayHashtable -InputObject $eligibilityByTaskId[[string]$taskId] } else { $null }
        $eligibleForDispatch = if ($eligibility) { [bool]$eligibility["eligible"] } else { $true }
        $effectiveWaitReason = if ($eligibility -and -not [string]::IsNullOrWhiteSpace([string]$eligibility["wait_reason"])) { [string]$eligibility["wait_reason"] } else { $waitReason }

        if ($kind -eq "repair") {
            $repairCount++
        }
        switch ($status) {
            "ready" { $readyCount++ }
            "running" { if ([string]::IsNullOrWhiteSpace($activeJobId)) { $runningCount++ } }
            "blocked" { $blockedCount++ }
            "completed" { $completedCount++ }
        }

        if ($status -eq "ready" -and [string]::IsNullOrWhiteSpace($activeJobId) -and $eligibleForDispatch) {
            $readyRow = [ordered]@{
                task_id = [string]$taskId
                status = $status
            }
            foreach ($field in @("phase_cursor", "parallel_safety")) {
                Copy-TaskLaneFieldIfPresent -Source $task -Target $readyRow -FieldName $field
            }
            if ($eligibility) {
                Copy-TaskLaneFieldIfPresent -Source $eligibility -Target $readyRow -FieldName "parallel_safety"
            }
            if ($task.ContainsKey("resource_locks") -and $null -ne $task["resource_locks"]) {
                $readyRow["resource_locks"] = @(ConvertTo-TaskLaneStringArray -Value $task["resource_locks"])
            }
            if ($eligibility -and $eligibility.ContainsKey("resource_locks")) {
                $readyRow["resource_locks"] = @(ConvertTo-TaskLaneStringArray -Value $eligibility["resource_locks"])
            }
            $readyQueueRows.Add($readyRow) | Out-Null
        }

        $isWaiting = ($status -ne "completed" -and [string]::IsNullOrWhiteSpace($activeJobId))
        if ($isWaiting -and ($status -in @("ready", "blocked", "waiting", "running") -or -not [string]::IsNullOrWhiteSpace($effectiveWaitReason) -or ($eligibility -and -not $eligibleForDispatch))) {
            $row = [ordered]@{
                task_id = [string]$taskId
                status = $status
                wait_reason = $effectiveWaitReason
            }
            foreach ($field in @("blocked_by", "depends_on", "blocked_by_jobs", "blocked_by_tasks")) {
                if ($task.ContainsKey($field) -and $null -ne $task[$field]) {
                    $row[$field] = @(ConvertTo-TaskLaneStringArray -Value $task[$field])
                }
                if ($eligibility -and $eligibility.ContainsKey($field) -and $null -ne $eligibility[$field]) {
                    $row[$field] = @(ConvertTo-TaskLaneStringArray -Value $eligibility[$field])
                }
            }
            foreach ($field in @("parallel_safety", "stall_reason")) {
                Copy-TaskLaneFieldIfPresent -Source $task -Target $row -FieldName $field
                if ($eligibility) {
                    Copy-TaskLaneFieldIfPresent -Source $eligibility -Target $row -FieldName $field
                }
            }
            $waitingTaskRows.Add($row) | Out-Null
        }
    }

    $pendingApproval = ConvertTo-RelayHashtable -InputObject $state["pending_approval"]
    $approvalSummary = $null
    if ($pendingApproval) {
        $approvalSummary = [ordered]@{
            approval_id = [string]$pendingApproval["approval_id"]
            requested_phase = [string]$pendingApproval["requested_phase"]
            task_id = ""
            prompt_message = [string]$pendingApproval["prompt_message"]
        }
        $proposedAction = ConvertTo-RelayHashtable -InputObject $pendingApproval["proposed_action"]
        if ($proposedAction) {
            $approvalSummary["action_type"] = [string]$proposedAction["type"]
            $approvalSummary["task_id"] = [string]$proposedAction["task_id"]
            $approvalSummary["phase"] = [string]$proposedAction["phase"]
            $approvalSummary["role"] = [string]$proposedAction["role"]
        }
    }

    $maxParallelJobs = 1
    if ($taskLane.ContainsKey("max_parallel_jobs") -and $null -ne $taskLane["max_parallel_jobs"]) {
        [void][int]::TryParse([string]$taskLane["max_parallel_jobs"], [ref]$maxParallelJobs)
    }
    if ($maxParallelJobs -lt 1) {
        $maxParallelJobs = 1
    }

    $usedSlots = $activeJobRows.Count
    $capacityRemaining = [Math]::Max(0, $maxParallelJobs - $usedSlots)
    $capacityFull = ($capacityRemaining -le 0)
    $leaseCandidates = @(Resolve-TaskLaneLeaseCandidates -RunState $state -ProjectRoot $projectRoot -ReadyQueue @($readyQueueRows.ToArray()) -CapacityRemaining $capacityRemaining)
    $stallReason = Resolve-TaskLaneStallReason -Lane $taskLane -ActiveJobs @($activeJobRows.ToArray()) -ReadyQueue @($readyQueueRows.ToArray()) -WaitingTasks @($waitingTaskRows.ToArray()) -CapacityRemaining $capacityRemaining
    $launchDetailParams = @{
        TaskStates = $taskStates
        EligibilityByTaskId = $eligibilityByTaskId
        LeaseCandidateTaskIds = (New-TaskLaneLeaseCandidateSet -LeaseCandidates $leaseCandidates)
        CapacityRemaining = $capacityRemaining
        CurrentPhase = [string]$state["current_phase"]
        ActiveJobs = @($activeJobRows.ToArray())
    }
    Add-TaskLaneLaunchBlockDetails @launchDetailParams -Rows @($readyQueueRows.ToArray())
    Add-TaskLaneLaunchBlockDetails @launchDetailParams -Rows @($waitingTaskRows.ToArray())

    return [ordered]@{
        total_tasks = @($taskStates.Keys).Count
        ready_count = $readyCount
        running_count = $runningCount
        blocked_count = $blockedCount
        completed_count = $completedCount
        repair_count = $repairCount
        active_jobs = @($activeJobRows.ToArray())
        task_groups = @($taskGroupRows.ToArray())
        task_group_workers = @($taskGroupWorkerRows.ToArray())
        active_task_group_count = $activeTaskGroupCount
        running_task_group_count = $runningTaskGroupCount
        running_task_group_worker_count = $runningTaskGroupWorkerCount
        ready_queue = @($readyQueueRows.ToArray())
        waiting_tasks = @($waitingTaskRows.ToArray())
        stall_reason = $stallReason
        mode = if ($taskLane.ContainsKey("mode")) { [string]$taskLane["mode"] } else { "single" }
        max_parallel_jobs = $maxParallelJobs
        capacity_remaining = $capacityRemaining
        capacity_full = $capacityFull
        stop_leasing = if ($taskLane.ContainsKey("stop_leasing")) { ConvertTo-TaskLaneBoolean -Value $taskLane["stop_leasing"] } else { $false }
        used_slots = $usedSlots
        lease_candidates = @($leaseCandidates)
        pending_approval = $approvalSummary
        event_count = @($Events).Count
    }
}
