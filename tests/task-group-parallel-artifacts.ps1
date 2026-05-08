$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\artifact-validator.ps1")
. (Join-Path $repoRoot "app\core\phase-validation-pipeline.ps1")
. (Join-Path $repoRoot "app\core\phase-completion-committer.ps1")
. (Join-Path $repoRoot "app\phases\phase-common.ps1")
. (Join-Path $repoRoot "app\phases\phase5.ps1")

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
}
finally {
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
