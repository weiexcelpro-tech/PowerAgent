BeforeAll {
    $mergedFile = Join-Path $PSScriptRoot '..\PowerAgent.ps1'
    . $mergedFile
    $testDataDir = 'C:\Work\202606\Bash-agent\Testcase\TC08-批量文件处理\原始数据'
    $outputDir = Join-Path $PSScriptRoot '_tc08_output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
}
AfterAll {
    if (Test-Path (Join-Path $PSScriptRoot '_tc08_output')) {
        Remove-Item (Join-Path $PSScriptRoot '_tc08_output') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'TC08 - Batch File Processing' {
    Context 'Merge 35 department Excel files' {
        It 'Merges all 35 files into one successfully' {
            $outputFile = Join-Path $outputDir '合并人力数据.xlsx'

            $script = @"
`$files = Get-ChildItem -Path '$testDataDir' -Filter '*_人力数据.xlsx'
`$all = @()
foreach (`$f in `$files) {
    `$dept = `$f.BaseName -replace '_人力数据$', ''
    `$data = ImportExcel\Import-Excel -Path `$f.FullName
    foreach (`$row in `$data) {
        `$row | Add-Member -NotePropertyName '来源' -NotePropertyValue `$dept -Force
        `$all += `$row
    }
}
`$all | Export-Excel -Path '$outputFile' -AutoSize
Write-Output "Files=`$(`$files.Count) Rows=`$(`$all.Count)"
"@
            $result = Invoke-ToolProcessExcel @{ script = $script }
            $result.status | Should -Be 'ok'
            $result.output | Should -Match 'Files=35'
        }

        It 'Output file exists' {
            $outputFile = Join-Path $outputDir '合并人力数据.xlsx'
            Test-Path $outputFile | Should -BeTrue
        }

        It 'Contains data from all 35 departments' {
            $outputFile = Join-Path $outputDir '合并人力数据.xlsx'
            $scriptCount = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$depts = (`$data | Select-Object -ExpandProperty 来源 -Unique).Count
`$rows = `$data.Count
Write-Output "depts=`$depts rows=`$rows"
"@
            $cnt = Invoke-ToolProcessExcel @{ script = $scriptCount }
            $cnt.status | Should -Be 'ok'
            if ($cnt.output -match 'depts=(\d+) rows=(\d+)') {
                [int]$depts = $Matches[1]
                [int]$rows = $Matches[2]
                $depts | Should -Be 35
                $rows | Should -BeGreaterOrEqual 100
            }
        }

        It 'Has the 来源 column' {
            $outputFile = Join-Path $outputDir '合并人力数据.xlsx'
            $scriptCols = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$cols = (`$data[0].PSObject.Properties | Select-Object -ExpandProperty Name) -join ','
Write-Output `$cols
"@
            $colResult = Invoke-ToolProcessExcel @{ script = $scriptCols }
            $colResult.status | Should -Be 'ok'
            $colResult.output | Should -Match '来源'
            $colResult.output | Should -Match '姓名'
            $colResult.output | Should -Match '部门'
        }

        It 'No rows have empty 来源' {
            $outputFile = Join-Path $outputDir '合并人力数据.xlsx'
            $scriptSrc = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$empty = (`$data | Where-Object { -not `$_.来源 -or `$_.来源.ToString().Trim() -eq '' }).Count
Write-Output "empty_source=`$empty"
"@
            $srcResult = Invoke-ToolProcessExcel @{ script = $scriptSrc }
            $srcResult.status | Should -Be 'ok'
            $srcResult.output | Should -Match 'empty_source=0'
        }
    }
}
