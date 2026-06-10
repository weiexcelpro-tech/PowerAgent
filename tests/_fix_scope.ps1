# Temporary script to replace $script: with $global: in all files
$libDir = Join-Path $PSScriptRoot "..\lib"
$testDir = $PSScriptRoot

# Fix lib files (skip Defaults.ps1 - already done)
Get-ChildItem "$libDir\*.ps1" | Where-Object { $_.Name -ne 'Defaults.ps1' } | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    $fixed = $raw.Replace('$script:', '$global:')
    if ($raw -ne $fixed) {
        [IO.File]::WriteAllText($_.FullName, $fixed, [Text.Encoding]::UTF8)
        Write-Host "[lib] Updated: $($_.Name)"
    }
}

# Fix test files
Get-ChildItem "$testDir\*.Tests.ps1" | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    $fixed = $raw.Replace('$script:', '$global:')
    if ($raw -ne $fixed) {
        [IO.File]::WriteAllText($_.FullName, $fixed, [Text.Encoding]::UTF8)
        Write-Host "[test] Updated: $($_.Name)"
    }
}

# Fix run_tests.ps1
$runner = Join-Path $testDir "run_tests.ps1"
$raw = [IO.File]::ReadAllText($runner, [Text.Encoding]::UTF8)
$fixed = $raw.Replace('$script:', '$global:')
if ($raw -ne $fixed) {
    [IO.File]::WriteAllText($runner, $fixed, [Text.Encoding]::UTF8)
    Write-Host "[runner] Updated: run_tests.ps1"
}

Write-Host "Done."
