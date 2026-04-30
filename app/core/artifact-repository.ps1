function Get-OutputsRootPath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot "outputs")
}

function ConvertTo-CompatibilityName {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $result = [string]$Value
    foreach ($char in $invalidChars) {
        $result = $result.Replace([string]$char, "_")
    }
    return $result.Trim()
}

function ConvertTo-CompatibilitySlug {
    param(
        [AllowNull()][string]$Value,
        [int]$MaxLength = 64
    )

    $safeValue = ConvertTo-CompatibilityName -Value $Value
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return ""
    }

    $slug = [regex]::Replace($safeValue, '\s+', '-')
    $slug = $slug.Trim(' ', '-', '.')
    if ($slug.Length -gt $MaxLength) {
        $slug = $slug.Substring(0, $MaxLength).Trim(' ', '-', '.')
    }

    return $slug
}

function Get-CompatibilityTaskFilePath {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $taskFileVar = Get-Variable -Name TaskFile -Scope Script -ErrorAction SilentlyContinue
    $configuredTaskFile = if ($taskFileVar -and -not [string]::IsNullOrWhiteSpace([string]$taskFileVar.Value)) {
        [string]$taskFileVar.Value
    }
    else {
        "tasks/task.md"
    }

    if ([System.IO.Path]::IsPathRooted($configuredTaskFile)) {
        return $configuredTaskFile
    }

    return (Join-Path $ProjectRoot $configuredTaskFile)
}

function Get-TaskFileCompatibilityName {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $taskFilePath = Get-CompatibilityTaskFilePath -ProjectRoot $ProjectRoot
    if (-not (Test-Path $taskFilePath)) {
        return ""
    }

    $raw = Get-Content -Path $taskFilePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ""
    }

    $title = ""
    foreach ($line in ($raw -split "\r?\n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith("#")) {
            $trimmed = $trimmed.TrimStart('#').Trim()
        }

        $candidateTitle = ConvertTo-CompatibilitySlug -Value $trimmed
        if (-not [string]::IsNullOrWhiteSpace($candidateTitle)) {
            $title = $trimmed
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [System.IO.Path]::GetFileNameWithoutExtension($taskFilePath)
    }

    return (ConvertTo-CompatibilitySlug -Value $title)
}

function Resolve-InitialCompatibilityRequirementName {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [string]$TaskId = "task-main"
    )

    $explicitTaskName = ConvertTo-CompatibilitySlug -Value $TaskId
    if (-not [string]::IsNullOrWhiteSpace($explicitTaskName) -and $explicitTaskName -ne "task-main") {
        return $explicitTaskName
    }

    $taskFileName = Get-TaskFileCompatibilityName -ProjectRoot $ProjectRoot
    if (-not [string]::IsNullOrWhiteSpace($taskFileName)) {
        return $taskFileName
    }

    return (ConvertTo-CompatibilitySlug -Value $RunId)
}

