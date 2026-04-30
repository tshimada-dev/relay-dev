if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}

function ConvertTo-RepairGuardArtifactValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            return $Value
        }

        try {
            return (ConvertTo-RelayHashtable -InputObject ($trimmed | ConvertFrom-Json))
        }
        catch {
            return $Value
        }
    }

    return (ConvertTo-RelayHashtable -InputObject $Value)
}

function Get-RepairDiffGuardPolicy {
    param([string]$ArtifactId)

    $reviewerArtifacts = @(
        "phase3-1_verdict.json",
        "phase4-1_verdict.json",
        "phase5-1_verdict.json",
        "phase5-2_verdict.json",
        "phase7_verdict.json"
    )

    $immutablePaths = @()
    if ($ArtifactId -in $reviewerArtifacts) {
        $immutablePaths += @("verdict", "rollback_phase")
    }
    if ($ArtifactId -eq "phase5-2_verdict.json") {
        $immutablePaths += @("security_checks[*].status")
    }

    return [ordered]@{
        artifact_id = $ArtifactId
        immutable_paths = $immutablePaths
    }
}

function Get-RepairGuardPathValue {
    param(
        $Artifact,
        [string]$Path
    )

    $current = ConvertTo-RepairGuardArtifactValue -Value $Artifact
    foreach ($segment in @($Path -split '\.')) {
        if ($null -eq $current) {
            return $null
        }

        if ($segment -match '^(?<name>[^\[]+)\[(?<index>\d+)\]$') {
            if (-not ($current -is [System.Collections.IDictionary])) {
                return $null
            }

            $name = $Matches["name"]
            $index = [int]$Matches["index"]
            if (-not $current.ContainsKey($name)) {
                return $null
            }

            $items = @($current[$name])
            if ($index -ge $items.Count) {
                return $null
            }

            $current = ConvertTo-RepairGuardArtifactValue -Value $items[$index]
            continue
        }

        if (-not ($current -is [System.Collections.IDictionary]) -or -not $current.ContainsKey($segment)) {
            return $null
        }

        $current = ConvertTo-RepairGuardArtifactValue -Value $current[$segment]
    }

    return $current
}

function Get-RepairGuardComparableValue {
    param($Value)

    $normalized = ConvertTo-RepairGuardArtifactValue -Value $Value
    if ($normalized -is [System.Collections.IDictionary] -or ($normalized -is [System.Collections.IEnumerable] -and -not ($normalized -is [string]))) {
        return ($normalized | ConvertTo-Json -Depth 20 -Compress)
    }

    return [string]$normalized
}

function Test-RepairGuardPathChanged {
    param(
        $OriginalArtifact,
        $RepairedArtifact,
        [string]$Path
    )

    $originalComparable = Get-RepairGuardComparableValue -Value (Get-RepairGuardPathValue -Artifact $OriginalArtifact -Path $Path)
    $repairedComparable = Get-RepairGuardComparableValue -Value (Get-RepairGuardPathValue -Artifact $RepairedArtifact -Path $Path)
    return ($originalComparable -ne $repairedComparable)
}

function Get-RepairGuardSecurityStatusViolations {
    param(
        $OriginalArtifact,
        $RepairedArtifact
    )

    $violations = @()
    $originalObject = ConvertTo-RepairGuardArtifactValue -Value $OriginalArtifact
    $repairedObject = ConvertTo-RepairGuardArtifactValue -Value $RepairedArtifact

    $originalChecks = @()
    $repairedChecks = @()
    if ($originalObject -is [System.Collections.IDictionary] -and $originalObject.ContainsKey("security_checks")) {
        $originalChecks = @($originalObject["security_checks"])
    }
    if ($repairedObject -is [System.Collections.IDictionary] -and $repairedObject.ContainsKey("security_checks")) {
        $repairedChecks = @($repairedObject["security_checks"])
    }

    $count = [Math]::Min($originalChecks.Count, $repairedChecks.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if (Test-RepairGuardPathChanged -OriginalArtifact $OriginalArtifact -RepairedArtifact $RepairedArtifact -Path "security_checks[$index].status") {
            $violations += "security_checks[$index].status"
        }
    }

    return $violations
}

function Test-ArtifactRepairDiffGuard {
    param(
        [string]$ArtifactId,
        $OriginalArtifact,
        $RepairedArtifact,
        [string[]]$ImmutablePaths = @()
    )

    $policy = ConvertTo-RelayHashtable -InputObject (Get-RepairDiffGuardPolicy -ArtifactId $ArtifactId)
    $paths = @($ImmutablePaths)
    if ($paths.Count -eq 0) {
        $paths = @($policy["immutable_paths"])
    }

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($path in $paths) {
        if ($path -eq "security_checks[*].status") {
            foreach ($violation in @(Get-RepairGuardSecurityStatusViolations -OriginalArtifact $OriginalArtifact -RepairedArtifact $RepairedArtifact)) {
                $violations.Add($violation)
            }
            continue
        }

        if (Test-RepairGuardPathChanged -OriginalArtifact $OriginalArtifact -RepairedArtifact $RepairedArtifact -Path $path) {
            $violations.Add($path)
        }
    }

    $originalValue = ConvertTo-RepairGuardArtifactValue -Value $OriginalArtifact
    $repairedValue = ConvertTo-RepairGuardArtifactValue -Value $RepairedArtifact

    return [ordered]@{
        allowed = ($violations.Count -eq 0)
        valid = ($violations.Count -eq 0)
        artifact_id = $ArtifactId
        immutable_paths = $paths
        violations = @($violations | Select-Object -Unique)
        errors = @(
            @($violations | Select-Object -Unique) |
                ForEach-Object { "Immutable field changed: $([string]$_)" }
        )
        original = $originalValue
        repaired = $repairedValue
    }
}

function Test-RepairDiffAllowed {
    param(
        [string]$ArtifactId,
        $OriginalArtifact,
        $RepairedArtifact,
        [string[]]$ImmutablePaths = @()
    )

    return (Test-ArtifactRepairDiffGuard -ArtifactId $ArtifactId -OriginalArtifact $OriginalArtifact -RepairedArtifact $RepairedArtifact -ImmutablePaths $ImmutablePaths)
}
