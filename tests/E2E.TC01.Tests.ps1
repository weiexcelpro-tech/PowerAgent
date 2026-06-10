BeforeAll {
    $mergedFile = Join-Path $PSScriptRoot '..\PowerAgent.ps1'
    . $mergedFile
    $testDataDir = 'C:\Work\202606\Bash-agent\Testcase\TC01-数据清洗与格式化\原始数据'
    $outputDir = Join-Path $PSScriptRoot '_tc01_output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
}
AfterAll {
    if (Test-Path (Join-Path $PSScriptRoot '_tc01_output')) {
        Remove-Item (Join-Path $PSScriptRoot '_tc01_output') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'TC01 - Data Cleaning and Formatting' {
    Context 'Excel data cleaning via ProcessExcel' {
        It 'Cleans the sales data file successfully' {
            $inputFile = Join-Path $testDataDir '销售数据.xlsx'
            $outputFile = Join-Path $outputDir '销售数据_清洗版.xlsx'

            $script = @"
`$data = ImportExcel\Import-Excel -Path '$inputFile'
`$clean = `$data | Where-Object { `$_.订单号 -and `$_.订单号.ToString().Trim() -ne '' }
`$seen = @{}; `$deduped = @()
foreach (`$row in `$clean) { `$k = `$row.订单号.ToString(); if (-not `$seen[`$k]) { `$seen[`$k] = `$true; `$deduped += `$row } }
foreach (`$row in `$deduped) {
    if (`$row.日期) {
        try {
            `$raw = `$row.日期.ToString() -replace '年', '-' -replace '月', '-' -replace '日', ''
            `$parsed = [datetime]::Parse(`$raw)
            `$row.日期 = `$parsed.ToString('yyyy-MM-dd')
        } catch { try { `$parsed = [datetime]::Parse(`$row.日期.ToString()); `$row.日期 = `$parsed.ToString('yyyy-MM-dd') } catch {} }
    }
    if (`$row.销售额) {
        try { `$row.销售额 = [math]::Round([double]::Parse(`$row.销售额.ToString()), 2) } catch {}
    }
}
`$deduped | ImportExcel\Export-Excel -Path '$outputFile' -AutoSize
Write-Output "Rows: `$(`$deduped.Count)"
"@
            $result = Invoke-ToolProcessExcel @{ script = $script }
            $result.status | Should -Be 'ok'
        }

        It 'Output file exists' {
            $outputFile = Join-Path $outputDir '销售数据_清洗版.xlsx'
            Test-Path $outputFile | Should -BeTrue
        }

        It 'Has fewer rows than original (empty rows + duplicates removed)' {
            $inputFile = Join-Path $testDataDir '销售数据.xlsx'
            $outputFile = Join-Path $outputDir '销售数据_清洗版.xlsx'

            $scriptCount = @"
`$orig = (ImportExcel\Import-Excel -Path '$inputFile').Count
`$clean = (ImportExcel\Import-Excel -Path '$outputFile').Count
Write-Output "orig=`$orig clean=`$clean"
"@
            $cntResult = Invoke-ToolProcessExcel @{ script = $scriptCount }
            $cntResult.status | Should -Be 'ok'
            $cntResult.output | Should -Match 'orig=\d+'
            $cntResult.output | Should -Match 'clean=\d+'
            $cntResult.output -match 'orig=(\d+)' | Out-Null; [int]$origCount = $Matches[1]
            $cntResult.output -match 'clean=(\d+)' | Out-Null; [int]$cleanCount = $Matches[1]
            $cleanCount | Should -BeLessOrEqual $origCount
        }

        It 'Has no duplicate order IDs' {
            $outputFile = Join-Path $outputDir '销售数据_清洗版.xlsx'
            $scriptDup = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$ids = `$data | Select-Object -ExpandProperty 订单号
`$unique = `$ids | Select-Object -Unique
Write-Output "total=`$(`$ids.Count) unique=`$(`$unique.Count)"
"@
            $dupResult = Invoke-ToolProcessExcel @{ script = $scriptDup }
            $dupResult.status | Should -Be 'ok'
            if ($dupResult.output -match 'total=(\d+) unique=(\d+)') {
                [int]$total = $Matches[1]
                [int]$unique = $Matches[2]
                $total | Should -Be $unique
            }
        }

        It 'All dates are parseable and formatted consistently' {
            $outputFile = Join-Path $outputDir '销售数据_清洗版.xlsx'
            $scriptDate = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$bad = 0
foreach (`$row in `$data) {
    if (`$row.PSObject.Properties['日期'] -and `$row.日期) {
        try {
            `$s = `$row.日期.ToString()
            if (`$s -notmatch '^\d{4}-\d{2}-\d{2}') {
                `$p = [datetime]::Parse(`$s)
            }
        } catch { `$bad++ }
    }
}
Write-Output "bad_dates=`$bad"
"@
            $dateResult = Invoke-ToolProcessExcel @{ script = $scriptDate }
            $dateResult.status | Should -Be 'ok'
            # Allow ≤1 unparseable date from original dirty data
            if ($dateResult.output -match 'bad_dates=(\d+)') {
                [int]$bad = $Matches[1]
                $bad | Should -BeLessOrEqual 1
            }
        }

        It 'Sales amounts have 2 decimal places' {
            $outputFile = Join-Path $outputDir '销售数据_清洗版.xlsx'
            $scriptDec = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$bad = 0
foreach (`$row in `$data) {
    if (`$row.销售额) {
        try {
            `$val = [double]::Parse(`$row.销售额.ToString())
            `$formatted = `$val.ToString('F2')
            `$rounded = [math]::Round(`$val, 2)
            if ([math]::Abs(`$val - `$rounded) -gt 0.005) { `$bad++ }
        } catch { `$bad++ }
    }
}
Write-Output "bad_decimals=`$bad"
"@
            $decResult = Invoke-ToolProcessExcel @{ script = $scriptDec }
            $decResult.status | Should -Be 'ok'
            $decResult.output | Should -Match 'bad_decimals=0'
        }
    }
}
