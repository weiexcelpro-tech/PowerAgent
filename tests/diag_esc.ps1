# diag_esc.ps1 — 诊断 ESC 检测各环节
$ErrorActionPreference = "Continue"

# 1. 加载 PA_KeyStateHelper
Write-Host "[1] 加载 PowerAgent.ps1..." -ForegroundColor Cyan
. .\PowerAgent.ps1

Write-Host "[2] 测试 GetAsyncKeyState 直接调用..." -ForegroundColor Cyan
$r = [PA_KeyStateHelper]::IsEscapePressed()
Write-Host "  IsEscapePressed() = $r"

Write-Host "[3] 测试 Timer 回调中写 global 变量..." -ForegroundColor Cyan
$global:_TEST_FLAG = $false
$timer = New-Object System.Timers.Timer
$timer.Interval = 100
$timer.AutoReset = $true
$timer.add_Elapsed({
    $global:_TEST_FLAG = $true
})
$timer.Start()
Start-Sleep -Milliseconds 300
$timer.Stop()
$timer.Dispose()
Write-Host "  _TEST_FLAG (after 300ms) = $($global:_TEST_FLAG)"

Write-Host "[4] 测试 Timer 回调中 GetAsyncKeyState + 写 global..." -ForegroundColor Cyan
$global:_ESC_FLAG = $false
$timer2 = New-Object System.Timers.Timer
$timer2.Interval = 100
$timer2.AutoReset = $true
$timer2.add_Elapsed({
    if ([PA_KeyStateHelper]::IsEscapePressed()) {
        $global:_ESC_FLAG = $true
    }
})
$timer2.Start()
Write-Host "  Timer 已启动 — 请按 ESC，等待 2 秒..."
Start-Sleep -Seconds 2
$timer2.Stop()
$timer2.Dispose()
Write-Host "  _ESC_FLAG (你按了 ESC 吗?) = $($global:_ESC_FLAG)"

Write-Host "[5] 测试 Runspace 中的 GetAsyncKeyState..." -ForegroundColor Cyan
$global:_RS_FLAG = $false
$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs.Open()
$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $rs
$sb = {
    $count = 0
    while ($count -lt 20) {
        try {
            if ([PA_KeyStateHelper]::IsEscapePressed()) {
                $global:_RS_FLAG = $true
            }
        } catch {
            Write-Host "  Runspace error: $_" -ForegroundColor Red
            break
        }
        Start-Sleep -Milliseconds 100
        $count++
    }
}
$null = $ps.AddScript($sb.ToString())
$null = $ps.BeginInvoke()
Write-Host "  Runspace 已启动 — 请按 ESC，等待 2 秒..."
Start-Sleep -Seconds 2
$ps.Stop()
$ps.Dispose()
$rs.Dispose()
Write-Host "  _RS_FLAG (你按了 ESC 吗?) = $($global:_RS_FLAG)"

Write-Host ""
Write-Host "诊断完成。如果 [4] Timer 方案 _ESC_FLAG=true 而 Runspace 方案=false，" -ForegroundColor Yellow
Write-Host "说明 Timer 方案可行，应该用 Timer 替代 Runspace。" -ForegroundColor Yellow
