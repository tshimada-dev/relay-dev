if (-not (Get-Command Resolve-PhaseRole -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "..\phases\phase-registry.ps1")
}
if (-not (Get-Command Normalize-ApprovalDecision -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "..\approval\approval-manager.ps1")
}
if (-not (Get-Command Resolve-Transition -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "transition-resolver.ps1")
}

function Test-TaskScopedPhase {
    param([Parameter(Mandatory)][string]$Phase)

    return $Phase -in @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
}

function New-TaskState {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [ValidateSet("not_started", "ready", "in_progress", "blocked", "completed", "abandoned")][string]$Status = "not_started",
        [ValidateSet("planned", "repair")][string]$Kind = "planned",
        [string]$LastCompletedPhase,
        [string[]]$DependsOn = @(),
        [Parameter(Mandatory)][string]$OriginPhase,
        [Parameter(Mandatory)]$TaskContractRef
    )

    return [ordered]@{
        task_id = $TaskId
        status = $Status
        kind = $Kind
        last_completed_phase = $LastCompletedPhase
        phase_cursor = $null
        active_job_id = $null
        wait_reason = $null
        depends_on = @($DependsOn)
        origin_phase = $OriginPhase
        task_contract_ref = (ConvertTo-RelayHashtable -InputObject $TaskContractRef)
    }
}

function Update-TaskReadiness {
    param([Parameter(Mandatory)]$RunState)

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $taskOrder = @($state["task_order"])
    foreach ($taskId in $taskOrder) {
        if (-not $state["task_states"].ContainsKey($taskId)) {
            continue
        }

        $taskState = $state["task_states"][$taskId]
        if ($taskState["status"] -in @("completed", "in_progress", "blocked", "abandoned")) {
            continue
        }

        $dependencies = @($taskState["depends_on"])
        $dependenciesSatisfied = $true
        foreach ($dependencyId in $dependencies) {
            if (-not $state["task_states"].ContainsKey($dependencyId) -or $state["task_states"][$dependencyId]["status"] -ne "completed") {
                $dependenciesSatisfied = $false
                break
            }
        }

        if ($dependenciesSatisfied) {
            $taskState["status"] = "ready"
        }
        else {
            $taskState["status"] = "not_started"
        }
    }

    return $state
}

function Register-PlannedTasks {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$TasksArtifact
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $tasksArtifactObject = ConvertTo-RelayHashtable -InputObject $TasksArtifact
    $tasks = @($tasksArtifactObject["tasks"])

    foreach ($task in $tasks) {
        $taskObject = ConvertTo-RelayHashtable -InputObject $task
        $taskId = [string]$taskObject["task_id"]
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            continue
        }

        if ($taskId -notin @($state["task_order"])) {
            $state["task_order"] = @($state["task_order"]) + $taskId
        }

        if (-not $state["task_states"].ContainsKey($taskId)) {
            $state["task_states"][$taskId] = New-TaskState -TaskId $taskId -Status "not_started" -Kind "planned" -DependsOn @($taskObject["dependencies"]) -OriginPhase "Phase4" -TaskContractRef @{
                phase = "Phase4"
                artifact_id = "phase4_tasks.json"
                item_id = $taskId
            }
        }
    }

    return (Update-TaskReadiness -RunState $state)
}

function Register-RepairTasksFromVerdict {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$VerdictArtifact,
        [string]$OriginPhase = "Phase7"
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $verdict = ConvertTo-RelayHashtable -InputObject $VerdictArtifact

    foreach ($followUpTask in @($verdict["follow_up_tasks"])) {
        $taskObject = ConvertTo-RelayHashtable -InputObject $followUpTask
        $taskId = [string]$taskObject["task_id"]
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            continue
        }

        if ($taskId -notin @($state["task_order"])) {
            $state["task_order"] = @($state["task_order"]) + $taskId
        }

        $taskContractRef = @{
            phase = $OriginPhase
            artifact_id = "phase7_verdict.json"
            item_id = $taskId
        }

        if (-not $state["task_states"].ContainsKey($taskId)) {
            $state["task_states"][$taskId] = New-TaskState -TaskId $taskId -Status "ready" -Kind "repair" -DependsOn @($taskObject["depends_on"]) -OriginPhase $OriginPhase -TaskContractRef $taskContractRef
            continue
        }

        $existingTaskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
        $existingTaskState["kind"] = "repair"
        $existingTaskState["depends_on"] = @($taskObject["depends_on"])
        $existingTaskState["origin_phase"] = $OriginPhase
        $existingTaskState["task_contract_ref"] = $taskContractRef
        $state["task_states"][$taskId] = $existingTaskState
    }

    return (Update-TaskReadiness -RunState $state)
}

function Resolve-TaskContract {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$TaskId
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    if (-not $state["task_states"].ContainsKey($TaskId)) {
        return $null
    }

    $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$TaskId]
    $taskContractRef = ConvertTo-RelayHashtable -InputObject $taskState["task_contract_ref"]
    if (-not $taskContractRef) {
        return $null
    }

    $artifact = Read-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -ArtifactRef @{
        scope = "run"
        phase = $taskContractRef["phase"]
        artifact_id = $taskContractRef["artifact_id"]
    }
    if (-not $artifact) {
        return $null
    }

    $artifactSnapshot = ConvertTo-RelayHashtable -InputObject (Get-ArtifactValidationSnapshot -ArtifactId ([string]$taskContractRef["artifact_id"]) -Artifact $artifact -Phase ([string]$taskContractRef["phase"]))
    $artifact = $artifactSnapshot["artifact"]
    if (-not ($artifact -is [System.Collections.IDictionary])) {
        return $null
    }

    switch ([string]$taskState["kind"]) {
        "repair" {
            foreach ($item in @($artifact["follow_up_tasks"])) {
                $taskObject = ConvertTo-RelayHashtable -InputObject $item
                if ([string]$taskObject["task_id"] -eq $taskContractRef["item_id"]) {
                    return $taskObject
                }
            }
        }
        default {
            foreach ($item in @($artifact["tasks"])) {
                $taskObject = ConvertTo-RelayHashtable -InputObject $item
                if ([string]$taskObject["task_id"] -eq $taskContractRef["item_id"]) {
                    return $taskObject
                }
            }
        }
    }

    return $null
}

