function Get-RelayProviderName {
    param([Parameter(Mandatory)]$JobSpec)

    $spec = ConvertTo-RelayHashtable -InputObject $JobSpec
    $provider = [string]$spec["provider"]
    if ($provider) {
        return $provider.ToLowerInvariant()
    }

    $command = [string]$spec["command"]
    if ($command) {
        return $command.ToLowerInvariant()
    }

    return "generic-cli"
}

function Get-ProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $provider = Get-RelayProviderName -JobSpec $JobSpec

    switch -Regex ($provider) {
        '^(fake|fake-provider)$' { return (Get-FakeProviderInvocationSpec -JobSpec $JobSpec) }
        '^(codex|codex-cli)$' { return (Get-CodexProviderInvocationSpec -JobSpec $JobSpec) }
        '^(gemini|gemini-cli)$' { return (Get-GeminiProviderInvocationSpec -JobSpec $JobSpec) }
        '^(claude|claude-code|claudecode)$' { return (Get-ClaudeProviderInvocationSpec -JobSpec $JobSpec) }
        '^(copilot|copilot-cli)$' { return (Get-CopilotProviderInvocationSpec -JobSpec $JobSpec) }
        default { return (Get-GenericCliProviderInvocationSpec -JobSpec $JobSpec) }
    }
}
