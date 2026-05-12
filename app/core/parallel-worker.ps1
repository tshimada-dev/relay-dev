if (-not (Get-Command ConvertTo-RelayHashtable -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-state-store.ps1")
}
if (-not (Get-Command Acquire-RunLock -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "run-lock.ps1")
}
if (-not (Get-Command Append-Event -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "event-store.ps1")
}
if (-not (Get-Command Invoke-PhaseExecutionTransaction -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "phase-execution-transaction.ps1")
}
if (-not (Get-Command Resolve-PhaseContractArtifactPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "phase-validation-pipeline.ps1")
}
if (-not (Get-Command Apply-JobResult -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "workflow-engine.ps1")
}
if (-not (Get-Command Get-PhaseDefinition -ErrorAction SilentlyContinue)) {
    . (Join-Path (Join-Path $PSScriptRoot "..\phases") "phase-registry.ps1")
}
if (-not (Get-Command Assert-TaskGroupWorkerIsolation -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "task-group-worker-isolation.ps1")
}

function Append-LeasedJobRunStatusChangedEvent {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$RunState
    )

    if (Get-Command Append-RunStatusChangedEvent -ErrorAction SilentlyContinue) {
        Append-RunStatusChangedEvent -RunId $RunId -RunState $RunState
        return
    }

    $state = ConvertTo-RelayHashtable -InputObject $RunState
    Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
        type = "run.status_changed"
        status = $state["status"]
        current_phase = $state["current_phase"]
        current_role = $state["current_role"]
        current_task_id = $state["current_task_id"]
        active_job_id = $state["active_job_id"]
        active_attempt = (ConvertTo-RelayHashtable -InputObject $state["active_attempt"])
        pending_approval = (ConvertTo-RelayHashtable -InputObject $state["pending_approval"])
        open_requirements = @($state["open_requirements"])
        task_order = @($state["task_order"])
        task_states = (ConvertTo-RelayHashtable -InputObject $state["task_states"])
    }
}

function Import-LeasedJobPackage {
    param(
        [Parameter(Mandatory)]$Package
    )

    if ($Package -is [string]) {
        if (-not (Test-Path -LiteralPath $Package)) {
            throw "Job package file not found: $Package"
        }
        return (ConvertTo-RelayHashtable -InputObject (Get-Content -LiteralPath $Package -Raw -Encoding UTF8 | ConvertFrom-Json))
    }

    return (ConvertTo-RelayHashtable -InputObject $Package)
}

function Import-TaskGroupWorkerPackage {
    param(
        [Parameter(Mandatory)]$Package,
        [string]$WorkerId
    )

    $packageObject = Import-LeasedJobPackage -Package $Package
    if ([string]$packageObject["package_kind"] -eq "task-group-leased-package") {
        $isolationPaths = @(Get-TaskGroupWorkerPackageIsolationPaths -Workers @($packageObject["workers"]))
        foreach ($workerRaw in @($packageObject["workers"])) {
            $worker = ConvertTo-RelayHashtable -InputObject $workerRaw
            if ([string]::IsNullOrWhiteSpace($WorkerId) -or [string]$worker["worker_id"] -eq $WorkerId -or [string]$worker["id"] -eq $WorkerId) {
                foreach ($field in @("run_id", "group_id", "provider_spec", "workspace_mode", "commit_policy")) {
                    if (-not $worker.ContainsKey($field) -and $packageObject.ContainsKey($field)) {
                        $worker[$field] = $packageObject[$field]
                    }
                }
                $worker["_task_group_worker_isolation_paths"] = @($isolationPaths)
                return $worker
            }
        }
        throw "Worker '$WorkerId' was not found in task group package."
    }

    return $packageObject
}

function New-TaskGroupWorkerPromptText {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)]$PhaseDefinition,
        [AllowNull()]$WorkerPackage
    )

    $definition = ConvertTo-RelayHashtable -InputObject $PhaseDefinition
    $worker = ConvertTo-RelayHashtable -InputObject $WorkerPackage
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Run task group worker phase $PhaseName for task $TaskId.") | Out-Null
    if ($worker -and $worker["selected_task"]) {
        $lines.Add("Selected task: $((ConvertTo-RelayHashtable -InputObject $worker["selected_task"]) | ConvertTo-Json -Depth 20 -Compress)") | Out-Null
    }
    $lines.Add("Write the required output artifacts exactly at these paths:") | Out-Null
    foreach ($contractRaw in @($definition["output_contract"])) {
        $contract = ConvertTo-RelayHashtable -InputObject $contractRaw
        $artifactPath = Resolve-PhaseContractArtifactPath -ProjectRoot $ProjectRoot -RunId $RunId -PhaseName $PhaseName -ContractItem $contract -TaskId $TaskId -JobId $WorkerId -StorageScope "job"
        $lines.Add("$($contract["artifact_id"]) => $artifactPath (write)") | Out-Null
    }

    return ($lines.ToArray() -join "`n")
}

