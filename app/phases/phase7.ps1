function Get-Phase7Definition {
    return [ordered]@{
        phase = "Phase7"
        role = "reviewer"
        input_contract = @(
            @{ artifact_id = "phase6_result.json"; scope = "task"; phase = "Phase6"; required = $false },
            @{ artifact_id = "phase3_design.json"; scope = "run"; phase = "Phase3"; required = $false }
        )
        output_contract = @(
            @{ artifact_id = "phase7_pr_review.md"; scope = "run"; format = "markdown"; required = $true },
            @{ artifact_id = "phase7_verdict.json"; scope = "run"; format = "json"; required = $true }
        )
        validator = @{
            artifact_id = "phase7_verdict.json"
        }
        transition_rules = @{
            go = "Phase7-1"
            conditional_go = "Phase5"
            reject = @("Phase1", "Phase3", "Phase4", "Phase5", "Phase6")
        }
    }
}

function Write-Phase7Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    $markdownPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope run -Phase "Phase7" -ArtifactId "phase7_pr_review.md" -Content $MarkdownContent
    $jsonPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json" -Content $JsonContent -AsJson
    $validation = Test-ArtifactContract -ArtifactId "phase7_verdict.json" -Artifact $JsonContent -Phase "Phase7"

    return [ordered]@{
        markdown_path = $markdownPath
        json_path = $jsonPath
        validation = $validation
    }
}
