$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "app\core\run-state-store.ps1")
. (Join-Path $repoRoot "app\core\artifact-repository.ps1")
. (Join-Path $repoRoot "app\core\workflow-engine.ps1")

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

function New-TestBoundaryContract {
    param([Parameter(Mandatory)][string]$ChangedFile)

    return [ordered]@{
        module_boundaries = @($ChangedFile)
        public_interfaces = @("file")
        allowed_dependencies = @()
        forbidden_dependencies = @()
        side_effect_boundaries = @("file")
        state_ownership = @("file")
    }
}

function New-TestVisualContract {
    return [ordered]@{
        mode = "not_applicable"
        design_sources = @()
        visual_constraints = @()
        component_patterns = @()
        responsive_expectations = @()
        interaction_guidelines = @()
    }
}

function New-TestTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ResourceLock
    )

    $changedFile = "parallel-test/$TaskId.txt"
    return [ordered]@{
        task_id = $TaskId
        purpose = "Headless parallel execution smoke for $TaskId"
        changed_files = @($changedFile)
        acceptance_criteria = @("parallel worker writes its declared file")
        boundary_contract = (New-TestBoundaryContract -ChangedFile $changedFile)
        visual_contract = (New-TestVisualContract)
        dependencies = @()
        tests = @("pwsh -NoProfile -File tests/task-parallelization-headless-execution.ps1")
        complexity = "small"
        resource_locks = @($ResourceLock)
        parallel_safety = "parallel"
    }
}

function Write-TestConfig {
    param([Parameter(Mandatory)][string]$Path)

    @'
cli:
  command: "copilot"
  flags: "--autopilot --yolo --max-autopilot-continues 30 -p"
  implementer_command: ""
  implementer_flags: ""
  reviewer_command: ""
  reviewer_flags: ""
escalation:
  phase1_timeout_sec: 300
  phase2_timeout_sec: 3600
  phase3_timeout_sec: 5400
watcher:
  poll_fallback_sec: 5
lock:
  retry_count: 30
  retry_delay_ms: 200
  timeout_sec: 300
log:
  directory: logs
  max_size_mb: 10
  rotation_count: 5
paths:
  project_dir: "."
  design_file: "DESIGN.md"
  status_file: queue/status.yaml
  lock_file: queue/status.lock
  dashboard_file: dashboard.md
  task_file: tasks/task.md
human_review:
  enabled: true
  phases:
    - Phase3-1
    - Phase4-1
    - Phase7
'@ | Set-Content -Path $Path -Encoding UTF8
}

function Write-TestProvider {
    param([Parameter(Mandatory)][string]$Path)

    @'
$ErrorActionPreference = "Stop"
$prompt = [Console]::In.ReadToEnd()
$taskId = if ($prompt -match "(?m)^TaskId:\s*(\S+)") { $Matches[1] } else { throw "missing TaskId" }
$changed = "parallel-test/$taskId.txt"
$mdPath = if ($prompt -match '(?m)phase5_implementation\.md\s*=>\s*(.+?)\s*\(write\)') { $Matches[1].Trim() } else { throw "missing phase5_implementation output path" }
$jsonPath = if ($prompt -match '(?m)phase5_result\.json\s*=>\s*(.+?)\s*\(write\)') { $Matches[1].Trim() } else { throw "missing phase5_result output path" }

Start-Sleep -Seconds 2

$productPath = Join-Path (Get-Location).Path ($changed -replace '/', [System.IO.Path]::DirectorySeparatorChar)
New-Item -ItemType Directory -Path (Split-Path -Parent $productPath) -Force | Out-Null
Set-Content -Path $productPath -Value "product $taskId" -Encoding UTF8

New-Item -ItemType Directory -Path (Split-Path -Parent $mdPath) -Force | Out-Null
Set-Content -Path $mdPath -Value "### Task Summary`n$taskId smoke implementation`n`n## 要約（200字以内）`nsmoke" -Encoding UTF8

$result = [ordered]@{
    task_id = $taskId
    changed_files = @($changed)
    commands_run = @("test-provider")
    implementation_summary = "parallel smoke $taskId"
    acceptance_criteria_status = @(
        [ordered]@{
            criterion = "parallel worker writes its declared file"
            status = "met"
            evidence = @($changed)
        }
    )
    known_issues = @()
}
New-Item -ItemType Directory -Path (Split-Path -Parent $jsonPath) -Force | Out-Null
Set-Content -Path $jsonPath -Value (($result | ConvertTo-Json -Depth 20) + "`n") -Encoding UTF8
Write-Output "wrote $taskId"
'@ | Set-Content -Path $Path -Encoding UTF8
}

