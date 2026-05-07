if (-not (Get-Command Read-ArtifactContentFromPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repository.ps1")
}
if (-not (Get-Command Get-ArtifactValidationSnapshot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-validator.ps1")
}
if (-not (Get-Command Finalize-PhaseMaterializedArtifacts -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "verdict-finalizer.ps1")
}
if (-not (Get-Command Test-TaskScopedPhase -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "workflow-engine.ps1")
}

function Resolve-PhaseContractArtifactPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
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
    $sourcePhase = if ($item["phase"]) { [string]$item["phase"] } else { $PhaseName }

    if ($scope -eq "task") {
        $resolvedTaskId = if ($item["task_id"]) { [string]$item["task_id"] } else { $TaskId }
        if ([string]::IsNullOrWhiteSpace($resolvedTaskId)) {
            throw "Task-scoped artifact '$($item["artifact_id"])' for phase '$PhaseName' requires a task id."
        }

        if ($StorageScope -ne "canonical") {
            return (Resolve-StagedArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -StorageScope $StorageScope -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $resolvedTaskId -JobId $JobId -AttemptId $AttemptId)
        }

        if ($PreferJobArtifacts -and -not [string]::IsNullOrWhiteSpace($JobId)) {
            return (Resolve-StagedArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -StorageScope "job" -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $resolvedTaskId -JobId $JobId)
        }

        return (Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -TaskId $resolvedTaskId)
    }

    if ($StorageScope -ne "canonical") {
        return (Resolve-StagedArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -StorageScope $StorageScope -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -JobId $JobId -AttemptId $AttemptId)
    }

    if ($PreferJobArtifacts -and -not [string]::IsNullOrWhiteSpace($JobId)) {
        return (Resolve-StagedArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -StorageScope "job" -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]) -JobId $JobId)
    }

    return (Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $scope -Phase $sourcePhase -ArtifactId ([string]$item["artifact_id"]))
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

    return [ordered]@{
        scope = $scope
        phase = $PhaseName
        artifact_id = $artifactId
        task_id = if ($scope -eq "task") { $TaskId } else { $null }
    }
}

function Get-PhaseMaterializedArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [string]$TaskId,
        [string]$JobId,
        [string]$AttemptId,
        [ValidateSet("canonical", "job", "attempt")][string]$StorageScope = "canonical",
        [AllowNull()][datetime]$AttemptStartedAtUtc
    )

    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $materialized = New-Object System.Collections.Generic.List[object]
    $missingRequired = New-Object System.Collections.Generic.List[string]
    $staleRequired = New-Object System.Collections.Generic.List[string]
    $readErrors = New-Object System.Collections.Generic.List[string]

    foreach ($contractItem in @($definition["output_contract"])) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        $artifactId = [string]$item["artifact_id"]
        if ([string]::IsNullOrWhiteSpace($artifactId)) {
            continue
        }

        $scope = if ($item["scope"]) { [string]$item["scope"] } else { "run" }
        $format = [string]$item["format"]
        $required = $false
        if ($item.ContainsKey("required")) {
            $required = [bool]$item["required"]
        }

        $path = Resolve-PhaseContractArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -PhaseName $PhaseName -ContractItem $item -TaskId $TaskId -JobId $JobId -AttemptId $AttemptId -StorageScope $StorageScope -PreferJobArtifacts:([bool](-not [string]::IsNullOrWhiteSpace($JobId)))
        if (-not (Test-Path -LiteralPath $path)) {
            if ($required) {
                $missingRequired.Add($artifactId) | Out-Null
            }
            continue
        }

        $fileItem = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($AttemptStartedAtUtc -and $fileItem.LastWriteTimeUtc -lt $AttemptStartedAtUtc) {
            if ($required) {
                $staleRequired.Add("$artifactId<$($fileItem.LastWriteTimeUtc.ToString("o"))") | Out-Null
            }
            continue
        }

        try {
            $content = Read-ArtifactContentFromPath -Path $path
            $materialized.Add([ordered]@{
                artifact_id = $artifactId
                scope = $scope
                phase = $PhaseName
                task_id = $TaskId
                path = $path
                content = $content
                as_json = ($format -eq "json" -or $artifactId.ToLowerInvariant().EndsWith(".json"))
                last_write_time_utc = $fileItem.LastWriteTimeUtc.ToString("o")
            }) | Out-Null
        }
        catch {
            $readErrors.Add("Failed to materialize artifact '$artifactId': $($_.Exception.Message)") | Out-Null
        }
    }

    return [ordered]@{
        materialized = @($materialized.ToArray())
        missing_required = @($missingRequired.ToArray())
        stale_required = @($staleRequired.ToArray())
        read_errors = @($readErrors.ToArray())
    }
}

