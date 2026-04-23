if (-not (Get-Command Get-PhaseDefinition -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "..\phases\phase-registry.ps1")
}

function Resolve-Transition {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$CurrentPhase,
        [Parameter(Mandatory)][string]$Verdict,
        [string]$RollbackPhase
    )

    $phaseDefinition = Get-PhaseDefinition -ProjectRoot $ProjectRoot -Phase $CurrentPhase
    $transitionRules = if ($phaseDefinition["transition_rules"]) { $phaseDefinition["transition_rules"] } else { @{} }

    switch ($Verdict) {
        "go" {
            $nextPhase = [string]$transitionRules["go"]
            if ([string]::IsNullOrWhiteSpace($nextPhase)) {
                return [ordered]@{
                    valid = $false
                    error = "Phase '$CurrentPhase' does not define a go transition."
                }
            }

            return [ordered]@{
                valid = $true
                verdict = $Verdict
                next_phase = $nextPhase
            }
        }
        "conditional_go" {
            $nextPhase = [string]$transitionRules["conditional_go"]
            if ([string]::IsNullOrWhiteSpace($nextPhase)) {
                return [ordered]@{
                    valid = $false
                    error = "Phase '$CurrentPhase' does not define a conditional_go transition."
                }
            }

            return [ordered]@{
                valid = $true
                verdict = $Verdict
                next_phase = $nextPhase
            }
        }
        "reject" {
            $rejectRule = $transitionRules["reject"]
            if ($null -eq $rejectRule) {
                return [ordered]@{
                    valid = $false
                    error = "Phase '$CurrentPhase' does not define a reject transition."
                }
            }

            if ([string]::IsNullOrWhiteSpace($RollbackPhase)) {
                return [ordered]@{
                    valid = $false
                    error = "reject transition requires rollback_phase."
                }
            }

            $allowedTargets = if ($rejectRule -is [System.Collections.IEnumerable] -and -not ($rejectRule -is [string])) {
                @($rejectRule)
            }
            else {
                @([string]$rejectRule)
            }

            if ($RollbackPhase -notin $allowedTargets) {
                return [ordered]@{
                    valid = $false
                    error = "rollback_phase '$RollbackPhase' is not allowed for phase '$CurrentPhase'. Allowed: $($allowedTargets -join ', ')."
                }
            }

            return [ordered]@{
                valid = $true
                verdict = $Verdict
                next_phase = $RollbackPhase
            }
        }
        default {
            return [ordered]@{
                valid = $false
                error = "Unsupported verdict '$Verdict'."
            }
        }
    }
}