$runId = "run-parallel-headless-test-" + ([guid]::NewGuid().ToString("N"))
$configPath = Join-Path ([System.IO.Path]::GetTempPath()) "relay-parallel-settings-$runId.yaml"
$providerPath = Join-Path ([System.IO.Path]::GetTempPath()) "relay-parallel-provider-$runId.ps1"
$productDir = Join-Path $repoRoot "parallel-test"

try {
    if (Test-Path -LiteralPath $productDir) {
        Remove-Item -LiteralPath $productDir -Recurse -Force
    }

    Write-TestConfig -Path $configPath
    Write-TestProvider -Path $providerPath

    $tasksArtifact = [ordered]@{
        tasks = @(
            (New-TestTask -TaskId "T-a" -ResourceLock "parallel-test-a"),
            (New-TestTask -TaskId "T-b" -ResourceLock "parallel-test-b")
        )
    }
    Save-Artifact -ProjectRoot $repoRoot -RunId $runId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $tasksArtifact -AsJson | Out-Null

    $state = New-RunState -RunId $runId -ProjectRoot $repoRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $state = Register-PlannedTasks -RunState $state -TasksArtifact $tasksArtifact
    $state["task_lane"]["mode"] = "parallel"
    $state["task_lane"]["max_parallel_jobs"] = 2
    Write-RunState -ProjectRoot $repoRoot -RunState $state | Out-Null

    $cliOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "app\cli.ps1") parallel-step -RunId $runId -ConfigFile $configPath -Provider generic-cli -ProviderCommand $providerPath 2>&1
    $jsonLine = @($cliOutput | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$jsonLine)) "parallel-step should emit a JSON summary."
    $summary = if (-not [string]::IsNullOrWhiteSpace([string]$jsonLine)) { $jsonLine | ConvertFrom-Json } else { $null }

    if ($summary) {
        Assert-Equal $summary.status "completed" "parallel-step should complete the worker batch."
        Assert-Equal $summary.leased_count 2 "parallel-step should lease two jobs."
        Assert-True ([bool]$summary.workers.all_succeeded) "all parallel workers should succeed."
        Assert-Equal $summary.workers.launched_count 2 "parallel-step should launch two workers."

        $workers = @($summary.workers.workers)
        if ($workers.Count -eq 2) {
            $latestStart = @($workers | ForEach-Object { [datetime]$_.started_at } | Sort-Object | Select-Object -Last 1)[0]
            $earliestFinish = @($workers | ForEach-Object { [datetime]$_.finished_at } | Sort-Object | Select-Object -First 1)[0]
            Assert-True ($latestStart -lt $earliestFinish) "worker execution windows should overlap."
        }
    }

    $finalState = Get-Content -Path (Join-Path $repoRoot "runs\$runId\run-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal @($finalState.active_jobs.PSObject.Properties).Count 0 "all active job leases should be cleared after successful commits."
    Assert-True (Test-Path -LiteralPath (Join-Path $productDir "T-a.txt") -PathType Leaf) "T-a product file should be merged back."
    Assert-True (Test-Path -LiteralPath (Join-Path $productDir "T-b.txt") -PathType Leaf) "T-b product file should be merged back."
    Assert-Equal $finalState.task_states."T-a".last_completed_phase "Phase5" "T-a should complete Phase5."
    Assert-Equal $finalState.task_states."T-b".last_completed_phase "Phase5" "T-b should complete Phase5."
}
finally {
    foreach ($path in @($configPath, $providerPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if (Test-Path -LiteralPath $productDir) {
        Remove-Item -LiteralPath $productDir -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "task-parallelization-headless-execution failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "task-parallelization-headless-execution passed." -ForegroundColor Green
