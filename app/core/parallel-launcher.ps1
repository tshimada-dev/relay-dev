function Resolve-ParallelPackageValue {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Package -is [System.Collections.IDictionary] -and $Package.Contains($name)) {
            return $Package[$name]
        }

        $property = $Package.PSObject.Properties[$name]
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

function Resolve-ParallelJobPackageFile {
    param([Parameter(Mandatory)]$Package)

    if ($Package -is [string]) {
        return $Package
    }

    $path = Resolve-ParallelPackageValue -Package $Package -Names @("package_path", "job_package_path", "path", "file")
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        throw "Parallel worker package is missing package_path."
    }

    return [string]$path
}

function Resolve-ParallelPackageIdentity {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$PackageFile
    )

    $jobId = Resolve-ParallelPackageValue -Package $Package -Names @("job_id", "JobId")
    $taskId = Resolve-ParallelPackageValue -Package $Package -Names @("task_id", "TaskId")

    if (([string]::IsNullOrWhiteSpace([string]$jobId) -or [string]::IsNullOrWhiteSpace([string]$taskId)) -and
        (Test-Path -LiteralPath $PackageFile -PathType Leaf)) {
        try {
            $raw = Get-Content -LiteralPath $PackageFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $json = $raw | ConvertFrom-Json
                if ([string]::IsNullOrWhiteSpace([string]$jobId)) {
                    $jobId = Resolve-ParallelPackageValue -Package $json -Names @("job_id", "JobId")
                    if ([string]::IsNullOrWhiteSpace([string]$jobId)) {
                        $job = Resolve-ParallelPackageValue -Package $json -Names @("job", "job_spec")
                        if ($job) {
                            $jobId = Resolve-ParallelPackageValue -Package $job -Names @("job_id", "JobId")
                        }
                    }
                }
                if ([string]::IsNullOrWhiteSpace([string]$taskId)) {
                    $taskId = Resolve-ParallelPackageValue -Package $json -Names @("task_id", "TaskId")
                    if ([string]::IsNullOrWhiteSpace([string]$taskId)) {
                        $task = Resolve-ParallelPackageValue -Package $json -Names @("task", "selected_task")
                        if ($task) {
                            $taskId = Resolve-ParallelPackageValue -Package $task -Names @("task_id", "TaskId")
                        }
                    }
                }
            }
        }
        catch {
            # Package identity is best-effort for parent summaries; worker execution owns validation.
        }
    }

    return [ordered]@{
        job_id = if ([string]::IsNullOrWhiteSpace([string]$jobId)) { [System.IO.Path]::GetFileNameWithoutExtension($PackageFile) } else { [string]$jobId }
        task_id = if ([string]::IsNullOrWhiteSpace([string]$taskId)) { $null } else { [string]$taskId }
    }
}

function Invoke-ParallelStepWorkers {
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [string]$CliPath = (Join-Path $ProjectRoot "app/cli.ps1"),
        [string]$PwshPath = "pwsh",
        [string]$LogDirectory,
        [hashtable]$WorkerParameters = @{}
    )

    $startedAt = Get-Date
    $logRoot = if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "worker-logs"
    }
    else {
        $LogDirectory
    }
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

    $processes = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Packages)) {
        $packageFile = [System.IO.Path]::GetFullPath((Resolve-ParallelJobPackageFile -Package $package))
        $identity = Resolve-ParallelPackageIdentity -Package $package -PackageFile $packageFile
        $safeJobId = ([string]$identity["job_id"]) -replace '[^A-Za-z0-9_.-]', '_'
        $slotStartedAt = Get-Date
        $stdoutPath = Join-Path $logRoot "$safeJobId.stdout.log"
        $stderrPath = Join-Path $logRoot "$safeJobId.stderr.log"

        $arguments = New-Object System.Collections.Generic.List[string]
        $arguments.Add("-NoLogo") | Out-Null
        $arguments.Add("-NoProfile") | Out-Null
        $arguments.Add("-ExecutionPolicy") | Out-Null
        $arguments.Add("Bypass") | Out-Null
        $arguments.Add("-File") | Out-Null
        $arguments.Add($CliPath) | Out-Null
        $arguments.Add("run-leased-job") | Out-Null
        $arguments.Add("-RunId") | Out-Null
        $arguments.Add($RunId) | Out-Null
        $arguments.Add("-JobPackageFile") | Out-Null
        $arguments.Add($packageFile) | Out-Null

        foreach ($key in @($WorkerParameters.Keys | Sort-Object)) {
            $value = $WorkerParameters[$key]
            if ($null -eq $value) {
                continue
            }
            $arguments.Add("-$key") | Out-Null
            if ($value -is [bool]) {
                if (-not $value) {
                    $arguments.RemoveAt($arguments.Count - 1)
                }
            }
            else {
                $arguments.Add([string]$value) | Out-Null
            }
        }

        $startParams = @{
            FilePath = $PwshPath
            ArgumentList = @($arguments.ToArray())
            WorkingDirectory = $ProjectRoot
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
            PassThru = $true
        }
        if ($IsWindows) {
            $startParams["WindowStyle"] = "Hidden"
        }

        $process = Start-Process @startParams
        $processes.Add([ordered]@{
            process = $process
            job_id = $identity["job_id"]
            task_id = $identity["task_id"]
            package_path = $packageFile
            stdout_log = $stdoutPath
            stderr_log = $stderrPath
            started_at = $slotStartedAt
        }) | Out-Null
    }

    foreach ($entry in @($processes.ToArray())) {
        $entry["process"].WaitForExit()
        $entry["finished_at"] = Get-Date
    }

    $finishedAt = Get-Date
    $workerResults = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($processes.ToArray())) {
        $process = $entry["process"]
        $workerResults.Add([ordered]@{
            job_id = $entry["job_id"]
            task_id = $entry["task_id"]
            package_path = $entry["package_path"]
            exit_code = $process.ExitCode
            stdout_log = $entry["stdout_log"]
            stderr_log = $entry["stderr_log"]
            started_at = $entry["started_at"].ToUniversalTime().ToString("o")
            finished_at = $entry["finished_at"].ToUniversalTime().ToString("o")
            elapsed_ms = [int64]([datetime]$entry["finished_at"] - [datetime]$entry["started_at"]).TotalMilliseconds
        }) | Out-Null
    }

    return [ordered]@{
        workspace_mode = "isolated-copy-experimental"
        run_id = $RunId
        launched_count = @($workerResults.ToArray()).Count
        started_at = $startedAt.ToUniversalTime().ToString("o")
        finished_at = $finishedAt.ToUniversalTime().ToString("o")
        elapsed_ms = [int64]($finishedAt - $startedAt).TotalMilliseconds
        log_directory = [System.IO.Path]::GetFullPath($logRoot)
        workers = @($workerResults.ToArray())
        all_succeeded = -not [bool](@($workerResults.ToArray()) | Where-Object { [int]$_["exit_code"] -ne 0 })
    }
}
