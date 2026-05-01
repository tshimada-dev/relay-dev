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
. (Join-Path $script:ProjectRoot "app/core/job-context-builder.ps1")
. (Join-Path $script:ProjectRoot "app/core/attempt-preparation.ps1")
. (Join-Path $script:ProjectRoot "app/core/phase-validation-pipeline.ps1")
. (Join-Path $script:ProjectRoot "app/core/phase-completion-committer.ps1")
. (Join-Path $script:ProjectRoot "app/core/phase-execution-transaction.ps1")
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

    $canRecover = $false
    if ($failureReason -eq "job_failed" -and $failureClass -in @("provider_error", "timeout")) {
        $canRecover = $true
    }
    elseif (
        $failureReason -eq "invalid_artifact" -and
        $lastJobFinishedEvent -and
        [string]$lastJobFinishedEvent["result_status"] -eq "succeeded"
    ) {
        $canRecover = $true
    }

    if (-not $canRecover) {
        return @{
            changed = $false
            run_state = $state
            recovery_event = $null
        }
    }

    $state["status"] = "running"
    $state["feedback"] = ""
    $state["updated_at"] = (Get-Date).ToString("o")
    $state = Clear-RunStateActiveAttempt -RunState $state -Status "recovered" -Result "retry_same_phase"
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
        [string]$TaskId,
        [string]$JobId,
        [string]$AttemptId,
        [ValidateSet("canonical", "job", "attempt")][string]$StorageScope = "canonical",
        [switch]$PreferJobArtifacts
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
    $useJobArtifacts = (
        $PreferJobArtifacts -and
        -not [string]::IsNullOrWhiteSpace($JobId) -and
        $sourcePhase -eq $PhaseName
    )
    if ($scope -eq "task") {
        if ($StorageScope -ne "canonical" -and $sourcePhase -eq $PhaseName) {
            return (Resolve-StagedArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -StorageScope $StorageScope -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $TaskId -JobId $JobId -AttemptId $AttemptId)
        }

        if ($useJobArtifacts) {
            return (Resolve-StagedArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -StorageScope "job" -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $TaskId -JobId $JobId)
        }

        return (Get-ArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $TaskId)
    }

    if ($StorageScope -ne "canonical" -and $sourcePhase -eq $PhaseName) {
        return (Resolve-StagedArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -StorageScope $StorageScope -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -JobId $JobId -AttemptId $AttemptId)
    }

    if ($useJobArtifacts) {
        return (Resolve-StagedArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -StorageScope "job" -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -JobId $JobId)
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
        [string]$TaskId,
        [string]$JobId,
        [string]$AttemptId,
        [ValidateSet("canonical", "job", "attempt")][string]$StorageScope = "canonical",
        [AllowNull()][datetime]$AttemptStartedAtUtc
    )

    return (Get-PhaseMaterializedArtifacts -ProjectRoot $script:ProjectRoot -RunId $RunId -PhaseName $PhaseName -PhaseDefinition $PhaseDefinition -TaskId $TaskId -JobId $JobId -AttemptId $AttemptId -StorageScope $StorageScope -AttemptStartedAtUtc $AttemptStartedAtUtc)
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

