function Get-Phase0Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase0" -Role "implementer" -InputContract @() -OutputContract @(
        @{ artifact_id = "phase0_context.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase0_context.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase0_context.json" -TransitionRules @{ go = "Phase1" })
}

function Write-Phase0Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase0" -MarkdownArtifactId "phase0_context.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase0_context.json" -JsonContent $JsonContent)
}
