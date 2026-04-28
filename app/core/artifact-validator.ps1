if (-not (Get-Command Get-VisualContractSchema -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "visual-contract-schema.ps1")
}

function New-ArtifactValidationResult {
    return [ordered]@{
        valid = $true
        errors = @()
        warnings = @()
    }
}

function Add-ArtifactValidationError {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Message
    )

    $Result["valid"] = $false
    $Result["errors"] = @($Result["errors"]) + $Message
}

function Add-ArtifactValidationWarning {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Message
    )

    $Result["warnings"] = @($Result["warnings"]) + $Message
}

function Test-ArtifactRequiredKeys {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string[]]$Keys,
        [Parameter(Mandatory)][string]$ArtifactId
    )

    foreach ($key in $Keys) {
        if (-not $Artifact.ContainsKey($key)) {
            Add-ArtifactValidationError -Result $Result -Message "$ArtifactId is missing required key '$key'."
        }
    }
}

function Test-ArtifactArrayField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [switch]$AllowEmpty
    )

    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $value = $Artifact[$FieldName]
    if ($null -eq $value -or -not ($value -is [System.Collections.IEnumerable]) -or ($value -is [string]) -or ($value -is [System.Collections.IDictionary])) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be an array."
        return
    }

    $items = @($value)
    if (-not $AllowEmpty -and $items.Count -eq 0) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must not be empty."
    }
}

function Test-ArtifactObjectArrayField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [switch]$AllowEmpty
    )

    Test-ArtifactArrayField -Artifact $Artifact -Result $Result -FieldName $FieldName -AllowEmpty:$AllowEmpty
    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    foreach ($item in @($Artifact[$FieldName])) {
        if (-not ($item -is [System.Collections.IDictionary])) {
            Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must contain objects."
            break
        }
    }
}

function Test-ArtifactStringField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName
    )

    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $value = [string]$Artifact[$FieldName]
    if ([string]::IsNullOrWhiteSpace($value)) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be a non-empty string."
    }
}

function Test-ArtifactEnumField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string[]]$AllowedValues
    )

    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $value = [string]$Artifact[$FieldName]
    if ($value -notin $AllowedValues) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be one of: $($AllowedValues -join ', ')."
    }
}

function Test-ArtifactNumericField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName
    )

    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $value = $Artifact[$FieldName]
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be numeric."
        return
    }

    $parsed = 0.0
    if (-not [double]::TryParse([string]$value, [ref]$parsed)) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be numeric."
    }
}

function Test-ArtifactNumericRangeField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][double]$Min,
        [Parameter(Mandatory)][double]$Max
    )

    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $parsed = 0.0
    if (-not [double]::TryParse([string]$Artifact[$FieldName], [ref]$parsed)) {
        return
    }

    if ($parsed -lt $Min -or $parsed -gt $Max) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be between $Min and $Max."
    }
}

function Test-ArtifactObjectField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName
    )

    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $value = ConvertTo-RelayHashtable -InputObject $Artifact[$FieldName]
    if (-not ($value -is [System.Collections.IDictionary])) {
        Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must be an object."
    }
}

function Test-ArtifactChecklistField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][string[]]$RequiredCheckIds,
        [Parameter(Mandatory)][string[]]$AllowedStatuses
    )

    $seen = @{}
    Test-ArtifactObjectArrayField -Artifact $Artifact -Result $Result -FieldName $FieldName
    if (-not $Artifact.ContainsKey($FieldName)) {
        return $seen
    }

    foreach ($entryRaw in @($Artifact[$FieldName])) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        if (-not ($entry -is [System.Collections.IDictionary])) {
            continue
        }

        Test-ArtifactRequiredKeys -Artifact $entry -Result $Result -Keys @("check_id", "status", "notes", "evidence") -ArtifactId "$ArtifactId $FieldName[]"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "check_id"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "status"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "notes"
        Test-ArtifactEnumField -Artifact $entry -Result $Result -FieldName "status" -AllowedValues $AllowedStatuses
        Test-ArtifactArrayField -Artifact $entry -Result $Result -FieldName "evidence" -AllowEmpty

        $checkId = [string]$entry["check_id"]
        $status = [string]$entry["status"]
        if (-not [string]::IsNullOrWhiteSpace($checkId)) {
            if ($checkId -notin $RequiredCheckIds) {
                Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName contains unknown check_id '$checkId'."
            }
            elseif ($seen.ContainsKey($checkId)) {
                Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName contains duplicate check_id '$checkId'."
            }
            else {
                $seen[$checkId] = $entry
            }
        }

        if ($status -ne "not_applicable" -and $entry.ContainsKey("evidence") -and @($entry["evidence"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName check '$checkId' must include evidence unless status is not_applicable."
        }
    }

    foreach ($requiredCheckId in $RequiredCheckIds) {
        if (-not $seen.ContainsKey($requiredCheckId)) {
            Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName is missing required check_id '$requiredCheckId'."
        }
    }

    return $seen
}

