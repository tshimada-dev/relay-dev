$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected,
        [string]$Message
    )
    if ($Actual -ne $Expected) {
        Add-Failure "$Message (expected='$Expected', actual='$Actual')"
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )
    if (-not $Text.Contains($Needle)) {
        Add-Failure "$Message (needle='$Needle')"
    }
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )
    if ($Text.Contains($Needle)) {
        Add-Failure "$Message (unexpected='$Needle')"
    }
}

function Get-TestFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant())
    }
    finally {
        $sha256.Dispose()
    }
}

function New-ChecklistEntry {
    param(
        [string]$CheckId,
        [string]$Status = "pass",
        [string]$Prefix = "check",
        [string[]]$Evidence
    )

    $resolvedEvidence = if ($PSBoundParameters.ContainsKey("Evidence")) {
        @($Evidence)
    }
    elseif ($Status -eq "not_applicable") {
        @()
    }
    else {
        @("${Prefix}:$CheckId")
    }

    return [ordered]@{
        check_id = $CheckId
        status = $Status
        notes = "$Prefix $CheckId $Status"
        evidence = [object[]]$resolvedEvidence
    }
}

function Assert-Skipped {
    param([string]$Message)

    Write-Host "  - skipped: $Message" -ForegroundColor DarkYellow
}

function Resolve-OptionalFunction {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command
        }
    }

    return $null
}

function Convert-EntryFieldToScalar {
    param(
        [Parameter(Mandatory)]$Entries,
        [string]$FieldName = "evidence"
    )

    $normalizedEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entryRaw in @($Entries)) {
        $entry = ConvertTo-RelayHashtable -InputObject $entryRaw
        if ($entry -is [System.Collections.IDictionary]) {
            $copy = [ordered]@{}
            foreach ($key in $entry.Keys) {
                $copy[[string]$key] = $entry[$key]
            }

            if ($copy.Keys -contains $FieldName) {
                $fieldValue = $copy[$FieldName]
                if ($null -eq $fieldValue) {
                    $items = @()
                }
                elseif ($fieldValue -is [string]) {
                    $items = @([string]$fieldValue)
                }
                else {
                    $items = @($fieldValue)
                }

                $items = [object[]]@($items)
                $copy[$FieldName] = if ($items.Count -gt 0) { [string]$items[0] } else { "" }
            }

            $normalizedEntries.Add($copy)
        }
        else {
            $normalizedEntries.Add($entryRaw)
        }
    }

    return @($normalizedEntries.ToArray())
}

function New-ChecklistSet {
    param(
        [string[]]$CheckIds,
        [string]$DefaultStatus = "pass",
        [hashtable]$StatusOverrides,
        [string]$Prefix = "check"
    )

    $overrides = if ($null -eq $StatusOverrides) { @{} } else { $StatusOverrides }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($checkId in $CheckIds) {
        $status = if ($overrides.ContainsKey($checkId)) { [string]$overrides[$checkId] } else { $DefaultStatus }
        $items.Add((New-ChecklistEntry -CheckId $checkId -Status $status -Prefix $Prefix))
    }

    return @($items.ToArray())
}

function New-Phase51ReviewChecks {
    param([hashtable]$StatusOverrides)

    return @(New-ChecklistSet -CheckIds @(
        "selected_task_alignment",
        "acceptance_criteria_coverage",
        "changed_files_audit",
        "test_evidence_review",
        "design_boundary_alignment",
        "visual_contract_alignment"
    ) -StatusOverrides $StatusOverrides -Prefix "phase51")
}

function New-Phase31ReviewChecks {
    param([hashtable]$StatusOverrides)

    return @(New-ChecklistSet -CheckIds @(
        "module_boundaries",
        "public_interfaces",
        "dependency_rules",
        "side_effect_boundaries",
        "state_ownership",
        "encapsulation_consistency",
        "visual_contract_readiness"
    ) -StatusOverrides $StatusOverrides -Prefix "phase31")
}

function New-BoundaryContract {
    param(
        [string]$ModuleName = "application/search",
        [string]$PublicInterface = "GET /api/search",
        [string]$AllowedDependency = "application/search -> domain/search",
        [string]$ForbiddenDependency = "application/search -> infra/db direct",
        [string]$SideEffectBoundary = "DB access must stay behind SearchRepository",
        [string]$StateOwner = "SearchQuery state is owned by application/search"
    )

    return [ordered]@{
        module_boundaries = @($ModuleName)
        public_interfaces = @($PublicInterface)
        allowed_dependencies = @($AllowedDependency)
        forbidden_dependencies = @($ForbiddenDependency)
        side_effect_boundaries = @($SideEffectBoundary)
        state_ownership = @($StateOwner)
    }
}

function New-VisualContract {
    param(
        [string]$Mode = "design_md",
        [string[]]$DesignSources = @("DESIGN.md"),
        [string[]]$VisualConstraints = @("Maintain the documented color, typography, and spacing system."),
        [string[]]$ComponentPatterns = @("Reuse the documented card and button treatment."),
        [string[]]$ResponsiveExpectations = @("Preserve the documented mobile stacking and spacing behavior."),
        [string[]]$InteractionGuidelines = @("Keep hover, focus, loading, and empty states aligned with the design source.")
    )

    if ($Mode -eq "not_applicable") {
        $DesignSources = @()
        $VisualConstraints = @()
        $ComponentPatterns = @()
        $ResponsiveExpectations = @()
        $InteractionGuidelines = @()
    }

    return [ordered]@{
        mode = $Mode
        design_sources = [object[]]@($DesignSources)
        visual_constraints = [object[]]@($VisualConstraints)
        component_patterns = [object[]]@($ComponentPatterns)
        responsive_expectations = [object[]]@($ResponsiveExpectations)
        interaction_guidelines = [object[]]@($InteractionGuidelines)
    }
}

function New-Phase52SecurityChecks {
    param([hashtable]$StatusOverrides)

    return @(New-ChecklistSet -CheckIds @(
        "input_validation",
        "authentication_authorization",
        "secret_handling_and_logging",
        "dangerous_side_effects",
        "dependency_surface"
    ) -StatusOverrides $StatusOverrides -Prefix "phase52")
}

function New-Phase6VerificationChecks {
    param([hashtable]$StatusOverrides)

    return @(New-ChecklistSet -CheckIds @(
        "lint_static_analysis",
        "automated_tests",
        "regression_scope",
        "error_path_coverage",
        "coverage_assessment"
    ) -StatusOverrides $StatusOverrides -Prefix "phase6")
}

function New-Phase7ReviewChecks {
    param([hashtable]$StatusOverrides)

    return @(New-ChecklistSet -CheckIds @(
        "requirements_alignment",
        "correctness_and_edge_cases",
        "security_and_privacy",
        "test_quality",
        "maintainability",
        "performance_and_operations"
    ) -StatusOverrides $StatusOverrides -Prefix "phase7")
}

function New-Phase51AcceptanceChecks {
    param([string]$Status = "pass")

    return @(
        [ordered]@{
            criterion = "API exists"
            status = $Status
            notes = "Acceptance criterion is $Status."
            evidence = [object[]]@("phase5_result.json")
        }
    )
}

function New-Phase7HumanReview {
    param([string]$Recommendation = "recommended")

    $reasons = if ($Recommendation -eq "not_needed") { @() } else { @("Human spot review is recommended for final sign-off.") }
    $focusPoints = if ($Recommendation -eq "not_needed") { @() } else { @("Critical issue handling") }

    return [ordered]@{
        recommendation = $Recommendation
        reasons = [object[]]$reasons
        focus_points = [object[]]$focusPoints
    }
}

function New-OpenRequirement {
    param(
        [string]$ItemId = "REQ-01",
        [string]$Description = "Follow-up verification is required.",
        [string]$SourcePhase = "Phase6",
        [string]$SourceTaskId = "T-01",
        [string]$VerifyInPhase = "Phase7",
        [string[]]$RequiredArtifacts = @("phase7_verdict.json")
    )

    return [ordered]@{
        item_id = $ItemId
        description = $Description
        source_phase = $SourcePhase
        source_task_id = $SourceTaskId
        verify_in_phase = $VerifyInPhase
        required_artifacts = [object[]]@($RequiredArtifacts)
    }
}

function New-Phase52OpenRequirements {
    param([string]$TaskId = "T-01")

    return @(
        (New-OpenRequirement -ItemId "SEC-01" -Description "Review dependency surface after downstream integration." -SourcePhase "Phase5-2" -SourceTaskId $TaskId -VerifyInPhase "Phase7" -RequiredArtifacts @("phase7_verdict.json"))
    )
}

function New-Phase6OpenRequirements {
    param([string]$TaskId = "T-01")

    return @(
        (New-OpenRequirement -ItemId "TEST-01" -Description "Coverage warning must be reviewed before merge." -SourcePhase "Phase6" -SourceTaskId $TaskId -VerifyInPhase "Phase7" -RequiredArtifacts @("phase7_verdict.json"))
    )
}

function New-MaterializedArtifact {
    param(
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)]$Content,
        [string]$Scope = "task",
        [string]$TaskId = "T-01",
        [string]$Path = "synthetic.json",
        [bool]$AsJson = $true
    )

    return [ordered]@{
        artifact_id = $ArtifactId
        scope = $Scope
        phase = $Phase
        task_id = $TaskId
        path = $Path
        content = $Content
        as_json = $AsJson
    }
}

Write-Host "[1/11] Testing config parser..."
. (Join-Path $repoRoot "config/common.ps1")

$tempConfig = [System.IO.Path]::GetTempFileName()
try {
    @'
cli:
  command: "codex" # inline comment
  flags: "--sandbox workspace-write"
human_review:
  enabled: true
  phases:
    - Phase3-1
    - Phase4-1
notes:
    summary: |
    [y] approve
    [n] reject
'@ | Set-Content -Path $tempConfig -Encoding UTF8

    $config = Read-Config -Path $tempConfig
    Assert-Equal $config["cli.command"] "codex" "Read-Config should parse quoted scalar"
    Assert-Equal $config["cli.flags"] "--sandbox workspace-write" "Read-Config should parse flags"
    Assert-Equal $config["human_review.enabled"] "true" "Read-Config should parse booleans as strings"
    Assert-Equal $config["human_review.phases.0"] "Phase3-1" "Read-Config should parse first array item"
    Assert-Equal $config["human_review.phases.1"] "Phase4-1" "Read-Config should parse second array item"
    Assert-Contains $config["notes.summary"] "[y] approve" "Read-Config should parse block scalar"
}
finally {
    Remove-Item $tempConfig -Force -ErrorAction SilentlyContinue
}

Write-Host "[2/11] Testing phase transition validator..."
function global:Write-Log {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )
}
. (Join-Path $repoRoot "lib/phase-validator.ps1")

$valid = Test-PhaseTransitionValidity -FromPhase "Phase5" -ToPhase "Phase5-1"
Assert-True ([bool]$valid.IsValid) "Phase5 -> Phase5-1 should be valid"

$invalid = Test-PhaseTransitionValidity -FromPhase "Phase5" -ToPhase "Phase7"
Assert-True (-not [bool]$invalid.IsValid) "Phase5 -> Phase7 should be invalid"
Assert-Contains $invalid.Message "Phase5 -> Phase7" "Invalid transition should include source/target"

$rollbackMismatch = Test-StateTransition -CurrentPhase "Phase4" -Feedback "差し戻し先: Phase3" -CurrentRole "implementer"
Assert-True (-not [bool]$rollbackMismatch.IsValid) "Mismatch redirect should be invalid"
Assert-Equal $rollbackMismatch.TargetPhase "Phase3" "Mismatch redirect should report target phase"

$rollbackMatch = Test-StateTransition -CurrentPhase "Phase3" -Feedback "差し戻し先: Phase3" -CurrentRole "implementer"
Assert-True ([bool]$rollbackMatch.IsValid) "Matching redirect should be valid"

Write-Host "[3/11] Testing run-state and event store..."
. (Join-Path $repoRoot "app/core/run-state-store.ps1")
. (Join-Path $repoRoot "app/core/run-lock.ps1")
. (Join-Path $repoRoot "app/core/event-store.ps1")
. (Join-Path $repoRoot "app/core/job-result-policy.ps1")

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-test-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = New-RunId -Now ([datetime]"2026-03-24T12:34:56+09:00")
    $defaultRunState = New-RunState -RunId "run-default" -ProjectRoot $tempRoot
    Assert-Equal $defaultRunState["current_phase"] "Phase0" "New-RunState should default to Phase0"
    Assert-True ($defaultRunState.Keys -contains "active_attempt") "New-RunState should initialize active_attempt"
    Assert-True ($null -eq $defaultRunState["active_attempt"]) "New-RunState should default active_attempt to null"
    Assert-True ($defaultRunState.Keys -contains "active_jobs") "New-RunState should initialize active_jobs"
    Assert-Equal @($defaultRunState["active_jobs"].Keys).Count 0 "New-RunState should default active_jobs to empty"
    Assert-True ($defaultRunState.Keys -contains "task_lane") "New-RunState should initialize task_lane"
    Assert-Equal $defaultRunState["task_lane"]["mode"] "single" "New-RunState should default task_lane mode to single"
    Assert-Equal ([int]$defaultRunState["task_lane"]["max_parallel_jobs"]) 1 "New-RunState should default max_parallel_jobs to 1"
    Assert-Equal ([bool]$defaultRunState["task_lane"]["stop_leasing"]) $false "New-RunState should default stop_leasing to false"
    Assert-Equal ([int]$defaultRunState["state_revision"]) 0 "New-RunState should start state_revision at 0 before first write"
    $runState = New-RunState -RunId $runId -ProjectRoot $tempRoot -CurrentPhase "Phase3" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $tempRoot -RunState $runState | Out-Null
    Set-CurrentRunPointer -ProjectRoot $tempRoot -RunId $runId | Out-Null
    Append-Event -ProjectRoot $tempRoot -RunId $runId -Event @{ type = "run.created" }
    Append-Event -ProjectRoot $tempRoot -RunId $runId -Event @{ type = "job.finished"; job_id = "job-1" }

    $readState = Read-RunState -ProjectRoot $tempRoot -RunId $runId
    Assert-Equal $readState["current_phase"] "Phase3" "Read-RunState should preserve current_phase"
    Assert-Equal @($readState["open_requirements"]).Count 0 "Read-RunState should preserve empty arrays"
    Assert-True ($readState.Keys -contains "active_attempt") "Read-RunState should preserve active_attempt compatibility field"
    Assert-True ($readState.Keys -contains "active_jobs") "Read-RunState should preserve active_jobs compatibility field"
    Assert-Equal @($readState["active_jobs"].Keys).Count 0 "Read-RunState should preserve empty active_jobs"
    Assert-Equal $readState["task_lane"]["mode"] "single" "Read-RunState should preserve task_lane mode"
    Assert-Equal ([int]$readState["state_revision"]) 1 "Write-RunState should increment state_revision on first write"
    Write-RunState -ProjectRoot $tempRoot -RunState $readState | Out-Null
    $readStateAfterSecondWrite = Read-RunState -ProjectRoot $tempRoot -RunId $runId
    Assert-Equal ([int]$readStateAfterSecondWrite["state_revision"]) 2 "Write-RunState should increment state_revision monotonically"
    Assert-Equal (Resolve-ActiveRunId -ProjectRoot $tempRoot) $runId "Resolve-ActiveRunId should use current-run pointer"
    Assert-Equal @((Get-Events -ProjectRoot $tempRoot -RunId $runId)).Count 2 "Get-Events should return appended events"
    Assert-Equal (Get-LastEvent -ProjectRoot $tempRoot -RunId $runId -Type "job.finished")["job_id"] "job-1" "Get-LastEvent should return the latest matching event"
    $statusProjection = Get-Content -Path (Join-Path $tempRoot "queue/status.yaml") -Raw -Encoding UTF8
    Assert-Contains $statusProjection 'current_phase: "Phase3"' "Write-RunState should project current_phase to status.yaml"
    Assert-Contains $statusProjection 'assigned_to: "implementer"' "Write-RunState should project assigned_to to status.yaml"

    $attemptState = Start-RunStateActiveAttempt -RunState $readState -AttemptId "attempt-0001" -Phase "Phase3" -Stage "dispatching" -Status "running" -TaskId "T-01" -JobId "job-1"
    $attemptState = Update-RunStateActiveAttempt -RunState $attemptState -AttemptId "attempt-0002" -Stage "committing" -Result "succeeded"
    Assert-Equal $attemptState["active_attempt"]["attempt_id"] "attempt-0002" "Update-RunStateActiveAttempt should allow replacing the active attempt id"
    Assert-Equal $attemptState["active_attempt"]["stage"] "committing" "Update-RunStateActiveAttempt should update the active attempt stage"
    $attemptState = Clear-RunStateActiveAttempt -RunState $attemptState -Status "completed" -Result "phase_transitioned"
    Assert-True ($null -eq $attemptState["active_attempt"]) "Clear-RunStateActiveAttempt should clear active_attempt"

    $taskHistoryState = New-RunState -RunId "run-history" -ProjectRoot $tempRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $taskHistoryState["current_task_id"] = "T-01"
    $taskHistoryState["phase_history"] = @()
    $taskHistoryState = Sync-RunStatePhaseHistory -RunState $taskHistoryState
    Assert-Equal $taskHistoryState["phase_history"][0]["task_id"] "T-01" "Sync-RunStatePhaseHistory should record task_id on new phase entries"
    $taskHistoryState["current_task_id"] = "T-02"
    $taskHistoryState = Sync-RunStatePhaseHistory -RunState $taskHistoryState
    Assert-Equal @($taskHistoryState["phase_history"]).Count 2 "Sync-RunStatePhaseHistory should open a new entry when the task id changes within a task-scoped phase"

    $lockHandle = $null
    $reacquiredLock = $null
    try {
        $lockHandle = Acquire-RunLock -ProjectRoot $tempRoot -RunId $runId -RetryCount 2 -RetryDelayMs 10 -TimeoutSec 1
        Assert-True ($null -ne $lockHandle["stream"]) "Acquire-RunLock should return an open stream handle"

        $secondAcquireFailed = $false
        try {
            $null = Acquire-RunLock -ProjectRoot $tempRoot -RunId $runId -RetryCount 2 -RetryDelayMs 10 -TimeoutSec 1
        }
        catch {
            $secondAcquireFailed = $true
            Assert-Contains $_.Exception.Message "locked by another step" "Acquire-RunLock should explain lock contention"
        }

        Assert-True $secondAcquireFailed "Acquire-RunLock should fail while the same run is already locked"
    }
    finally {
        Release-RunLock -LockHandle $lockHandle
    }

    try {
        $reacquiredLock = Acquire-RunLock -ProjectRoot $tempRoot -RunId $runId -RetryCount 2 -RetryDelayMs 10 -TimeoutSec 1
        Assert-True ($null -ne $reacquiredLock["stream"]) "Release-RunLock should allow the run to be locked again"
    }
    finally {
        Release-RunLock -LockHandle $reacquiredLock
    }
}
finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[4/11] Testing provider adapter argument normalization..."
. (Join-Path $repoRoot "app/execution/providers/generic-cli.ps1")
. (Join-Path $repoRoot "app/execution/providers/codex.ps1")
. (Join-Path $repoRoot "app/execution/providers/gemini.ps1")
. (Join-Path $repoRoot "app/execution/providers/claude.ps1")
. (Join-Path $repoRoot "app/execution/providers/copilot.ps1")
. (Join-Path $repoRoot "app/execution/providers/fake-provider.ps1")
. (Join-Path $repoRoot "app/execution/provider-adapter.ps1")
. (Join-Path $repoRoot "app/execution/execution-runner.ps1")

$providerSpec = Get-ProviderInvocationSpec -JobSpec @{
    provider = "gemini-cli"
    command = "gemini"
    flags = "-y -p"
}
Assert-Equal $providerSpec["arguments"] "-y" "Provider adapter should strip prompt flags from CLI arguments"
Assert-Equal $providerSpec["provider"] "gemini-cli" "Provider adapter should preserve normalized provider name"
Assert-Equal $providerSpec["environment"]["GEMINI_CLI_TRUST_WORKSPACE"] "true" "Gemini provider should trust the workspace for headless runs"

$claudeSpec = Get-ProviderInvocationSpec -JobSpec @{
    provider = "claudecode"
    command = "claude"
    flags = "--dangerously-skip-permissions -p"
}
Assert-Equal $claudeSpec["provider"] "claude-code" "Claude provider should normalize to claude-code"
Assert-Equal $claudeSpec["prompt_mode"] "stdin" "Claude provider should pass prompts via stdin"
Assert-Equal $claudeSpec["prompt_flag"] "-p" "Claude provider should preserve the prompt flag"
Assert-Equal $claudeSpec["arguments"] "--dangerously-skip-permissions" "Claude provider should strip prompt flags from base arguments"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$claudeSpec["environment"]["PATH"])) "Claude provider should propagate PATH for CLI discovery"

$claudeInvocation = Resolve-ProcessInvocationSpec -InvocationSpec $claudeSpec
$claudeArguments = Get-ExecutionArgumentsForAttempt -InvocationSpec $claudeInvocation -PromptText "hello world"
Assert-Equal $claudeArguments "--dangerously-skip-permissions" "Claude execution should preserve base arguments when prompts are sent via stdin"
$claudeDisplayArguments = Get-ExecutionArgumentsForAttempt -InvocationSpec $claudeInvocation -PromptText "hello world" -ForDisplay
Assert-Equal $claudeDisplayArguments "--dangerously-skip-permissions" "Claude execution logs should not append a redacted prompt argument when prompts are sent via stdin"
$claudeArgumentList = @(Get-ExecutionArgumentListForAttempt -InvocationSpec $claudeInvocation -PromptText "hello`nworld")
Assert-Equal $claudeArgumentList.Count 1 "Claude execution should not append prompt argv tokens when prompts are sent via stdin"
Assert-Equal $claudeArgumentList[0] "--dangerously-skip-permissions" "Claude execution should preserve the base argument token list when prompts are sent via stdin"

