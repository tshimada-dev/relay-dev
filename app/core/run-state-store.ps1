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
    $history = @($state["phase_history"])

    if ($history.Count -eq 0) {
        $history = @(
            [ordered]@{
                phase = $state["current_phase"]
                agent = $state["current_role"]
                started = $state["created_at"]
                completed = ""
                result = ""
            }
        )
    }
    else {
        $lastIndex = $history.Count - 1
        $lastEntry = ConvertTo-RelayHashtable -InputObject $history[$lastIndex]
        if ($lastEntry["phase"] -ne $state["current_phase"] -or $lastEntry["agent"] -ne $state["current_role"]) {
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
                    started = $now
                    completed = ""
                    result = ""
                }
            )
        }
        elseif ($state["status"] -in @("completed", "failed", "blocked")) {
            if ([string]::IsNullOrWhiteSpace([string]$lastEntry["completed"])) {
                $lastEntry["completed"] = $now
            }
            $lastEntry["result"] = [string]$state["status"]
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
        pending_approval = $null
        open_requirements = @()
        task_order = @()
        task_states = @{}
        feedback = ""
        phase_history = @(
            [ordered]@{
                phase = $CurrentPhase
                agent = $CurrentRole
                started = $now
                completed = ""
                result = ""
            }
        )
        created_at = $now
        updated_at = $now
    }
}

function Write-RunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$RunState
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $runId = $state["run_id"]
    if (-not $runId) {
        throw "run_id is required to write run-state.json"
    }

    Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $runId

    $state["updated_at"] = (Get-Date).ToString("o")
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

    return (ConvertTo-RelayHashtable -InputObject ($raw | ConvertFrom-Json))
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
