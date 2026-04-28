#requires -Version 7.0

param(
    [Parameter(Position = 0)][ValidateSet("new", "resume", "step", "show")][string]$Command = "show",
    [string]$ConfigFile = "config/settings.yaml",
    [string]$RunId,
    [string]$CurrentPhase = "Phase0",
    [string]$CurrentRole = "implementer",
    [string]$TaskId = "task-main",
    [string]$Prompt,
    [string]$PromptFile,
    [string]$Phase = "Phase1",
    [string]$Role = "implementer",
    [string]$Provider,
    [string]$ProviderCommand,
    [string]$ProviderFlags,
    [string]$ApprovalDecisionJson,
    [string]$ApprovalDecisionFile
)

$ErrorActionPreference = "Stop"
$script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:Role = "system"
Set-Location $script:ProjectRoot

. (Join-Path $script:ProjectRoot "config/common.ps1")
. (Join-Path $script:ProjectRoot "lib/logging.ps1")
. (Join-Path $script:ProjectRoot "lib/settings.ps1")
. (Join-Path $script:ProjectRoot "app/core/run-state-store.ps1")
. (Join-Path $script:ProjectRoot "app/core/run-lock.ps1")
. (Join-Path $script:ProjectRoot "app/core/event-store.ps1")
. (Join-Path $script:ProjectRoot "app/core/artifact-repository.ps1")
. (Join-Path $script:ProjectRoot "app/core/artifact-validator.ps1")
. (Join-Path $script:ProjectRoot "app/core/job-result-policy.ps1")
. (Join-Path $script:ProjectRoot "app/core/transition-resolver.ps1")
. (Join-Path $script:ProjectRoot "app/approval/approval-manager.ps1")
. (Join-Path $script:ProjectRoot "app/approval/terminal-adapter.ps1")
. (Join-Path $script:ProjectRoot "app/core/workflow-engine.ps1")
. (Join-Path $script:ProjectRoot "app/execution/providers/generic-cli.ps1")
. (Join-Path $script:ProjectRoot "app/execution/providers/codex.ps1")
. (Join-Path $script:ProjectRoot "app/execution/providers/gemini.ps1")
. (Join-Path $script:ProjectRoot "app/execution/providers/claude.ps1")
. (Join-Path $script:ProjectRoot "app/execution/providers/copilot.ps1")
. (Join-Path $script:ProjectRoot "app/execution/providers/fake-provider.ps1")
. (Join-Path $script:ProjectRoot "app/execution/provider-adapter.ps1")
. (Join-Path $script:ProjectRoot "app/execution/execution-runner.ps1")
. (Join-Path $script:ProjectRoot "app/phases/phase-registry.ps1")

$config = Read-Config -Path $ConfigFile
Initialize-Settings -Config $config -Role "system"

function Initialize-LegacyDirectories {
    foreach ($path in @("queue", "outputs", $script:LogDirectory)) {
        $fullPath = Join-Path $script:ProjectRoot $path
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        }
    }

    $taskFilePath = if ([System.IO.Path]::IsPathRooted($script:TaskFile)) {
        $script:TaskFile
    }
    else {
        Join-Path $script:ProjectRoot $script:TaskFile
    }
    $taskDir = Split-Path -Parent $taskFilePath
    if (-not [string]::IsNullOrWhiteSpace($taskDir) -and -not (Test-Path $taskDir)) {
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
    }

    if (-not (Test-Path $taskFilePath)) {
        $examplePath = "${taskFilePath}.example"
        if (Test-Path $examplePath) {
            Copy-Item -Path $examplePath -Destination $taskFilePath
        }
        else {
            Set-Content -Path $taskFilePath -Value "# Current Task`n" -Encoding UTF8
        }
    }
}

function Resolve-StepRunId {
    param([string]$RequestedRunId)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRunId)) {
        return $RequestedRunId
    }

    return (Resolve-ActiveRunId -ProjectRoot $script:ProjectRoot)
}

function Get-StepTimeoutPolicy {
    return @{
        warn_after_sec = $script:EscPhase1Sec
        retry_after_sec = $script:EscPhase2Sec
        abort_after_sec = $script:EscPhase3Sec
        max_retries = 1
    }
}

function Restart-CurrentPhaseHistoryForRecovery {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $history = @($state["phase_history"])
    if ($history.Count -eq 0) {
        return $state
    }

    $lastEntry = ConvertTo-RelayHashtable -InputObject $history[$history.Count - 1]
    if (
        $lastEntry["phase"] -eq $state["current_phase"] -and
        $lastEntry["agent"] -eq $state["current_role"] -and
        -not [string]::IsNullOrWhiteSpace([string]$lastEntry["completed"])
    ) {
        $history += @(
            [ordered]@{
                phase = $state["current_phase"]
                agent = $state["current_role"]
                started = (Get-Date).ToString("o")
                completed = ""
                result = ""
            }
        )
        $state["phase_history"] = $history
    }

    return $state
}

function Repair-RecoverableFailedRunState {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RecoverySource = "resume"
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $runId = [string]$state["run_id"]

    if (
        [string]$state["status"] -ne "failed" -or
        [string]::IsNullOrWhiteSpace($runId) -or
        $state["active_job_id"] -or
        $state["pending_approval"]
    ) {
        return @{
            changed = $false
            run_state = $state
            recovery_event = $null
        }
    }

    $lastFailureEvent = ConvertTo-RelayHashtable -InputObject (Get-LastEvent -ProjectRoot $ProjectRoot -RunId $runId -Type "run.failed")
    $lastJobFinishedEvent = ConvertTo-RelayHashtable -InputObject (Get-LastEvent -ProjectRoot $ProjectRoot -RunId $runId -Type "job.finished")

    $failureReason = if ($lastFailureEvent) { [string]$lastFailureEvent["reason"] } else { "" }
    $failureClass = if ($lastFailureEvent) { [string]$lastFailureEvent["failure_class"] } else { "" }

    if ([string]::IsNullOrWhiteSpace($failureReason) -and $lastJobFinishedEvent -and [string]$lastJobFinishedEvent["result_status"] -eq "failed") {
        $failureReason = "job_failed"
    }
    if ([string]::IsNullOrWhiteSpace($failureClass) -and $lastJobFinishedEvent) {
        $failureClass = [string]$lastJobFinishedEvent["failure_class"]
    }

    if ($failureReason -ne "job_failed" -or $failureClass -notin @("provider_error", "timeout")) {
        return @{
            changed = $false
            run_state = $state
            recovery_event = $null
        }
    }

    $state["status"] = "running"
    $state["feedback"] = ""
    $state["updated_at"] = (Get-Date).ToString("o")
    $state = Restart-CurrentPhaseHistoryForRecovery -RunState $state

    return @{
        changed = $true
        run_state = $state
        recovery_event = [ordered]@{
            type = "run.recovered"
            recovered_from_status = "failed"
            recovery_action = "retry_same_phase"
            recovery_source = $RecoverySource
            failure_reason = $failureReason
            failure_class = $failureClass
            phase = [string]$state["current_phase"]
            role = [string]$state["current_role"]
            task_id = [string]$state["current_task_id"]
            job_id = if ($lastJobFinishedEvent) { [string]$lastJobFinishedEvent["job_id"] } else { "" }
        }
    }
}

