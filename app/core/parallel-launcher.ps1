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

function Import-TaskGroupCoordinatorPackage {
    param([Parameter(Mandatory)]$Package)

    if ($Package -is [string]) {
        if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
            throw "Task group package file not found: $Package"
        }
        return (ConvertTo-RelayHashtable -InputObject (Get-Content -LiteralPath $Package -Raw -Encoding UTF8 | ConvertFrom-Json))
    }

    return (ConvertTo-RelayHashtable -InputObject $Package)
}

function Update-TaskGroupCoordinatorRunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)]$Patch,
        [int]$LockTimeoutSec = 30
    )

    $lock = $null
    try {
        $lock = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $RunId -RetryCount 0 -RetryDelayMs 200 -TimeoutSec $LockTimeoutSec
        $state = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
        if (-not $state) {
            throw "Run '$RunId' does not exist."
        }
        $state = Initialize-RunStateCompatibilityFields -RunState $state
        $groups = ConvertTo-RelayHashtable -InputObject $state["task_groups"]
        $entry = ConvertTo-RelayHashtable -InputObject $groups[$GroupId]
        if (-not $entry) {
            $entry = [ordered]@{ id = $GroupId; group_id = $GroupId }
        }

        $now = (Get-Date).ToString("o")
        foreach ($key in @($Patch.Keys)) {
            $entry[$key] = $Patch[$key]
        }
        $entry["updated_at"] = $now
        if (-not $entry.ContainsKey("created_at") -or [string]::IsNullOrWhiteSpace([string]$entry["created_at"])) {
            $entry["created_at"] = $now
        }
        $groups[$GroupId] = $entry
        $state["task_groups"] = $groups
        $state["updated_at"] = $now
        Write-RunState -ProjectRoot $ProjectRoot -RunState $state | Out-Null
        return $entry
    }
    finally {
        if ($lock) {
            Release-RunLock -LockHandle $lock
        }
    }
}

function Resolve-TaskGroupAggregateStatus {
    param([Parameter(Mandatory)][object[]]$Workers)

    $workerStatuses = @($Workers | ForEach-Object {
            $worker = ConvertTo-RelayHashtable -InputObject $_
            [string]$worker["status"]
        })
    $runningCount = @($workerStatuses | Where-Object { $_ -in @("queued", "running", "waiting_approval") }).Count
    if ($runningCount -gt 0) {
        return "running"
    }

    $succeededCount = @($workerStatuses | Where-Object { $_ -eq "succeeded" }).Count
    $failedCount = @($workerStatuses | Where-Object { $_ -eq "failed" }).Count
    if ($succeededCount -eq $workerStatuses.Count -and $workerStatuses.Count -gt 0) {
        return "succeeded"
    }
    if ($succeededCount -gt 0 -and $failedCount -gt 0) {
        return "partial_failed"
    }
    return "failed"
}

function Complete-TaskGroupCoordinatorRunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$GroupId,
        [int]$LockTimeoutSec = 30
    )

    $lock = $null
    try {
        $lock = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $RunId -RetryCount 0 -RetryDelayMs 200 -TimeoutSec $LockTimeoutSec
        $state = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
        if (-not $state) {
            throw "Run '$RunId' does not exist."
        }
        $state = Initialize-RunStateCompatibilityFields -RunState $state
        $groups = ConvertTo-RelayHashtable -InputObject $state["task_groups"]
        $workers = ConvertTo-RelayHashtable -InputObject $state["task_group_workers"]
        $group = ConvertTo-RelayHashtable -InputObject $groups[$GroupId]
        if (-not $group) {
            throw "Task group '$GroupId' does not exist in run-state."
        }

        $workerRows = New-Object System.Collections.Generic.List[object]
        foreach ($workerId in @($group["worker_ids"])) {
            $worker = ConvertTo-RelayHashtable -InputObject $workers[[string]$workerId]
            if ($worker) {
                $workerRows.Add($worker) | Out-Null
            }
        }
        $status = Resolve-TaskGroupAggregateStatus -Workers @($workerRows.ToArray())
        $failureRows = @($workerRows.ToArray() | Where-Object { [string](ConvertTo-RelayHashtable -InputObject $_)["status"] -eq "failed" })
        $now = (Get-Date).ToString("o")
        $group["status"] = $status
        $group["updated_at"] = $now
        $group["completed_at"] = if ($status -in @("succeeded", "partial_failed", "failed")) { $now } else { $null }
        $group["worker_results"] = @($workerRows.ToArray() | ForEach-Object {
                $worker = ConvertTo-RelayHashtable -InputObject $_
                if ($worker["worker_result"]) { ConvertTo-RelayHashtable -InputObject $worker["worker_result"] } else {
                    [ordered]@{
                        worker_id = [string]$worker["worker_id"]
                        group_id = [string]$worker["group_id"]
                        task_id = [string]$worker["task_id"]
                        status = [string]$worker["status"]
                        final_phase = [string]$worker["final_phase"]
                        errors = @($worker["errors"])
                        artifact_refs = @($worker["artifact_refs"])
                        changed_files = @($worker["declared_changed_files"])
                        workspace_path = [string]$worker["workspace_path"]
                    }
                }
            })
        $group["failure_summary"] = if ($failureRows.Count -gt 0) { "$($failureRows.Count) task group worker(s) failed" } else { $null }
        $groups[$GroupId] = $group
        $state["task_groups"] = $groups
        $state["updated_at"] = $now
        Write-RunState -ProjectRoot $ProjectRoot -RunState $state | Out-Null

        return [ordered]@{
            group = $group
            workers = @($workerRows.ToArray())
            run_state = $state
        }
    }
    finally {
        if ($lock) {
            Release-RunLock -LockHandle $lock
        }
    }
}

