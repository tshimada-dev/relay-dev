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

foreach ($fixture in @($successFixture, $failedFixture)) {
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