function Resolve-RoleProviderSpec {
    param(
        [Parameter(Mandatory)][string]$ResolvedRole,
        [string]$ProviderName,
        [string]$ExplicitCommand,
        [string]$ExplicitFlags
    )

    $defaultCommand = if ($ResolvedRole -eq "reviewer") { $script:ReviewerCommand } else { $script:ImplementerCommand }
    $defaultFlags = if ($ResolvedRole -eq "reviewer") { $script:ReviewerFlags } else { $script:ImplementerFlags }

    $resolvedCommand = if (-not [string]::IsNullOrWhiteSpace($ExplicitCommand)) {
        $ExplicitCommand
    }
    else {
        $defaultCommand
    }

    $resolvedFlags = if (-not [string]::IsNullOrWhiteSpace($ExplicitFlags)) {
        $ExplicitFlags
    }
    else {
        $defaultFlags
    }

    $resolvedProvider = if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
        $ProviderName
    }
    else {
        $resolvedCommand
    }

    return @{
        provider = $resolvedProvider
        command = $resolvedCommand
        flags = $resolvedFlags
    }
}

function Read-OptionalUtf8File {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return ""
    }

    return (Get-Content -Path $Path -Raw -Encoding UTF8)
}

function Resolve-TaskFilePath {
    if ([System.IO.Path]::IsPathRooted($script:TaskFile)) {
        return $script:TaskFile
    }

    return (Join-Path $script:ProjectRoot $script:TaskFile)
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Cannot calculate SHA256 because '$Path' does not exist."
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
        $hashBytes = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant())
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CurrentTaskSeedMetadata {
    $taskFilePath = Resolve-TaskFilePath
    return [ordered]@{
        task_path = $taskFilePath
        task_fingerprint = Get-FileSha256 -Path $taskFilePath
        seed_checked_at = (Get-Date).ToString("o")
    }
}

function Test-Phase0SeedFreshness {
    param([Parameter(Mandatory)]$SeedArtifact)

    $artifact = ConvertTo-RelayHashtable -InputObject $SeedArtifact
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($field in @("task_fingerprint", "task_path", "seed_created_at")) {
        if (-not $artifact.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$artifact[$field])) {
            $errors.Add("phase0_context.json is missing required seed metadata '$field'.")
        }
    }

    $currentMetadata = $null
    try {
        $currentMetadata = Get-CurrentTaskSeedMetadata
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    if ($currentMetadata -and $artifact.ContainsKey("task_fingerprint")) {
        $expectedFingerprint = [string]$currentMetadata["task_fingerprint"]
        $seedFingerprint = [string]$artifact["task_fingerprint"]
        if ($seedFingerprint -ne $expectedFingerprint) {
            $errors.Add("phase0_context.json task_fingerprint does not match the current tasks/task.md fingerprint.")
        }
    }

    return @{
        valid = ($errors.Count -eq 0)
        errors = @($errors)
        current_metadata = $currentMetadata
    }
}

function Resolve-ContractArtifactPath {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$ContractItem,
        [string]$TaskId
    )

    $item = ConvertTo-RelayHashtable -InputObject $ContractItem
    $scope = if ($item["scope"]) { [string]$item["scope"] } else { "run" }
    if ($scope -eq "external") {
        $relativePath = if ($item["path"]) { [string]$item["path"] } else { [string]$item["artifact_id"] }
        if ([System.IO.Path]::IsPathRooted($relativePath)) {
            return $relativePath
        }

        return (Join-Path $script:ProjectRoot $relativePath)
    }

    $sourcePhase = if ($item["phase"]) { [string]$item["phase"] } else { $PhaseName }
    if ($scope -eq "task") {
        return (Get-ArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $TaskId)
    }

    return (Get-ArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]))
}

function Resolve-PhaseValidatorArtifactRef {
    param(
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId
    )

    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $validator = ConvertTo-RelayHashtable -InputObject $definition["validator"]
    if (-not $validator -or [string]::IsNullOrWhiteSpace([string]$validator["artifact_id"])) {
        return $null
    }

    $artifactId = [string]$validator["artifact_id"]
    $scope = "run"
    foreach ($contractItem in @($definition["output_contract"])) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        if ([string]$item["artifact_id"] -eq $artifactId) {
            if ($item["scope"]) {
                $scope = [string]$item["scope"]
            }
            break
        }
    }

    return @{
        scope = $scope
        phase = $PhaseName
        artifact_id = $artifactId
        task_id = if ($scope -eq "task") { $TaskId } else { $null }
    }
}

function Sync-PhaseOutputArtifacts {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [string]$TaskId
    )

    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $materialized = @()
    $missingRequired = @()
    $readErrors = @()

    foreach ($contractItem in @($definition["output_contract"])) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        $scope = if ($item["scope"]) { [string]$item["scope"] } else { "run" }
        $artifactId = [string]$item["artifact_id"]
        $format = [string]$item["format"]
        $required = $false
        if ($item.ContainsKey("required")) {
            $required = [bool]$item["required"]
        }

        $path = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId
        if (-not (Test-Path $path)) {
            if ($required) {
                $missingRequired += $artifactId
            }
            continue
        }

        try {
            if ($format -eq "json" -or $artifactId.ToLowerInvariant().EndsWith(".json")) {
                $content = ConvertTo-RelayHashtable -InputObject ((Get-Content -Path $path -Raw -Encoding UTF8) | ConvertFrom-Json)
                if ($scope -eq "task") {
                    Write-CompatibilityArtifactProjection -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $PhaseName -ArtifactId $artifactId -Content $content -TaskId $TaskId -AsJson | Out-Null
                }
                else {
                    Write-CompatibilityArtifactProjection -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $PhaseName -ArtifactId $artifactId -Content $content -AsJson | Out-Null
                }
            }
            else {
                $content = Get-Content -Path $path -Raw -Encoding UTF8
                if ($scope -eq "task") {
                    Write-CompatibilityArtifactProjection -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $PhaseName -ArtifactId $artifactId -Content $content -TaskId $TaskId | Out-Null
                }
                else {
                    Write-CompatibilityArtifactProjection -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $PhaseName -ArtifactId $artifactId -Content $content | Out-Null
                }
            }

            $materialized += @{
                artifact_id = $artifactId
                scope = $scope
                path = $path
            }
        }
        catch {
            $readErrors += "Failed to materialize artifact '$artifactId': $_"
        }
    }

    return @{
        materialized = $materialized
        missing_required = $missingRequired
        read_errors = $readErrors
    }
}

function Get-CurrentPhaseHistoryEntry {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$Role
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $history = @($state["phase_history"])
    for ($index = $history.Count - 1; $index -ge 0; $index--) {
        $entry = ConvertTo-RelayHashtable -InputObject $history[$index]
        if ([string]$entry["phase"] -ne $PhaseName) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($Role) -and [string]$entry["agent"] -ne $Role) {
            continue
        }

        return $entry
    }

    return $null
}

function Convert-RelayDateTimeToUtc {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [ref]$parsed)) {
        return $null
    }

    return $parsed.ToUniversalTime()
}

