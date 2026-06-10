# diag_full.ps1 — PowerAgent ESC/CTRL+C 完整诊断
# 用法: powershell -NoProfile -File tests/diag_full.ps1
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  PowerAgent ESC/CTRL+C 问题诊断报告"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# TEST 1: Add-Type — PA_KeyStateHelper 是否正确编译
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 1] PA_KeyStateHelper 类型编译..." -ForegroundColor Yellow

$typeDef = @'
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
'@

try {
    Add-Type -TypeDefinition $typeDef -ErrorAction Stop
    Write-Host "  [PASS] Add-Type 成功" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] Add-Type 失败: $_" -ForegroundColor Red
}

# ═══════════════════════════════════════════════════════════════
# TEST 2: GetAsyncKeyState — ESC 当前状态
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 2] GetAsyncKeyState 调用测试..." -ForegroundColor Yellow

try {
    $state = [PA_KeyStateHelper]::IsEscapePressed()
    Write-Host "  [INFO] IsEscapePressed() = $state (ESC 当前$(
        if ($state) {'按下'} else {'未按下'}
    ))" -ForegroundColor White
} catch {
    Write-Host "  [FAIL] 调用失败: $_" -ForegroundColor Red
}

# ═══════════════════════════════════════════════════════════════
# TEST 3: Timer.Elapsed 回调中读取 GetAsyncKeyState
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 3] Timer 回调中 GetAsyncKeyState + 写 global..." -ForegroundColor Yellow

$global:_DIAG_FLAG = -1
$timer = New-Object System.Timers.Timer
$timer.Interval = 100
$timer.AutoReset = $false
$timer.add_Elapsed({
    try {
        if ([PA_KeyStateHelper]::IsEscapePressed()) {
            $global:_DIAG_FLAG = 1
        } else {
            $global:_DIAG_FLAG = 0
        }
    } catch {
        $global:_DIAG_FLAG = -2  # exception
    }
})
$timer.Start()
Start-Sleep -Milliseconds 300
$timer.Dispose()

switch ($global:_DIAG_FLAG) {
    -1 { Write-Host "  [FAIL] 回调未触发！Timer 可能未启动" -ForegroundColor Red }
    -2 { Write-Host "  [FAIL] 回调抛出异常（GetAsyncKeyState 在 ThreadPool 线程不可用）" -ForegroundColor Red }
     0 { Write-Host "  [PASS] 回调触发成功，IsEscapePressed()=false (正常)" -ForegroundColor Green }
     1 { Write-Host "  [PASS] 回调触发成功，IsEscapePressed()=true (你按着 ESC 吗？)" -ForegroundColor Green }
  default { Write-Host "  [WARN] 未知返回值: $($_DIAG_FLAG)" -ForegroundColor Yellow }
}

# ═══════════════════════════════════════════════════════════════
# TEST 4: Read-HostWithCompletion 中 CTRL+C 的行为
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 4] CTRL+C 在 Invoke-RunTurn 中的路径追踪..." -ForegroundColor Yellow

# 检查 Read-HostWithCompletion 中 CTRL+C 的代码
$paPath = Join-Path $root "PowerAgent.ps1"
$paContent = Get-Content $paPath -Raw

# 检查 CTRL+C 返回 $null 的代码
if ($paContent -match 'Ctrl\+C.*return \$null' -or $paContent -match 'Ctrl.*C.*return \$null') {
    Write-Host "  [INFO] Read-HostWithCompletion 内部处理 CTRL+C → return `$null" -ForegroundColor White
}

# 检查 Invoke-RunTurn 中 $null 的处理
if ($paContent -match '\$null -eq \$UserInput' -and $paContent -match 'PromptForChoice') {
    Write-Host "  [PASS] Invoke-RunTurn 中有 CTRL+C 确认对话框（PromptForChoice）" -ForegroundColor Green
} elseif ($paContent -match '\$null -eq \$UserInput') {
    Write-Host "  [FAIL] Invoke-RunTurn 中 `$null 检查存在，但用 PromptForChoice 了吗？" -ForegroundColor Red
} else {
    Write-Host "  [FAIL] 未找到 `$null -eq `$UserInput 检查" -ForegroundColor Red
}

