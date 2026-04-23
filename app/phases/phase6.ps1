function Get-Phase6Definition {
    return [ordered]@{
        phase = "Phase6"
        role = "reviewer"
        input_contract = @(
            @{ artifact_id = "phase5_result.json"; scope = "task"; phase = "Phase5"; required = $false }
        )
        output_contract = @(
            @{ artifact_id = "phase6_testing.md"; scope = "task"; format = "markdown"; required = $true },
            @{ artifact_id = "phase6_result.json"; scope = "task"; format = "json"; required = $true },
            @{ artifact_id = "test_output.log"; scope = "task"; format = "text"; required = $true },
            @{ artifact_id = "junit.xml"; scope = "task"; format = "xml"; required = $false },
            @{ artifact_id = "coverage.json"; scope = "task"; format = "json"; required = $false }
        )
        validator = @{
            artifact_id = "phase6_result.json"
        }
        transition_rules = @{
            go = "Phase7"
            conditional_go = "Phase5"
        }
    }
}

function Write-Phase6Artifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)]$JsonContent,
        [Parameter(Mandatory)][string]$TestOutput,
        [string]$JunitXml,
        [AllowNull()]$CoverageJson
    )

    $markdownPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase "Phase6" -ArtifactId "phase6_testing.md" -Content $MarkdownContent
    $jsonPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase "Phase6" -ArtifactId "phase6_result.json" -Content $JsonContent -AsJson
    $testOutputPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase "Phase6" -ArtifactId "test_output.log" -Content $TestOutput

    $junitPath = $null
    if (-not [string]::IsNullOrWhiteSpace($JunitXml)) {
        $junitPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase "Phase6" -ArtifactId "junit.xml" -Content $JunitXml
    }

    $coveragePath = $null
    if ($null -ne $CoverageJson) {
        $coveragePath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase "Phase6" -ArtifactId "coverage.json" -Content $CoverageJson -AsJson
    }

    $validation = Test-ArtifactContract -ArtifactId "phase6_result.json" -Artifact $JsonContent -Phase "Phase6"

    return [ordered]@{
        markdown_path = $markdownPath
        json_path = $jsonPath
        test_output_path = $testOutputPath
        junit_path = $junitPath
        coverage_path = $coveragePath
        validation = $validation
    }
}
