# diag_paste.ps1 — 分析 Windows Terminal Ctrl+Shift+V 粘贴行为
Write-Host "===== ReadKey 对粘贴的处理分析 =====" -ForegroundColor Cyan
Write-Host ""

# 测试: ReadKey($true) 后 Write-Host 回显 CJK 字符的行为
Write-Host "[1] 测试单个字符回显对光标的影响..." -ForegroundColor Yellow
Write-Host "提示符: " -NoNewline

$buf = [System.Text.StringBuilder]::new()
$test = "C:\Work\测试\中文路径\文件.md"

foreach ($ch in $test.ToCharArray()) {
    $buf.Append($ch) | Out-Null
    Write-Host $ch -NoNewline
}
Write-Host ""
Write-Host "Buffer 内容: $($buf.ToString())"
Write-Host "Buffer 长度: $($buf.Length), 字符数而非列数"

# 测试: KeyAvailable 在输入缓冲为空时的状态
Write-Host ""
Write-Host "[2] KeyAvailable 初始状态: $([Console]::KeyAvailable)" -ForegroundColor Yellow

# 测试: 检查输入缓冲中是否有残留
Write-Host "[3] 检查是否有残留按键待读取..." -ForegroundColor Yellow
$pending = 0
while ([Console]::KeyAvailable) {
    $null = [Console]::ReadKey($true)
    $pending++
}
Write-Host "  残留按键: $pending 个（已清除）"

# 测试结论
Write-Host ""
Write-Host "===== 分析结论 =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "问题产生机制:" -ForegroundColor Red
Write-Host "  1. 用户 Ctrl+Shift+V 粘贴，Windows Terminal 将剪贴板内容注入控制台输入缓冲"
Write-Host "  2. ReadKey 逐个读取字符"
Write-Host "  3. 每个字符调用 Write-Host `$ch -NoNewline 回显"
Write-Host "  4. Write-Host 写入控制台输出缓冲 → conhost 渲染 → 更新光标位置"
Write-Host "  5. 粘贴量大时，ReadKey-Write-Host 交替进行"
Write-Host "  6. 控制台输入/输出缓冲异步竞争：Write-Host 尚未完成输出时，ReadKey 已读取下一个字符"
Write-Host "  7. Write-Host 写入的字符被 conhost 回显机制错误地反馈到输入缓冲"
Write-Host ""
Write-Host "修复方案:" -ForegroundColor Green
Write-Host "  A. 粘贴时批量读取所有字符，不逐字回显，只在最后一次性重绘整行"
Write-Host "  B. 使用 [Console]::ReadKey(`$false) 让控制台自行回显（但会干扰 Tab/Esc 等特殊键）"
Write-Host "  C. 放弃 ReadKey，改用 Read-Host（但失去 Tab 补全）"
Write-Host ""
Write-Host "  推荐方案 A: 批量读取 + 一次性重绘" -ForegroundColor Green
