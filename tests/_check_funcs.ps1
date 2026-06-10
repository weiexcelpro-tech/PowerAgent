. (Join-Path $PSScriptRoot "..\PowerAgent.ps1")
$funcs = @("Initialize-Log","Write-Log","Initialize-SystemDirs","Import-Config","Start-AgentLoop","Invoke-RunTurn","Start-Daemon","Stop-Daemon")
foreach ($f in $funcs) {
    $cmd = Get-Command $f -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "FOUND: $f" } else { Write-Host "MISSING: $f" }
}
