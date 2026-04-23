# lib/logging.ps1 - Write-Log function with log rotation
# Requires: $script:ProjectRoot, $script:Role, $script:LogDirectory, $script:LogMaxSizeMB, $script:LogRotation

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")][string]$Level = "Info",
        [string]$LogDir = $(if ($script:LogDirectory) { $script:LogDirectory } else { "logs" })
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] [$($script:Role)] $Message"
    
    # Console output with colors
    switch ($Level) {
        "Info" { Write-Host $logEntry -ForegroundColor Cyan }
        "Warning" { Write-Host $logEntry -ForegroundColor Yellow }
        "Error" { Write-Host $logEntry -ForegroundColor Red }
        "Success" { Write-Host $logEntry -ForegroundColor Green }
    }
    
    # File output
    try {
        $logPath = Join-Path $script:ProjectRoot $LogDir
        if (-not (Test-Path $logPath)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        
        $logFile = Join-Path $logPath "agent-$($script:Role).log"
        
        # Log rotation check
        if (Test-Path $logFile) {
            $logSize = (Get-Item $logFile).Length / 1MB
            if ($logSize -gt $script:LogMaxSizeMB) {
                # Rotate logs
                for ($i = $script:LogRotation - 1; $i -ge 1; $i--) {
                    $oldLog = "${logFile}.${i}"
                    $newLog = "${logFile}.$($i + 1)"
                    if (Test-Path $oldLog) {
                        Move-Item -Path $oldLog -Destination $newLog -Force
                    }
                }
                Move-Item -Path $logFile -Destination "${logFile}.1" -Force
            }
        }
        
        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Fallback to console only if file logging fails
        Write-Host "[Log Error] Failed to write to log file: $_" -ForegroundColor DarkGray
    }
}
