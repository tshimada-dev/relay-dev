function Get-RunLockPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $RunId
    return (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "run.lock")
}

function Acquire-RunLock {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [int]$RetryCount = $(if ($script:LockRetryCount) { [int]$script:LockRetryCount } else { 30 }),
        [int]$RetryDelayMs = $(if ($script:LockRetryDelay) { [int]$script:LockRetryDelay } else { 200 }),
        [int]$TimeoutSec = $(if ($script:LockTimeout) { [int]$script:LockTimeout } else { 300 })
    )

    $lockPath = Get-RunLockPath -ProjectRoot $ProjectRoot -RunId $RunId
    $attempt = 0
    $sanitizedRetryCount = [Math]::Max($RetryCount, 0)
    $sanitizedRetryDelayMs = [Math]::Max($RetryDelayMs, 0)
    $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { $null }
    $lastError = ""

    while ($true) {
        $attempt++

        try {
            try {
                $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                $stream.SetLength(0)

                $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8, 1024, $true)
                try {
                    $payload = [ordered]@{
                        run_id = $RunId
                        pid = $PID
                        acquired_at = (Get-Date).ToString("o")
                    }
                    $writer.Write(($payload | ConvertTo-Json -Compress))
                    $writer.Flush()
                    $stream.Flush()
                }
                finally {
                    $writer.Dispose()
                }

                return @{
                    run_id = $RunId
                    path = $lockPath
                    stream = $stream
                    acquired_at = (Get-Date).ToString("o")
                    attempt = $attempt
                }
            }
            catch {
                if ($stream) {
                    $stream.Dispose()
                }
                throw
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        $timedOut = $false
        if ($deadline -and (Get-Date) -ge $deadline) {
            $timedOut = $true
        }

        $retryExhausted = $sanitizedRetryCount -gt 0 -and $attempt -ge $sanitizedRetryCount
        if ($timedOut -or $retryExhausted) {
            throw "Run '$RunId' is locked by another step. LockPath: $lockPath. Attempts: $attempt. LastError: $lastError"
        }

        Start-Sleep -Milliseconds $sanitizedRetryDelayMs
    }
}

function Release-RunLock {
    param([AllowNull()]$LockHandle)

    if ($null -eq $LockHandle) {
        return
    }

    $stream = $null
    if ($LockHandle -is [System.Collections.IDictionary]) {
        if ($LockHandle.Contains("stream")) {
            $stream = $LockHandle["stream"]
        }
    }
    elseif ($LockHandle.PSObject.Properties.Name -contains "stream") {
        $stream = $LockHandle.stream
    }
    else {
        $stream = $LockHandle
    }

    if ($stream -is [System.IDisposable]) {
        try {
            $stream.Dispose()
        }
        catch {
        }
    }
}
