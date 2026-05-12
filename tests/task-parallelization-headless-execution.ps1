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
        [Parameter(Mandatory)][string]$ResourceLock,
        [string]$ParallelSafety = "parallel"
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
        parallel_safety = $ParallelSafety
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
execution:
  mode: auto
  max_parallel_jobs: 2
  allow_single_parallel_job: true
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
$taskId = if ($prompt -match "(?m)^TaskId:\s*(\S+)") {
    $Matches[1]
}
elseif ($prompt -match "for task\s+(\S+)") {
    $Matches[1].TrimEnd(".")
}
else {
    throw "missing TaskId"
}
$changed = "parallel-test/$taskId.txt"

function Get-OutputPath {
    param([Parameter(Mandatory)][string]$ArtifactId)

    $pattern = "(?m)$([regex]::Escape($ArtifactId))\s*=>\s*(.+?)\s*\(write\)"
    if ($prompt -match $pattern) {
        return $Matches[1].Trim()
    }

    return $null
}

function Write-TextArtifact {
    param(
        [string]$ArtifactId,
        [string]$Content
    )

    $path = Get-OutputPath -ArtifactId $ArtifactId
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -Path $path -Value $Content -Encoding UTF8
}

function Write-JsonArtifact {
    param(
        [string]$ArtifactId,
        $Content
    )

    $path = Get-OutputPath -ArtifactId $ArtifactId
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -Path $path -Value (($Content | ConvertTo-Json -Depth 20) + "`n") -Encoding UTF8
}

$phase5JsonPath = Get-OutputPath -ArtifactId "phase5_result.json"

Start-Sleep -Seconds 2

$productPath = Join-Path (Get-Location).Path ($changed -replace '/', [System.IO.Path]::DirectorySeparatorChar)
New-Item -ItemType Directory -Path (Split-Path -Parent $productPath) -Force | Out-Null
Set-Content -Path $productPath -Value "product $taskId" -Encoding UTF8

$pass = "pass"
$evidence = @($changed)

