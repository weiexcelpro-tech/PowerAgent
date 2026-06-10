$t = $null
$e = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "..\PowerAgent.ps1"),
    [ref]$t,
    [ref]$e
)
Write-Host ("Parse errors: " + $e.Count)
foreach ($err in $e | Select-Object -First 20) {
    Write-Host ("  Line " + $err.Extent.StartLineNumber + ": " + $err.Message)
}