function Resolve-ArtifactCompletionCutoffUtc {
    param(
        [AllowNull()][datetime]$PhaseStartedAtUtc,
        [AllowNull()][datetime]$AttemptStartedAtUtc
    )

    if ($null -eq $PhaseStartedAtUtc) {
        return $AttemptStartedAtUtc
    }
    if ($null -eq $AttemptStartedAtUtc) {
        return $PhaseStartedAtUtc
    }
    if ($PhaseStartedAtUtc -gt $AttemptStartedAtUtc) {
        return $PhaseStartedAtUtc
    }

    return $AttemptStartedAtUtc
}

function Write-ArtifactProbeTrace {
    param([AllowNull()]$Payload)

    $logPath = $env:RELAY_DEV_ARTIFACT_PROBE_LOG
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        return
    }

    try {
        $entry = ConvertTo-RelayHashtable -InputObject $Payload
        Add-Content -Path $logPath -Value ($entry | ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
    }
    catch {
    }
}

$script:ArtifactCompletionProbeState = $null

function Test-PhaseArtifactCompletion {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [string]$TaskId,
        [AllowNull()][datetime]$PhaseStartedAtUtc,
        [AllowNull()][datetime]$AttemptStartedAtUtc
    )

    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $cutoffUtc = Resolve-ArtifactCompletionCutoffUtc -PhaseStartedAtUtc $PhaseStartedAtUtc -AttemptStartedAtUtc $AttemptStartedAtUtc
    $missingRequired = New-Object System.Collections.Generic.List[string]
    $staleRequired = New-Object System.Collections.Generic.List[string]
    $requiredArtifacts = New-Object System.Collections.Generic.List[object]
    $snapshotParts = New-Object System.Collections.Generic.List[string]
    $resolvedPaths = @{}

    foreach ($contractItem in @($definition["output_contract"])) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        $artifactId = [string]$item["artifact_id"]
        if ([string]::IsNullOrWhiteSpace($artifactId)) {
            continue
        }

        $path = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId
        $resolvedPaths[$artifactId] = $path

        $required = $false
        if ($item.ContainsKey("required")) {
            $required = [bool]$item["required"]
        }
        if (-not $required) {
            continue
        }

        if (-not (Test-Path $path)) {
            $missingRequired.Add($artifactId) | Out-Null
            continue
        }

        $fileItem = Get-Item -LiteralPath $path -ErrorAction Stop
        $lastWriteTimeUtc = $fileItem.LastWriteTimeUtc
        if ($cutoffUtc -and $lastWriteTimeUtc -lt $cutoffUtc) {
            $staleRequired.Add("$artifactId<$($lastWriteTimeUtc.ToString("o"))") | Out-Null
            continue
        }

        $length = if ($fileItem.PSIsContainer) { 0 } else { [int64]$fileItem.Length }
        $requiredArtifacts.Add([ordered]@{
            artifact_id = $artifactId
            path = $path
            last_write_time_utc = $lastWriteTimeUtc.ToString("o")
            length = $length
        }) | Out-Null
        $snapshotParts.Add("$artifactId|$($lastWriteTimeUtc.ToString("o"))|$length") | Out-Null
    }

    if ($missingRequired.Count -gt 0 -or $staleRequired.Count -gt 0) {
        $result = [ordered]@{
            detected = $false
            reason = if ($missingRequired.Count -gt 0) { "required_artifacts_missing" } else { "required_artifacts_stale" }
            missing_required = @($missingRequired)
            stale_required = @($staleRequired)
            cutoff_utc = if ($cutoffUtc) { $cutoffUtc.ToString("o") } else { $null }
            phase_started_at_utc = if ($PhaseStartedAtUtc) { $PhaseStartedAtUtc.ToString("o") } else { $null }
            attempt_started_at_utc = if ($AttemptStartedAtUtc) { $AttemptStartedAtUtc.ToString("o") } else { $null }
        }
        Write-ArtifactProbeTrace -Payload $result
        return $result
    }

    $validatorRef = Resolve-PhaseValidatorArtifactRef -PhaseDefinition $PhaseDefinition -PhaseName $PhaseName -TaskId $TaskId
    $validation = $null
    $artifact = $null
    if ($validatorRef) {
        $validatorRef = ConvertTo-RelayHashtable -InputObject $validatorRef
        $validatorArtifactId = [string]$validatorRef["artifact_id"]
        $validatorPath = if ($resolvedPaths.ContainsKey($validatorArtifactId)) {
            [string]$resolvedPaths[$validatorArtifactId]
        }
        else {
            $validatorPath = $null
            foreach ($contractItem in @($definition["output_contract"])) {
                $item = ConvertTo-RelayHashtable -InputObject $contractItem
                if ([string]$item["artifact_id"] -eq $validatorArtifactId) {
                    $validatorPath = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($validatorPath)) {
                if ([string]$validatorRef["scope"] -eq "task") {
                    $validatorPath = Get-ArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope "task" -Phase ([string]$validatorRef["phase"]) -ArtifactId $validatorArtifactId -TaskId ([string]$validatorRef["task_id"])
                }
                else {
                    $validatorPath = Get-ArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope ([string]$validatorRef["scope"]) -Phase ([string]$validatorRef["phase"]) -ArtifactId $validatorArtifactId
                }
            }

            $resolvedPaths[$validatorArtifactId] = $validatorPath
            $validatorPath
        }

        if (-not (Test-Path $validatorPath)) {
            $result = [ordered]@{
                detected = $false
                reason = "validator_missing"
                validator_ref = $validatorRef
                validator_path = $validatorPath
                cutoff_utc = if ($cutoffUtc) { $cutoffUtc.ToString("o") } else { $null }
                phase_started_at_utc = if ($PhaseStartedAtUtc) { $PhaseStartedAtUtc.ToString("o") } else { $null }
                attempt_started_at_utc = if ($AttemptStartedAtUtc) { $AttemptStartedAtUtc.ToString("o") } else { $null }
            }
            Write-ArtifactProbeTrace -Payload $result
            return $result
        }

        $validatorFileItem = Get-Item -LiteralPath $validatorPath -ErrorAction Stop
        $validatorLastWriteUtc = $validatorFileItem.LastWriteTimeUtc
        if ($cutoffUtc -and $validatorLastWriteUtc -lt $cutoffUtc) {
            $result = [ordered]@{
                detected = $false
                reason = "validator_stale"
                validator_ref = $validatorRef
                validator_path = $validatorPath
                stale_required = @("$validatorArtifactId<$($validatorLastWriteUtc.ToString("o"))")
                cutoff_utc = if ($cutoffUtc) { $cutoffUtc.ToString("o") } else { $null }
                phase_started_at_utc = if ($PhaseStartedAtUtc) { $PhaseStartedAtUtc.ToString("o") } else { $null }
                attempt_started_at_utc = if ($AttemptStartedAtUtc) { $AttemptStartedAtUtc.ToString("o") } else { $null }
            }
            Write-ArtifactProbeTrace -Payload $result
            return $result
        }

        $validatorLength = if ($validatorFileItem.PSIsContainer) { 0 } else { [int64]$validatorFileItem.Length }
        $validatorSnapshot = "$validatorArtifactId|$($validatorLastWriteUtc.ToString("o"))|$validatorLength"
        if ($validatorArtifactId -notin @($requiredArtifacts | ForEach-Object { [string]$_["artifact_id"] })) {
            $snapshotParts.Add($validatorSnapshot) | Out-Null
        }

        try {
            $validation = ConvertTo-RelayHashtable -InputObject (Test-ArtifactRef -ProjectRoot $script:ProjectRoot -RunId $RunId -ArtifactRef $validatorRef)
            $artifact = Read-Artifact -ProjectRoot $script:ProjectRoot -RunId $RunId -ArtifactRef $validatorRef
        }
        catch {
            $result = [ordered]@{
                detected = $false
                reason = "validator_unreadable"
                validator_ref = $validatorRef
                validator_path = $validatorPath
                errors = @([string]$_.Exception.Message)
            }
            Write-ArtifactProbeTrace -Payload $result
            return $result
        }

        if (-not [bool]$validation["valid"]) {
            $result = [ordered]@{
                detected = $false
                reason = "validator_invalid"
                validator_ref = $validatorRef
                validator_path = $validatorPath
                validation = $validation
                cutoff_utc = if ($cutoffUtc) { $cutoffUtc.ToString("o") } else { $null }
                phase_started_at_utc = if ($PhaseStartedAtUtc) { $PhaseStartedAtUtc.ToString("o") } else { $null }
                attempt_started_at_utc = if ($AttemptStartedAtUtc) { $AttemptStartedAtUtc.ToString("o") } else { $null }
            }
            Write-ArtifactProbeTrace -Payload $result
            return $result
        }
    }

    $snapshot = ($snapshotParts.ToArray() | Sort-Object) -join ";"
    if ([string]::IsNullOrWhiteSpace($snapshot)) {
        $snapshot = "__artifact_complete__"
    }

    $result = [ordered]@{
        detected = $true
        reason = "validated_artifacts_ready"
        snapshot = $snapshot
        required_artifacts = @($requiredArtifacts.ToArray())
        validator_ref = $validatorRef
        validation = $validation
        artifact = $artifact
        cutoff_utc = if ($cutoffUtc) { $cutoffUtc.ToString("o") } else { $null }
        phase_started_at_utc = if ($PhaseStartedAtUtc) { $PhaseStartedAtUtc.ToString("o") } else { $null }
        attempt_started_at_utc = if ($AttemptStartedAtUtc) { $AttemptStartedAtUtc.ToString("o") } else { $null }
    }
    Write-ArtifactProbeTrace -Payload $result
    return $result
}