function Get-TaskContractResourceLocks {
    param([AllowNull()]$TaskContract)

    $task = ConvertTo-RelayHashtable -InputObject $TaskContract
    if (-not ($task -is [System.Collections.IDictionary]) -or -not $task.ContainsKey("resource_locks")) {
        return @()
    }

    $locks = New-Object System.Collections.Generic.List[string]
    foreach ($lockId in @($task["resource_locks"])) {
        $normalizedLockId = [string]$lockId
        if (-not [string]::IsNullOrWhiteSpace($normalizedLockId) -and $normalizedLockId -notin @($locks.ToArray())) {
            $locks.Add($normalizedLockId)
        }
    }

    return @($locks.ToArray())
}

function Get-TaskContractParallelSafety {
    param([AllowNull()]$TaskContract)

    $task = ConvertTo-RelayHashtable -InputObject $TaskContract
    if (-not ($task -is [System.Collections.IDictionary]) -or [string]::IsNullOrWhiteSpace([string]$task["parallel_safety"])) {
        return "cautious"
    }

    $safety = ([string]$task["parallel_safety"]).Trim().ToLowerInvariant()
    if ($safety -in @("serial", "cautious", "parallel")) {
        return $safety
    }

    return "cautious"
}

function Get-ActiveTaskSchedulerConstraints {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $runId = [string]$state["run_id"]
    $active = New-Object System.Collections.Generic.List[object]

    foreach ($jobId in @(Get-RunStateActiveJobIds -RunState $state)) {
        $lease = $null
        if ($state["active_jobs"].ContainsKey($jobId)) {
            $lease = ConvertTo-RelayHashtable -InputObject $state["active_jobs"][$jobId]
        }
        else {
            $lease = @{ job_id = $jobId; task_id = $null }
        }

        $taskId = [string]$lease["task_id"]
        $contract = $null
        if (-not [string]::IsNullOrWhiteSpace($taskId)) {
            $contract = Resolve-TaskContract -ProjectRoot $ProjectRoot -RunId $runId -RunState $state -TaskId $taskId
        }

        $locks = if ($lease.ContainsKey("resource_locks")) { @($lease["resource_locks"]) } else { @(Get-TaskContractResourceLocks -TaskContract $contract) }
        $parallelSafety = if (-not [string]::IsNullOrWhiteSpace([string]$lease["parallel_safety"])) { [string]$lease["parallel_safety"] } else { Get-TaskContractParallelSafety -TaskContract $contract }

        $active.Add([ordered]@{
            job_id = $jobId
            task_id = if ([string]::IsNullOrWhiteSpace($taskId)) { $null } else { $taskId }
            resource_locks = @($locks)
            parallel_safety = $parallelSafety
            slot_id = if ([string]::IsNullOrWhiteSpace([string]$lease["slot_id"])) { $null } else { [string]$lease["slot_id"] }
        })
    }

    return @($active.ToArray())
}

