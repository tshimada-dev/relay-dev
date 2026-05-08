$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\run-lock.ps1")
. (Join-Path $repoRoot "app\core\parallel-launcher.ps1")

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

function New-CoordinatorFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$WorkerIds,
        [string[]]$FailWorkers = @()
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("relay-task-group-coordinator-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $runId = "run-coordinator-$Name"
    $groupId = "group-$Name"
    $state = New-RunState -RunId $runId -ProjectRoot $tempRoot -TaskId "task-main" -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state["task_groups"][$groupId] = [ordered]@{
        id = $groupId
        group_id = $groupId
        status = "planned"
        phase = "Phase5..Phase6"
        phase_range = "Phase5..Phase6"
        task_ids = @($WorkerIds | ForEach-Object { "T-$_" })
        worker_ids = @($WorkerIds)
        failure_summary = $null
    }

    $workerPackages = New-Object System.Collections.Generic.List[object]
    foreach ($workerId in $WorkerIds) {
        $taskId = "T-$workerId"
        $state["task_group_workers"][$workerId] = [ordered]@{
            id = $workerId
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            status = "queued"
            phase = "Phase5"
            current_phase = "Phase5"
            phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
            workspace_path = Join-Path $tempRoot "workspace-$workerId"
            artifact_root = Join-Path $tempRoot "artifacts-$workerId"
            declared_changed_files = @("src/$taskId.txt")
            resource_locks = @("lock-$taskId")
            errors = @()
            artifact_refs = @()
        }
        $workerPackages.Add([ordered]@{
            worker_id = $workerId
            group_id = $groupId
            task_id = $taskId
            phase_sequence = @("Phase5", "Phase5-1", "Phase5-2", "Phase6")
            selected_task = [ordered]@{ task_id = $taskId; purpose = "coordinator $Name" }
            workspace_path = Join-Path $tempRoot "workspace-$workerId"
            artifact_root = Join-Path $tempRoot "artifacts-$workerId"
            declared_changed_files = @("src/$taskId.txt")
            resource_locks = @("lock-$taskId")
            lease_token = "lease-$workerId"
            test_should_fail = ($workerId -in $FailWorkers)
        }) | Out-Null
    }
    Write-RunState -ProjectRoot $tempRoot -RunState $state | Out-Null

    $package = [ordered]@{
        schema_version = 1
        package_kind = "task-group-leased-package"
        run_id = $runId
        group_id = $groupId
        phase_range = "Phase5..Phase6"
        created_at = (Get-Date).ToString("o")
        workers = @($workerPackages.ToArray())
        provider_spec = [ordered]@{ provider = "fake"; command = "fake"; flags = "" }
        workspace_mode = "isolated-copy-experimental"
        commit_policy = "all_or_nothing"
    }
    $packageDir = Get-RunJobPath -ProjectRoot $tempRoot -RunId $runId -JobId $groupId
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    $packagePath = Join-Path $packageDir "task-group-package.json"
    Set-Content -Path $packagePath -Value (($package | ConvertTo-Json -Depth 30) + "`n") -Encoding UTF8

    $fakeCliPath = Join-Path $tempRoot "fake-cli.ps1"
    Set-Content -Path $fakeCliPath -Encoding UTF8 -Value @'
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$JobPackageFile,
    [string]$WorkerId,
    [string]$ConfigFile
)
$ErrorActionPreference = "Stop"
$coreRoot = $env:RELAY_TEST_CORE_ROOT
. (Join-Path $coreRoot "run-state-store.ps1")
. (Join-Path $coreRoot "run-lock.ps1")
. (Join-Path $coreRoot "parallel-worker.ps1")
$package = ConvertTo-RelayHashtable -InputObject (Get-Content -LiteralPath $JobPackageFile -Raw -Encoding UTF8 | ConvertFrom-Json)
$worker = $null
foreach ($candidateRaw in @($package["workers"])) {
    $candidate = ConvertTo-RelayHashtable -InputObject $candidateRaw
    if ([string]$candidate["worker_id"] -eq $WorkerId) {
        $worker = $candidate
        break
    }
}
if (-not $worker) { throw "worker not found: $WorkerId" }
$runId = [string]$package["run_id"]
$groupId = [string]$package["group_id"]
$projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $JobPackageFile))))
Update-TaskGroupWorkerRunState -ProjectRoot $projectRoot -RunId $runId -WorkerId $WorkerId -Patch @{
    status = "running"; current_phase = "Phase5"; group_id = $groupId; task_id = [string]$worker["task_id"]
} | Out-Null
if ([bool]$worker["test_should_fail"]) {
    Start-Sleep -Milliseconds 150
    $result = [ordered]@{
        worker_id = $WorkerId; group_id = $groupId; task_id = [string]$worker["task_id"]; status = "failed"; final_phase = "Phase5"
        errors = @("planned failure"); artifact_refs = @(); changed_files = @($worker["declared_changed_files"]); workspace_path = [string]$worker["workspace_path"]
    }
    Update-TaskGroupWorkerRunState -ProjectRoot $projectRoot -RunId $runId -WorkerId $WorkerId -Patch @{
        status = "failed"; current_phase = "Phase5"; final_phase = "Phase5"; errors = @("planned failure"); worker_result = $result; result_summary = "failed"
    } | Out-Null
    $deadline = (Get-Date).AddSeconds(5)
    do {
        $state = Read-RunState -ProjectRoot $projectRoot -RunId $runId
        $workers = ConvertTo-RelayHashtable -InputObject $state["task_group_workers"]
        $runningSibling = $false
        foreach ($id in @($workers.Keys)) {
            if ([string]$id -ne $WorkerId -and [string](ConvertTo-RelayHashtable -InputObject $workers[$id])["status"] -eq "running") {
                $runningSibling = $true
            }
        }
        if ($runningSibling) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    $state = Read-RunState -ProjectRoot $projectRoot -RunId $runId
    $group = ConvertTo-RelayHashtable -InputObject $state["task_groups"][$groupId]
    Set-Content -Path (Join-Path $projectRoot "mid-flight-status.txt") -Value ([string]$group["status"]) -Encoding UTF8
    exit 20
}
Start-Sleep -Milliseconds 700
$successResult = [ordered]@{
    worker_id = $WorkerId; group_id = $groupId; task_id = [string]$worker["task_id"]; status = "succeeded"; final_phase = "Phase6"
    errors = @(); artifact_refs = @(); changed_files = @($worker["declared_changed_files"]); workspace_path = [string]$worker["workspace_path"]
}
Update-TaskGroupWorkerRunState -ProjectRoot $projectRoot -RunId $runId -WorkerId $WorkerId -Patch @{
    status = "succeeded"; current_phase = "Phase6"; final_phase = "Phase6"; errors = @(); worker_result = $successResult; result_summary = "succeeded"
} | Out-Null
exit 0
'@

    return [ordered]@{
        root = $tempRoot
        run_id = $runId
        group_id = $groupId
        package_path = $packagePath
        fake_cli_path = $fakeCliPath
    }
}