function Invoke-PhaseArtifactCompletionProbe {
    param($ProbeContext)

    $probeState = ConvertTo-RelayHashtable -InputObject $script:ArtifactCompletionProbeState
    if (-not $probeState) {
        return $null
    }

    $probe = ConvertTo-RelayHashtable -InputObject $ProbeContext
    Write-ArtifactProbeTrace -Payload @{
        detected = $false
        reason = "probe_invoked"
        probe_context = $probe
        phase = [string]$probeState["phase_name"]
    }

    try {
        $attemptStartedAtUtc = Convert-RelayDateTimeToUtc -Value ([string]$probe["started_at"])
        return (Test-PhaseArtifactCompletion -RunId ([string]$probeState["run_id"]) -PhaseName ([string]$probeState["phase_name"]) -PhaseDefinition $probeState["phase_definition"] -TaskId ([string]$probeState["task_id"]) -PhaseStartedAtUtc $probeState["phase_started_at_utc"] -AttemptStartedAtUtc $attemptStartedAtUtc)
    }
    catch {
        Write-ArtifactProbeTrace -Payload @{
            detected = $false
            reason = "probe_exception"
            probe_context = $probe
            phase = [string]$probeState["phase_name"]
            errors = @([string]$_.Exception.Message)
        }
        throw
    }
}

function Resolve-StepValidation {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)]$OutputSyncResult,
        [string]$TaskId
    )

    $validatorRef = Resolve-PhaseValidatorArtifactRef -PhaseDefinition $PhaseDefinition -PhaseName $PhaseName -TaskId $TaskId
    if (-not $validatorRef) {
        return @{
            validator_ref = $null
            validation = $null
            artifact = $null
        }
    }

    $syncResult = ConvertTo-RelayHashtable -InputObject $OutputSyncResult
    $errors = @()
    if (@($syncResult["missing_required"]).Count -gt 0) {
        $errors += @($syncResult["missing_required"] | ForEach-Object { "Required artifact '$_' was not produced." })
    }
    if (@($syncResult["read_errors"]).Count -gt 0) {
        $errors += @($syncResult["read_errors"])
    }

    if ($errors.Count -gt 0) {
        return @{
            validator_ref = $validatorRef
            validation = @{
                valid = $false
                errors = $errors
                warnings = @()
            }
            artifact = $null
        }
    }

    $artifact = Read-Artifact -ProjectRoot $script:ProjectRoot -RunId $RunId -ArtifactRef $validatorRef
    if ($null -eq $artifact) {
        return @{
            validator_ref = $validatorRef
            validation = @{
                valid = $false
                errors = @("Validator artifact '$($validatorRef['artifact_id'])' could not be loaded.")
                warnings = @()
            }
            artifact = $null
        }
    }

    $artifactId = [string]$validatorRef["artifact_id"]
    $normalization = ConvertTo-RelayHashtable -InputObject (Normalize-ArtifactForValidation -ArtifactId $artifactId -Artifact $artifact)
    $artifact = $normalization["artifact"]
    $normalizationWarnings = @($normalization["warnings"])
    if ([bool]$normalization["changed"]) {
        $saveParams = @{
            ProjectRoot = $script:ProjectRoot
            RunId = $RunId
            Scope = [string]$validatorRef["scope"]
            Phase = [string]$validatorRef["phase"]
            ArtifactId = $artifactId
            Content = $artifact
            AsJson = $true
        }
        if ([string]$validatorRef["scope"] -eq "task") {
            $saveParams["TaskId"] = [string]$validatorRef["task_id"]
        }

        Save-Artifact @saveParams | Out-Null
    }

    $validation = ConvertTo-RelayHashtable -InputObject (Test-ArtifactContract -ArtifactId $artifactId -Artifact $artifact -Phase $PhaseName)
    if ($normalizationWarnings.Count -gt 0) {
        $validation["warnings"] = @($validation["warnings"]) + $normalizationWarnings
    }

    return @{
        validator_ref = $validatorRef
        validation = $validation
        artifact = $artifact
    }
}

function Format-ContractPromptLines {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$ContractItems,
        [string]$TaskId,
        [switch]$OutputMode
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($contractItem in @($ContractItems)) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        $artifactId = [string]$item["artifact_id"]
        $scope = if ($item["scope"]) { [string]$item["scope"] } else { "run" }
        $format = if ($item["format"]) { [string]$item["format"] } else { "text" }
        $requiredLabel = if ($item.ContainsKey("required") -and [bool]$item["required"]) { "required" } else { "optional" }
        if ($scope -eq "task" -and [string]::IsNullOrWhiteSpace($TaskId)) {
            $status = if ($OutputMode) { "write" } else { "unavailable" }
            $lines.Add("- [$requiredLabel][$scope][$format] $artifactId => <task artifact unavailable: no current task> ($status)")
            continue
        }
        $path = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId
        $status = if ($OutputMode) { "write" } else { if (Test-Path $path) { "exists" } else { "missing" } }
        $lines.Add("- [$requiredLabel][$scope][$format] $artifactId => $path ($status)")
    }

    return @($lines)
}