function Get-ChecklistStatusCounts {
    param([Parameter(Mandatory)]$ChecklistMap)

    $counts = @{
        pass = 0
        warning = 0
        fail = 0
        not_applicable = 0
    }

    foreach ($entry in $ChecklistMap.Values) {
        $status = [string]$entry["status"]
        if ($counts.ContainsKey($status)) {
            $counts[$status] = [int]$counts[$status] + 1
        }
    }

    return $counts
}

function Test-ArtifactStringArrayField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [switch]$AllowEmpty
    )

    Test-ArtifactArrayField -Artifact $Artifact -Result $Result -FieldName $FieldName -AllowEmpty:$AllowEmpty
    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    foreach ($item in @($Artifact[$FieldName])) {
        if ($item -is [System.Collections.IDictionary] -or ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string]))) {
            Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must contain strings."
            break
        }

        if ([string]::IsNullOrWhiteSpace([string]$item)) {
            Add-ArtifactValidationError -Result $Result -Message "Field '$FieldName' must not contain empty strings."
            break
        }
    }
}

function Test-ArtifactOpenRequirementsField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$ArtifactId,
        [switch]$RequireSourceTaskId
    )

    $seen = @{}
    Test-ArtifactObjectArrayField -Artifact $Artifact -Result $Result -FieldName $FieldName -AllowEmpty
    if (-not $Artifact.ContainsKey($FieldName)) {
        return $seen
    }

    foreach ($entryRaw in @($Artifact[$FieldName])) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        if (-not ($entry -is [System.Collections.IDictionary])) {
            continue
        }

        Test-ArtifactRequiredKeys -Artifact $entry -Result $Result -Keys @("item_id", "description", "source_phase", "source_task_id", "verify_in_phase", "required_artifacts") -ArtifactId "$ArtifactId $FieldName[]"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "item_id"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "description"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "source_phase"
        Test-ArtifactStringField -Artifact $entry -Result $Result -FieldName "verify_in_phase"
        Test-ArtifactStringArrayField -Artifact $entry -Result $Result -FieldName "required_artifacts" -AllowEmpty

        $sourceTaskId = [string]$entry["source_task_id"]
        if ($RequireSourceTaskId -and [string]::IsNullOrWhiteSpace($sourceTaskId)) {
            Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName must include source_task_id for task-scoped requirements."
        }

        $itemId = [string]$entry["item_id"]
        if (-not [string]::IsNullOrWhiteSpace($itemId)) {
            if ($seen.ContainsKey($itemId)) {
                Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName contains duplicate item_id '$itemId'."
            }
            else {
                $seen[$itemId] = $entry
            }
        }
    }

    return $seen
}

function Test-GenericCollectionArtifact {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string[]]$StringFields = @(),
        [string[]]$ArrayFields = @()
    )

    $result = New-ArtifactValidationResult
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys ($StringFields + $ArrayFields) -ArtifactId $ArtifactId

    foreach ($field in $StringFields) {
        Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName $field
    }
    foreach ($field in $ArrayFields) {
        Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName $field
    }

    return $result
}

function Test-GenericVerdictArtifact {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string[]]$AllowedRollbackPhases = @(),
        [switch]$RequireTaskId
    )

    $result = New-ArtifactValidationResult
    $requiredKeys = @("verdict", "rollback_phase", "must_fix", "warnings", "evidence")
    if ($RequireTaskId) {
        $requiredKeys = @("task_id") + $requiredKeys
    }

    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys $requiredKeys -ArtifactId $ArtifactId
    if ($RequireTaskId) {
        Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName "task_id"
    }

    Test-ArtifactEnumField -Artifact $Artifact -Result $result -FieldName "verdict" -AllowedValues @("go", "conditional_go", "reject")
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "must_fix" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "warnings" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "evidence" -AllowEmpty

    if ([string]$Artifact["verdict"] -eq "reject") {
        if ([string]::IsNullOrWhiteSpace([string]$Artifact["rollback_phase"])) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires rollback_phase."
        }
        elseif ($AllowedRollbackPhases.Count -gt 0 -and [string]$Artifact["rollback_phase"] -notin $AllowedRollbackPhases) {
            Add-ArtifactValidationError -Result $result -Message "rollback_phase must be one of: $($AllowedRollbackPhases -join ', ')."
        }
    }

    return $result
}

function Test-Phase0ContextArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @(
        "project_summary",
        "project_root",
        "framework_root",
        "constraints",
        "available_tools",
        "risks",
        "open_questions",
        "design_inputs",
        "visual_constraints",
        "task_fingerprint",
        "task_path",
        "seed_created_at"
    ) -ArtifactId "phase0_context.json"
    foreach ($field in @("project_summary", "project_root", "framework_root", "task_fingerprint", "task_path", "seed_created_at")) {
        Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName $field
    }
    foreach ($field in @("constraints", "available_tools", "risks", "open_questions")) {
        Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName $field
    }
    foreach ($field in @("design_inputs", "visual_constraints")) {
        Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName $field -AllowEmpty
    }
    return $result
}