function Resolve-CompatibilityRequirementName {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $runState = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
    if ($runState) {
        $compatibilityName = ConvertTo-CompatibilitySlug -Value ([string]$runState["compatibility_name"])
        if (-not [string]::IsNullOrWhiteSpace($compatibilityName)) {
            return $compatibilityName
        }

        $taskIdCandidate = ConvertTo-CompatibilitySlug -Value ([string]$runState["task_id"])
        if (-not [string]::IsNullOrWhiteSpace($taskIdCandidate) -and $taskIdCandidate -ne "task-main") {
            return $taskIdCandidate
        }
    }

    $outputsRoot = Get-OutputsRootPath -ProjectRoot $ProjectRoot
    $legacyRunName = ConvertTo-CompatibilitySlug -Value $RunId
    if (-not [string]::IsNullOrWhiteSpace($legacyRunName)) {
        $legacyRunPath = Join-Path $outputsRoot $legacyRunName
        if (Test-Path $legacyRunPath) {
            return $legacyRunName
        }
    }

    $taskFileName = Get-TaskFileCompatibilityName -ProjectRoot $ProjectRoot
    if (-not [string]::IsNullOrWhiteSpace($taskFileName)) {
        return $taskFileName
    }

    if (Test-Path $outputsRoot) {
        $existingDirs = @(Get-ChildItem -Path $outputsRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' })
        if ($existingDirs.Count -eq 1) {
            return $existingDirs[0].Name
        }
    }

    return $legacyRunName
}

function Get-CompatibilityArtifactPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string]$TaskId
    )

    $outputsRoot = Get-OutputsRootPath -ProjectRoot $ProjectRoot
    $requirementName = Resolve-CompatibilityRequirementName -ProjectRoot $ProjectRoot -RunId $RunId

    if ($Scope -eq "run") {
        return (Join-Path $outputsRoot "$requirementName\$ArtifactId")
    }

    if (-not $TaskId) {
        throw "TaskId is required to resolve task-scoped compatibility artifact paths."
    }

    return (Join-Path $outputsRoot "$requirementName\tasks\$TaskId\$ArtifactId")
}

function Write-CompatibilityTaskMarker {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Verdict
    )

    if ($Verdict -notin @("go", "conditional_go")) {
        return
    }

    $outputsRoot = Get-OutputsRootPath -ProjectRoot $ProjectRoot
    $requirementName = Resolve-CompatibilityRequirementName -ProjectRoot $ProjectRoot -RunId $RunId
    $markerDir = Join-Path $outputsRoot "$requirementName\.tasks"
    if (-not (Test-Path $markerDir)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }

    $markerPath = Join-Path $markerDir "$TaskId`_completed.md"
    $markerBody = @(
        "# Completed Task",
        "",
        "- TaskId: $TaskId",
        "- Verdict: $Verdict",
        "- CompletedAt: $((Get-Date).ToString('o'))"
    )
    Set-Content -Path $markerPath -Value ($markerBody -join "`n") -Encoding UTF8
}

function Write-CompatibilityFixContract {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$TaskContract
    )

    $task = ConvertTo-RelayHashtable -InputObject $TaskContract
    $taskId = [string]$task["task_id"]
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        return
    }

    $fixContractPath = Get-CompatibilityArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope task -TaskId $taskId -ArtifactId "fix_contract.yaml"
    $fixContractDir = Split-Path -Parent $fixContractPath
    if (-not (Test-Path $fixContractDir)) {
        New-Item -ItemType Directory -Path $fixContractDir -Force | Out-Null
    }

    $yaml = @(
        "issue_id: `"$((ConvertTo-CompatibilityName -Value $taskId))`"",
        "must_fix:",
        "  - `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$task['purpose'])))`"",
        "acceptance_criteria:"
    )
    foreach ($criterion in @($task["acceptance_criteria"])) {
        $yaml += "  - `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$criterion)))`""
    }
    $yaml += "verification:"
    foreach ($verificationStep in @($task["verification"])) {
        $yaml += "  - `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$verificationStep)))`""
    }
    $yaml += "out_of_scope:"
    $yaml += "  - `"`""
    $yaml += "changed_files:"
    foreach ($changedFile in @($task["changed_files"])) {
        $yaml += "  - `"$((ConvertTo-CompatibilityYamlDoubleQuoted -Value ([string]$changedFile)))`""
    }

    Set-Content -Path $fixContractPath -Value ($yaml -join "`n") -Encoding UTF8
}

