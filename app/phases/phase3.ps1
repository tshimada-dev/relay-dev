function Get-Phase3Definition {
    return [ordered]@{
        phase = "Phase3"
        role = "implementer"
        input_contract = @(
            @{ artifact_id = "phase1_requirements.md"; scope = "run"; phase = "Phase1"; required = $false },
            @{ artifact_id = "phase2_info_gathering.md"; scope = "run"; phase = "Phase2"; required = $false }
        )
        output_contract = @(
            @{ artifact_id = "phase3_design.md"; scope = "run"; format = "markdown"; required = $true },
            @{ artifact_id = "phase3_design.json"; scope = "run"; format = "json"; required = $true }
        )
        validator = @{
            artifact_id = "phase3_design.json"
        }
        transition_rules = @{
            go = "Phase3-1"
        }
    }
}

function Write-Phase3Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent
    )

    $markdownPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope run -Phase "Phase3" -ArtifactId "phase3_design.md" -Content $MarkdownContent
    $jsonPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope run -Phase "Phase3" -ArtifactId "phase3_design.json" -Content $JsonContent -AsJson
    $validation = Test-ArtifactContract -ArtifactId "phase3_design.json" -Artifact $JsonContent -Phase "Phase3"

    return [ordered]@{
        markdown_path = $markdownPath
        json_path = $jsonPath
        validation = $validation
    }
}
