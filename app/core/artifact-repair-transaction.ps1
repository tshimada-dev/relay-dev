if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Resolve-PromptPackage -ErrorAction SilentlyContinue)) {
    . (Join-Path (Join-Path $PSScriptRoot "..\phases") "phase-registry.ps1")
}
if (-not (Get-Command Invoke-ExecutionRunner -ErrorAction SilentlyContinue)) {
    . (Join-Path (Join-Path $PSScriptRoot "..\execution") "execution-runner.ps1")
}
if (-not (Get-Command Get-PhaseMaterializedArtifacts -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "phase-validation-pipeline.ps1")
}
if (-not (Get-Command New-RepairPromptText -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "repair-prompt-builder.ps1")
}
if (-not (Get-Command Get-ArtifactRepairDecision -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repair-policy.ps1")
}
if (-not (Get-Command Test-RepairDiffAllowed -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "repair-diff-guard.ps1")
}

function Get-RepairableValidatorArtifact {
    param(
        [Parameter(Mandatory)]$OutputSyncResult,
        [Parameter(Mandatory)]$ValidatorRef
    )

    $sync = ConvertTo-RelayHashtable -InputObject $OutputSyncResult
    $ref = ConvertTo-RelayHashtable -InputObject $ValidatorRef

    foreach ($artifactRaw in @($sync["materialized"])) {
        $artifact = ConvertTo-RelayHashtable -InputObject $artifactRaw
        if (
            [string]$artifact["artifact_id"] -eq [string]$ref["artifact_id"] -and
            [string]$artifact["scope"] -eq [string]$ref["scope"]
        ) {
            return $artifact
        }
    }

    return $null
}

function Get-RepairValidatorContractItem {
    param(
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)]$ValidatorRef
    )

    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $ref = ConvertTo-RelayHashtable -InputObject $ValidatorRef
    foreach ($contractItemRaw in @($definition["output_contract"])) {
        $contractItem = ConvertTo-RelayHashtable -InputObject $contractItemRaw
        if ([string]$contractItem["artifact_id"] -eq [string]$ref["artifact_id"]) {
            return $contractItem
        }
    }

    return $null
}

function Read-RepairArtifactRawText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function New-RepairExecutionResult {
    param(
        [bool]$Attempted = $false,
        [AllowNull()]$Decision,
        [AllowNull()]$RepairJobSpec,
        [AllowNull()]$RepairExecutionResult,
        [AllowNull()]$OutputSyncResult,
        [AllowNull()]$ValidationResult,
        [AllowNull()]$DiffGuardResult,
        [string]$Outcome = "",
        [string]$Error = ""
    )

    return [ordered]@{
        attempted = $Attempted
        decision = (ConvertTo-RelayHashtable -InputObject $Decision)
        repair_job_spec = (ConvertTo-RelayHashtable -InputObject $RepairJobSpec)
        repair_execution_result = (ConvertTo-RelayHashtable -InputObject $RepairExecutionResult)
        output_sync_result = (ConvertTo-RelayHashtable -InputObject $OutputSyncResult)
        validation_result = (ConvertTo-RelayHashtable -InputObject $ValidationResult)
        diff_guard_result = (ConvertTo-RelayHashtable -InputObject $DiffGuardResult)
        outcome = $Outcome
        error = $Error
    }
}

