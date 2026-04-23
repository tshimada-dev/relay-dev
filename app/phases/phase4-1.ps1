function Get-Phase41Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase4-1" -Role "reviewer" -InputContract @(
        @{ artifact_id = "phase4_tasks.json"; scope = "run"; phase = "Phase4"; required = $false },
        @{ artifact_id = "phase3_design.json"; scope = "run"; phase = "Phase3"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase4-1_task_review.md"; scope = "run"; format = "markdown"; required = $true },
        @{ artifact_id = "phase4-1_verdict.json"; scope = "run"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase4-1_verdict.json" -TransitionRules @{ go = "Phase5"; conditional_go = "Phase4"; reject = @("Phase3", "Phase4") })
}

function Write-Phase41Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-RunScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Phase "Phase4-1" -MarkdownArtifactId "phase4-1_task_review.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase4-1_verdict.json" -JsonContent $JsonContent)
}