function New-EnginePromptText {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$JobSpec,
        [Parameter(Mandatory)]$PhaseDefinition
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $engineAction = ConvertTo-RelayHashtable -InputObject $Action
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $promptPackage = ConvertTo-RelayHashtable -InputObject $job["prompt_package"]
    $promptLineBreak = "`n"

    $sections = New-Object System.Collections.Generic.List[string]

    $systemText = Read-OptionalUtf8File -Path ([string]$promptPackage["system_prompt_ref"])
    if (-not [string]::IsNullOrWhiteSpace($systemText)) {
        $sections.Add("## System`n$systemText")
    }

    $phaseText = Read-OptionalUtf8File -Path ([string]$promptPackage["phase_prompt_ref"])
    $phaseText = Expand-VisualContractPromptTemplates -Text $phaseText
    if (-not [string]::IsNullOrWhiteSpace($phaseText)) {
        $sections.Add("## Phase Instructions`n$phaseText")
    }

    $providerText = Read-OptionalUtf8File -Path ([string]$promptPackage["provider_hints_ref"])
    if (-not [string]::IsNullOrWhiteSpace($providerText)) {
        $sections.Add("## Provider Hints`n$providerText")
    }

    $contextLines = @(
        "RunId: $($job['run_id'])",
        "JobId: $($job['job_id'])",
        "Phase: $($job['phase'])",
        "Role: $($job['role'])",
        "TaskId: $($job['task_id'])",
        "Project root: $script:ProjectRoot",
        "Working directory: $script:ProjectDir",
        "Do not modify queue/status.yaml, runs/*/run-state.json, or events.jsonl directly.",
        "Execute exactly one phase and stop after writing the required artifacts."
    )
    $sections.Add("## Execution Context$promptLineBreak$($contextLines -join $promptLineBreak)")

    $inputLines = Format-ContractPromptLines -RunId ([string]$job["run_id"]) -PhaseName ([string]$job["phase"]) -ContractItems $definition["input_contract"] -TaskId ([string]$job["task_id"])
    if ($inputLines.Count -gt 0) {
        $sections.Add("## Input Artifacts$promptLineBreak$($inputLines -join $promptLineBreak)")
    }

    $outputLines = Format-ContractPromptLines -RunId ([string]$job["run_id"]) -PhaseName ([string]$job["phase"]) -ContractItems $definition["output_contract"] -TaskId ([string]$job["task_id"]) -OutputMode
    if ($outputLines.Count -gt 0) {
        $sections.Add("## Required Outputs$promptLineBreak$($outputLines -join $promptLineBreak)")
    }

    if ($engineAction["selected_task"]) {
        $selectedTaskJson = (ConvertTo-RelayHashtable -InputObject $engineAction["selected_task"]) | ConvertTo-Json -Depth 20
        $sections.Add("## Selected Task`n$selectedTaskJson")
    }

    if (@($state["open_requirements"]).Count -gt 0) {
        $openRequirementsJson = @($state["open_requirements"]) | ConvertTo-Json -Depth 20
        $sections.Add("## Open Requirements`n$openRequirementsJson")
    }

    return ($sections -join "`n`n")
}

function Read-StepApprovalDecision {
    param(
        [Parameter(Mandatory)]$ApprovalRequest,
        [string]$DecisionJson,
        [string]$DecisionFile
    )

    function Convert-ApprovalDecisionText {
        param([Parameter(Mandatory)][string]$RawDecision)

        $trimmed = $RawDecision.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            throw "Approval decision payload is empty."
        }

        switch ($trimmed.ToLowerInvariant()) {
            "y" { return @{ decision = "approve"; comment = "" } }
            "c" { return @{ decision = "conditional_approve"; comment = "" } }
            "n" { return @{ decision = "reject"; comment = "" } }
            "s" { return @{ decision = "skip"; comment = "" } }
            "q" { return @{ decision = "abort"; comment = "" } }
        }

        try {
            return (ConvertTo-RelayHashtable -InputObject ($trimmed | ConvertFrom-Json))
        }
        catch {
        }

        $decisionMatch = [regex]::Match($trimmed, '(approve|conditional_approve|reject|skip|abort)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $decisionMatch.Success) {
            throw "Could not parse approval decision payload: $trimmed"
        }

        $decision = $decisionMatch.Groups[1].Value.ToLowerInvariant()
        $result = [ordered]@{
            decision = $decision
            comment = ""
        }

        $targetPhaseMatch = [regex]::Match($trimmed, 'target_phase"?\s*[:=]\s*"?(Phase\d+(?:-\d+)?)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($targetPhaseMatch.Success) {
            $result["target_phase"] = $targetPhaseMatch.Groups[1].Value
        }

        $targetTaskMatch = [regex]::Match($trimmed, 'target_task_id"?\s*[:=]\s*"?(T-\d+|pr_fixes)"?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($targetTaskMatch.Success) {
            $result["target_task_id"] = $targetTaskMatch.Groups[1].Value
        }

        return $result
    }

    if (-not [string]::IsNullOrWhiteSpace($DecisionFile)) {
        return (Convert-ApprovalDecisionText -RawDecision (Get-Content -Path $DecisionFile -Raw -Encoding UTF8))
    }

    if (-not [string]::IsNullOrWhiteSpace($DecisionJson)) {
        return (Convert-ApprovalDecisionText -RawDecision $DecisionJson)
    }

    return (Read-ApprovalDecisionFromTerminal -ApprovalRequest $ApprovalRequest)
}

function Get-Phase0SeedArtifacts {
    $outputsRoot = Join-Path $script:ProjectRoot "outputs"
    $markdownPath = Join-Path $outputsRoot "phase0_context.md"
    $jsonPath = Join-Path $outputsRoot "phase0_context.json"
    if (-not (Test-Path $markdownPath) -or -not (Test-Path $jsonPath)) {
        return $null
    }

    $markdownContent = Get-Content -Path $markdownPath -Raw -Encoding UTF8
    $jsonArtifact = ConvertTo-RelayHashtable -InputObject ((Get-Content -Path $jsonPath -Raw -Encoding UTF8) | ConvertFrom-Json)
    $validation = Test-ArtifactContract -ArtifactId "phase0_context.json" -Artifact $jsonArtifact -Phase "Phase0"
    $freshness = Test-Phase0SeedFreshness -SeedArtifact $jsonArtifact

    return @{
        markdown_path = $markdownPath
        json_path = $jsonPath
        markdown = $markdownContent
        artifact = $jsonArtifact
        validation = $validation
        freshness = $freshness
    }
}

