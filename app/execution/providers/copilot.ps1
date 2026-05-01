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

function Get-CopilotArchitectureTokens {
    $tokens = New-Object System.Collections.Generic.List[string]

    $architecture = ""
    try {
        $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    }
    catch {
        $architecture = ""
    }

    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = [string]$env:PROCESSOR_ARCHITECTURE
    }

    switch ($architecture.ToLowerInvariant()) {
        "amd64" {
            $tokens.Add("x64") | Out-Null
            $tokens.Add("amd64") | Out-Null
        }
        "x64" {
            $tokens.Add("x64") | Out-Null
            $tokens.Add("amd64") | Out-Null
        }
        "x86" {
            $tokens.Add("x86") | Out-Null
            $tokens.Add("ia32") | Out-Null
        }
        "arm64" {
            $tokens.Add("arm64") | Out-Null
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($architecture)) {
                $tokens.Add($architecture.ToLowerInvariant()) | Out-Null
            }
        }
    }

    return @($tokens.ToArray())
}

function Get-CopilotNativeCommandPath {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $null
    }

    $resolvedPath = $Command
    if (-not (Test-Path $resolvedPath)) {
        $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($commandInfo) {
            if ($commandInfo.Path) {
                $resolvedPath = [string]$commandInfo.Path
            }
            elseif ($commandInfo.Source) {
                $resolvedPath = [string]$commandInfo.Source
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path $resolvedPath)) {
        return $null
    }

    $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
    if ($extension -eq ".exe") {
        return $resolvedPath
    }

    $platformToken = if ($IsWindows) {
        "win32"
    }
    elseif ($IsMacOS) {
        "darwin"
    }
    elseif ($IsLinux) {
        "linux"
    }
    else {
        ""
    }
    if ([string]::IsNullOrWhiteSpace($platformToken)) {
        return $null
    }

    $baseDir = Split-Path -Parent $resolvedPath
    if ([string]::IsNullOrWhiteSpace($baseDir)) {
        return $null
    }

    $packageRoot = Join-Path $baseDir "node_modules\@github\copilot"
    $nativePackageRoot = Join-Path $packageRoot "node_modules\@github"
    if (-not (Test-Path $nativePackageRoot)) {
        return $null
    }

    $nativePackageDirs = @(
        Get-ChildItem -Path $nativePackageRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "copilot-$platformToken-*" }
    )
    if ($nativePackageDirs.Count -eq 0) {
        return $null
    }

    $orderedDirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $seenDirs = @{}
    foreach ($archToken in @(Get-CopilotArchitectureTokens)) {
        foreach ($candidateDir in @($nativePackageDirs | Where-Object { $_.Name -match "(?i)-$([regex]::Escape($archToken))(?:-|$)" })) {
            $candidateKey = $candidateDir.FullName.ToLowerInvariant()
            if ($seenDirs.ContainsKey($candidateKey)) {
                continue
            }

            $seenDirs[$candidateKey] = $true
            $orderedDirs.Add($candidateDir) | Out-Null
        }
    }

    foreach ($candidateDir in $nativePackageDirs) {
        $candidateKey = $candidateDir.FullName.ToLowerInvariant()
        if ($seenDirs.ContainsKey($candidateKey)) {
            continue
        }

        $seenDirs[$candidateKey] = $true
        $orderedDirs.Add($candidateDir) | Out-Null
    }

    $binaryName = if ($IsWindows) { "copilot.exe" } else { "copilot" }
    foreach ($candidateDir in $orderedDirs) {
        $candidatePath = Join-Path $candidateDir.FullName $binaryName
        if (Test-Path $candidatePath) {
            return $candidatePath
        }
    }

    return $null
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
    $nativeCommandPath = Get-CopilotNativeCommandPath -Command ([string]$spec["command"])
    if (-not [string]::IsNullOrWhiteSpace($nativeCommandPath)) {
        $spec["command"] = $nativeCommandPath
    }
    $spec["environment"] = @{
        PATH = Get-CopilotProviderPath
    }
    return $spec
}
