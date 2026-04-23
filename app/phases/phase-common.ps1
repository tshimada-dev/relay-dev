function New-PhaseArtifactDefinition {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)]$InputContract,
        [Parameter(Mandatory)]$OutputContract,
        [string]$ValidatorArtifactId,
        [hashtable]$TransitionRules = @{}
    )

    return [ordered]@{
        phase = $Phase
        role = $Role
        input_contract = @($InputContract)
        output_contract = @($OutputContract)
        validator = if ($ValidatorArtifactId) { @{ artifact_id = $ValidatorArtifactId } } else { $null }
        transition_rules = $TransitionRules
    }
}

function Write-RunScopedPhaseArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$MarkdownArtifactId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)][string]$JsonArtifactId,
        [Parameter(Mandatory)]$JsonContent
    )

    $markdownPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope run -Phase $Phase -ArtifactId $MarkdownArtifactId -Content $MarkdownContent
    $jsonPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope run -Phase $Phase -ArtifactId $JsonArtifactId -Content $JsonContent -AsJson
    $validation = Test-ArtifactContract -ArtifactId $JsonArtifactId -Artifact $JsonContent -Phase $Phase

    return [ordered]@{
        markdown_path = $markdownPath
        json_path = $jsonPath
        validation = $validation
    }
}

function Write-TaskScopedPhaseArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$MarkdownArtifactId,
        [Parameter(Mandatory)][string]$MarkdownContent,
        [Parameter(Mandatory)][string]$JsonArtifactId,
        [Parameter(Mandatory)]$JsonContent
    )

    $markdownPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase $Phase -ArtifactId $MarkdownArtifactId -Content $MarkdownContent
    $jsonPath = Save-Artifact -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $TaskId -Phase $Phase -ArtifactId $JsonArtifactId -Content $JsonContent -AsJson
    $validation = Test-ArtifactContract -ArtifactId $JsonArtifactId -Artifact $JsonContent -Phase $Phase

    return [ordered]@{
        markdown_path = $markdownPath
        json_path = $jsonPath
        validation = $validation
    }
}