function Initialize-CompatibilityTaskDirectories {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$TasksArtifact
    )

    $tasksArtifactObject = ConvertTo-RelayHashtable -InputObject $TasksArtifact
    $outputsRoot = Get-OutputsRootPath -ProjectRoot $ProjectRoot
    $requirementName = Resolve-CompatibilityRequirementName -ProjectRoot $ProjectRoot -RunId $RunId
    $tasksRoot = Join-Path $outputsRoot "$requirementName\tasks"
    $dotTasksRoot = Join-Path $outputsRoot "$requirementName\.tasks"
    foreach ($dir in @($tasksRoot, $dotTasksRoot)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    foreach ($task in @($tasksArtifactObject["tasks"])) {
        $taskObject = ConvertTo-RelayHashtable -InputObject $task
        $taskId = [string]$taskObject["task_id"]
        if ([string]::IsNullOrWhiteSpace($taskId)) {
            continue
        }

        $taskDir = Join-Path $tasksRoot $taskId
        if (-not (Test-Path $taskDir)) {
            New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
        }
    }
}

function Write-CompatibilityArtifactProjection {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)]$Content,
        [string]$TaskId,
        [switch]$AsJson
    )

    $compatibilityPath = Get-CompatibilityArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -ArtifactId $ArtifactId -TaskId $TaskId
    $compatibilityDir = Split-Path -Parent $compatibilityPath
    if (-not (Test-Path $compatibilityDir)) {
        New-Item -ItemType Directory -Path $compatibilityDir -Force | Out-Null
    }

    if ($AsJson) {
        $serialized = (ConvertTo-RelayHashtable -InputObject $Content) | ConvertTo-Json -Depth 20
    }
    else {
        $serialized = [string]$Content
    }

    Set-Content -Path $compatibilityPath -Value $serialized -Encoding UTF8

    if ($Scope -eq "run" -and $ArtifactId -eq "phase4_tasks.json") {
        Initialize-CompatibilityTaskDirectories -ProjectRoot $ProjectRoot -RunId $RunId -TasksArtifact $Content
    }

    if ($Scope -eq "task" -and $ArtifactId -eq "phase6_result.json") {
        $phase6Artifact = ConvertTo-RelayHashtable -InputObject $Content
        Write-CompatibilityTaskMarker -ProjectRoot $ProjectRoot -RunId $RunId -TaskId $TaskId -Verdict ([string]$phase6Artifact["verdict"])
    }

    if ($Scope -eq "run" -and $ArtifactId -eq "phase7_verdict.json") {
        $phase7Artifact = ConvertTo-RelayHashtable -InputObject $Content
        foreach ($followUpTask in @($phase7Artifact["follow_up_tasks"])) {
            Write-CompatibilityFixContract -ProjectRoot $ProjectRoot -RunId $RunId -TaskContract $followUpTask
        }
    }

    return $compatibilityPath
}

function Get-JobArtifactsRootPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId
    )

    return (Join-Path (Get-RunJobPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId) "artifacts")
}

function Get-AttemptArtifactsRootPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$AttemptId
    )

    return (Join-Path (Get-JobArtifactsRootPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId) "attempts\$AttemptId")
}

function Resolve-ArtifactStorageRootPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("canonical", "job", "attempt")][string]$StorageScope,
        [string]$JobId,
        [string]$AttemptId
    )

    switch ($StorageScope) {
        "canonical" {
            return (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "artifacts")
        }
        "job" {
            if ([string]::IsNullOrWhiteSpace($JobId)) {
                throw "JobId is required when resolving job-scoped artifact storage roots."
            }

            return (Get-JobArtifactsRootPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId)
        }
        "attempt" {
            if ([string]::IsNullOrWhiteSpace($JobId)) {
                throw "JobId is required when resolving attempt-scoped artifact storage roots."
            }

            if ([string]::IsNullOrWhiteSpace($AttemptId)) {
                throw "AttemptId is required when resolving attempt-scoped artifact storage roots."
            }

            return (Get-AttemptArtifactsRootPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId -AttemptId $AttemptId)
        }
    }
}

function Get-JobArtifactPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string]$TaskId
    )

    $root = Get-JobArtifactsRootPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId
    if ($Scope -eq "run") {
        return (Join-Path $root "run\$Phase\$ArtifactId")
    }

    if (-not $TaskId) {
        throw "TaskId is required when scope is 'task'"
    }

    return (Join-Path $root "tasks\$TaskId\$Phase\$ArtifactId")
}

