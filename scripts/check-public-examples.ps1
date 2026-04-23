#requires -Version 7.0

param(
    [string]$ExamplesRoot = "examples"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedExamplesRoot = if ([System.IO.Path]::IsPathRooted($ExamplesRoot)) {
    $ExamplesRoot
}
else {
    Join-Path $repoRoot $ExamplesRoot
}

if (-not (Test-Path $resolvedExamplesRoot)) {
    Write-Host "No examples directory found; skipping public example checks."
    exit 0
}

$failures = New-Object System.Collections.Generic.List[string]
$publicExamples = @(
    Get-ChildItem -Path $resolvedExamplesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "example-manifest.json") }
)

if ($publicExamples.Count -eq 0) {
    Write-Host "No manifest-backed public examples found; skipping public example checks."
    exit 0
}

$requiredManifestKeys = @(
    "source_run_id",
    "sanitized_at",
    "included_artifacts",
    "redaction_notes",
    "validator_status"
)

$textExtensions = @(".md", ".json", ".yaml", ".yml", ".txt", ".ps1", ".sh", ".csv", ".tsv")
$absolutePathPatterns = @(
    '[A-Za-z]:[\\/]',
    '/Users/',
    '/home/',
    '/var/folders/',
    '/tmp/'
)
$secretPatterns = @(
    '(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*["'']?(?!YOUR_|REDACTED|redacted|placeholder|example)[A-Za-z0-9_\-]{12,}',
    '(?i)-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
)

foreach ($example in $publicExamples) {
    $manifestPath = Join-Path $example.FullName "example-manifest.json"
    try {
        $manifest = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $failures.Add("$manifestPath is not valid JSON: $($_.Exception.Message)")
        continue
    }

    foreach ($key in $requiredManifestKeys) {
        if ($null -eq $manifest.PSObject.Properties[$key] -or [string]::IsNullOrWhiteSpace([string]$manifest.$key)) {
            $failures.Add("$manifestPath is missing required manifest key '$key'.")
        }
    }

    $files = @(Get-ChildItem -Path $example.FullName -Recurse -File -Force)
    foreach ($file in $files) {
        $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)
        $pathParts = $relativePath -split '[\\/]'

        if ($pathParts -contains "runs") {
            $failures.Add("$relativePath must not include raw runs/ content.")
        }
        if ($pathParts -contains "jobs") {
            $failures.Add("$relativePath must not include raw provider job logs.")
        }
        if ($file.Extension -match '^\.log(\..*)?$' -or $file.Name -in @("stdout.txt", "stderr.txt")) {
            $failures.Add("$relativePath looks like a raw log file and should be summarized or redacted.")
        }

        if ($file.Extension.ToLowerInvariant() -notin $textExtensions) {
            continue
        }

        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($pattern in $absolutePathPatterns) {
            if ($content -match $pattern) {
                $failures.Add("$relativePath contains a local absolute path pattern: $pattern")
            }
        }
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern) {
                $failures.Add("$relativePath contains a possible secret pattern: $pattern")
            }
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "Public example checks failed."
}

Write-Host "Public example checks passed for $($publicExamples.Count) example(s)."