function Update-TaskGroupWorkerRunState {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)]$Patch,
        [int]$LockTimeoutSec = 30
    )

    $lock = $null
    try {
        $lock = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $RunId -RetryCount 0 -RetryDelayMs 200 -TimeoutSec $LockTimeoutSec
        $state = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
        if (-not $state) {
            throw "Run '$RunId' does not exist."
        }
        $state = Initialize-RunStateCompatibilityFields -RunState $state
        $workers = ConvertTo-RelayHashtable -InputObject $state["task_group_workers"]
        $entry = ConvertTo-RelayHashtable -InputObject $workers[$WorkerId]
        if (-not $entry) {
            $entry = [ordered]@{ id = $WorkerId; worker_id = $WorkerId }
        }

        $now = (Get-Date).ToString("o")
        foreach ($key in @($Patch.Keys)) {
            $entry[$key] = $Patch[$key]
        }
        $entry["updated_at"] = $now
        $entry["last_heartbeat_at"] = $now
        $workers[$WorkerId] = $entry
        $state["task_group_workers"] = $workers
        $state["updated_at"] = $now
        Write-RunState -ProjectRoot $ProjectRoot -RunState $state | Out-Null
        return $entry
    }
    finally {
        if ($lock) {
            Release-RunLock -LockHandle $lock
        }
    }
}

function Invoke-TaskGroupWorkerPackage {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$WorkerId,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [scriptblock]$PhaseDefinitionFactory,
        [scriptblock]$PromptFactory,
        [scriptblock]$TransactionFactory,
        [scriptblock]$ArtifactCompletionProbe,
        [int]$LockTimeoutSec = 30
    )

    $worker = Import-TaskGroupWorkerPackage -Package $Package -WorkerId $WorkerId
    $runId = [string]$worker["run_id"]
    $workerId = [string]$worker["worker_id"]
    if ([string]::IsNullOrWhiteSpace($workerId)) { $workerId = [string]$worker["id"] }
    $groupId = [string]$worker["group_id"]
    $taskId = [string]$worker["task_id"]
    if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($workerId) -or [string]::IsNullOrWhiteSpace($groupId) -or [string]::IsNullOrWhiteSpace($taskId)) {
        throw "Task group worker package requires run_id, worker_id, group_id, and task_id."
    }

    $phaseSequence = @($worker["phase_sequence"])
    if ($phaseSequence.Count -eq 0) {
        $phaseSequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
    }
    try {
        Assert-TaskGroupWorkerIsolation -Worker $worker -ProjectRoot $ProjectRoot -WorkerId $workerId
    }
    catch {
        Update-TaskGroupWorkerRunState -ProjectRoot $ProjectRoot -RunId $runId -WorkerId $workerId -LockTimeoutSec $LockTimeoutSec -Patch @{
            status = "failed"; current_phase = [string]$phaseSequence[0]; group_id = $groupId; task_id = $taskId
            errors = @($_.Exception.Message); result_summary = "failed"; artifact_refs = @()
        } | Out-Null
        throw
    }
    $workspacePath = [string]$worker["workspace_path"]
    $provider = ConvertTo-RelayHashtable -InputObject $worker["provider_spec"]
    $artifactRefs = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $finalPhase = $null

    Update-TaskGroupWorkerRunState -ProjectRoot $ProjectRoot -RunId $runId -WorkerId $workerId -LockTimeoutSec $LockTimeoutSec -Patch @{
        status = "running"; current_phase = [string]$phaseSequence[0]; group_id = $groupId; task_id = $taskId
        errors = @(); result_summary = $null; artifact_refs = @(); workspace_path = $workspacePath
    } | Out-Null

    foreach ($phaseName in $phaseSequence) {
        $finalPhase = [string]$phaseName
        Update-TaskGroupWorkerRunState -ProjectRoot $ProjectRoot -RunId $runId -WorkerId $workerId -LockTimeoutSec $LockTimeoutSec -Patch @{ status = "running"; current_phase = $finalPhase } | Out-Null

        try {
            $phaseDefinition = if ($PhaseDefinitionFactory) {
                & $PhaseDefinitionFactory $finalPhase $provider $worker
            }
            else {
                Get-PhaseDefinition -ProjectRoot $ProjectRoot -Phase $finalPhase -Provider ([string]$provider["provider"])
            }
            $phaseDefinition = ConvertTo-RelayHashtable -InputObject $phaseDefinition
            $promptText = if ($PromptFactory) {
                [string](& $PromptFactory $worker $finalPhase $phaseDefinition)
            }
            else {
                New-TaskGroupWorkerPromptText -ProjectRoot $ProjectRoot -RunId $runId -WorkerId $workerId -TaskId $taskId -PhaseName $finalPhase -PhaseDefinition $phaseDefinition -WorkerPackage $worker
            }
            $jobSpec = [ordered]@{
                run_id = $runId; job_id = $workerId; worker_id = $workerId; group_id = $groupId
                task_id = $taskId; phase = $finalPhase; role = if ($phaseDefinition["role"]) { [string]$phaseDefinition["role"] } else { "implementer" }
                attempt = 1; provider = [string]$provider["provider"]; command = [string]$provider["command"]; flags = [string]$provider["flags"]
                selected_task = (ConvertTo-RelayHashtable -InputObject $worker["selected_task"])
                workspace_path = $workspacePath; lease_token = [string]$worker["lease_token"]
            }
            $transaction = if ($TransactionFactory) {
                & $TransactionFactory $worker $finalPhase $phaseDefinition $promptText $jobSpec
            }
            else {
                $transactionParams = @{
                    JobSpec = $jobSpec; PromptText = $promptText; ProjectRoot = $ProjectRoot; WorkingDirectory = $workspacePath
                    TimeoutPolicy = $TimeoutPolicy; RunId = $runId; PhaseName = $finalPhase; PhaseDefinition = $phaseDefinition; TaskId = $taskId
                    PhaseStartedAtUtc = [datetime]::UtcNow; ArtifactStorageScope = "job"; CommitValidatedArtifacts = $false
                }
                if ($ArtifactCompletionProbe) { $transactionParams["ArtifactCompletionProbe"] = $ArtifactCompletionProbe }
                Invoke-PhaseExecutionTransaction @transactionParams
            }
            $transaction = ConvertTo-RelayHashtable -InputObject $transaction
            foreach ($artifactRef in @($transaction["artifact_refs"])) {
                $artifactRefs.Add((ConvertTo-RelayHashtable -InputObject $artifactRef)) | Out-Null
            }
            $validation = ConvertTo-RelayHashtable -InputObject $transaction["validation_result"]["validation"]
            $effective = ConvertTo-RelayHashtable -InputObject $transaction["effective_execution_result"]
            if (($effective -and [string]$effective["result_status"] -eq "failed") -or ($validation -and -not [bool]$validation["valid"])) {
                if ($effective -and $effective["failure_class"]) { $errors.Add([string]$effective["failure_class"]) | Out-Null }
                foreach ($error in @($validation["errors"])) { $errors.Add([string]$error) | Out-Null }
                break
            }
        }
        catch {
            $errors.Add($_.Exception.Message) | Out-Null
            break
        }
    }

    $status = if ($errors.Count -eq 0 -and $finalPhase -eq "Phase6") { "succeeded" } else { "failed" }
    $result = [ordered]@{
        worker_id = $workerId
        group_id = $groupId
        task_id = $taskId
        status = $status
        final_phase = $finalPhase
        errors = @($errors.ToArray())
        artifact_refs = @($artifactRefs.ToArray())
        changed_files = @($worker["declared_changed_files"])
        workspace_path = $workspacePath
        baseline_snapshot = if ($worker["baseline_snapshot"]) { ConvertTo-RelayHashtable -InputObject $worker["baseline_snapshot"] } else { $null }
    }
    Update-TaskGroupWorkerRunState -ProjectRoot $ProjectRoot -RunId $runId -WorkerId $workerId -LockTimeoutSec $LockTimeoutSec -Patch @{
        status = $status; current_phase = $finalPhase; result_summary = $status; errors = @($result["errors"]); artifact_refs = @($result["artifact_refs"])
        final_phase = $finalPhase; worker_result = $result
    } | Out-Null

    return $result
}