function Test-Phase1RequirementsArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("goals", "non_goals", "user_stories", "acceptance_criteria", "visual_acceptance_criteria", "assumptions", "unresolved_questions") -ArtifactId "phase1_requirements.json"
    foreach ($field in @("goals", "non_goals", "user_stories", "acceptance_criteria", "assumptions")) {
        Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName $field
    }
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "visual_acceptance_criteria" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "unresolved_questions" -AllowEmpty
    return $result
}

function Test-Phase2InfoGatheringArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("collected_evidence", "decisions", "unresolved_blockers", "source_refs", "next_actions") -ArtifactId "phase2_info_gathering.json"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "collected_evidence"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "decisions"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "unresolved_blockers" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "source_refs"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "next_actions"
    return $result
}

function Test-Phase3DesignArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    $requiredKeys = @(
        "feature_list",
        "api_definitions",
        "entities",
        "constraints",
        "state_transitions",
        "reuse_decisions",
        "module_boundaries",
        "public_interfaces",
        "allowed_dependencies",
        "forbidden_dependencies",
        "side_effect_boundaries",
        "state_ownership",
        "visual_contract"
    )
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys $requiredKeys -ArtifactId "phase3_design.json"

    foreach ($field in $requiredKeys) {
        if ($field -eq "visual_contract") {
            Test-VisualContractField -Artifact $Artifact -Result $result -FieldName $field -ArtifactId "phase3_design.json"
            continue
        }

        if ($Artifact.ContainsKey($field) -and $Artifact[$field] -is [System.Collections.IDictionary]) {
            if ($Artifact[$field].Count -eq 0) {
                Add-ArtifactValidationError -Result $result -Message "Field '$field' must not be empty."
            }
            continue
        }

        Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName $field
    }

    return $result
}

function Test-VisualContractField {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][string]$ArtifactId
    )

    Test-ArtifactObjectField -Artifact $Artifact -Result $Result -FieldName $FieldName
    if (-not $Artifact.ContainsKey($FieldName)) {
        return
    }

    $contract = ConvertTo-RelayHashtable -InputObject $Artifact[$FieldName]
    if (-not ($contract -is [System.Collections.IDictionary])) {
        return
    }

    $requiredKeys = Get-VisualContractRequiredKeys
    Test-ArtifactRequiredKeys -Artifact $contract -Result $Result -Keys $requiredKeys -ArtifactId "$ArtifactId $FieldName"
    Test-ArtifactStringField -Artifact $contract -Result $Result -FieldName "mode"
    Test-ArtifactEnumField -Artifact $contract -Result $Result -FieldName "mode" -AllowedValues (Get-VisualContractModeValues)

    $detailFields = Get-VisualContractArrayFieldNames
    foreach ($detailField in $detailFields) {
        Test-ArtifactArrayField -Artifact $contract -Result $Result -FieldName $detailField -AllowEmpty
    }

    $mode = [string]$contract["mode"]
    if ($mode -eq "design_md" -and @($contract["design_sources"]).Count -eq 0) {
        Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName mode 'design_md' requires at least one design source."
    }

    if ($mode -ne "not_applicable") {
        $hasDetails = $false
        foreach ($detailField in $detailFields) {
            if (@($contract[$detailField]).Count -gt 0) {
                $hasDetails = $true
                break
            }
        }

        if (-not $hasDetails) {
            Add-ArtifactValidationError -Result $Result -Message "$ArtifactId $FieldName must include at least one non-empty guidance field unless mode is 'not_applicable'."
        }
    }
}

function Test-Phase31VerdictArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = Test-GenericVerdictArtifact -Artifact $Artifact -ArtifactId "phase3-1_verdict.json" -AllowedRollbackPhases @("Phase1", "Phase3")
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("review_checks") -ArtifactId "phase3-1_verdict.json"
    $reviewChecks = Test-ArtifactChecklistField -Artifact $Artifact -Result $result -FieldName "review_checks" -ArtifactId "phase3-1_verdict.json" -RequiredCheckIds @(
        "module_boundaries",
        "public_interfaces",
        "dependency_rules",
        "side_effect_boundaries",
        "state_ownership",
        "encapsulation_consistency",
        "visual_contract_readiness"
    ) -AllowedStatuses @("pass", "warning", "fail")

    $counts = Get-ChecklistStatusCounts -ChecklistMap $reviewChecks
    $verdict = [string]$Artifact["verdict"]
    if ($verdict -eq "go") {
        if ([int]$counts["warning"] -gt 0 -or [int]$counts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict requires design contract review_checks to all pass."
        }
    }
    elseif ($verdict -eq "conditional_go") {
        if ([int]$counts["warning"] -eq 0 -and [int]$counts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one non-pass design contract review check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one must_fix item."
        }
    }
    elseif ($verdict -eq "reject") {
        if ([int]$counts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one failed design contract review check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one must_fix item."
        }
    }

    return $result
}

