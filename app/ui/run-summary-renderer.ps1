if (-not (Get-Command New-TaskLaneSummary -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "task-lane-summary.ps1")
}

function New-RunSummaryText {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$Events
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $lane = New-TaskLaneSummary -RunState $state -Events $Events
    $approvalSuffix = ""
    if ($lane["pending_approval"]) {
        $approvalSuffix = " Approval pending."
    }

    $stallSuffix = if ($lane["stall_reason"]) { " Stall: $($lane['stall_reason'])." } else { "" }
    $groupSuffix = ""
    if ([int]$lane["active_task_group_count"] -gt 0 -or @($lane["task_groups"]).Count -gt 0) {
        $groupSuffix = " Groups: $($lane['active_task_group_count']) active, $($lane['running_task_group_count']) running, $($lane['running_task_group_worker_count']) workers running."
    }
    $dispatchSuffix = if ($lane["dispatch_state"]) { " Dispatch: $($lane['dispatch_state'])." } else { "" }

    return "Run $($state['run_id']) is $($state['status']) at $($state['current_phase']) with $($lane['event_count']) events. Tasks: $($lane['completed_count'])/$($lane['total_tasks']) complete, $($lane['running_count']) running, $($lane['ready_count']) ready, $($lane['blocked_count']) blocked. Lane: $($lane['mode']) $($lane['used_slots'])/$($lane['max_parallel_jobs']) slots, capacity remaining $($lane['capacity_remaining']), ready queue $(@($lane['ready_queue']).Count), lease candidates $(@($lane['lease_candidates']).Count).$groupSuffix$dispatchSuffix$stallSuffix$approvalSuffix"
}
