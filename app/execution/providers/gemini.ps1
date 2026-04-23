function Get-GeminiProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $spec = Get-GenericCliProviderInvocationSpec -JobSpec $JobSpec
    $spec["provider"] = "gemini-cli"
    if (-not $spec["command"]) {
        $spec["command"] = "gemini"
    }
    return $spec
}

