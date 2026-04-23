param(
    [Parameter(Mandatory)][ValidateSet("implementer", "reviewer", "orchestrator")][string]$Role,
    [string]$ConfigFile = "config/settings.yaml",
    [switch]$InteractiveApproval
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $script:ProjectRoot
$script:Role = $Role
$script:LastWaitNoticeKey = $null

. (Join-Path $script:ProjectRoot "config/common.ps1")
. (Join-Path $script:ProjectRoot "lib/logging.ps1")
. (Join-Path $script:ProjectRoot "lib/settings.ps1")
. (Join-Path $script:ProjectRoot "app/core/run-state-store.ps1")

function Get-ApprovalActionSummary {
    param([AllowNull()]$Action)

    $actionObject = ConvertTo-RelayHashtable -InputObject $Action
    if (-not $actionObject) {
        return "no action"
    }

    $actionType = [string]$actionObject["type"]
    switch ($actionType) {
        "DispatchJob" {
            $phase = [string]$actionObject["phase"]
            $role = [string]$actionObject["role"]
            $taskId = [string]$actionObject["task_id"]
            if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                return "DispatchJob -> $phase [$role] task=$taskId"
            }

            return "DispatchJob -> $phase [$role]"
        }
        "Wait" {
            $reason = [string]$actionObject["reason"]
            if (-not [string]::IsNullOrWhiteSpace($reason)) {
                return "Wait ($reason)"
            }

            return "Wait"
        }
        "CompleteRun" { return "CompleteRun" }
        "FailRun" { return "FailRun" }
        default {
            if (-not [string]::IsNullOrWhiteSpace($actionType)) {
                return $actionType
            }

            return "unknown"
        }
    }
}

$Config = Read-Config -Path $ConfigFile
Initialize-Settings -Config $Config -Role $Role

$AppCli = Join-Path $script:ProjectRoot "app/cli.ps1"
if (-not (Test-Path $AppCli)) {
    throw "Missing CLI entrypoint: $AppCli"
}

Write-Log "Agent loop started (wrapper mode, polling: $($script:FallbackSec)s, role=$Role)" -Level Info

while ($true) {
    $runId = Resolve-ActiveRunId -ProjectRoot $script:ProjectRoot
    if (-not $runId) {
        Start-Sleep -Seconds $script:FallbackSec
        continue
    }

    $runState = Read-RunState -ProjectRoot $script:ProjectRoot -RunId $runId
    if (-not $runState) {
        Start-Sleep -Seconds $script:FallbackSec
        continue
    }

    $status = [string]$runState["status"]
    if ($status -in @("completed", "failed", "blocked")) {
        $script:LastWaitNoticeKey = $null
        Start-Sleep -Seconds $script:FallbackSec
        continue
    }

    if ($status -eq "waiting_approval") {
        $pendingApproval = ConvertTo-RelayHashtable -InputObject $runState["pending_approval"]
        $approvalId = if ($pendingApproval) { [string]$pendingApproval["approval_id"] } else { "" }
        $requestedPhase = if ($pendingApproval) { [string]$pendingApproval["requested_phase"] } else { [string]$runState["current_phase"] }
        $approveActionSummary = Get-ApprovalActionSummary -Action $pendingApproval["proposed_action"]
        $noticeKey = "waiting_approval:$approvalId"

        if ($InteractiveApproval -and $Role -eq "orchestrator") {
            if ($script:LastWaitNoticeKey -ne $noticeKey) {
                Write-Log "Approval pending for run '$runId' at $requestedPhase. Approve/Skip => $approveActionSummary. Prompting for a decision in the current terminal." -Level Warning
                $script:LastWaitNoticeKey = $noticeKey
            }
        }
        else {
            if ($script:LastWaitNoticeKey -ne $noticeKey) {
                Write-Log "Approval pending for run '$runId' at $requestedPhase. Approve/Skip => $approveActionSummary. Waiting for a user decision; this worker will not prompt in the current terminal." -Level Warning
                $script:LastWaitNoticeKey = $noticeKey
            }

            Start-Sleep -Seconds $script:FallbackSec
            continue
        }
    }

    $script:LastWaitNoticeKey = $null

    if ($Role -ne "orchestrator" -and [string]$runState["current_role"] -ne $Role) {
        Start-Sleep -Seconds $script:FallbackSec
        continue
    }

    try {
        $rawResult = & $AppCli step -ConfigFile $ConfigFile -RunId $runId
        $jsonLine = $null
        if ($rawResult -is [System.Array]) {
            $jsonLine = @($rawResult | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
            if ($jsonLine -is [System.Array]) {
                $jsonLine = ($jsonLine | Select-Object -Last 1)
            }
        }
        else {
            $jsonLine = [string]$rawResult
        }

        $parsedResult = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$jsonLine)) {
            $parsedResult = ConvertTo-RelayHashtable -InputObject ($jsonLine | ConvertFrom-Json)
        }

        if ($parsedResult) {
            $actionType = if ($parsedResult["mutation_action"]) {
                [string]$parsedResult["mutation_action"]["type"]
            }
            elseif ($parsedResult["applied_action"]) {
                [string]$parsedResult["applied_action"]["type"]
            }
            else {
                [string]$parsedResult["action"]["type"]
            }
            $phaseName = ""
            $statusLabel = ""
            if ($parsedResult["run_state"]) {
                $phaseName = [string]$parsedResult["run_state"]["current_phase"]
                $statusLabel = [string]$parsedResult["run_state"]["status"]
            }
            Write-Log "Wrapper step completed. action=$actionType phase=$phaseName status=$statusLabel run=$runId" -Level Info
        }
        else {
            Write-Log "Wrapper step completed without structured result. run=$runId" -Level Info
        }
    }
    catch {
        Write-Log "Wrapper step failed for run '$runId': $_" -Level Error
        Start-Sleep -Seconds $script:FallbackSec
        continue
    }

    Start-Sleep -Seconds 1
}