function New-LeasedJobCommitRejectedResult {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [string]$TaskId,
        [string]$Phase,
        [string]$LeaseToken,
        [string[]]$Errors = @(),
        [string]$Reason = "commit_fence_rejected"
    )

    return [ordered]@{
        ok = $false
        mode = "leased_job_worker"
        result = "commit_rejected"
        reason = $Reason
        run_id = $RunId
        job_id = $JobId
        task_id = if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId }
        phase = $Phase
        lease_token = $LeaseToken
        errors = @($Errors)
        exit_code = 20
        mutation_action = $null
    }
}

function Test-LeasedJobCommitFence {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$JobSpec,
        [AllowNull()]$Package
    )

    $state = Initialize-RunStateCompatibilityFields -RunState $RunState
    $job = ConvertTo-RelayHashtable -InputObject $JobSpec
    $packageObject = ConvertTo-RelayHashtable -InputObject $Package
    $jobId = [string]$job["job_id"]
    $leaseToken = [string]$job["lease_token"]
    $phase = [string]$job["phase"]
    $taskId = [string]$job["task_id"]
    $errors = New-Object System.Collections.Generic.List[string]

    $leaseResult = ConvertTo-RelayHashtable -InputObject (Test-RunStateActiveJobLease -RunState $state -JobId $jobId -LeaseToken $leaseToken -Phase $phase -TaskId $taskId)
    foreach ($error in @($leaseResult["errors"])) {
        $errors.Add([string]$error)
    }

    if ([string]$state["status"] -ne "running") {
        $errors.Add("run status '$($state['status'])' does not allow job commit for job '$jobId'")
    }

    $lease = ConvertTo-RelayHashtable -InputObject $leaseResult["lease"]
    if ($lease) {
        if ([string]$lease["job_id"] -ne $jobId) {
            $errors.Add("lease job_id mismatch for job '$jobId'")
        }

        $expectedLeaseRevision = $null
        foreach ($candidate in @($job["state_revision"], $packageObject["state_revision"], $packageObject["lease_state_revision"])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $parsed = 0
                if ([int]::TryParse([string]$candidate, [ref]$parsed)) {
                    $expectedLeaseRevision = $parsed
                    break
                }
            }
        }
        if ($null -ne $expectedLeaseRevision) {
            $leaseRevision = -1
            if (-not [int]::TryParse([string]$lease["state_revision"], [ref]$leaseRevision) -or $leaseRevision -ne $expectedLeaseRevision) {
                $errors.Add("lease state_revision mismatch for job '$jobId'")
            }

            $currentRevision = -1
            if ([int]::TryParse([string]$state["state_revision"], [ref]$currentRevision) -and $currentRevision -lt $expectedLeaseRevision) {
                $errors.Add("run state_revision is older than package revision for job '$jobId'")
            }
        }
    }

    return [ordered]@{
        valid = ($errors.Count -eq 0)
        errors = @($errors.ToArray())
        lease = $lease
        state_revision = $state["state_revision"]
    }
}

