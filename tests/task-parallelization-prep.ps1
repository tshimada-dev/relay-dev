$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\workflow-engine.ps1")
if (Test-Path (Join-Path $repoRoot "app\ui\task-lane-summary.ps1")) {
    . (Join-Path $repoRoot "app\ui\task-lane-summary.ps1")
}

$failures = New-Object System.Collections.Generic.List[string]
$skips = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $script:failures.Add($Message)
}

function Add-Skip {
    param([Parameter(Mandatory)][string]$Message)
    $script:skips.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        Add-Failure "$Message (expected='$Expected', actual='$Actual')"
    }
}

function Assert-HashtableKey {
    param(
        [Parameter(Mandatory)]$Hashtable,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True (($Hashtable -is [System.Collections.IDictionary]) -and $Hashtable.Contains($Key)) $Message
}

function Resolve-OptionalCommand {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command
        }
    }

    return $null
}

function Get-RequiredParameterNames {
    param([Parameter(Mandatory)]$Command)

    $required = New-Object System.Collections.Generic.List[string]
    foreach ($parameter in $Command.Parameters.GetEnumerator()) {
        foreach ($attribute in @($parameter.Value.Attributes)) {
            if ($attribute -is [System.Management.Automation.ParameterAttribute] -and $attribute.Mandatory) {
                $required.Add([string]$parameter.Key)
                break
            }
        }
    }

    return @($required.ToArray())
}

function Test-CommandSupportsOnlyKnownRequiredParameters {
    param(
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)][string[]]$KnownNames
    )

    $known = @{}
    foreach ($name in $KnownNames) {
        $known[$name] = $true
    }

    foreach ($name in @(Get-RequiredParameterNames -Command $Command)) {
        if (-not $known.ContainsKey($name)) {
            return $false
        }
    }

    return $true
}

function Invoke-OptionalLeaseCheck {
    param(
        [Parameter(Mandatory)][string]$TempRoot,
        [Parameter(Mandatory)]$RunState
    )

    $command = Resolve-OptionalCommand -Names @(
        "New-RunStateActiveJobLease",
        "Start-RunStateActiveJobLease",
        "Acquire-RunStateActiveJobLease",
        "Add-RunStateActiveJobLease"
    )

    if (-not $command) {
        Add-Skip "Lease creation helper is not present yet."
        return $RunState
    }

    $knownRequired = @("RunState", "ProjectRoot", "JobSpec", "JobId", "TaskId", "Phase", "Role", "LeaseOwner", "SlotId", "WorkspaceId")
    if (-not (Test-CommandSupportsOnlyKnownRequiredParameters -Command $command -KnownNames $knownRequired)) {
        Add-Skip "Lease creation helper '$($command.Name)' has required parameters this targeted script does not know how to fixture."
        return $RunState
    }

    $parameters = @{}
    foreach ($name in @($command.Parameters.Keys)) {
        switch ($name) {
            "RunState" { $parameters[$name] = $RunState }
            "ProjectRoot" { $parameters[$name] = $TempRoot }
            "JobSpec" { $parameters[$name] = @{ job_id = "job-lease-1"; task_id = "T-lease"; phase = "Phase5"; role = "implementer" } }
            "JobId" { $parameters[$name] = "job-lease-1" }
            "TaskId" { $parameters[$name] = "T-lease" }
            "Phase" { $parameters[$name] = "Phase5" }
            "Role" { $parameters[$name] = "implementer" }
            "LeaseOwner" { $parameters[$name] = "tests" }
            "SlotId" { $parameters[$name] = "slot-1" }
            "WorkspaceId" { $parameters[$name] = "workspace-main" }
        }
    }

    try {
        $leasedState = ConvertTo-RelayHashtable -InputObject (& $command @parameters)
        if ($leasedState.ContainsKey("run_state")) {
            $leasedState = ConvertTo-RelayHashtable -InputObject $leasedState["run_state"]
        }

        Assert-HashtableKey $leasedState "active_jobs" "Lease helper should return a state with active_jobs."
        Assert-True ($leasedState["active_jobs"].ContainsKey("job-lease-1") -or @($leasedState["active_jobs"].Keys).Count -eq 1) "Lease helper should create exactly one active job in sequential mode."

        $jobId = if ($leasedState["active_jobs"].ContainsKey("job-lease-1")) { "job-lease-1" } else { [string]@($leasedState["active_jobs"].Keys)[0] }
        $job = ConvertTo-RelayHashtable -InputObject $leasedState["active_jobs"][$jobId]
        foreach ($field in @("job_id", "task_id", "phase", "role", "lease_token", "lease_expires_at", "last_heartbeat_at", "lease_owner", "slot_id", "workspace_id", "state_revision")) {
            Assert-HashtableKey $job $field "Active job lease metadata should include '$field'."
        }

        if ($leasedState["task_states"].ContainsKey("T-lease")) {
            Assert-Equal $leasedState["task_states"]["T-lease"]["active_job_id"] $jobId "Lease helper should update task-local active_job_id."
        }

        return $leasedState
    }
    catch {
        Add-Failure "Lease creation helper '$($command.Name)' threw unexpectedly: $($_.Exception.Message)"
        return $RunState
    }
}

