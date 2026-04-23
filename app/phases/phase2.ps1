function Get-Phase2Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase2" -Role "implementer" -InputContract @(
        @{ artifact_id = "phase1_requirements.md"; scope = "run"; phase = "Phase1"; required = $false },
        @{ artifact_id = "phase1_requirements.json"; scope = "run"; phase = "Phase1"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase2_info_gathering.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase2_info_gathering.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase2_info_gathering.json" -TransitionRules @{ go = "Phase3"; reject = @("Phase1") })
}

function Write-Phase2Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase2" -MarkdownArtifactId "phase2_info_gathering.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase2_info_gathering.json" -JsonContent $JsonContent)
}