function Invoke-LeasedJobHeartbeatOnce {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$LeaseToken,
        [int]$LeaseDurationMinutes = 120,
        [int]$LockTimeoutSec = 30
    )

    $heartbeatLock = $null
    try {
        $heartbeatLock = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $RunId -RetryCount 0 -TimeoutSec $LockTimeoutSec
        $state = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
        if (-not $state) {
            return [ordered]@{ valid = $false; errors = @("run state not found") }
        }

        $heartbeat = ConvertTo-RelayHashtable -InputObject (Update-RunStateActiveJobHeartbeat -RunState $state -JobId $JobId -LeaseToken $LeaseToken -LeaseDurationMinutes $LeaseDurationMinutes)
        if ([bool]$heartbeat["valid"]) {
            Write-RunState -ProjectRoot $ProjectRoot -RunState $heartbeat["run_state"] | Out-Null
        }

        return $heartbeat
    }
    finally {
        if ($heartbeatLock) {
            Release-RunLock -LockHandle $heartbeatLock
        }
    }
}

function Start-LeasedJobHeartbeat {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$LeaseToken,
        [int]$IntervalSec = 30,
        [int]$LeaseDurationMinutes = 120
    )

    if ($IntervalSec -lt 1) {
        $IntervalSec = 30
    }

    $jobDir = Get-RunJobPath -ProjectRoot $ProjectRoot -RunId $RunId -JobId $JobId
    if (-not (Test-Path -LiteralPath $jobDir)) {
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    }
    $stopPath = Join-Path $jobDir "heartbeat.stop"
    if (Test-Path -LiteralPath $stopPath) {
        Remove-Item -LiteralPath $stopPath -Force
    }

    $coreRoot = $PSScriptRoot
    $heartbeatJob = Start-Job -ArgumentList @($coreRoot, $ProjectRoot, $RunId, $JobId, $LeaseToken, $IntervalSec, $LeaseDurationMinutes, $stopPath) -ScriptBlock {
        param($CoreRoot, $ProjectRoot, $RunId, $JobId, $LeaseToken, $IntervalSec, $LeaseDurationMinutes, $StopPath)

        $ErrorActionPreference = "Stop"
        . (Join-Path $CoreRoot "run-state-store.ps1")
        . (Join-Path $CoreRoot "run-lock.ps1")

        function Invoke-HeartbeatOnceInJob {
            $lock = $null
            try {
                $lock = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $RunId -RetryCount 0 -TimeoutSec 30
                $state = Read-RunState -ProjectRoot $ProjectRoot -RunId $RunId
                if (-not $state) {
                    return
                }

                $heartbeat = ConvertTo-RelayHashtable -InputObject (Update-RunStateActiveJobHeartbeat -RunState $state -JobId $JobId -LeaseToken $LeaseToken -LeaseDurationMinutes $LeaseDurationMinutes)
                if ([bool]$heartbeat["valid"]) {
                    Write-RunState -ProjectRoot $ProjectRoot -RunState $heartbeat["run_state"] | Out-Null
                }
            }
            catch {
            }
            finally {
                if ($lock) {
                    Release-RunLock -LockHandle $lock
                }
            }
        }

        Invoke-HeartbeatOnceInJob
        while (-not (Test-Path -LiteralPath $StopPath)) {
            Start-Sleep -Seconds $IntervalSec
            if (Test-Path -LiteralPath $StopPath) {
                break
            }
            Invoke-HeartbeatOnceInJob
        }
    }

    return [ordered]@{
        job = $heartbeatJob
        stop_path = $stopPath
        interval_sec = $IntervalSec
    }
}