function Invoke-OptionalCommitFenceCheck {
    param([Parameter(Mandatory)]$RunState)

    $command = Resolve-OptionalCommand -Names @(
        "Test-RunStateActiveJobLease",
        "Test-RunStateCommitFence",
        "Test-ActiveJobCommitFence",
        "Assert-ActiveJobCommitFence",
        "Test-JobLeaseFence"
    )

    if (-not $command) {
        Add-Skip "Commit/lease fencing helper is not present yet."
        return
    }

    $jobId = "job-fence"
    $token = "token-ok"
    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $state["active_jobs"][$jobId] = [ordered]@{
        job_id = $jobId
        task_id = "T-fence"
        phase = "Phase5"
        role = "implementer"
        lease_token = $token
        leased_at = (Get-Date).AddMinutes(-1).ToString("o")
        lease_expires_at = (Get-Date).AddMinutes(10).ToString("o")
        last_heartbeat_at = (Get-Date).ToString("o")
        lease_owner = "tests"
        slot_id = "slot-1"
        workspace_id = "workspace-main"
        state_revision = [int]$state["state_revision"]
    }

    $knownRequired = @("RunState", "JobId", "LeaseToken", "Token", "Phase", "TaskId", "Now")
    if (-not (Test-CommandSupportsOnlyKnownRequiredParameters -Command $command -KnownNames $knownRequired)) {
        Add-Skip "Commit fencing helper '$($command.Name)' has required parameters this targeted script does not know how to fixture."
        return
    }

    $baseParameters = @{}
    foreach ($name in @($command.Parameters.Keys)) {
        switch ($name) {
            "RunState" { $baseParameters[$name] = $state }
            "JobId" { $baseParameters[$name] = $jobId }
            "LeaseToken" { $baseParameters[$name] = $token }
            "Token" { $baseParameters[$name] = $token }
            "Phase" { $baseParameters[$name] = "Phase5" }
            "TaskId" { $baseParameters[$name] = "T-fence" }
            "Now" { $baseParameters[$name] = Get-Date }
        }
    }

    try {
        $accepted = & $command @baseParameters
        $acceptedObject = ConvertTo-RelayHashtable -InputObject $accepted
        $acceptedValid = if ($acceptedObject -is [System.Collections.IDictionary] -and $acceptedObject.ContainsKey("valid")) { [bool]$acceptedObject["valid"] } else { [bool]$accepted }
        Assert-True $acceptedValid "Commit fencing helper should accept the matching active lease token."

        $mismatchParameters = @{}
        foreach ($entry in $baseParameters.GetEnumerator()) {
            $mismatchParameters[$entry.Key] = $entry.Value
        }
        if ($mismatchParameters.ContainsKey("LeaseToken")) {
            $mismatchParameters["LeaseToken"] = "token-stale"
        }
        if ($mismatchParameters.ContainsKey("Token")) {
            $mismatchParameters["Token"] = "token-stale"
        }

        $rejected = & $command @mismatchParameters
        $rejectedObject = ConvertTo-RelayHashtable -InputObject $rejected
        $rejectedValid = if ($rejectedObject -is [System.Collections.IDictionary] -and $rejectedObject.ContainsKey("valid")) { [bool]$rejectedObject["valid"] } else { [bool]$rejected }
        Assert-True (-not $rejectedValid) "Commit fencing helper should reject a mismatched lease token."
    }
    catch {
        Add-Failure "Commit fencing helper '$($command.Name)' threw unexpectedly: $($_.Exception.Message)"
    }
}

function Invoke-OptionalTaskLaneSummaryCheck {
    param([Parameter(Mandatory)]$RunState)

    $command = Resolve-OptionalCommand -Names @(
        "Get-TaskLaneSummary",
        "New-TaskLaneSummary",
        "Get-RunTaskLaneSummary"
    )

    if (-not $command) {
        Add-Skip "Task lane summary helper is not present yet."
        return
    }

    $knownRequired = @("RunState", "Events")
    if (-not (Test-CommandSupportsOnlyKnownRequiredParameters -Command $command -KnownNames $knownRequired)) {
        Add-Skip "Task lane summary helper '$($command.Name)' has required parameters this targeted script does not know how to fixture."
        return
    }

    $parameters = @{}
    foreach ($name in @($command.Parameters.Keys)) {
        switch ($name) {
            "RunState" { $parameters[$name] = $RunState }
            "Events" { $parameters[$name] = @() }
        }
    }

    try {
        $summary = ConvertTo-RelayHashtable -InputObject (& $command @parameters)
        Assert-True ($null -ne $summary) "Task lane summary helper should return a summary object."
        Assert-True ($summary.ContainsKey("active_jobs") -or $summary.ContainsKey("active_job_count")) "Task lane summary should expose active job information."
        Assert-True ($summary.ContainsKey("task_lane") -or $summary.ContainsKey("max_parallel_jobs")) "Task lane summary should expose task lane information."
    }
    catch {
        Add-Failure "Task lane summary helper '$($command.Name)' threw unexpectedly: $($_.Exception.Message)"
    }
}