function Invoke-PhaseValidationPipeline {
    param(
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)]$MaterializedArtifacts,
        [string[]]$MissingRequired = @(),
        [string[]]$StaleRequired = @(),
        [string[]]$ReadErrors = @(),
        [string]$TaskId
    )

    $validatorRef = Resolve-PhaseValidatorArtifactRef -PhaseDefinition $PhaseDefinition -PhaseName $PhaseName -TaskId $TaskId
    if (-not $validatorRef) {
        return [ordered]@{
            validation = [ordered]@{
                valid = $false
                errors = @("Phase '$PhaseName' does not define a validator artifact.")
                warnings = @()
            }
            artifact = $null
            original_artifact = $null
            validator_ref = $null
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($artifactId in @($MissingRequired)) {
        $errors.Add("Required artifact '$artifactId' was not produced.") | Out-Null
    }
    foreach ($artifactId in @($StaleRequired)) {
        $errors.Add("Required artifact '$artifactId' was stale for this attempt.") | Out-Null
    }
    foreach ($readError in @($ReadErrors)) {
        $errors.Add([string]$readError) | Out-Null
    }

    if ($errors.Count -gt 0) {
        return [ordered]@{
            validation = [ordered]@{
                valid = $false
                errors = @($errors.ToArray())
                warnings = @()
            }
            artifact = $null
            original_artifact = $null
            validator_ref = $validatorRef
            materialized_artifacts = @($MaterializedArtifacts)
        }
    }

    $finalization = ConvertTo-RelayHashtable -InputObject (Finalize-PhaseMaterializedArtifacts -PhaseName $PhaseName -MaterializedArtifacts @($MaterializedArtifacts) -TaskId $TaskId)
    $effectiveMaterializedArtifacts = @($finalization["materialized"])
    $finalizationWarnings = @($finalization["warnings"])
    $finalizationErrors = @($finalization["errors"])
    if ($finalizationErrors.Count -gt 0) {
        return [ordered]@{
            validation = [ordered]@{
                valid = $false
                errors = $finalizationErrors
                warnings = $finalizationWarnings
            }
            artifact = $null
            original_artifact = $null
            validator_ref = $validatorRef
            finalization = $finalization
            materialized_artifacts = $effectiveMaterializedArtifacts
        }
    }

    $materializedValidatorArtifact = $null
    foreach ($materializedRaw in $effectiveMaterializedArtifacts) {
        $materializedArtifact = ConvertTo-RelayHashtable -InputObject $materializedRaw
        if (
            [string]$materializedArtifact["artifact_id"] -eq [string]$validatorRef["artifact_id"] -and
            [string]$materializedArtifact["scope"] -eq [string]$validatorRef["scope"]
        ) {
            $materializedValidatorArtifact = $materializedArtifact
            break
        }
    }

    if (-not $materializedValidatorArtifact) {
        return [ordered]@{
            validation = [ordered]@{
                valid = $false
                errors = @("Validator artifact '$($validatorRef["artifact_id"])' was not materialized for this attempt.")
                warnings = @()
            }
            artifact = $null
            original_artifact = $null
            validator_ref = $validatorRef
            finalization = $finalization
            materialized_artifacts = $effectiveMaterializedArtifacts
        }
    }

    $validationSnapshot = ConvertTo-RelayHashtable -InputObject (Get-ArtifactValidationSnapshot -ArtifactId ([string]$validatorRef["artifact_id"]) -Artifact $materializedValidatorArtifact["content"] -Phase $PhaseName)
    $validationStatus = ConvertTo-RelayHashtable -InputObject $validationSnapshot["validation"]
    if ($validationStatus -and $finalizationWarnings.Count -gt 0) {
        $validationStatus["warnings"] = @($validationStatus["warnings"]) + $finalizationWarnings
        $validationSnapshot["validation"] = $validationStatus
    }
    $artifact = $validationSnapshot["artifact"]
    if ($null -eq $artifact) {
        return [ordered]@{
            validation = [ordered]@{
                valid = $false
                errors = @("Validator artifact '$($validatorRef["artifact_id"])' did not deserialize to a valid object.")
                warnings = @($validationSnapshot["validation"]["warnings"])
            }
            artifact = $null
            original_artifact = $validationSnapshot["original_artifact"]
            validator_ref = $validatorRef
            validation_snapshot = $validationSnapshot
            finalization = $finalization
            materialized_artifacts = $effectiveMaterializedArtifacts
        }
    }

    return [ordered]@{
        validation = $validationSnapshot["validation"]
        artifact = $artifact
        original_artifact = $validationSnapshot["original_artifact"]
        validator_ref = $validatorRef
        validation_snapshot = $validationSnapshot
        finalization = $finalization
        materialized_artifacts = $effectiveMaterializedArtifacts
    }
}
