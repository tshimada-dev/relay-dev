function Remove-RelayPromptFlags {
    param([string]$Arguments)

    if (-not $Arguments) {
        return ""
    }

    $normalized = $Arguments -replace '(^|\s)(--prompt|-p)(?=\s|$)', ' '
    return ($normalized -replace '\s+', ' ').Trim()
}

function Get-GenericCliProviderInvocationSpec {
    param([Parameter(Mandatory)]$JobSpec)

    $spec = ConvertTo-RelayHashtable -InputObject $JobSpec
    $command = if ($spec["command"]) { [string]$spec["command"] } elseif ($spec["provider"]) { [string]$spec["provider"] } else { "" }
    if (-not $command) {
        throw "JobSpec must include command or provider"
    }

    return [ordered]@{
        provider = if ($spec["provider"]) { [string]$spec["provider"] } else { "generic-cli" }
        command = $command
        arguments = Remove-RelayPromptFlags -Arguments ([string]$spec["flags"])
    }
}

