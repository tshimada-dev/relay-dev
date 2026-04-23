# lib/phase-validator.ps1 - Phase transition validation
# Requires: Write-Log (from lib/logging.ps1)

# Valid phase transitions map
$script:ValidTransitions = @{
    "Phase1"   = @("Phase2")
    "Phase2"   = @("Phase3", "Phase1")  # Loop back to Phase1 allowed
    "Phase3"   = @("Phase3-1")
    "Phase3-1" = @("Phase4", "Phase3")  # Reject returns to Phase3
    "Phase4"   = @("Phase4-1")
    "Phase4-1" = @("Phase5", "Phase4")  # Reject returns to Phase4
    "Phase5"   = @("Phase5-1")
    "Phase5-1" = @("Phase5-2", "Phase5")  # Reject returns to Phase5
    "Phase5-2" = @("Phase6", "Phase5")  # Reject returns to Phase5
    "Phase6"   = @("Phase7", "Phase5")  # Can loop back to Phase5 for next task
    "Phase7"   = @("Phase7-1", "Phase1", "Phase3", "Phase4", "Phase5", "Phase6")  # Can reject to multiple phases
    "Phase7-1" = @("Phase8")
    "Phase8"   = @()  # Terminal phase
}

function Test-PhaseTransitionValidity {
    param(
        [string]$FromPhase,
        [string]$ToPhase
    )
    
    # Allow null/empty transitions (initialization)
    if (-not $FromPhase -or $FromPhase -eq '""') {
        return @{ IsValid = $true }
    }
    
    # Check if FromPhase exists in transition map
    if (-not $script:ValidTransitions.ContainsKey($FromPhase)) {
        Write-Log "Unknown source phase: $FromPhase" -Level Warning
        return @{ IsValid = $true }  # Unknown phases are allowed (forward compatibility)
    }
    
    # Check if transition is valid
    $allowedTargets = $script:ValidTransitions[$FromPhase]
    if ($ToPhase -notin $allowedTargets) {
        Write-Log "Invalid phase transition detected: $FromPhase -> $ToPhase" -Level Error
        Write-Log "Allowed transitions from ${FromPhase}: $($allowedTargets -join ', ')" -Level Error
        return @{
            IsValid = $false
            Message = "Invalid transition: $FromPhase -> $ToPhase. Allowed: $($allowedTargets -join ', ')"
        }
    }
    
    return @{ IsValid = $true }
}

# ============================================================
# State Transition Validation (P1-1)
# ============================================================
function Test-StateTransition {
    param(
        [string]$CurrentPhase,
        [string]$Feedback,
        [string]$CurrentRole
    )

    $feedbackText = if ($null -eq $Feedback) { "" } else { [string]$Feedback }
    $targetPhase = $null

    # Check if feedback contains an explicit redirect (e.g., "差し戻し先: Phase3").
    $explicitRedirect = [regex]::Match($feedbackText, '差し戻し先\s*:\s*(Phase\d+(?:-\d+)?)')
    if ($explicitRedirect.Success) {
        $targetPhase = $explicitRedirect.Groups[1].Value
        if ($targetPhase -ne $CurrentPhase) {
            Write-Log "Detected phase redirect: Current=$CurrentPhase, Target=$targetPhase" -Level Warning
            return [pscustomobject]@{
                IsValid     = $false
                TargetPhase = $targetPhase
                Message     = "Feedback indicates redirect to $targetPhase but current phase is $CurrentPhase"
            }
        }
    }

    # Check if feedback mentions "Phase X へ差し戻し".
    $implicitRedirect = [regex]::Match($feedbackText, '(Phase\d+(?:-\d+)?)\s*[へに]\s*差し?戻し')
    if ($implicitRedirect.Success) {
        $targetPhase = $implicitRedirect.Groups[1].Value
        if ($targetPhase -ne $CurrentPhase) {
            Write-Log "Detected phase mismatch in feedback: Current=$CurrentPhase, Mentioned=$targetPhase" -Level Warning
            return [pscustomobject]@{
                IsValid     = $false
                TargetPhase = $targetPhase
                Message     = "Feedback mentions $targetPhase but current phase is $CurrentPhase"
            }
        }
    }

    return [pscustomobject]@{
        IsValid     = $true
        TargetPhase = $targetPhase
        Message     = ""
    }
}
