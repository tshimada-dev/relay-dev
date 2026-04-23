function Get-EventsPath {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    return (Join-Path (Get-RunRootPath -ProjectRoot $ProjectRoot -RunId $RunId) "events.jsonl")
}

function Append-Event {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Event
    )

    Ensure-RunDirectories -ProjectRoot $ProjectRoot -RunId $RunId
    $eventObject = ConvertTo-RelayHashtable -InputObject $Event
    if (-not $eventObject["at"]) {
        $eventObject["at"] = (Get-Date).ToString("o")
    }
    if (-not $eventObject["run_id"]) {
        $eventObject["run_id"] = $RunId
    }

    $json = $eventObject | ConvertTo-Json -Depth 20 -Compress
    Add-Content -Path (Get-EventsPath -ProjectRoot $ProjectRoot -RunId $RunId) -Value $json -Encoding UTF8
}

function Get-Events {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $path = Get-EventsPath -ProjectRoot $ProjectRoot -RunId $RunId
    if (-not (Test-Path $path)) {
        return @()
    }

    $events = @()
    foreach ($line in (Get-Content -Path $path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $events += ,(ConvertTo-RelayHashtable -InputObject ($line | ConvertFrom-Json))
    }
    return $events
}

function Get-LastEvent {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Type
    )

    $events = Get-Events -ProjectRoot $ProjectRoot -RunId $RunId
    return ($events | Where-Object { $_["type"] -eq $Type } | Select-Object -Last 1)
}

