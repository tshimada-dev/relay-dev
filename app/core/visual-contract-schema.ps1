function Get-VisualContractSchema {
    return [ordered]@{
        mode = [ordered]@{
            type = "enum"
            allowed_values = @("not_applicable", "design_md", "reference_only", "custom")
            prompt_description = '`not_applicable` / `design_md` / `reference_only` / `custom`'
        }
        design_sources = [ordered]@{
            type = "array"
            prompt_description = '`DESIGN.md`、既存画面、参照URLなどの出典'
        }
        visual_constraints = [ordered]@{
            type = "array"
            prompt_description = "色、タイポグラフィ、余白、密度、トーン、禁止事項"
        }
        component_patterns = [ordered]@{
            type = "array"
            prompt_description = "ボタン、カード、フォーム、ナビゲーションなどの見た目・状態"
        }
        responsive_expectations = [ordered]@{
            type = "array"
            prompt_description = "breakpoint ごとの詰め替え、touch target、折り返しルール"
        }
        interaction_guidelines = [ordered]@{
            type = "array"
            prompt_description = "hover/focus/loading/empty/error/success などの振る舞い"
        }
    }
}

function Get-VisualContractRequiredKeys {
    return @((Get-VisualContractSchema).Keys)
}

function Get-VisualContractModeValues {
    return @((Get-VisualContractSchema)["mode"]["allowed_values"])
}

function Get-VisualContractArrayFieldNames {
    $schema = Get-VisualContractSchema
    $fields = New-Object System.Collections.Generic.List[string]
    foreach ($fieldName in $schema.Keys) {
        $fieldSchema = $schema[$fieldName]
        if ([string]$fieldSchema["type"] -eq "array") {
            $fields.Add([string]$fieldName)
        }
    }

    return @($fields.ToArray())
}

function Get-VisualContractPromptGuidance {
    $schema = Get-VisualContractSchema
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("全 detail field は JSON 配列にすること。文字列配列またはオブジェクト配列は許可するが、連想オブジェクトは許可しない。")

    foreach ($fieldName in $schema.Keys) {
        $fieldSchema = $schema[$fieldName]
        $description = [string]$fieldSchema["prompt_description"]
        $type = [string]$fieldSchema["type"]
        if ($type -eq "enum") {
            $lines.Add(('- `{0}`: {1}' -f $fieldName, $description))
            continue
        }

        $lines.Add(('- `{0}`: array. {1}' -f $fieldName, $description))
    }

    return ($lines -join "`n")
}

function Expand-VisualContractPromptTemplates {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    return $Text.Replace("{{VISUAL_CONTRACT_SCHEMA}}", (Get-VisualContractPromptGuidance))
}

function Convert-VisualContractMapEntryToArrayItem {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Value
    )

    $normalizedValue = ConvertTo-RelayHashtable -InputObject $Value
    if ($normalizedValue -is [System.Collections.IDictionary]) {
        $entry = [ordered]@{
            id = $Key
        }
        foreach ($subKey in $normalizedValue.Keys) {
            $entry[[string]$subKey] = $normalizedValue[$subKey]
        }

        return $entry
    }

    if (
        $null -ne $normalizedValue -and
        $normalizedValue -is [System.Collections.IEnumerable] -and
        -not ($normalizedValue -is [string])
    ) {
        return [ordered]@{
            id = $Key
            items = [object[]]@($normalizedValue)
        }
    }

    return [ordered]@{
        id = $Key
        value = $normalizedValue
    }
}

function Convert-VisualContractFieldValueToArray {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$FieldPath
    )

    $normalizedValue = ConvertTo-RelayHashtable -InputObject $Value
    if ($normalizedValue -is [System.Collections.IDictionary]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($entryKey in $normalizedValue.Keys) {
            $items.Add((Convert-VisualContractMapEntryToArrayItem -Key ([string]$entryKey) -Value $normalizedValue[$entryKey]))
        }

        return [ordered]@{
            changed = $true
            items = [object[]]@($items.ToArray())
            warnings = @("Normalized $FieldPath from object map to array for schema compatibility.")
        }
    }

    if ($null -eq $normalizedValue) {
        return [ordered]@{
            changed = $true
            items = @()
            warnings = @("Normalized $FieldPath from null to an empty array for schema compatibility.")
        }
    }

    if ($normalizedValue -is [string]) {
        return [ordered]@{
            changed = $true
            items = @($normalizedValue)
            warnings = @("Normalized $FieldPath from scalar to array for schema compatibility.")
        }
    }

    if ($normalizedValue -is [System.Collections.IEnumerable]) {
        return [ordered]@{
            changed = $false
            items = [object[]]@($normalizedValue)
            warnings = @()
        }
    }

    return [ordered]@{
        changed = $true
        items = @($normalizedValue)
        warnings = @("Normalized $FieldPath from scalar to array for schema compatibility.")
    }
}

