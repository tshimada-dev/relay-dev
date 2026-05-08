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

    return "Run $($state['run_id']) is $($state['status']) at $($state['current_phase']) with $($lane['event_count']) events. Tasks: $($lane['completed_count'])/$($lane['total_tasks']) complete, $($lane['running_count']) running, $($lane['ready_count']) ready, $($lane['blocked_count']) blocked. Lane: $($lane['mode']) $($lane['used_slots'])/$($lane['max_parallel_jobs']) slots.$approvalSuffix"
}

