if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}

function New-ArtifactRepairClassification {
    param(
        [string]$Decision = "terminal",
        [string]$Reason = "unclassified",
        [string[]]$Evidence = @(),
        [string]$Fingerprint = "",
        [int]$BudgetUsed = 0,
        [int]$BudgetLimit = 0
    )

    return [ordered]@{
        repairable = ($Decision -eq "repairable")
        classification = if ($Decision -eq "repairable") { "repairable" } else { "not_repairable" }
        decision = $Decision
        reason = $Reason
        evidence = @($Evidence)
        fingerprint = $Fingerprint
        budget = [ordered]@{
            used = $BudgetUsed
            limit = $BudgetLimit
            exhausted = ($BudgetLimit -gt 0 -and $BudgetUsed -ge $BudgetLimit)
        }
    }
}

function Get-ArtifactRepairFingerprint {
    param(
        [string]$ArtifactId,
        [string]$Phase,
        [string]$FailureClass,
        [string[]]$Messages = @()
    )

    $normalizedMessages = @(
        @($Messages) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }
    )
    $payload = [ordered]@{
        artifact_id = [string]$ArtifactId
        phase = [string]$Phase
        failure_class = [string]$FailureClass
        messages = $normalizedMessages
    } | ConvertTo-Json -Depth 10 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
}

function Get-ArtifactRepairBudgetStatus {
    param(
        [int]$AttemptCount = 0,
        [int]$BudgetLimit = 0,
        [string]$Fingerprint = "",
        [string[]]$PreviousFingerprints = @()
    )

    $matchingAttempts = 0
    if (-not [string]::IsNullOrWhiteSpace($Fingerprint)) {
        $matchingAttempts = @($PreviousFingerprints | Where-Object { [string]$_ -eq $Fingerprint }).Count
    }

    return [ordered]@{
        used = [Math]::Max($AttemptCount, 0)
        limit = [Math]::Max($BudgetLimit, 0)
        exhausted = ($BudgetLimit -gt 0 -and $AttemptCount -ge $BudgetLimit)
        fingerprint = $Fingerprint
        repeated_failure = ($matchingAttempts -gt 0)
        repeated_failure_count = $matchingAttempts
    }
}

function Test-ArtifactRepairBudgetExceeded {
    param(
        [int]$AttemptCount = 0,
        [int]$BudgetLimit = 0
    )

    return ($BudgetLimit -gt 0 -and $AttemptCount -ge $BudgetLimit)
}

function Get-ArtifactRepairFailureSignals {
    param(
        $ValidationResult,
        $MaterializationResult,
        $ExecutionResult
    )

    $validation = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $materialization = ConvertTo-RelayHashtable -InputObject $MaterializationResult
    $execution = ConvertTo-RelayHashtable -InputObject $ExecutionResult

    $messages = New-Object System.Collections.Generic.List[string]
    $categories = New-Object System.Collections.Generic.List[string]

    $validationErrors = if ($validation) { @($validation["errors"]) } else { @() }
    $materializationErrors = if ($materialization) { @($materialization["errors"]) } else { @() }
    $executionErrors = if ($execution) { @($execution["errors"]) } else { @() }

    foreach ($message in @($validationErrors) + @($materializationErrors) + @($executionErrors)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$message)) {
            $messages.Add([string]$message)
        }
    }

    foreach ($message in $messages) {
        $text = $message.ToLowerInvariant()
        if ($text -match 'json|parse|deserialize|escape|unexpected character|trailing comma') {
            $categories.Add("syntax")
        }
        if ($text -match 'schema|required key|missing required key|must be an array|must be an object|must contain|enum|one of:') {
            $categories.Add("schema")
        }
        if ($text -match 'materializ|deserialize to an object|read error|recoverable raw staged text') {
            $categories.Add("materialization")
        }
        if ($text -match 'missing required artifact|required artifact .+ was not produced|could not be loaded from reference|artifact could not be loaded') {
            $categories.Add("missing_artifact")
        }
        if ($text -match 'requires at least one|must not include|cannot include|requires rollback_phase|must not be empty|must be between') {
            $categories.Add("semantic")
        }
    }

    if ($execution -and [string]$execution["failure_class"] -eq "materialization_error") {
        $categories.Add("materialization")
    }

    return [ordered]@{
        messages = @($messages)
        categories = @($categories | Select-Object -Unique)
    }
}

