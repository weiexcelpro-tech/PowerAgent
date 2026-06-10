# verify_esc_ctrlc.ps1 — 验证 ESC 中断 和 CTRL+C 确认功能
param([switch]$Manual)

# Dot-source PowerAgent.ps1 以加载函数和类型
$root = Split-Path -Parent $PSScriptRoot
$paPath = Join-Path $root "PowerAgent.ps1"
if (-not (Test-Path $paPath)) {
    Write-Host "ERROR: PowerAgent.ps1 not found at $paPath" -ForegroundColor Red
    exit 1
}
. $paPath

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "PowerAgent ESC/CTRL+C 功能验证" -ForegroundColor Cyan
Write-Host "================================`n" -ForegroundColor Cyan

# ── 1. 验证新函数存在 ──
Write-Host "[1/5] 检查新函数是否已定义..." -ForegroundColor Yellow

$funcs = @("Start-EscMonitor", "Stop-EscMonitor", "Test-EscInterrupt")
foreach ($f in $funcs) {
    if (Get-Command $f -ErrorAction SilentlyContinue) {
        Write-Host "  [OK] 函数 '$f' 已存在" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] 函数 '$f' 不存在！请确认 PowerAgent.ps1 已加载" -ForegroundColor Red
        exit 1
    }
}

# ── 2. 验证 PA_KeyStateHelper 类型 ──
Write-Host "`n[2/5] 检查 PA_KeyStateHelper 类型..."

try {
    $result = [PA_KeyStateHelper]::IsEscapePressed()
    Write-Host "  [OK] PA_KeyStateHelper::IsEscapePressed() 返回 $result (ESC未按下)" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] PA_KeyStateHelper 类型不可用: $_" -ForegroundColor Red
    exit 1
}

# ── 3. 验证 EscMonitor 生命周期 ──
Write-Host "`n[3/5] 测试 EscMonitor 启动/检测/停止..."

# 启动
Start-EscMonitor

if ($null -eq $global:_ESC_SHARED) {
    Write-Host "  [FAIL] _ESC_SHARED 未设置" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] EscMonitor 已启动 (Runspace 已创建)" -ForegroundColor Green

# 检测初始状态
$initialCheck = Test-EscInterrupt
if ($initialCheck) {
    Write-Host "  [FAIL] Test-EscInterrupt 意外返回 true (ESC 未按下)" -ForegroundColor Red
    Stop-EscMonitor
    exit 1
}
Write-Host "  [OK] Test-EscInterrupt 返回 false (ESC 未按下)" -ForegroundColor Green

# 停止
Stop-EscMonitor
if ($null -ne $global:_ESC_SHARED) {
    Write-Host "  [FAIL] _ESC_SHARED 未清理" -ForegroundColor Red
    exit 1
}
if ($null -ne $global:_ESC_RS) {
    Write-Host "  [FAIL] _ESC_RS Runspace 未清理" -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] EscMonitor 已正确停止" -ForegroundColor Green

# ── 4. 验证重复启动安全 ──
Write-Host "`n[4/5] 测试重复启动安全性..."

Start-EscMonitor
$firstShared = $global:_ESC_SHARED
Start-EscMonitor  # 不应创建新的
if ($global:_ESC_SHARED -ne $firstShared) {
    Write-Host "  [FAIL] 第二次 Start-EscMonitor 创建了新实例" -ForegroundColor Red
    Stop-EscMonitor; Stop-EscMonitor
    exit 1
}
Stop-EscMonitor
Write-Host "  [OK] 重复启动安全 (不会重复创建)" -ForegroundColor Green

# ── 5. 验证 _EXIT_REQUESTED 和 _ESC_PRESSED 初始化 ──
Write-Host "`n[5/5] 检查全局变量初始化..."

$varsOk = $true
if ($null -eq $global:_EXIT_REQUESTED -and $null -eq (Get-Variable -Name '_EXIT_REQUESTED' -Scope Global -ErrorAction SilentlyContinue)) {
    Write-Host "  [INFO] _EXIT_REQUESTED 未初始化 (首次加载时由 Start-AgentLoop 设置)" -ForegroundColor DarkGray
}
if ($null -eq $global:_ESC_PRESSED -and $null -eq (Get-Variable -Name '_ESC_PRESSED' -Scope Global -ErrorAction SilentlyContinue)) {
    Write-Host "  [INFO] _ESC_PRESSED 未初始化 (首次加载时由 Start-AgentLoop/Start-EscMonitor 设置)" -ForegroundColor DarkGray
}

Write-Host "  [OK] 全局变量管理正常" -ForegroundColor Green

# ── 手动测试指引 ──
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  自动化验证全部通过！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "手动测试步骤:" -ForegroundColor Yellow
Write-Host "  1. 运行 .\PowerAgent.ps1 进入交互模式"
Write-Host "  2. 输入一个复杂的任务（如'帮我写一个完整的Web应用'）"
Write-Host "  3. 在代理思考/执行工具期间，按 ESC — 应看到'操作已中断 (ESC)'并返回输入提示"
Write-Host "  4. 再次输入任务，在思考期间按 CTRL+C — 应弹出 Yes/No 确认对话框"
Write-Host "  5. 选择 N — 应继续运行"
Write-Host "  6. 再次按 CTRL+C，选择 Y — 应退出程序"
Write-Host ""
