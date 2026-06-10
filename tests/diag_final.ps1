# diag_final.ps1 — 最终诊断：Timer 在 PowerShell sleep vs .NET I/O wait 下的行为差异
$ErrorActionPreference = "Continue"

Write-Host "===== Timer 在不同阻塞模式下的行为 =====" -ForegroundColor Cyan
Write-Host ""

# 只测试核心问题：Timer 回调是否能在不同阻塞模式下触发
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class P {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int v);
}
'@

# 测试1: Start-Sleep 阻塞
Write-Host "[1] Start-Sleep 阻塞中 Timer 能否触发..." -ForegroundColor Yellow
$c = 0
$t = New-Object System.Timers.Timer
$t.Interval = 100; $t.AutoReset = $true
$t.add_Elapsed({ $global:c1 = ++$script:c })
$script:c = 0; $global:c1 = 0
$t.Start()
Start-Sleep -Seconds 1
$t.Stop(); $t.Dispose()
Write-Host "    触发次数: $global:c1 (期望 >5)" -NoNewline
if ($global:c1 -gt 0) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }

# 测试2: HttpWebRequest 阻塞中 Timer 能否触发
Write-Host "[2] HttpWebRequest 阻塞中 Timer 能否触发..." -ForegroundColor Yellow
$script:c = 0; $global:c1 = 0
$t2 = New-Object System.Timers.Timer
$t2.Interval = 100; $t2.AutoReset = $true
$t2.add_Elapsed({ $global:c2 = ++$script:c })
$t2.Start()
try {
    $req = [System.Net.HttpWebRequest]::Create("https://httpbin.org/delay/2")
    $req.Timeout = 5000
    $req.Method = "GET"
    $resp = $req.GetResponse()
    $resp.Close()
} catch {
    # Expected if network is unavailable
}
$t2.Stop(); $t2.Dispose()
Write-Host "    触发次数: $global:c2 (期望 >5)" -NoNewline
if ($global:c2 -gt 0) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [FAIL]" -ForegroundColor Red }

# 测试3: 在 HttpWebRequest 阻塞中，直接（主线程）调用 GetAsyncKeyState 能否读取 ESC
Write-Host "[3] HttpWebRequest 阻塞时 GetAsyncKeyState 能否在主线程读取 ESC..." -ForegroundColor Yellow
Write-Host "    启动测试 — 请按 ESC..." -ForegroundColor White
$found = $false
try {
    $req2 = [System.Net.HttpWebRequest]::Create("https://httpbin.org/delay/3")
    $req2.Timeout = 6000
    $req2.Method = "GET"
    $async = $req2.BeginGetResponse($null, $null)
    $deadline = (Get-Date).AddSeconds(3)
    while (-not $async.IsCompleted -and (Get-Date) -lt $deadline) {
        if (([P]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) {
            $found = $true
            $req2.Abort()
            break
        }
        Start-Sleep -Milliseconds 30
    }
    if (-not $found) { try { $req2.EndGetResponse($async).Close() } catch {} }
} catch { }
Write-Host "    ESC 检测: $found" -NoNewline
if ($found) { Write-Host " [PASS]" -ForegroundColor Green } else { Write-Host " [INFO] (你按 ESC 了吗?)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "===== 结论 =====" -ForegroundColor Cyan
if ($global:c1 -eq 0) { Write-Host "  Timer 在 Start-Sleep 期间不触发 → 测试脚本不可靠" -ForegroundColor Red }
if ($global:c2 -gt 0) { Write-Host "  Timer 在 HttpWebRequest 期间触发 → Spinner 中的 ESC 检测理论上可行" -ForegroundColor Green }
if ($global:c2 -eq 0) { Write-Host "  Timer 在 HttpWebRequest 期间也不触发 → 必须换方案" -ForegroundColor Red }
Write-Host "  最终推荐: TEST 3 的方案（主线程异步轮询）最可靠" -ForegroundColor Cyan
