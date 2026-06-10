$query = 'OpenClaw AI agent'
$url = 'https://api.duckduckgo.com/?q=' + [uri]::EscapeDataString($query) + '&format=json'
try {
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
    Write-Host "=== Abstract ==="
    Write-Host $r.Abstract
    Write-Host "=== AbstractText ==="
    Write-Host $r.AbstractText
    Write-Host "=== AbstractSource ==="
    Write-Host $r.AbstractSource
    Write-Host "=== RelatedTopics (first 10) ==="
    $r.RelatedTopics | Select-Object -First 10 | ForEach-Object { Write-Host "- $($_.Text)" }
} catch {
    Write-Host "Error: $_"
}
