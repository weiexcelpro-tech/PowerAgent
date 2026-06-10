# Batch test runner - runs a single test file
# Usage: powershell -File run_batch.ps1 <TestFileName>
param(
    [Parameter(Mandatory=$true)]
    [string]$TestFile
)

Import-Module Pester -MinimumVersion 5.0.0 -Force

# Dot-source main file
$mergedFile = Join-Path $PSScriptRoot "..\PowerAgent.ps1"
if (-not (Test-Path $mergedFile)) {
    Write-Host "[BATCH] ERROR: PowerAgent.ps1 not found" -ForegroundColor Red
    exit 1
}

# Suppress Start-PowerAgent from running by setting env
$env:PA_MODE = "test"

. $mergedFile

# Promote script-scope vars to global for Pester
Get-Variable -Scope Script | Where-Object {
    $_.Value -is [hashtable] -or $_.Value -is [array]
} | ForEach-Object {
    Set-Variable -Name $_.Name -Value $_.Value -Scope Global -ErrorAction SilentlyContinue
}

# Test env vars
$env:PA_API_KEY = "test-key-12345"
$env:PA_API_URL = "http://localhost:9999/v1/messages"
$env:PA_MODEL = "test-model"
$env:PA_MCP_ENABLED = "false"
$env:PA_TRACE_ENABLED = "0"
$env:PA_MEMORY_ENABLED = "false"
$env:PA_TODO_ENABLED = "false"
$env:PA_LOG_LEVEL = "ERROR"
$env:PA_DAEMON_PORT = "19999"

$testPath = Join-Path $PSScriptRoot $TestFile
if (-not (Test-Path $testPath)) {
    Write-Host "[BATCH] ERROR: $TestFile not found" -ForegroundColor Red
    exit 1
}

$config = New-PesterConfiguration
$config.Run.Path = $testPath
$config.Output.Verbosity = "Detailed"
$config.Run.PassThru = $true

$r = Invoke-Pester -Configuration $config

Write-Host ""
Write-Host "=== $TestFile ===" -ForegroundColor Cyan
Write-Host "  Passed: $($r.PassedCount)" -ForegroundColor Green
Write-Host "  Failed: $($r.FailedCount)" -ForegroundColor Red
Write-Host "  Skipped: $($r.SkippedCount)" -ForegroundColor Yellow
Write-Host "  Total:  $($r.TotalCount)" -ForegroundColor White

if ($r.FailedCount -gt 0) {
    exit 1
}
