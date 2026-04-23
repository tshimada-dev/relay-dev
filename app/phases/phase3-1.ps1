function Get-Phase31Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase3-1" -Role "reviewer" -InputContract @(
        @{ artifact_id = "phase3_design.json"; scope = "run"; phase = "Phase3"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase3-1_design_review.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase3-1_verdict.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase3-1_verdict.json" -TransitionRules @{ go = "Phase4"; conditional_go = "Phase3"; reject = @("Phase1", "Phase3") })
}

function Write-Phase31Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase3-1" -MarkdownArtifactId "phase3-1_design_review.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase3-1_verdict.json" -JsonContent $JsonContent)
}