function Normalize-VisualContract {
    param(
        [AllowNull()]$VisualContract,
        [string]$Path = "visual_contract"
    )

    $contract = ConvertTo-RelayHashtable -InputObject $VisualContract
    if (-not ($contract -is [System.Collections.IDictionary])) {
        return [ordered]@{
            value = $VisualContract
            changed = $false
            warnings = @()
        }
    }

    $normalizedContract = [ordered]@{}
    foreach ($key in $contract.Keys) {
        $normalizedContract[[string]$key] = $contract[$key]
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $changed = $false
    foreach ($fieldName in Get-VisualContractArrayFieldNames) {
        if ($normalizedContract.Keys -notcontains $fieldName) {
            continue
        }

        $fieldResult = ConvertTo-RelayHashtable -InputObject (Convert-VisualContractFieldValueToArray -Value $normalizedContract[$fieldName] -FieldPath "$Path.$fieldName")
        $normalizedContract[$fieldName] = [object[]]@($fieldResult["items"])
        if ([bool]$fieldResult["changed"]) {
            $changed = $true
            foreach ($warning in @($fieldResult["warnings"])) {
                $warnings.Add([string]$warning)
            }
        }
    }

    return [ordered]@{
        value = $normalizedContract
        changed = $changed
        warnings = @($warnings.ToArray())
    }
}

function Add-NormalizationWarnings {
    param(
        [Parameter(Mandatory)]$Collector,
        [AllowNull()]$Warnings
    )

    foreach ($warning in @($Warnings)) {
        $Collector.Add([string]$warning)
    }
}

function Convert-ScalarFieldValueToArray {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$FieldPath
    )

    $normalizedValue = ConvertTo-RelayHashtable -InputObject $Value
    if ($null -eq $normalizedValue) {
        return [ordered]@{
            changed = $true
            items = @()
            warnings = @("Normalized $FieldPath from null to an empty array for schema compatibility.")
        }
    }

    if ($normalizedValue -is [string]) {
        return [ordered]@{
            changed = $true
            items = @($normalizedValue)
            warnings = @("Normalized $FieldPath from scalar to array for schema compatibility.")
        }
    }

    if ($normalizedValue -is [System.Collections.IDictionary]) {
        return [ordered]@{
            changed = $true
            items = @($normalizedValue)
            warnings = @("Normalized $FieldPath from object to single-item array for schema compatibility.")
        }
    }

    if ($normalizedValue -is [System.Collections.IEnumerable]) {
        return [ordered]@{
            changed = $false
            items = [object[]]@($normalizedValue)
            warnings = @()
        }
    }

    return [ordered]@{
        changed = $true
        items = @($normalizedValue)
        warnings = @("Normalized $FieldPath from scalar to array for schema compatibility.")
    }
}

function Normalize-ArrayFieldOnObject {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$FieldName,
        [string]$Path = $FieldName
    )

    if (-not ($Target -is [System.Collections.IDictionary]) -or $Target.Keys -notcontains $FieldName) {
        return [ordered]@{
            changed = $false
            warnings = @()
        }
    }

    $fieldResult = ConvertTo-RelayHashtable -InputObject (Convert-ScalarFieldValueToArray -Value $Target[$FieldName] -FieldPath $Path)
    $Target[$FieldName] = [object[]]@($fieldResult["items"])
    return [ordered]@{
        changed = [bool]$fieldResult["changed"]
        warnings = @($fieldResult["warnings"])
    }
}

function Copy-NormalizationObject {
    param([Parameter(Mandatory)]$Value)

    $map = ConvertTo-RelayHashtable -InputObject $Value
    if (-not ($map -is [System.Collections.IDictionary])) {
        return $Value
    }

    $copy = [ordered]@{}
    foreach ($key in $map.Keys) {
        $copy[[string]$key] = $map[$key]
    }

    return $copy
}