function Get-RelayAttemptPromptToken {
    return "__RELAY_ATTEMPT_ID__"
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
        [string]$JobId,
        [string]$AttemptId,
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

        $path = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId -JobId $JobId -AttemptId $AttemptId -StorageScope $(if (-not [string]::IsNullOrWhiteSpace($AttemptId)) { "attempt" } elseif (-not [string]::IsNullOrWhiteSpace($JobId)) { "job" } else { "canonical" }) -PreferJobArtifacts:([bool](-not [string]::IsNullOrWhiteSpace($JobId)))
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
                    $validatorPath = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId -JobId $JobId -AttemptId $AttemptId -StorageScope $(if (-not [string]::IsNullOrWhiteSpace($AttemptId)) { "attempt" } elseif (-not [string]::IsNullOrWhiteSpace($JobId)) { "job" } else { "canonical" }) -PreferJobArtifacts:([bool](-not [string]::IsNullOrWhiteSpace($JobId)))
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($validatorPath)) {
                if (-not [string]::IsNullOrWhiteSpace($AttemptId)) {
                    if ([string]$validatorRef["scope"] -eq "task") {
                        $validatorPath = Get-AttemptArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -JobId $JobId -AttemptId $AttemptId -Scope "task" -Phase ([string]$validatorRef["phase"]) -ArtifactId $validatorArtifactId -TaskId ([string]$validatorRef["task_id"])
                    }
                    else {
                        $validatorPath = Get-AttemptArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -JobId $JobId -AttemptId $AttemptId -Scope ([string]$validatorRef["scope"]) -Phase ([string]$validatorRef["phase"]) -ArtifactId $validatorArtifactId
                    }
                }
                elseif (-not [string]::IsNullOrWhiteSpace($JobId)) {
                    if ([string]$validatorRef["scope"] -eq "task") {
                        $validatorPath = Get-JobArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -JobId $JobId -Scope "task" -Phase ([string]$validatorRef["phase"]) -ArtifactId $validatorArtifactId -TaskId ([string]$validatorRef["task_id"])
                    }
                    else {
                        $validatorPath = Get-JobArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -JobId $JobId -Scope ([string]$validatorRef["scope"]) -Phase ([string]$validatorRef["phase"]) -ArtifactId $validatorArtifactId
                    }
                }
                elseif ([string]$validatorRef["scope"] -eq "task") {
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
            $artifact = Read-ArtifactContentFromPath -Path $validatorPath
            $validationSnapshot = ConvertTo-RelayHashtable -InputObject (Get-ArtifactValidationSnapshot -ArtifactId $validatorArtifactId -Artifact $artifact -Phase $PhaseName)
            $validation = ConvertTo-RelayHashtable -InputObject $validationSnapshot["validation"]
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
        $attemptId = if ($probe["attempt"]) { Get-ExecutionAttemptId -Attempt ([int]$probe["attempt"]) } else { $null }
        return (Test-PhaseArtifactCompletion -RunId ([string]$probeState["run_id"]) -PhaseName ([string]$probeState["phase_name"]) -PhaseDefinition $probeState["phase_definition"] -JobId ([string]$probeState["job_id"]) -AttemptId $attemptId -TaskId ([string]$probeState["task_id"]) -PhaseStartedAtUtc $probeState["phase_started_at_utc"] -AttemptStartedAtUtc $attemptStartedAtUtc)
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

    return (Invoke-PhaseValidationPipeline -PhaseName $PhaseName -PhaseDefinition $PhaseDefinition -MaterializedArtifacts @($OutputSyncResult["materialized"]) -MissingRequired @($OutputSyncResult["missing_required"]) -StaleRequired @($OutputSyncResult["stale_required"]) -ReadErrors @($OutputSyncResult["read_errors"]) -TaskId $TaskId)
}

function Format-ContractPromptLines {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$ContractItems,
        [string]$TaskId,
        [string]$JobId,
        [string]$AttemptId,
        [ValidateSet("canonical", "job", "attempt")][string]$StorageScope = "canonical",
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
        $path = Resolve-ContractArtifactPath -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId -JobId $JobId -AttemptId $AttemptId -StorageScope $StorageScope -PreferJobArtifacts:([bool]($OutputMode -and -not [string]::IsNullOrWhiteSpace($JobId)))
        $status = if ($OutputMode) { "write" } else { if (Test-Path $path) { "exists" } else { "missing" } }
        $lines.Add("- [$requiredLabel][$scope][$format] $artifactId => $path ($status)")
    }

    return @($lines)
}

function Format-ArchivedPhaseJsonContextLines {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId,
        $ArchivedContext
    )

    $context = if ($PSBoundParameters.ContainsKey("ArchivedContext") -and $null -ne $ArchivedContext) {
        ConvertTo-RelayHashtable -InputObject $ArchivedContext
    }
    else {
        $scope = if (Test-TaskScopedPhase -Phase $PhaseName) { "task" } else { "run" }
        if ($scope -eq "task" -and [string]::IsNullOrWhiteSpace($TaskId)) {
            return @()
        }

        ConvertTo-RelayHashtable -InputObject (Get-LatestArchivedJsonContext -ProjectRoot $script:ProjectRoot -RunId $RunId -Scope $scope -Phase $PhaseName -TaskId $TaskId)
    }

    $refs = @($context["archived_context_refs"])
    if ($refs.Count -eq 0) {
        return @()
    }

    return @(Format-ArchivedJsonContextPromptLines -ArchivedContext $context)
}

function Save-StagedPromptContextArtifact {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)]$Content,
        [string]$TaskId,
        [switch]$AsJson
    )

    $path = Resolve-StagedArtifactPath -ProjectRoot $script:ProjectRoot -RunId $RunId -StorageScope "job" -Scope $Scope -Phase $PhaseName -ArtifactId $ArtifactId -TaskId $TaskId -JobId $JobId
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $serialized = if ($AsJson) {
        (ConvertTo-RelayHashtable -InputObject $Content) | ConvertTo-Json -Depth 20
    }
    else {
        [string]$Content
    }

    $tempPath = "${path}.tmp"
    Set-Content -Path $tempPath -Value $serialized -Encoding UTF8
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
    Move-Item -LiteralPath $tempPath -Destination $path -Force
    return $path
}

