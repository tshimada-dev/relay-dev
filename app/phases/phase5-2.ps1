function Get-Phase52Definition {
    return (New-PhaseArtifactDefinition -Phase "Phase5-2" -Role "reviewer" -InputContract @(
        @{ artifact_id = "phase5_result.json"; scope = "task"; phase = "Phase5"; required = $false },
        @{ artifact_id = "phase5-1_verdict.json"; scope = "task"; phase = "Phase5-1"; required = $false }
    ) -OutputContract @(
        @{ artifact_id = "phase5-2_security_check.md"; scope = "task"; format = "markdown"; required = $true },
        @{ artifact_id = "phase5-2_verdict.json"; scope = "task"; format = "json"; required = $true }
    ) -ValidatorArtifactId "phase5-2_verdict.json" -TransitionRules @{ go = "Phase6"; conditional_go = "Phase6"; reject = @("Phase5") })
}

function Write-Phase52Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    return (Write-TaskScopedPhaseArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -TaskId $TaskId -Phase "Phase5-2" -MarkdownArtifactId "phase5-2_security_check.md" -MarkdownContent $MarkdownContent -JsonArtifactId "phase5-2_verdict.json" -JsonContent $JsonContent)
}