function Test-TaskDispatchEligibility {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$TaskId
    )

    $state = Update-TaskReadiness -RunState $RunState
    $runId = [string]$state["run_id"]
    $taskState = if ($state["task_states"].ContainsKey($TaskId)) { ConvertTo-RelayHashtable -InputObject $state["task_states"][$TaskId] } else { $null }
    $contract = if ($taskState) { Resolve-TaskContract -ProjectRoot $ProjectRoot -RunId $runId -RunState $state -TaskId $TaskId } else { $null }
    $resourceLocks = @(Get-TaskContractResourceLocks -TaskContract $contract)
    $parallelSafety = Get-TaskContractParallelSafety -TaskContract $contract
    if ($resourceLocks.Count -eq 0 -and $taskState -and $taskState.ContainsKey("resource_locks")) {
        $resourceLocks = @(Get-TaskContractResourceLocks -TaskContract $taskState)
    }
    if ($taskState -and $taskState.ContainsKey("parallel_safety") -and -not [string]::IsNullOrWhiteSpace([string]$taskState["parallel_safety"])) {
        $taskStateSafety = ([string]$taskState["parallel_safety"]).Trim().ToLowerInvariant()
        if ($taskStateSafety -in @("serial", "cautious", "parallel")) {
            $parallelSafety = $taskStateSafety
        }
    }

    $result = [ordered]@{
        task_id = $TaskId
        eligible = $true
        wait_reason = $null
        blocked_by = @()
        blocked_by_jobs = @()
        blocked_by_tasks = @()
        resource_locks = $resourceLocks
        parallel_safety = $parallelSafety
    }

    if (-not $taskState) {
        $result["eligible"] = $false
        $result["wait_reason"] = "unknown_task"
        return $result
    }

    $unmetDependencies = New-Object System.Collections.Generic.List[string]
    foreach ($dependencyId in @($taskState["depends_on"])) {
        $dependencyKey = [string]$dependencyId
        if ([string]::IsNullOrWhiteSpace($dependencyKey)) {
            continue
        }
        if (-not $state["task_states"].ContainsKey($dependencyKey) -or [string]$state["task_states"][$dependencyKey]["status"] -ne "completed") {
            $unmetDependencies.Add($dependencyKey)
        }
    }
    if ($unmetDependencies.Count -gt 0) {
        $result["eligible"] = $false
        $result["wait_reason"] = "dependencies"
        $result["blocked_by"] = @($unmetDependencies.ToArray())
        return $result
    }

    if ([string]$taskState["status"] -ne "ready") {
        $result["eligible"] = $false
        $result["wait_reason"] = [string]$taskState["status"]
        return $result
    }

    $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
    if ($taskLane -and [bool]$taskLane["stop_leasing"]) {
        $result["eligible"] = $false
        $result["wait_reason"] = "stop_leasing"
        return $result
    }

    $active = @(Get-ActiveTaskSchedulerConstraints -RunState $state -ProjectRoot $ProjectRoot)
    $activeJobIds = @($active | ForEach-Object { [string]$_["job_id"] } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $activeSerial = @($active | Where-Object { [string]$_["parallel_safety"] -eq "serial" })
    if ($parallelSafety -eq "serial" -and $activeJobIds.Count -gt 0) {
        $result["eligible"] = $false
        $result["wait_reason"] = "serial_safety"
        $result["blocked_by_jobs"] = $activeJobIds
        return $result
    }
    if ($activeSerial.Count -gt 0) {
        $result["eligible"] = $false
        $result["wait_reason"] = "serial_safety"
        $result["blocked_by_jobs"] = @($activeSerial | ForEach-Object { [string]$_["job_id"] })
        $result["blocked_by_tasks"] = @($activeSerial | ForEach-Object { [string]$_["task_id"] } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        return $result
    }

    $blockingLocks = New-Object System.Collections.Generic.List[string]
    $blockingJobs = New-Object System.Collections.Generic.List[string]
    $blockingTasks = New-Object System.Collections.Generic.List[string]
    foreach ($activeJob in $active) {
        foreach ($lockId in @($activeJob["resource_locks"])) {
            $normalizedLockId = [string]$lockId
            if ($normalizedLockId -in $resourceLocks) {
                if ($normalizedLockId -notin @($blockingLocks.ToArray())) { $blockingLocks.Add($normalizedLockId) }
                if ([string]$activeJob["job_id"] -notin @($blockingJobs.ToArray())) { $blockingJobs.Add([string]$activeJob["job_id"]) }
                if (-not [string]::IsNullOrWhiteSpace([string]$activeJob["task_id"]) -and [string]$activeJob["task_id"] -notin @($blockingTasks.ToArray())) { $blockingTasks.Add([string]$activeJob["task_id"]) }
            }
        }
    }
    if ($blockingLocks.Count -gt 0) {
        $result["eligible"] = $false
        $result["wait_reason"] = "resource_lock"
        $result["blocked_by"] = @($blockingLocks.ToArray())
        $result["blocked_by_jobs"] = @($blockingJobs.ToArray())
        $result["blocked_by_tasks"] = @($blockingTasks.ToArray())
    }

    return $result
}

function Get-TaskDispatchEligibility {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = Update-TaskReadiness -RunState $RunState
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($taskId in @($state["task_order"])) {
        if ([string]::IsNullOrWhiteSpace([string]$taskId)) {
            continue
        }
        $items.Add((Test-TaskDispatchEligibility -RunState $state -ProjectRoot $ProjectRoot -TaskId ([string]$taskId)))
    }

    return @($items.ToArray())
}

function Get-BatchLeaseCandidates {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = Update-TaskReadiness -RunState $RunState
    $runId = [string]$state["run_id"]
    $phase = [string]$state["current_phase"]
    if (-not (Test-TaskScopedPhase -Phase $phase)) {
        return @()
    }

    $taskLane = ConvertTo-RelayHashtable -InputObject $state["task_lane"]
    $maxParallelJobs = 1
    if ($taskLane -and $taskLane.ContainsKey("max_parallel_jobs")) {
        [void][int]::TryParse([string]$taskLane["max_parallel_jobs"], [ref]$maxParallelJobs)
    }
    if ($maxParallelJobs -lt 1) {
        $maxParallelJobs = 1
    }

    $activeJobIds = @(Get-RunStateActiveJobIds -RunState $state)
    $capacityRemaining = $maxParallelJobs - $activeJobIds.Count
    if ($capacityRemaining -le 0) {
        return @()
    }

    $role = Resolve-PhaseRole -Phase $phase
    $active = @(Get-ActiveTaskSchedulerConstraints -RunState $state -ProjectRoot $ProjectRoot)
    $activeTaskIds = @($active | ForEach-Object { [string]$_["task_id"] } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $selected = New-Object System.Collections.Generic.List[object]
    $selectedLocks = New-Object System.Collections.Generic.List[string]
    $selectedTaskIds = New-Object System.Collections.Generic.List[string]
    $reservedSlots = @{}
    foreach ($activeJob in $active) {
        $slotId = [string]$activeJob["slot_id"]
        if (-not [string]::IsNullOrWhiteSpace($slotId)) {
            $reservedSlots[$slotId] = $true
            if ($slotId -match "^slot-0*(\d+)$") {
                $reservedSlots[("slot-{0:d2}" -f [int]$Matches[1])] = $true
            }
        }
    }

    foreach ($taskIdRaw in @($state["task_order"])) {
        if ($selected.Count -ge $capacityRemaining) {
            break
        }

        $taskId = [string]$taskIdRaw
        if ([string]::IsNullOrWhiteSpace($taskId) -or $taskId -in $activeTaskIds -or $taskId -in @($selectedTaskIds.ToArray())) {
            continue
        }

        $eligibility = Test-TaskDispatchEligibility -RunState $state -ProjectRoot $ProjectRoot -TaskId $taskId
        if (-not [bool]$eligibility["eligible"]) {
            continue
        }

        $resourceLocks = @($eligibility["resource_locks"])
        $parallelSafety = [string]$eligibility["parallel_safety"]
        if ($parallelSafety -eq "serial" -and ($activeJobIds.Count -gt 0 -or $selected.Count -gt 0)) {
            continue
        }
        if (@($selected | Where-Object { [string]$_["parallel_safety"] -eq "serial" }).Count -gt 0) {
            break
        }

        $hasSelectedLockConflict = $false
        foreach ($lockId in $resourceLocks) {
            if ([string]$lockId -in @($selectedLocks.ToArray())) {
                $hasSelectedLockConflict = $true
                break
            }
        }
        if ($hasSelectedLockConflict) {
            continue
        }

        $slotOrdinal = 1
        $slotId = $null
        while ($null -eq $slotId) {
            $candidateSlot = "slot-{0:d2}" -f $slotOrdinal
            if (-not $reservedSlots.ContainsKey($candidateSlot)) {
                $slotId = $candidateSlot
                $reservedSlots[$slotId] = $true
            }
            $slotOrdinal++
        }

        $contract = Resolve-TaskContract -ProjectRoot $ProjectRoot -RunId $runId -RunState $state -TaskId $taskId
        foreach ($lockId in $resourceLocks) {
            if ([string]$lockId -notin @($selectedLocks.ToArray())) {
                $selectedLocks.Add([string]$lockId)
            }
        }
        $selectedTaskIds.Add($taskId)
        $selected.Add([ordered]@{
            task_id = $taskId
            phase = $phase
            role = $role
            selected_task = $contract
            resource_locks = @($resourceLocks)
            parallel_safety = $parallelSafety
            slot_id = $slotId
        })
    }

    return @($selected.ToArray())
}

function Resolve-NextReadyTaskId {
    param(
        [Parameter(Mandatory)]$RunState,
        [string]$ExcludeTaskId
    )

    $state = Update-TaskReadiness -RunState $RunState
    foreach ($taskId in @($state["task_order"])) {
        if ($ExcludeTaskId -and $taskId -eq $ExcludeTaskId) {
            continue
        }

        if (-not $state["task_states"].ContainsKey($taskId)) {
            continue
        }

        $taskState = $state["task_states"][$taskId]
        if ($taskState["status"] -eq "ready") {
            return $taskId
        }
    }

    return $null
}

function Merge-OpenRequirements {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$OpenRequirements
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $merged = New-Object System.Collections.Generic.List[object]
    $indexes = @{}

    foreach ($requirementRaw in @($state["open_requirements"])) {
        $requirement = ConvertTo-RelayHashtable -InputObject $requirementRaw
        if (-not ($requirement -is [System.Collections.IDictionary])) {
            continue
        }

        $itemId = [string]$requirement["item_id"]
        if ([string]::IsNullOrWhiteSpace($itemId) -or $indexes.ContainsKey($itemId)) {
            continue
        }

        $indexes[$itemId] = $merged.Count
        $merged.Add($requirement)
    }

    foreach ($requirementRaw in @($OpenRequirements)) {
        $requirement = ConvertTo-RelayHashtable -InputObject $requirementRaw
        if (-not ($requirement -is [System.Collections.IDictionary])) {
            continue
        }

        $itemId = [string]$requirement["item_id"]
        if ([string]::IsNullOrWhiteSpace($itemId)) {
            continue
        }

        if ($indexes.ContainsKey($itemId)) {
            $merged[[int]$indexes[$itemId]] = $requirement
        }
        else {
            $indexes[$itemId] = $merged.Count
            $merged.Add($requirement)
        }
    }

    $state["open_requirements"] = @($merged.ToArray())
    return $state
}

function Resolve-OpenRequirements {
    param(
        [Parameter(Mandatory)]$RunState,
        [string[]]$ResolvedRequirementIds = @()
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    if (@($ResolvedRequirementIds).Count -eq 0) {
        return $state
    }

    $resolved = @{}
    foreach ($itemId in @($ResolvedRequirementIds)) {
        $normalizedId = [string]$itemId
        if (-not [string]::IsNullOrWhiteSpace($normalizedId)) {
            $resolved[$normalizedId] = $true
        }
    }

    if ($resolved.Count -eq 0) {
        return $state
    }

    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($requirementRaw in @($state["open_requirements"])) {
        $requirement = ConvertTo-RelayHashtable -InputObject $requirementRaw
        if (-not ($requirement -is [System.Collections.IDictionary])) {
            continue
        }

        $itemId = [string]$requirement["item_id"]
        if ([string]::IsNullOrWhiteSpace($itemId) -or -not $resolved.ContainsKey($itemId)) {
            $remaining.Add($requirement)
        }
    }

    $state["open_requirements"] = @($remaining.ToArray())
    return $state
}

function Apply-ArtifactOpenRequirementDelta {
    param(
        [Parameter(Mandatory)]$RunState,
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $artifactObject = ConvertTo-RelayHashtable -InputObject $Artifact
    if (-not $artifactObject) {
        return $state
    }

    if ($artifactObject.ContainsKey("resolved_requirement_ids")) {
        $state = Resolve-OpenRequirements -RunState $state -ResolvedRequirementIds @($artifactObject["resolved_requirement_ids"])
    }

    if (-not $artifactObject.ContainsKey("open_requirements")) {
        return $state
    }

    $normalizedRequirements = New-Object System.Collections.Generic.List[object]
    foreach ($requirementRaw in @($artifactObject["open_requirements"])) {
        $requirement = ConvertTo-RelayHashtable -InputObject $requirementRaw
        if (-not ($requirement -is [System.Collections.IDictionary])) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$requirement["source_phase"])) {
            $requirement["source_phase"] = $Phase
        }
        if ($TaskId -and [string]::IsNullOrWhiteSpace([string]$requirement["source_task_id"])) {
            $requirement["source_task_id"] = $TaskId
        }

        $normalizedRequirements.Add($requirement)
    }

    if ($normalizedRequirements.Count -gt 0) {
        $state = Merge-OpenRequirements -RunState $state -OpenRequirements $normalizedRequirements.ToArray()
    }

    return $state
}

function Test-RelayPlaceholderText {
    param([AllowNull()]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $true
    }

    $normalized = $text.Trim().ToLowerInvariant()
    return $normalized -in @(
        "none",
        "n/a",
        "na",
        "null",
        "nil",
        "なし",
        "なし。",
        "特になし",
        "特になし。"
    )
}

function Convert-RelayArtifactEntryToDisplayText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $normalizedValue = ConvertTo-RelayHashtable -InputObject $Value
    if ($normalizedValue -is [string]) {
        return $normalizedValue.Trim()
    }

    if ($normalizedValue -is [System.Collections.IDictionary]) {
        foreach ($preferredKey in @("question", "description", "summary", "title", "name")) {
            $preferredValue = [string]$normalizedValue[$preferredKey]
            if (-not (Test-RelayPlaceholderText -Value $preferredValue)) {
                return $preferredValue.Trim()
            }
        }

        $segments = New-Object System.Collections.Generic.List[string]
        foreach ($entryKey in $normalizedValue.Keys) {
            $entryValue = [string]$normalizedValue[$entryKey]
            if (Test-RelayPlaceholderText -Value $entryValue) {
                continue
            }

            $segments.Add(("{0}: {1}" -f [string]$entryKey, $entryValue.Trim()))
        }

        if ($segments.Count -gt 0) {
            return ($segments -join "; ")
        }

        return ""
    }

    return ([string]$Value).Trim()
}

function Get-ArtifactFieldMeaningfulEntries {
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][string]$FieldName
    )

    $artifactObject = ConvertTo-RelayHashtable -InputObject $Artifact
    if (-not $artifactObject -or -not $artifactObject.ContainsKey($FieldName)) {
        return @()
    }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($artifactObject[$FieldName])) {
        if ($null -eq $entry) {
            continue
        }

        $displayText = Convert-RelayArtifactEntryToDisplayText -Value $entry
        if (Test-RelayPlaceholderText -Value $displayText) {
            continue
        }

        $entries.Add($displayText)
    }

    return @($entries.ToArray())
}

