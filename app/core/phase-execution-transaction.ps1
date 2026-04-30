if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Archive-PhaseArtifacts -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repository.ps1")
}
if (-not (Get-Command Get-LatestArchivedJsonContext -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "job-context-builder.ps1")
}
if (-not (Get-Command Get-PhaseMaterializedArtifacts -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "phase-validation-pipeline.ps1")
}
if (-not (Get-Command Complete-PhaseOutputCommit -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "phase-completion-committer.ps1")
}
if (-not (Get-Command Invoke-ExecutionRunner -ErrorAction SilentlyContinue)) {
    . (Join-Path (Join-Path $PSScriptRoot "..\execution") "execution-runner.ps1")
}

function Convert-PhaseExecutionDateTimeToUtc {
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

function Resolve-PhaseExecutionArtifactCompletionCutoffUtc {
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

function Resolve-PhaseExecutionEffectiveResult {
    param(
        [Parameter(Mandatory)]$ExecutionResult,
        [AllowNull()]$ValidationResult
    )

    $effectiveExecutionResult = ConvertTo-RelayHashtable -InputObject $ExecutionResult
    $validatorStatus = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $recoveredFromTimeout = $false

    if (
        $effectiveExecutionResult -and
        [string]$effectiveExecutionResult["failure_class"] -eq "timeout" -and
        $validatorStatus -and
        [bool]$validatorStatus["valid"]
    ) {
        $effectiveExecutionResult["result_status"] = "succeeded"
        $effectiveExecutionResult["failure_class"] = $null
        $effectiveExecutionResult["recovered_from_timeout"] = $true
        $recoveredFromTimeout = $true
    }
    elseif ($effectiveExecutionResult -and -not $effectiveExecutionResult.ContainsKey("recovered_from_timeout")) {
        $effectiveExecutionResult["recovered_from_timeout"] = $false
    }

    return [ordered]@{
        execution_result = $effectiveExecutionResult
        recovered_from_timeout = $recoveredFromTimeout
    }
}

function Invoke-PhaseExecutionTransaction {
    param(
        [Parameter(Mandatory)]$JobSpec,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [scriptblock]$ArtifactCompletionProbe,
        [int]$ArtifactCompletionStabilitySec = 5,
        [string]$TaskId,
        [AllowNull()][datetime]$PhaseStartedAtUtc,
        [bool]$ArchiveBeforeDispatch = $false,
        [string]$PreviousJobId,
        [scriptblock]$OnWarn,
        [scriptblock]$OnRetry,
        [scriptblock]$OnAbort
    )

    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $jobId = [string]$job["job_id"]
    $phaseScope = if ([string]::IsNullOrWhiteSpace($TaskId)) { "run" } else { "task" }

    $archiveResult = $null
    if ($ArchiveBeforeDispatch) {
        $archiveParams = @{
            ProjectRoot = $ProjectRoot
            RunId = $RunId
            Scope = $phaseScope
            Phase = $PhaseName
            Reason = "rerun_before_dispatch"
            PreviousJobId = $PreviousJobId
        }
        if ($phaseScope -eq "task") {
            $archiveParams["TaskId"] = $TaskId
        }
        $archiveResult = ConvertTo-RelayHashtable -InputObject (Archive-PhaseArtifacts @archiveParams)
    }

    $archivedContextParams = @{
        ProjectRoot = $ProjectRoot
        RunId = $RunId
        Scope = $phaseScope
        Phase = $PhaseName
    }
    if ($phaseScope -eq "task") {
        $archivedContextParams["TaskId"] = $TaskId
    }
    $archivedContext = ConvertTo-RelayHashtable -InputObject (Get-LatestArchivedJsonContext @archivedContextParams)

    $executionParams = @{
        JobSpec = $job
        PromptText = $PromptText
        ProjectRoot = $ProjectRoot
        WorkingDirectory = $WorkingDirectory
        TimeoutPolicy = $TimeoutPolicy
        ArtifactCompletionStabilitySec = $ArtifactCompletionStabilitySec
    }
    if ($ArtifactCompletionProbe) {
        $executionParams["ArtifactCompletionProbe"] = $ArtifactCompletionProbe
    }
    if ($OnWarn) {
        $executionParams["OnWarn"] = $OnWarn
    }
    if ($OnRetry) {
        $executionParams["OnRetry"] = $OnRetry
    }
    if ($OnAbort) {
        $executionParams["OnAbort"] = $OnAbort
    }

    $executionResult = ConvertTo-RelayHashtable -InputObject (Invoke-ExecutionRunner @executionParams)
    $attemptId = [string]$executionResult["attempt_id"]
    $finalAttemptStartedAt = [string]$executionResult["final_attempt_started_at"]
    $attemptStartedAtUtc = Convert-PhaseExecutionDateTimeToUtc -Value $finalAttemptStartedAt
    $artifactCompletionCutoffUtc = Resolve-PhaseExecutionArtifactCompletionCutoffUtc -PhaseStartedAtUtc $PhaseStartedAtUtc -AttemptStartedAtUtc $attemptStartedAtUtc

    $outputSyncParams = @{
        ProjectRoot = $ProjectRoot
        RunId = $RunId
        PhaseName = $PhaseName
        PhaseDefinition = $PhaseDefinition
        JobId = $jobId
        StorageScope = if (-not [string]::IsNullOrWhiteSpace($attemptId)) { "attempt" } else { "job" }
        AttemptStartedAtUtc = $attemptStartedAtUtc
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $outputSyncParams["TaskId"] = $TaskId
    }
    if (-not [string]::IsNullOrWhiteSpace($attemptId)) {
        $outputSyncParams["AttemptId"] = $attemptId
    }
    $outputSyncResult = ConvertTo-RelayHashtable -InputObject (Get-PhaseMaterializedArtifacts @outputSyncParams)

    $validationResult = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseValidationPipeline -PhaseName $PhaseName -PhaseDefinition $PhaseDefinition -MaterializedArtifacts @($outputSyncResult["materialized"]) -MissingRequired @($outputSyncResult["missing_required"]) -StaleRequired @($outputSyncResult["stale_required"]) -ReadErrors @($outputSyncResult["read_errors"]) -TaskId $TaskId)

    $commitResult = $null
    $validatorStatus = ConvertTo-RelayHashtable -InputObject $validationResult["validation"]
    if ($validatorStatus -and [bool]$validatorStatus["valid"]) {
        try {
            $commitResult = ConvertTo-RelayHashtable -InputObject (Complete-PhaseOutputCommit -ProjectRoot $ProjectRoot -RunId $RunId -MaterializedArtifacts @($outputSyncResult["materialized"]))
            $validationResult["commit"] = $commitResult
        }
        catch {
            $validatorStatus["valid"] = $false
            $validatorStatus["errors"] = @($validatorStatus["errors"]) + "Failed to commit validated artifacts: $($_.Exception.Message)"
            $validationResult["validation"] = $validatorStatus
            $commitResult = [ordered]@{
                committed = @()
                summary = [ordered]@{
                    committed_count = 0
                    artifact_ids = @()
                }
                error = $_.Exception.Message
            }
        }
    }

    $effectiveResultResolution = ConvertTo-RelayHashtable -InputObject (Resolve-PhaseExecutionEffectiveResult -ExecutionResult $executionResult -ValidationResult $validationResult["validation"])
    $effectiveExecutionResult = ConvertTo-RelayHashtable -InputObject $effectiveResultResolution["execution_result"]

    return [ordered]@{
        job_id = $jobId
        run_id = $RunId
        phase = $PhaseName
        task_id = if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId }
        archive_result = $archiveResult
        archived_context = $archivedContext
        execution_result = $executionResult
        raw_execution_result = $executionResult
        attempt_id = $attemptId
        resolved_attempt_id = $attemptId
        final_attempt_started_at = $finalAttemptStartedAt
        final_attempt_started_at_utc = if ($attemptStartedAtUtc) { $attemptStartedAtUtc.ToString("o") } else { $null }
        artifact_completion_cutoff_utc = if ($artifactCompletionCutoffUtc) { $artifactCompletionCutoffUtc.ToString("o") } else { $null }
        output_sync_result = $outputSyncResult
        validation_result = $validationResult
        commit_result = $commitResult
        effective_execution_result = $effectiveExecutionResult
        recovered_from_timeout = [bool]$effectiveResultResolution["recovered_from_timeout"]
    }
}
