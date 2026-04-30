if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}

function Read-RepairPromptOptionalUtf8File {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Format-RepairPromptArtifactLines {
    param(
        [Parameter(Mandatory)]$MaterializedArtifacts
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($artifactRaw in @($MaterializedArtifacts)) {
        $artifact = ConvertTo-RelayHashtable -InputObject $artifactRaw
        $scope = if ($artifact["scope"]) { [string]$artifact["scope"] } else { "run" }
        $taskSuffix = if (-not [string]::IsNullOrWhiteSpace([string]$artifact["task_id"])) { " task=$([string]$artifact["task_id"])" } else { "" }
        $lines.Add("- [$scope] $([string]$artifact["artifact_id"]) => $([string]$artifact["path"])$taskSuffix") | Out-Null
    }

    return @($lines.ToArray())
}

function New-RepairPromptText {
    param(
        [Parameter(Mandatory)]$RepairJobSpec,
        [Parameter(Mandatory)]$PhaseDefinition,
        [Parameter(Mandatory)]$ValidationResult,
        [Parameter(Mandatory)]$MaterializedArtifacts,
        [AllowNull()]$ArchivedContext,
        [AllowNull()]$RepairDecision,
        [AllowNull()]$OriginalJobSpec
    )

    $repairJob = ConvertTo-RelayHashtable -InputObject $RepairJobSpec
    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $validation = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $decision = ConvertTo-RelayHashtable -InputObject $RepairDecision
    $originalJob = ConvertTo-RelayHashtable -InputObject $OriginalJobSpec
    $promptPackage = ConvertTo-RelayHashtable -InputObject $repairJob["prompt_package"]
    $lineBreak = "`n"

    $sections = New-Object System.Collections.Generic.List[string]

    $systemText = Read-RepairPromptOptionalUtf8File -Path ([string]$promptPackage["system_prompt_ref"])
    if (-not [string]::IsNullOrWhiteSpace($systemText)) {
        $sections.Add("## System$lineBreak$systemText") | Out-Null
    }

    $phaseText = Read-RepairPromptOptionalUtf8File -Path ([string]$promptPackage["phase_prompt_ref"])
    if (-not [string]::IsNullOrWhiteSpace($phaseText)) {
        $sections.Add("## Phase Instructions$lineBreak$phaseText") | Out-Null
    }

    $providerText = Read-RepairPromptOptionalUtf8File -Path ([string]$promptPackage["provider_hints_ref"])
    if (-not [string]::IsNullOrWhiteSpace($providerText)) {
        $sections.Add("## Provider Hints$lineBreak$providerText") | Out-Null
    }

    $contextLines = @(
        "RunId: $([string]$repairJob["run_id"])",
        "RepairJobId: $([string]$repairJob["job_id"])",
        "OriginalJobId: $([string]$repairJob["repair_target_job_id"])",
        "Phase: $([string]$repairJob["phase"])",
        "Role: $([string]$repairJob["role"])",
        "TaskId: $([string]$repairJob["task_id"])",
        "Project root: $([string]$repairJob["project_root"])",
        "Working directory: $([string]$repairJob["working_directory"])",
        "Edit only the staged required artifacts listed below.",
        "Do not modify source code, tests, configs, canonical artifacts, archived artifacts, run-state files, queue/status.yaml, or events.jsonl."
    )
    $sections.Add("## Execution Context$lineBreak$($contextLines -join $lineBreak)") | Out-Null

    $repairGoalLines = @(
        "The previous phase job already ran. Your job is to repair the current staged artifacts for this same phase so validation can pass.",
        "Preserve the artifact meaning. Make the smallest possible fix.",
        "Do not create new outputs outside the staged artifact paths for this phase."
    )
    if ($originalJob) {
        $repairGoalLines += "Original phase role: $([string]$originalJob["role"])"
    }
    $sections.Add("## Repair Goal$lineBreak$($repairGoalLines -join $lineBreak)") | Out-Null

    $artifactLines = Format-RepairPromptArtifactLines -MaterializedArtifacts $MaterializedArtifacts
    if ($artifactLines.Count -gt 0) {
        $sections.Add("## Required Outputs$lineBreak$($artifactLines -join $lineBreak)") | Out-Null
    }

    if ($validation) {
        $validationJson = ($validation | ConvertTo-Json -Depth 20)
        $sections.Add("## Validation Errors$lineBreak$validationJson") | Out-Null
    }

    if ($decision) {
        $decisionJson = ($decision | ConvertTo-Json -Depth 20)
        $sections.Add("## Repair Policy$lineBreak$decisionJson") | Out-Null
    }

    $archivedContextObject = ConvertTo-RelayHashtable -InputObject $ArchivedContext
    $archivedRefs = @($archivedContextObject["archived_context_refs"])
    if ($archivedRefs.Count -gt 0) {
        $archivedLines = New-Object System.Collections.Generic.List[string]
        foreach ($refRaw in $archivedRefs) {
            $ref = ConvertTo-RelayHashtable -InputObject $refRaw
            $archivedLines.Add("- $([string]$ref["artifact_id"]) => $([string]$ref["path"]) (snapshot: $([string]$ref["snapshot_id"]))") | Out-Null
        }
        $archivedIntro = @(
            "These are prior-version JSON snapshots for this same phase.",
            "Use them only as fallback context. Do not copy semantic decisions from them unless needed to preserve the current artifact meaning."
        )
        $sections.Add("## Archived Phase JSON Context$lineBreak$($archivedIntro -join $lineBreak)$lineBreak$($archivedLines -join $lineBreak)") | Out-Null
    }

    $repairRules = @(
        "Fix only syntax, escaping, serialization, materialization, or schema-shape issues unless the repair policy explicitly allows more.",
        "If immutable fields are listed, they must remain semantically unchanged.",
        "Do not change verdict values, rollback targets, security status fields, or must-fix decisions.",
        "When finished, stop after updating the staged artifacts in place."
    )
    $sections.Add("## Repair Rules$lineBreak$($repairRules -join $lineBreak)") | Out-Null

    return ($sections -join "`n`n")
}
