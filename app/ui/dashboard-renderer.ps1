if (-not (Get-Command New-TaskLaneSummary -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "task-lane-summary.ps1")
}

function New-RunDashboardSummary {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $lane = New-TaskLaneSummary -RunState $state
    $approvalLine = "- Pending Approval: none"
    if ($lane["pending_approval"]) {
        $approval = ConvertTo-RelayHashtable -InputObject $lane["pending_approval"]
        $approvalLine = "- Pending Approval: $($approval['approval_id']) $($approval['requested_phase']) task=$($approval['task_id'])"
    }

    return @"
# Run Dashboard

- Run ID: $($state["run_id"])
- Status: $($state["status"])
- Phase: $($state["current_phase"])
- Role: $($state["current_role"])
- Updated: $($state["updated_at"])
- Task Lane: $($lane["mode"]) slots $($lane["used_slots"])/$($lane["max_parallel_jobs"]) stop_leasing=$($lane["stop_leasing"])
- Tasks: total=$($lane["total_tasks"]) ready=$($lane["ready_count"]) running=$($lane["running_count"]) blocked=$($lane["blocked_count"]) completed=$($lane["completed_count"]) repair=$($lane["repair_count"])
- Active Jobs: $(@($lane["active_jobs"]).Count)
- Waiting Tasks: $(@($lane["waiting_tasks"]).Count)
$approvalLine
"@
}

