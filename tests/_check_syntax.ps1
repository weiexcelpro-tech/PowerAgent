$files = @(
    'C:\Work\202606\Bash-agent\PowerAgent\tests\E2E.Tests.ps1',
    'C:\Work\202606\Bash-agent\PowerAgent\tests\E2E.Live.Tests.ps1'
)
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors) | Out-Null
    $name = Split-Path $f -Leaf
    if ($errors.Count -eq 0) {
        Write-Host "${name}: OK (0 parse errors)"
    } else {
        Write-Host "${name}: $($errors.Count) parse errors"
        foreach ($e in $errors) { Write-Host "  $($e.Message)" }
    }
}
