$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\run-lock.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\parallel-worker.ps1")

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $script:failures.Add($Message)
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

function Assert-ThrowsContaining {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$ExpectedText,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $ScriptBlock
        Add-Failure "$Message (expected exception containing '$ExpectedText')"
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedText*") {
            Add-Failure "$Message (expected exception containing '$ExpectedText', actual='$($_.Exception.Message)')"
        }
    }
}

function New-WorkerLoopFixture {
    param(
        [string]$Name
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-worker-loop-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = "run-worker-loop-$Name"
    $groupId = "group-$Name"
    $workerId = "worker-$Name"
    $taskId = "T-$Name"
    $workspacePath = Join-Path $tempRoot "workspace"
    $artifactRoot = Get-JobArtifactsRootPath -ProjectRoot $tempRoot -RunId $runId -JobId $workerId
    New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -TaskId $taskId -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state["task_groups"][$groupId] = [ordered]@{
        id = $groupId
        group_id = $groupId
        status = "planned"
        worker_ids = @($workerId)
        task_ids = @($taskId)
    }
    $state["task_group_workers"][$workerId] = [ordered]@{
        id = $workerId
        worker_id = $workerId
        group_id = $groupId
        task_id = $taskId
        status = "queued"
        current_phase = "Phase5"
        phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
        workspace_path = $workspacePath
        artifact_root = $artifactRoot
        declared_changed_files = @("src/$taskId.txt")
        errors = @()
        artifact_refs = @()
    }
    Write-RunState -ProjectRoot $tempRoot -RunState $state | Out-Null

    $package = [ordered]@{
        package_kind = "task-group-leased-package"
        run_id = $runId
        group_id = $groupId
        provider_spec = [ordered]@{ provider = "fake"; command = "fake"; flags = "" }
        workers = @(
            [ordered]@{
                worker_id = $workerId
                group_id = $groupId
                task_id = $taskId
                phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
                selected_task = [ordered]@{ task_id = $taskId; purpose = "worker loop test" }
                workspace_path = $workspacePath
                artifact_root = $artifactRoot
                declared_changed_files = @("src/$taskId.txt")
                resource_locks = @("lock-$taskId")
                lease_token = "lease-$Name"
            }
        )
    }

    return [ordered]@{
        root = $tempRoot
        run_id = $runId
        group_id = $groupId
        worker_id = $workerId
        task_id = $taskId
        package = $package
    }
}

$successFixture = New-WorkerLoopFixture -Name "success"
$successCalls = New-Object System.Collections.Generic.List[string]
$successResult = Invoke-TaskGroupWorkerPackage -Package $successFixture["package"] -ProjectRoot $successFixture["root"] -TimeoutPolicy ([ordered]@{}) -TransactionFactory {
    param($Worker, $PhaseName, $PhaseDefinition, $PromptText, $JobSpec)

    $script:successCalls.Add([string]$PhaseName) | Out-Null
    return [ordered]@{
        artifact_refs = @(
            [ordered]@{
                artifact_id = "$PhaseName-result.json"
                phase = $PhaseName
                storage_scope = "job"
                job_id = [string]$JobSpec["job_id"]
                path = Join-Path ([string]$Worker["artifact_root"]) "$PhaseName-result.json"
            }
        )
        validation_result = [ordered]@{ validation = [ordered]@{ valid = $true; errors = @() } }
        effective_execution_result = [ordered]@{ result_status = "succeeded"; failure_class = $null }
    }
} -PhaseDefinitionFactory {
    param($PhaseName, $ProviderSpec, $Worker)
    return [ordered]@{ phase = $PhaseName; role = "implementer"; output_contract = @(); validator = @{ artifact_id = "$PhaseName-result.json" } }
}

$successState = Read-RunState -ProjectRoot $successFixture["root"] -RunId $successFixture["run_id"]
$successWorker = ConvertTo-RelayHashtable -InputObject $successState["task_group_workers"][$successFixture["worker_id"]]
$canonicalSuccessPath = Get-ArtifactPath -ProjectRoot $successFixture["root"] -RunId $successFixture["run_id"] -Scope task -Phase "Phase6" -ArtifactId "phase6_result.json" -TaskId $successFixture["task_id"]

Assert-Equal $successResult["status"] "succeeded" "Fake worker should complete Phase5 through Phase6."
Assert-Equal ($successCalls.ToArray() -join ",") "Phase5,Phase5-1,Phase5-2,Phase6" "Worker should execute the fixed phase sequence."
Assert-Equal $successWorker["status"] "succeeded" "Parent run-state worker status should become succeeded."
Assert-Equal $successWorker["current_phase"] "Phase6" "Succeeded worker should end at Phase6."
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$successWorker["last_heartbeat_at"])) "Worker heartbeat timestamp should be recorded."
Assert-Equal @($successWorker["artifact_refs"]).Count 4 "Worker state should retain artifact refs from each phase."
Assert-True (-not (Test-Path -LiteralPath $canonicalSuccessPath)) "Worker loop should not create canonical parent artifacts."

