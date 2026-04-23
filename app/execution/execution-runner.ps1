function New-ExecutionJobId {
    param(
        [string]$Phase = "Phase0",
        [string]$Role = "agent",
        [datetime]$Now = (Get-Date)
    )

    return "job-{0}-{1}-{2}" -f $Now.ToString("yyyyMMddHHmmss"), $Phase.ToLowerInvariant(), $Role.ToLowerInvariant()
}

function Get-ExecutionJobDirectory {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RunId,
        [Parameter(Mandatory)][string]$JobId
    )

    if ($RunId) {
        Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $RunId
        $jobDir = Join-Path (Get-RunJobsPath -ProjectRoot $ProjectRoot -RunId $RunId) $JobId
    }
    else {
        $jobDir = Join-Path $ProjectRoot "logs\jobs\$JobId"
    }

    if (-not (Test-Path $jobDir)) {
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    }

    return $jobDir
}

function Join-ExecutionArguments {
    param([Parameter(Mandatory)][string[]]$Parts)

    return (($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join " ")
}

function Resolve-ProcessInvocationSpec {
    param([Parameter(Mandatory)]$InvocationSpec)

    $spec = ConvertTo-RelayHashtable -InputObject $InvocationSpec
    $command = [string]$spec["command"]
    $arguments = [string]$spec["arguments"]
    if ([string]::IsNullOrWhiteSpace($command)) {
        return $spec
    }

    $commandInfo = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $commandInfo) {
        return $spec
    }

    $resolvedPath = if ($commandInfo.Path) {
        [string]$commandInfo.Path
    }
    elseif ($commandInfo.Source) {
        [string]$commandInfo.Source
    }
    else {
        $command
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        return $spec
    }

    $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
    switch ($extension) {
        ".ps1" {
            $spec["command"] = "pwsh"
            $spec["arguments"] = Join-ExecutionArguments -Parts @(
                "-NoLogo"
                "-NoProfile"
                "-File"
                "`"$resolvedPath`""
                $arguments
            )
        }
        ".cmd" {
            $spec["command"] = "cmd.exe"
            $spec["arguments"] = Join-ExecutionArguments -Parts @(
                "/d"
                "/c"
                "`"$resolvedPath`""
                $arguments
            )
        }
        ".bat" {
            $spec["command"] = "cmd.exe"
            $spec["arguments"] = Join-ExecutionArguments -Parts @(
                "/d"
                "/c"
                "`"$resolvedPath`""
                $arguments
            )
        }
        default {
            if ($commandInfo.CommandType -eq "Application" -or (Test-Path $resolvedPath)) {
                $spec["command"] = $resolvedPath
            }
        }
    }

    return $spec
}

function Drain-ExecutionOutputQueue {
    param(
        [Parameter(Mandatory)]$Queue,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$StreamName,
        [string]$DisplayPrefix = "provider"
    )

    $line = $null
    while ($Queue.TryDequeue([ref]$line)) {
        if ($null -eq $line) {
            continue
        }

        $Target.Add([string]$line) | Out-Null
        $prefix = "[$DisplayPrefix][$StreamName]"
        switch ($StreamName) {
            "stderr" { Write-Host "$prefix $line" -ForegroundColor Yellow }
            default { Write-Host "$prefix $line" -ForegroundColor DarkGray }
        }
    }
}

function Drain-ExecutionEventStream {
    param(
        [Parameter(Mandatory)][string]$SourceIdentifier,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$StreamName,
        [string]$DisplayPrefix = "provider"
    )

    foreach ($eventRecord in @(Get-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue)) {
        $line = $eventRecord.SourceEventArgs.Data
        if ($null -ne $line) {
            $Target.Add([string]$line) | Out-Null
            $prefix = "[$DisplayPrefix][$StreamName]"
            switch ($StreamName) {
                "stderr" { Write-Host "$prefix $line" -ForegroundColor Yellow }
                default { Write-Host "$prefix $line" -ForegroundColor DarkGray }
            }
        }

        Remove-Event -EventIdentifier $eventRecord.EventIdentifier -ErrorAction SilentlyContinue
    }
}

function Invoke-ExecutionAttempt {
    param(
        [Parameter(Mandatory)]$InvocationSpec,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [scriptblock]$OnStarted,
        [scriptblock]$OnWarn,
        [scriptblock]$OnRetry,
        [scriptblock]$OnAbort
    )

    $warnAfter = 0
    if ($TimeoutPolicy["warn_after_sec"]) {
        $warnAfter = [int]$TimeoutPolicy["warn_after_sec"]
    }

    $retryAfter = 0
    if ($TimeoutPolicy["retry_after_sec"]) {
        $retryAfter = [int]$TimeoutPolicy["retry_after_sec"]
    }

    $abortAfter = 0
    if ($TimeoutPolicy["abort_after_sec"]) {
        $abortAfter = [int]$TimeoutPolicy["abort_after_sec"]
    }

    $resolvedInvocation = Resolve-ProcessInvocationSpec -InvocationSpec $InvocationSpec
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $resolvedInvocation["command"]
    $processInfo.Arguments = [string]$resolvedInvocation["arguments"]
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    if ($processInfo.PSObject.Properties.Name -contains "StandardOutputEncoding") {
        $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    }
    if ($processInfo.PSObject.Properties.Name -contains "StandardErrorEncoding") {
        $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo

    $startedAt = Get-Date
    $null = $process.Start()
    if ($OnStarted) {
        & $OnStarted @{
            pid = $process.Id
            started_at = $startedAt.ToString("o")
            command = $resolvedInvocation["command"]
            arguments = $resolvedInvocation["arguments"]
        }
    }

    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    $stdoutEventId = "relay-$($process.Id)-stdout-$([guid]::NewGuid().ToString('N'))"
    $stderrEventId = "relay-$($process.Id)-stderr-$([guid]::NewGuid().ToString('N'))"
    $stdoutSubscription = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -SourceIdentifier $stdoutEventId
    $stderrSubscription = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -SourceIdentifier $stderrEventId
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    try {
        $process.StandardInput.Write($PromptText)
    }
    catch {
        # Some providers may exit before consuming stdin. Treat this as non-fatal and
        # normalize based on the provider's exit code instead.
    }
    finally {
        try {
            $process.StandardInput.Close()
        }
        catch {
        }
    }

    $warned = $false
    $shouldRetry = $false
    $wasAborted = $false

    while (-not $process.HasExited) {
        Start-Sleep -Seconds 1
        Drain-ExecutionEventStream -SourceIdentifier $stdoutEventId -Target $stdoutLines -StreamName "stdout"
        Drain-ExecutionEventStream -SourceIdentifier $stderrEventId -Target $stderrLines -StreamName "stderr"
        $elapsed = (Get-Date) - $startedAt

        if ($warnAfter -gt 0 -and -not $warned -and $elapsed.TotalSeconds -ge $warnAfter) {
            $warned = $true
            if ($OnWarn) {
                & $OnWarn @{
                    attempt = $Attempt
                    elapsed_seconds = [int]$elapsed.TotalSeconds
                    command = $InvocationSpec["command"]
                }
            }
        }

        if ($retryAfter -gt 0 -and $elapsed.TotalSeconds -ge $retryAfter) {
            if ($OnRetry) {
                & $OnRetry @{
                    attempt = $Attempt
                    elapsed_seconds = [int]$elapsed.TotalSeconds
                    command = $InvocationSpec["command"]
                }
            }
            try {
                $process.Kill()
            }
            catch {
            }
            $shouldRetry = $true
            break
        }

        if ($abortAfter -gt 0 -and $elapsed.TotalSeconds -ge $abortAfter) {
            try {
                $process.Kill()
            }
            catch {
            }
            $wasAborted = $true
            if ($OnAbort) {
                & $OnAbort @{
                    attempt = $Attempt
                    elapsed_seconds = [int]$elapsed.TotalSeconds
                    command = $InvocationSpec["command"]
                }
            }
            break
        }
    }

    $process.WaitForExit()
    Start-Sleep -Milliseconds 200
    Drain-ExecutionEventStream -SourceIdentifier $stdoutEventId -Target $stdoutLines -StreamName "stdout"
    Drain-ExecutionEventStream -SourceIdentifier $stderrEventId -Target $stderrLines -StreamName "stderr"
    Unregister-Event -SourceIdentifier $stdoutEventId -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $stderrEventId -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier $stdoutEventId -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier $stderrEventId -ErrorAction SilentlyContinue
    $stdout = ($stdoutLines.ToArray() -join [Environment]::NewLine)
    $stderr = ($stderrLines.ToArray() -join [Environment]::NewLine)
    $finishedAt = Get-Date

    return [ordered]@{
        process_id = $process.Id
        exit_code = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
        started_at = $startedAt.ToString("o")
        finished_at = $finishedAt.ToString("o")
        elapsed_sec = [int](($finishedAt - $startedAt).TotalSeconds)
        should_retry = $shouldRetry
        was_aborted = $wasAborted
    }
}

function Invoke-ExecutionRunner {
    param(
        [Parameter(Mandatory)]$JobSpec,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [scriptblock]$OnWarn,
        [scriptblock]$OnRetry,
        [scriptblock]$OnAbort
    )

    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $runId = if ($job["run_id"]) { [string]$job["run_id"] } else { Resolve-ActiveRunId -ProjectRoot $ProjectRoot }
    $jobId = if ($job["job_id"]) { [string]$job["job_id"] } else { New-ExecutionJobId -Phase ([string]$job["phase"]) -Role ([string]$job["role"]) }
    $attempt = 1
    if ($job["attempt"]) {
        $attempt = [int]$job["attempt"]
    }

    $maxRetries = 0
    if ($TimeoutPolicy["max_retries"]) {
        $maxRetries = [int]$TimeoutPolicy["max_retries"]
    }
    $invocationSpec = Get-ProviderInvocationSpec -JobSpec $job
    $jobDir = Get-ExecutionJobDirectory -ProjectRoot $ProjectRoot -RunId $runId -JobId $jobId
    $stdoutPath = Join-Path $jobDir "stdout.log"
    $stderrPath = Join-Path $jobDir "stderr.log"
    $resultStatus = "failed"
    $failureClass = $null
    $firstStartedAt = $null
    $finalFinishedAt = $null
    $finalExitCode = 1
    $wasEscalated = $false

    if ($runId) {
        Append-Event -ProjectRoot $ProjectRoot -RunId $runId -Event @{
            type = "job.dispatched"
            job_id = $jobId
            phase = $job["phase"]
            role = $job["role"]
            attempt = $attempt
            provider = $invocationSpec["provider"]
        }
        Write-JobMetadata -ProjectRoot $ProjectRoot -RunId $runId -JobId $jobId -Metadata @{
            run_id = $runId
            job_id = $jobId
            phase = $job["phase"]
            role = $job["role"]
            provider = $invocationSpec["provider"]
            command = $invocationSpec["command"]
            arguments = $invocationSpec["arguments"]
            attempt = $attempt
            status = "dispatched"
            dispatched_at = (Get-Date).ToString("o")
        } | Out-Null
    }

    Set-Content -Path $stdoutPath -Value "" -Encoding UTF8
    Set-Content -Path $stderrPath -Value "" -Encoding UTF8

    while ($true) {
        if ($runId) {
            Append-Event -ProjectRoot $ProjectRoot -RunId $runId -Event @{
                type = "job.started"
                job_id = $jobId
                phase = $job["phase"]
                role = $job["role"]
                attempt = $attempt
                provider = $invocationSpec["provider"]
            }
        }

        $attemptResult = Invoke-ExecutionAttempt -InvocationSpec $invocationSpec -PromptText $PromptText -WorkingDirectory $WorkingDirectory -Attempt $attempt -TimeoutPolicy $TimeoutPolicy -OnStarted {
            param($StartedInfo)

            if ($runId) {
                Write-JobMetadata -ProjectRoot $ProjectRoot -RunId $runId -JobId $jobId -Metadata @{
                    run_id = $runId
                    job_id = $jobId
                    phase = $job["phase"]
                    role = $job["role"]
                    provider = $invocationSpec["provider"]
                    command = $invocationSpec["command"]
                    arguments = $invocationSpec["arguments"]
                    attempt = $attempt
                    status = "running"
                    pid = $StartedInfo["pid"]
                    started_at = $StartedInfo["started_at"]
                } | Out-Null
            }
        } -OnWarn $OnWarn -OnRetry $OnRetry -OnAbort $OnAbort
        if (-not $firstStartedAt) {
            $firstStartedAt = $attemptResult["started_at"]
        }
        $finalFinishedAt = $attemptResult["finished_at"]
        $finalExitCode = [int]$attemptResult["exit_code"]

        $header = "=== attempt $attempt ($(Get-Date -Format "yyyy-MM-dd HH:mm:ss")) ==="
        Add-Content -Path $stdoutPath -Value ($header + [Environment]::NewLine + $attemptResult["stdout"]) -Encoding UTF8
        Add-Content -Path $stderrPath -Value ($header + [Environment]::NewLine + $attemptResult["stderr"]) -Encoding UTF8

        if ($attemptResult["was_aborted"]) {
            $resultStatus = "failed"
            $failureClass = "timeout"
            $wasEscalated = $true
            break
        }

        if ($attemptResult["should_retry"] -and ($attempt -le $maxRetries)) {
            $attempt++
            continue
        }

        if ($attemptResult["should_retry"]) {
            $resultStatus = "failed"
            $failureClass = "timeout"
            break
        }

        if ([int]$attemptResult["exit_code"] -eq 0) {
            $resultStatus = "succeeded"
            $failureClass = $null
        }
        else {
            $resultStatus = "failed"
            $failureClass = "provider_error"
        }
        break
    }

    if ($runId) {
        Append-Event -ProjectRoot $ProjectRoot -RunId $runId -Event @{
            type = "job.finished"
            job_id = $jobId
            phase = $job["phase"]
            role = $job["role"]
            attempt = $attempt
            exit_code = $finalExitCode
            result_status = $resultStatus
            failure_class = $failureClass
        }
        Write-JobMetadata -ProjectRoot $ProjectRoot -RunId $runId -JobId $jobId -Metadata @{
            run_id = $runId
            job_id = $jobId
            phase = $job["phase"]
            role = $job["role"]
            provider = $invocationSpec["provider"]
            command = $invocationSpec["command"]
            arguments = $invocationSpec["arguments"]
            attempt = $attempt
            status = "finished"
            pid = $attemptResult["process_id"]
            started_at = $firstStartedAt
            finished_at = $finalFinishedAt
            exit_code = $finalExitCode
            result_status = $resultStatus
            failure_class = $failureClass
            was_escalated = $wasEscalated
        } | Out-Null
    }

    return [ordered]@{
        job_id = $jobId
        run_id = $runId
        attempt = $attempt
        exit_code = $finalExitCode
        result_status = $resultStatus
        started_at = $firstStartedAt
        finished_at = $finalFinishedAt
        stdout_path = $stdoutPath
        stderr_path = $stderrPath
        failure_class = $failureClass
        provider_metadata = @{
            provider = $invocationSpec["provider"]
            command = $invocationSpec["command"]
            arguments = $invocationSpec["arguments"]
        }
        was_escalated = $wasEscalated
    }
}
