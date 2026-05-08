function ConvertTo-ParallelWorkspaceRelativePath {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $Path))
    }

    $rootWithSeparator = $rootFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not ($candidate.Equals($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Path '$Path' resolves outside workspace '$WorkspaceRoot'."
    }

    $relative = [System.IO.Path]::GetRelativePath($rootFullPath, $candidate)
    return ($relative -replace '\\', '/')
}

function Get-ParallelWorkspacePathHash {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ParallelWorkspaceExcludedPath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string[]]$AdditionalExcludePaths = @()
    )

    $normalized = ($RelativePath -replace '\\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    $defaultExcludes = @(
        ".git",
        "node_modules",
        ".next",
        "coverage",
        "relay-dev/runs",
        "relay-dev/logs",
        "relay-dev/outputs",
        "relay-dev/queue",
        "relay-dev/.next",
        "runs",
        "logs/jobs"
    )

    foreach ($exclude in @($defaultExcludes + $AdditionalExcludePaths)) {
        if ([string]::IsNullOrWhiteSpace($exclude)) {
            continue
        }

        $excludeNormalized = ($exclude -replace '\\', '/').Trim('/')
        if ($normalized.Equals($excludeNormalized, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith("$excludeNormalized/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function New-IsolatedJobWorkspace {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$SourceWorkspace,
        [string[]]$AdditionalExcludePaths = @(),
        [switch]$Force
    )

    $sourceFullPath = [System.IO.Path]::GetFullPath($SourceWorkspace)
    if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Container)) {
        throw "Source workspace '$SourceWorkspace' does not exist."
    }

    $runRoot = Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId
    $workspaceRoot = Join-Path $runRoot "workspaces"
    $destination = Join-Path $workspaceRoot $JobId
    $destinationFullPath = [System.IO.Path]::GetFullPath($destination)
    $workspaceRootFullPath = [System.IO.Path]::GetFullPath($workspaceRoot)
    if (-not $destinationFullPath.StartsWith(($workspaceRootFullPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Isolated workspace destination '$destination' is outside run workspace root."
    }

    if (Test-Path -LiteralPath $destinationFullPath) {
        if (-not $Force) {
            throw "Isolated workspace '$destinationFullPath' already exists."
        }
        Remove-Item -LiteralPath $destinationFullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destinationFullPath -Force | Out-Null

    Get-ChildItem -LiteralPath $sourceFullPath -Recurse -Force -Directory | ForEach-Object {
        $relative = ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $sourceFullPath -Path $_.FullName
        if (Test-ParallelWorkspaceExcludedPath -RelativePath $relative -AdditionalExcludePaths $AdditionalExcludePaths) {
            return
        }

        $target = Join-Path $destinationFullPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
    }

    Get-ChildItem -LiteralPath $sourceFullPath -Recurse -Force -File | ForEach-Object {
        $relative = ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $sourceFullPath -Path $_.FullName
        if (Test-ParallelWorkspaceExcludedPath -RelativePath $relative -AdditionalExcludePaths $AdditionalExcludePaths) {
            return
        }

        $target = Join-Path $destinationFullPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    }

    return [ordered]@{
        workspace_mode = "isolated-copy-experimental"
        run_id = $RunId
        job_id = $JobId
        source_workspace = $sourceFullPath
        workspace_path = $destinationFullPath
        excluded_paths = @($AdditionalExcludePaths)
        created_at = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function New-WorkspaceBaselineSnapshot {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string[]]$Paths = @(),
        [string[]]$AdditionalExcludePaths = @()
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    if (-not (Test-Path -LiteralPath $rootFullPath -PathType Container)) {
        throw "Workspace '$WorkspaceRoot' does not exist."
    }

    $entries = [ordered]@{}
    $candidateRelativePaths = New-Object System.Collections.Generic.List[string]

    if (@($Paths).Count -gt 0) {
        foreach ($path in @($Paths)) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }
            $candidateRelativePaths.Add((ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $rootFullPath -Path $path)) | Out-Null
        }
    }
    else {
        Get-ChildItem -LiteralPath $rootFullPath -Recurse -Force -File | ForEach-Object {
            $relative = ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $rootFullPath -Path $_.FullName
            if (-not (Test-ParallelWorkspaceExcludedPath -RelativePath $relative -AdditionalExcludePaths $AdditionalExcludePaths)) {
                $candidateRelativePaths.Add($relative) | Out-Null
            }
        }
    }

    foreach ($relativePath in @($candidateRelativePaths.ToArray() | Sort-Object -Unique)) {
        $fullPath = Join-Path $rootFullPath ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
        $entries[$relativePath] = [ordered]@{
            path = $relativePath
            exists = [bool]$item
            hash = if ($item -and -not $item.PSIsContainer) { Get-ParallelWorkspacePathHash -Path $fullPath } else { $null }
            length = if ($item -and -not $item.PSIsContainer) { [int64]$item.Length } else { $null }
            last_write_time_utc = if ($item) { $item.LastWriteTimeUtc.ToString("o") } else { $null }
        }
    }

    return [ordered]@{
        workspace_root = $rootFullPath
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        entries = $entries
    }
}

function Test-ParallelWorkspaceSharedFileAllowed {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [object[]]$ResourceLocks = @()
    )

    $normalized = ($RelativePath -replace '\\', '/').Trim('/')
    $sharedPatterns = @(
        "package.json",
        "package-lock.json",
        "pnpm-lock.yaml",
        "yarn.lock",
        "bun.lockb",
        "vitest.config.ts",
        "next.config.js",
        "next.config.mjs",
        "tsconfig.json",
        "prisma/migrations/",
        "db/migrations/",
        "migrations/"
    )

    $isShared = $false
    foreach ($pattern in $sharedPatterns) {
        if ($normalized.Equals($pattern, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isShared = $true
            break
        }
    }
    if (-not $isShared) {
        return $true
    }

    foreach ($lock in @($ResourceLocks)) {
        $lockText = if ($lock -is [System.Collections.IDictionary]) {
            @($lock.Keys | ForEach-Object { [string]$lock[$_] }) -join " "
        }
        else {
            [string]$lock
        }

        if (-not [string]::IsNullOrWhiteSpace($lockText) -and
            ($lockText -match "package|lockfile|migration|config|shared")) {
            return $true
        }
    }

    return $false
}

function Test-WorkspaceBoundaryDelta {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)]$BaselineSnapshot,
        [Parameter(Mandatory)][string[]]$DeclaredChangedFiles,
        [object[]]$ResourceLocks = @(),
        [string[]]$AdditionalExcludePaths = @()
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    $allowed = [ordered]@{}
    foreach ($file in @($DeclaredChangedFiles)) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            continue
        }
        $relative = ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $rootFullPath -Path $file
        $allowed[$relative] = $true
    }

    $current = New-WorkspaceBaselineSnapshot -WorkspaceRoot $rootFullPath -AdditionalExcludePaths $AdditionalExcludePaths
    $baselineEntries = if ($BaselineSnapshot -is [System.Collections.IDictionary]) { $BaselineSnapshot["entries"] } else { $BaselineSnapshot.entries }
    $allPaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($baselineEntries.Keys)) { $allPaths.Add([string]$key) | Out-Null }
    foreach ($key in @($current["entries"].Keys)) { $allPaths.Add([string]$key) | Out-Null }

    $changed = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    $sharedRejected = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($allPaths | Sort-Object)) {
        if (Test-ParallelWorkspaceExcludedPath -RelativePath $path -AdditionalExcludePaths $AdditionalExcludePaths) {
            continue
        }

        $before = $baselineEntries[$path]
        $after = $current["entries"][$path]
        $beforeExists = $before -and [bool]$before["exists"]
        $afterExists = $after -and [bool]$after["exists"]
        $beforeHash = if ($before) { [string]$before["hash"] } else { $null }
        $afterHash = if ($after) { [string]$after["hash"] } else { $null }

        if ($beforeExists -ne $afterExists -or $beforeHash -ne $afterHash) {
            $changed.Add($path) | Out-Null
            if (-not $allowed.Contains($path)) {
                $unexpected.Add($path) | Out-Null
            }
            elseif (-not (Test-ParallelWorkspaceSharedFileAllowed -RelativePath $path -ResourceLocks $ResourceLocks)) {
                $sharedRejected.Add($path) | Out-Null
            }
        }
    }

    $accepted = @($changed.ToArray() | Where-Object { $allowed.Contains($_) -and $_ -notin @($sharedRejected.ToArray()) })
    return [ordered]@{
        ok = (@($unexpected.ToArray()).Count -eq 0 -and @($sharedRejected.ToArray()).Count -eq 0)
        workspace_root = $rootFullPath
        declared_changed_files = @($allowed.Keys)
        changed_files = @($changed.ToArray())
        accepted_changed_files = @($accepted)
        unexpected_changed_files = @($unexpected.ToArray())
        shared_file_rejections = @($sharedRejected.ToArray())
        checked_at = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Invoke-IsolatedWorkspaceMergeBack {
    param(
        [Parameter(Mandatory)][string]$MainWorkspace,
        [Parameter(Mandatory)][string]$IsolatedWorkspace,
        [Parameter(Mandatory)]$BaselineSnapshot,
        [Parameter(Mandatory)][string[]]$AcceptedChangedFiles
    )

    $mainRoot = [System.IO.Path]::GetFullPath($MainWorkspace)
    $isolatedRoot = [System.IO.Path]::GetFullPath($IsolatedWorkspace)
    $baselineEntries = if ($BaselineSnapshot -is [System.Collections.IDictionary]) { $BaselineSnapshot["entries"] } else { $BaselineSnapshot.entries }
    $copied = New-Object System.Collections.Generic.List[string]
    $deleted = New-Object System.Collections.Generic.List[string]
    $conflicts = New-Object System.Collections.Generic.List[object]

    foreach ($file in @($AcceptedChangedFiles)) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            continue
        }

        $relative = ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $mainRoot -Path $file
        $mainPath = Join-Path $mainRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $isolatedPath = Join-Path $isolatedRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $baseline = $baselineEntries[$relative]
        $baselineExists = $baseline -and [bool]$baseline["exists"]
        $baselineHash = if ($baseline) { [string]$baseline["hash"] } else { $null }
        $mainExists = Test-Path -LiteralPath $mainPath -PathType Leaf
        $mainHash = Get-ParallelWorkspacePathHash -Path $mainPath

        if ($baselineExists -ne $mainExists -or $baselineHash -ne $mainHash) {
            $conflicts.Add([ordered]@{
                path = $relative
                reason = "main_target_drift"
                baseline_hash = $baselineHash
                main_hash = $mainHash
                baseline_exists = $baselineExists
                main_exists = $mainExists
            }) | Out-Null
            continue
        }
    }

    if ($conflicts.Count -gt 0) {
        return [ordered]@{
            ok = $false
            reason = "main_workspace_drift"
            conflicts = @($conflicts.ToArray())
            copied_files = @()
            deleted_files = @()
        }
    }

    foreach ($file in @($AcceptedChangedFiles)) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            continue
        }

        $relative = ConvertTo-ParallelWorkspaceRelativePath -WorkspaceRoot $mainRoot -Path $file
        $mainPath = Join-Path $mainRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $isolatedPath = Join-Path $isolatedRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)

        if (Test-Path -LiteralPath $isolatedPath -PathType Leaf) {
            $targetDir = Split-Path -Parent $mainPath
            if (-not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $isolatedPath -Destination $mainPath -Force
            $copied.Add($relative) | Out-Null
        }
        elseif (Test-Path -LiteralPath $mainPath -PathType Leaf) {
            Remove-Item -LiteralPath $mainPath -Force
            $deleted.Add($relative) | Out-Null
        }
    }

    return [ordered]@{
        ok = $true
        reason = "merged"
        copied_files = @($copied.ToArray())
        deleted_files = @($deleted.ToArray())
        merged_at = (Get-Date).ToUniversalTime().ToString("o")
    }
}