function Stop-LeasedJobHeartbeat {
    param([AllowNull()]$Heartbeat)

    if (-not $Heartbeat) {
        return
    }

    $stopPath = $null
    $job = $null
    if ($Heartbeat -is [System.Collections.IDictionary]) {
        if ($Heartbeat.Contains("stop_path")) {
            $stopPath = [string]$Heartbeat["stop_path"]
        }
        if ($Heartbeat.Contains("job")) {
            $job = $Heartbeat["job"]
        }
    }
    else {
        if ($Heartbeat.PSObject.Properties.Name -contains "stop_path") {
            $stopPath = [string]$Heartbeat.stop_path
        }
        if ($Heartbeat.PSObject.Properties.Name -contains "job") {
            $job = $Heartbeat.job
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($stopPath)) {
        Set-Content -Path $stopPath -Value ((Get-Date).ToString("o")) -Encoding UTF8
    }

    if ($job) {
        try {
            Wait-Job -Job $job -Timeout 10 | Out-Null
        }
        catch {
        }
        try {
            if ($job.State -eq "Running") {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

function Invoke-LeasedJobPackageCloseout {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$JobSpec,
        [Parameter(Mandatory)]$TransactionResult,
        [string[]]$ApprovalPhases = @()
    )

    $jobSpec = ConvertTo-RelayHashtable -InputObject $JobSpec
    $transaction = ConvertTo-RelayHashtable -InputObject $TransactionResult
    $phaseName = [string]$jobSpec["phase"]
    $taskId = [string]$jobSpec["task_id"]
    $validationResult = ConvertTo-RelayHashtable -InputObject $transaction["validation_result"]
    $commitResult = ConvertTo-RelayHashtable -InputObject $transaction["commit_result"]
    $commitGuardResult = ConvertTo-RelayHashtable -InputObject $transaction["commit_guard_result"]
    $effectiveExecutionResult = ConvertTo-RelayHashtable -InputObject $transaction["effective_execution_result"]
    $effectiveExecutionResult["phase"] = $phaseName
    $effectiveExecutionResult["role"] = [string]$jobSpec["role"]
    $effectiveExecutionResult["task_id"] = $taskId
    $effectiveExecutionResult["lease_token"] = [string]$jobSpec["lease_token"]

    if ($validationResult["validator_ref"]) {
        $validatorRef = ConvertTo-RelayHashtable -InputObject $validationResult["validator_ref"]
        $validatorStatus = ConvertTo-RelayHashtable -InputObject $validationResult["validation"]
        Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
            type = "artifact.validated"
            phase = $phaseName
            task_id = $taskId
            artifact_id = $validatorRef["artifact_id"]
            valid = if ($validatorStatus) { [bool]$validatorStatus["valid"] } else { $true }
            errors = if ($validatorStatus) { @($validatorStatus["errors"]) } else { @() }
            warnings = if ($validatorStatus) { @($validatorStatus["warnings"]) } else { @() }
        }
        if ($commitResult -and @($commitResult["committed"]).Count -gt 0) {
            Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
                type = "phase.artifacts_committed"
                phase = $phaseName
                task_id = $taskId
                job_id = [string]$jobSpec["job_id"]
                artifact_ids = @(
                    @($commitResult["committed"]) |
                        ForEach-Object {
                            $committedArtifact = ConvertTo-RelayHashtable -InputObject $_
                            [string]$committedArtifact["artifact_id"]
                        }
                )
            }
        }
    }

    if ($commitGuardResult -and -not [bool]$commitGuardResult["valid"]) {
        Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
            type = "job.commit_rejected"
            job_id = [string]$jobSpec["job_id"]
            phase = $phaseName
            task_id = $taskId
            lease_token = [string]$jobSpec["lease_token"]
            errors = @($commitGuardResult["errors"])
        }
    }

    if ([bool]$transaction["recovered_from_timeout"]) {
        Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
            type = "job.timeout_recovered"
            job_id = [string]$jobSpec["job_id"]
            phase = $phaseName
            task_id = $taskId
        }
    }
    if ([bool]$effectiveExecutionResult["recovered_from_artifacts"]) {
        Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
            type = "job.artifact_completion_recovered"
            job_id = [string]$jobSpec["job_id"]
            phase = $phaseName
            task_id = $taskId
            artifact_completion = (ConvertTo-RelayHashtable -InputObject $effectiveExecutionResult["artifact_completion"])
        }
    }

    $mutation = Apply-JobResult -RunState $RunState -JobResult $effectiveExecutionResult -ValidationResult $validationResult["validation"] -Artifact $validationResult["artifact"] -ProjectRoot $ProjectRoot -ApprovalPhases $ApprovalPhases
    $nextRunState = ConvertTo-RelayHashtable -InputObject $mutation["run_state"]
    $mutationAction = ConvertTo-RelayHashtable -InputObject $mutation["action"]

    $taskLane = ConvertTo-RelayHashtable -InputObject $nextRunState["task_lane"]
    if ([string]$mutationAction["type"] -eq "RequestApproval") {
        $taskLane["stop_leasing"] = $true
        $nextRunState["task_lane"] = $taskLane
    }

    Write-RunState -ProjectRoot $ProjectRoot -RunState $nextRunState | Out-Null
    Append-LeasedJobRunStatusChangedEvent -ProjectRoot $ProjectRoot -RunId $RunId -RunState $nextRunState

    foreach ($spawnedTask in @($mutation["spawned_tasks"])) {
        $spawnedTaskObject = ConvertTo-RelayHashtable -InputObject $spawnedTask
        $spawnedTaskState = $null
        if (
            -not [string]::IsNullOrWhiteSpace([string]$spawnedTaskObject["task_id"]) -and
            $nextRunState["task_states"] -and
            $nextRunState["task_states"].ContainsKey([string]$spawnedTaskObject["task_id"])
        ) {
            $spawnedTaskState = ConvertTo-RelayHashtable -InputObject $nextRunState["task_states"][[string]$spawnedTaskObject["task_id"]]
        }
        Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
            type = "task.spawned"
            origin_phase = $phaseName
            task_id = $spawnedTaskObject["task_id"]
            task_kind = "repair"
            task_contract_ref = if ($spawnedTaskState) { $spawnedTaskState["task_contract_ref"] } else { $null }
            depends_on = if ($spawnedTaskState) { @($spawnedTaskState["depends_on"]) } else { @($spawnedTaskObject["depends_on"]) }
        }
    }

    if (
        $phaseName -eq "Phase6" -and
        -not [string]::IsNullOrWhiteSpace($taskId) -and
        [string]$mutationAction["type"] -ne "FailRun" -and
        $nextRunState["task_states"] -and
        $nextRunState["task_states"].ContainsKey($taskId)
    ) {
        $completedTaskState = ConvertTo-RelayHashtable -InputObject $nextRunState["task_states"][$taskId]
        if ([string]$completedTaskState["status"] -eq "completed") {
            Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
                type = "task.completed"
                phase = $phaseName
                task_id = $taskId
                task_contract_ref = $completedTaskState["task_contract_ref"]
            }
        }
    }

    switch ([string]$mutationAction["type"]) {
        "Continue" {
            Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
                type = "phase.transitioned"
                from_phase = $phaseName
                to_phase = $mutationAction["next_phase"]
                task_id = $mutationAction["next_task_id"]
            }
        }
        "RequestApproval" {
            $pendingApproval = ConvertTo-RelayHashtable -InputObject $mutationAction["pending_approval"]
            Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
                type = "approval.requested"
                approval_id = $pendingApproval["approval_id"]
                requested_phase = $pendingApproval["requested_phase"]
                requested_role = $pendingApproval["requested_role"]
                requested_task_id = $pendingApproval["requested_task_id"]
                proposed_action = $pendingApproval["proposed_action"]
            }
        }
        "FailRun" {
            Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{
                type = "run.failed"
                reason = $mutationAction["reason"]
                failure_class = $effectiveExecutionResult["failure_class"]
            }
        }
        "CompleteRun" {
            Append-Event -ProjectRoot $ProjectRoot -RunId $RunId -Event @{ type = "run.completed" }
        }
    }

    return [ordered]@{
        run_state = $nextRunState
        mutation_action = $mutationAction
        job = $effectiveExecutionResult
        validation = $validationResult["validation"]
    }
}