function Invoke-TaskGroupWorkers {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$CliPath = (Join-Path $ProjectRoot "app/cli.ps1"),
        [string]$PwshPath = "pwsh",
        [string]$LogDirectory,
        [hashtable]$WorkerParameters = @{},
        [int]$LockTimeoutSec = 30
    )

    $packageObject = Import-TaskGroupCoordinatorPackage -Package $Package
    $runId = [string]$packageObject["run_id"]
    $groupId = [string]$packageObject["group_id"]
    if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($groupId)) {
        throw "Task group package requires run_id and group_id."
    }

    $workers = @($packageObject["workers"] | ForEach-Object { ConvertTo-RelayHashtable -InputObject $_ })
    if ($workers.Count -eq 0) {
        throw "Task group package '$groupId' has no workers."
    }

    $startedAt = Get-Date
    $logRoot = if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $runId) "task-group-worker-logs"
    }
    else {
        $LogDirectory
    }
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

    Update-TaskGroupCoordinatorRunState -ProjectRoot $ProjectRoot -RunId $runId -GroupId $groupId -LockTimeoutSec $LockTimeoutSec -Patch @{
        status = "running"
        coordinator_started_at = $startedAt.ToUniversalTime().ToString("o")
    } | Out-Null

    $processes = New-Object System.Collections.Generic.List[object]
    foreach ($worker in $workers) {
        $workerId = [string]$worker["worker_id"]
        if ([string]::IsNullOrWhiteSpace($workerId)) {
            $workerId = [string]$worker["id"]
        }
        if ([string]::IsNullOrWhiteSpace($workerId)) {
            throw "Task group package '$groupId' contains a worker without worker_id."
        }
        $safeWorkerId = $workerId -replace '[^A-Za-z0-9_.-]', '_'
        $slotStartedAt = Get-Date
        $stdoutPath = Join-Path $logRoot "$safeWorkerId.stdout.log"
        $stderrPath = Join-Path $logRoot "$safeWorkerId.stderr.log"

        $arguments = New-Object System.Collections.Generic.List[string]
        $arguments.Add("-NoLogo") | Out-Null
        $arguments.Add("-NoProfile") | Out-Null
        $arguments.Add("-ExecutionPolicy") | Out-Null
        $arguments.Add("Bypass") | Out-Null
        $arguments.Add("-File") | Out-Null
        $arguments.Add($CliPath) | Out-Null
        $arguments.Add("run-task-group-worker") | Out-Null
        $arguments.Add("-JobPackageFile") | Out-Null
        $arguments.Add((Resolve-ParallelJobPackageFile -Package $Package)) | Out-Null
        $arguments.Add("-WorkerId") | Out-Null
        $arguments.Add($workerId) | Out-Null

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
            worker_id = $workerId
            task_id = [string]$worker["task_id"]
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
    $aggregate = ConvertTo-RelayHashtable -InputObject (Complete-TaskGroupCoordinatorRunState -ProjectRoot $ProjectRoot -RunId $runId -GroupId $groupId -LockTimeoutSec $LockTimeoutSec)
    $group = ConvertTo-RelayHashtable -InputObject $aggregate["group"]
    $workerRows = @($aggregate["workers"] | ForEach-Object { ConvertTo-RelayHashtable -InputObject $_ })

    $launchRows = @($processes.ToArray() | ForEach-Object {
            $process = $_["process"]
            [ordered]@{
                worker_id = [string]$_["worker_id"]
                task_id = [string]$_["task_id"]
                exit_code = $process.ExitCode
                stdout_log = [string]$_["stdout_log"]
                stderr_log = [string]$_["stderr_log"]
                started_at = ([datetime]$_["started_at"]).ToUniversalTime().ToString("o")
                finished_at = ([datetime]$_["finished_at"]).ToUniversalTime().ToString("o")
                elapsed_ms = [int64]([datetime]$_["finished_at"] - [datetime]$_["started_at"]).TotalMilliseconds
            }
        })

    return [ordered]@{
        mode = "task-group"
        run_id = $runId
        group_id = $groupId
        status = [string]$group["status"]
        launched_count = $launchRows.Count
        started_at = $startedAt.ToUniversalTime().ToString("o")
        finished_at = $finishedAt.ToUniversalTime().ToString("o")
        elapsed_ms = [int64]($finishedAt - $startedAt).TotalMilliseconds
        log_directory = [System.IO.Path]::GetFullPath($logRoot)
        group = $group
        workers = @($workerRows)
        launches = @($launchRows)
        all_succeeded = ([string]$group["status"] -eq "succeeded")
    }
}

function Invoke-TaskGroupCoordinator {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$CliPath = (Join-Path $ProjectRoot "app/cli.ps1"),
        [string]$PwshPath = "pwsh",
        [string]$LogDirectory,
        [hashtable]$WorkerParameters = @{},
        [int]$LockTimeoutSec = 30
    )

    return Invoke-TaskGroupWorkers -Package $Package -ProjectRoot $ProjectRoot -CliPath $CliPath -PwshPath $PwshPath -LogDirectory $LogDirectory -WorkerParameters $WorkerParameters -LockTimeoutSec $LockTimeoutSec
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