function Invoke-SeededPhase0Step {
    param(
        [Parameter(Mandatory)][string]$ResolvedRunId,
        [Parameter(Mandatory)]$RunState
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    if ([string]$state["current_phase"] -ne "Phase0") {
        return $null
    }
    if ($state["active_job_id"] -or $state["pending_approval"]) {
        return $null
    }

    $seedArtifacts = Get-Phase0SeedArtifacts
    if (-not $seedArtifacts) {
        return $null
    }

    $seedValidation = ConvertTo-RelayHashtable -InputObject $seedArtifacts["validation"]
    if (-not [bool]$seedValidation["valid"]) {
        throw "Phase0 seed is invalid: $(@($seedValidation['errors']) -join '; ')"
    }

    $seedFreshness = ConvertTo-RelayHashtable -InputObject $seedArtifacts["freshness"]
    if (-not [bool]$seedFreshness["valid"]) {
        throw "Phase0 seed is stale or incomplete: $(@($seedFreshness['errors']) -join '; ')"
    }

    Write-Phase0Artifacts -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -MarkdownContent ([string]$seedArtifacts["markdown"]) -JsonContent $seedArtifacts["artifact"] | Out-Null
    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
        type = "phase0.seeded"
        source = @($seedArtifacts["markdown_path"], $seedArtifacts["json_path"])
        task_fingerprint = [string]$seedArtifacts["artifact"]["task_fingerprint"]
        task_path = [string]$seedArtifacts["artifact"]["task_path"]
    }
    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
        type = "artifact.validated"
        phase = "Phase0"
        artifact_id = "phase0_context.json"
        valid = $true
        errors = @()
        warnings = @()
    }

    $mutation = Apply-JobResult -RunState $state -JobResult @{
        phase = "Phase0"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult $seedValidation -Artifact $seedArtifacts["artifact"] -ProjectRoot $script:ProjectRoot -ApprovalPhases $script:HumanReviewPhases

    $nextRunState = ConvertTo-RelayHashtable -InputObject $mutation["run_state"]
    Write-RunState -ProjectRoot $script:ProjectRoot -RunState $nextRunState | Out-Null
    Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $nextRunState

    $mutationAction = ConvertTo-RelayHashtable -InputObject $mutation["action"]
    switch ([string]$mutationAction["type"]) {
        "Continue" {
            Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                type = "phase.transitioned"
                from_phase = "Phase0"
                to_phase = $mutationAction["next_phase"]
                task_id = $mutationAction["next_task_id"]
            }
        }
        "FailRun" {
            Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                type = "run.failed"
                reason = $mutationAction["reason"]
            }
        }
    }

    return @{
        mode = "engine"
        action = @{
            type = "SeedPhase0"
            phase = "Phase0"
        }
        validation = $seedValidation
        mutation_action = $mutationAction
        run_state = $nextRunState
    }
}

function Sync-RunStateFromCanonicalArtifacts {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$RunState
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState

    $plannedTasksArtifact = Read-Artifact -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json"
    if ($plannedTasksArtifact) {
        $state = Register-PlannedTasks -RunState $state -TasksArtifact $plannedTasksArtifact
    }

    $phase7VerdictArtifact = Read-Artifact -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json"
    if ($phase7VerdictArtifact -and [string]$phase7VerdictArtifact["verdict"] -eq "conditional_go") {
        $state = Register-RepairTasksFromVerdict -RunState $state -VerdictArtifact $phase7VerdictArtifact -OriginPhase "Phase7"
    }

    return $state
}

function Resolve-CurrentTaskContractRef {
    param(
        [Parameter(Mandatory)]$RunState,
        [string]$TaskId
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $resolvedTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $TaskId
    }
    else {
        [string]$state["current_task_id"]
    }

    if (
        [string]::IsNullOrWhiteSpace($resolvedTaskId) -or
        -not $state["task_states"] -or
        -not $state["task_states"].ContainsKey($resolvedTaskId)
    ) {
        return $null
    }

    $taskState = ConvertTo-RelayHashtable -InputObject $state["task_states"][$resolvedTaskId]
    return (ConvertTo-RelayHashtable -InputObject $taskState["task_contract_ref"])
}

function Append-RunStatusChangedEvent {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$RunState
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $currentTaskContractRef = Resolve-CurrentTaskContractRef -RunState $state -TaskId ([string]$state["current_task_id"])
    Append-Event -ProjectRoot $script:ProjectRoot -RunId $RunId -Event @{
        type = "run.status_changed"
        status = $state["status"]
        current_phase = $state["current_phase"]
        current_role = $state["current_role"]
        current_task_id = $state["current_task_id"]
        active_job_id = $state["active_job_id"]
        pending_approval = (ConvertTo-RelayHashtable -InputObject $state["pending_approval"])
        open_requirements = @($state["open_requirements"])
        task_order = @($state["task_order"])
        task_states = (ConvertTo-RelayHashtable -InputObject $state["task_states"])
        current_task_contract_ref = $currentTaskContractRef
    }
}

function Invoke-ManualStep {
    param(
        [Parameter(Mandatory)][string]$ResolvedRunId,
        [Parameter(Mandatory)][string]$PromptText
    )

    $providerSpec = Resolve-RoleProviderSpec -ResolvedRole $Role -ProviderName $Provider -ExplicitCommand $ProviderCommand -ExplicitFlags $ProviderFlags
    $jobSpec = @{
        run_id = $ResolvedRunId
        job_id = New-ExecutionJobId -Phase $Phase -Role $Role
        phase = $Phase
        role = $Role
        attempt = 1
        provider = $providerSpec["provider"]
        command = $providerSpec["command"]
        flags = $providerSpec["flags"]
        prompt_package = (Resolve-PromptPackage -ProjectRoot $script:ProjectRoot -Phase $Phase -Role $Role -Provider ([string]$providerSpec["provider"]))
    }

    return (Invoke-ExecutionRunner -JobSpec $jobSpec -PromptText $PromptText -ProjectRoot $script:ProjectRoot -WorkingDirectory $script:ProjectDir -TimeoutPolicy (Get-StepTimeoutPolicy))
}

