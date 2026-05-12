$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\artifact-validator.ps1")
. (Join-Path $repoRoot "app\core\phase-validation-pipeline.ps1")
. (Join-Path $repoRoot "app\core\phase-completion-committer.ps1")
. (Join-Path $repoRoot "app\core\parallel-workspace.ps1")
. (Join-Path $repoRoot "app\phases\phase-common.ps1")
. (Join-Path $repoRoot "app\phases\phase5.ps1")
. (Join-Path $repoRoot "app\phases\phase5-1.ps1")

function Invoke-ExecutionRunner {
    param(
        [Parameter(Mandatory)]$JobSpec,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)]$TimeoutPolicy,
        [int]$ArtifactCompletionStabilitySec = 5
    )

    $jsonPath = if ($PromptText -match '(?m)^phase5_result\.json\s*=>\s*(.+?)\s*\(write\)') {
        $Matches[1].Trim()
    }
    else {
        throw "missing phase5_result output path in prompt"
    }
    $mdPath = if ($PromptText -match '(?m)^phase5_implementation\.md\s*=>\s*(.+?)\s*\(write\)') {
        $Matches[1].Trim()
    }
    else {
        throw "missing phase5_implementation output path in prompt"
    }

    $taskId = [string]$JobSpec["task_id"]
    New-Item -ItemType Directory -Path (Split-Path -Parent $mdPath) -Force | Out-Null
    Set-Content -Path $mdPath -Value "worker-local implementation" -Encoding UTF8

    $result = [ordered]@{
        task_id = $taskId
        changed_files = @("src/$taskId.txt")
        commands_run = @("fake-worker-provider")
        implementation_summary = "worker-local artifact boundary"
        acceptance_criteria_status = @(
            [ordered]@{
                criterion = "worker artifact path is local"
                status = "met"
                evidence = @($jsonPath)
            }
        )
        known_issues = @()
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $jsonPath) -Force | Out-Null
    Set-Content -Path $jsonPath -Value (($result | ConvertTo-Json -Depth 20) + "`n") -Encoding UTF8

    return [ordered]@{
        job_id = [string]$JobSpec["job_id"]
        attempt_id = "attempt-fake"
        final_attempt_started_at = (Get-Date).AddMinutes(-1).ToUniversalTime().ToString("o")
        result_status = "succeeded"
        failure_class = $null
        exit_code = 0
    }
}

