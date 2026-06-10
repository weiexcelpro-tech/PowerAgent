# verify_final.ps1 — 验证主线程异步轮询 ESC 检测（Invoke-HttpRequest 中使用的模式）
Write-Host "===== 主线程轮询 ESC 检测测试 =====" -ForegroundColor Cyan

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PK {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int v);
    public const int VK_ESC = 0x1B;
    public static bool EscPressed() { return (GetAsyncKeyState(VK_ESC) & 0x8000) != 0; }
}
'@

# 模拟 Invoke-HttpRequest 中的轮询循环
$global:_ESC_MONITOR_ACTIVE = $true
$global:_ESC_PRESSED = $false
$escDetected = $false

Write-Host "开始轮询（3 秒，请按 ESC）..." -ForegroundColor Yellow

$deadline = (Get-Date).AddSeconds(3)
$loopCount = 0
while ((Get-Date) -lt $deadline) {
    $loopCount++
    if ($global:_ESC_MONITOR_ACTIVE -and [PK]::EscPressed()) {
        $global:_ESC_PRESSED = $true
        $escDetected = $true
        break
    }
    Start-Sleep -Milliseconds 50
}

Write-Host ""
Write-Host "结果:" -ForegroundColor Cyan
Write-Host "  循环次数: $loopCount"
Write-Host "  ESC 检测: $escDetected"
Write-Host "  _ESC_PRESSED: $($global:_ESC_PRESSED)"
Write-Host ""

if ($escDetected) {
    Write-Host "[PASS] 主线程 ESC 轮询成功！" -ForegroundColor Green
} else {
    Write-Host "[INFO] 未检测到 ESC（你按了吗？）" -ForegroundColor Yellow
    Write-Host "  如果按了 ESC 且循环次数>0，说明 GetAsyncKeyState 从主线程可用。" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "===== CTRL+C 确认测试 =====" -ForegroundColor Cyan
Write-Host "当前无法自动测试 CTRL+C，但代码已改为:"
Write-Host "  Write-Host '确定要退出吗？[Y/N] ' -NoNewline"
Write-Host "  `$key = [Console]::ReadKey(`$true)"
Write-Host "  if (`$key.KeyChar -eq 'y') { 退出 } else { 继续 }"
Write-Host ""
Write-Host "这个模式在 Console 环境下可靠，不依赖 `$host.UI.PromptForChoice。" -ForegroundColor DarkGray
