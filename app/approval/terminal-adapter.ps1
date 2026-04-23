function New-ManualApprovalOpenRequirement {
    param(
        [Parameter(Mandatory)]$ApprovalRequest,
        [Parameter(Mandatory)][string]$Description
    )

    $request = ConvertTo-RelayHashtable -InputObject $ApprovalRequest
    $verifyPhase = [string]$request["requested_phase"]
    if ($request["proposed_action"]) {
        $proposedAction = ConvertTo-RelayHashtable -InputObject $request["proposed_action"]
        if ($proposedAction["phase"]) {
            $verifyPhase = [string]$proposedAction["phase"]
        }
    }

    $itemId = "manual-{0}" -f (([string]$request["approval_id"]).Replace("approval-", ""))
    if ([string]::IsNullOrWhiteSpace($itemId) -or $itemId -eq "manual-") {
        $itemId = "manual-{0}" -f (Get-Date -Format "yyyyMMddHHmmss")
    }

    return @{
        item_id = $itemId
        description = $Description
        source_phase = [string]$request["requested_phase"]
        source_task_id = [string]$request["requested_task_id"]
        verify_in_phase = $verifyPhase
        required_artifacts = @()
    }
}

function Get-ApprovalActionSummary {
    param([AllowNull()]$Action)

    $actionObject = ConvertTo-RelayHashtable -InputObject $Action
    if (-not $actionObject) {
        return "no action"
    }

    $actionType = [string]$actionObject["type"]
    switch ($actionType) {
        "DispatchJob" {
            $phase = [string]$actionObject["phase"]
            $role = [string]$actionObject["role"]
            $taskId = [string]$actionObject["task_id"]
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                return "DispatchJob -> $phase [$role] task=$taskId"
            }

            return "DispatchJob -> $phase [$role]"
        }
        "Wait" {
            $reason = [string]$actionObject["reason"]
            if (-not [string]::IsNullOrWhiteSpace($reason)) {
                return "Wait ($reason)"
            }

            return "Wait"
        }
        "CompleteRun" { return "CompleteRun" }
        "FailRun" { return "FailRun" }
        default {
            if (-not [string]::IsNullOrWhiteSpace($actionType)) {
                return $actionType
            }

            return "unknown"
        }
    }
}

function Read-ApprovalDecisionFromTerminal {
    param([Parameter(Mandatory)]$ApprovalRequest)

    $request = ConvertTo-RelayHashtable -InputObject $ApprovalRequest
    if ([string]$request["approval_mode"] -eq "clarification_questions") {
        $promptMessage = [string]$request["prompt_message"]
        $blockingItems = @($request["blocking_items"])

        Write-Host ""
        Write-Host "Phase2 clarification required" -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($promptMessage)) {
            Write-Host $promptMessage -ForegroundColor DarkYellow
        }
        if ($blockingItems.Count -gt 0) {
            Write-Host "Questions:" -ForegroundColor White
            foreach ($item in $blockingItems) {
                Write-Host ("- {0}" -f [string]$item) -ForegroundColor White
            }
        }
        Write-Host "[y] answered and continue  [q] abort" -ForegroundColor White

        while ($true) {
            $inputValue = (Read-Host "Decision [y/q]").Trim().ToLowerInvariant()
            switch ($inputValue) {
                "y" { return @{ decision = "approve"; comment = "clarification_answers_provided" } }
                "q" { return @{ decision = "abort"; comment = "" } }
                default { Write-Host "y か q を入力してください。" -ForegroundColor Red }
            }
        }
    }

    $approveActionSummary = Get-ApprovalActionSummary -Action $request["proposed_action"]
    $allowedRejectTargets = @(Resolve-ApprovalRejectTargetPhases -ApprovalRequest $request)
    $rejectTargetPhase = Resolve-DefaultApprovalRejectTargetPhase -ApprovalRequest $request
    $promptMessage = [string]$request["prompt_message"]
    $blockingItems = @($request["blocking_items"])

    Write-Host ""
    Write-Host "Approval required for $($request['requested_phase']) [$($request['requested_role'])]" -ForegroundColor Yellow
    Write-Host "Approve/Skip result: $approveActionSummary" -ForegroundColor DarkYellow
    if (-not [string]::IsNullOrWhiteSpace($promptMessage)) {
        Write-Host $promptMessage -ForegroundColor DarkYellow
    }
    if ($blockingItems.Count -gt 0) {
        Write-Host "Must-fix / blocking items:" -ForegroundColor White
        foreach ($item in $blockingItems) {
            Write-Host ("- {0}" -f [string]$item) -ForegroundColor White
        }
    }
    if ($allowedRejectTargets.Count -gt 0) {
        Write-Host "Reject targets: $($allowedRejectTargets -join ', ')" -ForegroundColor DarkYellow
        Write-Host "Reject default target: $rejectTargetPhase" -ForegroundColor DarkYellow
    }
    Write-Host "[y] approve  [c] conditional approve  [n] reject  [s] skip  [q] abort" -ForegroundColor White

    while ($true) {
        $inputValue = (Read-Host "Decision [y/c/n/s/q]").Trim().ToLowerInvariant()
        switch ($inputValue) {
            "y" { return @{ decision = "approve"; comment = "" } }
            "c" {
                $comment = Read-Host "Comment"
                return @{
                    decision = "conditional_approve"
                    comment = $comment
                    must_fix = @((New-ManualApprovalOpenRequirement -ApprovalRequest $request -Description $comment))
                }
            }
            "n" {
                $comment = Read-Host "Comment"
                $selectedTargetPhase = $rejectTargetPhase
                if ($allowedRejectTargets.Count -gt 1) {
                    while ($true) {
                        $targetInput = (Read-Host "Reject target phase [$($allowedRejectTargets -join '/')] (default: $rejectTargetPhase)").Trim()
                        if ([string]::IsNullOrWhiteSpace($targetInput)) {
                            break
                        }

                        if ($targetInput -in $allowedRejectTargets) {
                            $selectedTargetPhase = $targetInput
                            break
                        }

                        Write-Host "Reject target must be one of: $($allowedRejectTargets -join ', ')." -ForegroundColor Red
                    }
                }
                return @{
                    decision = "reject"
                    comment = $comment
                    target_phase = $selectedTargetPhase
                    target_task_id = $request["requested_task_id"]
                }
            }
            "s" { return @{ decision = "skip"; comment = "" } }
            "q" { return @{ decision = "abort"; comment = "" } }
            default { Write-Host "y/c/n/s/q のいずれかを入力してください。" -ForegroundColor Red }
        }
    }
}
