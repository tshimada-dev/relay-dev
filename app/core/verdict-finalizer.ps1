if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}

function Get-VerdictFinalizerArrayItems {
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][string]$FieldName
    )

    $artifactObject = ConvertTo-RelayHashtable -InputObject $Artifact
    if (-not ($artifactObject -is [System.Collections.IDictionary])) {
        return @()
    }
    if (-not $artifactObject.ContainsKey($FieldName) -or $null -eq $artifactObject[$FieldName]) {
        return @()
    }

    $value = $artifactObject[$FieldName]
    if ($value -is [string]) {
        return @([string]$value)
    }

    return @($value)
}

function Get-VerdictFinalizerChecklistStatusCounts {
    param([AllowNull()]$ChecklistEntries)

    $counts = @{
        pass = 0
        warning = 0
        fail = 0
        not_applicable = 0
    }

    foreach ($entryRaw in @($ChecklistEntries)) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        if (-not ($entry -is [System.Collections.IDictionary])) {
            continue
        }

        $status = [string]$entry["status"]
        if ($counts.ContainsKey($status)) {
            $counts[$status] = [int]$counts[$status] + 1
        }
    }

    return $counts
}

function Resolve-Phase6CanonicalVerdict {
    param([Parameter(Mandatory)]$Artifact)

    $artifactObject = ConvertTo-RelayHashtable -InputObject $Artifact
    $testsFailed = 0
    [void][int]::TryParse([string]$artifactObject["tests_failed"], [ref]$testsFailed)

    $verificationCounts = Get-VerdictFinalizerChecklistStatusCounts -ChecklistEntries $artifactObject["verification_checks"]
    if ($testsFailed -gt 0 -or [int]$verificationCounts["fail"] -gt 0) {
        return "reject"
    }

    $openRequirements = @(Get-VerdictFinalizerArrayItems -Artifact $artifactObject -FieldName "open_requirements")
    if ([int]$verificationCounts["warning"] -gt 0 -or $openRequirements.Count -gt 0) {
        return "conditional_go"
    }

    return "go"
}

function Finalize-Phase6MaterializedArtifact {
    param([Parameter(Mandatory)]$MaterializedArtifact)

    $artifact = ConvertTo-RelayHashtable -InputObject $MaterializedArtifact
    $content = ConvertTo-RelayHashtable -InputObject $artifact["content"]
    if (-not ($content -is [System.Collections.IDictionary])) {
        return [ordered]@{
            artifact = $artifact
            changed = $false
            warnings = @()
            errors = @()
        }
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $changed = $false

    $incomingVerdict = if ($content.ContainsKey("verdict")) { [string]$content["verdict"] } else { "" }
    $canonicalVerdict = Resolve-Phase6CanonicalVerdict -Artifact $content
    if ($incomingVerdict -ne $canonicalVerdict) {
        $fromValue = if ([string]::IsNullOrWhiteSpace($incomingVerdict)) { "<missing>" } else { $incomingVerdict }
        $warnings.Add("Phase6 canonical verdict finalized from '$fromValue' to '$canonicalVerdict'.") | Out-Null
    }

    if (-not $content.ContainsKey("verdict") -or [string]$content["verdict"] -ne $canonicalVerdict) {
        $content["verdict"] = $canonicalVerdict
        $changed = $true
    }

    $existingRollbackPhase = if ($content.ContainsKey("rollback_phase")) { [string]$content["rollback_phase"] } else { "" }
    if ($canonicalVerdict -ne "reject") {
        if (-not [string]::IsNullOrWhiteSpace($existingRollbackPhase) -or -not $content.ContainsKey("rollback_phase")) {
            $content["rollback_phase"] = ""
            $changed = $true
        }
    }
    elseif (-not $content.ContainsKey("rollback_phase")) {
        $content["rollback_phase"] = ""
        $changed = $true
    }

    $conditionalGoReasons = @(Get-VerdictFinalizerArrayItems -Artifact $content -FieldName "conditional_go_reasons")
    if ($canonicalVerdict -ne "conditional_go") {
        if ($conditionalGoReasons.Count -gt 0 -or -not $content.ContainsKey("conditional_go_reasons")) {
            $content["conditional_go_reasons"] = @()
            $changed = $true
        }
    }
    elseif (-not $content.ContainsKey("conditional_go_reasons")) {
        $content["conditional_go_reasons"] = @()
        $changed = $true
    }

    $artifact["content"] = $content
    return [ordered]@{
        artifact = $artifact
        changed = $changed
        warnings = @($warnings.ToArray())
        errors = @()
    }
}

function Finalize-PhaseMaterializedArtifacts {
    param(
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$MaterializedArtifacts,
        [string]$TaskId
    )

    $finalizedArtifacts = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $changed = $false

    foreach ($artifactRaw in @($MaterializedArtifacts)) {
        $artifact = ConvertTo-RelayHashtable -InputObject $artifactRaw
        $result = switch ($PhaseName) {
            "Phase6" {
                if ([string]$artifact["artifact_id"] -eq "phase6_result.json") {
                    Finalize-Phase6MaterializedArtifact -MaterializedArtifact $artifact
                }
                else {
                    [ordered]@{
                        artifact = $artifact
                        changed = $false
                        warnings = @()
                        errors = @()
                    }
                }
            }
            default {
                [ordered]@{
                    artifact = $artifact
                    changed = $false
                    warnings = @()
                    errors = @()
                }
            }
        }

        $finalizedArtifacts.Add($result["artifact"]) | Out-Null
        foreach ($warning in @($result["warnings"])) {
            $warnings.Add([string]$warning) | Out-Null
        }
        foreach ($error in @($result["errors"])) {
            $errors.Add([string]$error) | Out-Null
        }
        if ([bool]$result["changed"]) {
            $changed = $true
        }
    }

    return [ordered]@{
        phase = $PhaseName
        task_id = $TaskId
        changed = $changed
        materialized = @($finalizedArtifacts.ToArray())
        warnings = @($warnings.ToArray())
        errors = @($errors.ToArray())
    }
}