function Test-ArtifactFieldHasMeaningfulEntries {
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][string]$FieldName
    )

    return (@(Get-ArtifactFieldMeaningfulEntries -Artifact $Artifact -FieldName $FieldName).Count -gt 0)
}

function Convert-ApprovalEntriesToOpenRequirements {
    param(
        [AllowNull()]$Entries,
        [Parameter(Mandatory)][string]$SourcePhase,
        [string]$SourceTaskId,
        [Parameter(Mandatory)][string]$VerifyInPhase,
        [string]$ItemIdPrefix = "carry"
    )

    $normalizedRequirements = New-Object System.Collections.Generic.List[object]
    $nextIndex = 1

    foreach ($entryRaw in @($Entries)) {
        if ($null -eq $entryRaw) {
            continue
        }

        $entryObject = ConvertTo-RelayHashtable -InputObject $entryRaw
        $requirement = [ordered]@{}
        if ($entryObject -is [System.Collections.IDictionary]) {
            foreach ($entryKey in $entryObject.Keys) {
                $requirement[[string]$entryKey] = $entryObject[$entryKey]
            }
        }

        $description = Convert-RelayArtifactEntryToDisplayText -Value $entryRaw
        if (Test-RelayPlaceholderText -Value $description) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$requirement["item_id"])) {
            $requirement["item_id"] = "{0}-{1:d2}" -f $ItemIdPrefix, $nextIndex
        }

        $requirement["description"] = $description
        if ([string]::IsNullOrWhiteSpace([string]$requirement["source_phase"])) {
            $requirement["source_phase"] = $SourcePhase
        }
        if (-not (@($requirement.Keys) -contains "source_task_id") -or [string]::IsNullOrWhiteSpace([string]$requirement["source_task_id"])) {
            $requirement["source_task_id"] = $SourceTaskId
        }
        if ([string]::IsNullOrWhiteSpace([string]$requirement["verify_in_phase"])) {
            $requirement["verify_in_phase"] = $VerifyInPhase
        }
        if (-not (@($requirement.Keys) -contains "required_artifacts") -or $null -eq $requirement["required_artifacts"]) {
            $requirement["required_artifacts"] = @()
        }
        else {
            $requirement["required_artifacts"] = @($requirement["required_artifacts"])
        }

        $normalizedRequirements.Add($requirement)
        $nextIndex++
    }

    return @($normalizedRequirements.ToArray())
}

