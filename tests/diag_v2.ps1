# diag_v2.ps1 — 模拟真实的 Spinner → ESC 检测链路
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "===== 真实链路诊断 =====" -ForegroundColor Cyan

# 1. 编译类型
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PA_KeyStateHelper {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    public const int VK_ESCAPE = 0x1B;
    public static bool IsEscapePressed() {
        return (GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0;
    }
}
'@ -ErrorAction SilentlyContinue

# 2. 模拟真实的 Start-SpinnerBg（完全复制 PowerAgent.ps1 中的实现）
$global:_ESC_MONITOR_ACTIVE = $true
$global:_ESC_RELEASED = $true
$global:_ESC_PRESSED = $false
$global:_ACTIVE_WEB_REQUEST = $null
$global:_TIMER_FIRE_COUNT = 0

$timer = New-Object System.Timers.Timer
$timer.Interval = 100
$timer.AutoReset = $true   # ← 使用 true，和真实 Spinner 一致
$timer.add_Elapsed({
    $global:_TIMER_FIRE_COUNT++
    if ($global:_ESC_MONITOR_ACTIVE) {
        try {
            if ([PA_KeyStateHelper]::IsEscapePressed()) {
                if ($global:_ESC_RELEASED) {
                    $global:_ESC_PRESSED = $true
                    $global:_ESC_RELEASED = $false
                }
            } else {
                $global:_ESC_RELEASED = $true
            }
        } catch { }
    }
})
$timer.Start()

Write-Host "Timer 运行中 (AutoReset=true, Interval=100ms)" -ForegroundColor White
Write-Host "请在 3 秒内按 ESC..." -ForegroundColor Yellow
Write-Host ""

Start-Sleep -Seconds 3

$timer.Stop()
$timer.Dispose()

Write-Host ""
Write-Host "===== 结果 =====" -ForegroundColor Cyan
Write-Host "Timer 触发次数: $($global:_TIMER_FIRE_COUNT)"
Write-Host "_ESC_PRESSED:    $($global:_ESC_PRESSED)"
Write-Host "_ESC_RELEASED:   $($global:_ESC_RELEASED)"
Write-Host ""

if ($global:_TIMER_FIRE_COUNT -eq 0) {
    Write-Host "[结论] Timer 回调完全未触发！可能 PowerAgent.ps1 也未生效" -ForegroundColor Red
} elseif ($global:_ESC_PRESSED) {
    Write-Host "[结论] ESC 检测成功！" -ForegroundColor Green
} else {
    Write-Host "[结论] Timer 触发了 ($($global:_TIMER_FIRE_COUNT) 次)，但 ESC 未被检测到" -ForegroundColor Yellow
    Write-Host "  可能原因:" -ForegroundColor Yellow
    Write-Host "  1. 你没有在 3 秒内按 ESC" -ForegroundColor DarkGray
    Write-Host "  2. GetAsyncKeyState 在 ThreadPool 线程不可用" -ForegroundColor DarkGray
}
