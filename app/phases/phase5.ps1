function Get-Phase5Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase5" -Role "implementer" -InputContract @(
        @{ artifact_id = "phase4_tasks.json"; scope = "run"; phase = "Phase4"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase5_implementation.md"; scope = "task"; format = "markdown"; required = $true },
        @{ artifact_id = "phase5_result.json"; scope = "task"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase5_result.json" -TransitionRules @{ go = "Phase5-1" })
}

function Write-Phase5Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-TaskScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -TaskId $TaskId -Phase "Phase5" -MarkdownArtifactId "phase5_implementation.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase5_result.json" -JsonContent $JsonContent)
}