function Invoke-OptionalApprovalLaneCheck {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    $state["pending_approval"] = New-ApprovalRequest `
        -ApprovalId "approval-test" `
        -RequestedPhase "Phase5-2" `
        -RequestedRole "reviewer" `
        -RequestedTaskId "T-approval" `
        -ProposedAction @{ type = "DispatchJob"; phase = "Phase6"; role = "reviewer"; task_id = "T-approval" } `
        -AllowedRejectPhases @("Phase5") `
        -PromptMessage "approval test"

    $command = Resolve-OptionalCommand -Names @(
        "Set-RunStateApprovalWait",
        "Set-TaskLaneApprovalWait",
        "Update-RunStateApprovalWait"
    )

    if (-not $command) {
        try {
            $approvalMutation = Apply-JobResult -RunState $RunState -JobResult @{
                phase = "Phase4-1"
                result_status = "succeeded"
                exit_code = 0
            } -ValidationResult @{ valid = $true } -Artifact @{ verdict = "go"; rollback_phase = $null } -ProjectRoot $ProjectRoot -ApprovalPhases @("Phase4-1")
            Assert-Equal ([bool]$approvalMutation["run_state"]["task_lane"]["stop_leasing"]) $true "Approval request should set task_lane.stop_leasing."

            $approvalResolved = Apply-ApprovalDecision -RunState $approvalMutation["run_state"] -ApprovalDecision @{
                decision = "approve"
            }
            Assert-Equal ([bool]$approvalResolved["run_state"]["task_lane"]["stop_leasing"]) $false "Approval resolution should clear task_lane.stop_leasing."
        }
        catch {
            Add-Failure "Approval stop_leasing integration check threw unexpectedly: $($_.Exception.Message)"
        }
        return
    }

    $knownRequired = @("RunState", "ApprovalRequest", "TaskId")
    if (-not (Test-CommandSupportsOnlyKnownRequiredParameters -Command $command -KnownNames $knownRequired)) {
        Add-Skip "Approval stop_leasing helper '$($command.Name)' has required parameters this targeted script does not know how to fixture."
        return
    }

    $parameters = @{}
    foreach ($name in @($command.Parameters.Keys)) {
        switch ($name) {
            "RunState" { $parameters[$name] = $state }
            "ApprovalRequest" { $parameters[$name] = $state["pending_approval"] }
            "TaskId" { $parameters[$name] = "T-approval" }
        }
    }

    try {
        $approvalState = ConvertTo-RelayHashtable -InputObject (& $command @parameters)
        if ($approvalState.ContainsKey("run_state")) {
            $approvalState = ConvertTo-RelayHashtable -InputObject $approvalState["run_state"]
        }

        Assert-Equal ([bool]$approvalState["task_lane"]["stop_leasing"]) $true "Approval wait should set task_lane.stop_leasing."
        if ($approvalState["task_states"].ContainsKey("T-approval")) {
            Assert-Equal $approvalState["task_states"]["T-approval"]["wait_reason"] "approval" "Approval wait should set task wait_reason to approval."
        }
    }
    catch {
        Add-Failure "Approval stop_leasing helper '$($command.Name)' threw unexpectedly: $($_.Exception.Message)"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-dev-tpp-tests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $runId = "run-tpp-prep"
    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -CurrentPhase "Phase4-1" -CurrentRole "reviewer"

    Assert-HashtableKey $state "active_jobs" "New-RunState should include active_jobs."
    Assert-Equal @($state["active_jobs"].Keys).Count 0 "New-RunState should initialize active_jobs as empty."
    Assert-HashtableKey $state "task_lane" "New-RunState should include task_lane."
    Assert-Equal $state["task_lane"]["mode"] "single" "New-RunState should default task_lane.mode to single."
    Assert-Equal ([int]$state["task_lane"]["max_parallel_jobs"]) 1 "New-RunState should default max_parallel_jobs to 1."
    Assert-Equal ([bool]$state["task_lane"]["stop_leasing"]) $false "New-RunState should default stop_leasing to false."
    Assert-Equal ([int]$state["state_revision"]) 0 "New-RunState should start state_revision at 0."

    Write-RunState -ProjectRoot $tempRoot -RunState $state | Out-Null
    $afterFirstWrite = Read-RunState -ProjectRoot $tempRoot -RunId $runId
    Assert-Equal ([int]$afterFirstWrite["state_revision"]) 1 "Write-RunState should increment state_revision on first write."

    Write-RunState -ProjectRoot $tempRoot -RunState $afterFirstWrite | Out-Null
    $afterSecondWrite = Read-RunState -ProjectRoot $tempRoot -RunId $runId
    Assert-Equal ([int]$afterSecondWrite["state_revision"]) 2 "Write-RunState should increment state_revision monotonically."

    $legacyState = @{
        run_id = "run-legacy"
        project_root = $tempRoot
        status = "running"
        current_phase = "Phase5"
        current_role = "implementer"
        current_task_id = "T-legacy"
        active_job_id = $null
        pending_approval = $null
        open_requirements = @()
        task_order = @("T-legacy")
        task_states = @{
            "T-legacy" = @{
                task_id = "T-legacy"
                status = "ready"
                kind = "planned"
                last_completed_phase = $null
                depends_on = @()
                origin_phase = "Phase4"
                task_contract_ref = @{ phase = "Phase4"; artifact_id = "phase4_tasks.json"; item_id = "T-legacy" }
            }
        }
        feedback = ""
        phase_history = @()
        created_at = (Get-Date).ToString("o")
        updated_at = (Get-Date).ToString("o")
    }
    $initializedLegacyState = Initialize-RunStateCompatibilityFields -RunState $legacyState
    $legacyTaskState = ConvertTo-RelayHashtable -InputObject $initializedLegacyState["task_states"]["T-legacy"]
    Assert-HashtableKey $legacyTaskState "phase_cursor" "Initialized task state should include phase_cursor."
    Assert-HashtableKey $legacyTaskState "active_job_id" "Initialized task state should include active_job_id."
    Assert-HashtableKey $legacyTaskState "wait_reason" "Initialized task state should include wait_reason."
    Assert-Equal $legacyTaskState["phase_cursor"] $null "Initialized phase_cursor should default to null."
    Assert-Equal $legacyTaskState["active_job_id"] $null "Initialized task active_job_id should default to null."
    Assert-Equal $legacyTaskState["wait_reason"] $null "Initialized wait_reason should default to null."

    $registeredState = Register-PlannedTasks -RunState $afterSecondWrite -TasksArtifact @{
        tasks = @(
            @{
                task_id = "T-cursor"
                title = "Task cursor fixture"
                dependencies = @()
                summary = "Fixture task for task-local cursor fields."
            }
        )
    }
    $registeredTask = ConvertTo-RelayHashtable -InputObject $registeredState["task_states"]["T-cursor"]
    Assert-HashtableKey $registeredTask "phase_cursor" "New task state should include phase_cursor."
    Assert-HashtableKey $registeredTask "active_job_id" "New task state should include active_job_id."
    Assert-HashtableKey $registeredTask "wait_reason" "New task state should include wait_reason."
    Assert-Equal $registeredTask["phase_cursor"] $null "New task phase_cursor should default to null."
    Assert-Equal $registeredTask["active_job_id"] $null "New task active_job_id should default to null."
    Assert-Equal $registeredTask["wait_reason"] $null "New task wait_reason should default to null."

    $cursorState = Set-RunStateCursor -RunState $registeredState -Phase "Phase5" -TaskId "T-cursor"
    Assert-Equal $cursorState["current_phase"] "Phase5" "Set-RunStateCursor should preserve task-scoped current_phase compatibility field."
    Assert-Equal $cursorState["current_task_id"] "T-cursor" "Set-RunStateCursor should preserve task-scoped current_task_id compatibility field."

    if ($cursorState["task_states"].ContainsKey("T-cursor")) {
        $cursorState["task_states"]["T-cursor"]["phase_cursor"] = "Phase5"
        Assert-Equal $cursorState["task_states"]["T-cursor"]["phase_cursor"] "Phase5" "Task phase_cursor should be writable on task state fixtures."
    }

    $leasedState = Invoke-OptionalLeaseCheck -TempRoot $tempRoot -RunState $cursorState
    Invoke-OptionalCommitFenceCheck -RunState $cursorState
    Invoke-OptionalTaskLaneSummaryCheck -RunState $leasedState
    Invoke-OptionalApprovalLaneCheck -RunState $cursorState -ProjectRoot $repoRoot
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}

if ($skips.Count -gt 0) {
    Write-Host "Skipped optional checks:" -ForegroundColor Yellow
    foreach ($skip in $skips) {
        Write-Host "  - $skip" -ForegroundColor Yellow
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-prep targeted tests failed:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-prep targeted tests passed." -ForegroundColor Green
exit 0
