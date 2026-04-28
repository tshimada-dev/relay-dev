if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    $runStateStorePath = Join-Path $PSScriptRoot "..\core\run-state-store.ps1"
    if (Test-Path $runStateStorePath) {
        . $runStateStorePath
    }
}

foreach ($phaseModulePath in @(
    (Join-Path $PSScriptRoot "phase-common.ps1"),
    (Join-Path $PSScriptRoot "phase0.ps1"),
    (Join-Path $PSScriptRoot "phase1.ps1"),
    (Join-Path $PSScriptRoot "phase2.ps1"),
    (Join-Path $PSScriptRoot "phase3.ps1"),
    (Join-Path $PSScriptRoot "phase3-1.ps1"),
    (Join-Path $PSScriptRoot "phase4.ps1"),
    (Join-Path $PSScriptRoot "phase4-1.ps1"),
    (Join-Path $PSScriptRoot "phase5.ps1"),
    (Join-Path $PSScriptRoot "phase5-1.ps1"),
    (Join-Path $PSScriptRoot "phase5-2.ps1"),
    (Join-Path $PSScriptRoot "phase6.ps1"),
    (Join-Path $PSScriptRoot "phase7.ps1"),
    (Join-Path $PSScriptRoot "phase7-1.ps1"),
    (Join-Path $PSScriptRoot "phase8.ps1")
)) {
    if (Test-Path $phaseModulePath) {
        . $phaseModulePath
    }
}

function Resolve-PhaseRole {
    param([Parameter(Mandatory)][string]$Phase)

    switch ($Phase) {
        "Phase0" { return "implementer" }
        "Phase3-1" { return "reviewer" }
        "Phase4-1" { return "reviewer" }
        "Phase5-1" { return "reviewer" }
        "Phase5-2" { return "reviewer" }
        "Phase6" { return "reviewer" }
        "Phase7" { return "reviewer" }
        default { return "implementer" }
    }
}

function Get-DefaultTransitionRules {
    param([Parameter(Mandatory)][string]$Phase)

    switch ($Phase) {
        "Phase0" { return @{ go = "Phase1" } }
        "Phase1" { return @{ go = "Phase3" } }
        "Phase2" { return @{ go = "Phase3"; reject = @("Phase1") } }
        "Phase3" { return @{ go = "Phase3-1" } }
        "Phase3-1" { return @{ go = "Phase4"; conditional_go = "Phase3"; reject = @("Phase1", "Phase3") } }
        "Phase4" { return @{ go = "Phase4-1" } }
        "Phase4-1" { return @{ go = "Phase5"; conditional_go = "Phase4"; reject = @("Phase3", "Phase4") } }
        "Phase5" { return @{ go = "Phase5-1" } }
        "Phase5-1" { return @{ go = "Phase5-2"; reject = @("Phase5") } }
        "Phase5-2" { return @{ go = "Phase6"; conditional_go = "Phase6"; reject = @("Phase5") } }
        "Phase6" { return @{ go = "Phase7"; conditional_go = "Phase5"; reject = @("Phase3", "Phase4", "Phase5") } }
        "Phase7-1" { return @{ go = "Phase8" } }
        "Phase8" { return @{} }
        default { return @{} }
    }
}

function Resolve-PromptPackage {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Role,
        [string]$Provider = "generic-cli"
    )

    $systemFile = Join-Path $ProjectRoot "app\prompts\system\$Role.md"
    if (-not (Test-Path $systemFile)) {
        $systemFile = Join-Path $ProjectRoot "app\prompts\system\implementer.md"
    }

    $phaseFile = Join-Path $ProjectRoot "app\prompts\phases\$($Phase.ToLowerInvariant()).md"
    if (-not (Test-Path $phaseFile)) {
        $phaseFile = Join-Path $ProjectRoot "app\prompts\phases\default.md"
    }

    $providerKey = switch -Regex ($Provider.ToLowerInvariant()) {
        'codex' { "codex-cli.md" }
        'gemini' { "gemini-cli.md" }
        'claude' { "claude-code.md" }
        'copilot' { "copilot-cli.md" }
        default { "default.md" }
    }
    $providerFile = Join-Path $ProjectRoot "app\prompts\providers\$providerKey"

    return [ordered]@{
        system_prompt_ref = $systemFile
        phase_prompt_ref = $phaseFile
        provider_hints_ref = $providerFile
    }
}

function Get-ConfiguredTaskFilePath {
    $taskFileVar = Get-Variable -Name TaskFile -Scope Script -ErrorAction SilentlyContinue
    if ($taskFileVar -and -not [string]::IsNullOrWhiteSpace([string]$taskFileVar.Value)) {
        return [string]$taskFileVar.Value
    }

    return "tasks/task.md"
}

function Get-ConfiguredDesignFilePath {
    $designFileVar = Get-Variable -Name DesignFile -Scope Script -ErrorAction SilentlyContinue
    if ($designFileVar -and -not [string]::IsNullOrWhiteSpace([string]$designFileVar.Value)) {
        return [string]$designFileVar.Value
    }

    $projectDirVar = Get-Variable -Name ProjectDir -Scope Script -ErrorAction SilentlyContinue
    if ($projectDirVar -and -not [string]::IsNullOrWhiteSpace([string]$projectDirVar.Value)) {
        return (Join-Path ([string]$projectDirVar.Value) "DESIGN.md")
    }

    return "DESIGN.md"
}

