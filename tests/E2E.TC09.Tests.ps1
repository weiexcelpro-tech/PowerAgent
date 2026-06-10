BeforeAll {
    $mergedFile = Join-Path $PSScriptRoot '..\PowerAgent.ps1'
    . $mergedFile
    $testDataSrc = 'C:\Work\202606\Bash-agent\Testcase\TC09-工作空间文件整理\原始数据\我收集的资料'
    $outputDir = Join-Path $PSScriptRoot '_tc09_output'
    if (Test-Path $outputDir) { Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item -Path $testDataSrc -Destination $outputDir -Recurse -Force
}
AfterAll {
    if (Test-Path (Join-Path $PSScriptRoot '_tc09_output')) {
        Remove-Item (Join-Path $PSScriptRoot '_tc09_output') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'TC09 - Workspace File Organization' {
    Context 'Classify 15 files into 3 categories' {
        It 'Creates 3 category directories and moves files' {
            # Define classification rules
            $产品设计 = @('星辰智能体产品设计文档.md', '用户体验改进方案.docx', '交互设计规范.pdf', 'Agent工作流设计.md', '技能市场调研报告.xlsx')
            $政策研究 = @('国家AI发展规划解读.pdf', '数据安全法律汇编.docx', '产业政策分析.md', '地方政府AI补贴政策.md')
            $科研论文 = @('ReAct_Agent_Framework.pdf', 'LLM规划能力研究综述.pdf', '多模态大模型训练方法.md', 'RAG检索增强生成论文.pdf', 'Agent_Benchmarking_2025.pdf', 'Tool_Learning_Paper.md')

            # Build PS command to create dirs and move files
            $moves = @()
            foreach ($f in $产品设计) { $moves += "Move-Item -Path '$outputDir\$f' -Destination '$outputDir\产品设计\' -Force -ErrorAction SilentlyContinue" }
            foreach ($f in $政策研究) { $moves += "Move-Item -Path '$outputDir\$f' -Destination '$outputDir\政策研究\' -Force -ErrorAction SilentlyContinue" }
            foreach ($f in $科研论文) { $moves += "Move-Item -Path '$outputDir\$f' -Destination '$outputDir\科研论文\' -Force -ErrorAction SilentlyContinue" }

            $cmd = @"
New-Item -ItemType Directory -Path '$outputDir\产品设计' -Force | Out-Null
New-Item -ItemType Directory -Path '$outputDir\政策研究' -Force | Out-Null
New-Item -ItemType Directory -Path '$outputDir\科研论文' -Force | Out-Null
$($moves -join "`n")
Write-Output 'done'
"@
            $result = Invoke-ToolPowerShell @{ command = $cmd }
            $result.status | Should -Be 'ok'
        }

        It '3 category directories exist' {
            $result = Invoke-ToolListFiles @{ path = $outputDir }
            $result.status | Should -Be 'ok'
            $dirs = $result.entries | Where-Object { $_.type -eq 'dir' }
            $dirs.Count | Should -Be 3
            $dirNames = $dirs | ForEach-Object { $_['name'] }
            $dirNames | Should -Contain '产品设计'
            $dirNames | Should -Contain '政策研究'
            $dirNames | Should -Contain '科研论文'
        }

        It 'Total file count is still 15 (no files deleted)' {
            $result = Invoke-ToolListFiles @{ path = $outputDir; recursive = $true }
            $result.status | Should -Be 'ok'
            $files = $result.entries | Where-Object { $_.type -eq 'file' }
            $files.Count | Should -Be 15
        }

        It '产品设计 has 5 files' {
            $result = Invoke-ToolListFiles @{ path = "$outputDir\产品设计" }
            $result.status | Should -Be 'ok'
            $files = $result.entries | Where-Object { $_.type -eq 'file' }
            $files.Count | Should -Be 5
        }

        It '政策研究 has 4 files' {
            $result = Invoke-ToolListFiles @{ path = "$outputDir\政策研究" }
            $result.status | Should -Be 'ok'
            $files = $result.entries | Where-Object { $_.type -eq 'file' }
            $files.Count | Should -Be 4
        }

        It '科研论文 has 6 files' {
            $result = Invoke-ToolListFiles @{ path = "$outputDir\科研论文" }
            $result.status | Should -Be 'ok'
            $files = $result.entries | Where-Object { $_.type -eq 'file' }
            $files.Count | Should -Be 6
        }

        It 'No files remain in root directory' {
            $result = Invoke-ToolListFiles @{ path = $outputDir }
            $result.status | Should -Be 'ok'
            $rootFiles = $result.entries | Where-Object { $_.type -eq 'file' }
            $rootFiles.Count | Should -Be 0
        }
    }
}