function Normalize-EntryArrayFields {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$CollectionField,
        [Parameter(Mandatory)][string[]]$NestedArrayFields,
        [string]$Path = $CollectionField
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    $changed = $false

    $collectionResult = Normalize-ArrayFieldOnObject -Target $Target -FieldName $CollectionField -Path $Path
    if ([bool]$collectionResult["changed"]) {
        $changed = $true
        Add-NormalizationWarnings -Collector $warnings -Warnings $collectionResult["warnings"]
    }

    if ($Target.Keys -notcontains $CollectionField) {
        return [ordered]@{
            changed = $changed
            warnings = @($warnings.ToArray())
        }
    }

    $collection = $Target[$CollectionField]
    if ($null -eq $collection -or ($collection -is [string]) -or -not ($collection -is [System.Collections.IEnumerable])) {
        return [ordered]@{
            changed = $changed
            warnings = @($warnings.ToArray())
        }
    }

    $normalizedEntries = New-Object System.Collections.Generic.List[object]
    $entryIndex = 0
    foreach ($entryRaw in @($collection)) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        if ($entry -is [System.Collections.IDictionary]) {
            $normalizedEntry = Copy-NormalizationObject -Value $entry
            foreach ($nestedField in $NestedArrayFields) {
                $nestedPath = "{0}[{1}].{2}" -f $Path, $entryIndex, $nestedField
                $nestedResult = Normalize-ArrayFieldOnObject -Target $normalizedEntry -FieldName $nestedField -Path $nestedPath
                if ([bool]$nestedResult["changed"]) {
                    $changed = $true
                    Add-NormalizationWarnings -Collector $warnings -Warnings $nestedResult["warnings"]
                }
            }

            $normalizedEntries.Add($normalizedEntry)
        }
        else {
            $normalizedEntries.Add($entryRaw)
        }

        $entryIndex += 1
    }

    $Target[$CollectionField] = [object[]]@($normalizedEntries.ToArray())
    return [ordered]@{
        changed = $changed
        warnings = @($warnings.ToArray())
    }
}

function Normalize-NestedObjectArrayFields {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$ObjectField,
        [Parameter(Mandatory)][string[]]$NestedArrayFields,
        [string]$Path = $ObjectField
    )

    if (-not ($Target -is [System.Collections.IDictionary]) -or $Target.Keys -notcontains $ObjectField) {
        return [ordered]@{
            changed = $false
            warnings = @()
        }
    }

    $nestedObject = ConvertTo-RelayHashtable -InputObject $Target[$ObjectField]
    if (-not ($nestedObject -is [System.Collections.IDictionary])) {
        return [ordered]@{
            changed = $false
            warnings = @()
        }
    }

    $normalizedObject = Copy-NormalizationObject -Value $nestedObject
    $warnings = New-Object System.Collections.Generic.List[string]
    $changed = $false
    foreach ($nestedField in $NestedArrayFields) {
        $nestedPath = "{0}.{1}" -f $Path, $nestedField
        $nestedResult = Normalize-ArrayFieldOnObject -Target $normalizedObject -FieldName $nestedField -Path $nestedPath
        if ([bool]$nestedResult["changed"]) {
            $changed = $true
            Add-NormalizationWarnings -Collector $warnings -Warnings $nestedResult["warnings"]
        }
    }

    $Target[$ObjectField] = $normalizedObject
    return [ordered]@{
        changed = $changed
        warnings = @($warnings.ToArray())
    }
}

function Get-ArtifactArrayNormalizationSpec {
    param([Parameter(Mandatory)][string]$ArtifactId)

    switch ($ArtifactId) {
        "phase3-1_verdict.json" {
            return [ordered]@{
                top_level_array_fields = @("must_fix", "warnings", "evidence")
                entry_array_fields = [ordered]@{
                    review_checks = @("evidence")
                }
                nested_object_array_fields = [ordered]@{}
            }
        }
        "phase5-1_verdict.json" {
            return [ordered]@{
                top_level_array_fields = @("must_fix", "warnings", "evidence")
                entry_array_fields = [ordered]@{
                    acceptance_criteria_checks = @("evidence")
                    review_checks = @("evidence")
                }
                nested_object_array_fields = [ordered]@{}
            }
        }
        "phase5-2_verdict.json" {
            return [ordered]@{
                top_level_array_fields = @("must_fix", "warnings", "evidence", "resolved_requirement_ids")
                entry_array_fields = [ordered]@{
                    security_checks = @("evidence")
                    open_requirements = @("required_artifacts")
                }
                nested_object_array_fields = [ordered]@{}
            }
        }
        "phase6_result.json" {
            return [ordered]@{
                top_level_array_fields = @("conditional_go_reasons", "resolved_requirement_ids")
                entry_array_fields = [ordered]@{
                    verification_checks = @("evidence")
                    open_requirements = @("required_artifacts")
                }
                nested_object_array_fields = [ordered]@{}
            }
        }
        "phase7_verdict.json" {
            return [ordered]@{
                top_level_array_fields = @("must_fix", "warnings", "evidence", "resolved_requirement_ids", "follow_up_tasks")
                entry_array_fields = [ordered]@{
                    review_checks = @("evidence")
                    follow_up_tasks = @("changed_files", "acceptance_criteria", "depends_on", "verification", "source_evidence")
                }
                nested_object_array_fields = [ordered]@{
                    human_review = @("reasons", "focus_points")
                }
            }
        }
        default {
            return $null
        }
    }
}