function Invoke-EngineStep {
    param([Parameter(Mandatory)][string]$ResolvedRunId)

    $runState = Read-RunState -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId
    if (-not $runState) {
        throw "Run '$ResolvedRunId' does not exist."
    }
    $runState = Sync-RunStateFromCanonicalArtifacts -RunId $ResolvedRunId -RunState $runState
    $staleRepair = Repair-StaleActiveJobState -RunState $runState -ProjectRoot $script:ProjectRoot
    if ([bool]$staleRepair["changed"]) {
        $recoveredMetadata = ConvertTo-RelayHashtable -InputObject $staleRepair["job_metadata"]
        $recoveredJobId = [string]$runState["active_job_id"]
        $runState = ConvertTo-RelayHashtable -InputObject $staleRepair["run_state"]
        Write-RunState -ProjectRoot $script:ProjectRoot -RunState $runState | Out-Null
        Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $runState
        Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
            type = "job.recovered"
            job_id = $recoveredJobId
            reason = $staleRepair["reason"]
            metadata = $recoveredMetadata
        }
    }

    $failedRecovery = Repair-RecoverableFailedRunState -RunState $runState -ProjectRoot $script:ProjectRoot -RecoverySource "step"
    if ([bool]$failedRecovery["changed"]) {
        $runState = ConvertTo-RelayHashtable -InputObject $failedRecovery["run_state"]
        Write-RunState -ProjectRoot $script:ProjectRoot -RunState $runState | Out-Null
        Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $runState
        Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event $failedRecovery["recovery_event"]
    }

    $seededPhase0 = Invoke-SeededPhase0Step -ResolvedRunId $ResolvedRunId -RunState $runState
    if ($seededPhase0) {
        return $seededPhase0
    }

    $nextAction = Get-NextAction -RunState $runState -ProjectRoot $script:ProjectRoot
    switch ([string]$nextAction["type"]) {
        "DispatchJob" {
            $phaseName = [string]$nextAction["phase"]
            $resolvedRole = [string]$nextAction["role"]
            $taskId = [string]$nextAction["task_id"]
            $providerSpec = Resolve-RoleProviderSpec -ResolvedRole $resolvedRole -ProviderName $Provider -ExplicitCommand $ProviderCommand -ExplicitFlags $ProviderFlags
            $phaseDefinition = Get-PhaseDefinition -ProjectRoot $script:ProjectRoot -Phase $phaseName -Provider ([string]$providerSpec["provider"])

            $jobSpec = @{
                run_id = $ResolvedRunId
                job_id = New-ExecutionJobId -Phase $phaseName -Role $resolvedRole
                phase = $phaseName
                role = $resolvedRole
                task_id = $taskId
                attempt = 1
                provider = $providerSpec["provider"]
                command = $providerSpec["command"]
                flags = $providerSpec["flags"]
                prompt_package = $phaseDefinition["prompt_package"]
                selected_task = $nextAction["selected_task"]
            }

            $dispatchState = ConvertTo-RelayHashtable -InputObject $runState
            $dispatchState["status"] = "running"
            $dispatchState["active_job_id"] = $jobSpec["job_id"]
            $dispatchState = Set-RunStateCursor -RunState $dispatchState -Phase $phaseName -TaskId $taskId
            $dispatchState = Sync-RunStatePhaseHistory -RunState $dispatchState
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $dispatchState | Out-Null
            Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $dispatchState

            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "task.selected"
                    task_id = $taskId
                    phase = $phaseName
                    task_contract_ref = (Resolve-CurrentTaskContractRef -RunState $dispatchState -TaskId $taskId)
                }
            }

            $promptText = if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
                Get-Content -Path $PromptFile -Raw -Encoding UTF8
            }
            elseif (-not [string]::IsNullOrWhiteSpace($Prompt)) {
                $Prompt
            }
            else {
                New-EnginePromptText -RunState $dispatchState -Action $nextAction -JobSpec $jobSpec -PhaseDefinition $phaseDefinition
            }

            $phaseHistoryEntry = Get-CurrentPhaseHistoryEntry -RunState $dispatchState -PhaseName $phaseName -Role $resolvedRole
            $phaseStartedAtUtc = Convert-RelayDateTimeToUtc -Value ([string]$phaseHistoryEntry["started"])
            $script:ArtifactCompletionProbeState = @{
                run_id = $ResolvedRunId
                phase_name = $phaseName
                phase_definition = $phaseDefinition
                task_id = $taskId
                phase_started_at_utc = $phaseStartedAtUtc
            }
            try {
                $executionResult = Invoke-ExecutionRunner -JobSpec $jobSpec -PromptText $promptText -ProjectRoot $script:ProjectRoot -WorkingDirectory $script:ProjectDir -TimeoutPolicy (Get-StepTimeoutPolicy) -ArtifactCompletionProbe ${function:Invoke-PhaseArtifactCompletionProbe}
            }
            finally {
                $script:ArtifactCompletionProbeState = $null
            }
            $outputSync = Sync-PhaseOutputArtifacts -RunId $ResolvedRunId -PhaseName $phaseName -PhaseDefinition $phaseDefinition -TaskId $taskId
            $validationResult = Resolve-StepValidation -RunId $ResolvedRunId -PhaseName $phaseName -PhaseDefinition $phaseDefinition -OutputSyncResult $outputSync -TaskId $taskId

            if ($validationResult["validator_ref"]) {
                $validatorRef = ConvertTo-RelayHashtable -InputObject $validationResult["validator_ref"]
                $validatorStatus = ConvertTo-RelayHashtable -InputObject $validationResult["validation"]
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "artifact.validated"
                    phase = $phaseName
                    task_id = $taskId
                    artifact_id = $validatorRef["artifact_id"]
                    valid = if ($validatorStatus) { [bool]$validatorStatus["valid"] } else { $true }
                    errors = if ($validatorStatus) { @($validatorStatus["errors"]) } else { @() }
                    warnings = if ($validatorStatus) { @($validatorStatus["warnings"]) } else { @() }
                }
            }

            $effectiveResultResolution = Resolve-EffectiveExecutionResult -ExecutionResult $executionResult -ValidationResult $validationResult["validation"]
            $effectiveExecutionResult = ConvertTo-RelayHashtable -InputObject $effectiveResultResolution["execution_result"]
            if ([bool]$effectiveResultResolution["recovered_from_timeout"]) {
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "job.timeout_recovered"
                    job_id = $jobSpec["job_id"]
                    phase = $phaseName
                    task_id = $taskId
                }
            }
            if ([bool]$effectiveExecutionResult["recovered_from_artifacts"]) {
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "job.artifact_completion_recovered"
                    job_id = $jobSpec["job_id"]
                    phase = $phaseName
                    task_id = $taskId
                    artifact_completion = (ConvertTo-RelayHashtable -InputObject $effectiveExecutionResult["artifact_completion"])
                }
            }

            $mutation = Apply-JobResult -RunState $dispatchState -JobResult $effectiveExecutionResult -ValidationResult $validationResult["validation"] -Artifact $validationResult["artifact"] -ProjectRoot $script:ProjectRoot -ApprovalPhases $script:HumanReviewPhases
            $nextRunState = ConvertTo-RelayHashtable -InputObject $mutation["run_state"]
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $nextRunState | Out-Null
            Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $nextRunState

            $mutationAction = ConvertTo-RelayHashtable -InputObject $mutation["action"]
            foreach ($spawnedTask in @($mutation["spawned_tasks"])) {
                $spawnedTaskObject = ConvertTo-RelayHashtable -InputObject $spawnedTask
                $spawnedTaskState = $null
                if (
                    -not [string]::IsNullOrWhiteSpace([string]$spawnedTaskObject["task_id"]) -and
                    $nextRunState["task_states"] -and
                    $nextRunState["task_states"].ContainsKey([string]$spawnedTaskObject["task_id"])
                ) {
                    $spawnedTaskState = ConvertTo-RelayHashtable -InputObject $nextRunState["task_states"][[string]$spawnedTaskObject["task_id"]]
                }
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "task.spawned"
                    origin_phase = $phaseName
                    task_id = $spawnedTaskObject["task_id"]
                    task_kind = "repair"
                    task_contract_ref = if ($spawnedTaskState) { $spawnedTaskState["task_contract_ref"] } else { $null }
                    depends_on = if ($spawnedTaskState) { @($spawnedTaskState["depends_on"]) } else { @($spawnedTaskObject["depends_on"]) }
                }
            }

            $completedTaskState = $null
            if (
                -not [string]::IsNullOrWhiteSpace($taskId) -and
                $nextRunState["task_states"] -and
                $nextRunState["task_states"].ContainsKey($taskId)
            ) {
                $completedTaskState = ConvertTo-RelayHashtable -InputObject $nextRunState["task_states"][$taskId]
            }

            if (
                $phaseName -eq "Phase6" -and
                -not [string]::IsNullOrWhiteSpace($taskId) -and
                [string]$mutationAction["type"] -ne "FailRun" -and
                $completedTaskState -and
                [string]$completedTaskState["status"] -eq "completed"
            ) {
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "task.completed"
                    phase = $phaseName
                    task_id = $taskId
                    task_contract_ref = $completedTaskState["task_contract_ref"]
                }
            }

            switch ([string]$mutationAction["type"]) {
                "Continue" {
                    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                        type = "phase.transitioned"
                        from_phase = $phaseName
                        to_phase = $mutationAction["next_phase"]
                        task_id = $mutationAction["next_task_id"]
                    }
                }
                "RequestApproval" {
                    $pendingApproval = ConvertTo-RelayHashtable -InputObject $mutationAction["pending_approval"]
                    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                        type = "approval.requested"
                        approval_id = $pendingApproval["approval_id"]
                        requested_phase = $pendingApproval["requested_phase"]
                        requested_role = $pendingApproval["requested_role"]
                        requested_task_id = $pendingApproval["requested_task_id"]
                        proposed_action = $pendingApproval["proposed_action"]
                    }
                }
                "FailRun" {
                    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                        type = "run.failed"
                        reason = $mutationAction["reason"]
                        failure_class = $effectiveExecutionResult["failure_class"]
                    }
                }
                "CompleteRun" {
                    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                        type = "run.completed"
                    }
                }
            }

            return @{
                mode = "engine"
                action = $nextAction
                job = $effectiveExecutionResult
                validation = $validationResult["validation"]
                output_sync = $outputSync
                mutation_action = $mutationAction
                run_state = $nextRunState
            }
        }
        "RequestApproval" {
            $decision = Read-StepApprovalDecision -ApprovalRequest $nextAction["pending_approval"] -DecisionJson $ApprovalDecisionJson -DecisionFile $ApprovalDecisionFile
            $applied = Apply-ApprovalDecision -RunState $runState -ApprovalDecision $decision
            $nextRunState = ConvertTo-RelayHashtable -InputObject $applied["run_state"]
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $nextRunState | Out-Null
            Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $nextRunState

            $pendingApproval = ConvertTo-RelayHashtable -InputObject $nextAction["pending_approval"]
            Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                type = "approval.resolved"
                approval_id = $pendingApproval["approval_id"]
                decision = $decision["decision"]
                target_phase = $decision["target_phase"]
                target_task_id = $decision["target_task_id"]
                must_fix = $decision["must_fix"]
                comment = $decision["comment"]
                applied_action = $applied["applied_action"]
                pending_approval = $false
            }

            $appliedAction = ConvertTo-RelayHashtable -InputObject $applied["applied_action"]
            if ([string]$appliedAction["type"] -eq "DispatchJob") {
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = "phase.transitioned"
                    from_phase = $pendingApproval["requested_phase"]
                    to_phase = $appliedAction["phase"]
                    task_id = $appliedAction["task_id"]
                }
            }

            return @{
                mode = "engine"
                action = $nextAction
                approval_decision = $decision
                applied_action = $appliedAction
                run_state = $nextRunState
            }
        }
        default {
            return @{
                mode = "engine"
                action = $nextAction
                run_state = $runState
            }
        }
    }
}