$missingWorkspaceFixture = New-WorkerLoopFixture -Name "missing-workspace"
$missingWorkspaceFixture["package"]["workers"][0].Remove("workspace_path")
Assert-ThrowsContaining -ExpectedText "workspace_path is required" -Message "Task-group workers should require an isolated workspace path." -ScriptBlock {
    Invoke-TaskGroupWorkerPackage -Package $missingWorkspaceFixture["package"] -ProjectRoot $missingWorkspaceFixture["root"] -TimeoutPolicy ([ordered]@{}) -TransactionFactory {
        throw "transaction should not run when worker isolation is invalid"
    } -PhaseDefinitionFactory {
        param($PhaseName, $ProviderSpec, $Worker)
        return [ordered]@{ phase = $PhaseName; role = "implementer"; output_contract = @(); validator = @{ artifact_id = "$PhaseName-result.json" } }
    } | Out-Null
}
$missingWorkspaceState = Read-RunState -ProjectRoot $missingWorkspaceFixture["root"] -RunId $missingWorkspaceFixture["run_id"]
$missingWorkspaceWorker = ConvertTo-RelayHashtable -InputObject $missingWorkspaceState["task_group_workers"][$missingWorkspaceFixture["worker_id"]]
$missingWorkspaceErrors = (@($missingWorkspaceWorker["errors"]) -join "`n")
Assert-Equal $missingWorkspaceWorker["status"] "failed" "Invalid isolation should be recorded on the worker row."
Assert-True ($missingWorkspaceErrors -like "*workspace_path is required*") "Invalid isolation should persist a worker-local error."

$overlapFixture = New-WorkerLoopFixture -Name "overlap"
$overlapFixture["package"]["workers"][0]["artifact_root"] = Join-Path ([string]$overlapFixture["package"]["workers"][0]["workspace_path"]) "artifacts"
Assert-ThrowsContaining -ExpectedText "workspace_path and artifact_root must be separate" -Message "Task-group workers should keep workspace and artifact roots separate." -ScriptBlock {
    Invoke-TaskGroupWorkerPackage -Package $overlapFixture["package"] -ProjectRoot $overlapFixture["root"] -TimeoutPolicy ([ordered]@{}) -TransactionFactory {
        throw "transaction should not run when worker isolation is invalid"
    } -PhaseDefinitionFactory {
        param($PhaseName, $ProviderSpec, $Worker)
        return [ordered]@{ phase = $PhaseName; role = "implementer"; output_contract = @(); validator = @{ artifact_id = "$PhaseName-result.json" } }
    } | Out-Null
}

$siblingOverlapFixture = New-WorkerLoopFixture -Name "sibling-overlap"
$firstWorker = ConvertTo-RelayHashtable -InputObject $siblingOverlapFixture["package"]["workers"][0]
$siblingOverlapFixture["package"]["workers"] = @($siblingOverlapFixture["package"]["workers"]) + @(
    [ordered]@{
        worker_id = "worker-sibling-overlap-other"
        group_id = [string]$siblingOverlapFixture["group_id"]
        task_id = "T-sibling-overlap-other"
        phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
        selected_task = [ordered]@{ task_id = "T-sibling-overlap-other"; purpose = "sibling isolation test" }
        workspace_path = [string]$firstWorker["workspace_path"]
        artifact_root = Join-Path ([string]$siblingOverlapFixture["root"]) "other-artifacts"
        declared_changed_files = @("src/T-sibling-overlap-other.txt")
        resource_locks = @("lock-T-sibling-overlap-other")
        lease_token = "lease-sibling-overlap-other"
    }
)
Assert-ThrowsContaining -ExpectedText "overlaps sibling worker" -Message "Task-group workers should reject overlapping sibling workspaces." -ScriptBlock {
    Invoke-TaskGroupWorkerPackage -Package $siblingOverlapFixture["package"] -ProjectRoot $siblingOverlapFixture["root"] -WorkerId ([string]$siblingOverlapFixture["worker_id"]) -TimeoutPolicy ([ordered]@{}) -TransactionFactory {
        throw "transaction should not run when sibling isolation is invalid"
    } -PhaseDefinitionFactory {
        param($PhaseName, $ProviderSpec, $Worker)
        return [ordered]@{ phase = $PhaseName; role = "implementer"; output_contract = @(); validator = @{ artifact_id = "$PhaseName-result.json" } }
    } | Out-Null
}