function Invoke-LeasedJobPackage {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$MainWorkspace,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [string[]]$ApprovalPhases = @(),
        [scriptblock]$ArtifactCompletionProbe,
        [int]$LockTimeoutSec = 300,
        [int]$HeartbeatIntervalSec = 30,
        [int]$LeaseDurationMinutes = 120
    )

    $packageObject = Import-LeasedJobPackage -Package $Package
    $jobSpec = ConvertTo-RelayHashtable -InputObject $(if ($packageObject["job_spec"]) { $packageObject["job_spec"] } else { $packageObject["job"] })
    if (-not $jobSpec) {
        throw "Leased job package must include job_spec or job."
    }

    $runId = if ($packageObject["run_id"]) { [string]$packageObject["run_id"] } else { [string]$jobSpec["run_id"] }
    $phaseName = if ($packageObject["phase"]) { [string]$packageObject["phase"] } else { [string]$jobSpec["phase"] }
    $taskId = if ($packageObject["task_id"]) { [string]$packageObject["task_id"] } else { [string]$jobSpec["task_id"] }
    $jobSpec["run_id"] = $runId
    $jobSpec["phase"] = $phaseName
    $jobSpec["task_id"] = $taskId
    $promptText = [string]$packageObject["prompt_text"]
    if ([string]::IsNullOrWhiteSpace($promptText) -and -not [string]::IsNullOrWhiteSpace([string]$packageObject["prompt_file"])) {
        $promptText = Get-Content -LiteralPath ([string]$packageObject["prompt_file"]) -Raw -Encoding UTF8
    }
    if ([string]::IsNullOrWhiteSpace($promptText)) {
        throw "Leased job package must include prompt_text or prompt_file."
    }

    $phaseDefinition = ConvertTo-RelayHashtable -InputObject $packageObject["phase_definition"]
    if (-not $phaseDefinition) {
        throw "Leased job package must include phase_definition."
    }

    $workspaceInfo = ConvertTo-RelayHashtable -InputObject $packageObject["workspace"]
    $workingDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$packageObject["workspace_path"])) {
        [string]$packageObject["workspace_path"]
    }
    elseif ($workspaceInfo -and -not [string]::IsNullOrWhiteSpace([string]$workspaceInfo["path"])) {
        [string]$workspaceInfo["path"]
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$packageObject["working_directory"])) {
        [string]$packageObject["working_directory"]
    }
    else {
        $ProjectRoot
    }
    if ([string]::IsNullOrWhiteSpace($MainWorkspace)) {
        $MainWorkspace = $ProjectRoot
    }

    $leasedCommitState = @{
        lock = $null
        state = $null
        fence = $null
        rejected = $null
    }
    $heartbeat = $null

    try {
        $transactionParams = @{
            JobSpec = $jobSpec
            PromptText = $promptText
            ProjectRoot = $ProjectRoot
            WorkingDirectory = $workingDirectory
            TimeoutPolicy = $TimeoutPolicy
            RunId = $runId
            PhaseName = $phaseName
            PhaseDefinition = $phaseDefinition
            TaskId = $taskId
            PhaseStartedAtUtc = (Convert-PhaseExecutionDateTimeToUtc -Value ([string]$packageObject["phase_started_at"])
            )
            PreCommitGuard = {
                param($GuardContext)

                $leasedCommitState["lock"] = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $runId -RetryCount 0 -TimeoutSec $LockTimeoutSec
                $leasedCommitState["state"] = Read-RunState -ProjectRoot $ProjectRoot -RunId $runId
                $commitJob = ConvertTo-RelayHashtable -InputObject $GuardContext["job_spec"]
                $leasedCommitState["fence"] = ConvertTo-RelayHashtable -InputObject (Test-LeasedJobCommitFence -RunState $leasedCommitState["state"] -JobSpec $commitJob -Package $packageObject)
                if (-not [bool]$leasedCommitState["fence"]["valid"]) {
                    $leasedCommitState["rejected"] = New-LeasedJobCommitRejectedResult -RunId $runId -JobId ([string]$commitJob["job_id"]) -TaskId ([string]$commitJob["task_id"]) -Phase ([string]$commitJob["phase"]) -LeaseToken ([string]$commitJob["lease_token"]) -Errors @($leasedCommitState["fence"]["errors"])
                    return $leasedCommitState["fence"]
                }

                $boundaryResult = $null
                if (Get-Command Test-WorkspaceBoundaryDelta -ErrorAction SilentlyContinue) {
                    $workspacePackage = ConvertTo-RelayHashtable -InputObject $packageObject["workspace"]
                    $boundaryExcludePaths = @(
                        "artifacts",
                        "jobs",
                        "runs",
                        "docs/worklog",
                        "tasks/task.md",
                        "relay-dev/artifacts",
                        "relay-dev/jobs",
                        "relay-dev/runs",
                        "relay-dev/docs/worklog",
                        "relay-dev/tasks/task.md",
                        "probe.txt",
                        "write-probe.txt",
                        "__write_test.tmp"
                    )
                    foreach ($contractRaw in @($phaseDefinition["output_contract"])) {
                        $contract = ConvertTo-RelayHashtable -InputObject $contractRaw
                        $artifactId = [string]$contract["artifact_id"]
                        if ([string]::IsNullOrWhiteSpace($artifactId)) {
                            continue
                        }
                        $boundaryExcludePaths += $artifactId
                        $boundaryExcludePaths += "relay-dev/$artifactId"
                    }
                    $boundaryResult = ConvertTo-RelayHashtable -InputObject (Test-WorkspaceBoundaryDelta -WorkspaceRoot $workingDirectory -BaselineSnapshot $workspacePackage["baseline"] -DeclaredChangedFiles @($workspacePackage["declared_changed_files"]) -ResourceLocks @($packageObject["resource_locks"]) -AdditionalExcludePaths $boundaryExcludePaths)
                    if ($boundaryResult -and -not [bool]$boundaryResult["ok"]) {
                        $boundaryErrors = @(
                            @($boundaryResult["unexpected_changed_files"]) | ForEach-Object { "unexpected workspace change: $_" }
                        ) + @(
                            @($boundaryResult["shared_file_rejections"]) | ForEach-Object { "shared file change rejected: $_" }
                        )
                        $leasedCommitState["fence"]["valid"] = $false
                        $leasedCommitState["fence"]["errors"] = @($leasedCommitState["fence"]["errors"]) + @($boundaryErrors)
                        $leasedCommitState["rejected"] = New-LeasedJobCommitRejectedResult -RunId $runId -JobId ([string]$commitJob["job_id"]) -TaskId ([string]$commitJob["task_id"]) -Phase ([string]$commitJob["phase"]) -LeaseToken ([string]$commitJob["lease_token"]) -Errors @($leasedCommitState["fence"]["errors"]) -Reason "workspace_boundary_rejected"
                        return $leasedCommitState["fence"]
                    }
                }

                if (Get-Command Invoke-IsolatedWorkspaceMergeBack -ErrorAction SilentlyContinue) {
                    $workspacePackage = ConvertTo-RelayHashtable -InputObject $packageObject["workspace"]
                    $acceptedChangedFiles = if ($boundaryResult) { @($boundaryResult["accepted_changed_files"]) } else { @($workspacePackage["declared_changed_files"]) }
                    $mergeResult = ConvertTo-RelayHashtable -InputObject (Invoke-IsolatedWorkspaceMergeBack -MainWorkspace $MainWorkspace -IsolatedWorkspace $workingDirectory -BaselineSnapshot $workspacePackage["baseline"] -AcceptedChangedFiles @($acceptedChangedFiles))
                    if ($mergeResult -and -not [bool]$mergeResult["ok"]) {
                        $mergeErrors = @($mergeResult["conflicts"]) | ForEach-Object {
                            $conflict = ConvertTo-RelayHashtable -InputObject $_
                            "merge conflict $($conflict['path']): $($conflict['reason'])"
                        }
                        $leasedCommitState["fence"]["valid"] = $false
                        $leasedCommitState["fence"]["errors"] = @($leasedCommitState["fence"]["errors"]) + @($mergeErrors)
                        $leasedCommitState["rejected"] = New-LeasedJobCommitRejectedResult -RunId $runId -JobId ([string]$commitJob["job_id"]) -TaskId ([string]$commitJob["task_id"]) -Phase ([string]$commitJob["phase"]) -LeaseToken ([string]$commitJob["lease_token"]) -Errors @($leasedCommitState["fence"]["errors"]) -Reason "workspace_merge_rejected"
                        return $leasedCommitState["fence"]
                    }
                }

                return $leasedCommitState["fence"]
            }
        }
        if ($ArtifactCompletionProbe) {
            $transactionParams["ArtifactCompletionProbe"] = $ArtifactCompletionProbe
        }

        Invoke-LeasedJobHeartbeatOnce -ProjectRoot $ProjectRoot -RunId $runId -JobId ([string]$jobSpec["job_id"]) -LeaseToken ([string]$jobSpec["lease_token"]) -LeaseDurationMinutes $LeaseDurationMinutes | Out-Null
        $heartbeat = Start-LeasedJobHeartbeat -ProjectRoot $ProjectRoot -RunId $runId -JobId ([string]$jobSpec["job_id"]) -LeaseToken ([string]$jobSpec["lease_token"]) -IntervalSec $HeartbeatIntervalSec -LeaseDurationMinutes $LeaseDurationMinutes

        $transactionResult = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseExecutionTransaction @transactionParams)

        if ($null -eq $leasedCommitState["lock"]) {
            $leasedCommitState["lock"] = Acquire-RunLock -ProjectRoot $ProjectRoot -RunId $runId -RetryCount 0 -TimeoutSec $LockTimeoutSec
            $leasedCommitState["state"] = Read-RunState -ProjectRoot $ProjectRoot -RunId $runId
            $leasedCommitState["fence"] = ConvertTo-RelayHashtable -InputObject (Test-LeasedJobCommitFence -RunState $leasedCommitState["state"] -JobSpec $jobSpec -Package $packageObject)
            if (-not [bool]$leasedCommitState["fence"]["valid"]) {
                $leasedCommitState["rejected"] = New-LeasedJobCommitRejectedResult -RunId $runId -JobId ([string]$jobSpec["job_id"]) -TaskId $taskId -Phase $phaseName -LeaseToken ([string]$jobSpec["lease_token"]) -Errors @($leasedCommitState["fence"]["errors"])
            }
        }

        if ($leasedCommitState["rejected"]) {
            $commitRejected = ConvertTo-RelayHashtable -InputObject $leasedCommitState["rejected"]
            $rejectedState = if ($leasedCommitState["state"]) { ConvertTo-RelayHashtable -InputObject $leasedCommitState["state"] } else { Read-RunState -ProjectRoot $ProjectRoot -RunId $runId }
            if ($rejectedState) {
                $rejectedState = Clear-RunStateActiveJobLease -RunState $rejectedState -JobId ([string]$jobSpec["job_id"])
                if ([string]$rejectedState["status"] -eq "running") {
                    $rejectedState["status"] = "failed"
                }
                $rejectedState["updated_at"] = (Get-Date).ToString("o")
                Write-RunState -ProjectRoot $ProjectRoot -RunState $rejectedState | Out-Null
                Append-LeasedJobRunStatusChangedEvent -ProjectRoot $ProjectRoot -RunId $runId -RunState $rejectedState
                Append-Event -ProjectRoot $ProjectRoot -RunId $runId -Event @{
                    type = "run.failed"
                    reason = [string]$commitRejected["reason"]
                    failure_class = "commit_rejected"
                }
            }
            Append-Event -ProjectRoot $ProjectRoot -RunId $runId -Event @{
                type = "job.commit_rejected"
                job_id = [string]$jobSpec["job_id"]
                phase = $phaseName
                task_id = $taskId
                lease_token = [string]$jobSpec["lease_token"]
                reason = [string]$commitRejected["reason"]
                errors = @($commitRejected["errors"])
            }
            return $commitRejected
        }

        $latestState = if ($leasedCommitState["state"]) { $leasedCommitState["state"] } else { Read-RunState -ProjectRoot $ProjectRoot -RunId $runId }
        $approvalCollision = $false
        if ($phaseName -in @($ApprovalPhases) -and $latestState["pending_approval"]) {
            $approvalCollision = $true
        }
        if ($approvalCollision) {
            $commitRejected = New-LeasedJobCommitRejectedResult -RunId $runId -JobId ([string]$jobSpec["job_id"]) -TaskId $taskId -Phase $phaseName -LeaseToken ([string]$jobSpec["lease_token"]) -Errors @("pending approval already exists; rejecting second approval commit") -Reason "approval_commit_rejected"
            Append-Event -ProjectRoot $ProjectRoot -RunId $runId -Event @{
                type = "approval.commit_rejected"
                job_id = [string]$jobSpec["job_id"]
                phase = $phaseName
                task_id = $taskId
                lease_token = [string]$jobSpec["lease_token"]
                errors = @($commitRejected["errors"])
            }
            return $commitRejected
        }

        $closeout = ConvertTo-RelayHashtable -InputObject (Invoke-LeasedJobPackageCloseout -ProjectRoot $ProjectRoot -RunId $runId -RunState $latestState -JobSpec $jobSpec -TransactionResult $transactionResult -ApprovalPhases $ApprovalPhases)
        return [ordered]@{
            ok = $true
            mode = "leased_job_worker"
            result = "committed"
            run_id = $runId
            job_id = [string]$jobSpec["job_id"]
            task_id = $taskId
            phase = $phaseName
            mutation_action = $closeout["mutation_action"]
            validation = $closeout["validation"]
            job = $closeout["job"]
            exit_code = 0
        }
    }
    finally {
        if ($leasedCommitState["lock"]) {
            Release-RunLock -LockHandle $leasedCommitState["lock"]
        }
        if ($heartbeat) {
            Stop-LeasedJobHeartbeat -Heartbeat $heartbeat
        }
    }
}