function Set-RunStateCursor {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $state["current_phase"] = $Phase
    $state["current_role"] = Resolve-PhaseRole -Phase $Phase
    if (Test-TaskScopedPhase -Phase $Phase) {
        $state["current_task_id"] = $TaskId
        if (-not [string]::IsNullOrWhiteSpace($TaskId) -and $state["task_states"] -and $state["task_states"].ContainsKey($TaskId)) {
            $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$TaskId]
            $taskState["phase_cursor"] = $Phase
            if ([string]$taskState["status"] -notin @("completed", "blocked", "abandoned")) {
                $taskState["status"] = "in_progress"
            }
            $state["task_states"][$TaskId] = $taskState
        }
    }
    else {
        $state["current_task_id"] = $null
    }
    $state["updated_at"] = (Get-Date).ToString("o")
    return $state
}

function Repair-StaleActiveJobState {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $activeJobIds = @(Get-RunStateActiveJobIds -RunState $state)
    if ($activeJobIds.Count -eq 0) {
        return @{
            changed = $false
            run_state = $state
            reason = $null
            job_metadata = $null
            recovered_jobs = @()
        }
    }

    if (-not (Get-Command Read-JobMetadata -ErrorAction SilentlyContinue)) {
        return @{
            changed = $false
            run_state = $state
            reason = $null
            job_metadata = $null
            recovered_jobs = @()
        }
    }

    $recoveredJobs = New-Object System.Collections.Generic.List[object]
    $firstObservedMetadata = $null
    $now = Get-Date
    foreach ($activeJobIdRaw in $activeJobIds) {
        $activeJobId = [string]$activeJobIdRaw
        if ([string]::IsNullOrWhiteSpace($activeJobId)) {
            continue
        }

        $activeLease = $null
        $activeLeaseHasFreshHeartbeat = $false
        if ($state["active_jobs"].ContainsKey($activeJobId)) {
            $activeLease = ConvertTo-RelayHashtable -InputObject $state["active_jobs"][$activeJobId]
            $lastHeartbeatAt = [datetime]::MinValue
            $leaseExpiresAt = [datetime]::MinValue
            if (
                [datetime]::TryParse([string]$activeLease["last_heartbeat_at"], [ref]$lastHeartbeatAt) -and
                [datetime]::TryParse([string]$activeLease["lease_expires_at"], [ref]$leaseExpiresAt) -and
                $lastHeartbeatAt -le $now -and
                $leaseExpiresAt -gt $now
            ) {
                $activeLeaseHasFreshHeartbeat = $true
            }
        }

        $jobMetadata = Read-JobMetadata -ProjectRoot $ProjectRoot -RunId ([string]$state["run_id"]) -JobId $activeJobId
        $jobMetadataObject = $null
        $shouldClear = $false
        $reason = $null

        if (-not $jobMetadata) {
            $shouldClear = $true
            $reason = "missing_job_metadata"
        }
        else {
            $jobMetadataObject = ConvertTo-RelayHashtable -InputObject $jobMetadata
            if (-not $firstObservedMetadata) {
                $firstObservedMetadata = $jobMetadataObject
            }

            $jobStatus = [string]$jobMetadataObject["status"]
            $jobProcessId = 0
            $hasPid = [int]::TryParse([string]$jobMetadataObject["pid"], [ref]$jobProcessId)
            $processAlive = $false
            if ($hasPid -and $jobProcessId -gt 0) {
                try {
                    $null = Get-Process -Id $jobProcessId -ErrorAction Stop
                    $processAlive = $true
                }
                catch {
                    $processAlive = $false
                }
            }

            if ($jobStatus -eq "finished") {
                $shouldClear = $true
                $reason = "finished_job_not_committed"
            }
            elseif (($jobStatus -eq "dispatched" -or $jobStatus -eq "running") -and -not $hasPid) {
                $shouldClear = $true
                $reason = "job_missing_pid"
            }
            elseif ($hasPid -and -not $processAlive) {
                $shouldClear = $true
                $reason = "stale_active_job"
            }
        }

        if ($shouldClear -and $activeLeaseHasFreshHeartbeat -and $reason -in @("missing_job_metadata", "job_missing_pid", "stale_active_job")) {
            continue
        }

        if (-not $shouldClear) {
            continue
        }

        $state = Clear-RunStateActiveJobLease -RunState $state -JobId $activeJobId
        $recoveredJobs.Add([ordered]@{
            job_id = $activeJobId
            reason = $reason
            job_metadata = $jobMetadataObject
        }) | Out-Null
    }

    if ($recoveredJobs.Count -eq 0) {
        return @{
            changed = $false
            run_state = $state
            reason = $null
            job_metadata = $firstObservedMetadata
            recovered_jobs = @()
        }
    }

    $state["status"] = "running"
    $state["updated_at"] = (Get-Date).ToString("o")
    $firstRecoveredJob = ConvertTo-RelayHashtable -InputObject $recoveredJobs[0]
    return @{
        changed = $true
        run_state = $state
        reason = [string]$firstRecoveredJob["reason"]
        job_metadata = (ConvertTo-RelayHashtable -InputObject $firstRecoveredJob["job_metadata"])
        recovered_jobs = @($recoveredJobs.ToArray())
    }
}