function Get-SharedInputContract {
    param([Parameter(Mandatory)][string]$Phase)

    $contracts = New-Object System.Collections.Generic.List[object]
    $contracts.Add([ordered]@{
        artifact_id = "task.md"
        scope = "external"
        path = Get-ConfiguredTaskFilePath
        format = "markdown"
        required = $true
    })
    $contracts.Add([ordered]@{
        artifact_id = "DESIGN.md"
        scope = "external"
        path = Get-ConfiguredDesignFilePath
        format = "markdown"
        required = $false
    })

    if ($Phase -ne "Phase0") {
        $contracts.Add([ordered]@{
            artifact_id = "phase0_context.md"
            scope = "run"
            phase = "Phase0"
            format = "markdown"
            required = $true
        })
        $contracts.Add([ordered]@{
            artifact_id = "phase0_context.json"
            scope = "run"
            phase = "Phase0"
            format = "json"
            required = $true
        })
    }

    foreach ($feedbackContract in @(Get-ReviewFeedbackInputContract -Phase $Phase)) {
        $contracts.Add($feedbackContract)
    }

    return @($contracts.ToArray())
}

function Get-ReviewFeedbackInputContract {
    param([Parameter(Mandatory)][string]$Phase)

    $contracts = New-Object System.Collections.Generic.List[object]
    $feedbackMap = switch ($Phase) {
        "Phase1" {
            @(
                @{ artifact_id = "phase3-1_verdict.json"; scope = "run"; phase = "Phase3-1"; format = "json"; required = $false },
                @{ artifact_id = "phase7_verdict.json"; scope = "run"; phase = "Phase7"; format = "json"; required = $false }
            )
        }
        "Phase3" {
            @(
                @{ artifact_id = "phase3-1_verdict.json"; scope = "run"; phase = "Phase3-1"; format = "json"; required = $false },
                @{ artifact_id = "phase4-1_verdict.json"; scope = "run"; phase = "Phase4-1"; format = "json"; required = $false },
                @{ artifact_id = "phase7_verdict.json"; scope = "run"; phase = "Phase7"; format = "json"; required = $false }
            )
        }
        "Phase4" {
            @(
                @{ artifact_id = "phase4-1_verdict.json"; scope = "run"; phase = "Phase4-1"; format = "json"; required = $false },
                @{ artifact_id = "phase7_verdict.json"; scope = "run"; phase = "Phase7"; format = "json"; required = $false }
            )
        }
        "Phase5" {
            @(
                @{ artifact_id = "phase5-1_verdict.json"; scope = "task"; phase = "Phase5-1"; format = "json"; required = $false },
                @{ artifact_id = "phase5-2_verdict.json"; scope = "task"; phase = "Phase5-2"; format = "json"; required = $false },
                @{ artifact_id = "phase6_result.json"; scope = "task"; phase = "Phase6"; format = "json"; required = $false },
                @{ artifact_id = "phase7_verdict.json"; scope = "run"; phase = "Phase7"; format = "json"; required = $false }
            )
        }
        default {
            @()
        }
    }

    foreach ($contract in @($feedbackMap)) {
        $contracts.Add([ordered]@{
            artifact_id = $contract["artifact_id"]
            scope = $contract["scope"]
            phase = $contract["phase"]
            format = "json"
            required = $false
        })
    }

    return @($contracts.ToArray())
}

function Merge-PhaseInputContract {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()]$InputContract
    )

    $items = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($contractItem in @((Get-SharedInputContract -Phase $Phase)) + @($InputContract)) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        if (-not ($item -is [System.Collections.IDictionary])) {
            continue
        }

        $scope = if ($item["scope"]) { [string]$item["scope"] } else { "run" }
        $artifactId = [string]$item["artifact_id"]
        $key = if ($scope -eq "external") {
            $path = if ($item["path"]) { [string]$item["path"] } else { $artifactId }
            "external|$path|$artifactId"
        }
        else {
            $sourcePhase = if ($item["phase"]) { [string]$item["phase"] } else { $Phase }
            "$scope|$sourcePhase|$artifactId"
        }

        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $items.Add($item)
    }

    return @($items.ToArray())
}

function Get-PhaseDefinition {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Phase,
        [string]$Provider = "generic-cli"
    )

    $definition = switch ($Phase) {
        "Phase0" { Get-Phase0Definition }
        "Phase1" { Get-Phase1Definition }
        "Phase2" { Get-Phase2Definition }
        "Phase3" { Get-Phase3Definition }
        "Phase3-1" { Get-Phase31Definition }
        "Phase4" { Get-Phase4Definition }
        "Phase4-1" { Get-Phase41Definition }
        "Phase5" { Get-Phase5Definition }
        "Phase5-1" { Get-Phase51Definition }
        "Phase5-2" { Get-Phase52Definition }
        "Phase6" { Get-Phase6Definition }
        "Phase7" { Get-Phase7Definition }
        "Phase7-1" { Get-Phase71Definition }
        "Phase8" { Get-Phase8Definition }
        default { $null }
    }

    $role = if ($definition -and $definition["role"]) {
        [string]$definition["role"]
    }
    else {
        Resolve-PhaseRole -Phase $Phase
    }

    if (-not $definition) {
        $definition = [ordered]@{
            phase = $Phase
            role = $role
            input_contract = @()
            output_contract = @()
            validator = $null
            transition_rules = Get-DefaultTransitionRules -Phase $Phase
        }
    }

    $definition["phase"] = $Phase
    $definition["role"] = $role
    $definition["input_contract"] = Merge-PhaseInputContract -Phase $Phase -InputContract $definition["input_contract"]
    $definition["prompt_package"] = Resolve-PromptPackage -ProjectRoot $ProjectRoot -Phase $Phase -Role $role -Provider $Provider

    return $definition
}