function Test-Phase4TaskDefinition {
    param(
        [Parameter(Mandatory)]$TaskDefinition,
        [Parameter(Mandatory)]$Result
    )

    $requiredKeys = @("task_id", "purpose", "changed_files", "acceptance_criteria", "boundary_contract", "visual_contract", "dependencies", "tests", "complexity")
    Test-ArtifactRequiredKeys -Artifact $TaskDefinition -Result $Result -Keys $requiredKeys -ArtifactId "phase4_tasks.json tasks[]"
    Test-ArtifactStringField -Artifact $TaskDefinition -Result $Result -FieldName "task_id"
    Test-ArtifactStringField -Artifact $TaskDefinition -Result $Result -FieldName "purpose"
    Test-ArtifactStringField -Artifact $TaskDefinition -Result $Result -FieldName "complexity"
    Test-ArtifactArrayField -Artifact $TaskDefinition -Result $Result -FieldName "changed_files"
    Test-ArtifactArrayField -Artifact $TaskDefinition -Result $Result -FieldName "acceptance_criteria"
    Test-ArtifactArrayField -Artifact $TaskDefinition -Result $Result -FieldName "dependencies" -AllowEmpty
    Test-ArtifactArrayField -Artifact $TaskDefinition -Result $Result -FieldName "tests" -AllowEmpty
    Test-ArtifactObjectField -Artifact $TaskDefinition -Result $Result -FieldName "boundary_contract"
    Test-VisualContractField -Artifact $TaskDefinition -Result $Result -FieldName "visual_contract" -ArtifactId "phase4_tasks.json tasks[]"
    if ($TaskDefinition.ContainsKey("boundary_contract")) {
        $boundaryContract = ConvertTo-RelayHashtable -InputObject $TaskDefinition["boundary_contract"]
        if ($boundaryContract -is [System.Collections.IDictionary]) {
            $boundaryFields = @(
                "module_boundaries",
                "public_interfaces",
                "allowed_dependencies",
                "forbidden_dependencies",
                "side_effect_boundaries",
                "state_ownership"
            )
            Test-ArtifactRequiredKeys -Artifact $boundaryContract -Result $Result -Keys $boundaryFields -ArtifactId "phase4_tasks.json tasks[] boundary_contract"
            foreach ($field in $boundaryFields) {
                if (-not $boundaryContract.ContainsKey($field)) {
                    continue
                }

                $value = ConvertTo-RelayHashtable -InputObject $boundaryContract[$field]
                if ($value -is [System.Collections.IDictionary]) {
                    if ($value.Count -eq 0) {
                        Add-ArtifactValidationError -Result $Result -Message "phase4_tasks.json tasks[] boundary_contract field '$field' must not be empty."
                    }
                    continue
                }

                Test-ArtifactArrayField -Artifact $boundaryContract -Result $Result -FieldName $field
            }
        }
    }
}

function Test-Phase4TasksArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("tasks") -ArtifactId "phase4_tasks.json"
    Test-ArtifactObjectArrayField -Artifact $Artifact -Result $result -FieldName "tasks"

    $taskMap = @{}
    $indegree = @{}
    $adjacency = @{}

    foreach ($task in @($Artifact["tasks"])) {
        $taskObject = ConvertTo-RelayHashtable -InputObject $task
        if (-not ($taskObject -is [System.Collections.IDictionary])) {
            continue
        }

        Test-Phase4TaskDefinition -TaskDefinition $taskObject -Result $result
        $taskId = [string]$taskObject["task_id"]
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            continue
        }

        if ($taskMap.ContainsKey($taskId)) {
            Add-ArtifactValidationError -Result $result -Message "phase4_tasks.json contains duplicate task_id '$taskId'."
            continue
        }

        $taskMap[$taskId] = $taskObject
        $indegree[$taskId] = 0
        $adjacency[$taskId] = New-Object System.Collections.Generic.List[string]
    }

    foreach ($taskId in $taskMap.Keys) {
        foreach ($dependencyId in @($taskMap[$taskId]["dependencies"])) {
            if (-not $taskMap.ContainsKey($dependencyId)) {
                Add-ArtifactValidationError -Result $result -Message "Task '$taskId' depends on unknown task '$dependencyId'."
                continue
            }

            $indegree[$taskId] = [int]$indegree[$taskId] + 1
            $adjacency[$dependencyId].Add($taskId)
        }
    }

    if ($taskMap.Count -gt 0) {
        $queue = New-Object System.Collections.Generic.Queue[string]
        foreach ($taskId in $taskMap.Keys) {
            if ([int]$indegree[$taskId] -eq 0) {
                $queue.Enqueue($taskId)
            }
        }

        $visitedCount = 0
        while ($queue.Count -gt 0) {
            $currentTaskId = $queue.Dequeue()
            $visitedCount++

            foreach ($dependentTaskId in $adjacency[$currentTaskId]) {
                $indegree[$dependentTaskId] = [int]$indegree[$dependentTaskId] - 1
                if ([int]$indegree[$dependentTaskId] -eq 0) {
                    $queue.Enqueue($dependentTaskId)
                }
            }
        }

        if ($visitedCount -lt $taskMap.Count) {
            Add-ArtifactValidationError -Result $result -Message "phase4_tasks.json contains a dependency cycle."
        }
    }

    return $result
}

