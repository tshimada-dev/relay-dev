function Get-Phase8Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase8" -Role "implementer" -InputContract @(
        @{ artifact_id = "phase7-1_summary.json"; scope = "run"; phase = "Phase7-1"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase8_release.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase8_release.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase8_release.json" -TransitionRules @{})
}

function Write-Phase8Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase8" -MarkdownArtifactId "phase8_release.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase8_release.json" -JsonContent $JsonContent)
}
