if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Get-LatestArchivedPhaseSnapshot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "artifact-repository.ps1")
}

function New-ArchivedJsonContextRef {
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][string]$RunId
    )

    $item = ConvertTo-RelayHashtable -InputObject $Artifact
    return [ordered]@{
        run_id = $RunId
        scope = [string]$item["scope"]
        phase = [string]$item["phase"]
        task_id = if ($null -ne $item["task_id"] -and -not [string]::IsNullOrWhiteSpace([string]$item["task_id"])) { [string]$item["task_id"] } else { $null }
        snapshot_id = [string]$item["snapshot_id"]
        artifact_id = [string]$item["artifact_id"]
        path = [string]$item["path"]
        archived_at = if ($item.ContainsKey("archived_at") -and $item["archived_at"]) { [string]$item["archived_at"] } else { $null }
    }
}

function Get-LatestArchivedJsonContext {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $snapshot = ConvertTo-RelayHashtable -InputObject (Get-LatestArchivedPhaseSnapshot -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -TaskId $TaskId)
    $artifacts = @(Get-LatestArchivedPhaseJsonArtifacts -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -TaskId $TaskId)

    $refs = New-Object System.Collections.Generic.List[object]
    foreach ($artifact in $artifacts) {
        $refs.Add((New-ArchivedJsonContextRef -Artifact $artifact -RunId $RunId)) | Out-Null
    }

    $snapshotMetadata = $null
    if ($snapshot) {
        $metadata = ConvertTo-RelayHashtable -InputObject $snapshot["metadata"]
        $snapshotMetadata = [ordered]@{
            run_id = $RunId
            scope = $Scope
            phase = $Phase
            task_id = if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId }
            snapshot_id = [string]$snapshot["snapshot_id"]
            snapshot_path = [string]$snapshot["snapshot_path"]
            archived_at = if ($metadata -and $metadata["archived_at"]) { [string]$metadata["archived_at"] } else { $null }
            artifact_count = $refs.Count
        }
    }

    return [ordered]@{
        archived_context_refs = @($refs.ToArray())
        archived_context_snapshot = $snapshotMetadata
    }
}

function Format-ArchivedJsonContextPromptLines {
    param(
        [Parameter(Mandatory)]$ArchivedContext
    )

    $context = ConvertTo-RelayHashtable -InputObject $ArchivedContext
    $refs = @($context["archived_context_refs"])
    if ($refs.Count -eq 0) {
        return @()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($ref in $refs) {
        $item = ConvertTo-RelayHashtable -InputObject $ref
        $scope = if ($item["scope"]) { [string]$item["scope"] } else { "run" }
        $snapshotId = if ($item["snapshot_id"]) { [string]$item["snapshot_id"] } else { "" }
        $lines.Add("- [archived][$scope][json] $([string]$item["artifact_id"]) => $([string]$item["path"]) (latest snapshot: $snapshotId)") | Out-Null
    }

    return @($lines.ToArray())
}
