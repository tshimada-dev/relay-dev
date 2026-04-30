if (-not (Get-Command Commit-PhaseOutputArtifacts -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repository.ps1")
}

function Complete-PhaseOutputCommit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$MaterializedArtifacts
    )

    $commitResult = ConvertTo-RelayHashtable -InputObject (Commit-PhaseOutputArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -MaterializedArtifacts $MaterializedArtifacts)
    $committedArtifacts = @($commitResult["committed"])

    $artifactIds = New-Object System.Collections.Generic.List[string]
    foreach ($committedRaw in $committedArtifacts) {
        $committedArtifact = ConvertTo-RelayHashtable -InputObject $committedRaw
        $artifactId = [string]$committedArtifact["artifact_id"]
        if (-not [string]::IsNullOrWhiteSpace($artifactId)) {
            $artifactIds.Add($artifactId) | Out-Null
        }
    }

    return [ordered]@{
        committed = $committedArtifacts
        summary = [ordered]@{
            committed_count = $committedArtifacts.Count
            artifact_ids = @($artifactIds.ToArray())
        }
    }
}