function Get-NextAction {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = Update-TaskReadiness -RunState $RunState
    $runId = [string]$state["run_id"]

    switch ([string]$state["status"]) {
        "completed" {
            return [ordered]@{
                type = "CompleteRun"
                run_id = $runId
            }
        }
        "failed" {
            return [ordered]@{
                type = "FailRun"
                run_id = $runId
            }
        }
        "blocked" {
            return [ordered]@{
                type = "Wait"
                reason = "manual_intervention_required"
                run_id = $runId
            }
        }
        "waiting_approval" {
            return [ordered]@{
                type = "RequestApproval"
                run_id = $runId
                pending_approval = $state["pending_approval"]
            }
        }
    }

    if ($state["pending_approval"]) {
        return [ordered]@{
            type = "RequestApproval"
            run_id = $runId
            pending_approval = $state["pending_approval"]
        }
    }

    $activeJobIds = @(Get-RunStateActiveJobIds -RunState $state)
    if ($activeJobIds.Count -gt 0) {
        return [ordered]@{
            type = "Wait"
            reason = "job_in_progress"
            run_id = $runId
            job_id = $activeJobIds[0]
            active_job_ids = $activeJobIds
        }
    }

    $phase = [string]$state["current_phase"]
    $role = Resolve-PhaseRole -Phase $phase
    $taskId = [string]$state["current_task_id"]
    $selectedTask = $null

    if (Test-TaskScopedPhase -Phase $phase) {
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            $taskId = Resolve-NextReadyTaskId -RunState $state
            if ([string]::IsNullOrWhiteSpace($taskId)) {
                return [ordered]@{
                    type = "Wait"
                    reason = "no_ready_tasks"
                    run_id = $runId
                }
            }
        }

        $selectedTask = Resolve-TaskContract -ProjectRoot $ProjectRoot -RunId $runId -RunState $state -TaskId $taskId
    }

    $dispatchTaskId = $null
    if (Test-TaskScopedPhase -Phase $phase) {
        $dispatchTaskId = $taskId
    }

    return [ordered]@{
        type = "DispatchJob"
        run_id = $runId
        phase = $phase
        role = $role
        task_id = $dispatchTaskId
        selected_task = $selectedTask
    }
}

function Resolve-ApprovalAllowedRejectPhases {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Phase
    )

    $phaseDefinition = Get-PhaseDefinition -ProjectRoot $ProjectRoot -Phase $Phase
    $definition = ConvertTo-RelayHashtable -InputObject $phaseDefinition
    $transitionRules = if ($definition["transition_rules"]) {
        ConvertTo-RelayHashtable -InputObject $definition["transition_rules"]
    }
    else {
        @{}
    }

    $rejectRule = $transitionRules["reject"]
    if ($null -eq $rejectRule) {
        return @()
    }

    if ($rejectRule -is [System.Collections.IEnumerable] -and -not ($rejectRule -is [string])) {
        return @(
            @($rejectRule) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        )
    }

    $singleTarget = [string]$rejectRule
    if ([string]::IsNullOrWhiteSpace($singleTarget)) {
        return @()
    }

    return @($singleTarget)
}

