function Get-CopilotProviderPath {
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

    $candidates = New-Object System.Collections.Generic.List[string]

    $ghCommand = Get-Command "gh" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ghCommand) {
        $ghPath = if ($ghCommand.Path) { [string]$ghCommand.Path } elseif ($ghCommand.Source) { [string]$ghCommand.Source } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($ghPath)) {
            $candidates.Add((Split-Path -Parent $ghPath)) | Out-Null
        }
    }

    $candidates.Add("C:\Program Files\GitHub CLI") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI")) | Out-Null
    }

    foreach ($candidate in $candidates) {
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

function Get-CopilotProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $spec = Get-GenericCliProviderInvocationSpec -JobSpec $job
    $spec["provider"] = "copilot-cli"
    if (-not $spec["command"]) {
        $spec["command"] = "copilot"
    }

    $spec["prompt_mode"] = "argv"
    $spec["prompt_flag"] = Get-RelayPromptFlag -Arguments ([string]$job["flags"]) -DefaultFlag "-p"
    $spec["environment"] = @{
        PATH = Get-CopilotProviderPath
    }
    return $spec
}