function Normalize-ArtifactForValidation {
    param(
        [Parameter(Mandatory)][string]$ArtifactId,
        [AllowNull()]$Artifact
    )

    $normalizedArtifact = ConvertTo-RelayHashtable -InputObject $Artifact
    if (-not ($normalizedArtifact -is [System.Collections.IDictionary])) {
        return [ordered]@{
            artifact = $Artifact
            changed = $false
            warnings = @()
        }
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $changed = $false

    switch ($ArtifactId) {
        "phase3_design.json" {
            if ($normalizedArtifact.Keys -contains "visual_contract") {
                $contractResult = ConvertTo-RelayHashtable -InputObject (Normalize-VisualContract -VisualContract $normalizedArtifact["visual_contract"] -Path "visual_contract")
                $normalizedArtifact["visual_contract"] = $contractResult["value"]
                if ([bool]$contractResult["changed"]) {
                    $changed = $true
                    foreach ($warning in @($contractResult["warnings"])) {
                        $warnings.Add([string]$warning)
                    }
                }
            }
        }
        "phase4_tasks.json" {
            if ($normalizedArtifact.Keys -contains "tasks") {
                $normalizedTasks = New-Object System.Collections.Generic.List[object]
                $taskIndex = 0
                foreach ($taskRaw in @($normalizedArtifact["tasks"])) {
                    $task = ConvertTo-RelayHashtable -InputObject $taskRaw
                    if ($task -is [System.Collections.IDictionary] -and $task.Keys -contains "visual_contract") {
                        $taskLabel = if ([string]::IsNullOrWhiteSpace([string]$task["task_id"])) { "tasks[$taskIndex]" } else { "tasks[$([string]$task["task_id"])]" }
                        $contractResult = ConvertTo-RelayHashtable -InputObject (Normalize-VisualContract -VisualContract $task["visual_contract"] -Path "$taskLabel.visual_contract")
                        $task["visual_contract"] = $contractResult["value"]
                        if ([bool]$contractResult["changed"]) {
                            $changed = $true
                            foreach ($warning in @($contractResult["warnings"])) {
                                $warnings.Add([string]$warning)
                            }
                        }
                    }

                    $normalizedTasks.Add($task)
                    $taskIndex += 1
                }

                $normalizedArtifact["tasks"] = [object[]]@($normalizedTasks.ToArray())
            }
        }
    }

    $arrayNormalizationSpec = ConvertTo-RelayHashtable -InputObject (Get-ArtifactArrayNormalizationSpec -ArtifactId $ArtifactId)
    if ($arrayNormalizationSpec -is [System.Collections.IDictionary]) {
        foreach ($fieldName in @($arrayNormalizationSpec["top_level_array_fields"])) {
            $fieldResult = Normalize-ArrayFieldOnObject -Target $normalizedArtifact -FieldName ([string]$fieldName) -Path ([string]$fieldName)
            if ([bool]$fieldResult["changed"]) {
                $changed = $true
                Add-NormalizationWarnings -Collector $warnings -Warnings $fieldResult["warnings"]
            }
        }

        $entryArrayFields = ConvertTo-RelayHashtable -InputObject $arrayNormalizationSpec["entry_array_fields"]
        foreach ($collectionField in $entryArrayFields.Keys) {
            $entryResult = Normalize-EntryArrayFields -Target $normalizedArtifact -CollectionField ([string]$collectionField) -NestedArrayFields @($entryArrayFields[$collectionField]) -Path ([string]$collectionField)
            if ([bool]$entryResult["changed"]) {
                $changed = $true
                Add-NormalizationWarnings -Collector $warnings -Warnings $entryResult["warnings"]
            }
        }

        $nestedObjectFields = ConvertTo-RelayHashtable -InputObject $arrayNormalizationSpec["nested_object_array_fields"]
        foreach ($objectField in $nestedObjectFields.Keys) {
            $nestedObjectResult = Normalize-NestedObjectArrayFields -Target $normalizedArtifact -ObjectField ([string]$objectField) -NestedArrayFields @($nestedObjectFields[$objectField]) -Path ([string]$objectField)
            if ([bool]$nestedObjectResult["changed"]) {
                $changed = $true
                Add-NormalizationWarnings -Collector $warnings -Warnings $nestedObjectResult["warnings"]
            }
        }
    }

    return [ordered]@{
        artifact = $normalizedArtifact
        changed = $changed
        warnings = @($warnings.ToArray())
    }
}
