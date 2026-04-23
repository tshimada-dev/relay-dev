function Get-Phase71Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase7-1" -Role "implementer" -InputContract @(
        @{ artifact_id = "phase7_verdict.json"; scope = "run"; phase = "Phase7"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase7-1_pr_summary.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase7-1_summary.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase7-1_summary.json" -TransitionRules @{ go = "Phase8" })
}

function Write-Phase71Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase7-1" -MarkdownArtifactId "phase7-1_pr_summary.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase7-1_summary.json" -JsonContent $JsonContent)
}
