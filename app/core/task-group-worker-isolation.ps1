function Get-TaskGroupWorkerId {
    param([AllowNull()]$Worker)

    $worker = ConvertTo-RelayHashtable -InputObject $Worker
    if (-not $worker) {
        return ""
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$worker["worker_id"])) {
        return [string]$worker["worker_id"]
    }

    return [string]$worker["id"]
}

function Get-TaskGroupWorkerPackageIsolationPaths {
    param([AllowNull()]$Workers)

    return @($Workers | ForEach-Object {
            $worker = ConvertTo-RelayHashtable -InputObject $_
            [ordered]@{
                worker_id = Get-TaskGroupWorkerId -Worker $worker
                workspace_path = [string]$worker["workspace_path"]
                artifact_root = [string]$worker["artifact_root"]
            }
        })
}

function Get-TaskGroupWorkerFullPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function Get-TaskGroupWorkerPathComparison {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }

    return [System.StringComparison]::Ordinal
}

function Test-TaskGroupWorkerPathOverlap {
    param(
        [AllowNull()][string]$First,
        [AllowNull()][string]$Second
    )

    $firstFull = Get-TaskGroupWorkerFullPath -Path $First
    $secondFull = Get-TaskGroupWorkerFullPath -Path $Second
    if ([string]::IsNullOrWhiteSpace($firstFull) -or [string]::IsNullOrWhiteSpace($secondFull)) {
        return $false
    }

    $comparison = Get-TaskGroupWorkerPathComparison
    if ([string]::Equals($firstFull, $secondFull, $comparison)) {
        return $true
    }

    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    return $firstFull.StartsWith($secondFull + $separator, $comparison) -or $secondFull.StartsWith($firstFull + $separator, $comparison)
}

function Test-TaskGroupWorkerPathIsProjectContainer {
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $pathFull = Get-TaskGroupWorkerFullPath -Path $Path
    $projectFull = Get-TaskGroupWorkerFullPath -Path $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($pathFull) -or [string]::IsNullOrWhiteSpace($projectFull)) {
        return $false
    }

    $comparison = Get-TaskGroupWorkerPathComparison
    if ([string]::Equals($pathFull, $projectFull, $comparison)) {
        return $true
    }

    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    return $projectFull.StartsWith($pathFull + $separator, $comparison)
}

function Add-TaskGroupWorkerIsolationError {
    param(
        [Parameter(Mandatory)]$Errors,
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Condition) {
        $Errors.Add($Message) | Out-Null
    }
}

function Assert-TaskGroupWorkerIsolation {
    param(
        [Parameter(Mandatory)]$Worker,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkerId
    )

    $worker = ConvertTo-RelayHashtable -InputObject $Worker
    $workspaceFull = Get-TaskGroupWorkerFullPath -Path ([string]$worker["workspace_path"])
    $artifactFull = Get-TaskGroupWorkerFullPath -Path ([string]$worker["artifact_root"])
    $errors = New-Object System.Collections.Generic.List[string]

    Add-TaskGroupWorkerIsolationError -Errors $errors -Condition ([string]::IsNullOrWhiteSpace($workspaceFull)) -Message "workspace_path is required for isolated task-group workers"
    if (-not [string]::IsNullOrWhiteSpace($workspaceFull)) {
        Add-TaskGroupWorkerIsolationError -Errors $errors -Condition (Test-TaskGroupWorkerPathIsProjectContainer -Path $workspaceFull -ProjectRoot $ProjectRoot) -Message "workspace_path must not be the project root or contain the project root"
    }

    Add-TaskGroupWorkerIsolationError -Errors $errors -Condition ([string]::IsNullOrWhiteSpace($artifactFull)) -Message "artifact_root is required for isolated task-group workers"
    if (-not [string]::IsNullOrWhiteSpace($artifactFull)) {
        Add-TaskGroupWorkerIsolationError -Errors $errors -Condition (Test-TaskGroupWorkerPathIsProjectContainer -Path $artifactFull -ProjectRoot $ProjectRoot) -Message "artifact_root must not be the project root or contain the project root"
    }

    $hasWorkspaceAndArtifacts = -not [string]::IsNullOrWhiteSpace($workspaceFull) -and -not [string]::IsNullOrWhiteSpace($artifactFull)
    Add-TaskGroupWorkerIsolationError -Errors $errors -Condition ($hasWorkspaceAndArtifacts -and (Test-TaskGroupWorkerPathOverlap -First $workspaceFull -Second $artifactFull)) -Message "workspace_path and artifact_root must be separate paths"

    foreach ($siblingRaw in @($worker["_task_group_worker_isolation_paths"])) {
        $sibling = ConvertTo-RelayHashtable -InputObject $siblingRaw
        $siblingId = [string]$sibling["worker_id"]
        if ([string]::IsNullOrWhiteSpace($siblingId) -or $siblingId -eq $WorkerId) {
            continue
        }

        $siblingWorkspace = [string]$sibling["workspace_path"]
        $siblingArtifactRoot = [string]$sibling["artifact_root"]
        Add-TaskGroupWorkerIsolationError -Errors $errors -Condition (Test-TaskGroupWorkerPathOverlap -First $workspaceFull -Second $siblingWorkspace) -Message "workspace_path overlaps sibling worker '$siblingId' workspace_path"
        Add-TaskGroupWorkerIsolationError -Errors $errors -Condition (Test-TaskGroupWorkerPathOverlap -First $artifactFull -Second $siblingArtifactRoot) -Message "artifact_root overlaps sibling worker '$siblingId' artifact_root"
        Add-TaskGroupWorkerIsolationError -Errors $errors -Condition (Test-TaskGroupWorkerPathOverlap -First $workspaceFull -Second $siblingArtifactRoot) -Message "workspace_path overlaps sibling worker '$siblingId' artifact_root"
        Add-TaskGroupWorkerIsolationError -Errors $errors -Condition (Test-TaskGroupWorkerPathOverlap -First $artifactFull -Second $siblingWorkspace) -Message "artifact_root overlaps sibling worker '$siblingId' workspace_path"
    }

    if ($errors.Count -gt 0) {
        throw "Task group worker '$WorkerId' isolation violation: $($errors.ToArray() -join '; ')"
    }
}