$env:RELAY_TEST_CORE_ROOT = Join-Path $repoRoot "app\core"

$successFixture = New-CoordinatorFixture -Name "success" -WorkerIds @("worker-a", "worker-b")
$successResult = Invoke-TaskGroupCoordinator -Package $successFixture["package_path"] -ProjectRoot $successFixture["root"] -CliPath $successFixture["fake_cli_path"] -PwshPath "pwsh"
$successState = Read-RunState -ProjectRoot $successFixture["root"] -RunId $successFixture["run_id"]
$successGroup = ConvertTo-RelayHashtable -InputObject $successState["task_groups"][$successFixture["group_id"]]
Assert-Equal $successResult["status"] "succeeded" "All successful workers should return group succeeded."
Assert-Equal $successGroup["status"] "succeeded" "All successful workers should persist group succeeded."
Assert-Equal @($successGroup["worker_results"]).Count 2 "Group should retain worker result summaries."
Assert-True ([bool]$successResult["all_succeeded"]) "Coordinator should expose all_succeeded for a succeeded group."

$partialFixture = New-CoordinatorFixture -Name "partial" -WorkerIds @("worker-fail", "worker-ok") -FailWorkers @("worker-fail")
$partialResult = Invoke-TaskGroupCoordinator -Package $partialFixture["package_path"] -ProjectRoot $partialFixture["root"] -CliPath $partialFixture["fake_cli_path"] -PwshPath "pwsh"
$partialState = Read-RunState -ProjectRoot $partialFixture["root"] -RunId $partialFixture["run_id"]
$partialGroup = ConvertTo-RelayHashtable -InputObject $partialState["task_groups"][$partialFixture["group_id"]]
$midFlightStatus = if (Test-Path (Join-Path $partialFixture["root"] "mid-flight-status.txt")) {
    Get-Content -Path (Join-Path $partialFixture["root"] "mid-flight-status.txt") -Raw -Encoding UTF8
}
else {
    ""
}
Assert-Equal $partialResult["status"] "partial_failed" "One failed and one successful worker should return group partial_failed."
Assert-Equal $partialGroup["status"] "partial_failed" "One failed and one successful worker should persist group partial_failed."
Assert-Equal ($midFlightStatus.Trim()) "running" "A failed worker while a sibling is still running should not make the group terminal failed."
Assert-Equal @($partialGroup["worker_results"]).Count 2 "Partial failure group should retain both worker result summaries."
Assert-True (-not [bool]$partialResult["all_succeeded"]) "Coordinator should expose all_succeeded=false for partial failure."

foreach ($fixture in @($successFixture, $partialFixture)) {
    if (Test-Path -LiteralPath $fixture["root"]) {
        Remove-Item -LiteralPath $fixture["root"] -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-group-parallel-coordinator failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-group-parallel-coordinator passed." -ForegroundColor Green
exit 0