function Get-AttemptArtifactPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$AttemptId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string]$TaskId
    )

    $root = Get-AttemptArtifactsRootPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId -AttemptId $AttemptId
    if ($Scope -eq "run") {
        return (Join-Path $root "run\$Phase\$ArtifactId")
    }

    if (-not $TaskId) {
        throw "TaskId is required when scope is 'task'"
    }

    return (Join-Path $root "tasks\$TaskId\$Phase\$ArtifactId")
}

function Get-JobArtifactPhaseDirectory {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $artifactPath = Get-JobArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId -Scope $Scope -Phase $Phase -ArtifactId "__phase_dir_placeholder__" -TaskId $TaskId
    return (Split-Path -Parent $artifactPath)
}

function Get-AttemptArtifactPhaseDirectory {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$AttemptId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $artifactPath = Get-AttemptArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId -AttemptId $AttemptId -Scope $Scope -Phase $Phase -ArtifactId "__phase_dir_placeholder__" -TaskId $TaskId
    return (Split-Path -Parent $artifactPath)
}

function Get-ArtifactPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string]$TaskId
    )

    $root = Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId
    if ($Scope -eq "run") {
        return (Join-Path $root "artifacts\run\$Phase\$ArtifactId")
    }

    if (-not $TaskId) {
        throw "TaskId is required when scope is 'task'"
    }

    return (Join-Path $root "artifacts\tasks\$TaskId\$Phase\$ArtifactId")
}

function Resolve-StagedArtifactPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("canonical", "job", "attempt")][string]$StorageScope,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ArtifactId,
        [string]$TaskId,
        [string]$JobId,
        [string]$AttemptId
    )

    switch ($StorageScope) {
        "canonical" {
            return (Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -ArtifactId $ArtifactId -TaskId $TaskId)
        }
        "job" {
            if ([string]::IsNullOrWhiteSpace($JobId)) {
                throw "JobId is required when resolving job-scoped staged artifact paths."
            }

            return (Get-JobArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId -Scope $Scope -Phase $Phase -ArtifactId $ArtifactId -TaskId $TaskId)
        }
        "attempt" {
            if ([string]::IsNullOrWhiteSpace($JobId)) {
                throw "JobId is required when resolving attempt-scoped staged artifact paths."
            }

            if ([string]::IsNullOrWhiteSpace($AttemptId)) {
                throw "AttemptId is required when resolving attempt-scoped staged artifact paths."
            }

            return (Get-AttemptArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId -AttemptId $AttemptId -Scope $Scope -Phase $Phase -ArtifactId $ArtifactId -TaskId $TaskId)
        }
    }
}

function Get-ArtifactPhaseDirectory {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $artifactPath = Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -ArtifactId "__phase_dir_placeholder__" -TaskId $TaskId
    return (Split-Path -Parent $artifactPath)
}

function Get-ArchivedArtifactPhaseRoot {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $root = Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId
    if ($Scope -eq "run") {
        return (Join-Path $root "artifacts\archive\run\$Phase")
    }

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        throw "TaskId is required when resolving task-scoped archive roots."
    }

    return (Join-Path $root "artifacts\archive\tasks\$TaskId\$Phase")
}

function New-ArtifactArchiveSnapshotId {
    $snapshotId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffffffZ")
    if ([string]::IsNullOrWhiteSpace($snapshotId)) {
        return [guid]::NewGuid().ToString("N")
    }

    return $snapshotId
}

