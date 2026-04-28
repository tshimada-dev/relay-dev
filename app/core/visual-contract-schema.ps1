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

    return [ordered]@{
        artifact = $normalizedArtifact
        changed = $changed
        warnings = @($warnings.ToArray())
    }
}
