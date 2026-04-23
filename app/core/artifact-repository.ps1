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

    if (-not (Test-Path $path)) {
        return $null
    }

    $raw = Get-Content -Path $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    if ($path.ToLowerInvariant().EndsWith(".json")) {
        return (ConvertTo-RelayHashtable -InputObject ($raw | ConvertFrom-Json))
    }

    return $raw
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
