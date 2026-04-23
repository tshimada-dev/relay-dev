function New-RunDashboardSummary {
    param([Parameter(Mandatory)]$RunState)

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    return @"
# Run Dashboard

- Run ID: $($state["run_id"])
- Status: $($state["status"])
- Phase: $($state["current_phase"])
- Role: $($state["current_role"])
- Updated: $($state["updated_at"])
"@
}

