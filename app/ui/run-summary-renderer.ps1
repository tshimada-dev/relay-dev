function New-RunSummaryText {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$Events
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $eventCount = @($Events).Count
    return "Run $($state['run_id']) is $($state['status']) at $($state['current_phase']) with $eventCount events."
}