function Test-Phase41VerdictArtifact {
    param([Parameter(Mandatory)]$Artifact)

    return (Test-GenericVerdictArtifact -Artifact $Artifact -ArtifactId "phase4-1_verdict.json" -AllowedRollbackPhases @("Phase3", "Phase4"))
}

function Test-Phase5ResultArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("task_id", "changed_files", "commands_run", "implementation_summary", "acceptance_criteria_status", "known_issues") -ArtifactId "phase5_result.json"
    Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName "task_id"
    Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName "implementation_summary"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "changed_files"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "commands_run"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "acceptance_criteria_status"
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "known_issues" -AllowEmpty
    return $result
}

function Test-Phase51VerdictArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = Test-GenericVerdictArtifact -Artifact $Artifact -ArtifactId "phase5-1_verdict.json" -AllowedRollbackPhases @("Phase5") -RequireTaskId
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("acceptance_criteria_checks", "review_checks") -ArtifactId "phase5-1_verdict.json"
    Test-ArtifactObjectArrayField -Artifact $Artifact -Result $result -FieldName "acceptance_criteria_checks"
    $reviewChecks = Test-ArtifactChecklistField -Artifact $Artifact -Result $result -FieldName "review_checks" -ArtifactId "phase5-1_verdict.json" -RequiredCheckIds @(
        "selected_task_alignment",
        "acceptance_criteria_coverage",
        "changed_files_audit",
        "test_evidence_review",
        "design_boundary_alignment",
        "visual_contract_alignment"
    ) -AllowedStatuses @("pass", "fail")

    $criterionFailures = 0
    if ($Artifact.ContainsKey("acceptance_criteria_checks")) {
        foreach ($checkRaw in @($Artifact["acceptance_criteria_checks"])) {
            $check = ConvertTo-RelayHashtable -InputObject $checkRaw
            if (-not ($check -is [System.Collections.IDictionary])) {
                continue
            }

            Test-ArtifactRequiredKeys -Artifact $check -Result $result -Keys @("criterion", "status", "notes", "evidence") -ArtifactId "phase5-1_verdict.json acceptance_criteria_checks[]"
            Test-ArtifactStringField -Artifact $check -Result $result -FieldName "criterion"
            Test-ArtifactStringField -Artifact $check -Result $result -FieldName "notes"
            Test-ArtifactEnumField -Artifact $check -Result $result -FieldName "status" -AllowedValues @("pass", "fail")
            Test-ArtifactArrayField -Artifact $check -Result $result -FieldName "evidence"
            if ([string]$check["status"] -eq "fail") {
                $criterionFailures++
            }
        }
    }

    $reviewCounts = Get-ChecklistStatusCounts -ChecklistMap $reviewChecks
    $verdict = [string]$Artifact["verdict"]
    if ($verdict -eq "conditional_go") {
        Add-ArtifactValidationError -Result $result -Message "phase5-1_verdict.json does not allow conditional_go."
    }
    elseif ($verdict -eq "go") {
        if ($criterionFailures -gt 0 -or [int]$reviewCounts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict requires all completion checks to pass."
        }
    }
    elseif ($verdict -eq "reject") {
        if ($criterionFailures -eq 0 -and [int]$reviewCounts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one failed completion check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one must_fix item."
        }
    }

    return $result
}