switch ($Command) {
    "new" {
        Initialize-LegacyDirectories
        $resolvedRunId = if ($RunId) { $RunId } else { New-RunId }
        $runState = New-RunState -RunId $resolvedRunId -ProjectRoot $script:ProjectDir -TaskId $TaskId -CurrentPhase $CurrentPhase -CurrentRole $CurrentRole
        $runState["compatibility_name"] = Resolve-InitialCompatibilityRequirementName -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId -TaskId $TaskId
        Write-RunState -ProjectRoot $script:ProjectRoot -RunState $runState | Out-Null
        Set-CurrentRunPointer -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId | Out-Null
        Append-Event -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId -Event @{ type = "run.created" }
        Append-RunStatusChangedEvent -RunId $resolvedRunId -RunState $runState
        Write-Output $resolvedRunId
    }
    "resume" {
        Initialize-LegacyDirectories
        $resolvedRunId = if ($RunId) { $RunId } else { Resolve-ActiveRunId -ProjectRoot $script:ProjectRoot }
        if (-not $resolvedRunId) {
            $resolvedRunId = New-RunId
            $seedState = New-RunState -RunId $resolvedRunId -ProjectRoot $script:ProjectDir -TaskId $TaskId -CurrentPhase $CurrentPhase -CurrentRole $CurrentRole
            $seedState["compatibility_name"] = Resolve-InitialCompatibilityRequirementName -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId -TaskId $TaskId
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $seedState | Out-Null
            Append-Event -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId -Event @{ type = "run.created"; recovered = $true }
            Append-RunStatusChangedEvent -RunId $resolvedRunId -RunState $seedState
        }
        Set-CurrentRunPointer -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId | Out-Null
        $resumeState = Read-RunState -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId
        if ($resumeState) {
            $failedRecovery = Repair-RecoverableFailedRunState -RunState $resumeState -ProjectRoot $script:ProjectRoot -RecoverySource "resume"
            if ([bool]$failedRecovery["changed"]) {
                $resumeState = ConvertTo-RelayHashtable -InputObject $failedRecovery["run_state"]
                Write-RunState -ProjectRoot $script:ProjectRoot -RunState $resumeState | Out-Null
                Append-RunStatusChangedEvent -RunId $resolvedRunId -RunState $resumeState
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId -Event $failedRecovery["recovery_event"]
            }
        }
        Write-Output $resolvedRunId
    }
    "step" {
        $resolvedRunId = Resolve-StepRunId -RequestedRunId $RunId
        if (-not $resolvedRunId) {
            throw "No active run."
        }

        $runLock = $null
        try {
            $runLock = Acquire-RunLock -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId -RetryCount $script:LockRetryCount -RetryDelayMs $script:LockRetryDelay -TimeoutSec $script:LockTimeout

            $result = if (-not [string]::IsNullOrWhiteSpace($PromptFile) -or -not [string]::IsNullOrWhiteSpace($Prompt)) {
                $promptText = if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
                    Get-Content -Path $PromptFile -Raw -Encoding UTF8
                }
                else {
                    $Prompt
                }
                Invoke-ManualStep -ResolvedRunId $resolvedRunId -PromptText $promptText
            }
            else {
                Invoke-EngineStep -ResolvedRunId $resolvedRunId
            }

            $result | ConvertTo-Json -Depth 20 -Compress
        }
        finally {
            Release-RunLock -LockHandle $runLock
        }
    }
    "show" {
        $resolvedRunId = Resolve-StepRunId -RequestedRunId $RunId
        if (-not $resolvedRunId) {
            Write-Output "No active run"
            exit 0
        }
        $state = Read-RunState -ProjectRoot $script:ProjectRoot -RunId $resolvedRunId
        Write-Output ($state | ConvertTo-Json -Depth 20 -Compress)
    }
}