if (-not [string]::IsNullOrWhiteSpace($phase5JsonPath)) {
    Write-TextArtifact -ArtifactId "phase5_implementation.md" -Content "### Task Summary`n$taskId smoke implementation`n`n## 要約（200字以内）`nsmoke"
    Write-JsonArtifact -ArtifactId "phase5_result.json" -Content ([ordered]@{
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
    })
}
elseif (Get-OutputPath -ArtifactId "phase5-1_verdict.json") {
    Write-TextArtifact -ArtifactId "phase5-1_completion_check.md" -Content "completion check $taskId"
    $reviewChecks = @("selected_task_alignment", "acceptance_criteria_coverage", "changed_files_audit", "test_evidence_review", "design_boundary_alignment", "visual_contract_alignment") | ForEach-Object {
        [ordered]@{ check_id = $_; status = $pass; notes = "ok"; evidence = $evidence }
    }
    Write-JsonArtifact -ArtifactId "phase5-1_verdict.json" -Content ([ordered]@{
        task_id = $taskId
        verdict = "go"
        rollback_phase = ""
        must_fix = @()
        warnings = @()
        evidence = @($changed)
        acceptance_criteria_checks = @(
            [ordered]@{ criterion = "parallel worker writes its declared file"; status = "pass"; notes = "ok"; evidence = $evidence }
        )
        review_checks = @($reviewChecks)
    })
}
elseif (Get-OutputPath -ArtifactId "phase5-2_verdict.json") {
    Write-TextArtifact -ArtifactId "phase5-2_security_check.md" -Content "security check $taskId"
    $securityChecks = @("input_validation", "authentication_authorization", "secret_handling_and_logging", "dangerous_side_effects", "dependency_surface") | ForEach-Object {
        [ordered]@{ check_id = $_; status = $pass; notes = "ok"; evidence = $evidence }
    }
    Write-JsonArtifact -ArtifactId "phase5-2_verdict.json" -Content ([ordered]@{
        task_id = $taskId
        verdict = "go"
        rollback_phase = ""
        must_fix = @()
        warnings = @()
        evidence = @($changed)
        security_checks = @($securityChecks)
        open_requirements = @()
        resolved_requirement_ids = @()
    })
}
elseif (Get-OutputPath -ArtifactId "phase6_result.json") {
    Write-TextArtifact -ArtifactId "phase6_testing.md" -Content "testing $taskId"
    Write-TextArtifact -ArtifactId "test_output.log" -Content "ok $taskId"
    $verificationChecks = @("lint_static_analysis", "automated_tests", "regression_scope", "error_path_coverage", "coverage_assessment") | ForEach-Object {
        [ordered]@{ check_id = $_; status = $pass; notes = "ok"; evidence = $evidence }
    }
    Write-JsonArtifact -ArtifactId "phase6_result.json" -Content ([ordered]@{
        task_id = $taskId
        test_command = "test-provider"
        lint_command = "test-provider"
        tests_passed = 1
        tests_failed = 0
        coverage_line = 100
        coverage_branch = 100
        verdict = "go"
        rollback_phase = ""
        conditional_go_reasons = @()
        verification_checks = @($verificationChecks)
        open_requirements = @()
        resolved_requirement_ids = @()
    })
}
else {
    throw "missing known output path"
}
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

    if (Test-Path -LiteralPath $productDir) {
        Remove-Item -LiteralPath $productDir -Recurse -Force
    }

    $cautiousRunId = "$runId-cautious"
    $cautiousTasksArtifact = [ordered]@{
        tasks = @(
            (New-TestTask -TaskId "T-cautious-a" -ResourceLock "parallel-test-cautious-a" -ParallelSafety "cautious"),
            (New-TestTask -TaskId "T-cautious-b" -ResourceLock "parallel-test-cautious-b" -ParallelSafety "cautious")
        )
    }
    Save-Artifact -ProjectRoot $repoRoot -RunId $cautiousRunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $cautiousTasksArtifact -AsJson | Out-Null
    $cautiousState = New-RunState -RunId $cautiousRunId -ProjectRoot $repoRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $cautiousState = Register-PlannedTasks -RunState $cautiousState -TasksArtifact $cautiousTasksArtifact
    $cautiousState["task_lane"]["mode"] = "parallel"
    $cautiousState["task_lane"]["max_parallel_jobs"] = 2
    Write-RunState -ProjectRoot $repoRoot -RunState $cautiousState | Out-Null

    $cautiousDefaultOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "app\cli.ps1") parallel-step -RunId $cautiousRunId -ConfigFile $configPath -Provider generic-cli -ProviderCommand $providerPath 2>&1
    $cautiousDefaultJsonLine = @($cautiousDefaultOutput | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1)
    $cautiousDefaultSummary = if (-not [string]::IsNullOrWhiteSpace([string]$cautiousDefaultJsonLine)) { $cautiousDefaultJsonLine | ConvertFrom-Json } else { $null }
    if ($cautiousDefaultSummary) {
        Assert-Equal $cautiousDefaultSummary.status "wait" "parallel-step should reject cautious candidates by default."
        Assert-True ([string]$cautiousDefaultSummary.rejected_candidates[0].launchability.reason -like "*cautious*") "default cautious rejection should identify cautious safety."
    }

    $cautiousOptInOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "app\cli.ps1") parallel-step -RunId $cautiousRunId -ConfigFile $configPath -Provider generic-cli -ProviderCommand $providerPath -AllowCautiousParallelJob 2>&1
    $cautiousOptInJsonLine = @($cautiousOptInOutput | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$cautiousOptInJsonLine)) "cautious parallel-step should emit a JSON summary."
    $cautiousOptInSummary = if (-not [string]::IsNullOrWhiteSpace([string]$cautiousOptInJsonLine)) { $cautiousOptInJsonLine | ConvertFrom-Json } else { $null }
    if ($cautiousOptInSummary) {
        Assert-Equal $cautiousOptInSummary.status "completed" "cautious opt-in parallel-step should complete the worker batch."
        Assert-Equal $cautiousOptInSummary.leased_count 2 "cautious opt-in parallel-step should lease cautious jobs."
    }

    $script:ExecutionMode = "auto"
    $script:ExecutionMaxParallelJobs = 2
    $phase4State = New-RunState -RunId "$runId-phase4" -ProjectRoot $repoRoot -CurrentPhase "Phase4" -CurrentRole "implementer"
    $phase4Mutation = Apply-JobResult -RunState $phase4State -JobResult @{
        job_id = "job-phase4"
        phase = "Phase4"
        task_id = ""
        result_status = "succeeded"
        exit_code = 0
    } -ValidationResult @{ valid = $true } -Artifact $tasksArtifact -ProjectRoot $repoRoot -ApprovalPhases @()
    $phase4NextState = ConvertTo-RelayHashtable -InputObject $phase4Mutation["run_state"]
    Assert-Equal $phase4NextState["task_lane"]["mode"] "parallel" "Phase4 task registration should enable parallel lane in auto mode."
    Assert-Equal ([int]$phase4NextState["task_lane"]["max_parallel_jobs"]) 2 "Phase4 task registration should apply configured max_parallel_jobs."

    if (Test-Path -LiteralPath $productDir) {
        Remove-Item -LiteralPath $productDir -Recurse -Force
    }

    $autoRunId = "$runId-auto-step"
    Save-Artifact -ProjectRoot $repoRoot -RunId $autoRunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $tasksArtifact -AsJson | Out-Null
    $autoState = New-RunState -RunId $autoRunId -ProjectRoot $repoRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $autoState = Register-PlannedTasks -RunState $autoState -TasksArtifact $tasksArtifact
    $autoState["task_lane"]["mode"] = "parallel"
    $autoState["task_lane"]["max_parallel_jobs"] = 2
    Write-RunState -ProjectRoot $repoRoot -RunState $autoState | Out-Null

    $autoOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "app\cli.ps1") step -RunId $autoRunId -ConfigFile $configPath -Provider generic-cli -ProviderCommand $providerPath 2>&1
    $autoJsonLine = @($autoOutput | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$autoJsonLine)) "auto step should emit a JSON summary."
    $autoSummary = if (-not [string]::IsNullOrWhiteSpace([string]$autoJsonLine)) { $autoJsonLine | ConvertFrom-Json } else { $null }
    if ($autoSummary) {
        Assert-Equal $autoSummary.mode "task-group" "step should prefer task-group execution in auto mode for task-scoped parallel lanes."
        Assert-Equal $autoSummary.status "completed" "auto task-group step should complete the worker group."
        Assert-Equal $autoSummary.worker_count 2 "auto task-group step should run two workers."
    }

    if (Test-Path -LiteralPath $productDir) {
        Remove-Item -LiteralPath $productDir -Recurse -Force
    }

    $activeGroupRunId = "$runId-active-group"
    $activeGroupTasksArtifact = [ordered]@{
        tasks = @(
            (New-TestTask -TaskId "T-active-a" -ResourceLock "parallel-test-active-a"),
            (New-TestTask -TaskId "T-active-b" -ResourceLock "parallel-test-active-b")
        )
    }
    Save-Artifact -ProjectRoot $repoRoot -RunId $activeGroupRunId -Scope run -Phase "Phase4" -ArtifactId "phase4_tasks.json" -Content $activeGroupTasksArtifact -AsJson | Out-Null
    $activeGroupState = New-RunState -RunId $activeGroupRunId -ProjectRoot $repoRoot -CurrentPhase "Phase5" -CurrentRole "implementer"
    $activeGroupState = Register-PlannedTasks -RunState $activeGroupState -TasksArtifact $activeGroupTasksArtifact
    $activeGroupState["task_lane"]["mode"] = "parallel"
    $activeGroupState["task_lane"]["max_parallel_jobs"] = 2
    $activeGroupState["task_groups"]["task-group-active"] = [ordered]@{
        id = "task-group-active"
        group_id = "task-group-active"
        status = "running"
        phase = "Phase5..Phase6"
        phase_range = "Phase5..Phase6"
        task_ids = @("T-active-a")
        worker_ids = @("task-worker-active")
    }
    $activeGroupState["task_group_workers"]["task-worker-active"] = [ordered]@{
        id = "task-worker-active"
        worker_id = "task-worker-active"
        group_id = "task-group-active"
        task_id = "T-active-a"
        status = "running"
        phase = "Phase5"
        current_phase = "Phase5"
    }
    Write-RunState -ProjectRoot $repoRoot -RunState $activeGroupState | Out-Null

    $activeGroupOutput = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "app\cli.ps1") step -RunId $activeGroupRunId -ConfigFile $configPath -Provider generic-cli -ProviderCommand $providerPath 2>&1
    $activeGroupJsonLine = @($activeGroupOutput | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$activeGroupJsonLine)) "active task-group step should emit a JSON wait summary."
    $activeGroupSummary = if (-not [string]::IsNullOrWhiteSpace([string]$activeGroupJsonLine)) { $activeGroupJsonLine | ConvertFrom-Json } else { $null }
    if ($activeGroupSummary) {
        Assert-Equal $activeGroupSummary.mode "task-group" "active task group should keep step on the task-group path."
        Assert-Equal $activeGroupSummary.status "wait" "active task group should make step wait instead of falling back to single dispatch."
        Assert-Equal $activeGroupSummary.reason "task group already active" "active task group wait reason should be explicit."
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $productDir "T-active-a.txt"))) "active task group wait should not run a fallback provider for T-active-a."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $productDir "T-active-b.txt"))) "active task group wait should not run a fallback provider for T-active-b."
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
