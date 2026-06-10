# ============================================================================
#  PowerAgent Test Runner
#  Runs all Pester tests in the tests/ directory
#  Usage: .\tests\run_tests.ps1 [-TestFile <pattern>] [-Verbose]
# ============================================================================

param(
    [string]$TestFile = "*",
    [switch]$Verbose,
    [switch]$NoExit
)

# Resolve paths
$testDir = $PSScriptRoot
$rootDir = Split-Path $testDir -Parent

# Check Pester availability
$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1

if (-not $pesterModule) {
    Write-Host "[TEST] Pester not found. Installing Pester v5..." -ForegroundColor Yellow
    try {
        Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0
        $pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    } catch {
        Write-Host "[TEST] ERROR: Cannot install Pester. Run: Install-Module Pester -Force -Scope CurrentUser" -ForegroundColor Red
        exit 1
    }
}

Write-Host "[TEST] Using Pester v$($pesterModule.Version)" -ForegroundColor Cyan
Import-Module Pester -MinimumVersion 5.0.0 -Force

# Configure Pester
$config = New-PesterConfiguration
$config.Run.Path = $testDir
$config.Run.PassThru = $true
$config.Output.Verbosity = if ($Verbose) { "Detailed" } else { "Normal" }

# Filter by test file pattern
if ($TestFile -ne "*") {
    $config.Filter.FullName = "*$TestFile*"
}

# Dot-source merged PowerAgent file for test access
# All modules (ModelProfiles, Defaults, Utils, Config, Messages, HttpClient,
# Tools, Trace, Compression, AgentSystem, McpClient, AgentLoop, Daemon)
# are inlined in PowerAgent.ps1
$mergedFile = Join-Path $rootDir "PowerAgent.ps1"
if (Test-Path $mergedFile) {
    . $mergedFile
} else {
    Write-Host "[TEST] ERROR: PowerAgent.ps1 not found at $mergedFile" -ForegroundColor Red
    exit 1
}

# Pester v5 scope fix: promote all script-scope module variables to global scope
# Pester test files have their own $global: scope, so they can't see this file's
# $global: variables. Promoting to $global: makes them accessible via bare name.
Get-Variable -Scope Script | Where-Object {
    $_.Name -match '^(PA_|DEFAULT_|MCP_|SCRIPT_|LOG_|_CFG|_SP_|_ERR|ESC_|BOLD|DIM|GREEN|CYAN|YELLOW|RED|GRAY|ANSI_|RESET|_TOOLS_SCHEMA|_TRACE|TRACE_)' -or
    $_.Value -is [hashtable] -or $_.Value -is [array]
} | ForEach-Object {
    Set-Variable -Name $_.Name -Value $_.Value -Scope Global -ErrorAction SilentlyContinue
}

# Pester v5 scope fix: promote all dot-sourced functions to global scope
# Dot-sourced functions from PowerAgent.ps1 are in the caller's scope, but
# Pester v5's Describe/Context/It blocks have isolated scope and can't see them.
# Strategy: snapshot function names right after dot-source, then re-define all
# non-module (PowerAgent-defined) functions in global scope.
#
# IMPORTANT: Save definitions BEFORE promoting — PS5.1's Set-Item with string value
# creates working global functions but .Definition returns empty string. Tests that
# mock and restore functions (Daemon.Tests.ps1) need the original definitions.
$script:_paFnNames = @()
$global:_PA_ORIGINAL_FN_DEFS = @{}
Get-ChildItem function: | Where-Object { $_.Module -eq $null } | ForEach-Object {
    $script:_paFnNames += $_.Name
    # Save ORIGINAL definition BEFORE promotion (for mock restore in test files)
    $global:_PA_ORIGINAL_FN_DEFS[$_.Name] = $_.Definition
    # Copy each function to global scope so Pester Describe/Context/It can see it
    Set-Item -Path "function:global:$($_.Name)" -Value $_.Definition -ErrorAction SilentlyContinue
}

# Remove script-scope originals so global mocks aren't shadowed.
# After promotion, both script-scope and global-scope copies exist.
# When a promoted function (e.g. Test-TurnBudget) calls a sub-function
# (e.g. Estimate-ContextTokens), PS5.1 scope resolution finds the
# script-scope original BEFORE reaching the global mock. Deleting
# script-scope copies ensures global mocks are the only visible definitions.
$script:_paFnNames | ForEach-Object {
    Remove-Item "Function:\$_" -ErrorAction SilentlyContinue
}

# Set test environment variables (prevent real API calls)
$env:PA_API_KEY = "test-key-12345"
$env:PA_API_URL = "http://localhost:9999/v1/messages"
$env:PA_MODEL = "test-model"
$env:PA_MCP_ENABLED = "false"
$env:PA_TRACE_ENABLED = "0"
$env:PA_MEMORY_ENABLED = "false"
$env:PA_TODO_ENABLED = "false"
$env:PA_LOG_LEVEL = "ERROR"
$env:PA_DAEMON_PORT = "19999"
# Clear DEEPSEEK_API_KEY to prevent E2E live tests from running
$script:savedDeepseekKey = $env:DEEPSEEK_API_KEY
$env:DEEPSEEK_API_KEY = $null

# Run tests
Write-Host "[TEST] Running PowerAgent test suite..." -ForegroundColor Cyan
Write-Host "[TEST] Test directory: $testDir" -ForegroundColor Gray

$result = Invoke-Pester -Configuration $config

# Summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PowerAgent Test Results" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Passed:  $($result.PassedCount)" -ForegroundColor Green
Write-Host "  Failed:  $($result.FailedCount)" -ForegroundColor Red
Write-Host "  Skipped: $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "  Total:   $($result.TotalCount)" -ForegroundColor White
Write-Host "  Duration: $([Math]::Round($result.Duration.TotalSeconds, 2))s" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan

if (-not $NoExit) {
    if ($result.FailedCount -gt 0) {
        exit 1
    }
    exit 0
}
