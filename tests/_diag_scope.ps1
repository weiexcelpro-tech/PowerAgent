# Diagnostic: Check function visibility inside Pester v5
param()

$testDir = $PSScriptRoot
$rootDir = Split-Path $testDir -Parent

Import-Module Pester -MinimumVersion 5.0.0 -Force

# Dot-source
. (Join-Path $rootDir "PowerAgent.ps1")

# Promote functions
Get-ChildItem function: | Where-Object { $_.Module -eq $null } | ForEach-Object {
    Set-Item -Path "function:global:$($_.Name)" -Value $_.Definition -ErrorAction SilentlyContinue
}

# Verify promotion
Write-Host "=== BEFORE Invoke-Pester ==="
Write-Host "Build-ApiRequestBody exists: $(Test-Path function:global:Build-ApiRequestBody)"
Write-Host "Get-ApiHeaders exists: $(Test-Path function:global:Get-ApiHeaders)"
Write-Host "Invoke-ApiCall exists: $(Test-Path function:global:Invoke-ApiCall)"

# Set env vars
$env:PA_API_KEY = "test-key-12345"
$env:PA_API_URL = "http://localhost:9999"
$env:PA_MODEL = "test-model"
$env:PA_MCP_ENABLED = "false"
$env:PA_TRACE_ENABLED = "0"
$env:PA_MEMORY_ENABLED = "false"
$env:PA_TODO_ENABLED = "false"
$env:PA_LOG_LEVEL = "ERROR"
$env:DEEPSEEK_API_KEY = $null

# Create a minimal test file that checks scope
$diagTest = @'
Describe "Scope Diagnostics" {
    It "Can see Build-ApiRequestBody" {
        Write-Host "  Build-ApiRequestBody visible: $(Test-Path function:Build-ApiRequestBody)"
        Write-Host "  Build-ApiRequestBody global: $(Test-Path function:global:Build-ApiRequestBody)"
        { Get-Command Build-ApiRequestBody -ErrorAction Stop } | Should -Not -Throw
    }
    It "Can see Get-ApiHeaders" {
        Write-Host "  Get-ApiHeaders visible: $(Test-Path function:Get-ApiHeaders)"
        Write-Host "  Get-ApiHeaders global: $(Test-Path function:global:Get-ApiHeaders)"
        { Get-Command Get-ApiHeaders -ErrorAction Stop } | Should -Not -Throw
    }
    It "Can see Invoke-ApiCall" {
        Write-Host "  Invoke-ApiCall visible: $(Test-Path function:Invoke-ApiCall)"
        Write-Host "  Invoke-ApiCall global: $(Test-Path function:global:Invoke-ApiCall)"
        { Get-Command Invoke-ApiCall -ErrorAction Stop } | Should -Not -Throw
    }
}
'@

$diagFile = Join-Path $testDir "_scope_check.Tests.ps1"
$diagTest | Set-Content $diagFile -Encoding UTF8

$config = New-PesterConfiguration
$config.Run.Path = $testDir
$config.Filter.FullName = "*Scope Diagnostics*"
$config.Output.Verbosity = "Detailed"

Write-Host ""
Write-Host "=== INSIDE Invoke-Pester ==="
$result = Invoke-Pester -Configuration $config

Write-Host ""
Write-Host "=== AFTER Invoke-Pester ==="
Write-Host "Build-ApiRequestBody exists: $(Test-Path function:global:Build-ApiRequestBody)"

# Cleanup
Remove-Item $diagFile -ErrorAction SilentlyContinue
