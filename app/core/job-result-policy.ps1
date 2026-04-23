function Resolve-EffectiveExecutionResult {
    param(
        [Parameter(Mandatory)]$ExecutionResult,
        $ValidationResult
    )

    $effectiveExecutionResult = ConvertTo-RelayHashtable -InputObject $ExecutionResult
    $effectiveValidation = ConvertTo-RelayHashtable -InputObject $ValidationResult
    $recoveredFromTimeout = $false

    if (
        [string]$effectiveExecutionResult["failure_class"] -eq "timeout" -and
        [string]$effectiveExecutionResult["result_status"] -ne "succeeded" -and
        $effectiveValidation -and
        [bool]$effectiveValidation["valid"]
    ) {
        $effectiveExecutionResult["result_status"] = "succeeded"
        $effectiveExecutionResult["exit_code"] = 0
        $effectiveExecutionResult["failure_class"] = $null
        $effectiveExecutionResult["recovered_from_timeout"] = $true
        $recoveredFromTimeout = $true
    }

    return [ordered]@{
        execution_result = $effectiveExecutionResult
        recovered_from_timeout = $recoveredFromTimeout
    }
}
