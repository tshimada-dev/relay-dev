# common.ps1 - Shared functions for relay-dev scripts
# Dot-source this file: . "$PSScriptRoot/../config/common.ps1"

function Read-Config {
    <#
    .SYNOPSIS
        Loads relay-dev config from a two-level YAML file.
    .DESCRIPTION
        Supports section headers (e.g. "cli:") and key-value pairs under them.
        Returns a flat hashtable with keys like "cli.command", "cli.flags", etc.
        Inline comments (# ...) are stripped. Quoted and unquoted values are both supported.
    .PARAMETER Path
        Path to the YAML config file (e.g. "config/settings.yaml").
    #>
    param([string]$Path)

    $config = @{}
    if (-not (Test-Path $Path)) {
        Write-Warning "Config not found: $Path - using defaults"
        return $config
    }

    $normalizeScalar = {
        param([string]$v)
        $trimmed = $v.Trim()
        return ($trimmed -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1')
    }

    $section = ""
    $lines = Get-Content -Path $Path -Encoding UTF8

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        $cleanLine = $line -replace '\s+#.*$', ''  # strip inline comments

        if ($cleanLine -match '^(\w+):\s*$') {
            $section = $Matches[1]
            continue
        }

        if ($cleanLine -match '^\s+(\w+)\s*:\s*(.*?)\s*$') {
            $key = $Matches[1]
            $rawValue = $Matches[2]
            $compositeKey = "${section}.${key}"

            # Block scalar (e.g., options: |)
            if ($rawValue -eq '|') {
                $blockLines = @()
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    $blockLine = $lines[$j]
                    if ($blockLine -match '^\s{4}(.*)$') {
                        $blockLines += $Matches[1]
                        continue
                    }
                    if ($blockLine -match '^\s*$') {
                        $blockLines += ""
                        continue
                    }
                    break
                }
                $config[$compositeKey] = ($blockLines -join "`n")
                $i = $j - 1
                continue
            }

            # Array style (e.g., phases: \n  - Phase3-1 ...)
            if ([string]::IsNullOrWhiteSpace($rawValue)) {
                $items = @()
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $nextLine = $lines[$j]
                    if ($nextLine -match '^\s*#' -or $nextLine -match '^\s*$') {
                        $j++
                        continue
                    }
                    if ($nextLine -match '^\s{4,}-\s*(.*?)\s*$') {
                        $itemRaw = ($Matches[1] -replace '\s+#.*$', '')
                        $items += (& $normalizeScalar $itemRaw)
                        $j++
                        continue
                    }
                    break
                }

                if ($items.Count -gt 0) {
                    for ($k = 0; $k -lt $items.Count; $k++) {
                        $config["${compositeKey}.${k}"] = $items[$k]
                    }
                    $i = $j - 1
                    continue
                }
            }

            $config[$compositeKey] = (& $normalizeScalar $rawValue)
        }
    }
    return $config
}

function Get-DefaultValue {
    <#
    .SYNOPSIS
        Returns $Value if non-empty, otherwise $Default. PowerShell 5.1 compatible.
    #>
    param($Value, $Default)
    if ($Value) { $Value } else { $Default }
}