$copilotSpec = Get-ProviderInvocationSpec -JobSpec @{
    provider = "copilot"
    command = "copilot"
    flags = "--autopilot --yolo --max-autopilot-continues 30 -p"
}
Assert-Equal $copilotSpec["provider"] "copilot-cli" "Copilot provider should normalize to copilot-cli"
Assert-Equal $copilotSpec["prompt_mode"] "stdin" "Copilot provider should pass prompts via stdin"
Assert-Equal $copilotSpec["prompt_flag"] "-p" "Copilot provider should preserve the prompt flag"
Assert-Equal $copilotSpec["arguments"] "--autopilot --yolo --max-autopilot-continues 30" "Copilot provider should strip prompt flags from base arguments"
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$copilotSpec["environment"]["PATH"])) "Copilot provider should propagate PATH for GitHub CLI discovery"

$copilotInvocation = Resolve-ProcessInvocationSpec -InvocationSpec $copilotSpec
$copilotArguments = Get-ExecutionArgumentsForAttempt -InvocationSpec $copilotInvocation -PromptText "hello world"
Assert-Equal $copilotArguments "--autopilot --yolo --max-autopilot-continues 30" "Copilot execution should preserve base arguments when prompts are sent via stdin"

$copilotDisplayArguments = Get-ExecutionArgumentsForAttempt -InvocationSpec $copilotInvocation -PromptText "hello world" -ForDisplay
Assert-Equal $copilotDisplayArguments "--autopilot --yolo --max-autopilot-continues 30" "Copilot execution logs should not append a redacted prompt argument when prompts are sent via stdin"
$copilotArgumentList = @(Get-ExecutionArgumentListForAttempt -InvocationSpec $copilotInvocation -PromptText "hello`nworld")
Assert-Equal $copilotArgumentList.Count 4 "Copilot execution should not append prompt argv tokens when prompts are sent via stdin"
Assert-Equal $copilotArgumentList[0] "--autopilot" "Copilot execution should preserve the first base argument token when prompts are sent via stdin"
Assert-Equal $copilotArgumentList[1] "--yolo" "Copilot execution should preserve the second base argument token when prompts are sent via stdin"
Assert-Equal $copilotArgumentList[2] "--max-autopilot-continues" "Copilot execution should preserve flag/value argument ordering when prompts are sent via stdin"
Assert-Equal $copilotArgumentList[3] "30" "Copilot execution should preserve the max-autopilot-continues value token when prompts are sent via stdin"

$tempCopilotProviderRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-copilot-provider-" + [guid]::NewGuid().ToString("N"))
try {
    $archToken = (Get-CopilotArchitectureTokens | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($archToken)) {
        $archToken = "x64"
    }
    $platformToken = Get-CopilotPlatformToken
    if ([string]::IsNullOrWhiteSpace($platformToken)) {
        throw "Copilot platform token should resolve for the current test host."
    }

    $wrapperPath = Join-Path $tempCopilotProviderRoot "copilot.ps1"
    $packageRoot = Join-Path $tempCopilotProviderRoot "node_modules"
    $packageRoot = Join-Path $packageRoot "@github"
    $packageRoot = Join-Path $packageRoot "copilot"
    $nativePackageRoot = Join-Path $packageRoot "node_modules"
    $nativePackageRoot = Join-Path $nativePackageRoot "@github"
    $nativePackageDir = Join-Path $nativePackageRoot ("copilot-{0}-{1}" -f $platformToken, $archToken)
    $nativeBinaryName = if ($platformToken -eq "win32") { "copilot.exe" } else { "copilot" }
    $nativeBinaryPath = Join-Path $nativePackageDir $nativeBinaryName
    New-Item -ItemType Directory -Path $nativePackageDir -Force | Out-Null
    Set-Content -Path $wrapperPath -Value "# synthetic copilot wrapper" -Encoding UTF8
    Set-Content -Path $nativeBinaryPath -Value "" -Encoding UTF8

    $resolvedNativePath = Get-CopilotNativeCommandPath -Command $wrapperPath
    Assert-Equal ([System.IO.Path]::GetFullPath($resolvedNativePath)) ([System.IO.Path]::GetFullPath($nativeBinaryPath)) "Copilot provider should resolve a wrapper install to the adjacent native executable"

    $syntheticCopilotSpec = Get-CopilotProviderInvocationSpec -JobSpec @{
        provider = "copilot"
        command = $wrapperPath
        flags = "--autopilot --yolo --max-autopilot-continues 30 -p"
    }
    Assert-Equal ([System.IO.Path]::GetFullPath([string]$syntheticCopilotSpec["command"])) ([System.IO.Path]::GetFullPath($nativeBinaryPath)) "Copilot invocation spec should bypass the PowerShell wrapper when the native executable exists"

    $syntheticCopilotInvocation = Resolve-ProcessInvocationSpec -InvocationSpec $syntheticCopilotSpec
    Assert-Equal ([System.IO.Path]::GetFullPath([string]$syntheticCopilotInvocation["command"])) ([System.IO.Path]::GetFullPath($nativeBinaryPath)) "Resolved Copilot invocation should launch the native executable directly"
}
finally {
    Remove-Item -Path $tempCopilotProviderRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$timeoutRecovery = Resolve-EffectiveExecutionResult -ExecutionResult @{
    result_status = "failed"
    exit_code = -1
    failure_class = "timeout"
} -ValidationResult @{
    valid = $true
}
Assert-Equal $timeoutRecovery["execution_result"]["result_status"] "succeeded" "Timeout with valid artifacts should be recovered to success"
Assert-Equal $timeoutRecovery["execution_result"]["exit_code"] 0 "Timeout recovery should normalize exit code to zero"
Assert-True ([bool]$timeoutRecovery["recovered_from_timeout"]) "Timeout recovery should report recovery"

$timeoutNoRecovery = Resolve-EffectiveExecutionResult -ExecutionResult @{
    result_status = "failed"
    exit_code = -1
    failure_class = "timeout"
} -ValidationResult @{
    valid = $false
}
Assert-Equal $timeoutNoRecovery["execution_result"]["result_status"] "failed" "Timeout without valid artifacts should remain failed"
Assert-True (-not [bool]$timeoutNoRecovery["recovered_from_timeout"]) "Timeout without valid artifacts should not be recovered"

$tempScriptCommand = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-command-" + [guid]::NewGuid().ToString("N") + ".ps1")
try {
    Set-Content -Path $tempScriptCommand -Value "Write-Output 'ok'" -Encoding UTF8
    $resolvedInvocation = Resolve-ProcessInvocationSpec -InvocationSpec @{
        command = $tempScriptCommand
        arguments = "--version"
    }
    Assert-Equal $resolvedInvocation["command"] "pwsh" "Process invocation should wrap .ps1 commands with pwsh"
    Assert-Contains $resolvedInvocation["arguments"] $tempScriptCommand "Wrapped .ps1 invocation should include the script path"
}
finally {
    Remove-Item -Path $tempScriptCommand -Force -ErrorAction SilentlyContinue
}

$tempArgvScriptCommand = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-argv-command-" + [guid]::NewGuid().ToString("N") + ".ps1")
try {
    @'
$result = [ordered]@{
    count = $args.Count
    flag = if ($args.Count -ge 2) { [string]$args[$args.Count - 2] } else { "" }
    prompt = if ($args.Count -ge 1) { [string]$args[$args.Count - 1] } else { "" }
}
$result | ConvertTo-Json -Compress
'@ | Set-Content -Path $tempArgvScriptCommand -Encoding UTF8

    $argvAttempt = Invoke-ExecutionAttempt -InvocationSpec @{
        provider = "test-cli"
        command = $tempArgvScriptCommand
        arguments = "--alpha"
        prompt_mode = "argv"
        prompt_flag = "-p"
    } -PromptText "line1`nline2" -WorkingDirectory $repoRoot -Attempt 1 -TimeoutPolicy @{
        warn_after_sec = 0
        retry_after_sec = 0
        abort_after_sec = 0
    }
    $argvPayload = ConvertTo-RelayHashtable -InputObject (($argvAttempt["stdout"] | ConvertFrom-Json))
    Assert-Equal $argvPayload["count"] 3 "Execution runner should preserve argv prompt transport for .ps1 commands without splitting multiline prompts"
    Assert-Equal $argvPayload["flag"] "-p" "Execution runner should pass the argv prompt flag as a dedicated argument"
    Assert-Equal $argvPayload["prompt"] "line1`nline2" "Execution runner should pass multiline argv prompts as a single argument"
}
finally {
    Remove-Item -Path $tempArgvScriptCommand -Force -ErrorAction SilentlyContinue
}

Write-Host "[5/11] Testing typed artifacts and validator..."
. (Join-Path $repoRoot "app/core/artifact-repository.ps1")
. (Join-Path $repoRoot "app/core/artifact-validator.ps1")
. (Join-Path $repoRoot "app/core/artifact-repair-policy.ps1")
. (Join-Path $repoRoot "app/core/repair-diff-guard.ps1")
. (Join-Path $repoRoot "app/core/verdict-finalizer.ps1")
. (Join-Path $repoRoot "app/core/phase-validation-pipeline.ps1")
. (Join-Path $repoRoot "app/phases/phase-registry.ps1")

$claudePromptPackage = Resolve-PromptPackage -ProjectRoot $repoRoot -Phase "Phase1" -Role "implementer" -Provider "claude-code"
Assert-Contains $claudePromptPackage["provider_hints_ref"] "claude-code.md" "Prompt package should load Claude-specific provider hints"

$copilotPromptPackage = Resolve-PromptPackage -ProjectRoot $repoRoot -Phase "Phase1" -Role "implementer" -Provider "copilot-cli"
Assert-Contains $copilotPromptPackage["provider_hints_ref"] "copilot-cli.md" "Prompt package should load Copilot-specific provider hints"

$tempArtifactRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-artifact-test-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempArtifactRoot -Force | Out-Null

    $artifactRunState = New-RunState -RunId "run-artifact-test" -ProjectRoot $tempArtifactRoot -TaskId "req-compat" -CurrentPhase "Phase3" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $tempArtifactRoot -RunState $artifactRunState | Out-Null

    $phase3Json = [ordered]@{
        feature_list = @(@{ id = "F-01"; summary = "Search API" })
        api_definitions = @(@{ name = "GET /api/search" })
        entities = @(@{ name = "SearchResult" })
        constraints = @(@{ name = "Latency"; target = "p95 < 500ms" })
        state_transitions = @(@{ from = "idle"; to = "loading" })
        reuse_decisions = @(@{ target = "auth"; decision = "reuse" })
        module_boundaries = @(@{ module = "application/search"; responsibility = "Search orchestration" })
        public_interfaces = @(@{ name = "GET /api/search"; kind = "http_endpoint" })
        allowed_dependencies = @(@{ from = "application/search"; to = "domain/search" })
        forbidden_dependencies = @(@{ from = "application/search"; to = "infra/db"; reason = "Use repository boundary" })
        side_effect_boundaries = @(@{ effect = "db"; boundary = "SearchRepository" })
        state_ownership = @(@{ state = "SearchQuery"; owner = "application/search" })
        visual_contract = (New-VisualContract)
    }
    $phase6Json = [ordered]@{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 12
        tests_failed = 0
        coverage_line = 85
        coverage_branch = 77
        verdict = "go"
        rollback_phase = $null
        conditional_go_reasons = @()
        verification_checks = New-Phase6VerificationChecks
        open_requirements = @()
        resolved_requirement_ids = @()
    }
    $phase2Json = [ordered]@{
        collected_evidence = @("E1")
        decisions = @("D1")
        unresolved_blockers = @()
        source_refs = @("S1")
        next_actions = @("N1")
    }
    $phase7Json = [ordered]@{
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("Null guard is missing")
        warnings = @("Coverage is slightly below target")
        evidence = @("src/app.ts:42")
        review_checks = New-Phase7ReviewChecks -StatusOverrides @{
            correctness_and_edge_cases = "warning"
        }
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @()
        follow_up_tasks = @(
            @{
                task_id = "pr_fixes"
                purpose = "Add null guard"
                changed_files = @("src/app.ts")
                acceptance_criteria = @("Null guard is added")
                depends_on = @()
                verification = @("npm test")
                source_evidence = @("src/app.ts:42")
            }
        )
    }

    $runId = "run-artifact-test"
    Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $runId -Scope run -Phase "Phase2" -ArtifactId "phase2_info_gathering.json" -Content $phase2Json -AsJson | Out-Null
    $phase3Write = Write-Phase3Artifacts -ProjectRoot $tempArtifactRoot -RunId $runId -MarkdownContent "# Phase3" -JsonContent $phase3Json
    $phase6Write = Write-Phase6Artifacts -ProjectRoot $tempArtifactRoot -RunId $runId -TaskId "T-01" -MarkdownContent "# Phase6" -JsonContent $phase6Json -TestOutput "ok"
    $phase7Write = Write-Phase7Artifacts -ProjectRoot $tempArtifactRoot -RunId $runId -MarkdownContent "# Phase7" -JsonContent $phase7Json

    Assert-True (Test-Path $phase3Write["json_path"]) "Write-Phase3Artifacts should persist canonical JSON"
    Assert-True (Test-Path $phase6Write["test_output_path"]) "Write-Phase6Artifacts should persist test output"
    Assert-True (Test-Path $phase7Write["json_path"]) "Write-Phase7Artifacts should persist canonical JSON"
    $phase2Validation = Test-ArtifactRef -ProjectRoot $tempArtifactRoot -RunId $runId -ArtifactRef @{
        scope = "run"
        phase = "Phase2"
        artifact_id = "phase2_info_gathering.json"
    }
    Assert-True ([bool]$phase2Validation["valid"]) "Phase2 artifact should allow empty unresolved_blockers"
    Assert-True ([bool]$phase3Write["validation"]["valid"]) "Phase3 artifact should validate"
    Assert-True ([bool]$phase6Write["validation"]["valid"]) "Phase6 artifact should validate"
    Assert-True ([bool]$phase7Write["validation"]["valid"]) "Phase7 artifact should validate"
    $legacyPhase3Json = [ordered]@{
        feature_list = @(@{ id = "F-legacy"; summary = "Legacy schema" })
        api_definitions = @(@{ name = "GET /api/legacy" })
        entities = @(@{ name = "LegacyView" })
        constraints = @(@{ name = "Schema"; target = "Normalize visual_contract" })
        state_transitions = @(@{ from = "draft"; to = "published" })
        reuse_decisions = @(@{ target = "layout"; decision = "reuse" })
        module_boundaries = @(@{ module = "ui/legacy"; responsibility = "Render legacy UI" })
        public_interfaces = @(@{ name = "LegacyView"; kind = "component" })
        allowed_dependencies = @(@{ from = "ui/legacy"; to = "ui/shared" })
        forbidden_dependencies = @(@{ from = "ui/legacy"; to = "infra/db"; reason = "UI must stay pure" })
        side_effect_boundaries = @(@{ effect = "network"; boundary = "hooks/useLegacyData" })
        state_ownership = @(@{ state = "LegacyFilters"; owner = "ui/legacy" })
        visual_contract = [ordered]@{
            mode = "design_md"
            design_sources = @("DESIGN.md")
            visual_constraints = @("Keep the documented neutral workspace tone.")
            component_patterns = [ordered]@{
                buttons = [ordered]@{
                    primary = "Use the compact filled button style."
                }
            }
            responsive_expectations = [ordered]@{
                mobile_employee = [ordered]@{
                    breakpoint = "<= 640px"
                    layout = "single column"
                }
            }
            interaction_guidelines = [ordered]@{
                loading = [ordered]@{
                    button = "Show a spinner and disable repeat taps."
                }
            }
        }
    }
    $legacyNormalization = Normalize-ArtifactForValidation -ArtifactId "phase3_design.json" -Artifact $legacyPhase3Json
    $legacyNormalizedArtifact = ConvertTo-RelayHashtable -InputObject $legacyNormalization["artifact"]
    Assert-True ([bool]$legacyNormalization["changed"]) "Legacy Phase3 visual_contract maps should be normalized before validation"
    Assert-Contains (@($legacyNormalization["warnings"]) -join "`n") "visual_contract.component_patterns" "Normalization warnings should explain which Phase3 field was repaired"
    Assert-True ($legacyNormalizedArtifact["visual_contract"]["component_patterns"] -is [System.Collections.IEnumerable] -and -not ($legacyNormalizedArtifact["visual_contract"]["component_patterns"] -is [string]) -and -not ($legacyNormalizedArtifact["visual_contract"]["component_patterns"] -is [System.Collections.IDictionary])) "Normalized Phase3 component_patterns should become an array"
    $legacyPhase3Validation = Test-ArtifactContract -ArtifactId "phase3_design.json" -Artifact $legacyPhase3Json -Phase "Phase3"
    Assert-True ([bool]$legacyPhase3Validation["valid"]) "Legacy Phase3 visual_contract maps should validate after normalization"
    Assert-Contains (@($legacyPhase3Validation["warnings"]) -join "`n") "visual_contract.responsive_expectations" "Phase3 validation should preserve normalization warnings"

    $legacyPhase4Tasks = [ordered]@{
        tasks = @(
            [ordered]@{
                task_id = "T-legacy"
                purpose = "Carry normalized visual contract into tasks"
                changed_files = @("src/legacy.tsx")
                acceptance_criteria = @("Legacy task keeps the documented UI contract")
                boundary_contract = (New-BoundaryContract)
                visual_contract = $legacyPhase3Json["visual_contract"]
                dependencies = @()
                tests = @("npm test")
                complexity = "small"
            }
        )
    }
    $legacyPhase4Validation = Test-ArtifactContract -ArtifactId "phase4_tasks.json" -Artifact $legacyPhase4Tasks -Phase "Phase4"
    Assert-True ([bool]$legacyPhase4Validation["valid"]) "Legacy task visual_contract maps should validate after normalization in Phase4"
    Assert-Contains (@($legacyPhase4Validation["warnings"]) -join "`n") "tasks[T-legacy].visual_contract.component_patterns" "Phase4 normalization warnings should include the task path"

    $archiveRunId = "run-archive-phase"
    Write-RunState -ProjectRoot $tempArtifactRoot -RunState (New-RunState -RunId $archiveRunId -ProjectRoot $tempArtifactRoot -CurrentPhase "Phase3" -CurrentRole "implementer") | Out-Null
    Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $archiveRunId -Scope run -Phase "Phase3" -ArtifactId "phase3_design.md" -Content "# Archived Phase3" | Out-Null
    Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $archiveRunId -Scope run -Phase "Phase3" -ArtifactId "phase3_design.json" -Content @{
        feature_list = @("archive-test")
        api_definitions = @("GET /archive")
        entities = @("ArchiveEntity")
        constraints = @("Archive before rerun")
        state_transitions = @("none")
        reuse_decisions = @("reuse")
        module_boundaries = @("src/archive")
        public_interfaces = @("archive()")
        allowed_dependencies = @("archive -> shared")
        forbidden_dependencies = @("archive -> db direct")
        side_effect_boundaries = @("archive boundary")
        state_ownership = @("archive owner")
        visual_contract = (New-VisualContract -Mode "not_applicable")
    } -AsJson | Out-Null
    $phaseArchiveResult = Archive-PhaseArtifacts -ProjectRoot $tempArtifactRoot -RunId $archiveRunId -Scope run -Phase "Phase3" -Reason "test_rerun_archive"
    Assert-True ([bool]$phaseArchiveResult["archived"]) "Archive-PhaseArtifacts should move existing run-scoped phase outputs before rerun"
    Assert-True (-not (Test-Path (Get-ArtifactPath -ProjectRoot $tempArtifactRoot -RunId $archiveRunId -Scope run -Phase "Phase3" -ArtifactId "phase3_design.json"))) "Archived run-scoped phase JSON should no longer remain in the active phase directory"
    Assert-True (Test-Path (Join-Path ([string]$phaseArchiveResult["snapshot_path"]) "metadata.json")) "Archive-PhaseArtifacts should record snapshot metadata"
    $latestArchivedPhaseJson = @(Get-LatestArchivedPhaseJsonArtifacts -ProjectRoot $tempArtifactRoot -RunId $archiveRunId -Scope run -Phase "Phase3")
    Assert-Equal $latestArchivedPhaseJson.Count 1 "Get-LatestArchivedPhaseJsonArtifacts should return the latest archived phase JSON files"
    Assert-Equal ([string]$latestArchivedPhaseJson[0]["artifact_id"]) "phase3_design.json" "Archived phase JSON context should surface the archived artifact id"

    $archiveTaskRunId = "run-archive-task"
    Write-RunState -ProjectRoot $tempArtifactRoot -RunState (New-RunState -RunId $archiveTaskRunId -ProjectRoot $tempArtifactRoot -CurrentPhase "Phase5" -CurrentRole "implementer" -TaskId "T-archive") | Out-Null
    Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $archiveTaskRunId -Scope task -TaskId "T-archive" -Phase "Phase6" -ArtifactId "phase6_result.json" -Content @{
        task_id = "T-archive"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 1
        tests_failed = 0
        coverage_line = 80
        coverage_branch = 70
        verdict = "go"
        conditional_go_reasons = @()
        verification_checks = New-Phase6VerificationChecks
        open_requirements = @()
        resolved_requirement_ids = @()
    } -AsJson | Out-Null
    $taskArchiveResult = Archive-PhaseArtifacts -ProjectRoot $tempArtifactRoot -RunId $archiveTaskRunId -Scope task -Phase "Phase6" -TaskId "T-archive" -Reason "test_task_rerun_archive"
    Assert-True ([bool]$taskArchiveResult["archived"]) "Archive-PhaseArtifacts should move existing task-scoped phase outputs before rerun"
    $latestArchivedTaskJson = @(Get-LatestArchivedPhaseJsonArtifacts -ProjectRoot $tempArtifactRoot -RunId $archiveTaskRunId -Scope task -Phase "Phase6" -TaskId "T-archive")
    Assert-Equal $latestArchivedTaskJson.Count 1 "Get-LatestArchivedPhaseJsonArtifacts should return the latest archived task-scoped JSON files"
    Assert-Contains ([string]$latestArchivedTaskJson[0]["path"]) "T-archive" "Archived task-scoped JSON context should preserve the task scope path"
    Assert-True (Test-Path (Join-Path $tempArtifactRoot "outputs/req-compat/phase3_design.md")) "Run-scoped markdown should be projected to outputs/"
    Assert-True (Test-Path (Join-Path $tempArtifactRoot "outputs/req-compat/tasks/T-01/phase6_result.json")) "Task-scoped JSON should be projected to outputs/"
    Assert-True (Test-Path (Join-Path $tempArtifactRoot "outputs/req-compat/.tasks/T-01_completed.md")) "Phase6 verdict should create compatibility completion marker"
    Assert-True (Test-Path (Join-Path $tempArtifactRoot "outputs/req-compat/tasks/pr_fixes/fix_contract.yaml")) "Phase7 repair task should project fix_contract.yaml"

    $taskFilePath = Join-Path $tempArtifactRoot "tasks\task.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskFilePath) -Force | Out-Null
    Set-Content -Path $taskFilePath -Value "# Cross-day output reuse`n`nSame task across multiple runs." -Encoding UTF8

    $taskMainRunA = "run-20260401-090000"
    $taskMainRunB = "run-20260402-090000"
    Write-RunState -ProjectRoot $tempArtifactRoot -RunState (New-RunState -RunId $taskMainRunA -ProjectRoot $tempArtifactRoot -CurrentPhase "Phase1" -CurrentRole "implementer") | Out-Null
    Write-RunState -ProjectRoot $tempArtifactRoot -RunState (New-RunState -RunId $taskMainRunB -ProjectRoot $tempArtifactRoot -CurrentPhase "Phase1" -CurrentRole "implementer") | Out-Null
    Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $taskMainRunA -Scope run -Phase "Phase1" -ArtifactId "phase1_requirements.md" -Content "# Task Main A" | Out-Null
    Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $taskMainRunB -Scope run -Phase "Phase1" -ArtifactId "phase1_requirements.md" -Content "# Task Main B" | Out-Null

    $taskMainCompatA = Resolve-CompatibilityRequirementName -ProjectRoot $tempArtifactRoot -RunId $taskMainRunA
    $taskMainCompatB = Resolve-CompatibilityRequirementName -ProjectRoot $tempArtifactRoot -RunId $taskMainRunB
    Assert-Equal $taskMainCompatA $taskMainCompatB "task-main runs with the same task file should reuse one compatibility output directory"
    Assert-Contains $taskMainCompatA "Cross-day-output-reuse" "task-main compatibility directory should derive from task.md title"
    Assert-True (Test-Path (Join-Path $tempArtifactRoot "outputs/$taskMainCompatA/phase1_requirements.md")) "task-main compatibility projection should write to the stable task-based directory"

    $phase6Artifact = Read-Artifact -ProjectRoot $tempArtifactRoot -RunId $runId -Scope task -TaskId "T-01" -Phase "Phase6" -ArtifactId "phase6_result.json"
    Assert-Equal $phase6Artifact["verdict"] "go" "Read-Artifact should deserialize canonical JSON"

    $phase6DefinitionForValidation = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase6" -Provider "codex-cli"
    $phase6WarningLegacyVerdict = [ordered]@{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 12
        tests_failed = 0
        coverage_line = 85
        coverage_branch = 77
        verdict = "reject"
        rollback_phase = "Phase5"
        conditional_go_reasons = @("Coverage warning must be reviewed before merge.")
        verification_checks = (New-Phase6VerificationChecks -StatusOverrides @{
            coverage_assessment = "warning"
        })
        open_requirements = (New-Phase6OpenRequirements -TaskId "T-01")
        resolved_requirement_ids = @()
    }
    $phase6WarningFinalized = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseValidationPipeline -PhaseName "Phase6" -PhaseDefinition $phase6DefinitionForValidation -MaterializedArtifacts @(
            (New-MaterializedArtifact -ArtifactId "phase6_result.json" -Phase "Phase6" -TaskId "T-01" -Content $phase6WarningLegacyVerdict)
        ) -TaskId "T-01")
    $phase6WarningFinalizedMaterialized = ConvertTo-RelayHashtable -InputObject (@($phase6WarningFinalized["materialized_artifacts"])[0])
    Assert-True ([bool]$phase6WarningFinalized["validation"]["valid"]) "Phase6 machine-owned verdict should accept warning-only artifacts when carry-forward fields are present"
    Assert-Equal $phase6WarningFinalized["artifact"]["verdict"] "conditional_go" "Phase6 machine-owned verdict should infer conditional_go from warning-only verification checks"
    Assert-Equal ([string]$phase6WarningFinalized["artifact"]["rollback_phase"]) "" "Phase6 machine-owned verdict should clear rollback_phase for conditional_go"
    Assert-Equal $phase6WarningFinalizedMaterialized["content"]["verdict"] "conditional_go" "Phase6 finalization should feed the canonical verdict back into materialized artifacts for commit"
    Assert-Contains (@($phase6WarningFinalized["validation"]["warnings"]) -join "`n") "finalized from 'reject' to 'conditional_go'" "Phase6 finalization should surface when it overrides a legacy verdict"

    $phase6FailLegacyVerdict = [ordered]@{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 11
        tests_failed = 0
        coverage_line = 85
        coverage_branch = 77
        verdict = "go"
        rollback_phase = "Phase5"
        conditional_go_reasons = @()
        verification_checks = (New-Phase6VerificationChecks -StatusOverrides @{
            automated_tests = "fail"
        })
        open_requirements = @()
        resolved_requirement_ids = @()
    }
    $phase6FailFinalized = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseValidationPipeline -PhaseName "Phase6" -PhaseDefinition $phase6DefinitionForValidation -MaterializedArtifacts @(
            (New-MaterializedArtifact -ArtifactId "phase6_result.json" -Phase "Phase6" -TaskId "T-01" -Content $phase6FailLegacyVerdict)
        ) -TaskId "T-01")
    Assert-True ([bool]$phase6FailFinalized["validation"]["valid"]) "Phase6 machine-owned verdict should accept failed verification artifacts when rollback data is present"
    Assert-Equal $phase6FailFinalized["artifact"]["verdict"] "reject" "Phase6 machine-owned verdict should infer reject from failed verification checks"
    Assert-Contains (@($phase6FailFinalized["validation"]["warnings"]) -join "`n") "finalized from 'go' to 'reject'" "Phase6 finalization should surface when it upgrades a go verdict to reject"

    $phase6MissingRollback = [ordered]@{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 11
        tests_failed = 0
        coverage_line = 85
        coverage_branch = 77
        verdict = "go"
        rollback_phase = ""
        conditional_go_reasons = @()
        verification_checks = (New-Phase6VerificationChecks -StatusOverrides @{
            automated_tests = "fail"
        })
        open_requirements = @()
        resolved_requirement_ids = @()
    }
    $phase6MissingRollbackValidation = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseValidationPipeline -PhaseName "Phase6" -PhaseDefinition $phase6DefinitionForValidation -MaterializedArtifacts @(
            (New-MaterializedArtifact -ArtifactId "phase6_result.json" -Phase "Phase6" -TaskId "T-01" -Content $phase6MissingRollback)
        ) -TaskId "T-01")
    Assert-True (-not [bool]$phase6MissingRollbackValidation["validation"]["valid"]) "Phase6 finalization should still fail when reject supporting fields are missing"
    Assert-Contains (@($phase6MissingRollbackValidation["validation"]["errors"]) -join "`n") "reject verdict requires rollback_phase." "Phase6 finalization should keep rollback_phase as an explicit reject contract"

    $phase6MissingCarryForward = [ordered]@{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 12
        tests_failed = 0
        coverage_line = 85
        coverage_branch = 77
        verdict = "go"
        rollback_phase = ""
        conditional_go_reasons = @()
        verification_checks = (New-Phase6VerificationChecks -StatusOverrides @{
            coverage_assessment = "warning"
        })
        open_requirements = @()
        resolved_requirement_ids = @()
    }
    $phase6MissingCarryForwardValidation = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseValidationPipeline -PhaseName "Phase6" -PhaseDefinition $phase6DefinitionForValidation -MaterializedArtifacts @(
            (New-MaterializedArtifact -ArtifactId "phase6_result.json" -Phase "Phase6" -TaskId "T-01" -Content $phase6MissingCarryForward)
        ) -TaskId "T-01")
    Assert-True (-not [bool]$phase6MissingCarryForwardValidation["validation"]["valid"]) "Phase6 finalization should still require carry-forward fields when warnings remain"
    Assert-Contains (@($phase6MissingCarryForwardValidation["validation"]["errors"]) -join "`n") "conditional_go verdict requires at least one conditional_go_reasons item." "Phase6 finalization should keep conditional_go_reasons as an explicit contract"
    Assert-Contains (@($phase6MissingCarryForwardValidation["validation"]["errors"]) -join "`n") "conditional_go verdict requires at least one open_requirements item." "Phase6 finalization should keep open_requirements as an explicit contract"

    $invalidPhase7 = Test-ArtifactContract -ArtifactId "phase7_verdict.json" -Artifact @{
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("Need repair task")
        warnings = @()
        evidence = @()
        review_checks = New-Phase7ReviewChecks -StatusOverrides @{
            correctness_and_edge_cases = "warning"
        }
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @()
        follow_up_tasks = @()
    } -Phase "Phase7"
    Assert-True (-not [bool]$invalidPhase7["valid"]) "Invalid Phase7 artifact should fail validation"
    Assert-Contains ($invalidPhase7["errors"] -join "`n") "follow_up_tasks" "Invalid Phase7 artifact should report missing follow_up_tasks"

    $invalidPhase31 = Test-ArtifactContract -ArtifactId "phase3-1_verdict.json" -Artifact @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("design reviewed")
        review_checks = New-Phase31ReviewChecks -StatusOverrides @{
            encapsulation_consistency = "warning"
        }
    } -Phase "Phase3-1"
    Assert-True (-not [bool]$invalidPhase31["valid"]) "go verdict with non-pass design boundary review check should be invalid"
    Assert-Contains ($invalidPhase31["errors"] -join "`n") "design contract review_checks" "Phase3-1 validator should enforce fixed design contract review checks"

    $legacyPhase31Verdict = [ordered]@{
        verdict = "conditional_go"
        rollback_phase = ""
        must_fix = "Clarify design boundary issue"
        warnings = "Track the remaining review warning"
        evidence = "phase3_design.json"
        review_checks = Convert-EntryFieldToScalar -Entries (New-Phase31ReviewChecks -StatusOverrides @{
            dependency_rules = "warning"
        })
    }
    $legacyPhase31Normalization = Normalize-ArtifactForValidation -ArtifactId "phase3-1_verdict.json" -Artifact $legacyPhase31Verdict
    $legacyPhase31NormalizedArtifact = ConvertTo-RelayHashtable -InputObject $legacyPhase31Normalization["artifact"]
    Assert-True ([bool]$legacyPhase31Normalization["changed"]) "Legacy Phase3-1 scalar evidence should be normalized before validation"
    Assert-Contains (@($legacyPhase31Normalization["warnings"]) -join "`n") "review_checks[0].evidence" "Phase3-1 normalization warnings should point to checklist evidence"
    Assert-True ($legacyPhase31NormalizedArtifact["review_checks"][0]["evidence"] -is [System.Collections.IEnumerable] -and -not ($legacyPhase31NormalizedArtifact["review_checks"][0]["evidence"] -is [string])) "Normalized Phase3-1 checklist evidence should become an array"
    $legacyPhase31Validation = Test-ArtifactContract -ArtifactId "phase3-1_verdict.json" -Artifact $legacyPhase31Verdict -Phase "Phase3-1"
    Assert-True ([bool]$legacyPhase31Validation["valid"]) "Legacy Phase3-1 scalar evidence should validate after normalization"
    $legacySnapshotRunId = "run-validation-snapshot"
    Write-RunState -ProjectRoot $tempArtifactRoot -RunState (New-RunState -RunId $legacySnapshotRunId -ProjectRoot $tempArtifactRoot -CurrentPhase "Phase3-1" -CurrentRole "reviewer") | Out-Null
    $legacySnapshotPath = Save-Artifact -ProjectRoot $tempArtifactRoot -RunId $legacySnapshotRunId -Scope run -Phase "Phase3-1" -ArtifactId "phase3-1_verdict.json" -Content $legacyPhase31Verdict -AsJson
    $legacySnapshotBefore = Get-Content -Path $legacySnapshotPath -Raw -Encoding UTF8
    $legacySnapshotValidation = ConvertTo-RelayHashtable -InputObject (Get-ArtifactRefValidationSnapshot -ProjectRoot $tempArtifactRoot -RunId $legacySnapshotRunId -ArtifactRef @{
        scope = "run"
        phase = "Phase3-1"
        artifact_id = "phase3-1_verdict.json"
    })
    Assert-True ([bool]$legacySnapshotValidation["validation"]["valid"]) "Artifact ref validation snapshot should validate legacy reviewer artifacts in memory"
    Assert-True ([bool]$legacySnapshotValidation["normalization"]["changed"]) "Artifact ref validation snapshot should report in-memory normalization"
    Assert-True ($legacySnapshotValidation["artifact"]["review_checks"][0]["evidence"] -is [System.Collections.IEnumerable] -and -not ($legacySnapshotValidation["artifact"]["review_checks"][0]["evidence"] -is [string])) "Artifact ref validation snapshot should expose normalized array fields without rewriting canonical JSON"
    $legacySnapshotStoredArtifact = Get-Content -Path $legacySnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($legacySnapshotStoredArtifact.review_checks[0].evidence -is [string]) "Read-only validation should not rewrite canonical reviewer artifacts on disk"
    Assert-Equal (Get-Content -Path $legacySnapshotPath -Raw -Encoding UTF8) $legacySnapshotBefore "Read-only validation should leave the stored artifact bytes unchanged"

    $legacyPhase51Verdict = [ordered]@{
        task_id = "T-legacy"
        verdict = "reject"
        rollback_phase = "Phase5"
        must_fix = "Repair the failed acceptance criterion"
        warnings = "Reviewer warning"
        evidence = "phase5_result.json"
        acceptance_criteria_checks = @(
            [ordered]@{
                criterion = "API exists"
                status = "fail"
                notes = "Acceptance criterion failed."
                evidence = "phase5_result.json"
            }
        )
        review_checks = Convert-EntryFieldToScalar -Entries (New-Phase51ReviewChecks -StatusOverrides @{
            changed_files_audit = "fail"
        })
    }
    $legacyPhase51Validation = Test-ArtifactContract -ArtifactId "phase5-1_verdict.json" -Artifact $legacyPhase51Verdict -Phase "Phase5-1"
    Assert-True ([bool]$legacyPhase51Validation["valid"]) "Legacy Phase5-1 scalar evidence should validate after normalization"
    Assert-Contains (@($legacyPhase51Validation["warnings"]) -join "`n") "acceptance_criteria_checks[0].evidence" "Phase5-1 normalization warnings should include acceptance criteria evidence"

    $legacyPhase7Verdict = [ordered]@{
        verdict = "conditional_go"
        rollback_phase = ""
        must_fix = "Address the final review issue"
        warnings = "Hold for a small follow-up"
        evidence = "phase7_pr_review.md"
        review_checks = Convert-EntryFieldToScalar -Entries (New-Phase7ReviewChecks -StatusOverrides @{
            maintainability = "warning"
        })
        human_review = [ordered]@{
            recommendation = "recommended"
            reasons = "Human spot-check before merge"
            focus_points = "Critical path behavior"
        }
        resolved_requirement_ids = "REQ-01"
        follow_up_tasks = [ordered]@{
            task_id = "T-fix"
            purpose = "Address the flagged issue"
            changed_files = "src/app.ts"
            acceptance_criteria = "Fix the flagged issue"
            depends_on = "T-01"
            verification = "npm test"
            source_evidence = "phase7_verdict.json"
        }
    }
    $legacyPhase7Validation = Test-ArtifactContract -ArtifactId "phase7_verdict.json" -Artifact $legacyPhase7Verdict -Phase "Phase7"
    Assert-True ([bool]$legacyPhase7Validation["valid"]) "Legacy Phase7 scalar arrays should validate after normalization"
    Assert-Contains (@($legacyPhase7Validation["warnings"]) -join "`n") "human_review.reasons" "Phase7 normalization warnings should include nested human_review arrays"

    $repairerClassifier = Resolve-OptionalFunction -Names @("Get-ArtifactRepairDecision", "Get-RepairableArtifactClassification")
    if ($repairerClassifier) {
        $semanticInvariantArtifact = @{
            task_id = "T-01"
            verdict = "conditional_go"
            rollback_phase = $null
            must_fix = @("Need remediation")
            warnings = @()
            evidence = @("phase5-2_security_check.md")
            security_checks = New-Phase52SecurityChecks -StatusOverrides @{
                dangerous_side_effects = "fail"
                dependency_surface = "warning"
            }
            open_requirements = @(New-Phase52OpenRequirements -TaskId "T-01")
            resolved_requirement_ids = @()
        }
        $semanticInvariantValidation = Test-ArtifactContract -ArtifactId "phase5-2_verdict.json" -Artifact $semanticInvariantArtifact -Phase "Phase5-2"

        $badJsonEscapeClassification = & $repairerClassifier.Name `
            -ArtifactId "phase7_verdict.json" `
            -Phase "Phase7" `
            -ValidationResult @{ errors = @("Invalid JSON escape sequence '\q'.") } `
            -MaterializationResult @{ errors = @() } `
            -ExecutionResult $null `
            -ArtifactOnlyRepair
        Assert-Equal ([string]$badJsonEscapeClassification["classification"]) "repairable" "Bad JSON escape should classify as repairable"
        Assert-Equal ([string]$badJsonEscapeClassification["reason"]) "bad_json_escape" "Bad JSON escape should report a focused repairability reason"

        $missingRequiredArtifactClassification = & $repairerClassifier.Name `
            -ArtifactId "phase7_verdict.json" `
            -Phase "Phase7" `
            -ValidationResult @{ errors = @("Required artifact 'phase7_verdict.json' was not produced.") } `
            -MaterializationResult @{ errors = @() } `
            -ExecutionResult $null `
            -ArtifactOnlyRepair
        Assert-Equal ([string]$missingRequiredArtifactClassification["classification"]) "not_repairable" "Missing required artifact should stay non-repairable"
        Assert-Equal ([string]$missingRequiredArtifactClassification["reason"]) "missing_required_artifact" "Missing required artifact should report a focused repairability reason"

        $semanticInvariantClassification = & $repairerClassifier.Name `
            -ArtifactId "phase5-2_verdict.json" `
            -Phase "Phase5-2" `
            -ValidationResult @{ errors = @($semanticInvariantValidation["errors"]) } `
            -MaterializationResult @{ errors = @() } `
            -ExecutionResult $null `
            -ArtifactOnlyRepair
        Assert-Equal ([string]$semanticInvariantClassification["classification"]) "repairable" "Semantic invariant violations should be repairable through the artifact repair pass"
        Assert-Equal ([string]$semanticInvariantClassification["reason"]) "semantic_invariant" "Semantic invariant violations should report a focused repairability reason"
    }
    else {
        Assert-Skipped "repairability classification scaffolding is waiting for Get-ArtifactRepairDecision"
    }

    $agentLoopText = Get-Content -Path (Join-Path $repoRoot "agent-loop.ps1") -Raw -Encoding UTF8
    Assert-Contains $agentLoopText '$null = & $AppCli resume -ConfigFile $ConfigFile -RunId $runId' "Agent loop should attempt auto-resume for failed runs"
    Assert-True ($agentLoopText -notmatch '\("completed",\s*"failed",\s*"blocked"\)') "Agent loop should not treat failed runs as immediately terminal"

    $immutableGuard = Resolve-OptionalFunction -Names @("Test-RepairDiffAllowed", "Test-ReviewerArtifactImmutableFields")
    if ($immutableGuard) {
        $priorReviewerArtifact = @{
            verdict = "reject"
            rollback_phase = "Phase5"
            security_checks = New-Phase52SecurityChecks -StatusOverrides @{
                input_validation = "pass"
                authentication_authorization = "warning"
                secret_handling_and_logging = "pass"
                dangerous_side_effects = "pass"
                dependency_surface = "pass"
            }
        }

        $reviewerArtifactWithImmutableChanges = @{
            verdict = "go"
            rollback_phase = $null
            security_checks = New-Phase52SecurityChecks -StatusOverrides @{
                input_validation = "pass"
                authentication_authorization = "pass"
                secret_handling_and_logging = "pass"
                dangerous_side_effects = "pass"
                dependency_surface = "pass"
            }
        }

        $immutableGuardResult = & $immutableGuard.Name -ArtifactId "phase5-2_verdict.json" -OriginalArtifact $priorReviewerArtifact -RepairedArtifact $reviewerArtifactWithImmutableChanges
        Assert-True (-not [bool]$immutableGuardResult["valid"]) "Reviewer immutable-field guard should reject verdict and rollback/security status rewrites"
        $immutableGuardErrors = @($immutableGuardResult["errors"]) -join "`n"
        Assert-Contains $immutableGuardErrors "verdict" "Immutable-field guard should mention verdict"
        Assert-Contains $immutableGuardErrors "rollback_phase" "Immutable-field guard should mention rollback_phase"
        Assert-Contains $immutableGuardErrors "security_checks[1].status" "Immutable-field guard should pinpoint the changed reviewer security status"
    }
    else {
        Assert-Skipped "immutable reviewer-field guard scaffolding is waiting for Test-RepairDiffAllowed"
    }

    $phaseDefinition = Get-PhaseDefinition -ProjectRoot $tempArtifactRoot -Phase "Phase6" -Provider "codex-cli"
    Assert-Equal $phaseDefinition["validator"]["artifact_id"] "phase6_result.json" "Phase definition should expose validator artifact id"
    Assert-True (@($phaseDefinition["transition_rules"]["reject"]) -contains "Phase5") "Phase6 definition should expose reject rollback targets"
    $phase0Definition = Get-PhaseDefinition -ProjectRoot $tempArtifactRoot -Phase "Phase0" -Provider "codex-cli"
    $phase0TaskInput = @($phase0Definition["input_contract"] | Where-Object { $_["scope"] -eq "external" -and $_["artifact_id"] -eq "task.md" })
    $phase0DesignInput = @($phase0Definition["input_contract"] | Where-Object { $_["scope"] -eq "external" -and $_["artifact_id"] -eq "DESIGN.md" })
    Assert-Equal $phase0TaskInput.Count 1 "Phase0 should auto-load tasks/task.md"
    Assert-Equal $phase0DesignInput.Count 1 "Phase0 should expose optional DESIGN.md input"
    $phase5Definition = Get-PhaseDefinition -ProjectRoot $tempArtifactRoot -Phase "Phase5" -Provider "codex-cli"
    $phase5TaskInput = @($phase5Definition["input_contract"] | Where-Object { $_["scope"] -eq "external" -and $_["artifact_id"] -eq "task.md" })
    $phase5DesignInput = @($phase5Definition["input_contract"] | Where-Object { $_["scope"] -eq "external" -and $_["artifact_id"] -eq "DESIGN.md" })
    $phase5ContextInput = @($phase5Definition["input_contract"] | Where-Object { $_["scope"] -eq "run" -and $_["artifact_id"] -eq "phase0_context.json" -and $_["phase"] -eq "Phase0" })
    $phase5TaskBreakdownInput = @($phase5Definition["input_contract"] | Where-Object { $_["scope"] -eq "run" -and $_["artifact_id"] -eq "phase4_tasks.json" -and $_["phase"] -eq "Phase4" })
    $phase3Definition = Get-PhaseDefinition -ProjectRoot $tempArtifactRoot -Phase "Phase3" -Provider "codex-cli"
    $phase3ReviewFeedback = @($phase3Definition["input_contract"] | Where-Object { $_["artifact_id"] -eq "phase3-1_verdict.json" -and $_["phase"] -eq "Phase3-1" })
    $phase3TaskScopedFeedback = @($phase3Definition["input_contract"] | Where-Object { $_["scope"] -eq "task" })
    $phase4Definition = Get-PhaseDefinition -ProjectRoot $tempArtifactRoot -Phase "Phase4" -Provider "codex-cli"
    $phase4ReviewFeedback = @($phase4Definition["input_contract"] | Where-Object { $_["artifact_id"] -eq "phase4-1_verdict.json" -and $_["phase"] -eq "Phase4-1" })
    $phase4TaskScopedFeedback = @($phase4Definition["input_contract"] | Where-Object { $_["scope"] -eq "task" })
    $phase5ReviewFeedback = @($phase5Definition["input_contract"] | Where-Object { $_["artifact_id"] -eq "phase5-2_verdict.json" -and $_["phase"] -eq "Phase5-2" })
    $phase5TestingFeedback = @($phase5Definition["input_contract"] | Where-Object { $_["artifact_id"] -eq "phase6_result.json" -and $_["phase"] -eq "Phase6" })
    Assert-Equal $phase5TaskInput.Count 1 "All phases should auto-load tasks/task.md"
    Assert-Equal $phase5DesignInput.Count 1 "All phases should expose optional DESIGN.md input"
    Assert-Equal $phase5ContextInput.Count 1 "Post-Phase0 phases should reference phase0_context.json from Phase0"
    Assert-Equal $phase5TaskBreakdownInput.Count 1 "Phase5 should resolve phase4_tasks.json from Phase4"
    Assert-Equal $phase3ReviewFeedback.Count 1 "Phase3 reruns should receive Phase3-1 reviewer verdict JSON as input"
    Assert-Equal $phase3TaskScopedFeedback.Count 0 "Run-scoped Phase3 should not receive task-scoped feedback inputs"
    Assert-Equal $phase4ReviewFeedback.Count 1 "Phase4 reruns should receive Phase4-1 reviewer verdict JSON as input"
    Assert-Equal $phase4TaskScopedFeedback.Count 0 "Run-scoped Phase4 should not receive task-scoped feedback inputs"
    Assert-Equal $phase5ReviewFeedback.Count 1 "Phase5 reruns should receive Phase5-2 reviewer verdict JSON as input"
    Assert-Equal $phase5TestingFeedback.Count 1 "Phase5 reruns should receive Phase6 reviewer result JSON as input"

    $implementerPrompt = Get-Content (Join-Path $repoRoot "app\prompts\system\implementer.md") -Raw
    Assert-Contains $implementerPrompt "reviewer feedback JSON such as" "Implementer prompt should instruct reruns to read reviewer feedback JSON when present"
}
finally {
    Remove-Item $tempArtifactRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[6/11] Testing remaining phase artifacts..."

$tempRemainingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-remaining-phases-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempRemainingRoot -Force | Out-Null
    $remainingRunId = "run-remaining-phases"
    $remainingState = New-RunState -RunId $remainingRunId -ProjectRoot $tempRemainingRoot -TaskId "req-rest" -CurrentPhase "Phase0" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $tempRemainingRoot -RunState $remainingState | Out-Null

    $phase0Write = Write-Phase0Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase0" -JsonContent @{
        project_summary = "Relay redesign"
        project_root = "C:/Projects/agent"
        framework_root = "C:/Projects/agent/relay-dev"
        constraints = @("PowerShell")
        available_tools = @("codex", "git")
        risks = @("migration")
        open_questions = @("none")
        design_inputs = @("DESIGN.md")
        visual_constraints = @("Keep the documented editorial spacing and accent colors.")
        task_fingerprint = "remaining-phases-fixture-fingerprint"
        task_path = "tasks/task.md"
        seed_created_at = "2026-04-23T00:00:00Z"
    }
    $phase1Write = Write-Phase1Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase1" -JsonContent @{
        goals = @("refresh system")
        non_goals = @("rewrite provider")
        user_stories = @("As a maintainer")
        acceptance_criteria = @("workflow runs")
        visual_acceptance_criteria = @("Updated screens follow the documented visual system.")
        assumptions = @("single repo")
        unresolved_questions = @()
    }
    $phase2Write = Write-Phase2Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase2" -JsonContent @{
        collected_evidence = @("README")
        decisions = @("use engine")
        unresolved_blockers = @("none")
        source_refs = @("docs")
        next_actions = @("phase3")
    }
    $phase31Write = Write-Phase31Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase3-1" -JsonContent @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("design reviewed")
        review_checks = New-Phase31ReviewChecks
    }
    $phase4Json = @{
        tasks = @(
            @{
                task_id = "T-01"
                purpose = "Implement API"
                changed_files = @("src/api.ts")
                acceptance_criteria = @("API exists")
                boundary_contract = (New-BoundaryContract)
                visual_contract = (New-VisualContract)
                dependencies = @()
                tests = @("npm test")
                complexity = "medium"
            }
        )
    }
    $phase4Write = Write-Phase4Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase4" -JsonContent $phase4Json
    $phase41Write = Write-Phase41Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase4-1" -JsonContent @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("tasks reviewed")
    }
    $phase5Write = Write-Phase5Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -TaskId "T-01" -MarkdownContent "# Phase5" -JsonContent @{
        task_id = "T-01"
        changed_files = @("src/api.ts")
        commands_run = @("npm test")
        implementation_summary = "implemented"
        acceptance_criteria_status = @("met")
        known_issues = @()
    }
    $phase51Write = Write-Phase51Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -TaskId "T-01" -MarkdownContent "# Phase5-1" -JsonContent @{
        task_id = "T-01"
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("checked")
        acceptance_criteria_checks = @(New-Phase51AcceptanceChecks)
        review_checks = New-Phase51ReviewChecks
    }
    $phase52Write = Write-Phase52Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -TaskId "T-01" -MarkdownContent "# Phase5-2" -JsonContent @{
        task_id = "T-01"
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("watch residual risk")
        warnings = @("minor risk")
        evidence = @("security checked")
        security_checks = New-Phase52SecurityChecks -StatusOverrides @{
            dependency_surface = "warning"
        }
        open_requirements = @(New-Phase52OpenRequirements -TaskId "T-01")
        resolved_requirement_ids = @()
    }
    $phase71Write = Write-Phase71Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase7-1" -JsonContent @{
        summary = "ready"
        merged_changes = @("api")
        task_results = @("T-01")
        residual_risks = @("minor")
        release_notes = @("v1")
    }
    $phase8Write = Write-Phase8Artifacts -ProjectRoot $tempRemainingRoot -RunId $remainingRunId -MarkdownContent "# Phase8" -JsonContent @{
        final_verdict = "ship"
        release_decision = "approved"
        residual_risks = @("minor")
        follow_up_actions = @("monitor")
    }

    $remainingArtifacts = @(
        @{ name = "phase0"; write = $phase0Write },
        @{ name = "phase1"; write = $phase1Write },
        @{ name = "phase2"; write = $phase2Write },
        @{ name = "phase31"; write = $phase31Write },
        @{ name = "phase4"; write = $phase4Write },
        @{ name = "phase41"; write = $phase41Write },
        @{ name = "phase5"; write = $phase5Write },
        @{ name = "phase51"; write = $phase51Write },
        @{ name = "phase52"; write = $phase52Write },
        @{ name = "phase71"; write = $phase71Write },
        @{ name = "phase8"; write = $phase8Write }
    )
    foreach ($artifactEntry in $remainingArtifacts) {
        $artifactWrite = $artifactEntry["write"]
        Assert-True ([bool]$artifactWrite["validation"]["valid"]) "Remaining phase artifact should validate: $($artifactEntry['name'])"
    }

    $invalidPhase51 = Test-ArtifactContract -ArtifactId "phase5-1_verdict.json" -Artifact @{
        task_id = "T-01"
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("checked")
        acceptance_criteria_checks = @(New-Phase51AcceptanceChecks -Status "pass")
        review_checks = New-Phase51ReviewChecks -StatusOverrides @{
            test_evidence_review = "fail"
        }
    } -Phase "Phase5-1"
    Assert-True (-not [bool]$invalidPhase51["valid"]) "go verdict with failed completion review check should be invalid"
    Assert-Contains ($invalidPhase51["errors"] -join "`n") "go verdict requires all completion checks to pass" "Phase5-1 validator should enforce fixed completion checks"

    $invalidPhase6 = Test-ArtifactContract -ArtifactId "phase6_result.json" -Artifact @{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 12
        tests_failed = 0
        coverage_line = 85
        coverage_branch = 77
        verdict = "conditional_go"
        rollback_phase = $null
        conditional_go_reasons = @("Coverage follow-up")
        verification_checks = New-Phase6VerificationChecks
        open_requirements = @()
        resolved_requirement_ids = @()
    } -Phase "Phase6"
    Assert-True (-not [bool]$invalidPhase6["valid"]) "conditional_go without warning verification check should be invalid"
    Assert-Contains ($invalidPhase6["errors"] -join "`n") "warning verification check" "Phase6 validator should enforce fixed verification checklist semantics"

    $invalidPhase6Reject = Test-ArtifactContract -ArtifactId "phase6_result.json" -Artifact @{
        task_id = "T-01"
        test_command = "npm test"
        lint_command = "npm run lint"
        tests_passed = 11
        tests_failed = 1
        coverage_line = 85
        coverage_branch = 77
        verdict = "reject"
        rollback_phase = $null
        conditional_go_reasons = @()
        verification_checks = New-Phase6VerificationChecks -StatusOverrides @{
            automated_tests = "fail"
        }
        open_requirements = @()
        resolved_requirement_ids = @()
    } -Phase "Phase6"
    Assert-True (-not [bool]$invalidPhase6Reject["valid"]) "reject without rollback_phase should be invalid"
    Assert-Contains ($invalidPhase6Reject["errors"] -join "`n") "rollback_phase" "Phase6 validator should require rollback_phase on reject"

    $invalidPhase52 = Test-ArtifactContract -ArtifactId "phase5-2_verdict.json" -Artifact @{
        task_id = "T-01"
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("watch residual risk")
        warnings = @("minor risk")
        evidence = @("security checked")
        security_checks = New-Phase52SecurityChecks -StatusOverrides @{
            dependency_surface = "warning"
        }
        open_requirements = @()
        resolved_requirement_ids = @()
    } -Phase "Phase5-2"
    Assert-True (-not [bool]$invalidPhase52["valid"]) "conditional_go without open_requirements should be invalid"
    Assert-Contains ($invalidPhase52["errors"] -join "`n") "open_requirements" "Phase5-2 validator should require tracked open requirements"

    Assert-True (Test-Path (Join-Path $tempRemainingRoot "outputs/req-rest/phase0_context.json")) "Phase0 compatibility projection should exist"
    Assert-True (Test-Path (Join-Path $tempRemainingRoot "outputs/req-rest/phase4_tasks.json")) "Phase4 compatibility projection should exist"
    Assert-True (Test-Path (Join-Path $tempRemainingRoot "outputs/req-rest/tasks/T-01/phase5_result.json")) "Phase5 task projection should exist"
    Assert-True (Test-Path (Join-Path $tempRemainingRoot "outputs/req-rest/phase8_release.json")) "Phase8 compatibility projection should exist"

    $invalidPhase4 = Test-ArtifactContract -ArtifactId "phase4_tasks.json" -Artifact @{
        tasks = @(
            @{
                task_id = "T-01"
                purpose = "dup"
                changed_files = @("a")
                acceptance_criteria = @("a")
                boundary_contract = (New-BoundaryContract -ModuleName "module/a" -PublicInterface "A" -AllowedDependency "a->b" -ForbiddenDependency "a->c" -SideEffectBoundary "A service" -StateOwner "A owner")
                visual_contract = (New-VisualContract -Mode "not_applicable")
                dependencies = @()
                tests = @()
                complexity = "small"
            },
            @{
                task_id = "T-01"
                purpose = "dup2"
                changed_files = @("b")
                acceptance_criteria = @("b")
                boundary_contract = (New-BoundaryContract -ModuleName "module/b" -PublicInterface "B" -AllowedDependency "b->c" -ForbiddenDependency "b->d" -SideEffectBoundary "B service" -StateOwner "B owner")
                visual_contract = (New-VisualContract -Mode "not_applicable")
                dependencies = @("T-99")
                tests = @()
                complexity = "small"
            }
        )
    } -Phase "Phase4"
    Assert-True (-not [bool]$invalidPhase4["valid"]) "Invalid Phase4 task artifact should fail validation"
    Assert-Contains ($invalidPhase4["errors"] -join "`n") "duplicate task_id" "Invalid Phase4 task artifact should report duplicate task ids"

    $phase8Definition = Get-PhaseDefinition -ProjectRoot $tempRemainingRoot -Phase "Phase8" -Provider "codex-cli"
    Assert-Equal $phase8Definition["validator"]["artifact_id"] "phase8_release.json" "Phase8 definition should expose validator artifact id"
}
finally {
    Remove-Item $tempRemainingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[7/11] Testing fake provider runner..."
. (Join-Path $repoRoot "app/execution/execution-runner.ps1")
. (Join-Path $repoRoot "app/core/workflow-engine.ps1")

$tempFakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-fake-provider-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempFakeRoot -Force | Out-Null
    $fakeRunState = New-RunState -RunId "run-fake-provider" -ProjectRoot $tempFakeRoot -TaskId "req-fake" -CurrentPhase "Phase1" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $tempFakeRoot -RunState $fakeRunState | Out-Null

    $successResult = Invoke-ExecutionRunner -JobSpec @{
        run_id = "run-fake-provider"
        job_id = "job-fake-success"
        phase = "Phase1"
        role = "implementer"
        provider = "fake-provider"
        fake_stdout = "fake success"
        fake_exit_code = 0
    } -PromptText "hello" -ProjectRoot $tempFakeRoot -WorkingDirectory $tempFakeRoot -TimeoutPolicy @{
        warn_after_sec = 0
        retry_after_sec = 0
        abort_after_sec = 0
        max_retries = 0
    }
    Assert-Equal $successResult["result_status"] "succeeded" "Fake provider success should be normalized as succeeded"
    Assert-Contains (Get-Content -Path $successResult["stdout_path"] -Raw -Encoding UTF8) "fake success" "Fake provider should write stdout log"
    $successJobMetadata = Read-JobMetadata -ProjectRoot $tempFakeRoot -RunId "run-fake-provider" -JobId "job-fake-success"
    Assert-Equal $successJobMetadata["status"] "finished" "Execution runner should persist finished job metadata"
    Assert-Equal $successJobMetadata["result_status"] "succeeded" "Finished job metadata should store normalized result status"

    $utf8Prompt = "勤怠シフト承認"
    $echoPromptResult = Invoke-ExecutionRunner -JobSpec @{
        run_id = "run-fake-provider"
        job_id = "job-fake-echo-prompt"
        phase = "Phase1"
        role = "implementer"
        provider = "fake-provider"
        fake_mode = "echo_prompt"
    } -PromptText $utf8Prompt -ProjectRoot $tempFakeRoot -WorkingDirectory $tempFakeRoot -TimeoutPolicy @{
        warn_after_sec = 0
        retry_after_sec = 0
        abort_after_sec = 0
        max_retries = 0
    }
    Assert-Equal $echoPromptResult["result_status"] "succeeded" "Fake provider prompt echo should succeed"
    Assert-Contains (Get-Content -Path $echoPromptResult["stdout_path"] -Raw -Encoding UTF8) "PROMPT:$utf8Prompt" "Execution runner should preserve UTF-8 prompt text through provider stdin"

    $failureResult = Invoke-ExecutionRunner -JobSpec @{
        run_id = "run-fake-provider"
        job_id = "job-fake-failure"
        phase = "Phase1"
        role = "implementer"
        provider = "fake-provider"
        fake_stderr = "fake failure"
        fake_mode = "failure"
    } -PromptText "hello" -ProjectRoot $tempFakeRoot -WorkingDirectory $tempFakeRoot -TimeoutPolicy @{
        warn_after_sec = 0
        retry_after_sec = 0
        abort_after_sec = 0
        max_retries = 0
    }
    Assert-Equal $failureResult["failure_class"] "provider_error" "Fake provider failure should map to provider_error"

    $startFailureResult = Invoke-ExecutionRunner -JobSpec @{
        run_id = "run-fake-provider"
        job_id = "job-start-failure"
        phase = "Phase1"
        role = "implementer"
        provider = "generic-cli"
        command = "C:\\definitely-missing\\relay-dev-provider.exe"
        flags = ""
    } -PromptText "hello" -ProjectRoot $tempFakeRoot -WorkingDirectory $tempFakeRoot -TimeoutPolicy @{
        warn_after_sec = 0
        retry_after_sec = 0
        abort_after_sec = 0
        max_retries = 0
    }
    Assert-Equal $startFailureResult["result_status"] "failed" "Start failures should return a failed execution result instead of throwing"
    Assert-Equal $startFailureResult["failure_class"] "provider_error" "Start failures should be classified as provider_error"
    $startFailureStderr = Get-Content -Path $startFailureResult["stderr_path"] -Raw -Encoding UTF8
    Assert-True ($startFailureStderr -match 'Exception calling "Start"|No such file or directory|cannot find|system cannot find|指定されたファイルが見つかりません') "Start failures should persist the process start error to stderr logs"

    $artifactRecoveryScriptPath = Join-Path $tempFakeRoot "artifact-recovery.ps1"
    $artifactRecoveryFlagPath = Join-Path $tempFakeRoot "artifact-recovery.flag"
    @"
Start-Sleep -Seconds 1
Set-Content -Path "$artifactRecoveryFlagPath" -Value "done" -Encoding UTF8
Start-Sleep -Seconds 30
"@ | Set-Content -Path $artifactRecoveryScriptPath -Encoding UTF8
    $artifactRecoveryProbe = {
        param($ProbeContext)

        if (Test-Path $artifactRecoveryFlagPath) {
            return @{
                detected = $true
                snapshot = "flag-ready"
            }
        }

        return @{
            detected = $false
        }
    }.GetNewClosure()
    $artifactRecoveryStartedAt = Get-Date
    $artifactRecoveryResult = Invoke-ExecutionRunner -JobSpec @{
        run_id = "run-fake-provider"
        job_id = "job-fake-artifact-recovery"
        phase = "Phase3"
        role = "implementer"
        provider = "generic-cli"
        command = $artifactRecoveryScriptPath
        flags = "--autopilot --yolo --max-autopilot-continues 30"
    } -PromptText "artifact recovery" -ProjectRoot $tempFakeRoot -WorkingDirectory $tempFakeRoot -TimeoutPolicy @{
        warn_after_sec = 0
        retry_after_sec = 0
        abort_after_sec = 0
        max_retries = 0
    } -ArtifactCompletionProbe $artifactRecoveryProbe -ArtifactCompletionStabilitySec 3
    $artifactRecoveryElapsedSec = [int]((Get-Date) - $artifactRecoveryStartedAt).TotalSeconds
    Assert-True ($artifactRecoveryElapsedSec -lt 15) "Execution runner should stop waiting once artifact completion is stable"
    Assert-Equal $artifactRecoveryResult["result_status"] "succeeded" "Artifact completion recovery should normalize the job to succeeded"
    Assert-True ([bool]$artifactRecoveryResult["recovered_from_artifacts"]) "Artifact completion recovery should report recovered_from_artifacts"
    Assert-Equal $artifactRecoveryResult["artifact_completion"]["snapshot"] "flag-ready" "Artifact completion recovery should preserve the confirmed snapshot"

    $staleState = New-RunState -RunId "run-fake-provider" -ProjectRoot $tempFakeRoot -CurrentPhase "Phase1" -CurrentRole "implementer"
    $staleState["active_job_id"] = "job-stale"
    Write-JobMetadata -ProjectRoot $tempFakeRoot -RunId "run-fake-provider" -JobId "job-stale" -Metadata @{
        run_id = "run-fake-provider"
        job_id = "job-stale"
        status = "running"
        pid = 999999
    } | Out-Null
    $repairedStale = Repair-StaleActiveJobState -RunState $staleState -ProjectRoot $tempFakeRoot
    Assert-True ([bool]$repairedStale["changed"]) "Repair-StaleActiveJobState should detect stale running jobs"
    Assert-Equal $repairedStale["run_state"]["active_job_id"] $null "Repair-StaleActiveJobState should clear stale active job ids"

    $missingMetadataState = New-RunState -RunId "run-fake-provider" -ProjectRoot $tempFakeRoot -CurrentPhase "Phase1" -CurrentRole "implementer"
    $missingMetadataState["active_job_id"] = "job-missing"
    $repairedMissingMetadata = Repair-StaleActiveJobState -RunState $missingMetadataState -ProjectRoot $tempFakeRoot
    Assert-True ([bool]$repairedMissingMetadata["changed"]) "Repair-StaleActiveJobState should recover when active job metadata is missing"
    Assert-Equal $repairedMissingMetadata["reason"] "missing_job_metadata" "Missing job metadata should surface an explicit stale recovery reason"
    Assert-Equal $repairedMissingMetadata["run_state"]["active_job_id"] $null "Missing job metadata recovery should clear active job ids"

    $dispatchedNoPidState = New-RunState -RunId "run-fake-provider" -ProjectRoot $tempFakeRoot -CurrentPhase "Phase1" -CurrentRole "implementer"
    $dispatchedNoPidState["active_job_id"] = "job-dispatched-no-pid"
    Write-JobMetadata -ProjectRoot $tempFakeRoot -RunId "run-fake-provider" -JobId "job-dispatched-no-pid" -Metadata @{
        run_id = "run-fake-provider"
        job_id = "job-dispatched-no-pid"
        status = "dispatched"
    } | Out-Null
    $repairedDispatchedNoPid = Repair-StaleActiveJobState -RunState $dispatchedNoPidState -ProjectRoot $tempFakeRoot
    Assert-True ([bool]$repairedDispatchedNoPid["changed"]) "Repair-StaleActiveJobState should clear dispatched jobs that never acquired a pid"
    Assert-Equal ([string]$repairedDispatchedNoPid["reason"]) "job_missing_pid" "Dispatched jobs without a pid should report a focused recovery reason"
}
finally {
    Remove-Item $tempFakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[8/11] Testing workflow engine and transition resolver..."
. (Join-Path $repoRoot "app/core/transition-resolver.ps1")
. (Join-Path $repoRoot "app/core/workflow-engine.ps1")

$tempEngineRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-engine-test-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempEngineRoot -Force | Out-Null

    $runId = "run-engine-test"
    $phase4Tasks = [ordered]@{
        tasks = @(
            @{
                task_id = "T-01"
                purpose = "Implement API"
                changed_files = @("src/api.ts")
                acceptance_criteria = @("API exists")
                boundary_contract = (New-BoundaryContract)
                visual_contract = (New-VisualContract)
                dependencies = @()
                tests = @("npm test")
                complexity = "medium"
            },
            @{
                task_id = "T-02"
                purpose = "Add null guard"
                changed_files = @("src/app.ts")
                acceptance_criteria = @("Null guard exists")
                boundary_contract = (New-BoundaryContract -ModuleName "application/guard" -PublicInterface "NullGuard.apply" -AllowedDependency "application/guard -> domain/guard" -ForbiddenDependency "application/guard -> infra/db direct" -SideEffectBoundary "No direct side effects outside GuardService" -StateOwner "GuardDecision state is owned by application/guard")
                visual_contract = (New-VisualContract -Mode "not_applicable")
                dependencies = @("T-01")
                tests = @("npm test")
                complexity = "small"
            }
        )
    }
    Save-Artifact -ProjectRoot $tempEngineRoot -RunId $runId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $phase4Tasks -AsJson | Out-Null
    Save-Artifact -ProjectRoot $tempEngineRoot -RunId $runId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json" -Content @{
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("Add null guard")
        warnings = @()
        evidence = @("src/app.ts:10")
        review_checks = New-Phase7ReviewChecks -StatusOverrides @{
            correctness_and_edge_cases = "warning"
        }
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @()
        follow_up_tasks = @(
            @{
                task_id = "pr_fixes"
                purpose = "Fix PR review issue"
                changed_files = @("src/app.ts")
                acceptance_criteria = @("Null guard added")
                depends_on = @()
                verification = @("npm test")
                source_evidence = @("src/app.ts:10")
            }
        )
    } -AsJson | Out-Null

    $runState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase4" -CurrentRole "implementer"
    $registered = Register-PlannedTasks -RunState $runState -TasksArtifact $phase4Tasks
    Assert-Equal $registered["task_states"]["T-01"]["status"] "ready" "Register-PlannedTasks should mark dependency-free tasks ready"
    Assert-Equal $registered["task_states"]["T-02"]["status"] "not_started" "Register-PlannedTasks should keep blocked tasks not_started"
    Assert-True ($registered["task_states"]["T-01"].ContainsKey("phase_cursor")) "New task states should include phase_cursor"
    Assert-True ($null -eq $registered["task_states"]["T-01"]["phase_cursor"]) "New task states should default phase_cursor to null"
    Assert-True ($registered["task_states"]["T-01"].ContainsKey("active_job_id")) "New task states should include active_job_id"
    Assert-True ($null -eq $registered["task_states"]["T-01"]["active_job_id"]) "New task states should default active_job_id to null"
    Assert-True ($registered["task_states"]["T-01"].ContainsKey("wait_reason")) "New task states should include wait_reason"
    Assert-True ($null -eq $registered["task_states"]["T-01"]["wait_reason"]) "New task states should default wait_reason to null"

    $selectedState = Set-RunStateCursor -RunState $registered -Phase "Phase5" -TaskId $null
    $nextAction = Get-NextAction -RunState $selectedState -ProjectRoot $tempEngineRoot
    Assert-Equal $nextAction["type"] "DispatchJob" "Get-NextAction should dispatch a task-scoped job"
    Assert-Equal $nextAction["task_id"] "T-01" "Get-NextAction should pick the first ready task"
    Assert-Equal $nextAction["selected_task"]["purpose"] "Implement API" "Get-NextAction should resolve selected_task from canonical artifact"
    Assert-True ($nextAction["selected_task"].ContainsKey("boundary_contract")) "Get-NextAction should preserve boundary_contract in selected_task"
    Assert-True ($nextAction["selected_task"].ContainsKey("visual_contract")) "Get-NextAction should preserve visual_contract in selected_task"

    $phase41State = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase4-1" -CurrentRole "reviewer"
    $phase41State = Register-PlannedTasks -RunState $phase41State -TasksArtifact $phase4Tasks
    $phase41Mutation = Apply-JobResult -RunState $phase41State -JobResult @{
        phase = "Phase4-1"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{ verdict = "go"; rollback_phase = $null } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase41Mutation["run_state"]["current_phase"] "Phase5" "Phase4-1 go should advance to Phase5"
    Assert-Equal $phase41Mutation["run_state"]["current_task_id"] "T-01" "Phase4-1 go should select the first ready task"

    $phase41ApprovalMutation = Apply-JobResult -RunState $phase41State -JobResult @{
        phase = "Phase4-1"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{ verdict = "go"; rollback_phase = $null } -ProjectRoot $tempEngineRoot -ApprovalPhases @("Phase4-1")
    Assert-Equal $phase41ApprovalMutation["action"]["type"] "RequestApproval" "Configured approval phases should request approval"
    Assert-Equal (@($phase41ApprovalMutation["run_state"]["pending_approval"]["allowed_reject_phases"]) -join ",") "Phase3,Phase4" "Approval request should preserve all valid reject targets"

    $phase41ConditionalApprovalMutation = Apply-JobResult -RunState $phase41State -JobResult @{
        phase = "Phase4-1"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @(
            "Tighten task selection guard",
            "Add regression coverage for reviewer must-fix carry-forward"
        )
        warnings = @("Task breakdown looks mostly sound but needs one more pass.")
        evidence = @("phase4 review evidence")
    } -ProjectRoot $tempEngineRoot -ApprovalPhases @("Phase4-1")
    Assert-Equal $phase41ConditionalApprovalMutation["action"]["type"] "RequestApproval" "conditional_go approval phases should still request approval"
    Assert-Contains $phase41ConditionalApprovalMutation["run_state"]["pending_approval"]["prompt_message"] "open_requirements" "conditional_go approval request should explain automatic carry-forward"
    Assert-Contains (@($phase41ConditionalApprovalMutation["run_state"]["pending_approval"]["blocking_items"]) -join "`n") "Tighten task selection guard" "conditional_go approval request should surface reviewer must-fix items"
    Assert-Equal @($phase41ConditionalApprovalMutation["run_state"]["pending_approval"]["carry_forward_requirements"]).Count 2 "conditional_go approval request should stage carry-forward requirements"

    $phase41ConditionalApproved = Apply-ApprovalDecision -RunState $phase41ConditionalApprovalMutation["run_state"] -ApprovalDecision @{
        decision = "approve"
    }
    Assert-Equal $phase41ConditionalApproved["run_state"]["current_phase"] "Phase4" "Approving conditional_go should resume the proposed Phase4 action"
    Assert-Equal @($phase41ConditionalApproved["run_state"]["open_requirements"]).Count 2 "Approving conditional_go should preserve reviewer must-fix items as open requirements"
    Assert-Equal $phase41ConditionalApproved["run_state"]["open_requirements"][0]["source_phase"] "Phase4-1" "Auto-carried requirements should keep the reviewer phase as source"
    Assert-Equal $phase41ConditionalApproved["run_state"]["open_requirements"][0]["verify_in_phase"] "Phase4" "Auto-carried requirements should target the resumed phase for verification"

    $phase1DirectState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase1" -CurrentRole "implementer"
    $phase1Direct = Apply-JobResult -RunState $phase1DirectState -JobResult @{
        phase = "Phase1"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        unresolved_questions = @()
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase1Direct["run_state"]["current_phase"] "Phase3" "Phase1 should skip Phase2 when unresolved_questions is empty"

    $phase1PlaceholderState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase1" -CurrentRole "implementer"
    $phase1Placeholder = Apply-JobResult -RunState $phase1PlaceholderState -JobResult @{
        phase = "Phase1"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        unresolved_questions = @("none")
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase1Placeholder["run_state"]["current_phase"] "Phase3" "Phase1 should ignore placeholder unresolved_questions values"

    $phase1FallbackState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase1" -CurrentRole "implementer"
    $phase1Fallback = Apply-JobResult -RunState $phase1FallbackState -JobResult @{
        phase = "Phase1"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        unresolved_questions = @("Need user choice for rollout strategy")
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase1Fallback["run_state"]["current_phase"] "Phase2" "Phase1 should route to Phase2 only when meaningful unresolved_questions remain"

    $phase2DirectState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase2" -CurrentRole "implementer"
    $phase2Direct = Apply-JobResult -RunState $phase2DirectState -JobResult @{
        phase = "Phase2"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        unresolved_blockers = @()
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase2Direct["run_state"]["current_phase"] "Phase3" "Phase2 should advance to Phase3 when unresolved_blockers is empty"

    $phase2PlaceholderState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase2" -CurrentRole "implementer"
    $phase2Placeholder = Apply-JobResult -RunState $phase2PlaceholderState -JobResult @{
        phase = "Phase2"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        unresolved_blockers = @("none")
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase2Placeholder["run_state"]["current_phase"] "Phase3" "Phase2 should ignore placeholder unresolved_blockers values"

    $phase2ClarificationState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase2" -CurrentRole "implementer"
    $phase2Clarification = Apply-JobResult -RunState $phase2ClarificationState -JobResult @{
        phase = "Phase2"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        unresolved_blockers = @("Choose rollout strategy for production cutover")
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase2Clarification["action"]["type"] "RequestApproval" "Phase2 should pause for clarification when unresolved_blockers remain"
    Assert-Equal $phase2Clarification["run_state"]["status"] "waiting_approval" "Phase2 clarification pause should persist waiting_approval state"
    Assert-Equal $phase2Clarification["run_state"]["pending_approval"]["requested_phase"] "Phase2" "Phase2 clarification pause should record Phase2 as the requested phase"
    Assert-Equal $phase2Clarification["run_state"]["pending_approval"]["proposed_action"]["phase"] "Phase0" "Phase2 clarification resume should restart from Phase0"
    Assert-Equal $phase2Clarification["run_state"]["pending_approval"]["approval_mode"] "clarification_questions" "Phase2 clarification pause should use the clarification approval mode"
    Assert-Contains $phase2Clarification["run_state"]["pending_approval"]["prompt_message"] "質問事項に回答してください" "Phase2 clarification pause should surface the question-answer prompt"
    Assert-Contains (@($phase2Clarification["run_state"]["pending_approval"]["blocking_items"]) -join "`n") "Choose rollout strategy" "Phase2 clarification pause should include unresolved blockers"

    $phase2ClarificationApproved = Apply-ApprovalDecision -RunState $phase2Clarification["run_state"] -ApprovalDecision @{
        decision = "approve"
    }
    Assert-Equal $phase2ClarificationApproved["run_state"]["current_phase"] "Phase0" "Approving Phase2 clarification should restart from Phase0"

    $transition = Resolve-Transition -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -Verdict "reject" -RollbackPhase "Phase6"
    Assert-True ([bool]$transition["valid"]) "Resolve-Transition should accept valid reject rollback"
    Assert-Equal $transition["next_phase"] "Phase6" "Resolve-Transition should return rollback phase"

    $phase6State = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase6" -CurrentRole "reviewer"
    $phase6State = Register-PlannedTasks -RunState $phase6State -TasksArtifact $phase4Tasks
    $phase6State["task_states"]["T-01"]["status"] = "in_progress"
    $phase6State["task_states"]["T-02"]["status"] = "ready"
    $phase6State["current_task_id"] = "T-01"
    $phase6Conditional = Apply-JobResult -RunState $phase6State -JobResult @{
        phase = "Phase6"
        task_id = "T-01"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        task_id = "T-01"
        verdict = "conditional_go"
        conditional_go_reasons = @("Coverage is low")
        open_requirements = @(New-Phase6OpenRequirements -TaskId "T-01")
        resolved_requirement_ids = @()
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase6Conditional["run_state"]["current_phase"] "Phase5" "Phase6 conditional_go should return to Phase5 when next task exists"
    Assert-Equal $phase6Conditional["run_state"]["current_task_id"] "T-02" "Phase6 conditional_go should move to the next ready task"
    Assert-Equal @($phase6Conditional["run_state"]["open_requirements"]).Count 1 "Phase6 conditional_go should register open requirements"

    $phase6Reject = Apply-JobResult -RunState $phase6State -JobResult @{
        phase = "Phase6"
        task_id = "T-01"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        task_id = "T-01"
        verdict = "reject"
        rollback_phase = "Phase5"
        open_requirements = @()
        resolved_requirement_ids = @()
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase6Reject["run_state"]["current_phase"] "Phase5" "Phase6 reject should rollback to the requested phase"
    Assert-Equal $phase6Reject["run_state"]["current_task_id"] "T-01" "Phase6 reject should keep the current task selected"

    $phase7GoBlockedState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -CurrentRole "reviewer"
    $phase7GoBlockedState["open_requirements"] = @(New-Phase6OpenRequirements -TaskId "T-01")
    $phase7GoBlocked = Apply-JobResult -RunState $phase7GoBlockedState -JobResult @{
        phase = "Phase7"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("reviewed")
        follow_up_tasks = @()
        review_checks = New-Phase7ReviewChecks
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @()
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase7GoBlocked["action"]["type"] "FailRun" "Phase7 go should fail when open requirements remain unresolved"
    Assert-Equal $phase7GoBlocked["action"]["reason"] "unresolved_open_requirements" "Phase7 go should surface unresolved open requirements"

    $phase7GoResolvedState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -CurrentRole "reviewer"
    $phase7GoResolvedState["open_requirements"] = @(New-Phase6OpenRequirements -TaskId "T-01")
    $phase7GoResolved = Apply-JobResult -RunState $phase7GoResolvedState -JobResult @{
        phase = "Phase7"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("reviewed")
        follow_up_tasks = @()
        review_checks = New-Phase7ReviewChecks
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @("TEST-01")
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase7GoResolved["run_state"]["current_phase"] "Phase7-1" "Phase7 go should advance once open requirements are resolved"
    Assert-Equal @($phase7GoResolved["run_state"]["open_requirements"]).Count 0 "Phase7 go should clear resolved open requirements"

    $repairBaseState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -CurrentRole "reviewer"
    $repairMutation = Apply-JobResult -RunState $repairBaseState -JobResult @{
        phase = "Phase7"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact (Read-Artifact -ProjectRoot $tempEngineRoot -RunId $runId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json") -ProjectRoot $tempEngineRoot
    Assert-Equal $repairMutation["run_state"]["current_phase"] "Phase5" "Phase7 conditional_go should move back to Phase5"
    Assert-Equal $repairMutation["run_state"]["current_task_id"] "pr_fixes" "Phase7 conditional_go should select spawned repair task"
    Assert-Equal $repairMutation["run_state"]["task_states"]["pr_fixes"]["kind"] "repair" "Phase7 conditional_go should register repair task state"

    $repairMutation["run_state"]["task_states"]["pr_fixes"]["status"] = "completed"
    $repairMutation["run_state"]["task_states"]["pr_fixes"]["last_completed_phase"] = "Phase6"
    $reSyncedRepairState = Register-RepairTasksFromVerdict -RunState $repairMutation["run_state"] -VerdictArtifact (Read-Artifact -ProjectRoot $tempEngineRoot -RunId $runId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json") -OriginPhase "Phase7"
    Assert-Equal $reSyncedRepairState["task_states"]["pr_fixes"]["status"] "completed" "Repair task sync should preserve existing completed status"
    Assert-Equal $reSyncedRepairState["task_states"]["pr_fixes"]["last_completed_phase"] "Phase6" "Repair task sync should preserve the last completed phase"

    $phase7Reject = Apply-JobResult -RunState (New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -CurrentRole "reviewer") -JobResult @{
        phase = "Phase7"
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact @{
        verdict = "reject"
        rollback_phase = "Phase3"
        must_fix = @("Revise design")
        warnings = @()
        evidence = @()
        review_checks = New-Phase7ReviewChecks -StatusOverrides @{
            correctness_and_edge_cases = "fail"
        }
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @()
        follow_up_tasks = @()
    } -ProjectRoot $tempEngineRoot
    Assert-Equal $phase7Reject["run_state"]["current_phase"] "Phase3" "Phase7 reject should rollback to the requested phase"

    $approvalState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -CurrentRole "reviewer"
    $approvalState["status"] = "waiting_approval"
    $approvalState["pending_approval"] = New-ApprovalRequest -ApprovalId "approval-1" -RequestedPhase "Phase7" -RequestedRole "reviewer" -ProposedAction @{
        type = "DispatchJob"
        phase = "Phase7-1"
        role = "implementer"
        task_id = $null
    } -AllowedRejectPhases @("Phase5", "Phase6")
    $approvalApplied = Apply-ApprovalDecision -RunState $approvalState -ApprovalDecision @{
        decision = "conditional_approve"
        must_fix = @(
            @{
                item_id = "AP-01"
                description = "Verify null guard"
                verify_in_phase = "Phase7-1"
                required_artifacts = @("phase7-1_summary.json")
            }
        )
    }
    Assert-Equal $approvalApplied["run_state"]["current_phase"] "Phase7-1" "conditional_approve should resume proposed action"
    Assert-Equal @($approvalApplied["run_state"]["open_requirements"]).Count 1 "conditional_approve should append open requirements"
    Assert-Equal $approvalApplied["run_state"]["open_requirements"][0]["source_phase"] "Phase7" "conditional_approve should normalize source_phase"

    $rejectApprovalState = New-RunState -RunId $runId -ProjectRoot $tempEngineRoot -CurrentPhase "Phase7" -CurrentRole "reviewer"
    $rejectApprovalState["status"] = "waiting_approval"
    $rejectApprovalState["pending_approval"] = New-ApprovalRequest -ApprovalId "approval-2" -RequestedPhase "Phase7" -RequestedRole "reviewer" -ProposedAction @{
        type = "DispatchJob"
        phase = "Phase7-1"
        role = "implementer"
        task_id = $null
    } -AllowedRejectPhases @("Phase5", "Phase6")
    $approvalRejected = Apply-ApprovalDecision -RunState $rejectApprovalState -ApprovalDecision @{
        decision = "reject"
        target_phase = "Phase6"
    }
    Assert-Equal $approvalRejected["run_state"]["current_phase"] "Phase6" "Reject approval should allow any configured rollback target"

    $invalidRejectThrew = $false
    try {
        $null = Apply-ApprovalDecision -RunState $rejectApprovalState -ApprovalDecision @{
            decision = "reject"
            target_phase = "Phase3"
        }
    }
    catch {
        $invalidRejectThrew = $true
        Assert-Contains $_.Exception.Message "Allowed phases" "Reject approval should explain allowed rollback targets"
    }
    Assert-True $invalidRejectThrew "Reject approval should fail for invalid rollback targets"
}
finally {
    Remove-Item $tempEngineRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[9/11] Testing workflow approval request action..."
. (Join-Path $repoRoot "app/approval/approval-manager.ps1")
. (Join-Path $repoRoot "app/approval/terminal-adapter.ps1")

$approvalRequestState = New-RunState -RunId "run-approval-action" -ProjectRoot $repoRoot -CurrentPhase "Phase7" -CurrentRole "reviewer"
$approvalRequestState["status"] = "waiting_approval"
$approvalRequestState["pending_approval"] = @{
    approval_id = "approval-queued"
    requested_phase = "Phase7"
    requested_role = "reviewer"
    requested_task_id = $null
    proposed_action = @{
        type = "DispatchJob"
        phase = "Phase7-1"
        role = "implementer"
        task_id = $null
    }
}
$approvalNextAction = Get-NextAction -RunState $approvalRequestState -ProjectRoot $repoRoot
Assert-Equal $approvalNextAction["type"] "RequestApproval" "waiting_approval state should return RequestApproval action"

Write-Host "[10/11] Testing phase prompt source-of-truth..."
$implementerSystemPromptPath = Join-Path $repoRoot "app\\prompts\\system\\implementer.md"
$reviewerSystemPromptPath = Join-Path $repoRoot "app\\prompts\\system\\reviewer.md"
$phase0PromptPath = Join-Path $repoRoot "app\\prompts\\phases\\phase0.md"
$implementerSystemPromptText = Get-Content -Path $implementerSystemPromptPath -Raw -Encoding UTF8
$reviewerSystemPromptText = Get-Content -Path $reviewerSystemPromptPath -Raw -Encoding UTF8
$phase0PromptText = Get-Content -Path $phase0PromptPath -Raw -Encoding UTF8
Assert-Contains $implementerSystemPromptText "write them in Japanese by default" "Implementer system prompt should require Japanese markdown outputs"
Assert-Contains $implementerSystemPromptText '`Selected Task` includes a `boundary_contract`' "Implementer system prompt should enforce task boundary contracts"
Assert-Contains $implementerSystemPromptText '`Selected Task` includes a `visual_contract`' "Implementer system prompt should enforce task visual contracts"
Assert-Contains $implementerSystemPromptText "Archived Phase JSON Context" "Implementer system prompt should describe archived phase rerun context"
Assert-Contains $reviewerSystemPromptText "write them in Japanese by default" "Reviewer system prompt should require Japanese markdown outputs"
Assert-Contains $reviewerSystemPromptText "Archived Phase JSON Context" "Reviewer system prompt should describe archived phase rerun context"
Assert-Contains $phase0PromptText "人間向けドキュメントとして日本語で記述すること" "Phase0 prompt should require Japanese markdown output"
Assert-Contains $phase0PromptText "design_inputs" "Phase0 prompt should capture design input summaries"

$phase7Definition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase7" -Provider "codex-cli"
$phase7PromptRef = [string]$phase7Definition["prompt_package"]["phase_prompt_ref"]
$expectedPhase7PromptRef = (Resolve-Path (Join-Path $repoRoot "app\\prompts\\phases\\phase7.md")).Path
Assert-Equal $phase7PromptRef $expectedPhase7PromptRef "Phase7 prompt should resolve from app/prompts/phases"
Assert-True (Test-Path $phase7PromptRef) "Resolved Phase7 prompt should exist"
$phase7PromptText = Get-Content -Path $phase7PromptRef -Raw -Encoding UTF8
Assert-Contains $phase7PromptText "前段 review を鵜呑みにせず、盲点を補うこと" "Phase7 prompt should preserve phase-specific review guidance"
Assert-Contains $phase7PromptText "review_checks[].evidence" "Phase7 prompt should require checklist evidence arrays explicitly"
Assert-Contains $phase7PromptText "human_review.reasons" "Phase7 prompt should require nested human review arrays explicitly"
Assert-True (-not $phase7PromptText.Contains("queue/status.yaml")) "Phase7 prompt should not expose queue/status.yaml instructions"
Assert-True (-not $phase7PromptText.Contains("assigned_to:")) "Phase7 prompt should not expose legacy YAML update lines"
Assert-True (-not $phase7PromptText.Contains("outputs/{要件名}")) "Phase7 prompt should not expose legacy output paths"
Assert-True (-not $phase7PromptText.Contains("Next task")) "Phase7 prompt should not expose legacy next-task control instructions"
Assert-Contains $phase7PromptText "follow_up_tasks" "Phase7 prompt should preserve repair-task contract guidance"
Assert-True (-not $phase7PromptText.Contains("conditional_go_log.md")) "Phase7 prompt should not require legacy conditional_go_log updates"

$phase3Definition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase3" -Provider "codex-cli"
$phase3PromptRef = [string]$phase3Definition["prompt_package"]["phase_prompt_ref"]
$phase3PromptText = Get-Content -Path $phase3PromptRef -Raw -Encoding UTF8
Assert-Contains $phase3PromptText "app/prompts/phases/examples/phase3_example.md" "Phase3 prompt should reference in-tree example guidance"
Assert-Contains $phase3PromptText "module_boundaries" "Phase3 prompt should require explicit module boundary design"
Assert-Contains $phase3PromptText "visual_contract" "Phase3 prompt should require explicit visual contracts"
Assert-Contains $phase3PromptText "{{VISUAL_CONTRACT_SCHEMA}}" "Phase3 prompt should source visual_contract schema from the shared template"
Assert-True (-not $phase3PromptText.Contains("templates/examples/phase3_example.md")) "Phase3 prompt should not reference templates examples"
$expandedPhase3PromptText = Expand-VisualContractPromptTemplates -Text $phase3PromptText
Assert-Contains $expandedPhase3PromptText '`component_patterns`: array' "Expanded Phase3 prompt should state that component_patterns must be an array"
Assert-Contains $expandedPhase3PromptText "連想オブジェクトは許可しない" "Expanded Phase3 prompt should forbid associative-object visual_contract output"
Assert-NotContains $expandedPhase3PromptText "配列またはオブジェクトのどちらでもよい" "Expanded Phase3 prompt should not preserve the ambiguous array-or-object guidance"

$phase4PromptDefinition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase4" -Provider "codex-cli"
$phase4PromptRef = [string]$phase4PromptDefinition["prompt_package"]["phase_prompt_ref"]
$phase4PromptText = Get-Content -Path $phase4PromptRef -Raw -Encoding UTF8
Assert-Contains $phase4PromptText "{{VISUAL_CONTRACT_SCHEMA}}" "Phase4 prompt should source visual_contract schema from the shared template"
$expandedPhase4PromptText = Expand-VisualContractPromptTemplates -Text $phase4PromptText
Assert-Contains $expandedPhase4PromptText '`responsive_expectations`: array' "Expanded Phase4 prompt should state that responsive_expectations must be an array"

$phase6Definition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase6" -Provider "codex-cli"
$phase6PromptRef = [string]$phase6Definition["prompt_package"]["phase_prompt_ref"]
$phase6PromptText = Get-Content -Path $phase6PromptRef -Raw -Encoding UTF8
Assert-Contains $phase6PromptText "app/prompts/phases/examples/phase6_example.md" "Phase6 prompt should reference in-tree example guidance"
Assert-True (-not $phase6PromptText.Contains("templates/examples/phase6_example.md")) "Phase6 prompt should not reference templates examples"
Assert-True (-not $phase6PromptText.Contains("conditional_go_log.md")) "Phase6 prompt should not require legacy conditional_go_log updates"
Assert-True (-not $phase6PromptText.Contains("T-XX_completed.md")) "Phase6 prompt should not require legacy task markers"
Assert-True (-not $phase6PromptText.Contains("pr_fixes")) "Phase6 prompt should not special-case a legacy repair-task id"
Assert-Contains $phase6PromptText "canonical な最終 verdict は engine" "Phase6 prompt should explain that canonical verdict ownership moved to the engine"
Assert-Contains $phase6PromptText "status を正直に書くこと" "Phase6 prompt should prioritize accurate checklist statuses over verdict matching"
Assert-Contains $phase6PromptText '`warning` を付けたのに `conditional_go_reasons=[]` や `open_requirements=[]` のままにしないこと' "Phase6 prompt should force carry-forward fields when warnings remain"

$phase5Definition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase5" -Provider "codex-cli"
$phase5PromptRef = [string]$phase5Definition["prompt_package"]["phase_prompt_ref"]
$phase5PromptText = Get-Content -Path $phase5PromptRef -Raw -Encoding UTF8
Assert-True (-not $phase5PromptText.Contains("fix_contract.yaml")) "Phase5 prompt should not require legacy repair fix contracts"
Assert-True (-not $phase5PromptText.Contains("task marker directory")) "Phase5 prompt should not self-select tasks from marker directories"
Assert-Contains $phase5PromptText "doc-only task や repo 外インフラ設定 task でも空配列にしてはいけない" "Phase5 prompt should require commands_run for documentation-only or infra-only tasks"

$phase51Definition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase5-1" -Provider "codex-cli"
$phase51PromptRef = [string]$phase51Definition["prompt_package"]["phase_prompt_ref"]
$phase51PromptText = Get-Content -Path $phase51PromptRef -Raw -Encoding UTF8
Assert-True (-not $phase51PromptText.Contains("fix_contract.yaml")) "Phase5-1 prompt should review repair tasks from Selected Task instead of legacy fix contracts"
Assert-Contains $phase51PromptText "差し戻し先: Phase5" "Phase5-1 prompt should only allow Phase5 as a reject target"
Assert-Contains $phase51PromptText "acceptance_criteria_checks[].evidence" "Phase5-1 prompt should require acceptance criteria evidence arrays explicitly"

$phase31Definition = Get-PhaseDefinition -ProjectRoot $repoRoot -Phase "Phase3-1" -Provider "codex-cli"
$phase31PromptRef = [string]$phase31Definition["prompt_package"]["phase_prompt_ref"]
$phase31PromptText = Get-Content -Path $phase31PromptRef -Raw -Encoding UTF8
Assert-Contains $phase31PromptText "review_checks[].evidence" "Phase3-1 prompt should require checklist evidence arrays explicitly"

$startAgentsShPath = Join-Path $repoRoot "start-agents.sh"
$startAgentsShText = Get-Content -Path $startAgentsShPath -Raw -Encoding UTF8
Assert-Contains $startAgentsShText "-Role orchestrator -ConfigFile" "Linux launcher should start the orchestrator worker"
Assert-Contains $startAgentsShText "-InteractiveApproval" "Linux launcher should enable interactive approval in the worker pane"
Assert-Contains $startAgentsShText "watch-run.ps1" "Linux launcher should start the monitor pane"
Assert-Contains $startAgentsShText "runs/current-run.json" "Linux launcher should check the canonical run pointer before status.yaml"
Assert-Contains $startAgentsShText 'RESUME_SOURCE" == "runs/current-run.json"' "Linux launcher should resume canonical runs without legacy phase overrides"
Assert-True (-not $startAgentsShText.Contains("-Role implementer")) "Linux launcher should no longer rely on implementer-only pane startup"
Assert-True (-not $startAgentsShText.Contains("-Role reviewer")) "Linux launcher should no longer rely on reviewer-only pane startup"

$startAgentsPs1Path = Join-Path $repoRoot "start-agents.ps1"
$startAgentsPs1Text = Get-Content -Path $startAgentsPs1Path -Raw -Encoding UTF8
Assert-Contains $startAgentsPs1Text "Get-CanonicalRunSummary" "Windows launcher should inspect canonical run state before legacy status.yaml"
Assert-Contains $startAgentsPs1Text '$resumeSource -eq "runs/current-run.json"' "Windows launcher should resume canonical runs without legacy phase overrides"
Assert-Contains $startAgentsPs1Text "#requires -Version 7.0" "Windows launcher should fail fast outside PowerShell 7"
Assert-Contains $startAgentsPs1Text '[Console]::InputEncoding=[System.Text.Encoding]::UTF8' "Windows launcher should seed worker terminals with UTF-8 encoding"
$executionRunnerPath = Join-Path $repoRoot "app/execution/execution-runner.ps1"
$executionRunnerText = Get-Content -Path $executionRunnerPath -Raw -Encoding UTF8
Assert-Contains $executionRunnerText "StandardInputEncoding" "Execution runner should opt into UTF-8 stdin when the runtime supports it"

Write-Host "[11/12] Testing engine-driven CLI step..."
$cliRunId = "run-cli-step-" + [guid]::NewGuid().ToString("N")
$cliSeedRunId = "run-cli-seed-" + [guid]::NewGuid().ToString("N")
$staleSeedRunId = "run-cli-stale-seed-" + [guid]::NewGuid().ToString("N")
$cliSpawnRunId = "run-cli-spawn-" + [guid]::NewGuid().ToString("N")
$cliInvalidPhase6RunId = "run-cli-phase6-invalid-" + [guid]::NewGuid().ToString("N")
$cliRecoverResumeRunId = "run-cli-resume-recover-" + [guid]::NewGuid().ToString("N")
$cliRecoverStepRunId = "run-cli-step-recover-" + [guid]::NewGuid().ToString("N")
$cliRecoverInvalidArtifactRunId = "run-cli-invalid-artifact-recover-" + [guid]::NewGuid().ToString("N")
$cliRecoverInvalidTransitionRunId = "run-cli-invalid-transition-recover-" + [guid]::NewGuid().ToString("N")
$cliNonRecoverableRunId = "run-cli-no-recover-" + [guid]::NewGuid().ToString("N")
$cliSyncRunId = "run-cli-sync-" + [guid]::NewGuid().ToString("N")
$currentRunPointerPath = Get-CurrentRunPointerPath -ProjectRoot $repoRoot
$originalPointerRaw = if (Test-Path $currentRunPointerPath) { Get-Content -Path $currentRunPointerPath -Raw -Encoding UTF8 } else { $null }
$cliOutputDir = Join-Path $repoRoot "outputs/req-cli-step"
$phase0SeedMarkdownPath = Join-Path $repoRoot "outputs/phase0_context.md"
$phase0SeedJsonPath = Join-Path $repoRoot "outputs/phase0_context.json"
$taskFilePath = Join-Path $repoRoot "tasks/task.md"
$originalPhase0SeedMarkdown = if (Test-Path $phase0SeedMarkdownPath) { Get-Content -Path $phase0SeedMarkdownPath -Raw -Encoding UTF8 } else { $null }
$originalPhase0SeedJson = if (Test-Path $phase0SeedJsonPath) { Get-Content -Path $phase0SeedJsonPath -Raw -Encoding UTF8 } else { $null }
$originalTaskFile = if (Test-Path $taskFilePath) { Get-Content -Path $taskFilePath -Raw -Encoding UTF8 } else { $null }

try {
    $seedRunState = New-RunState -RunId $cliSeedRunId -ProjectRoot $repoRoot -TaskId "req-cli-seed" -CurrentPhase "Phase0" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $repoRoot -RunState $seedRunState | Out-Null

    $pwshPath = (Get-Process -Id $PID).Path
    $cliScriptPath = Join-Path $repoRoot "app/cli.ps1"
    $configPath = Join-Path $repoRoot "config/settings.yaml"

    @'
# Phase0 Project Context

- Project name: Relay-Dev
- Summary: Seeded regression fixture
'@ | Set-Content -Path $phase0SeedMarkdownPath -Encoding UTF8
    @'
# Seeded Regression Task

Use the seeded Phase0 fixture.
'@ | Set-Content -Path $taskFilePath -Encoding UTF8
    $taskFingerprint = Get-TestFileSha256 -Path $taskFilePath
    @{
        project_summary = "Seeded regression fixture"
        project_root = $repoRoot
        framework_root = $repoRoot
        constraints = @("Keep CI deterministic")
        available_tools = @("pwsh", "fake-provider")
        risks = @("Seeded regression fixture risk")
        open_questions = @("Seeded regression fixture question")
        design_inputs = @("DESIGN.md")
        visual_constraints = @("Use the seeded design system when UI work exists.")
        task_fingerprint = $taskFingerprint
        task_path = $taskFilePath
        seed_created_at = "2026-04-23T00:00:00Z"
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $phase0SeedJsonPath -Encoding UTF8

    $seedStepRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $cliSeedRunId -Provider fake-provider
    $seedStepJson = @($seedStepRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $seedStep = ConvertTo-RelayHashtable -InputObject ($seedStepJson | ConvertFrom-Json)
    Assert-Equal $seedStep["action"]["type"] "SeedPhase0" "CLI step should seed Phase0 from outputs/phase0_context artifacts when available"
    Assert-Equal $seedStep["run_state"]["current_phase"] "Phase1" "Seeded Phase0 should advance directly to Phase1"
    $seedEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliSeedRunId | Where-Object { $_["type"] -eq "phase0.seeded" } | Select-Object -Last 1))
    Assert-Equal $seedEvent["task_fingerprint"] $taskFingerprint "Seeded Phase0 event should record the accepted task fingerprint"

    $staleSeedRunState = New-RunState -RunId $staleSeedRunId -ProjectRoot $repoRoot -TaskId "req-cli-stale-seed" -CurrentPhase "Phase0" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $repoRoot -RunState $staleSeedRunState | Out-Null
    Set-Content -Path $taskFilePath -Value "# Changed Seeded Regression Task`n" -Encoding UTF8
    $staleSeedRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $staleSeedRunId -Provider fake-provider 2>&1 | Out-String
    Assert-Contains $staleSeedRaw "Phase0 seed is stale or incomplete" "CLI step should reject stale Phase0 seeds when task.md changes"

    $cliRunState = New-RunState -RunId $cliRunId -ProjectRoot $repoRoot -TaskId "req-cli-step" -CurrentPhase "Phase4-1" -CurrentRole "reviewer"
    Write-RunState -ProjectRoot $repoRoot -RunState $cliRunState | Out-Null

    Save-Artifact -ProjectRoot $repoRoot -RunId $cliRunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content @{
        tasks = @(
            @{
                task_id = "T-01"
                purpose = "Implement API"
                changed_files = @("src/api.ts")
                acceptance_criteria = @("API exists")
                boundary_contract = (New-BoundaryContract)
                visual_contract = (New-VisualContract)
                dependencies = @()
                tests = @("npm test")
                complexity = "medium"
            }
        )
    } -AsJson | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliRunId -Scope run -Phase "Phase4-1" -ArtifactId "phase4-1_task_review.md" -Content "# Phase4-1 review" | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliRunId -Scope run -Phase "Phase4-1" -ArtifactId "phase4-1_verdict.json" -Content @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("tasks reviewed")
    } -AsJson | Out-Null
    $cliPhase41ProviderScriptPath = Join-Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRunId) "phase41-provider.ps1"
    @'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$prompt = [Console]::In.ReadToEnd()
$reviewMatch = [regex]::Match($prompt, '(?m)^- \[required\]\[run\]\[markdown\] phase4-1_task_review\.md => (?<path>.+?) \(write\)$')
$verdictMatch = [regex]::Match($prompt, '(?m)^- \[required\]\[run\]\[json\] phase4-1_verdict\.json => (?<path>.+?) \(write\)$')
if (-not $reviewMatch.Success -or -not $verdictMatch.Success) {
    throw 'Phase4-1 required outputs were not present in the prompt'
}
$reviewPath = $reviewMatch.Groups['path'].Value.Trim()
$verdictPath = $verdictMatch.Groups['path'].Value.Trim()
New-Item -ItemType Directory -Path (Split-Path -Parent $reviewPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $verdictPath) -Force | Out-Null
Set-Content -Path $reviewPath -Value '# Phase4-1 review' -Encoding UTF8
([ordered]@{
    verdict = 'go'
    rollback_phase = $null
    must_fix = @()
    warnings = @()
    evidence = @('tasks reviewed')
} | ConvertTo-Json -Depth 20) | Set-Content -Path $verdictPath -Encoding UTF8
Write-Output 'phase4-1 outputs written'
'@ | Set-Content -Path $cliPhase41ProviderScriptPath -Encoding UTF8

    $step1Raw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $cliRunId -Provider generic-cli -ProviderCommand $cliPhase41ProviderScriptPath
    $step1Json = @($step1Raw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $step1 = ConvertTo-RelayHashtable -InputObject ($step1Json | ConvertFrom-Json)
    Assert-Equal $step1["mutation_action"]["type"] "RequestApproval" "CLI step should request approval after Phase4-1 go"
    Assert-Equal $step1["run_state"]["status"] "waiting_approval" "CLI step should persist waiting_approval state"

    $cliPendingState = Read-RunState -ProjectRoot $repoRoot -RunId $cliRunId
    Assert-Equal $cliPendingState["pending_approval"]["requested_phase"] "Phase4-1" "CLI step should store pending approval for the completed reviewer phase"
    $cliStatusEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRunId | Where-Object { $_["type"] -eq "run.status_changed" } | Select-Object -Last 1))
    Assert-Equal @($cliStatusEvent["task_order"]).Count 1 "CLI run.status_changed should persist task order for replay"
    Assert-Equal $cliStatusEvent["pending_approval"]["requested_phase"] "Phase4-1" "CLI run.status_changed should persist pending approval details for replay"
    Assert-Equal @($cliStatusEvent["open_requirements"]).Count 0 "CLI run.status_changed should include open requirements even when empty"
    Assert-Equal $cliStatusEvent["task_states"]["T-01"]["task_contract_ref"]["item_id"] "T-01" "CLI run.status_changed should persist task state contract refs for replay"

    $step2Raw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $cliRunId -ApprovalDecisionJson 'y'
    $step2Json = @($step2Raw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $step2 = ConvertTo-RelayHashtable -InputObject ($step2Json | ConvertFrom-Json)
    Assert-Equal $step2["applied_action"]["phase"] "Phase5" "Approved CLI step should resume the proposed Phase5 action"

    $cliApprovedState = Read-RunState -ProjectRoot $repoRoot -RunId $cliRunId
    Assert-Equal $cliApprovedState["current_phase"] "Phase5" "Approval resolution should move the run to Phase5"
    Assert-Equal $cliApprovedState["current_task_id"] "T-01" "Approval resolution should preserve the selected task"
    Assert-True ($null -eq $cliApprovedState["pending_approval"]) "Approval resolution should clear pending_approval"
    $cliApprovedStatusEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRunId | Where-Object { $_["type"] -eq "run.status_changed" } | Select-Object -Last 1))
    Assert-Equal $cliApprovedStatusEvent["current_task_contract_ref"]["artifact_id"] "phase4_tasks.json" "CLI run.status_changed should include the current task contract ref once the run returns to a task-scoped phase"

    $cliSpawnState = New-RunState -RunId $cliSpawnRunId -ProjectRoot $repoRoot -TaskId "req-cli-spawn" -CurrentPhase "Phase7" -CurrentRole "reviewer"
    Write-RunState -ProjectRoot $repoRoot -RunState $cliSpawnState | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliSpawnRunId -Scope run -Phase "Phase7" -ArtifactId "phase7_pr_review.md" -Content "# Phase7 review" | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliSpawnRunId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json" -Content @{
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("Add a null guard before merge")
        warnings = @()
        evidence = @("src/app.ts:42")
        review_checks = New-Phase7ReviewChecks -StatusOverrides @{
            correctness_and_edge_cases = "warning"
        }
        human_review = (New-Phase7HumanReview)
        resolved_requirement_ids = @()
        follow_up_tasks = @(
            @{
                task_id = "repair-01"
                purpose = "Add a null guard"
                changed_files = @("src/app.ts")
                acceptance_criteria = @("Null guard is added")
                depends_on = @()
                verification = @("npm test")
                source_evidence = @("src/app.ts:42")
            }
        )
    } -AsJson | Out-Null
    $cliPhase7ProviderScriptPath = Join-Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliSpawnRunId) "phase7-provider.ps1"
    @'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$prompt = [Console]::In.ReadToEnd()
$reviewMatch = [regex]::Match($prompt, '(?m)^- \[required\]\[run\]\[markdown\] phase7_pr_review\.md => (?<path>.+?) \(write\)$')
$verdictMatch = [regex]::Match($prompt, '(?m)^- \[required\]\[run\]\[json\] phase7_verdict\.json => (?<path>.+?) \(write\)$')
if (-not $reviewMatch.Success -or -not $verdictMatch.Success) {
    throw 'Phase7 required outputs were not present in the prompt'
}
$reviewPath = $reviewMatch.Groups['path'].Value.Trim()
$verdictPath = $verdictMatch.Groups['path'].Value.Trim()
New-Item -ItemType Directory -Path (Split-Path -Parent $reviewPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $verdictPath) -Force | Out-Null
Set-Content -Path $reviewPath -Value '# Phase7 review' -Encoding UTF8
([ordered]@{
    verdict = 'conditional_go'
    rollback_phase = $null
    must_fix = @('Add a null guard before merge')
    warnings = @()
    evidence = @('src/app.ts:42')
    review_checks = @(
        [ordered]@{ check_id = 'requirements_alignment'; status = 'pass'; notes = 'phase7 requirements_alignment pass'; evidence = @('phase7:requirements_alignment') }
        [ordered]@{ check_id = 'correctness_and_edge_cases'; status = 'warning'; notes = 'phase7 correctness_and_edge_cases warning'; evidence = @('phase7:correctness_and_edge_cases') }
        [ordered]@{ check_id = 'security_and_privacy'; status = 'pass'; notes = 'phase7 security_and_privacy pass'; evidence = @('phase7:security_and_privacy') }
        [ordered]@{ check_id = 'test_quality'; status = 'pass'; notes = 'phase7 test_quality pass'; evidence = @('phase7:test_quality') }
        [ordered]@{ check_id = 'maintainability'; status = 'pass'; notes = 'phase7 maintainability pass'; evidence = @('phase7:maintainability') }
        [ordered]@{ check_id = 'performance_and_operations'; status = 'pass'; notes = 'phase7 performance_and_operations pass'; evidence = @('phase7:performance_and_operations') }
    )
    human_review = [ordered]@{
        recommendation = 'recommended'
        reasons = @('Human spot review is recommended for final sign-off.')
        focus_points = @('Critical issue handling')
    }
    resolved_requirement_ids = @()
    follow_up_tasks = @(
        [ordered]@{
            task_id = 'repair-01'
            purpose = 'Add a null guard'
            changed_files = @('src/app.ts')
            acceptance_criteria = @('Null guard is added')
            depends_on = @()
            verification = @('npm test')
            source_evidence = @('src/app.ts:42')
        }
    )
} | ConvertTo-Json -Depth 20) | Set-Content -Path $verdictPath -Encoding UTF8
Write-Output 'phase7 outputs written'
'@ | Set-Content -Path $cliPhase7ProviderScriptPath -Encoding UTF8

    $spawnStepRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $cliSpawnRunId -Provider generic-cli -ProviderCommand $cliPhase7ProviderScriptPath
    $spawnStepJson = @($spawnStepRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $spawnStep = ConvertTo-RelayHashtable -InputObject ($spawnStepJson | ConvertFrom-Json)
    Assert-Equal $spawnStep["mutation_action"]["type"] "RequestApproval" "CLI step should request approval after Phase7 conditional_go repair spawning"
    Assert-Equal $spawnStep["run_state"]["current_phase"] "Phase7" "Phase7 conditional_go should remain on Phase7 while approval is pending"
    Assert-Equal $spawnStep["mutation_action"]["pending_approval"]["proposed_action"]["phase"] "Phase5" "Phase7 conditional_go approval should propose the Phase5 repair step"
    Assert-Equal $spawnStep["mutation_action"]["pending_approval"]["proposed_action"]["task_id"] "repair-01" "Phase7 conditional_go approval should target the spawned repair task"
    $cliSpawnEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliSpawnRunId | Where-Object { $_["type"] -eq "task.spawned" } | Select-Object -Last 1))
    Assert-Equal $cliSpawnEvent["task_contract_ref"]["phase"] "Phase7" "CLI task.spawned should include the source phase in the task contract ref"
    Assert-Equal $cliSpawnEvent["task_contract_ref"]["artifact_id"] "phase7_verdict.json" "CLI task.spawned should include the verdict artifact in the task contract ref"
    Assert-Equal $cliSpawnEvent["task_contract_ref"]["item_id"] "repair-01" "CLI task.spawned should include the spawned task id in the task contract ref"
    Assert-Equal @(@($cliSpawnEvent["depends_on"]) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count 0 "CLI task.spawned should preserve repair task dependencies"

    $cliInvalidPhase6State = New-RunState -RunId $cliInvalidPhase6RunId -ProjectRoot $repoRoot -TaskId "req-cli-phase6-invalid" -CurrentPhase "Phase6" -CurrentRole "reviewer"
    $cliInvalidPhase6State["task_order"] = @("T-01")
    $cliInvalidPhase6State["task_states"]["T-01"] = New-TaskState -TaskId "T-01" -Status "ready" -Kind "planned" -OriginPhase "Phase4" -TaskContractRef @{
        phase = "Phase4"
        artifact_id = "phase4_tasks.json"
        item_id = "T-01"
    }
    $cliInvalidPhase6State["current_task_id"] = "T-01"
    Write-RunState -ProjectRoot $repoRoot -RunState $cliInvalidPhase6State | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliInvalidPhase6RunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content @{
        tasks = @(
            @{
                task_id = "T-01"
                purpose = "Implement API"
                changed_files = @("src/api.ts")
                acceptance_criteria = @("API exists")
                boundary_contract = (New-BoundaryContract)
                visual_contract = (New-VisualContract)
                dependencies = @()
                tests = @("npm test")
                complexity = "medium"
            }
        )
    } -AsJson | Out-Null

    $invalidPhase6StepRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $cliInvalidPhase6RunId -Provider fake-provider
    $invalidPhase6StepJson = @($invalidPhase6StepRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $invalidPhase6Step = ConvertTo-RelayHashtable -InputObject ($invalidPhase6StepJson | ConvertFrom-Json)
    Assert-Equal $invalidPhase6Step["mutation_action"]["type"] "FailRun" "CLI step should fail when Phase6 required artifacts are missing"
    Assert-Equal $invalidPhase6Step["mutation_action"]["reason"] "invalid_artifact" "CLI step should surface invalid_artifact when Phase6 validation fails"
    Assert-Equal @((Get-Events -ProjectRoot $repoRoot -RunId $cliInvalidPhase6RunId | Where-Object { $_["type"] -eq "task.completed" })).Count 0 "CLI should not append task.completed when Phase6 validation fails"

    $cliRecoverResumeState = New-RunState -RunId $cliRecoverResumeRunId -ProjectRoot $repoRoot -TaskId "req-cli-recover" -CurrentPhase "Phase3" -CurrentRole "implementer"
    $cliRecoverResumeState["status"] = "failed"
    $cliRecoverResumeState = Sync-RunStatePhaseHistory -RunState $cliRecoverResumeState
    Write-RunState -ProjectRoot $repoRoot -RunState $cliRecoverResumeState | Out-Null
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverResumeRunId -Event @{
        type = "run.status_changed"
        status = $cliRecoverResumeState["status"]
        current_phase = $cliRecoverResumeState["current_phase"]
        current_role = $cliRecoverResumeState["current_role"]
        current_task_id = $cliRecoverResumeState["current_task_id"]
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverResumeRunId -Event @{
        type = "run.failed"
        reason = "job_failed"
        failure_class = "provider_error"
    }

    $recoverResumeRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath resume -ConfigFile $configPath -RunId $cliRecoverResumeRunId
    $recoverResumeRunId = @($recoverResumeRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    Assert-Equal $recoverResumeRunId $cliRecoverResumeRunId "CLI resume should return the recovered run id"

    $cliRecoveredResumeState = Read-RunState -ProjectRoot $repoRoot -RunId $cliRecoverResumeRunId
    Assert-Equal $cliRecoveredResumeState["status"] "running" "CLI resume should recover retriable failed runs back to running"
    Assert-Equal @($cliRecoveredResumeState["phase_history"]).Count 2 "Recovered failed runs should append a new phase history entry for the retry"
    Assert-Equal $cliRecoveredResumeState["phase_history"][1]["phase"] "Phase3" "Recovered failed runs should retry the same phase"
    Assert-Equal $cliRecoveredResumeState["phase_history"][1]["agent"] "implementer" "Recovered failed runs should preserve the same role"
    $cliResumeRecoveryEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRecoverResumeRunId | Where-Object { $_["type"] -eq "run.recovered" } | Select-Object -Last 1))
    Assert-Equal $cliResumeRecoveryEvent["recovery_source"] "resume" "CLI resume should record the recovery source"
    Assert-Equal $cliResumeRecoveryEvent["failure_class"] "provider_error" "Recovered run events should preserve the original failure class"

    $cliRecoverStepState = New-RunState -RunId $cliRecoverStepRunId -ProjectRoot $repoRoot -TaskId "req-cli-recover-step" -CurrentPhase "Phase4-1" -CurrentRole "reviewer"
    $cliRecoverStepState["status"] = "failed"
    $cliRecoverStepState = Sync-RunStatePhaseHistory -RunState $cliRecoverStepState
    Write-RunState -ProjectRoot $repoRoot -RunState $cliRecoverStepState | Out-Null
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Event @{
        type = "run.status_changed"
        status = $cliRecoverStepState["status"]
        current_phase = $cliRecoverStepState["current_phase"]
        current_role = $cliRecoverStepState["current_role"]
        current_task_id = $cliRecoverStepState["current_task_id"]
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Event @{
        type = "run.failed"
        reason = "job_failed"
        failure_class = "provider_error"
    }
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content @{
        tasks = @(
            @{
                task_id = "T-99"
                purpose = "Retry task review"
                changed_files = @("src/retry.ts")
                acceptance_criteria = @("Retry path is reviewed")
                boundary_contract = (New-BoundaryContract -ModuleName "application/retry" -PublicInterface "RetryPath.review" -AllowedDependency "application/retry -> domain/retry" -ForbiddenDependency "application/retry -> infra/db direct" -SideEffectBoundary "Retry path side effects stay in RetryService" -StateOwner "RetryReview state is owned by application/retry")
                visual_contract = (New-VisualContract -Mode "not_applicable")
                dependencies = @()
                tests = @("npm test")
                complexity = "small"
            }
        )
    } -AsJson | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Scope run -Phase "Phase4-1" -ArtifactId "phase4-1_task_review.md" -Content "# Phase4-1 review retry" | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Scope run -Phase "Phase4-1" -ArtifactId "phase4-1_verdict.json" -Content @{
        verdict = "go"
        rollback_phase = $null
        must_fix = @()
        warnings = @()
        evidence = @("retry review")
    } -AsJson | Out-Null

    $recoverReviewPath = Get-ArtifactPath -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Scope run -Phase "Phase4-1" -ArtifactId "phase4-1_task_review.md"
    $recoverVerdictPath = Get-ArtifactPath -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId -Scope run -Phase "Phase4-1" -ArtifactId "phase4-1_verdict.json"
    $recoverPromptCapturePath = Join-Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId) "recover-phase41-prompt.txt"
    $recoverProviderScriptPath = Join-Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId) "recover-phase41-provider.ps1"
    $escapedRecoverPromptCapturePath = $recoverPromptCapturePath.Replace("'", "''")
    $escapedRecoverReviewPath = $recoverReviewPath.Replace("'", "''")
    $escapedRecoverVerdictPath = $recoverVerdictPath.Replace("'", "''")
    @'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$prompt = [Console]::In.ReadToEnd()
Set-Content -Path '__PROMPT_CAPTURE_PATH__' -Value $prompt -Encoding UTF8
$match = [regex]::Match($prompt, '(?m)^- \[archived\]\[run\]\[json\] phase4-1_verdict\.json => (?<path>.+?) \(latest snapshot: (?<snapshot>[^\)]+)\)$')
if (-not $match.Success) {
    throw 'Archived Phase JSON Context did not include phase4-1_verdict.json'
}
$reviewOutputMatch = [regex]::Match($prompt, '(?m)^- \[required\]\[run\]\[markdown\] phase4-1_task_review\.md => (?<path>.+?) \(write\)$')
if (-not $reviewOutputMatch.Success) {
    throw 'Required Outputs did not include phase4-1_task_review.md'
}
$verdictOutputMatch = [regex]::Match($prompt, '(?m)^- \[required\]\[run\]\[json\] phase4-1_verdict\.json => (?<path>.+?) \(write\)$')
if (-not $verdictOutputMatch.Success) {
    throw 'Required Outputs did not include phase4-1_verdict.json'
}
$reviewOutputPath = $reviewOutputMatch.Groups['path'].Value.Trim()
$verdictOutputPath = $verdictOutputMatch.Groups['path'].Value.Trim()
$reviewOutputDir = Split-Path -Parent $reviewOutputPath
if (-not (Test-Path $reviewOutputDir)) {
    New-Item -ItemType Directory -Path $reviewOutputDir -Force | Out-Null
}
$verdictOutputDir = Split-Path -Parent $verdictOutputPath
if (-not (Test-Path $verdictOutputDir)) {
    New-Item -ItemType Directory -Path $verdictOutputDir -Force | Out-Null
}
$archivedVerdictPath = $match.Groups['path'].Value.Trim()
$archivedVerdict = Get-Content -Path $archivedVerdictPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nextEvidence = @()
if ($null -ne $archivedVerdict.evidence) {
    $nextEvidence += @($archivedVerdict.evidence)
}
$nextEvidence += 'rerun-regenerated'
$nextVerdict = [ordered]@{
    verdict = [string]$archivedVerdict.verdict
    rollback_phase = $archivedVerdict.rollback_phase
    must_fix = @($archivedVerdict.must_fix)
    warnings = @($archivedVerdict.warnings)
    evidence = @($nextEvidence)
}
Set-Content -Path $reviewOutputPath -Value ('# Phase4-1 review rerun' + [Environment]::NewLine + [Environment]::NewLine + 'Archived snapshot: ' + $match.Groups['snapshot'].Value) -Encoding UTF8
$nextVerdict | ConvertTo-Json -Depth 20 | Set-Content -Path $verdictOutputPath -Encoding UTF8
Write-Output 'rerun regenerated phase4-1 artifacts'
'@.Replace('__PROMPT_CAPTURE_PATH__', $escapedRecoverPromptCapturePath) | Set-Content -Path $recoverProviderScriptPath -Encoding UTF8

    $recoverStepRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $configPath -RunId $cliRecoverStepRunId -Provider generic-cli -ProviderCommand $recoverProviderScriptPath
    $recoverStepJson = @($recoverStepRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $recoverStep = ConvertTo-RelayHashtable -InputObject ($recoverStepJson | ConvertFrom-Json)
    Assert-Equal $recoverStep["mutation_action"]["type"] "RequestApproval" "CLI step should recover retriable failed runs, archive stale outputs, and re-request approval for the rerun"
    $cliRecoveredStepState = Read-RunState -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId
    Assert-Equal $cliRecoveredStepState["status"] "waiting_approval" "Recovered failed step should continue the workflow instead of remaining failed"
    $cliStepRecoveryEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId | Where-Object { $_["type"] -eq "run.recovered" } | Select-Object -Last 1))
    Assert-Equal $cliStepRecoveryEvent["recovery_source"] "step" "CLI step should record when it recovered a failed run"
    $cliRecoverArchiveEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId | Where-Object { $_["type"] -eq "phase.artifacts_archived" } | Select-Object -Last 1))
    Assert-Equal $cliRecoverArchiveEvent["phase"] "Phase4-1" "Recovered reruns should archive the stale artifacts for the retried phase"
    $recoverPromptText = Get-Content -Path $recoverPromptCapturePath -Raw -Encoding UTF8
    Assert-Contains $recoverPromptText "## Archived Phase JSON Context" "Recovered rerun prompts should include archived JSON context"
    Assert-Contains $recoverPromptText "phase4-1_verdict.json" "Recovered rerun prompts should point the agent at the archived verdict JSON"
    Assert-True ($recoverPromptText -match '[\\/]+attempts[\\/]+attempt-\d{4}[\\/]') "Recovered rerun prompts should direct outputs into the attempt-scoped staging area"
    Assert-True (Test-Path $recoverReviewPath) "Committed canonical Phase4-1 review should exist after staged rerun commit"
    Assert-True (Test-Path $recoverVerdictPath) "Committed canonical Phase4-1 verdict should exist after staged rerun commit"
    if (Test-Path $recoverReviewPath) {
        Assert-Contains (Get-Content -Path $recoverReviewPath -Raw -Encoding UTF8) "# Phase4-1 review rerun" "Committed canonical Phase4-1 review should come from the staged rerun output"
    }
    if (Test-Path $recoverVerdictPath) {
        Assert-Contains (Get-Content -Path $recoverVerdictPath -Raw -Encoding UTF8) "rerun-regenerated" "Committed canonical Phase4-1 verdict should come from the staged rerun output"
    }

    $cliRecoverInvalidArtifactState = New-RunState -RunId $cliRecoverInvalidArtifactRunId -ProjectRoot $repoRoot -TaskId "req-cli-invalid-artifact-recover" -CurrentPhase "Phase5-2" -CurrentRole "reviewer"
    $cliRecoverInvalidArtifactState["status"] = "failed"
    $cliRecoverInvalidArtifactState["current_task_id"] = "T-02"
    $cliRecoverInvalidArtifactState = Sync-RunStatePhaseHistory -RunState $cliRecoverInvalidArtifactState
    Write-RunState -ProjectRoot $repoRoot -RunState $cliRecoverInvalidArtifactState | Out-Null
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverInvalidArtifactRunId -Event @{
        type = "run.status_changed"
        status = $cliRecoverInvalidArtifactState["status"]
        current_phase = $cliRecoverInvalidArtifactState["current_phase"]
        current_role = $cliRecoverInvalidArtifactState["current_role"]
        current_task_id = $cliRecoverInvalidArtifactState["current_task_id"]
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverInvalidArtifactRunId -Event @{
        type = "job.finished"
        job_id = "job-invalid-artifact-finished"
        phase = "Phase5-2"
        role = "reviewer"
        attempt = 1
        exit_code = 0
        failure_class = $null
        result_status = "succeeded"
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverInvalidArtifactRunId -Event @{
        type = "run.failed"
        reason = "invalid_artifact"
        failure_class = $null
    }

    $recoverInvalidArtifactRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath resume -ConfigFile $configPath -RunId $cliRecoverInvalidArtifactRunId
    $recoverInvalidArtifactRunId = @($recoverInvalidArtifactRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    Assert-Equal $recoverInvalidArtifactRunId $cliRecoverInvalidArtifactRunId "CLI resume should return the invalid-artifact recovery run id"

    $cliRecoveredInvalidArtifactState = Read-RunState -ProjectRoot $repoRoot -RunId $cliRecoverInvalidArtifactRunId
    Assert-Equal $cliRecoveredInvalidArtifactState["status"] "running" "CLI resume should recover invalid_artifact failures when the underlying job succeeded"
    Assert-True (@($cliRecoveredInvalidArtifactState["phase_history"]).Count -ge 2) "Recovered invalid_artifact runs should retain history and append a retry entry"
    $cliRecoveredInvalidArtifactLastPhase = ConvertTo-RelayHashtable -InputObject (@($cliRecoveredInvalidArtifactState["phase_history"])[-1])
    Assert-Equal $cliRecoveredInvalidArtifactLastPhase["phase"] "Phase5-2" "Recovered invalid_artifact runs should retry the same phase"
    Assert-Equal $cliRecoveredInvalidArtifactLastPhase["agent"] "reviewer" "Recovered invalid_artifact runs should preserve the same role"
    $cliInvalidArtifactRecoveryEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRecoverInvalidArtifactRunId | Where-Object { $_["type"] -eq "run.recovered" } | Select-Object -Last 1))
    Assert-Equal $cliInvalidArtifactRecoveryEvent["failure_reason"] "invalid_artifact" "Recovered invalid_artifact runs should preserve the original failure reason"
    Assert-Equal $cliInvalidArtifactRecoveryEvent["recovery_source"] "resume" "Recovered invalid_artifact runs should record the recovery source"

    $cliRecoverInvalidTransitionState = New-RunState -RunId $cliRecoverInvalidTransitionRunId -ProjectRoot $repoRoot -TaskId "req-cli-invalid-transition-recover" -CurrentPhase "Phase6" -CurrentRole "reviewer"
    $cliRecoverInvalidTransitionState["status"] = "failed"
    $cliRecoverInvalidTransitionState = Sync-RunStatePhaseHistory -RunState $cliRecoverInvalidTransitionState
    Write-RunState -ProjectRoot $repoRoot -RunState $cliRecoverInvalidTransitionState | Out-Null
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverInvalidTransitionRunId -Event @{
        type = "run.status_changed"
        status = $cliRecoverInvalidTransitionState["status"]
        current_phase = $cliRecoverInvalidTransitionState["current_phase"]
        current_role = $cliRecoverInvalidTransitionState["current_role"]
        current_task_id = $cliRecoverInvalidTransitionState["current_task_id"]
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverInvalidTransitionRunId -Event @{
        type = "job.finished"
        job_id = "job-invalid-transition-finished"
        phase = "Phase6"
        role = "reviewer"
        attempt = 1
        exit_code = 0
        failure_class = $null
        result_status = "succeeded"
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliRecoverInvalidTransitionRunId -Event @{
        type = "run.failed"
        reason = "invalid_transition"
        failure_class = $null
    }

    $recoverInvalidTransitionRaw = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath resume -ConfigFile $configPath -RunId $cliRecoverInvalidTransitionRunId
    $recoverInvalidTransitionRunId = @($recoverInvalidTransitionRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    Assert-Equal $recoverInvalidTransitionRunId $cliRecoverInvalidTransitionRunId "CLI resume should return the invalid-transition recovery run id"

    $cliRecoveredInvalidTransitionState = Read-RunState -ProjectRoot $repoRoot -RunId $cliRecoverInvalidTransitionRunId
    Assert-Equal $cliRecoveredInvalidTransitionState["status"] "running" "CLI resume should recover invalid_transition failures when the underlying job succeeded"
    Assert-True (@($cliRecoveredInvalidTransitionState["phase_history"]).Count -ge 2) "Recovered invalid_transition runs should retain history and append a retry entry"
    $cliRecoveredInvalidTransitionLastPhase = ConvertTo-RelayHashtable -InputObject (@($cliRecoveredInvalidTransitionState["phase_history"])[-1])
    Assert-Equal $cliRecoveredInvalidTransitionLastPhase["phase"] "Phase6" "Recovered invalid_transition runs should retry the same phase"
    Assert-Equal $cliRecoveredInvalidTransitionLastPhase["agent"] "reviewer" "Recovered invalid_transition runs should preserve the same role"
    $cliInvalidTransitionRecoveryEvent = ConvertTo-RelayHashtable -InputObject ((Get-Events -ProjectRoot $repoRoot -RunId $cliRecoverInvalidTransitionRunId | Where-Object { $_["type"] -eq "run.recovered" } | Select-Object -Last 1))
    Assert-Equal $cliInvalidTransitionRecoveryEvent["failure_reason"] "invalid_transition" "Recovered invalid_transition runs should preserve the original failure reason"
    Assert-Equal $cliInvalidTransitionRecoveryEvent["recovery_source"] "resume" "Recovered invalid_transition runs should record the recovery source"

    $cliNonRecoverableState = New-RunState -RunId $cliNonRecoverableRunId -ProjectRoot $repoRoot -TaskId "req-cli-no-recover" -CurrentPhase "Phase3" -CurrentRole "implementer"
    $cliNonRecoverableState["status"] = "failed"
    $cliNonRecoverableState = Sync-RunStatePhaseHistory -RunState $cliNonRecoverableState
    Write-RunState -ProjectRoot $repoRoot -RunState $cliNonRecoverableState | Out-Null
    Append-Event -ProjectRoot $repoRoot -RunId $cliNonRecoverableRunId -Event @{
        type = "run.status_changed"
        status = $cliNonRecoverableState["status"]
        current_phase = $cliNonRecoverableState["current_phase"]
        current_role = $cliNonRecoverableState["current_role"]
        current_task_id = $cliNonRecoverableState["current_task_id"]
    }
    Append-Event -ProjectRoot $repoRoot -RunId $cliNonRecoverableRunId -Event @{
        type = "run.failed"
        reason = "invalid_artifact"
        failure_class = $null
    }

    $null = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath resume -ConfigFile $configPath -RunId $cliNonRecoverableRunId
    $cliStillFailedState = Read-RunState -ProjectRoot $repoRoot -RunId $cliNonRecoverableRunId
    Assert-Equal $cliStillFailedState["status"] "failed" "CLI resume should not recover non-retriable failed runs"
    Assert-Equal @((Get-Events -ProjectRoot $repoRoot -RunId $cliNonRecoverableRunId | Where-Object { $_["type"] -eq "run.recovered" })).Count 0 "Non-retriable failures should not append run.recovered events"

    $cliSyncState = New-RunState -RunId $cliSyncRunId -ProjectRoot $repoRoot -TaskId "req-cli-sync" -CurrentPhase "Phase7" -CurrentRole "reviewer"
    Write-RunState -ProjectRoot $repoRoot -RunState $cliSyncState | Out-Null
    Save-Artifact -ProjectRoot $repoRoot -RunId $cliSyncRunId -Scope run -Phase "Phase7" -ArtifactId "phase7_verdict.json" -Content @{
        verdict = "conditional_go"
        rollback_phase = $null
        must_fix = @("Repair the approval edge case")
        warnings = "Reviewer warning"
        evidence = "src/approval.ts:18"
        review_checks = (Convert-EntryFieldToScalar -Entries (New-Phase7ReviewChecks -StatusOverrides @{
            correctness_and_edge_cases = "warning"
        }))
        human_review = @{
            recommendation = "recommended"
            reasons = "approval edge case remains"
            focus_points = "verify repair task registration"
        }
        resolved_requirement_ids = @()
        follow_up_tasks = @{
            task_id = "repair-sync"
            purpose = "Repair approval edge case"
            changed_files = "src/approval.ts"
            acceptance_criteria = "Repair task is registered from canonical Phase7 output"
            depends_on = ""
            verification = "npm test"
            source_evidence = "src/approval.ts:18"
        }
    } -AsJson | Out-Null
    $syncProbeScriptPath = Join-Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliSyncRunId) "sync-state-probe.ps1"
    @'
$null = . '__CLI_SCRIPT_PATH__' show -ConfigFile '__CONFIG_PATH__' -RunId '__RUN_ID__'
$state = Read-RunState -ProjectRoot $script:ProjectRoot -RunId '__RUN_ID__'
$synced = Sync-RunStateFromCanonicalArtifacts -RunId '__RUN_ID__' -RunState $state
$taskState = $null
if ($synced["task_states"].ContainsKey("repair-sync")) {
    $taskState = $synced["task_states"]["repair-sync"]
}
[ordered]@{
    has_repair_task = $null -ne $taskState
    task_state = $taskState
} | ConvertTo-Json -Depth 20 -Compress
'@.Replace('__CLI_SCRIPT_PATH__', $cliScriptPath.Replace("'", "''")).Replace('__CONFIG_PATH__', $configPath.Replace("'", "''")).Replace('__RUN_ID__', $cliSyncRunId) | Set-Content -Path $syncProbeScriptPath -Encoding UTF8
    $syncProbeRaw = & $pwshPath -NoLogo -NoProfile -File $syncProbeScriptPath
    $syncProbeJson = @($syncProbeRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1) | Select-Object -Last 1
    $syncProbe = ConvertTo-RelayHashtable -InputObject ($syncProbeJson | ConvertFrom-Json)
    Assert-True ([bool]$syncProbe["has_repair_task"]) "Sync-RunStateFromCanonicalArtifacts should register repair tasks from legacy Phase7 artifacts without rewriting canonical JSON"
    if ($syncProbe["task_state"]) {
        Assert-Equal $syncProbe["task_state"]["task_contract_ref"]["item_id"] "repair-sync" "Synced repair task should preserve the follow-up task id"
        Assert-Equal @(@($syncProbe["task_state"]["depends_on"]) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count 0 "Synced repair task should normalize empty depends_on into an empty dependency list"
    }
}
finally {
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliSeedRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $staleSeedRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliSpawnRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliInvalidPhase6RunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRecoverResumeRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRecoverStepRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRecoverInvalidArtifactRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliRecoverInvalidTransitionRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliNonRecoverableRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $cliSyncRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $cliOutputDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($null -ne $originalPhase0SeedMarkdown) {
        Set-Content -Path $phase0SeedMarkdownPath -Value $originalPhase0SeedMarkdown -Encoding UTF8
    }
    else {
        Remove-Item -Path $phase0SeedMarkdownPath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $originalPhase0SeedJson) {
        Set-Content -Path $phase0SeedJsonPath -Value $originalPhase0SeedJson -Encoding UTF8
    }
    else {
        Remove-Item -Path $phase0SeedJsonPath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $originalTaskFile) {
        Set-Content -Path $taskFilePath -Value $originalTaskFile -Encoding UTF8
    }
    else {
        Remove-Item -Path $taskFilePath -Force -ErrorAction SilentlyContinue
    }

    if ($null -ne $originalPointerRaw) {
        Set-Content -Path $currentRunPointerPath -Value $originalPointerRaw -Encoding UTF8
    }
    else {
        Remove-Item -Path $currentRunPointerPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[12/12] Testing CLI run lock contention across processes..."
$lockRunId = "run-cli-lock-" + [guid]::NewGuid().ToString("N")
$lockConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-lock-config-" + [guid]::NewGuid().ToString("N") + ".yaml")
$lockScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-lock-holder-" + [guid]::NewGuid().ToString("N") + ".ps1")
$lockStepProcess = $null

try {
    $lockRunState = New-RunState -RunId $lockRunId -ProjectRoot $repoRoot -TaskId "req-cli-lock" -CurrentPhase "Phase1" -CurrentRole "implementer"
    Write-RunState -ProjectRoot $repoRoot -RunState $lockRunState | Out-Null

    @'
lock:
  retry_count: 3
  retry_delay_ms: 100
  timeout_sec: 1
'@ | Set-Content -Path $lockConfigPath -Encoding UTF8

    @'
Start-Sleep -Seconds 3
Write-Output "lock-holder-finished"
'@ | Set-Content -Path $lockScriptPath -Encoding UTF8

    $pwshPath = (Get-Process -Id $PID).Path
    $cliScriptPath = Join-Path $repoRoot "app/cli.ps1"

    $lockStepStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $lockStepStartInfo.FileName = $pwshPath
    $lockStepStartInfo.UseShellExecute = $false
    $lockStepStartInfo.RedirectStandardOutput = $true
    $lockStepStartInfo.RedirectStandardError = $true
    foreach ($arg in @(
        "-NoLogo",
        "-NoProfile",
        "-File",
        $cliScriptPath,
        "step",
        "-ConfigFile",
        $lockConfigPath,
        "-RunId",
        $lockRunId,
        "-Prompt",
        "lock-regression",
        "-ProviderCommand",
        $lockScriptPath,
        "-ProviderFlags",
        "placeholder"
    )) {
        [void]$lockStepStartInfo.ArgumentList.Add($arg)
    }

    $lockStepProcess = [System.Diagnostics.Process]::Start($lockStepStartInfo)
    Start-Sleep -Milliseconds 1500
    Assert-True (-not $lockStepProcess.HasExited) "First CLI step should still be running before a competing step starts"

    $contendedStepOutput = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $lockConfigPath -RunId $lockRunId -Prompt "lock-regression" -ProviderCommand $lockScriptPath -ProviderFlags "placeholder" 2>&1 | Out-String
    $contendedStepExitCode = $LASTEXITCODE
    Assert-True ($contendedStepExitCode -ne 0) "Second CLI step should fail while the same run lock is held"
    Assert-Contains $contendedStepOutput "locked by another step" "Second CLI step should report run lock contention"

    $lockStepProcess.WaitForExit()
    $lockStepStdout = $lockStepProcess.StandardOutput.ReadToEnd()
    $lockStepStderr = $lockStepProcess.StandardError.ReadToEnd()
    Assert-Equal $lockStepProcess.ExitCode 0 "First CLI step should finish successfully after holding the lock"
    Assert-Contains $lockStepStdout '"result_status":"succeeded"' "First CLI step should still emit a successful result payload"
    Assert-True ([string]::IsNullOrWhiteSpace($lockStepStderr)) "First CLI step should not emit stderr during lock contention regression"

    $postLockStepOutput = & $pwshPath -NoLogo -NoProfile -File $cliScriptPath step -ConfigFile $lockConfigPath -RunId $lockRunId -Prompt "lock-regression" -ProviderCommand $lockScriptPath -ProviderFlags "placeholder" 2>&1 | Out-String
    $postLockStepExitCode = $LASTEXITCODE
    Assert-Equal $postLockStepExitCode 0 "CLI step should succeed again after the lock holder exits"
    Assert-Contains $postLockStepOutput '"result_status":"succeeded"' "CLI step should return success once the lock is released"
}
finally {
    if ($lockStepProcess -and -not $lockStepProcess.HasExited) {
        try {
            $lockStepProcess.Kill()
        }
        catch {
        }
    }
    if ($lockStepProcess) {
        $lockStepProcess.Dispose()
    }

    Remove-Item -Path (Get-RunRootPath -ProjectRoot $repoRoot -RunId $lockRunId) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $lockConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $lockScriptPath -Force -ErrorAction SilentlyContinue
}

Write-Host "[13/13] Testing reviewer prompt deduplication..."
$implementerPrompt = Get-Content -Path (Join-Path $repoRoot "app/prompts/system/implementer.md") -Raw
$reviewerPrompt = Get-Content -Path (Join-Path $repoRoot "app/prompts/system/reviewer.md") -Raw
$phase51Prompt = Get-Content -Path (Join-Path $repoRoot "app/prompts/phases/phase5-1.md") -Raw
$phase52Prompt = Get-Content -Path (Join-Path $repoRoot "app/prompts/phases/phase5-2.md") -Raw
$phase7Prompt = Get-Content -Path (Join-Path $repoRoot "app/prompts/phases/phase7.md") -Raw
$cliPromptSource = Get-Content -Path (Join-Path $repoRoot "app/cli.ps1") -Raw

Assert-Contains $implementerPrompt "keep framework prompt exploration scoped to the current phase prompt" "Implementer system prompt should scope framework prompt exploration to the active phase"
Assert-Contains $implementerPrompt "Do not enumerate or open unrelated framework prompt/example files" "Implementer system prompt should block unrelated prompt/example exploration"
Assert-Contains $implementerPrompt "Avoid repeated full reads of the same large artifact" "Implementer system prompt should discourage repeated full artifact reads"
Assert-Contains $implementerPrompt 'Do not add cross-module dependencies, public interfaces, side-effect paths, or state owners that are outside the `Selected Task` contract' "Implementer system prompt should prohibit boundary expansion beyond the task contract"
Assert-Contains $implementerPrompt 'Do not add new UI patterns, colors, typography rules, responsive behaviors, or interaction states that are outside the `Selected Task` visual contract' "Implementer system prompt should prohibit visual contract expansion beyond the task contract"
Assert-Contains $reviewerPrompt "## Review Posture" "Reviewer system prompt should define the shared review posture"
Assert-Contains $reviewerPrompt "## Evidence Rules" "Reviewer system prompt should define shared evidence rules"
Assert-Contains $reviewerPrompt "## Command Rules" "Reviewer system prompt should define shared command rules"
Assert-Contains $reviewerPrompt "Do not use watch mode" "Reviewer system prompt should ban watch mode centrally"
Assert-Contains $reviewerPrompt 'keep artifact exploration scoped to `## Input Artifacts`' "Reviewer system prompt should scope artifact exploration to declared inputs"
Assert-Contains $reviewerPrompt "Do not enumerate or open unrelated framework prompt/example files" "Reviewer system prompt should block unrelated prompt/example exploration"
Assert-Contains $reviewerPrompt "Avoid repeated full reads of the same artifact" "Reviewer system prompt should discourage repeated full artifact reads"

Assert-Contains $phase51Prompt "design_boundary_alignment" "Phase5-1 prompt should require explicit design boundary alignment checks"
Assert-Contains $phase51Prompt "visual_contract_alignment" "Phase5-1 prompt should require explicit visual contract alignment checks"
Assert-Contains $phase3PromptText "side_effect_boundaries" "Phase3 prompt should require explicit side-effect boundary design"
Assert-NotContains $phase51Prompt "## 対立レビュー原則" "Phase5-1 should no longer duplicate the adversarial review section"
Assert-NotContains $phase51Prompt "### 重要: 行番号根拠の取得（捏造防止）" "Phase5-1 should no longer duplicate line-number guidance"
Assert-NotContains $phase51Prompt "### 重要: テスト実行コマンド（Watchモード禁止）" "Phase5-1 should no longer duplicate watch-mode guidance"

Assert-NotContains $phase52Prompt "## 対立レビュー原則" "Phase5-2 should no longer duplicate the adversarial review section"
Assert-NotContains $phase52Prompt "### 重要: 根拠（行番号/差分）の取り方" "Phase5-2 should no longer duplicate line-number guidance"
Assert-Contains $phase52Prompt 'security_checks[].status` に `fail` が 1 件でもある場合、verdict は `reject`' "Phase5-2 prompt should explicitly align failed security checks with reject"
Assert-Contains $phase52Prompt 'conditional_go の場合は `security_checks[].status = fail` を含めない' "Phase5-2 prompt should explicitly forbid fail statuses on conditional_go"

Assert-NotContains $phase7Prompt "## 対立レビュー原則" "Phase7 should no longer duplicate the adversarial review section"
Assert-NotContains $phase7Prompt "## 行番号付き根拠の必須化（捏造防止）" "Phase7 should no longer duplicate line-number guidance"
Assert-Contains $phase7Prompt 'conditional_go`: 修正タスクを作れば進行可能。`must_fix` と `follow_up_tasks` をそれぞれ 1 件以上必須' "Phase7 prompt should require must_fix and follow_up_tasks for conditional_go"
Assert-Contains $phase7Prompt '`warnings[]` は non-blocker 専用' "Phase7 prompt should reserve warnings for non-blocking issues"
Assert-Contains $phase7Prompt '`conditional_go` を選ぶ場合、`must_fix.length >= 1`' "Phase7 prompt should include a conditional_go self-check for must_fix"
Assert-Contains $cliPromptSource '$promptLineBreak = "`n"' "CLI prompt builder should define a real newline separator"
Assert-Contains $cliPromptSource '-join $promptLineBreak' "CLI prompt builder should join contract lines with real newlines"
Assert-NotContains $cliPromptSource '-join ''`n''' "CLI prompt builder should not join contract lines with a literal backtick-n token"

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Regression tests failed: $($failures.Count)" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "All regression tests passed." -ForegroundColor Green
