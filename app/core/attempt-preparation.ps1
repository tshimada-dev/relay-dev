if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Get-ArtifactPhaseDirectory -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repository.ps1")
}
if (-not (Get-Command Get-LatestArchivedJsonContext -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "job-context-builder.ps1")
}

function Get-PhaseAttemptArtifactScope {
    param(
        [Parameter(Mandatory)][string]$PhaseName
    )

    if (Test-TaskScopedPhase -Phase $PhaseName) {
        return "task"
    }

    return "run"
}

function Test-PhaseHasCompletedHistory {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    foreach ($entryRaw in @($state["phase_history"])) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        if ([string]$entry["phase"] -ne $PhaseName) {
            continue
        }

        if (Test-TaskScopedPhase -Phase $PhaseName) {
            if ([string]$entry["task_id"] -ne [string]$TaskId) {
                continue
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$entry["completed"])) {
            return $true
        }
    }

    return $false
}

function Test-PhaseHasActiveArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId
    )

    $scope = Get-PhaseAttemptArtifactScope -PhaseName $PhaseName
    if ($scope -eq "task" -and [string]::IsNullOrWhiteSpace($TaskId)) {
        return $false
    }

    $phaseDirectory = Get-ArtifactPhaseDirectory -ProjectRoot $ProjectRoot -RunId $RunId -Scope $scope -Phase $PhaseName -TaskId $TaskId
    if (-not (Test-Path -LiteralPath $phaseDirectory)) {
        return $false
    }

    return (@(Get-ChildItem -LiteralPath $phaseDirectory -Force -ErrorAction SilentlyContinue).Count -gt 0)
}

function Test-PhaseWasRecoveredForRetry {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $runId = [string]$state["run_id"]
    if ([string]::IsNullOrWhiteSpace($runId)) {
        return $false
    }

    $lastRecoveryEvent = ConvertTo-RelayHashtable -InputObject (Get-LastEvent -ProjectRoot $ProjectRoot -RunId $runId -Type "run.recovered")
    if (-not $lastRecoveryEvent) {
        return $false
    }

    if ([string]$lastRecoveryEvent["phase"] -ne $PhaseName) {
        return $false
    }

    if ((Get-PhaseAttemptArtifactScope -PhaseName $PhaseName) -eq "task") {
        return ([string]$lastRecoveryEvent["task_id"] -eq [string]$TaskId)
    }

    return $true
}

function Test-PhaseShouldArchiveBeforeDispatch {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $runId = [string]$state["run_id"]
    if ([string]::IsNullOrWhiteSpace($runId)) {
        return $false
    }

    if (-not (Test-PhaseHasActiveArtifacts -ProjectRoot $ProjectRoot -RunId $runId -PhaseName $PhaseName -TaskId $TaskId)) {
        return $false
    }

    if (Test-PhaseHasCompletedHistory -RunState $state -PhaseName $PhaseName -TaskId $TaskId) {
        return $true
    }

    if (Test-PhaseWasRecoveredForRetry -RunState $state -ProjectRoot $ProjectRoot -PhaseName $PhaseName -TaskId $TaskId) {
        return $true
    }

    return $false
}

function Prepare-PhaseAttemptDispatchMetadata {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$PhaseName,
        [string]$TaskId,
        [string]$Reason = "rerun_before_dispatch",
        [switch]$ArchiveIfNeeded
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $runId = [string]$state["run_id"]
    $scope = Get-PhaseAttemptArtifactScope -PhaseName $PhaseName
    $shouldArchive = $false
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        $shouldArchive = Test-PhaseShouldArchiveBeforeDispatch -RunState $state -ProjectRoot $ProjectRoot -PhaseName $PhaseName -TaskId $TaskId
    }

    $archiveResult = $null
    $archiveEvent = $null
    if ($ArchiveIfNeeded -and $shouldArchive) {
        $archiveResult = ConvertTo-RelayHashtable -InputObject (Archive-PhaseArtifacts -ProjectRoot $ProjectRoot -RunId $runId -Scope $scope -Phase $PhaseName -TaskId $TaskId -Reason $Reason -PreviousJobId ([string]$state["active_job_id"]))
        if ([bool]$archiveResult["archived"]) {
            $archiveEvent = [ordered]@{
                type = "phase.artifacts_archived"
                phase = $PhaseName
                task_id = $TaskId
                scope = $scope
                snapshot_id = $archiveResult["snapshot_id"]
                snapshot_path = $archiveResult["snapshot_path"]
                artifact_ids = @(
                    @($archiveResult["archived_artifacts"]) |
                        ForEach-Object {
                            $archivedArtifact = ConvertTo-RelayHashtable -InputObject $_
                            [string]$archivedArtifact["artifact_id"]
                        }
                )
            }
        }
    }

    $archivedContext = if ([string]::IsNullOrWhiteSpace($runId)) {
        [ordered]@{
            archived_context_refs = @()
            archived_context_snapshot = $null
        }
    }
    else {
        Get-LatestArchivedJsonContext -ProjectRoot $ProjectRoot -RunId $runId -Scope $scope -Phase $PhaseName -TaskId $TaskId
    }

    return [ordered]@{
        scope = $scope
        should_archive_before_dispatch = $shouldArchive
        archive_reason = if ($shouldArchive) { $Reason } else { $null }
        archive_result = $archiveResult
        archive_event = $archiveEvent
        archived_context = $archivedContext
    }
}