function Get-RelevantOpenRequirementsForPrompt {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $allRequirements = @($state["open_requirements"])
    $relevant = New-Object System.Collections.Generic.List[object]
    $omittedIds = New-Object System.Collections.Generic.List[string]
    $isTaskScopedPhase = Test-TaskScopedPhase -Phase $PhaseName

    foreach ($requirementRaw in $allRequirements) {
        $requirement = ConvertTo-RelayHashtable -InputObject $requirementRaw
        $sourceTaskId = [string]$requirement["source_task_id"]
        $isGlobalRequirement = [string]::IsNullOrWhiteSpace($sourceTaskId)
        $isCurrentTaskRequirement = -not [string]::IsNullOrWhiteSpace($TaskId) -and $sourceTaskId -eq $TaskId
        $matchesCurrentPhase = [string]$requirement["verify_in_phase"] -eq $PhaseName

        $include = if ($isTaskScopedPhase) {
            $isGlobalRequirement -or $isCurrentTaskRequirement
        }
        else {
            $isGlobalRequirement -or $matchesCurrentPhase
        }

        if ($include) {
            $relevant.Add($requirement) | Out-Null
            continue
        }

        $itemId = [string]$requirement["item_id"]
        if ([string]::IsNullOrWhiteSpace($itemId)) {
            $itemId = "<no-item-id>"
        }
        $omittedIds.Add($itemId) | Out-Null
    }

    return [ordered]@{
        total_count = $allRequirements.Count
        relevant = @($relevant.ToArray())
        relevant_count = $relevant.Count
        omitted_count = $omittedIds.Count
        omitted_item_ids = @($omittedIds.ToArray())
        is_task_scoped_phase = $isTaskScopedPhase
    }
}

function Get-SelectedTaskChangedFileMetadata {
    param([AllowNull()]$SelectedTask)

    $task = ConvertTo-RelayHashtable -InputObject $SelectedTask
    $metadata = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($changedFileRaw in @($task["changed_files"])) {
        $rawText = [string]$changedFileRaw
        if ([string]::IsNullOrWhiteSpace($rawText)) {
            continue
        }

        $normalizedPath = $rawText.Trim()
        foreach ($delimiter in @("（", "(")) {
            $delimiterIndex = $normalizedPath.IndexOf($delimiter)
            if ($delimiterIndex -gt 0) {
                $normalizedPath = $normalizedPath.Substring(0, $delimiterIndex).Trim()
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
            $normalizedPath = $rawText.Trim()
        }

        $key = $normalizedPath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $leafName = Split-Path -Leaf ($normalizedPath -replace '/', '\')
        $metadata.Add([ordered]@{
                raw = $rawText.Trim()
                path = $normalizedPath
                leaf = $leafName
            }) | Out-Null
    }

    return @($metadata.ToArray())
}

function Get-SuggestedChangedFilesForOpenRequirement {
    param(
        [Parameter(Mandatory)]$Requirement,
        [Parameter(Mandatory)][object[]]$ChangedFileMetadata,
        [string]$CurrentTaskId
    )

    $requirementObject = ConvertTo-RelayHashtable -InputObject $Requirement
    $description = [string]$requirementObject["description"]
    $sourceTaskId = [string]$requirementObject["source_task_id"]
    $matches = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($entryRaw in @($ChangedFileMetadata)) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        $pathCandidate = [string]$entry["path"]
        $leafCandidate = [string]$entry["leaf"]
        $isMatch = $false

        foreach ($candidate in @($pathCandidate, $leafCandidate)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            if ($description.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $isMatch = $true
                break
            }
        }

        if (-not $isMatch) {
            continue
        }

        $key = $pathCandidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $matches.Add($pathCandidate) | Out-Null
    }

    if ($matches.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($CurrentTaskId) -and $sourceTaskId -eq $CurrentTaskId) {
        foreach ($entryRaw in @($ChangedFileMetadata)) {
            $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
            $pathCandidate = [string]$entry["path"]
            if ([string]::IsNullOrWhiteSpace($pathCandidate)) {
                continue
            }

            $key = $pathCandidate.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }

            $seen[$key] = $true
            $matches.Add($pathCandidate) | Out-Null
        }
    }

    return @($matches.ToArray())
}