function Test-ArtifactFailureRepairable {
    param(
        [string[]]$Categories = @(),
        [switch]$ArtifactOnlyRepair
    )

    $categorySet = @($Categories | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($categorySet.Count -eq 0) {
        return $false
    }

    if ($categorySet -contains "missing_artifact") {
        return $false
    }

    if ($categorySet -contains "semantic") {
        return $false
    }

    $disallowedCategories = @($categorySet | Where-Object { $_ -notin @("syntax", "schema", "materialization") })
    if ($ArtifactOnlyRepair -and $disallowedCategories.Count -gt 0) {
        return $false
    }

    $repairableCategories = @($categorySet | Where-Object { $_ -in @("syntax", "schema", "materialization") })
    return ($repairableCategories.Count -gt 0)
}

function Get-ArtifactRepairDecision {
    param(
        [string]$ArtifactId,
        [string]$Phase,
        $ValidationResult,
        $MaterializationResult,
        $ExecutionResult,
        [int]$AttemptCount = 0,
        [int]$BudgetLimit = 0,
        [string[]]$PreviousFingerprints = @(),
        [switch]$ArtifactOnlyRepair
    )

    $signals = ConvertTo-RelayHashtable -InputObject (Get-ArtifactRepairFailureSignals -ValidationResult $ValidationResult -MaterializationResult $MaterializationResult -ExecutionResult $ExecutionResult)
    $categories = @($signals["categories"])
    $messages = @($signals["messages"])
    $failureClass = if ($categories.Count -gt 0) { $categories -join "+" } else { "unknown" }
    $fingerprint = Get-ArtifactRepairFingerprint -ArtifactId $ArtifactId -Phase $Phase -FailureClass $failureClass -Messages $messages
    $budget = ConvertTo-RelayHashtable -InputObject (Get-ArtifactRepairBudgetStatus -AttemptCount $AttemptCount -BudgetLimit $BudgetLimit -Fingerprint $fingerprint -PreviousFingerprints $PreviousFingerprints)

    if (Test-ArtifactRepairBudgetExceeded -AttemptCount $budget["used"] -BudgetLimit $budget["limit"]) {
        return (New-ArtifactRepairClassification -Decision "terminal" -Reason "repair_budget_exhausted" -Evidence $messages -Fingerprint $fingerprint -BudgetUsed $budget["used"] -BudgetLimit $budget["limit"])
    }

    if (Test-ArtifactFailureRepairable -Categories $categories -ArtifactOnlyRepair:$ArtifactOnlyRepair) {
        $reason = if ($categories -contains "syntax") {
            if (@($messages | Where-Object { [string]$_ -match 'escape' }).Count -gt 0) {
                "bad_json_escape"
            }
            else {
                "artifact_syntax"
            }
        }
        elseif ($categories -contains "schema") {
            "schema_shape_mismatch"
        }
        else {
            "artifact_materialization"
        }
        return (New-ArtifactRepairClassification -Decision "repairable" -Reason $reason -Evidence $messages -Fingerprint $fingerprint -BudgetUsed $budget["used"] -BudgetLimit $budget["limit"])
    }

    $reason = if ($categories -contains "semantic") {
        "semantic_invariant"
    }
    elseif ($categories -contains "missing_artifact") {
        "missing_required_artifact"
    }
    else {
        "terminal_failure"
    }

    return (New-ArtifactRepairClassification -Decision "terminal" -Reason $reason -Evidence $messages -Fingerprint $fingerprint -BudgetUsed $budget["used"] -BudgetLimit $budget["limit"])
}

function Get-ArtifactRepairClassification {
    param(
        [string]$ArtifactId,
        [string]$Phase,
        $ValidationResult,
        $MaterializationResult,
        $ExecutionResult,
        [int]$AttemptCount = 0,
        [int]$BudgetLimit = 0,
        [string[]]$PreviousFingerprints = @(),
        [switch]$ArtifactOnlyRepair
    )

    return (Get-ArtifactRepairDecision -ArtifactId $ArtifactId -Phase $Phase -ValidationResult $ValidationResult -MaterializationResult $MaterializationResult -ExecutionResult $ExecutionResult -AttemptCount $AttemptCount -BudgetLimit $BudgetLimit -PreviousFingerprints $PreviousFingerprints -ArtifactOnlyRepair:$ArtifactOnlyRepair)
}