. (Join-Path $repoRoot "app\core\phase-execution-transaction.ps1")

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-artifacts-" + [guid]::NewGuid().ToString("N"))
$runId = "run-task-group-artifacts"
$workerId = "worker-artifacts-1"
$taskId = "T-artifacts"
$isolatedRoot = $null
$fallbackRoot = $null
$looseRoot = $null

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $phaseDefinition = Get-Phase5Definition
    $contractItems = @($phaseDefinition["output_contract"])

    $promptLines = New-Object System.Collections.Generic.List[string]
    foreach ($contractItem in $contractItems) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        $path = Resolve-PhaseContractArtifactPath -ProjectRoot $tempRoot -RunId $runId -PhaseName "Phase5" -ContractItem $item -TaskId $taskId -JobId $workerId -StorageScope "job"
        $promptLines.Add("$($item['artifact_id']) => $path (write)") | Out-Null
    }
    $promptText = ($promptLines.ToArray() -join "`n")

    $promptJsonPath = if ($promptText -match '(?m)^phase5_result\.json\s*=>\s*(.+?)\s*\(write\)') { $Matches[1].Trim() } else { "" }
    $validatorJsonPath = Resolve-PhaseContractArtifactPath -ProjectRoot $tempRoot -RunId $runId -PhaseName "Phase5" -ContractItem $contractItems[1] -TaskId $taskId -JobId $workerId -StorageScope "job"
    Assert-Equal $promptJsonPath $validatorJsonPath "Prompt output path and validator input path should use the same job-scoped path."
    Assert-Equal $promptJsonPath (Get-JobArtifactPath -ProjectRoot $tempRoot -RunId $runId -JobId $workerId -Scope task -Phase "Phase5" -ArtifactId "phase5_result.json" -TaskId $taskId) "Worker-local path should resolve under job artifact storage."

    $canonicalJsonPath = Get-ArtifactPath -ProjectRoot $tempRoot -RunId $runId -Scope task -Phase "Phase5" -ArtifactId "phase5_result.json" -TaskId $taskId
    $transactionResult = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseExecutionTransaction `
            -JobSpec ([ordered]@{ job_id = $workerId; task_id = $taskId }) `
            -PromptText $promptText `
            -ProjectRoot $tempRoot `
            -WorkingDirectory $tempRoot `
            -TimeoutPolicy ([ordered]@{}) `
            -RunId $runId `
            -PhaseName "Phase5" `
            -PhaseDefinition $phaseDefinition `
            -TaskId $taskId `
            -PhaseStartedAtUtc ([datetime]::UtcNow.AddMinutes(-2)) `
            -ArtifactStorageScope "job" `
            -CommitValidatedArtifacts:$false)

    $validationStatus = ConvertTo-RelayHashtable -InputObject $transactionResult["validation_result"]["validation"]
    Assert-True ([bool]$validationStatus["valid"]) "Worker-local validation should accept the job-scoped artifacts."
    Assert-Equal $transactionResult["artifact_storage_scope"] "job" "Transaction should report job artifact storage for worker-local validation."
    Assert-True (-not (Test-Path -LiteralPath $canonicalJsonPath)) "Worker-local validation should not create canonical parent artifacts before group commit."
    Assert-Equal ([int]$transactionResult["commit_result"]["summary"]["committed_count"]) 0 "Skipped canonical commit should commit zero artifacts."
    Assert-True ([bool]$transactionResult["commit_result"]["skipped"]) "Commit result should identify the skipped canonical commit."

    $materializedJson = @($transactionResult["output_sync_result"]["materialized"] | Where-Object { [string]$_["artifact_id"] -eq "phase5_result.json" })[0]
    Assert-Equal ([string]$materializedJson["path"]) $promptJsonPath "Validator materialized artifact should be read from the prompt-advertised path."

    $artifactRefs = @($transactionResult["artifact_refs"])
    Assert-True ($artifactRefs.Count -ge 2) "Transaction should return serializable artifact refs for worker results."
    $jsonRef = @($artifactRefs | Where-Object { [string]$_["artifact_id"] -eq "phase5_result.json" })[0]
    Assert-Equal $jsonRef["storage_scope"] "job" "Artifact refs should preserve job storage scope."
    Assert-Equal $jsonRef["job_id"] $workerId "Artifact refs should preserve the worker job id."
    Assert-Equal $jsonRef["path"] $promptJsonPath "Artifact refs should include the worker-local artifact path."
    $jsonRoundTrip = ($jsonRef | ConvertTo-Json -Depth 20) | ConvertFrom-Json
    Assert-Equal $jsonRoundTrip.storage_scope "job" "Artifact refs should serialize into worker result rows."

    $isolatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-artifacts-workspace-" + [guid]::NewGuid().ToString("N"))
    $isolatedWorkerId = "worker-artifacts-isolated"
    New-Item -ItemType Directory -Path $isolatedRoot -Force | Out-Null

    $isolatedPromptLines = New-Object System.Collections.Generic.List[string]
    foreach ($contractItem in $contractItems) {
        $item = ConvertTo-RelayHashtable -InputObject $contractItem
        $path = Resolve-PhaseContractArtifactPath -ProjectRoot $isolatedRoot -RunId $runId -PhaseName "Phase5" -ContractItem $item -TaskId $taskId -JobId $isolatedWorkerId -StorageScope "job"
        $isolatedPromptLines.Add("$($item['artifact_id']) => $path (write)") | Out-Null
    }
    $isolatedPromptText = ($isolatedPromptLines.ToArray() -join "`n")
    $isolatedPromptJsonPath = if ($isolatedPromptText -match '(?m)^phase5_result\.json\s*=>\s*(.+?)\s*\(write\)') { $Matches[1].Trim() } else { "" }
    $mainJobJsonPath = Resolve-PhaseContractArtifactPath -ProjectRoot $tempRoot -RunId $runId -PhaseName "Phase5" -ContractItem $contractItems[1] -TaskId $taskId -JobId $isolatedWorkerId -StorageScope "job"

    $isolatedTransactionResult = ConvertTo-RelayHashtable -InputObject (Invoke-PhaseExecutionTransaction `
            -JobSpec ([ordered]@{ job_id = $isolatedWorkerId; task_id = $taskId }) `
            -PromptText $isolatedPromptText `
            -ProjectRoot $tempRoot `
            -WorkingDirectory $isolatedRoot `
            -TimeoutPolicy ([ordered]@{}) `
            -RunId $runId `
            -PhaseName "Phase5" `
            -PhaseDefinition $phaseDefinition `
            -TaskId $taskId `
            -PhaseStartedAtUtc ([datetime]::UtcNow.AddMinutes(-2)) `
            -ArtifactStorageScope "job" `
            -CommitValidatedArtifacts:$false)

    $isolatedValidationStatus = ConvertTo-RelayHashtable -InputObject $isolatedTransactionResult["validation_result"]["validation"]
    Assert-True ([bool]$isolatedValidationStatus["valid"]) "Isolated worker artifacts should be synced into main job storage before validation."
    Assert-True (Test-Path -LiteralPath $isolatedPromptJsonPath -PathType Leaf) "Provider should write artifacts inside the isolated workspace."
    Assert-True (Test-Path -LiteralPath $mainJobJsonPath -PathType Leaf) "Transaction should copy isolated job artifacts back to the main job artifact root."
    $workspaceArtifactSync = ConvertTo-RelayHashtable -InputObject $isolatedTransactionResult["workspace_artifact_sync"]
    Assert-True ([bool]$workspaceArtifactSync["synced"]) "Transaction result should report isolated artifact sync."
    Assert-Equal ([int]$workspaceArtifactSync["copied_count"]) 2 "Both required Phase5 artifacts should be synced from the isolated workspace."
    $isolatedMaterializedJson = @($isolatedTransactionResult["output_sync_result"]["materialized"] | Where-Object { [string]$_["artifact_id"] -eq "phase5_result.json" })[0]
    Assert-Equal ([string]$isolatedMaterializedJson["path"]) $mainJobJsonPath "Validator should materialize the synced main job artifact path."

    $fallbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-artifacts-fallback-" + [guid]::NewGuid().ToString("N"))
    $fallbackWorkerId = "worker-artifacts-fallback"
    $fallbackSourceDir = Join-Path $fallbackRoot "artifacts\attempts\attempt-fake\tasks\$taskId\Phase5"
    New-Item -ItemType Directory -Path $fallbackSourceDir -Force | Out-Null
    Set-Content -Path (Join-Path $fallbackSourceDir "phase5_implementation.md") -Value "fallback implementation" -Encoding UTF8
    Set-Content -Path (Join-Path $fallbackSourceDir "phase5_result.json") -Value (@{
            task_id = $taskId
            changed_files = @()
            commands_run = @()
            implementation_summary = "fallback"
            acceptance_criteria_status = @()
            known_issues = @()
        } | ConvertTo-Json -Depth 20) -Encoding UTF8

    $fallbackSync = ConvertTo-RelayHashtable -InputObject (Sync-PhaseExecutionWorkspaceJobArtifacts -ProjectRoot $tempRoot -WorkingDirectory $fallbackRoot -RunId $runId -JobId $fallbackWorkerId)
    $fallbackTargetJsonPath = Join-Path $tempRoot "runs\$runId\jobs\$fallbackWorkerId\artifacts\attempts\attempt-fake\tasks\$taskId\Phase5\phase5_result.json"
    Assert-True ([bool]$fallbackSync["synced"]) "Workspace artifact sync should accept sandbox fallback artifacts rooted at workspace/artifacts."
    Assert-True (Test-Path -LiteralPath $fallbackTargetJsonPath -PathType Leaf) "Fallback workspace artifacts should be copied into the main job artifact root."

    $relativeJobWorkerId = "worker-artifacts-relative-job"
    $relativeJobSourceDir = Join-Path $fallbackRoot "jobs\$relativeJobWorkerId\artifacts\attempts\attempt-fake\tasks\$taskId\Phase5"
    New-Item -ItemType Directory -Path $relativeJobSourceDir -Force | Out-Null
    Set-Content -Path (Join-Path $relativeJobSourceDir "phase5_implementation.md") -Value "relative job implementation" -Encoding UTF8
    Set-Content -Path (Join-Path $relativeJobSourceDir "phase5_result.json") -Value (@{
            task_id = $taskId
            changed_files = @()
            commands_run = @()
            implementation_summary = "relative job"
            acceptance_criteria_status = @()
            known_issues = @()
        } | ConvertTo-Json -Depth 20) -Encoding UTF8

    $relativeJobSync = ConvertTo-RelayHashtable -InputObject (Sync-PhaseExecutionWorkspaceJobArtifacts -ProjectRoot $tempRoot -WorkingDirectory $fallbackRoot -RunId $runId -JobId $relativeJobWorkerId)
    $relativeJobTargetJsonPath = Join-Path $tempRoot "runs\$runId\jobs\$relativeJobWorkerId\artifacts\attempts\attempt-fake\tasks\$taskId\Phase5\phase5_result.json"
    Assert-True ([bool]$relativeJobSync["synced"]) "Workspace artifact sync should accept sandbox artifacts rooted at workspace/jobs/<job>/artifacts."
    Assert-True (Test-Path -LiteralPath $relativeJobTargetJsonPath -PathType Leaf) "Relative job artifacts should be copied into the main job artifact root."

    $looseRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-artifacts-loose-" + [guid]::NewGuid().ToString("N"))
    $looseWorkerId = "worker-artifacts-loose"
    $looseAttemptId = "attempt-loose"
    New-Item -ItemType Directory -Path $looseRoot -Force | Out-Null
    Set-Content -Path (Join-Path $looseRoot "phase5-1_completion_check.md") -Value "loose completion check" -Encoding UTF8
    Set-Content -Path (Join-Path $looseRoot "phase5-1_verdict.json") -Value (@{
            verdict = "go"
            findings = @()
            summary = "loose root artifact"
        } | ConvertTo-Json -Depth 20) -Encoding UTF8

    $phase51Definition = Get-Phase51Definition
    $looseSync = ConvertTo-RelayHashtable -InputObject (Sync-PhaseExecutionWorkspaceJobArtifacts -ProjectRoot $tempRoot -WorkingDirectory $looseRoot -RunId $runId -JobId $looseWorkerId -PhaseName "Phase5-1" -PhaseDefinition $phase51Definition -TaskId $taskId -AttemptId $looseAttemptId -StorageScope "attempt")
    $phase51ContractItems = @($phase51Definition["output_contract"])
    $looseTargetJsonPath = Resolve-PhaseContractArtifactPath -ProjectRoot $tempRoot -RunId $runId -PhaseName "Phase5-1" -ContractItem $phase51ContractItems[1] -TaskId $taskId -JobId $looseWorkerId -AttemptId $looseAttemptId -StorageScope "attempt"
    Assert-True ([bool]$looseSync["synced"]) "Workspace artifact sync should recover contract artifacts written directly to the workspace root."
    Assert-Equal ([int]$looseSync["copied_count"]) 2 "Both loose Phase5-1 artifacts should be synced into attempt storage."
    Assert-True (Test-Path -LiteralPath $looseTargetJsonPath -PathType Leaf) "Loose root artifacts should be copied into the expected attempt artifact path."

    $looseBoundaryRoot = Join-Path $looseRoot "boundary"
    New-Item -ItemType Directory -Path $looseBoundaryRoot -Force | Out-Null
    $looseBoundaryBaseline = New-WorkspaceBaselineSnapshot -WorkspaceRoot $looseBoundaryRoot
    Set-Content -Path (Join-Path $looseBoundaryRoot "phase5-1_completion_check.md") -Value "loose boundary check" -Encoding UTF8
    Set-Content -Path (Join-Path $looseBoundaryRoot "phase5-1_verdict.json") -Value "{}" -Encoding UTF8
    Set-Content -Path (Join-Path $looseBoundaryRoot "probe.txt") -Value "provider write probe" -Encoding UTF8
    $jobArtifactDir = Join-Path $looseBoundaryRoot "jobs\worker-artifacts-boundary\artifacts\attempts\attempt-fake\tasks\$taskId\Phase5-1"
    New-Item -ItemType Directory -Path $jobArtifactDir -Force | Out-Null
    Set-Content -Path (Join-Path $jobArtifactDir "phase5-1_verdict.json") -Value "{}" -Encoding UTF8
    $seedTaskPath = Join-Path $looseBoundaryRoot "relay-dev\tasks\task.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $seedTaskPath) -Force | Out-Null
    Set-Content -Path $seedTaskPath -Value "control plane seed scratch" -Encoding UTF8
    $nestedGitIndexPath = Join-Path $looseBoundaryRoot "relay-dev\.git\index"
    New-Item -ItemType Directory -Path (Split-Path -Parent $nestedGitIndexPath) -Force | Out-Null
    Set-Content -Path $nestedGitIndexPath -Value "nested git metadata scratch" -Encoding UTF8
    $looseBoundary = ConvertTo-RelayHashtable -InputObject (Test-WorkspaceBoundaryDelta -WorkspaceRoot $looseBoundaryRoot -BaselineSnapshot $looseBoundaryBaseline -DeclaredChangedFiles @() -AdditionalExcludePaths @("phase5-1_completion_check.md", "phase5-1_verdict.json", "probe.txt", "jobs", "relay-dev/tasks/task.md"))
    Assert-True ([bool]$looseBoundary["ok"]) "Workspace boundary checks should allow loose root, job-scoped contract artifacts, and provider probe files when the phase excludes them."

    $emptyMergeRoot = Join-Path $looseRoot "empty-merge-main"
    $emptyMergeWorkerRoot = Join-Path $looseRoot "empty-merge-worker"
    New-Item -ItemType Directory -Path $emptyMergeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $emptyMergeWorkerRoot -Force | Out-Null
    $emptyMergeBaseline = New-WorkspaceBaselineSnapshot -WorkspaceRoot $emptyMergeRoot
    $emptyMerge = ConvertTo-RelayHashtable -InputObject (Invoke-IsolatedWorkspaceMergeBack -MainWorkspace $emptyMergeRoot -IsolatedWorkspace $emptyMergeWorkerRoot -BaselineSnapshot $emptyMergeBaseline -AcceptedChangedFiles @())
    Assert-True ([bool]$emptyMerge["ok"]) "Workspace merge-back should accept reviewer workers with no product file changes."
    Assert-Equal (@($emptyMerge["copied_files"]).Count) 0 "Empty merge-back should not copy product files."
    Assert-Equal (@($emptyMerge["deleted_files"]).Count) 0 "Empty merge-back should not delete product files."
}
finally {
    if ($looseRoot -and (Test-Path -LiteralPath $looseRoot)) {
        Remove-Item -LiteralPath $looseRoot -Recurse -Force
    }
    if ($fallbackRoot -and (Test-Path -LiteralPath $fallbackRoot)) {
        Remove-Item -LiteralPath $fallbackRoot -Recurse -Force
    }
    if ($isolatedRoot -and (Test-Path -LiteralPath $isolatedRoot)) {
        Remove-Item -LiteralPath $isolatedRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-artifacts failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-artifacts passed." -ForegroundColor Green
exit 0