function New-SelectedTaskOpenRequirementOverlay {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$SelectedTask,
        [Parameter(Mandatory)]$JobSpec
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $task = ConvertTo-RelayHashtable -InputObject $SelectedTask
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $taskId = [string]$task["task_id"]
    $phaseName = [string]$job["phase"]

    if ([string]::IsNullOrWhiteSpace($taskId) -or -not (Test-TaskScopedPhase -Phase $phaseName)) {
        return $null
    }

    $selection = ConvertTo-RelayHashtable -InputObject (Get-RelevantOpenRequirementsForPrompt -RunState $state -PhaseName $phaseName -TaskId $taskId)
    $changedFileMetadata = @(Get-SelectedTaskChangedFileMetadata -SelectedTask $task)
    $overlayItems = New-Object System.Collections.Generic.List[object]
    $nonOverlayItemIds = New-Object System.Collections.Generic.List[string]

    foreach ($requirementRaw in @($selection["relevant"])) {
        $requirement = ConvertTo-RelayHashtable -InputObject $requirementRaw
        $itemId = [string]$requirement["item_id"]
        $verifyInPhase = [string]$requirement["verify_in_phase"]
        $description = [string]$requirement["description"]
        $requiredArtifacts = @(
            @($requirement["required_artifacts"]) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $suggestedChangedFiles = @(Get-SuggestedChangedFilesForOpenRequirement -Requirement $requirement -ChangedFileMetadata $changedFileMetadata -CurrentTaskId $taskId)
        $sourceTaskId = [string]$requirement["source_task_id"]
        $isCurrentTaskRequirement = -not [string]::IsNullOrWhiteSpace($sourceTaskId) -and $sourceTaskId -eq $taskId
        $isOverlayCandidate = $isCurrentTaskRequirement -or $suggestedChangedFiles.Count -gt 0

        if (-not $isOverlayCandidate) {
            if (-not [string]::IsNullOrWhiteSpace($itemId)) {
                $nonOverlayItemIds.Add($itemId) | Out-Null
            }
            continue
        }

        $additionalAcceptanceCriteria = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($description)) {
            $additionalAcceptanceCriteria.Add($description) | Out-Null
        }
        if ($suggestedChangedFiles.Count -gt 0) {
            $additionalAcceptanceCriteria.Add("解消の主対象が Selected Task.changed_files の範囲に収まり、次の変更候補で確認できること: $($suggestedChangedFiles -join ', ')") | Out-Null
        }
        if ($requiredArtifacts.Count -gt 0) {
            $additionalAcceptanceCriteria.Add("後続の $verifyInPhase で $($requiredArtifacts -join ', ') を根拠 artifact として解消確認できること") | Out-Null
        }

        $verification = New-Object System.Collections.Generic.List[string]
        if ($suggestedChangedFiles.Count -gt 0) {
            $verification.Add("実装変更を確認: $($suggestedChangedFiles -join ', ')") | Out-Null
        }
        if ($requiredArtifacts.Count -gt 0) {
            $verification.Add("次回 $verifyInPhase で次の artifact を照合: $($requiredArtifacts -join ', ')") | Out-Null
        }
        else {
            $verification.Add("次回 $verifyInPhase で関連コードと phase artifact を照合して解消確認する") | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($itemId)) {
            $verification.Add("解消した場合は後続 verdict artifact の resolved_requirement_ids に '$itemId' を記録できる状態にする") | Out-Null
        }

        $overlayItems.Add([ordered]@{
                item_id = $itemId
                source_phase = [string]$requirement["source_phase"]
                source_task_id = $sourceTaskId
                verify_in_phase = $verifyInPhase
                required_artifacts = $requiredArtifacts
                description = $description
                additional_acceptance_criteria = @($additionalAcceptanceCriteria.ToArray())
                verification = @($verification.ToArray())
                suggested_changed_files = $suggestedChangedFiles
            }) | Out-Null
    }

    if ($overlayItems.Count -eq 0) {
        return $null
    }

    $overlayArtifactId = "open_requirement_overlay.json"
    $overlayArtifactContent = [ordered]@{
        generated_at = (Get-Date).ToString("o")
        run_id = [string]$job["run_id"]
        job_id = [string]$job["job_id"]
        phase = $phaseName
        task_id = $taskId
        overlay_policy = "Actionable task-scoped subset distilled from relevant open requirements. Actual run-state closure still requires downstream resolved_requirement_ids."
        relevant_item_ids = @(
            @($selection["relevant"]) |
                ForEach-Object {
                    $requirement = ConvertTo-RelayHashtable -InputObject $_
                    [string]$requirement["item_id"]
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        non_overlay_relevant_item_ids = @($nonOverlayItemIds.ToArray())
        overlay_items = @($overlayItems.ToArray())
    }
    $overlayArtifactPath = Save-StagedPromptContextArtifact -RunId ([string]$job["run_id"]) -JobId ([string]$job["job_id"]) -PhaseName $phaseName -Scope "task" -ArtifactId $overlayArtifactId -TaskId $taskId -Content $overlayArtifactContent -AsJson

    return [ordered]@{
        artifact_path = $overlayArtifactPath
        overlay = [ordered]@{
            artifact_ref = $overlayArtifactPath
            note = "This overlay is a task-scoped addendum distilled from relevant open requirements. It narrows actionable carry-forward work but does not authorize boundary expansion. Actual run-state closure still happens only when a later verdict artifact records resolved_requirement_ids."
            non_overlay_relevant_item_ids = @($nonOverlayItemIds.ToArray())
            items = @($overlayItems.ToArray())
        }
    }
}

function New-OpenRequirementsPromptSection {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$JobSpec,
        [AllowNull()]$TaskOpenRequirementOverlay
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $phaseName = [string]$job["phase"]
    $taskId = [string]$job["task_id"]
    $selection = ConvertTo-RelayHashtable -InputObject (Get-RelevantOpenRequirementsForPrompt -RunState $state -PhaseName $phaseName -TaskId $taskId)

    if ([int]$selection["total_count"] -eq 0) {
        return $null
    }

    $artifactScope = if ([bool]$selection["is_task_scoped_phase"] -and -not [string]::IsNullOrWhiteSpace($taskId)) { "task" } else { "run" }
    $allRequirementsArtifactId = "open_requirements_full.json"
    $allRequirementsArtifactContent = [ordered]@{
        generated_at = (Get-Date).ToString("o")
        run_id = [string]$job["run_id"]
        job_id = [string]$job["job_id"]
        phase = $phaseName
        task_id = if ([string]::IsNullOrWhiteSpace($taskId)) { $null } else { $taskId }
        total_open_requirements = [int]$selection["total_count"]
        unresolved_open_requirements = @($state["open_requirements"])
    }
    $allRequirementsArtifactPath = Save-StagedPromptContextArtifact -RunId ([string]$job["run_id"]) -JobId ([string]$job["job_id"]) -PhaseName $phaseName -Scope $artifactScope -ArtifactId $allRequirementsArtifactId -TaskId $taskId -Content $allRequirementsArtifactContent -AsJson

    $relevantArtifactId = "open_requirements_context.json"
    $relevantArtifactContent = [ordered]@{
        generated_at = (Get-Date).ToString("o")
        run_id = [string]$job["run_id"]
        job_id = [string]$job["job_id"]
        phase = $phaseName
        task_id = if ([string]::IsNullOrWhiteSpace($taskId)) { $null } else { $taskId }
        total_open_requirements = [int]$selection["total_count"]
        relevant_open_requirements = @($selection["relevant"])
        omitted_open_requirement_ids = @($selection["omitted_item_ids"])
        selection_policy = [ordered]@{
            phase_scope = if ([bool]$selection["is_task_scoped_phase"]) { "task" } else { "run" }
            include_global_requirements = $true
            include_current_task_requirements = [bool]$selection["is_task_scoped_phase"]
            include_current_phase_requirements = -not [bool]$selection["is_task_scoped_phase"]
        }
    }
    $relevantArtifactPath = Save-StagedPromptContextArtifact -RunId ([string]$job["run_id"]) -JobId ([string]$job["job_id"]) -PhaseName $phaseName -Scope $artifactScope -ArtifactId $relevantArtifactId -TaskId $taskId -Content $relevantArtifactContent -AsJson

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("Prompt size is intentionally bounded here. Read the JSON artifact for full relevant requirement details.") | Out-Null
    $summaryLines.Add("- total open requirements in run-state: $([int]$selection["total_count"])") | Out-Null
    $summaryLines.Add("- relevant to this prompt: $([int]$selection["relevant_count"])") | Out-Null
    $summaryLines.Add("- selection policy: $(if ([bool]$selection["is_task_scoped_phase"]) { "global + current task requirements" } else { "global + current phase requirements" })") | Out-Null
    $summaryLines.Add("- role-scoped relevant requirement JSON: $relevantArtifactPath") | Out-Null
    $summaryLines.Add("- full unresolved requirement JSON: $allRequirementsArtifactPath") | Out-Null
    if ([int]$selection["omitted_count"] -gt 0) {
        $summaryLines.Add("- omitted from inline prompt as unrelated here: $([int]$selection["omitted_count"])") | Out-Null
    }
    if ([string]$job["role"] -in @("implementer", "repairer")) {
        $summaryLines.Add("- if you can resolve carry-forward items in this task, inspect the full unresolved requirement JSON before stopping") | Out-Null
    }
    $overlayInfo = ConvertTo-RelayHashtable -InputObject $TaskOpenRequirementOverlay
    if ($overlayInfo -and $overlayInfo["artifact_path"]) {
        $overlayObject = ConvertTo-RelayHashtable -InputObject $overlayInfo["overlay"]
        $overlayItems = @($overlayObject["items"])
        if ($overlayItems.Count -gt 0) {
            $summaryLines.Add("- task-scoped actionable overlay JSON: $([string]$overlayInfo['artifact_path'])") | Out-Null
            $overlayItemIds = @(
                $overlayItems |
                    ForEach-Object {
                        $overlayItem = ConvertTo-RelayHashtable -InputObject $_
                        [string]$overlayItem["item_id"]
                    } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            if ($overlayItemIds.Count -gt 0) {
                $summaryLines.Add("- overlay item_ids in Selected Task.open_requirement_overlay: $($overlayItemIds -join ', ')") | Out-Null
            }
        }
    }

    $relevantItemIds = @(
        @($selection["relevant"]) |
            ForEach-Object {
                $requirement = ConvertTo-RelayHashtable -InputObject $_
                [string]$requirement["item_id"]
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($relevantItemIds.Count -gt 0) {
        $visibleIds = if ($relevantItemIds.Count -gt 8) { @($relevantItemIds[0..7]) } else { $relevantItemIds }
        $suffix = if ($relevantItemIds.Count -gt $visibleIds.Count) { " (+$($relevantItemIds.Count - $visibleIds.Count) more)" } else { "" }
        $summaryLines.Add("- relevant item_ids: $($visibleIds -join ", ")$suffix") | Out-Null
    }

    return "## Relevant Open Requirements`n$($summaryLines -join "`n")"
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

    $archivedContextLines = Format-ArchivedPhaseJsonContextLines -RunId ([string]$job["run_id"]) -PhaseName ([string]$job["phase"]) -TaskId ([string]$job["task_id"]) -ArchivedContext $job["archived_context"]
    if ($archivedContextLines.Count -gt 0) {
        $archivedContextIntro = @(
            "These are the most recent archived JSON artifacts for this same phase from before the current rerun."
            "Read them as prior-version context only. Do not treat them as the current required outputs."
        )
        $sections.Add("## Archived Phase JSON Context$promptLineBreak$($archivedContextIntro -join $promptLineBreak)$promptLineBreak$($archivedContextLines -join $promptLineBreak)")
    }

    $outputLines = Format-ContractPromptLines -RunId ([string]$job["run_id"]) -PhaseName ([string]$job["phase"]) -ContractItems $definition["output_contract"] -TaskId ([string]$job["task_id"]) -JobId ([string]$job["job_id"]) -AttemptId ([string]$job["attempt_id"]) -StorageScope $(if (-not [string]::IsNullOrWhiteSpace([string]$job["attempt_id"])) { "attempt" } elseif (-not [string]::IsNullOrWhiteSpace([string]$job["job_id"])) { "job" } else { "canonical" }) -OutputMode
    if ($outputLines.Count -gt 0) {
        $sections.Add("## Required Outputs$promptLineBreak$($outputLines -join $promptLineBreak)")
    }

    if ($engineAction["selected_task"]) {
        $selectedTaskForPrompt = ConvertTo-RelayHashtable -InputObject $engineAction["selected_task"]
        $taskOpenRequirementOverlay = New-SelectedTaskOpenRequirementOverlay -RunState $state -SelectedTask $selectedTaskForPrompt -JobSpec $job
        if ($taskOpenRequirementOverlay -and $taskOpenRequirementOverlay["overlay"]) {
            $selectedTaskForPrompt["open_requirement_overlay"] = $taskOpenRequirementOverlay["overlay"]
        }
        $selectedTaskJson = $selectedTaskForPrompt | ConvertTo-Json -Depth 20
        $sections.Add("## Selected Task`n$selectedTaskJson")
    }

    if (@($state["open_requirements"]).Count -gt 0) {
        $openRequirementsSection = New-OpenRequirementsPromptSection -RunState $state -JobSpec $job -TaskOpenRequirementOverlay $taskOpenRequirementOverlay
        if (-not [string]::IsNullOrWhiteSpace($openRequirementsSection)) {
            $sections.Add($openRequirementsSection)
        }
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

    $plannedTasksSnapshot = ConvertTo-RelayHashtable -InputObject (Get-ArtifactRefValidationSnapshot -ProjectRoot $script:ProjectRoot -RunId $RunId -ArtifactRef @{
        scope = "run"
        phase = "Phase4"
        artifact_id = "phase4_tasks.json"
    })
    if ($plannedTasksSnapshot["artifact"] -and [bool]$plannedTasksSnapshot["validation"]["valid"]) {
        $state = Register-PlannedTasks -RunState $state -TasksArtifact $plannedTasksSnapshot["artifact"]
    }

    $phase7VerdictSnapshot = ConvertTo-RelayHashtable -InputObject (Get-ArtifactRefValidationSnapshot -ProjectRoot $script:ProjectRoot -RunId $RunId -ArtifactRef @{
        scope = "run"
        phase = "Phase7"
        artifact_id = "phase7_verdict.json"
    })
    $phase7VerdictArtifact = $phase7VerdictSnapshot["artifact"]
    if ($phase7VerdictArtifact -and [bool]$phase7VerdictSnapshot["validation"]["valid"] -and [string]$phase7VerdictArtifact["verdict"] -eq "conditional_go") {
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
        active_attempt = (ConvertTo-RelayHashtable -InputObject $state["active_attempt"])
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
        attempt_id = Get-RelayAttemptPromptToken
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
        $runState = Clear-RunStateActiveAttempt -RunState $runState -Status "recovered" -Result ([string]$staleRepair["reason"])
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
            $dispatchPreparation = ConvertTo-RelayHashtable -InputObject (Prepare-PhaseAttemptDispatchMetadata -RunState $runState -ProjectRoot $script:ProjectRoot -PhaseName $phaseName -TaskId $taskId -ArchiveIfNeeded)

            $jobSpec = @{
                run_id = $ResolvedRunId
                job_id = New-ExecutionJobId -Phase $phaseName -Role $resolvedRole
                phase = $phaseName
                role = $resolvedRole
                task_id = $taskId
                attempt = 1
                attempt_id = Get-RelayAttemptPromptToken
                provider = $providerSpec["provider"]
                command = $providerSpec["command"]
                flags = $providerSpec["flags"]
                prompt_package = $phaseDefinition["prompt_package"]
                selected_task = $nextAction["selected_task"]
                archived_context = $dispatchPreparation["archived_context"]
            }

            $dispatchState = ConvertTo-RelayHashtable -InputObject $runState
            $dispatchState["status"] = "running"
            $dispatchState["active_job_id"] = $jobSpec["job_id"]
            $dispatchState = Set-RunStateCursor -RunState $dispatchState -Phase $phaseName -TaskId $taskId
            $archiveResult = ConvertTo-RelayHashtable -InputObject $dispatchPreparation["archive_result"]
            $archivePath = if ($archiveResult) { [string]$archiveResult["snapshot_path"] } else { $null }
            $dispatchState = Start-RunStateActiveAttempt -RunState $dispatchState -AttemptId ([string]$jobSpec["attempt_id"]) -Phase $phaseName -Stage "dispatching" -Status "running" -TaskId $taskId -JobId ([string]$jobSpec["job_id"]) -ArchivePath $archivePath
            $dispatchState = Sync-RunStatePhaseHistory -RunState $dispatchState
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $dispatchState | Out-Null
            if ($dispatchPreparation["archive_event"]) {
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event $dispatchPreparation["archive_event"]
            }
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

            $dispatchState = Update-RunStateActiveAttempt -RunState $dispatchState -Stage "running" -Status "running" -TaskId $taskId -JobId ([string]$jobSpec["job_id"])
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $dispatchState | Out-Null
            Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $dispatchState

            $phaseHistoryEntry = Get-CurrentPhaseHistoryEntry -RunState $dispatchState -PhaseName $phaseName -Role $resolvedRole
            $phaseStartedAtUtc = if ($phaseHistoryEntry) {
                Convert-RelayDateTimeToUtc -Value ([string]$phaseHistoryEntry["started"])
            }
            elseif ($dispatchState["active_attempt"]) {
                $activeAttempt = ConvertTo-RelayHashtable -InputObject $dispatchState["active_attempt"]
                Convert-RelayDateTimeToUtc -Value ([string]$activeAttempt["started_at"])
            }
            else {
                $null
            }
            $script:ArtifactCompletionProbeState = @{
                run_id = $ResolvedRunId
                job_id = [string]$jobSpec["job_id"]
                phase_name = $phaseName
                phase_definition = $phaseDefinition
                task_id = $taskId
                phase_started_at_utc = $phaseStartedAtUtc
            }
            try {
                $transactionResult = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseExecutionTransaction -JobSpec $jobSpec -PromptText $promptText -ProjectRoot $script:ProjectRoot -WorkingDirectory $script:ProjectDir -TimeoutPolicy (Get-StepTimeoutPolicy) -RunId $ResolvedRunId -PhaseName $phaseName -PhaseDefinition $phaseDefinition -ArtifactCompletionProbe ${function:Invoke-PhaseArtifactCompletionProbe} -TaskId $taskId -PhaseStartedAtUtc $phaseStartedAtUtc -OnRepairStart {
                        param($RepairContext)

                        $repairState = ConvertTo-RelayHashtable -InputObject $RepairContext
                        $dispatchState = Update-RunStateActiveAttempt -RunState $dispatchState -Stage "repairing" -Status "running" -TaskId $taskId -JobId ([string]$jobSpec["job_id"]) -Result ([string]$repairState["decision"]["reason"])
                        Write-RunState -ProjectRoot $script:ProjectRoot -RunState $dispatchState | Out-Null
                        Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $dispatchState
                        Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                            type = "artifact.repair_requested"
                            phase = $phaseName
                            task_id = $taskId
                            job_id = $jobSpec["job_id"]
                            repair_job_id = $repairState["repair_job_id"]
                            artifact_id = $repairState["validator_ref"]["artifact_id"]
                            repair_decision = (ConvertTo-RelayHashtable -InputObject $repairState["decision"])
                        }
                    })
            }
            finally {
                $script:ArtifactCompletionProbeState = $null
            }
            $outputSync = ConvertTo-RelayHashtable -InputObject $transactionResult["output_sync_result"]
            $validationResult = ConvertTo-RelayHashtable -InputObject $transactionResult["validation_result"]
            $commitResult = ConvertTo-RelayHashtable -InputObject $transactionResult["commit_result"]
            $repairResult = ConvertTo-RelayHashtable -InputObject $transactionResult["repair_result"]
            $executionResult = ConvertTo-RelayHashtable -InputObject $transactionResult["raw_execution_result"]
            $effectiveExecutionResult = ConvertTo-RelayHashtable -InputObject $transactionResult["effective_execution_result"]
            $attemptId = [string]$transactionResult["resolved_attempt_id"]
            $dispatchState = Update-RunStateActiveAttempt -RunState $dispatchState -AttemptId $attemptId -Stage "committing" -Status "running" -TaskId $taskId -JobId ([string]$jobSpec["job_id"]) -Result ([string]$effectiveExecutionResult["result_status"])
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $dispatchState | Out-Null
            Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $dispatchState

            if ($repairResult -and [bool]$repairResult["attempted"]) {
                $repairExecutionResult = ConvertTo-RelayHashtable -InputObject $repairResult["repair_execution_result"]
                $repairEventType = if ([string]$repairResult["outcome"] -eq "repaired") { "artifact.repair_completed" } else { "artifact.repair_failed" }
                Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                    type = $repairEventType
                    phase = $phaseName
                    task_id = $taskId
                    job_id = $jobSpec["job_id"]
                    repair_job_id = if ($repairExecutionResult) { [string]$repairExecutionResult["job_id"] } else { "" }
                    artifact_id = $validationResult["validator_ref"]["artifact_id"]
                    outcome = [string]$repairResult["outcome"]
                    error = [string]$repairResult["error"]
                    repair_decision = (ConvertTo-RelayHashtable -InputObject $repairResult["decision"])
                    diff_guard = (ConvertTo-RelayHashtable -InputObject $repairResult["diff_guard_result"])
                }
            }

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
                if ($commitResult -and @($commitResult["committed"]).Count -gt 0) {
                    Append-Event -ProjectRoot $script:ProjectRoot -RunId $ResolvedRunId -Event @{
                        type = "phase.artifacts_committed"
                        phase = $phaseName
                        task_id = $taskId
                        job_id = $jobSpec["job_id"]
                        artifact_ids = @(
                            @($commitResult["committed"]) |
                                ForEach-Object {
                                    $committedArtifact = ConvertTo-RelayHashtable -InputObject $_
                                    [string]$committedArtifact["artifact_id"]
                                }
                        )
                    }
                }
            }

            if ([bool]$transactionResult["recovered_from_timeout"]) {
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
            $mutationAction = ConvertTo-RelayHashtable -InputObject $mutation["action"]
            $attemptTerminalStatus = if ([string]$mutationAction["type"] -eq "FailRun") { "failed" } else { "completed" }
            $attemptTerminalResult = switch ([string]$mutationAction["type"]) {
                "FailRun" { [string]$mutationAction["reason"] }
                "RequestApproval" { "waiting_approval" }
                "Continue" { "phase_transitioned" }
                "CompleteRun" { "run_completed" }
                default { [string]$mutationAction["type"] }
            }
            $nextRunState = Clear-RunStateActiveAttempt -RunState $nextRunState -Status $attemptTerminalStatus -Result $attemptTerminalResult
            Write-RunState -ProjectRoot $script:ProjectRoot -RunState $nextRunState | Out-Null
            Append-RunStatusChangedEvent -RunId $ResolvedRunId -RunState $nextRunState

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
