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
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Parts)

    return (($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join " ")
}

function Quote-ExecutionArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\\') {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            $null = $builder.Append(('\\' * (($backslashCount * 2) + 1)))
            $null = $builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            $null = $builder.Append(('\\' * $backslashCount))
            $backslashCount = 0
        }

        $null = $builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        $null = $builder.Append(('\\' * ($backslashCount * 2)))
    }

    $null = $builder.Append('"')
    return $builder.ToString()
}

function Get-ExecutionPromptMode {
    param([Parameter(Mandatory)]$InvocationSpec)

    $spec = ConvertTo-RelayHashtable -InputObject $InvocationSpec
    $promptMode = [string]$spec["prompt_mode"]
    if ([string]::IsNullOrWhiteSpace($promptMode)) {
        return "stdin"
    }

    return $promptMode.ToLowerInvariant()
}

function Get-ExecutionPromptFlag {
    param([Parameter(Mandatory)]$InvocationSpec)

    $spec = ConvertTo-RelayHashtable -InputObject $InvocationSpec
    $promptFlag = [string]$spec["prompt_flag"]
    if ([string]::IsNullOrWhiteSpace($promptFlag)) {
        return "-p"
    }

    return $promptFlag
}

function Get-ExecutionArgumentsForAttempt {
    param(
        [Parameter(Mandatory)]$InvocationSpec,
        [Parameter(Mandatory)][string]$PromptText,
        [switch]$ForDisplay
    )

    $spec = ConvertTo-RelayHashtable -InputObject $InvocationSpec
    $arguments = [string]$spec["arguments"]
    if ((Get-ExecutionPromptMode -InvocationSpec $spec) -ne "argv") {
        return $arguments
    }

    $promptToken = if ($ForDisplay) { "<prompt>" } else { Quote-ExecutionArgument -Value $PromptText }
    return (Join-ExecutionArguments -Parts @(
            $arguments
            (Get-ExecutionPromptFlag -InvocationSpec $spec)
            $promptToken
        ))
}

function Apply-ExecutionEnvironmentOverrides {
    param(
        [Parameter(Mandatory)]$ProcessInfo,
        [Parameter(Mandatory)]$InvocationSpec
    )

    $spec = ConvertTo-RelayHashtable -InputObject $InvocationSpec
    $environment = ConvertTo-RelayHashtable -InputObject $spec["environment"]
    if (-not ($environment -is [System.Collections.IDictionary])) {
        return
    }

    foreach ($name in $environment.Keys) {
        $value = [string]$environment[$name]
        if ($ProcessInfo.PSObject.Properties.Name -contains "Environment") {
            $ProcessInfo.Environment[[string]$name] = $value
        }
        else {
            $ProcessInfo.EnvironmentVariables[[string]$name] = $value
        }
    }
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

function Stop-ExecutionProcessTreeById {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)]$ChildrenByParent
    )

    foreach ($child in @($ChildrenByParent[$ProcessId])) {
        Stop-ExecutionProcessTreeById -ProcessId ([int]$child.ProcessId) -ChildrenByParent $ChildrenByParent
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    }
    catch {
    }
}

function Stop-ExecutionProcessTree {
    param([AllowNull()]$Process)

    if ($null -eq $Process) {
        return
    }

    $processId = 0
    try {
        $processId = [int]$Process.Id
    }
    catch {
        return
    }

    if ($processId -le 0) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            $killTreeMethod = $Process.GetType().GetMethod("Kill", [type[]]@([bool]))
            if ($null -ne $killTreeMethod) {
                $Process.Kill($true)
                return
            }
        }
    }
    catch {
    }

    $isWindowsPlatform = $false
    try {
        $isWindowsPlatform = [bool]$IsWindows -or $env:OS -eq "Windows_NT"
    }
    catch {
        $isWindowsPlatform = $env:OS -eq "Windows_NT"
    }

    if (-not $isWindowsPlatform) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
        return
    }

    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $childrenByParent = @{}
    foreach ($candidate in $allProcesses) {
        $parentId = [int]$candidate.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = @()
        }
        $childrenByParent[$parentId] = @($childrenByParent[$parentId]) + $candidate
    }

    Stop-ExecutionProcessTreeById -ProcessId $processId -ChildrenByParent $childrenByParent
}

