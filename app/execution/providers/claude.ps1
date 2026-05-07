function Get-ClaudeProviderPath {
    $entries = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($entry in @($env:PATH -split [System.IO.Path]::PathSeparator)) {
        $trimmed = [string]$entry
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $normalized = $trimmed.Trim()
        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $entries.Add($normalized) | Out-Null
    }

    $candidateDirs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidateDirs.Add((Join-Path $env:USERPROFILE ".local\bin")) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidateDirs.Add((Join-Path $env:LOCALAPPDATA "AnthropicClaudeCode\bin")) | Out-Null
    }

    foreach ($candidate in $candidateDirs) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path $candidate)) {
            continue
        }

        $normalized = $candidate.Trim()
        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $entries.Add($normalized) | Out-Null
    }

    return ($entries -join [System.IO.Path]::PathSeparator)
}

function Get-ClaudeProviderCommand {
    $commandInfo = Get-Command "claude" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($commandInfo) {
        if ($commandInfo.Path) {
            return [string]$commandInfo.Path
        }

        if ($commandInfo.Source) {
            return [string]$commandInfo.Source
        }
    }

    $candidatePaths = @()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidatePaths += (Join-Path $env:USERPROFILE ".local\bin\claude.exe")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidatePaths += (Join-Path $env:LOCALAPPDATA "AnthropicClaudeCode\bin\claude.exe")
    }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    return "claude"
}

function Get-ClaudeProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $spec = Get-GenericCliProviderInvocationSpec -JobSpec $job
    $spec["provider"] = "claude-code"
    $spec["command"] = Get-ClaudeProviderCommand
    $spec["prompt_mode"] = "stdin"
    $spec["prompt_flag"] = Get-RelayPromptFlag -Arguments ([string]$job["flags"]) -DefaultFlag "-p"

    $spec["environment"] = @{
        PATH = Get-ClaudeProviderPath
    }
    return $spec
}