function Invoke-ArtifactRepairTransaction {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)]$OriginalJobSpec,
        [Parameter(Mandatory)]$OutputSyncResult,
        [Parameter(Mandatory)]$ValidationResult,
        [Parameter(Mandatory)][string]$AttemptId,
        [string]$TaskId,
        [AllowNull()]$ArchivedContext,
        [int]$RepairBudgetLimit = 1,
        [scriptblock]$OnRepairStart
    )

    $job = ConvertTo-RelayHashtable -InputObject $OriginalJobSpec
    $outputSync = ConvertTo-RelayHashtable -InputObject $OutputSyncResult
    $validation = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $validatorRef = ConvertTo-RelayHashtable -InputObject $validation["validator_ref"]
    if (-not $validatorRef) {
        return (New-RepairExecutionResult)
    }

    $materializationErrors = [ordered]@{
        errors = @($outputSync["read_errors"])
    }
    $decision = ConvertTo-RelayHashtable -InputObject (Get-ArtifactRepairDecision `
            -ArtifactId ([string]$validatorRef["artifact_id"]) `
            -Phase $PhaseName `
            -ValidationResult $validation["validation"] `
            -MaterializationResult $materializationErrors `
            -ExecutionResult $null `
            -AttemptCount 0 `
            -BudgetLimit $RepairBudgetLimit `
            -PreviousFingerprints @() `
            -ArtifactOnlyRepair)

    if (-not [bool]$decision["repairable"]) {
        return (New-RepairExecutionResult -Decision $decision -Outcome "not_repairable")
    }

    $validatorArtifact = ConvertTo-RelayHashtable -InputObject (Get-RepairableValidatorArtifact -OutputSyncResult $outputSync -ValidatorRef $validatorRef)
    $validatorContractItem = ConvertTo-RelayHashtable -InputObject (Get-RepairValidatorContractItem -PhaseDefinition $PhaseDefinition -ValidatorRef $validatorRef)
    $validatorPath = if ($validatorContractItem) {
        Resolve-PhaseContractArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -PhaseName $PhaseName -ContractItem $validatorContractItem -TaskId $TaskId -JobId ([string]$job["job_id"]) -AttemptId $AttemptId -StorageScope "attempt"
    }
    else {
        $null
    }
    $originalValidatorRawText = Read-RepairArtifactRawText -Path $validatorPath
    if (-not $validatorArtifact -and [string]::IsNullOrWhiteSpace($originalValidatorRawText)) {
        return (New-RepairExecutionResult -Attempted $true -Decision $decision -Outcome "repair_target_missing" -Error "Validator artifact could not be located in staged artifacts.")
    }

    $repairMaterializedArtifacts = New-Object System.Collections.Generic.List[object]
    foreach ($artifactRaw in @($outputSync["materialized"])) {
        $repairMaterializedArtifacts.Add((ConvertTo-RelayHashtable -InputObject $artifactRaw)) | Out-Null
    }
    if (-not $validatorArtifact -and -not [string]::IsNullOrWhiteSpace($originalValidatorRawText)) {
        $repairMaterializedArtifacts.Add([ordered]@{
                artifact_id = [string]$validatorRef["artifact_id"]
                scope = [string]$validatorRef["scope"]
                phase = $PhaseName
                task_id = $TaskId
                path = $validatorPath
                content = $originalValidatorRawText
                as_json = $true
            }) | Out-Null
    }

    $repairJobSpec = [ordered]@{
        run_id = $RunId
        job_id = New-ExecutionJobId -Phase $PhaseName -Role "repairer"
        phase = $PhaseName
        role = "repairer"
        task_id = $TaskId
        attempt = 1
        attempt_id = "__RELAY_ATTEMPT_ID__"
        provider = [string]$job["provider"]
        command = [string]$job["command"]
        flags = [string]$job["flags"]
        prompt_package = (Resolve-PromptPackage -ProjectRoot $ProjectRoot -Phase $PhaseName -Role "repairer" -Provider ([string]$job["provider"]))
        repair_target_job_id = [string]$job["job_id"]
        repair_target_attempt_id = $AttemptId
        project_root = $ProjectRoot
        working_directory = $WorkingDirectory
    }

    if ($OnRepairStart) {
        & $OnRepairStart ([ordered]@{
                repair_job_id = [string]$repairJobSpec["job_id"]
                phase = $PhaseName
                task_id = $TaskId
                decision = $decision
                validator_ref = $validatorRef
            })
    }

    $repairPrompt = New-RepairPromptText `
        -RepairJobSpec $repairJobSpec `
        -PhaseDefinition $PhaseDefinition `
        -ValidationResult $validation["validation"] `
        -MaterializedArtifacts @($repairMaterializedArtifacts.ToArray()) `
        -ArchivedContext $ArchivedContext `
        -RepairDecision $decision `
        -OriginalJobSpec $job

    $repairExecutionResult = ConvertTo-RelayHashtable -InputObject (Invoke-ExecutionRunner -JobSpec $repairJobSpec -PromptText $repairPrompt -ProjectRoot $ProjectRoot -WorkingDirectory $WorkingDirectory -TimeoutPolicy $TimeoutPolicy)
    if ([string]$repairExecutionResult["result_status"] -ne "succeeded" -or [int]$repairExecutionResult["exit_code"] -ne 0) {
        return (New-RepairExecutionResult -Attempted $true -Decision $decision -RepairJobSpec $repairJobSpec -RepairExecutionResult $repairExecutionResult -Outcome "repair_job_failed" -Error "Repair job failed before artifacts could be revalidated.")
    }

    $repairedOutputSync = ConvertTo-RelayHashtable -InputObject (Get-PhaseMaterializedArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -PhaseName $PhaseName -PhaseDefinition $PhaseDefinition -JobId ([string]$job["job_id"]) -AttemptId $AttemptId -StorageScope "attempt" -TaskId $TaskId)
    $repairedValidation = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseValidationPipeline -PhaseName $PhaseName -PhaseDefinition $PhaseDefinition -MaterializedArtifacts @($repairedOutputSync["materialized"]) -MissingRequired @($repairedOutputSync["missing_required"]) -StaleRequired @($repairedOutputSync["stale_required"]) -ReadErrors @($repairedOutputSync["read_errors"]) -TaskId $TaskId)

    $repairedValidatorArtifact = ConvertTo-RelayHashtable -InputObject (Get-RepairableValidatorArtifact -OutputSyncResult $repairedOutputSync -ValidatorRef $validatorRef)
    $repairedValidatorRawText = Read-RepairArtifactRawText -Path $validatorPath
    $diffGuard = $null
    if ($repairedValidatorArtifact -or -not [string]::IsNullOrWhiteSpace($repairedValidatorRawText)) {
        $originalDiffArtifact = if (-not [string]::IsNullOrWhiteSpace($originalValidatorRawText)) { $originalValidatorRawText } elseif ($validatorArtifact) { $validatorArtifact["content"] } else { $null }
        $repairedDiffArtifact = if (-not [string]::IsNullOrWhiteSpace($repairedValidatorRawText)) { $repairedValidatorRawText } elseif ($repairedValidatorArtifact) { $repairedValidatorArtifact["content"] } else { $null }
        $diffGuard = ConvertTo-RelayHashtable -InputObject (Test-RepairDiffAllowed -ArtifactId ([string]$validatorRef["artifact_id"]) -OriginalArtifact $originalDiffArtifact -RepairedArtifact $repairedDiffArtifact)
        if (-not [bool]$diffGuard["allowed"]) {
            $guardErrors = @(
                @($diffGuard["violations"]) |
                    ForEach-Object { "Repairer modified immutable field '$([string]$_)'." }
            )
            $repairedValidation["validation"] = [ordered]@{
                valid = $false
                errors = $guardErrors
                warnings = @()
            }
            return (New-RepairExecutionResult -Attempted $true -Decision $decision -RepairJobSpec $repairJobSpec -RepairExecutionResult $repairExecutionResult -OutputSyncResult $repairedOutputSync -ValidationResult $repairedValidation -DiffGuardResult $diffGuard -Outcome "immutable_field_violation" -Error ($guardErrors -join "; "))
        }
    }

    $outcome = if ([bool]$repairedValidation["validation"]["valid"]) { "repaired" } else { "repair_validation_failed" }
    return (New-RepairExecutionResult -Attempted $true -Decision $decision -RepairJobSpec $repairJobSpec -RepairExecutionResult $repairExecutionResult -OutputSyncResult $repairedOutputSync -ValidationResult $repairedValidation -DiffGuardResult $diffGuard -Outcome $outcome)
}
