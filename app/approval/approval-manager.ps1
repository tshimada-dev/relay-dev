function New-ApprovalId {
    param(
        [string]$Prefix = "approval",
        [datetime]$Now = (Get-Date)
    )

    return "{0}-{1}" -f $Prefix, $Now.ToString("yyyyMMddHHmmss")
}

function New-ApprovalRequest {
    param(
        [Parameter(Mandatory)][string]$ApprovalId,
        [Parameter(Mandatory)][string]$RequestedPhase,
        [Parameter(Mandatory)][string]$RequestedRole,
        [string]$RequestedTaskId,
        [Parameter(Mandatory)]$ProposedAction,
        [string[]]$AllowedRejectPhases = @(),
        [string]$PromptMessage = "",
        [string[]]$BlockingItems = @(),
        [object[]]$CarryForwardRequirements = @(),
        [string]$ApprovalMode = ""
    )

    return [ordered]@{
        approval_id = $ApprovalId
        requested_phase = $RequestedPhase
        requested_role = $RequestedRole
        requested_task_id = $RequestedTaskId
        proposed_action = (ConvertTo-RelayHashtable -InputObject $ProposedAction)
        allowed_reject_phases = @($AllowedRejectPhases | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        prompt_message = $PromptMessage
        blocking_items = @($BlockingItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        carry_forward_requirements = @($CarryForwardRequirements)
        approval_mode = $ApprovalMode
        requested_at = (Get-Date).ToString("o")
    }
}

function Resolve-ApprovalRejectTargetPhases {
    param([Parameter(Mandatory)]$ApprovalRequest)

    $request = ConvertTo-RelayHashtable -InputObject $ApprovalRequest
    $configuredTargets = @(
        @($request["allowed_reject_phases"]) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($configuredTargets.Count -gt 0) {
        return $configuredTargets
    }

    switch ([string]$request["requested_phase"]) {
        "Phase3-1" { return @("Phase3") }
        "Phase4-1" { return @("Phase4") }
        "Phase7" { return @("Phase5") }
        default {
            $phase = [string]$request["requested_phase"]
            if ([string]::IsNullOrWhiteSpace($phase)) {
                return @()
            }

            return @($phase)
        }
    }
}

function Resolve-DefaultApprovalRejectTargetPhase {
    param([Parameter(Mandatory)]$ApprovalRequest)

    $targets = @(Resolve-ApprovalRejectTargetPhases -ApprovalRequest $ApprovalRequest)
    if ($targets.Count -gt 0) {
        return [string]$targets[0]
    }

    return ""
}

function Normalize-ApprovalDecision {
    param([Parameter(Mandatory)]$Decision)

    $normalized = ConvertTo-RelayHashtable -InputObject $Decision
    if (-not $normalized["decision"]) {
        throw "ApprovalDecision.decision is required"
    }

    $allowed = @("approve", "conditional_approve", "reject", "skip", "abort")
    if ($normalized["decision"] -notin $allowed) {
        throw "Unsupported approval decision: $($normalized['decision'])"
    }

    if ($normalized["decision"] -eq "conditional_approve" -and (-not $normalized["must_fix"] -or @($normalized["must_fix"]).Count -eq 0)) {
        throw "conditional_approve requires must_fix[]"
    }

    return $normalized
}