function Archive-PhaseArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId,
        [string]$Reason = "rerun_before_dispatch",
        [string]$PreviousJobId
    )

    $phaseDirectory = Get-ArtifactPhaseDirectory -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -TaskId $TaskId
    if (-not (Test-Path $phaseDirectory)) {
        return [ordered]@{
            archived = $false
            reason = "phase_directory_missing"
            phase_directory = $phaseDirectory
            scope = $Scope
            phase = $Phase
            task_id = $TaskId
        }
    }

    $items = @(Get-ChildItem -LiteralPath $phaseDirectory -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        return [ordered]@{
            archived = $false
            reason = "phase_directory_empty"
            phase_directory = $phaseDirectory
            scope = $Scope
            phase = $Phase
            task_id = $TaskId
        }
    }

    $archiveRoot = Get-ArchivedArtifactPhaseRoot -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -TaskId $TaskId
    if (-not (Test-Path $archiveRoot)) {
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    }

    $snapshotId = New-ArtifactArchiveSnapshotId
    $snapshotPath = Join-Path $archiveRoot $snapshotId
    if (Test-Path $snapshotPath) {
        $snapshotId = "{0}-{1}" -f $snapshotId, ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $snapshotPath = Join-Path $archiveRoot $snapshotId
    }

    New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null

    $archivedArtifacts = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $destination = Join-Path $snapshotPath $item.Name
        Move-Item -LiteralPath $item.FullName -Destination $destination -Force
        $archivedArtifacts.Add([ordered]@{
            artifact_id = $item.Name
            kind = if ($item.PSIsContainer) { "directory" } else { "file" }
            path = $destination
        }) | Out-Null
    }

    $metadata = [ordered]@{
        run_id = $RunId
        scope = $Scope
        phase = $Phase
        task_id = $TaskId
        reason = $Reason
        previous_job_id = $PreviousJobId
        archived_at = (Get-Date).ToString("o")
        source_phase_directory = $phaseDirectory
        archived_artifacts = @($archivedArtifacts.ToArray())
    }
    $metadataPath = Join-Path $snapshotPath "metadata.json"
    Set-Content -Path $metadataPath -Value ($metadata | ConvertTo-Json -Depth 20) -Encoding UTF8

    return [ordered]@{
        archived = $true
        reason = $Reason
        snapshot_id = $snapshotId
        snapshot_path = $snapshotPath
        metadata_path = $metadataPath
        phase_directory = $phaseDirectory
        archive_root = $archiveRoot
        scope = $Scope
        phase = $Phase
        task_id = $TaskId
        archived_artifacts = @($archivedArtifacts.ToArray())
    }
}

function Get-LatestArchivedPhaseSnapshot {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $archiveRoot = Get-ArchivedArtifactPhaseRoot -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -TaskId $TaskId
    if (-not (Test-Path $archiveRoot)) {
        return $null
    }

    $snapshotDirectories = @(Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($directory in $snapshotDirectories) {
        $metadataPath = Join-Path $directory.FullName "metadata.json"
        $metadata = $null
        if (Test-Path $metadataPath) {
            try {
                $metadata = ConvertTo-RelayHashtable -InputObject ((Get-Content -Path $metadataPath -Raw -Encoding UTF8) | ConvertFrom-Json)
            }
            catch {
                $metadata = $null
            }
        }

        return [ordered]@{
            snapshot_id = $directory.Name
            snapshot_path = $directory.FullName
            metadata = $metadata
        }
    }

    return $null
}

function Get-LatestArchivedPhaseJsonArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [string]$TaskId
    )

    $snapshot = ConvertTo-RelayHashtable -InputObject (Get-LatestArchivedPhaseSnapshot -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -TaskId $TaskId)
    if (-not $snapshot) {
        return @()
    }

    $metadata = ConvertTo-RelayHashtable -InputObject $snapshot["metadata"]
    $archivedAt = if ($metadata -and $metadata["archived_at"]) { [string]$metadata["archived_at"] } else { $null }
    $jsonFiles = @(Get-ChildItem -LiteralPath ([string]$snapshot["snapshot_path"]) -File -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "metadata.json" } | Sort-Object Name)
    $artifacts = New-Object System.Collections.Generic.List[object]
    foreach ($file in $jsonFiles) {
        $artifacts.Add([ordered]@{
            artifact_id = $file.Name
            path = $file.FullName
            snapshot_id = [string]$snapshot["snapshot_id"]
            archived_at = $archivedAt
            scope = $Scope
            phase = $Phase
            task_id = $TaskId
        }) | Out-Null
    }

    return @($artifacts.ToArray())
}