# 检查 PipelineStoppedException 处理
if ($paContent -match 'PipelineStoppedException.*PromptForChoice' -or $paContent -match 'PromptForChoice.*PipelineStoppedException') {
    Write-Host "  [PASS] Start-AgentLoop PipelineStoppedException 有确认对话框" -ForegroundColor Green
} else {
    Write-Host "  [INFO] PipelineStoppedException + PromptForChoice 离太远，未在同一窗口匹配" -ForegroundColor White
}

# ═══════════════════════════════════════════════════════════════
# TEST 5: $host.UI.PromptForChoice 可用性
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 5] `$host.UI.PromptForChoice 可用性..." -ForegroundColor Yellow

try {
    $testChoices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        (New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "yes")
    )
    $hostType = $host.GetType().FullName
    Write-Host "  [INFO] Host 类型: $hostType" -ForegroundColor White
    
    if ($host.UI -and $host.UI.PromptForChoice) {
        Write-Host "  [PASS] PromptForChoice 可用" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] PromptForChoice 不可用" -ForegroundColor Red
    }
} catch {
    Write-Host "  [FAIL] 访问失败: $_" -ForegroundColor Red
}

# ═══════════════════════════════════════════════════════════════
# TEST 6: 检查 PowerAgent.ps1 文件中的修改是否完整
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 6] 代码完整性检查..." -ForegroundColor Yellow

$checks = @{
    "_ESC_MONITOR_ACTIVE"  = "ESC 监测开关"
    "Test-EscInterrupt"    = "ESC 中断检测函数"
    "Start-EscMonitor"     = "ESC 监测启动函数"
    "Stop-EscMonitor"      = "ESC 监测停止函数"
    "PA_KeyStateHelper"    = "Win32 ESC 检测类型"
    "_ACTIVE_WEB_REQUEST"  = "HTTP Abort 引用"
    "RequestCanceled"      = "ESC 中止的 exit code 7 处理"
}

foreach ($key in $checks.Keys) {
    $found = $paContent -match [regex]::Escape($key)
    $label = $checks[$key]
    if ($found) {
        Write-Host "  [PASS] $label ($key)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] 缺少: $label ($key)" -ForegroundColor Red
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST 7: 模拟 Spinner → ESC 检测的完整链路
# ═══════════════════════════════════════════════════════════════
Write-Host "[TEST 7] 端到端模拟：Spinner 定时器 → ESC 检测 → 全局变量..." -ForegroundColor Yellow

$global:_ESC_MONITOR_ACTIVE = $true
$global:_ESC_RELEASED = $true
$global:_ESC_PRESSED = $false
$global:_ACTIVE_WEB_REQUEST = $null

$timer2 = New-Object System.Timers.Timer
$timer2.Interval = 100
$timer2.AutoReset = $false
$timer2.add_Elapsed({
    if ($global:_ESC_MONITOR_ACTIVE) {
        try {
            if ([PA_KeyStateHelper]::IsEscapePressed()) {
                if ($global:_ESC_RELEASED) {
                    $global:_ESC_PRESSED = $true
                    $global:_ESC_RELEASED = $false
                    if ($global:_ACTIVE_WEB_REQUEST) {
                        try { $global:_ACTIVE_WEB_REQUEST.Abort() } catch { }
                    }
                }
            } else {
                $global:_ESC_RELEASED = $true
            }
        } catch { }
    }
})
$timer2.Start()
Write-Host "  Timer 已启动 — 请在 2 秒内按 ESC..." -ForegroundColor White
Start-Sleep -Seconds 2
$timer2.Dispose()

$global:_ESC_MONITOR_ACTIVE = $false

if ($global:_ESC_PRESSED) {
    Write-Host "  [PASS] ESC 被检测到！`$global:_ESC_PRESSED = true" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] ESC 未被检测到。可能原因：" -ForegroundColor Red
    Write-Host "     a) GetAsyncKeyState 在 ThreadPool 线程不可用" -ForegroundColor DarkGray
    Write-Host "     b) 你未在 2 秒内按 ESC" -ForegroundColor DarkGray
    Write-Host "     c) Timer 回调未触发（同 TEST 3）" -ForegroundColor DarkGray
}

# ═══════════════════════════════════════════════════════════════
# 总结
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  诊断完成。请将以上输出反馈给我。" -ForegroundColor Cyan
Write-Host "  重点关注 TEST 3 和 TEST 7 的结果。" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
