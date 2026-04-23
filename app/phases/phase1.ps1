function Get-Phase1Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase1" -Role "implementer" -InputContract @(
        @{ artifact_id = "phase0_context.json"; scope = "run"; phase = "Phase0"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase1_requirements.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase1_requirements.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase1_requirements.json" -TransitionRules @{ go = "Phase3" })
}

function Write-Phase1Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase1" -MarkdownArtifactId "phase1_requirements.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase1_requirements.json" -JsonContent $JsonContent)
}
