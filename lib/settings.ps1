# lib/settings.ps1 - Configuration resolution and validation
# Requires: Read-Config, Get-DefaultValue (from config/common.ps1), Write-Log (from lib/logging.ps1)

function Test-ConfigValues {
    param([hashtable]$ConfigHash)
    
    $requiredIntegers = @(
        "escalation.phase1_timeout_sec",
        "escalation.phase2_timeout_sec",
        "escalation.phase3_timeout_sec",
        "watcher.poll_fallback_sec",
        "watcher.debounce_ms",
        "lock.retry_count",
        "lock.retry_delay_ms",
        "lock.timeout_sec",
        "log.max_size_mb",
        "log.rotation_count"
    )
    
    $errors = @()
    
    foreach ($key in $requiredIntegers) {
        $val = $ConfigHash[$key]
        if ($val -and -not ($val -match '^\d+$')) {
            $errors += "Config error: $key must be an integer (got '$val')"
        }
    }
    
    # Check timeout values are in correct order
    $phase1 = [int](Get-DefaultValue $ConfigHash["escalation.phase1_timeout_sec"] "120")
    $phase2 = [int](Get-DefaultValue $ConfigHash["escalation.phase2_timeout_sec"] "240")
    $phase3 = [int](Get-DefaultValue $ConfigHash["escalation.phase3_timeout_sec"] "480")
    
    if ($phase1 -ge $phase2) {
        $errors += "Config error: escalation.phase1_timeout_sec ($phase1) must be less than phase2_timeout_sec ($phase2)"
    }
    if ($phase2 -ge $phase3) {
        $errors += "Config error: escalation.phase2_timeout_sec ($phase2) must be less than phase3_timeout_sec ($phase3)"
    }
    
    if ($errors.Count -gt 0) {
        foreach ($err in $errors) {
            Write-Host $err -ForegroundColor Red
        }
        throw "Configuration validation failed"
    }
    
    Write-Log "Configuration validated successfully" -Level Info
}

function Initialize-Settings {
    param(
        [hashtable]$Config,
        [string]$Role
    )
    
    # Validate config
    Test-ConfigValues -ConfigHash $Config
    
    # CLI settings
    $script:CliCommand = Get-DefaultValue $Config["cli.command"]                   "gemini"
    $script:CliFlags = Get-DefaultValue $Config["cli.flags"]                     "-y -p"
    # Role-specific CLI overrides (empty string = fall back to common command/flags)
    $script:ImplementerCommand = if ($Config["cli.implementer_command"] -and $Config["cli.implementer_command"] -ne "") { $Config["cli.implementer_command"] } else { $script:CliCommand }
    $script:ImplementerFlags = if ($Config["cli.implementer_flags"] -and $Config["cli.implementer_flags"] -ne "") { $Config["cli.implementer_flags"] } else { $script:CliFlags }
    $script:ReviewerCommand = if ($Config["cli.reviewer_command"] -and $Config["cli.reviewer_command"] -ne "") { $Config["cli.reviewer_command"] } else { $script:CliCommand }
    $script:ReviewerFlags = if ($Config["cli.reviewer_flags"] -and $Config["cli.reviewer_flags"] -ne "") { $Config["cli.reviewer_flags"] } else { $script:CliFlags }
    
    # Path settings
    $script:StatusFile = Get-DefaultValue $Config["paths.status_file"]             "queue/status.yaml"
    $script:LockFile = Get-DefaultValue $Config["paths.lock_file"]              "queue/status.lock"
    $script:DashboardFile = Get-DefaultValue $Config["paths.dashboard_file"]          "dashboard.md"
    $script:TaskFile = Get-DefaultValue $Config["paths.task_file"]              "tasks/task.md"
    
    # Resolve project directory (where code is generated)
    $ProjectDirRaw = Get-DefaultValue $Config["paths.project_dir"] ""
    if ($ProjectDirRaw -and $ProjectDirRaw -ne "" -and $ProjectDirRaw -ne ".") {
        $script:ProjectDir = [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $ProjectDirRaw))
        if (-not (Test-Path $script:ProjectDir)) {
            throw "project_dir '$($script:ProjectDir)' does not exist. Please create it or fix paths.project_dir in config/settings.yaml"
        }
    }
    else {
        $script:ProjectDir = $script:ProjectRoot
    }

    $designFileRaw = Get-DefaultValue $Config["paths.design_file"] ""
    if ($designFileRaw -and $designFileRaw -ne "") {
        if ([System.IO.Path]::IsPathRooted($designFileRaw)) {
            $script:DesignFile = $designFileRaw
        }
        else {
            $script:DesignFile = [System.IO.Path]::GetFullPath((Join-Path $script:ProjectDir $designFileRaw))
        }
    }
    else {
        $script:DesignFile = (Join-Path $script:ProjectDir "DESIGN.md")
    }
    
    # Watcher settings
    $script:FallbackSec = [int](Get-DefaultValue $Config["watcher.poll_fallback_sec"]          "5")
    $script:DebounceMsec = [int](Get-DefaultValue $Config["watcher.debounce_ms"]                "300")
    
    # Escalation settings
    $script:EscPhase1Sec = [int](Get-DefaultValue $Config["escalation.phase1_timeout_sec"]      "120")
    $script:EscPhase2Sec = [int](Get-DefaultValue $Config["escalation.phase2_timeout_sec"]      "240")
    $script:EscPhase3Sec = [int](Get-DefaultValue $Config["escalation.phase3_timeout_sec"]      "480")
    
    # Lock settings
    $script:LockRetryCount = [int](Get-DefaultValue $Config["lock.retry_count"]                   "30")
    $script:LockRetryDelay = [int](Get-DefaultValue $Config["lock.retry_delay_ms"]                "200")
    $script:LockTimeout = [int](Get-DefaultValue $Config["lock.timeout_sec"]                   "300")
    $script:LoopGuardWaitSec = [int](Get-DefaultValue $Config["lock.loop_guard_wait_sec"]        "1800")
    
    # Log settings
    $script:LogDirectory = Get-DefaultValue $Config["log.directory"]                        "logs"
    $script:LogMaxSizeMB = [int](Get-DefaultValue $Config["log.max_size_mb"]                    "10")
    $script:LogRotation = [int](Get-DefaultValue $Config["log.rotation_count"]                 "5")
    
    # Human review settings
    $script:HumanReviewEnabled = Get-DefaultValue $Config["human_review.enabled"]                "false"
    $script:HumanReviewPhases = @()
    if ($script:HumanReviewEnabled -eq "true") {
        # Parse human_review.phases array from config
        $phasePattern = $Config.Keys |
            Where-Object { $_ -match '^human_review\.phases\.(\d+)$' } |
            Sort-Object { [int](($_ -split '\.')[-1]) }
        foreach ($key in $phasePattern) {
            $script:HumanReviewPhases += $Config[$key]
        }
        # Fallback if parsing fails
        if ($script:HumanReviewPhases.Count -eq 0) {
            $script:HumanReviewPhases = @("Phase3-1", "Phase4-1", "Phase7")
        }
    }
}