function Apply-JobResult {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$JobResult,
        [AllowNull()]$ValidationResult,
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string[]]$ApprovalPhases = @()
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $job = ConvertTo-RelayHashtable -InputObject $JobResult
    $validation = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $artifactObject = ConvertTo-RelayHashtable -InputObject $Artifact

    $jobId = [string]$job["job_id"]
    $state = Clear-RunStateActiveJobLease -RunState $state -JobId $jobId
    $state["updated_at"] = (Get-Date).ToString("o")

    if ([string]$job["result_status"] -ne "succeeded" -or [int]$job["exit_code"] -ne 0) {
        $state["status"] = "failed"
        return [ordered]@{
            run_state = $state
            action = @{
                type = "FailRun"
                reason = "job_failed"
                failure_class = $job["failure_class"]
            }
            spawned_tasks = @()
        }
    }

    if ($validation -and -not [bool]$validation["valid"]) {
        $state["status"] = "failed"
        return [ordered]@{
            run_state = $state
            action = @{
                type = "FailRun"
                reason = "invalid_artifact"
                errors = @($validation["errors"])
            }
            spawned_tasks = @()
        }
    }

    $phase = if ($job["phase"]) { [string]$job["phase"] } else { [string]$state["current_phase"] }
    $taskId = if ($job["task_id"]) { [string]$job["task_id"] } else { [string]$state["current_task_id"] }
    $spawnedTasks = @()

    $state = Apply-ArtifactOpenRequirementDelta -RunState $state -Artifact $artifactObject -Phase $phase -TaskId $taskId

    if ($taskId -and $state["task_states"].ContainsKey($taskId)) {
        $taskState = $state["task_states"][$taskId]
        $taskState["last_completed_phase"] = $phase
        $taskState["active_job_id"] = $null
        $taskState["wait_reason"] = $null
        if ($phase -eq "Phase6") {
            $taskState["status"] = "completed"
        }
        else {
            $taskState["status"] = "in_progress"
            $nextTaskPhase = $null
            switch ($phase) {
                "Phase5" { $nextTaskPhase = "Phase5-1" }
                "Phase5-1" { $nextTaskPhase = "Phase5-2" }
                "Phase5-2" { $nextTaskPhase = "Phase6" }
            }
            if ($nextTaskPhase) {
                $taskState["phase_cursor"] = $nextTaskPhase
            }
        }
    }

    if ($phase -eq "Phase4" -and $artifactObject) {
        $state = Register-PlannedTasks -RunState $state -TasksArtifact $artifactObject
    }

    if ($phase -eq "Phase7" -and $artifactObject -and [string]$artifactObject["verdict"] -eq "conditional_go") {
        $state = Register-RepairTasksFromVerdict -RunState $state -VerdictArtifact $artifactObject -OriginPhase "Phase7"
        $spawnedTasks = @($artifactObject["follow_up_tasks"])
    }

    if ($phase -eq "Phase8") {
        $state["status"] = "completed"
        $state["current_phase"] = "Phase8"
        $state["current_role"] = Resolve-PhaseRole -Phase "Phase8"
        $state["current_task_id"] = $null
        return [ordered]@{
            run_state = $state
            action = @{
                type = "CompleteRun"
            }
            spawned_tasks = $spawnedTasks
        }
    }

    $verdict = "go"
    if ($artifactObject -and $artifactObject.ContainsKey("verdict")) {
        $verdict = [string]$artifactObject["verdict"]
    }

    if ($phase -eq "Phase7" -and $verdict -eq "go" -and @($state["open_requirements"]).Count -gt 0) {
        $remainingRequirementIds = @(
            @($state["open_requirements"]) |
                ForEach-Object {
                    $requirement = ConvertTo-RelayHashtable -InputObject $_
                    [string]$requirement["item_id"]
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        )
        $state["status"] = "failed"
        return [ordered]@{
            run_state = $state
            action = @{
                type = "FailRun"
                reason = "unresolved_open_requirements"
                open_requirement_ids = $remainingRequirementIds
            }
            spawned_tasks = $spawnedTasks
        }
    }

    $rollbackPhase = $null
    if ($artifactObject) {
        $rollbackPhase = [string]$artifactObject["rollback_phase"]
    }

    $transition = Resolve-Transition -ProjectRoot $ProjectRoot -CurrentPhase $phase -Verdict $verdict -RollbackPhase $rollbackPhase
    if (-not [bool]$transition["valid"]) {
        $state["status"] = "failed"
        return [ordered]@{
            run_state = $state
            action = @{
                type = "FailRun"
                reason = "invalid_transition"
                error = $transition["error"]
            }
            spawned_tasks = $spawnedTasks
        }
    }

    $nextPhase = [string]$transition["next_phase"]
    $nextTaskId = $null
    if ($phase -eq "Phase1" -and $verdict -eq "go") {
        $needsClarificationFallback = Test-ArtifactFieldHasMeaningfulEntries -Artifact $artifactObject -FieldName "unresolved_questions"
        $nextPhase = if ($needsClarificationFallback) { "Phase2" } else { "Phase3" }
    }

    if ($phase -eq "Phase6" -and $verdict -in @("go", "conditional_go")) {
        $nextTaskId = Resolve-NextReadyTaskId -RunState $state -ExcludeTaskId $taskId
        if ($nextTaskId) {
            $nextPhase = "Phase5"
        }
        else {
            $nextPhase = "Phase7"
        }
    }
    elseif (Test-TaskScopedPhase -Phase $nextPhase) {
        if ($taskId) {
            $nextTaskId = $taskId
        }
        else {
            $nextTaskId = Resolve-NextReadyTaskId -RunState $state
        }
    }

    $state["status"] = "running"
    $state = Set-RunStateCursor -RunState $state -Phase $nextPhase -TaskId $nextTaskId

    if ($phase -eq "Phase2" -and $verdict -eq "go") {
        $blockingQuestions = @(Get-ArtifactFieldMeaningfulEntries -Artifact $artifactObject -FieldName "unresolved_blockers")
        if ($blockingQuestions.Count -gt 0) {
            $clarificationMessage = "質問事項に回答してください。`tasks/task.md` と必要に応じて `outputs/phase0_context.*` を更新したら y を入力します。y で Phase0 から再開します。"
            $approvalRequest = New-ApprovalRequest -ApprovalId (New-ApprovalId) -RequestedPhase $phase -RequestedRole (Resolve-PhaseRole -Phase $phase) -RequestedTaskId $taskId -ProposedAction @{
                type = "DispatchJob"
                phase = "Phase0"
                role = Resolve-PhaseRole -Phase "Phase0"
                task_id = $null
            } -AllowedRejectPhases @("Phase0") -PromptMessage $clarificationMessage -BlockingItems $blockingQuestions -ApprovalMode "clarification_questions"

            $state["status"] = "waiting_approval"
            $state["pending_approval"] = $approvalRequest
            $state["task_lane"]["stop_leasing"] = $true
            $state = Set-RunStateCursor -RunState $state -Phase $phase -TaskId $taskId
            if ($taskId -and $state["task_states"].ContainsKey($taskId)) {
                $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
                $taskState["wait_reason"] = "approval"
                $state["task_states"][$taskId] = $taskState
            }

            return [ordered]@{
                run_state = $state
                action = @{
                    type = "RequestApproval"
                    pending_approval = $approvalRequest
                    proposed_action = $approvalRequest["proposed_action"]
                }
                spawned_tasks = $spawnedTasks
            }
        }
    }

    if ($phase -in $ApprovalPhases) {
        $allowedRejectPhases = Resolve-ApprovalAllowedRejectPhases -ProjectRoot $ProjectRoot -Phase $phase
        $approvalId = New-ApprovalId
        $approvalPromptMessage = ""
        $approvalBlockingItems = @()
        $approvalCarryForwardRequirements = @()
        if ($verdict -eq "conditional_go") {
            $approvalBlockingItems = @(Get-ArtifactFieldMeaningfulEntries -Artifact $artifactObject -FieldName "must_fix")
            $approvalCarryForwardRequirements = @(
                Convert-ApprovalEntriesToOpenRequirements `
                    -Entries @($artifactObject["must_fix"]) `
                    -SourcePhase $phase `
                    -SourceTaskId $taskId `
                    -VerifyInPhase $nextPhase `
                    -ItemIdPrefix "carry-$approvalId"
            )
            if ($approvalBlockingItems.Count -gt 0) {
                $approvalPromptMessage = "Reviewer の must_fix を確認してください。approve/skip でも次の $nextPhase の open_requirements に持ち越されます。"
            }
        }

        $approvalRequest = New-ApprovalRequest -ApprovalId $approvalId -RequestedPhase $phase -RequestedRole (Resolve-PhaseRole -Phase $phase) -RequestedTaskId $taskId -ProposedAction @{
            type = "DispatchJob"
            phase = $nextPhase
            role = Resolve-PhaseRole -Phase $nextPhase
            task_id = $nextTaskId
        } -AllowedRejectPhases $allowedRejectPhases -PromptMessage $approvalPromptMessage -BlockingItems $approvalBlockingItems -CarryForwardRequirements $approvalCarryForwardRequirements

        $state["status"] = "waiting_approval"
        $state["pending_approval"] = $approvalRequest
        $state["task_lane"]["stop_leasing"] = $true
        $state = Set-RunStateCursor -RunState $state -Phase $phase -TaskId $taskId
        if ($taskId -and $state["task_states"].ContainsKey($taskId)) {
            $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$taskId]
            $taskState["wait_reason"] = "approval"
            $state["task_states"][$taskId] = $taskState
        }

        return [ordered]@{
            run_state = $state
            action = @{
                type = "RequestApproval"
                pending_approval = $approvalRequest
                proposed_action = $approvalRequest["proposed_action"]
            }
            spawned_tasks = $spawnedTasks
        }
    }

    return [ordered]@{
        run_state = $state
        action = @{
            type = "Continue"
            next_phase = $nextPhase
            next_task_id = $nextTaskId
        }
        spawned_tasks = $spawnedTasks
    }
}

function Apply-ApprovalDecision {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$ApprovalDecision
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $decision = Normalize-ApprovalDecision -Decision $ApprovalDecision
    $pendingApproval = ConvertTo-RelayHashtable -InputObject $state["pending_approval"]
    if (-not $pendingApproval) {
        throw "No pending approval to resolve."
    }

    $appliedAction = ConvertTo-RelayHashtable -InputObject $pendingApproval["proposed_action"]
    $state["pending_approval"] = $null
    if ($state["task_lane"]) {
        $state["task_lane"]["stop_leasing"] = $false
    }
    $requestedTaskId = [string]$pendingApproval["requested_task_id"]
    if (-not [string]::IsNullOrWhiteSpace($requestedTaskId) -and $state["task_states"].ContainsKey($requestedTaskId)) {
        $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$requestedTaskId]
        if ([string]$taskState["wait_reason"] -eq "approval") {
            $taskState["wait_reason"] = $null
        }
        $state["task_states"][$requestedTaskId] = $taskState
    }
    $verifyPhase = [string]$pendingApproval["requested_phase"]
    if ($appliedAction -and $appliedAction["phase"]) {
        $verifyPhase = [string]$appliedAction["phase"]
    }

    $requirementsToMerge = New-Object System.Collections.Generic.List[object]
    $carryForwardRequirements = @(
        Convert-ApprovalEntriesToOpenRequirements `
            -Entries @($pendingApproval["carry_forward_requirements"]) `
            -SourcePhase ([string]$pendingApproval["requested_phase"]) `
            -SourceTaskId ([string]$pendingApproval["requested_task_id"]) `
            -VerifyInPhase $verifyPhase `
            -ItemIdPrefix "carry-$([string]$pendingApproval['approval_id'])"
    )

    switch ([string]$decision["decision"]) {
        "approve" {
            foreach ($requirement in $carryForwardRequirements) {
                $requirementsToMerge.Add($requirement)
            }
        }
        "skip" {
            foreach ($requirement in $carryForwardRequirements) {
                $requirementsToMerge.Add($requirement)
            }
        }
        "conditional_approve" {
            foreach ($requirement in $carryForwardRequirements) {
                $requirementsToMerge.Add($requirement)
            }

            $manualRequirements = @(
                Convert-ApprovalEntriesToOpenRequirements `
                    -Entries @($decision["must_fix"]) `
                    -SourcePhase ([string]$pendingApproval["requested_phase"]) `
                    -SourceTaskId ([string]$pendingApproval["requested_task_id"]) `
                    -VerifyInPhase $verifyPhase `
                    -ItemIdPrefix "manual-$([string]$pendingApproval['approval_id'])"
            )
            foreach ($requirement in $manualRequirements) {
                $requirementsToMerge.Add($requirement)
            }
        }
        "reject" {
            $allowedRejectPhases = @(Resolve-ApprovalRejectTargetPhases -ApprovalRequest $pendingApproval)
            $targetPhase = [string]$decision["target_phase"]
            if ([string]::IsNullOrWhiteSpace($targetPhase) -and $allowedRejectPhases.Count -eq 1) {
                $targetPhase = [string]$allowedRejectPhases[0]
            }
            if ([string]::IsNullOrWhiteSpace($targetPhase)) {
                throw "reject decision requires target_phase."
            }
            if ($allowedRejectPhases.Count -gt 0 -and $targetPhase -notin $allowedRejectPhases) {
                throw "reject target_phase '$targetPhase' is not allowed. Allowed phases: $($allowedRejectPhases -join ', ')."
            }

            $appliedAction = @{
                type = "DispatchJob"
                phase = $targetPhase
                role = Resolve-PhaseRole -Phase $targetPhase
                task_id = $decision["target_task_id"]
            }
        }
        "abort" {
            $state["status"] = "blocked"
            $state["updated_at"] = (Get-Date).ToString("o")
            return [ordered]@{
                run_state = $state
                applied_action = @{
                    type = "Wait"
                    reason = "manual_intervention_required"
                }
            }
        }
    }

    if ($requirementsToMerge.Count -gt 0) {
        $state = Merge-OpenRequirements -RunState $state -OpenRequirements $requirementsToMerge.ToArray()
    }

    if ($appliedAction["type"] -eq "DispatchJob") {
        $state["status"] = "running"
        $state = Set-RunStateCursor -RunState $state -Phase $appliedAction["phase"] -TaskId $appliedAction["task_id"]
    }

    return [ordered]@{
        run_state = $state
        applied_action = $appliedAction
    }
}