function Request-ExecutionProcessStop {
    param([AllowNull()]$Process)

    if ($null -eq $Process) {
        return
    }

    $processId = 0
    try {
        $processId = [int]$Process.Id
    }
    catch {
        return
    }

    if ($processId -le 0) {
        return
    }

    $isWindowsPlatform = $false
    try {
        $isWindowsPlatform = [bool]$IsWindows -or $env:OS -eq "Windows_NT"
    }
    catch {
        $isWindowsPlatform = $env:OS -eq "Windows_NT"
    }

    if ($isWindowsPlatform) {
        $taskkillCommand = Get-Command taskkill.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($taskkillCommand) {
            $taskkillPath = if ($taskkillCommand.Path) { [string]$taskkillCommand.Path } else { [string]$taskkillCommand.Source }
            try {
                Start-Process -FilePath $taskkillPath -ArgumentList @("/T", "/F", "/PID", "$processId") -WindowStyle Hidden | Out-Null
                return
            }
            catch {
            }
        }

        try {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
        return
    }

    Stop-ExecutionProcessTree -Process $Process
}

function Write-ExecutionProbeTrace {
    param([AllowNull()]$Payload)

    $logPath = $env:RELAY_DEV_ARTIFACT_PROBE_LOG
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        return
    }

    try {
        $entry = ConvertTo-RelayHashtable -InputObject $Payload
        Add-Content -Path $logPath -Value ($entry | ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
    }
    catch {
    }
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
        [scriptblock]$ArtifactCompletionProbe,
        [int]$ArtifactCompletionStabilitySec = 5,
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
    $promptMode = Get-ExecutionPromptMode -InvocationSpec $resolvedInvocation
    $executionArguments = Get-ExecutionArgumentsForAttempt -InvocationSpec $resolvedInvocation -PromptText $PromptText
    $displayArguments = Get-ExecutionArgumentsForAttempt -InvocationSpec $resolvedInvocation -PromptText $PromptText -ForDisplay
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $resolvedInvocation["command"]
    $processInfo.Arguments = $executionArguments
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $promptMode -eq "stdin"
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    if ($processInfo.RedirectStandardInput -and $processInfo.PSObject.Properties.Name -contains "StandardInputEncoding") {
        $processInfo.StandardInputEncoding = $utf8NoBom
    }
    if ($processInfo.PSObject.Properties.Name -contains "StandardOutputEncoding") {
        $processInfo.StandardOutputEncoding = $utf8NoBom
    }
    if ($processInfo.PSObject.Properties.Name -contains "StandardErrorEncoding") {
        $processInfo.StandardErrorEncoding = $utf8NoBom
    }
    Apply-ExecutionEnvironmentOverrides -ProcessInfo $processInfo -InvocationSpec $resolvedInvocation

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo

    $startedAt = Get-Date
    $null = $process.Start()
    if ($OnStarted) {
        & $OnStarted @{
            pid = $process.Id
            started_at = $startedAt.ToString("o")
            command = $resolvedInvocation["command"]
            arguments = $displayArguments
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
    if ($promptMode -eq "stdin") {
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
    }

    $warned = $false
    $shouldRetry = $false
    $wasAborted = $false
    $artifactCompleted = $false
    $artifactCompletion = $null
    $artifactCompletionCandidate = $null
    $processStopRequested = $false
    Write-ExecutionProbeTrace -Payload @{
        detected = $false
        reason = "attempt_started"
        has_probe = [bool]$ArtifactCompletionProbe
        attempt = $Attempt
        pid = $process.Id
    }

    while (-not $process.HasExited) {
        Start-Sleep -Seconds 1
        Drain-ExecutionEventStream -SourceIdentifier $stdoutEventId -Target $stdoutLines -StreamName "stdout"
        Drain-ExecutionEventStream -SourceIdentifier $stderrEventId -Target $stderrLines -StreamName "stderr"
        $elapsed = (Get-Date) - $startedAt
        Write-ExecutionProbeTrace -Payload @{
            detected = $false
            reason = "attempt_poll"
            has_probe = [bool]$ArtifactCompletionProbe
            attempt = $Attempt
            pid = $process.Id
            elapsed_seconds = [int]$elapsed.TotalSeconds
        }

        if ($ArtifactCompletionProbe) {
            $probeResult = $null
            try {
                $probeResult = & $ArtifactCompletionProbe @{
                    attempt = $Attempt
                    pid = $process.Id
                    started_at = $startedAt.ToString("o")
                    observed_at = (Get-Date).ToString("o")
                }
            }
            catch {
                Write-ExecutionProbeTrace -Payload @{
                    detected = $false
                    reason = "probe_call_exception"
                    attempt = $Attempt
                    pid = $process.Id
                    errors = @([string]$_.Exception.Message)
                }
                $probeResult = $null
            }

            $probe = ConvertTo-RelayHashtable -InputObject $probeResult
            if ($probe -and [bool]$probe["detected"]) {
                $snapshot = [string]$probe["snapshot"]
                if ([string]::IsNullOrWhiteSpace($snapshot)) {
                    $snapshot = "__artifact_complete__"
                }

                $observedAt = Get-Date
                if ($artifactCompletionCandidate -and [string]$artifactCompletionCandidate["snapshot"] -eq $snapshot) {
                    $firstSeen = [datetime]::MinValue
                    $firstSeenRaw = [string]$artifactCompletionCandidate["first_seen"]
                    if ([datetime]::TryParse($firstSeenRaw, [ref]$firstSeen)) {
                        if (($observedAt - $firstSeen).TotalSeconds -ge $ArtifactCompletionStabilitySec) {
                            $artifactCompletion = $probe
                            $artifactCompletion["first_detected_at"] = $firstSeen.ToString("o")
                            $artifactCompletion["confirmed_at"] = $observedAt.ToString("o")
                            $artifactCompletion["stability_seconds"] = $ArtifactCompletionStabilitySec
                            $processStopRequested = $true
                            Request-ExecutionProcessStop -Process $process
                            $artifactCompleted = $true
                            break
                        }
                    }
                }
                else {
                    $artifactCompletionCandidate = @{
                        snapshot = $snapshot
                        first_seen = $observedAt.ToString("o")
                    }
                }
            }
            else {
                $artifactCompletionCandidate = $null
            }
        }

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
                $processStopRequested = $true
                Request-ExecutionProcessStop -Process $process
            }
            catch {
            }
            $shouldRetry = $true
            break
        }

        if ($abortAfter -gt 0 -and $elapsed.TotalSeconds -ge $abortAfter) {
            try {
                $processStopRequested = $true
                Request-ExecutionProcessStop -Process $process
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

    if (-not $process.HasExited) {
        if ($artifactCompleted) {
            try {
                $process.CancelOutputRead()
            }
            catch {
            }
            try {
                $process.CancelErrorRead()
            }
            catch {
            }
        }
        elseif ($processStopRequested) {
            $null = $process.WaitForExit(5000)
        }
        else {
            $process.WaitForExit()
        }
    }
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
    $exitCode = if ($process.HasExited) {
        $process.ExitCode
    }
    elseif ($artifactCompleted) {
        0
    }
    else {
        1
    }

    return [ordered]@{
        process_id = $process.Id
        exit_code = $exitCode
        stdout = $stdout
        stderr = $stderr
        started_at = $startedAt.ToString("o")
        finished_at = $finishedAt.ToString("o")
        elapsed_sec = [int](($finishedAt - $startedAt).TotalSeconds)
        should_retry = $shouldRetry
        was_aborted = $wasAborted
        artifact_completed = $artifactCompleted
        artifact_completion = $artifactCompletion
    }
}

function Invoke-ExecutionRunner {
    param(
        [Parameter(Mandatory)]$JobSpec,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [scriptblock]$ArtifactCompletionProbe,
        [int]$ArtifactCompletionStabilitySec = 5,
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
    Write-ExecutionProbeTrace -Payload @{
        detected = $false
        reason = "runner_started"
        has_probe = [bool]$ArtifactCompletionProbe
        job_id = $jobId
        run_id = $runId
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
    $recoveredFromArtifacts = $false
    $artifactCompletion = $null

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

        $attemptResult = Invoke-ExecutionAttempt -InvocationSpec $invocationSpec -PromptText $PromptText -WorkingDirectory $WorkingDirectory -Attempt $attempt -TimeoutPolicy $TimeoutPolicy -ArtifactCompletionProbe $ArtifactCompletionProbe -ArtifactCompletionStabilitySec $ArtifactCompletionStabilitySec -OnStarted {
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

        if ([bool]$attemptResult["artifact_completed"]) {
            $resultStatus = "succeeded"
            $failureClass = $null
            $recoveredFromArtifacts = $true
            $artifactCompletion = ConvertTo-RelayHashtable -InputObject $attemptResult["artifact_completion"]
            $finalExitCode = 0
            break
        }

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
            recovered_from_artifacts = $recoveredFromArtifacts
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
            recovered_from_artifacts = $recoveredFromArtifacts
            artifact_completion = $artifactCompletion
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
        recovered_from_artifacts = $recoveredFromArtifacts
        artifact_completion = $artifactCompletion
        provider_metadata = @{
            provider = $invocationSpec["provider"]
            command = $invocationSpec["command"]
            arguments = $invocationSpec["arguments"]
        }
        was_escalated = $wasEscalated
    }
}