function Save-Artifact {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet("run", "task")][string]$Scope,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)]$Content,
        [string]$TaskId,
        [switch]$AsJson
    )

    Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $RunId
    $path = Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -ArtifactId $ArtifactId -TaskId $TaskId
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $serialized = if ($AsJson) {
        (ConvertTo-RelayHashtable -InputObject $Content) | ConvertTo-Json -Depth 20
    }
    else {
        [string]$Content
    }

    $tempPath = "${path}.tmp"
    Set-Content -Path $tempPath -Value $serialized -Encoding UTF8
    if (Test-Path $path) {
        Remove-Item $path -Force
    }
    Move-Item -Path $tempPath -Destination $path -Force
    Write-CompatibilityArtifactProjection -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -ArtifactId $ArtifactId -Content $Content -TaskId $TaskId -AsJson:$AsJson | Out-Null
    return $path
}

function Read-ArtifactContentFromPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    if ($Path.ToLowerInvariant().EndsWith(".json")) {
        return (ConvertTo-RelayHashtable -InputObject ($raw | ConvertFrom-Json))
    }

    return $raw
}

function Commit-PhaseOutputArtifacts {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$MaterializedArtifacts
    )

    $committedArtifacts = New-Object System.Collections.Generic.List[object]
    foreach ($artifactRaw in @($MaterializedArtifacts)) {
        $artifact = ConvertTo-RelayHashtable -InputObject $artifactRaw
        $scope = if ($artifact["scope"]) { [string]$artifact["scope"] } else { "run" }
        $phase = [string]$artifact["phase"]
        $artifactId = [string]$artifact["artifact_id"]
        $taskId = [string]$artifact["task_id"]
        $asJson = $false
        if ($artifact.ContainsKey("as_json")) {
            $asJson = [bool]$artifact["as_json"]
        }

        $saveParams = @{
            ProjectRoot = $ProjectRoot
            RunId = $RunId
            Scope = $scope
            Phase = $phase
            ArtifactId = $artifactId
            Content = $artifact["content"]
            AsJson = $asJson
        }
        if ($scope -eq "task") {
            $saveParams["TaskId"] = $taskId
        }

        $destinationPath = Save-Artifact @saveParams
        $committedArtifacts.Add([ordered]@{
            artifact_id = $artifactId
            scope = $scope
            phase = $phase
            task_id = $taskId
            source_path = [string]$artifact["path"]
            destination_path = $destinationPath
            as_json = $asJson
        }) | Out-Null
    }

    return [ordered]@{
        committed = @($committedArtifacts.ToArray())
    }
}

function Read-Artifact {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [ValidateSet("run", "task")][string]$Scope,
        [string]$Phase,
        [string]$ArtifactId,
        [string]$TaskId,
        [AllowNull()]$ArtifactRef
    )

    $path = if ($null -ne $ArtifactRef) {
        Resolve-ArtifactRef -ProjectRoot $ProjectRoot -RunId $RunId -ArtifactRef $ArtifactRef
    }
    else {
        Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $Scope -Phase $Phase -ArtifactId $ArtifactId -TaskId $TaskId
    }

    return (Read-ArtifactContentFromPath -Path $path)
}

function Resolve-ArtifactRef {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$ArtifactRef
    )

    $ref = ConvertTo-RelayHashtable -InputObject $ArtifactRef
    $scope = if ($ref["scope"]) { [string]$ref["scope"] } else { "run" }
    return (Get-ArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -Scope $scope -Phase $ref["phase"] -ArtifactId $ref["artifact_id"] -TaskId $ref["task_id"])
}