$failedFixture = New-WorkerLoopFixture -Name "failed"
$failedCalls = New-Object System.Collections.Generic.List[string]
$failedResult = Invoke-TaskGroupWorkerPackage -Package $failedFixture["package"] -ProjectRoot $failedFixture["root"] -TimeoutPolicy ([ordered]@{}) -TransactionFactory {
    param($Worker, $PhaseName, $PhaseDefinition, $PromptText, $JobSpec)

    $script:failedCalls.Add([string]$PhaseName) | Out-Null
    if ($PhaseName -eq "Phase5-1") {
        return [ordered]@{
            artifact_refs = @()
            validation_result = [ordered]@{ validation = [ordered]@{ valid = $false; errors = @("invalid artifact for worker attribution") } }
            effective_execution_result = [ordered]@{ result_status = "succeeded"; failure_class = $null }
        }
    }
    return [ordered]@{
        artifact_refs = @()
        validation_result = [ordered]@{ validation = [ordered]@{ valid = $true; errors = @() } }
        effective_execution_result = [ordered]@{ result_status = "succeeded"; failure_class = $null }
    }
} -PhaseDefinitionFactory {
    param($PhaseName, $ProviderSpec, $Worker)
    return [ordered]@{ phase = $PhaseName; role = "implementer"; output_contract = @(); validator = @{ artifact_id = "$PhaseName-result.json" } }
}

$failedState = Read-RunState -ProjectRoot $failedFixture["root"] -RunId $failedFixture["run_id"]
$failedWorker = ConvertTo-RelayHashtable -InputObject $failedState["task_group_workers"][$failedFixture["worker_id"]]
$canonicalFailedPath = Get-ArtifactPath -ProjectRoot $failedFixture["root"] -RunId $failedFixture["run_id"] -Scope task -Phase "Phase5-1" -ArtifactId "phase5-1_verdict.json" -TaskId $failedFixture["task_id"]

Assert-Equal $failedResult["status"] "failed" "Invalid artifact should fail the worker."
Assert-Equal ($failedCalls.ToArray() -join ",") "Phase5,Phase5-1" "Worker should stop at the failed phase."
Assert-Equal $failedResult["worker_id"] $failedFixture["worker_id"] "Failure result should include worker attribution."
Assert-Equal $failedResult["group_id"] $failedFixture["group_id"] "Failure result should include group attribution."
Assert-Equal $failedResult["task_id"] $failedFixture["task_id"] "Failure result should include task attribution."
Assert-Equal $failedResult["final_phase"] "Phase5-1" "Failure result should include final phase attribution."
Assert-True (@($failedResult["errors"]) -contains "invalid artifact for worker attribution") "Failure result should include validation errors."
Assert-Equal $failedWorker["status"] "failed" "Parent run-state worker status should become failed."
Assert-Equal $failedWorker["current_phase"] "Phase5-1" "Failed worker should retain the failed phase."
Assert-True (-not (Test-Path -LiteralPath $canonicalFailedPath)) "Failed worker should not create canonical parent artifacts."

foreach ($fixture in @($successFixture, $missingWorkspaceFixture, $overlapFixture, $siblingOverlapFixture, $failedFixture)) {
    if (Test-Path -LiteralPath $fixture["root"]) {
        Remove-Item -LiteralPath $fixture["root"] -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-worker-loop failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-worker-loop passed." -ForegroundColor Green
exit 0
