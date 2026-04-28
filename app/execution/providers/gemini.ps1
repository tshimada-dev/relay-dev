function Get-GeminiProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $spec = Get-GenericCliProviderInvocationSpec -JobSpec $JobSpec
    $spec["provider"] = "gemini-cli"
    if (-not $spec["command"]) {
        $spec["command"] = "gemini"
    }
    $spec["environment"] = @{
        GEMINI_CLI_TRUST_WORKSPACE = "true"
    }
    return $spec
}

