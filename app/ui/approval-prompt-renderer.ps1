function New-ApprovalPromptText {
    param([Parameter(Mandatory)]$ApprovalRequest)

    $request = ConvertTo-RelayHashtable -InputObject $ApprovalRequest
    return "Approval required: phase=$($request['requested_phase']) role=$($request['requested_role'])"
}

