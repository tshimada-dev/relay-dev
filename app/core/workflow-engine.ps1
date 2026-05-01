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
        depends_on = @($DependsOn)
        origin_phase = $OriginPhase
        task_contract_ref = (ConvertTo-RelayHashtable -InputObject $TaskContractRef)
    }
}

function Update-TaskReadiness {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $state["current_phase"] = $Phase
    $state["current_role"] = Resolve-PhaseRole -Phase $Phase
    if (Test-TaskScopedPhase -Phase $Phase) {
        $state["current_task_id"] = $TaskId
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $activeJobId = [string]$state["active_job_id"]
    if ([string]::IsNullOrWhiteSpace($activeJobId)) {
        return @{
            changed = $false
            run_state = $state
            reason = $null
            job_metadata = $null
        }
    }

    if (-not (Get-Command Read-JobMetadata -ErrorAction SilentlyContinue)) {
        return @{
            changed = $false
            run_state = $state
            reason = $null
            job_metadata = $null
        }
    }

    $jobMetadata = Read-JobMetadata -ProjectRoot $ProjectRoot -RunId ([string]$state["run_id"]) -JobId $activeJobId
    if (-not $jobMetadata) {
        $state["active_job_id"] = $null
        $state["status"] = "running"
        $state["updated_at"] = (Get-Date).ToString("o")
        return @{
            changed = $true
            run_state = $state
            reason = "missing_job_metadata"
            job_metadata = $null
        }
    }

    $jobMetadata = ConvertTo-RelayHashtable -InputObject $jobMetadata
    $jobStatus = [string]$jobMetadata["status"]
    $jobProcessId = 0
    $hasPid = [int]::TryParse([string]$jobMetadata["pid"], [ref]$jobProcessId)
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

    $shouldClear = $false
    $reason = $null
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

    if (-not $shouldClear) {
        return @{
            changed = $false
            run_state = $state
            reason = $null
            job_metadata = $jobMetadata
        }
    }

    $state["active_job_id"] = $null
    $state["status"] = "running"
    $state["updated_at"] = (Get-Date).ToString("o")
    return @{
        changed = $true
        run_state = $state
        reason = $reason
        job_metadata = $jobMetadata
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

    if ($state["active_job_id"]) {
        return [ordered]@{
            type = "Wait"
            reason = "job_in_progress"
            run_id = $runId
            job_id = $state["active_job_id"]
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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $job = ConvertTo-RelayHashtable -InputObject $JobResult
    $validation = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $artifactObject = ConvertTo-RelayHashtable -InputObject $Artifact

    $state["active_job_id"] = $null
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
        if ($phase -eq "Phase6") {
            $taskState["status"] = "completed"
        }
        else {
            $taskState["status"] = "in_progress"
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
            $state = Set-RunStateCursor -RunState $state -Phase $phase -TaskId $taskId

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
        $state = Set-RunStateCursor -RunState $state -Phase $phase -TaskId $taskId

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

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $decision = Normalize-ApprovalDecision -Decision $ApprovalDecision
    $pendingApproval = ConvertTo-RelayHashtable -InputObject $state["pending_approval"]
    if (-not $pendingApproval) {
        throw "No pending approval to resolve."
    }

    $appliedAction = ConvertTo-RelayHashtable -InputObject $pendingApproval["proposed_action"]
    $state["pending_approval"] = $null
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
