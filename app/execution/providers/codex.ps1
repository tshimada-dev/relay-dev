function Get-CodexProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $spec = Get-GenericCliProviderInvocationSpec -JobSpec $JobSpec
    $spec["provider"] = "codex-cli"
    if (-not $spec["command"]) {
        $spec["command"] = "codex"
    }
    return $spec
}

