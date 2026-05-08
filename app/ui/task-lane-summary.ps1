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

    $waitingTaskRows = New-Object System.Collections.Generic.List[object]
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

        if ($kind -eq "repair") {
            $repairCount++
        }
        switch ($status) {
            "ready" { $readyCount++ }
            "running" { if ([string]::IsNullOrWhiteSpace($activeJobId)) { $runningCount++ } }
            "blocked" { $blockedCount++ }
            "completed" { $completedCount++ }
        }

        $isWaiting = ($status -ne "completed" -and [string]::IsNullOrWhiteSpace($activeJobId))
        if ($isWaiting -and ($status -in @("ready", "blocked", "waiting") -or -not [string]::IsNullOrWhiteSpace($waitReason))) {
            $row = [ordered]@{
                task_id = [string]$taskId
                status = $status
                wait_reason = $waitReason
            }
            foreach ($field in @("blocked_by", "depends_on")) {
                if ($task.ContainsKey($field) -and $null -ne $task[$field]) {
                    $row[$field] = @($task[$field])
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

    return [ordered]@{
        total_tasks = @($taskStates.Keys).Count
        ready_count = $readyCount
        running_count = $runningCount
        blocked_count = $blockedCount
        completed_count = $completedCount
        repair_count = $repairCount
        active_jobs = @($activeJobRows.ToArray())
        waiting_tasks = @($waitingTaskRows.ToArray())
        mode = if ($taskLane.ContainsKey("mode")) { [string]$taskLane["mode"] } else { "single" }
        max_parallel_jobs = $maxParallelJobs
        stop_leasing = if ($taskLane.ContainsKey("stop_leasing")) { ConvertTo-TaskLaneBoolean -Value $taskLane["stop_leasing"] } else { $false }
        used_slots = $activeJobRows.Count
        pending_approval = $approvalSummary
        event_count = @($Events).Count
    }
}
