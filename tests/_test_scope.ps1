# Test: Check if functions defined after Start-PowerAgent are visible inside it
$ErrorActionPreference = 'Continue'
$paFile = Join-Path $PSScriptRoot "..\PowerAgent.ps1"

# Direct execution test
Write-Host "=== Test 1: Direct execution ==="
$env:PA_ONESHOT_PROMPT = "回复OK"
$env:PA_MCP_ENABLED = "false"
& $paFile --oneshot 2>&1 | Select-Object -First 5

Write-Host ""
Write-Host "=== Test 2: Dot-source execution ==="
. $paFile
Write-Host "Functions available:"
Get-Command Initialize-Log -ErrorAction SilentlyContinue | Select-Object Name
Get-Command Start-PowerAgent -ErrorAction SilentlyContinue | Select-Object Name
