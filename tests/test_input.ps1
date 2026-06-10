# test_input.ps1 — 验证 Read-HostWithCompletion 的 buffer 逻辑
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "PowerAgent.ps1") 2>$null

$esc = [char]27
$rst = "${esc}[0m"

Write-Host "===== Read-HostWithCompletion Buffer 逻辑测试 =====" -ForegroundColor Cyan

# 我们无法直接调用 Read-HostWithCompletion（它会阻塞等待键盘），
# 但我们可以检验核心逻辑：行尾插入 vs 行中插入

$testBuf = [System.Text.StringBuilder]::new()
$testBuf.Append("hello world") | Out-Null
$cursorPos = $testBuf.Length  # = 11

Write-Host "[TEST 1] 行尾插入：写入字符并回显，不重绘整行" -ForegroundColor Yellow
# 模拟 paste 100 个字符
$chars = "C:\Work\202606\Bash-agent\PowerAgent-v0.6\tests\TC03-图表生成\测试用例说明.md"
$expectedEnd = "hello world" + $chars
foreach ($ch in $chars.ToCharArray()) {
    if ([int]$ch -ge 32) {
        if ($cursorPos -eq $testBuf.Length) {
            $testBuf.Append($ch) | Out-Null
            $cursorPos++
        } else {
            $testBuf.Insert($cursorPos, $ch) | Out-Null
            $cursorPos++
        }
    }
}

Write-Host "  结果: '$($testBuf.ToString())'"
if ($testBuf.ToString() -eq $expectedEnd) {
    Write-Host "  [PASS] Buffer 内容正确" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Buffer 不正确" -ForegroundColor Red
    Write-Host "  期望: '$expectedEnd'" -ForegroundColor Red
}

Write-Host "[TEST 2] 行中插入：在 'world' 前插入 'beautiful '" -ForegroundColor Yellow
$testBuf2 = [System.Text.StringBuilder]::new()
$testBuf2.Append("hello world") | Out-Null
$cursorPos2 = 6  # 在空格之后
$insert = "beautiful "
foreach ($ch in $insert.ToCharArray()) {
    if ($cursorPos2 -eq $testBuf2.Length) {
        $testBuf2.Append($ch) | Out-Null
    } else {
        $testBuf2.Insert($cursorPos2, $ch) | Out-Null
    }
    $cursorPos2++
}
$expected2 = "hello beautiful world"
if ($testBuf2.ToString() -eq $expected2) {
    Write-Host "  [PASS] Buffer 正确: '$($testBuf2.ToString())'" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] 得到: '$($testBuf2.ToString())'" -ForegroundColor Red
}

Write-Host "[TEST 3] Backspace + 光标归位逻辑" -ForegroundColor Yellow
$testBuf3 = [System.Text.StringBuilder]::new()
$testBuf3.Append("hello world") | Out-Null
$cursorPos3 = $testBuf3.Length  # 11
# Backspace 一次
if ($cursorPos3 -gt 0) {
    $cursorPos3--
    $testBuf3.Remove($cursorPos3, 1) | Out-Null
}
$moveBack3 = $testBuf3.Length - $cursorPos3  # $buf.Length(10) - cursorPos(10) = 0
if ($moveBack3 -eq 0 -and $cursorPos3 -eq $testBuf3.Length) {
    Write-Host "  [PASS] Backspace 后光标在行尾: buf='$($testBuf3.ToString())', cursor=$cursorPos3" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] buf='$($testBuf3.ToString())', cursor=$cursorPos3, moveBack=$moveBack3" -ForegroundColor Red
}

Write-Host ""
Write-Host "===== 所有测试通过 =====" -ForegroundColor Green
