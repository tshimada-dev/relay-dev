function Get-Phase4Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase4" -Role "implementer" -InputContract @(
        @{ artifact_id = "phase3_design.json"; scope = "run"; phase = "Phase3"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase4_task_breakdown.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase4_tasks.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase4_tasks.json" -TransitionRules @{ go = "Phase4-1" })
}

function Write-Phase4Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase4" -MarkdownArtifactId "phase4_task_breakdown.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase4_tasks.json" -JsonContent $JsonContent)
}