function Test-Phase52VerdictArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = Test-GenericVerdictArtifact -Artifact $Artifact -ArtifactId "phase5-2_verdict.json" -AllowedRollbackPhases @("Phase5") -RequireTaskId
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys @("security_checks", "open_requirements", "resolved_requirement_ids") -ArtifactId "phase5-2_verdict.json"
    $securityChecks = Test-ArtifactChecklistField -Artifact $Artifact -Result $result -FieldName "security_checks" -ArtifactId "phase5-2_verdict.json" -RequiredCheckIds @(
        "input_validation",
        "authentication_authorization",
        "secret_handling_and_logging",
        "dangerous_side_effects",
        "dependency_surface"
    ) -AllowedStatuses @("pass", "warning", "fail", "not_applicable")
    $openRequirements = Test-ArtifactOpenRequirementsField -Artifact $Artifact -Result $result -FieldName "open_requirements" -ArtifactId "phase5-2_verdict.json" -RequireSourceTaskId
    Test-ArtifactStringArrayField -Artifact $Artifact -Result $result -FieldName "resolved_requirement_ids" -AllowEmpty

    $counts = Get-ChecklistStatusCounts -ChecklistMap $securityChecks
    $verdict = [string]$Artifact["verdict"]
    if ($verdict -eq "go") {
        if ([int]$counts["warning"] -gt 0 -or [int]$counts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict requires security_checks to be pass or not_applicable only."
        }
        if (@($Artifact["open_requirements"]).Count -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict must not include open_requirements."
        }
    }
    elseif ($verdict -eq "conditional_go") {
        if ([int]$counts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict cannot include failed security checks."
        }
        if ([int]$counts["warning"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one warning security check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one must_fix item."
        }
        if (@($Artifact["open_requirements"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one open_requirements item."
        }
    }
    elseif ($verdict -eq "reject") {
        if ([int]$counts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one failed security check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one must_fix item."
        }
        if (@($Artifact["open_requirements"]).Count -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict must not include open_requirements."
        }
    }

    return $result
}

function Test-Phase6ResultArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    $requiredKeys = @("task_id", "test_command", "lint_command", "tests_passed", "tests_failed", "coverage_line", "coverage_branch", "verdict", "conditional_go_reasons", "verification_checks", "open_requirements", "resolved_requirement_ids")
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys $requiredKeys -ArtifactId "phase6_result.json"

    Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName "task_id"
    Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName "test_command"
    Test-ArtifactStringField -Artifact $Artifact -Result $result -FieldName "lint_command"
    Test-ArtifactNumericField -Artifact $Artifact -Result $result -FieldName "tests_passed"
    Test-ArtifactNumericField -Artifact $Artifact -Result $result -FieldName "tests_failed"
    Test-ArtifactNumericField -Artifact $Artifact -Result $result -FieldName "coverage_line"
    Test-ArtifactNumericField -Artifact $Artifact -Result $result -FieldName "coverage_branch"
    Test-ArtifactNumericRangeField -Artifact $Artifact -Result $result -FieldName "coverage_line" -Min 0 -Max 100
    Test-ArtifactNumericRangeField -Artifact $Artifact -Result $result -FieldName "coverage_branch" -Min 0 -Max 100
    Test-ArtifactEnumField -Artifact $Artifact -Result $result -FieldName "verdict" -AllowedValues @("go", "conditional_go", "reject")
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "conditional_go_reasons" -AllowEmpty
    $verificationChecks = Test-ArtifactChecklistField -Artifact $Artifact -Result $result -FieldName "verification_checks" -ArtifactId "phase6_result.json" -RequiredCheckIds @(
        "lint_static_analysis",
        "automated_tests",
        "regression_scope",
        "error_path_coverage",
        "coverage_assessment"
    ) -AllowedStatuses @("pass", "warning", "fail", "not_applicable")
    $openRequirements = Test-ArtifactOpenRequirementsField -Artifact $Artifact -Result $result -FieldName "open_requirements" -ArtifactId "phase6_result.json" -RequireSourceTaskId
    Test-ArtifactStringArrayField -Artifact $Artifact -Result $result -FieldName "resolved_requirement_ids" -AllowEmpty

    $verdict = [string]$Artifact["verdict"]
    $counts = Get-ChecklistStatusCounts -ChecklistMap $verificationChecks
    $testsFailed = 0
    [void][int]::TryParse([string]$Artifact["tests_failed"], [ref]$testsFailed)

    if ($verdict -eq "conditional_go" -and @($Artifact["conditional_go_reasons"]).Count -eq 0) {
        Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one conditional_go_reasons item."
    }
    if ($verdict -eq "go") {
        if ($testsFailed -ne 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict requires tests_failed to be 0."
        }
        if ([int]$counts["warning"] -gt 0 -or [int]$counts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict requires verification_checks to be pass or not_applicable only."
        }
        if (@($Artifact["conditional_go_reasons"]).Count -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict must not include conditional_go_reasons."
        }
        if (@($Artifact["open_requirements"]).Count -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict must not include open_requirements."
        }
    }
    elseif ($verdict -eq "conditional_go") {
        if ($testsFailed -ne 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires tests_failed to be 0."
        }
        if ([int]$counts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict cannot include failed verification checks."
        }
        if ([int]$counts["warning"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one warning verification check."
        }
        if (@($Artifact["open_requirements"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one open_requirements item."
        }
    }
    elseif ($verdict -eq "reject") {
        if ($testsFailed -eq 0 -and [int]$counts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires a failed test or failed verification check."
        }
        if (@($Artifact["open_requirements"]).Count -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict must not include open_requirements."
        }
    }

    return $result
}

function Test-Phase7FollowUpTask {
    param(
        [Parameter(Mandatory)]$TaskContract,
        [Parameter(Mandatory)]$Result
    )

    if (-not ($TaskContract -is [System.Collections.IDictionary])) {
        Add-ArtifactValidationError -Result $Result -Message "follow_up_tasks items must be objects."
        return
    }

    $requiredKeys = @("task_id", "purpose", "changed_files", "acceptance_criteria", "depends_on", "verification", "source_evidence")
    Test-ArtifactRequiredKeys -Artifact $TaskContract -Result $Result -Keys $requiredKeys -ArtifactId "phase7_verdict.json follow_up_tasks[]"
    Test-ArtifactStringField -Artifact $TaskContract -Result $Result -FieldName "task_id"
    Test-ArtifactStringField -Artifact $TaskContract -Result $Result -FieldName "purpose"
    Test-ArtifactArrayField -Artifact $TaskContract -Result $Result -FieldName "changed_files"
    Test-ArtifactArrayField -Artifact $TaskContract -Result $Result -FieldName "acceptance_criteria"
    Test-ArtifactArrayField -Artifact $TaskContract -Result $Result -FieldName "depends_on" -AllowEmpty
    Test-ArtifactArrayField -Artifact $TaskContract -Result $Result -FieldName "verification"
    Test-ArtifactArrayField -Artifact $TaskContract -Result $Result -FieldName "source_evidence"
}

function Test-Phase7VerdictArtifact {
    param([Parameter(Mandatory)]$Artifact)

    $result = New-ArtifactValidationResult
    $requiredKeys = @("verdict", "rollback_phase", "must_fix", "warnings", "evidence", "follow_up_tasks", "review_checks", "human_review", "resolved_requirement_ids")
    Test-ArtifactRequiredKeys -Artifact $Artifact -Result $result -Keys $requiredKeys -ArtifactId "phase7_verdict.json"

    Test-ArtifactEnumField -Artifact $Artifact -Result $result -FieldName "verdict" -AllowedValues @("go", "conditional_go", "reject")
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "must_fix" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "warnings" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "evidence" -AllowEmpty
    Test-ArtifactArrayField -Artifact $Artifact -Result $result -FieldName "follow_up_tasks" -AllowEmpty
    Test-ArtifactStringArrayField -Artifact $Artifact -Result $result -FieldName "resolved_requirement_ids" -AllowEmpty
    $reviewChecks = Test-ArtifactChecklistField -Artifact $Artifact -Result $result -FieldName "review_checks" -ArtifactId "phase7_verdict.json" -RequiredCheckIds @(
        "requirements_alignment",
        "correctness_and_edge_cases",
        "security_and_privacy",
        "test_quality",
        "maintainability",
        "performance_and_operations"
    ) -AllowedStatuses @("pass", "warning", "fail")
    Test-ArtifactObjectField -Artifact $Artifact -Result $result -FieldName "human_review"
    if ($Artifact.ContainsKey("human_review")) {
        $humanReview = ConvertTo-RelayHashtable -InputObject $Artifact["human_review"]
        if ($humanReview -is [System.Collections.IDictionary]) {
            Test-ArtifactRequiredKeys -Artifact $humanReview -Result $result -Keys @("recommendation", "reasons", "focus_points") -ArtifactId "phase7_verdict.json human_review"
            Test-ArtifactEnumField -Artifact $humanReview -Result $result -FieldName "recommendation" -AllowedValues @("required", "recommended", "not_needed")
            Test-ArtifactArrayField -Artifact $humanReview -Result $result -FieldName "reasons" -AllowEmpty
            Test-ArtifactArrayField -Artifact $humanReview -Result $result -FieldName "focus_points" -AllowEmpty
            if ([string]$humanReview["recommendation"] -ne "not_needed" -and @($humanReview["reasons"]).Count -eq 0) {
                Add-ArtifactValidationError -Result $result -Message "human_review reasons must not be empty unless recommendation is not_needed."
            }
        }
    }

    if ($Artifact["verdict"] -eq "conditional_go" -and @($Artifact["follow_up_tasks"]).Count -eq 0) {
        Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one follow_up_tasks item."
    }

    if ($Artifact["verdict"] -eq "reject") {
        if ([string]::IsNullOrWhiteSpace([string]$Artifact["rollback_phase"])) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires rollback_phase."
        }
        elseif ([string]$Artifact["rollback_phase"] -notin @("Phase1", "Phase3", "Phase4", "Phase5", "Phase6")) {
            Add-ArtifactValidationError -Result $result -Message "rollback_phase must be one of: Phase1, Phase3, Phase4, Phase5, Phase6."
        }
    }

    foreach ($followUpTask in @($Artifact["follow_up_tasks"])) {
        Test-Phase7FollowUpTask -TaskContract (ConvertTo-RelayHashtable -InputObject $followUpTask) -Result $result
    }

    $counts = Get-ChecklistStatusCounts -ChecklistMap $reviewChecks
    $verdict = [string]$Artifact["verdict"]
    if ($verdict -eq "go") {
        if ([int]$counts["warning"] -gt 0 -or [int]$counts["fail"] -gt 0) {
            Add-ArtifactValidationError -Result $result -Message "go verdict requires review_checks to all pass."
        }
    }
    elseif ($verdict -eq "conditional_go") {
        if ([int]$counts["warning"] -eq 0 -and [int]$counts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one non-pass review check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "conditional_go verdict requires at least one must_fix item."
        }
    }
    elseif ($verdict -eq "reject") {
        if ([int]$counts["fail"] -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one failed review check."
        }
        if (@($Artifact["must_fix"]).Count -eq 0) {
            Add-ArtifactValidationError -Result $result -Message "reject verdict requires at least one must_fix item."
        }
    }

    return $result
}

function Test-Phase71SummaryArtifact {
    param([Parameter(Mandatory)]$Artifact)

    return (Test-GenericCollectionArtifact -Artifact $Artifact -ArtifactId "phase7-1_summary.json" -StringFields @("summary") -ArrayFields @("merged_changes", "task_results", "residual_risks", "release_notes"))
}

function Test-Phase8ReleaseArtifact {
    param([Parameter(Mandatory)]$Artifact)

    return (Test-GenericCollectionArtifact -Artifact $Artifact -ArtifactId "phase8_release.json" -StringFields @("final_verdict", "release_decision") -ArrayFields @("residual_risks", "follow_up_actions"))
}

function Test-ArtifactContract {
    param(
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)]$Artifact,
        [string]$Phase
    )

    $normalization = ConvertTo-RelayHashtable -InputObject (Normalize-ArtifactForValidation -ArtifactId $ArtifactId -Artifact $Artifact)
    $normalizedArtifact = ConvertTo-RelayHashtable -InputObject $normalization["artifact"]
    $normalizationWarnings = @($normalization["warnings"])
    if (-not ($normalizedArtifact -is [System.Collections.IDictionary])) {
        return [ordered]@{
            valid = $false
            errors = @("Artifact '$ArtifactId' must deserialize to an object.")
            warnings = $normalizationWarnings
        }
    }

    $validationResult = switch ($ArtifactId) {
        "phase0_context.json" { Test-Phase0ContextArtifact -Artifact $normalizedArtifact }
        "phase1_requirements.json" { Test-Phase1RequirementsArtifact -Artifact $normalizedArtifact }
        "phase2_info_gathering.json" { Test-Phase2InfoGatheringArtifact -Artifact $normalizedArtifact }
        "phase3_design.json" { Test-Phase3DesignArtifact -Artifact $normalizedArtifact }
        "phase3-1_verdict.json" { Test-Phase31VerdictArtifact -Artifact $normalizedArtifact }
        "phase4_tasks.json" { Test-Phase4TasksArtifact -Artifact $normalizedArtifact }
        "phase4-1_verdict.json" { Test-Phase41VerdictArtifact -Artifact $normalizedArtifact }
        "phase5_result.json" { Test-Phase5ResultArtifact -Artifact $normalizedArtifact }
        "phase5-1_verdict.json" { Test-Phase51VerdictArtifact -Artifact $normalizedArtifact }
        "phase5-2_verdict.json" { Test-Phase52VerdictArtifact -Artifact $normalizedArtifact }
        "phase6_result.json" { Test-Phase6ResultArtifact -Artifact $normalizedArtifact }
        "phase7_verdict.json" { Test-Phase7VerdictArtifact -Artifact $normalizedArtifact }
        "phase7-1_summary.json" { Test-Phase71SummaryArtifact -Artifact $normalizedArtifact }
        "phase8_release.json" { Test-Phase8ReleaseArtifact -Artifact $normalizedArtifact }
        default {
            [ordered]@{
                valid = $true
                errors = @()
                warnings = @("No validator registered for artifact '$ArtifactId'.")
            }
        }
    }

    $validationResult = ConvertTo-RelayHashtable -InputObject $validationResult
    if ($normalizationWarnings.Count -gt 0) {
        $validationResult["warnings"] = @($validationResult["warnings"]) + $normalizationWarnings
    }

    return $validationResult
}

function Test-ArtifactRef {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$ArtifactRef
    )

    $artifact = Read-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -ArtifactRef $ArtifactRef
    if ($null -eq $artifact) {
        return [ordered]@{
            valid = $false
            errors = @("Artifact could not be loaded from reference.")
            warnings = @()
        }
    }

    $ref = ConvertTo-RelayHashtable -InputObject $ArtifactRef
    return (Test-ArtifactContract -ArtifactId $ref["artifact_id"] -Artifact $artifact -Phase $ref["phase"])
}
