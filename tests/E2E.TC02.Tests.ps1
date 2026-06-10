BeforeAll {
    $mergedFile = Join-Path $PSScriptRoot '..\PowerAgent.ps1'
    . $mergedFile
    $testDataDir = 'C:\Work\202606\Bash-agent\Testcase\TC02-数据汇总\原始数据'
    $outputDir = Join-Path $PSScriptRoot '_tc02_output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
}
AfterAll {
    if (Test-Path (Join-Path $PSScriptRoot '_tc02_output')) {
        Remove-Item (Join-Path $PSScriptRoot '_tc02_output') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'TC02 - Data Aggregation and Summary' {
    Context 'Monthly sales aggregation via ProcessExcel' {
        It 'Aggregates sales data by month successfully' {
            $inputFile = Join-Path $testDataDir '销售明细.xlsx'
            $outputFile = Join-Path $outputDir '月度销售汇总.xlsx'

            $script = @"
`$data = ImportExcel\Import-Excel -Path '$inputFile'
`$monthly = `$data | ForEach-Object {
    `$d = `$_.日期
    try { `$ym = ([datetime]::Parse(`$d.ToString())).ToString('yyyy-MM') } catch { `$ym = 'unknown' }
    [PSCustomObject]@{
        YearMonth  = `$ym
        销售额     = [double]::Parse(`$_.销售额.ToString())
        订单号     = `$_.订单号
        成本       = [double]::Parse(`$_.成本.ToString())
    }
} | Group-Object YearMonth | ForEach-Object {
    [PSCustomObject]@{
        月份       = `$_.Name
        销售额     = (`$_.Group | Measure-Object 销售额 -Sum).Sum
        订单数     = `$_.Count
        客单价     = [math]::Round((`$_.Group | Measure-Object 销售额 -Sum).Sum / `$_.Count, 2)
    }
}
`$monthly = `$monthly | Sort-Object 月份
`$monthly | ImportExcel\Export-Excel -Path '$outputFile' -AutoSize
Write-Output "Months: `$(`$monthly.Count)"
"@
            $result = Invoke-ToolProcessExcel @{ script = $script }
            $result.status | Should -Be 'ok'
        }

        It 'Output file exists' {
            $outputFile = Join-Path $outputDir '月度销售汇总.xlsx'
            Test-Path $outputFile | Should -BeTrue
        }

        It 'Has multiple months of data' {
            $outputFile = Join-Path $outputDir '月度销售汇总.xlsx'
            $scriptCount = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
Write-Output "count=`$(`$data.Count)"
"@
            $cnt = Invoke-ToolProcessExcel @{ script = $scriptCount }
            $cnt.status | Should -Be 'ok'
            if ($cnt.output -match 'count=(\d+)') {
                [int]$c = $Matches[1]
                $c | Should -BeGreaterOrEqual 6
            }
        }

        It 'Has required columns' {
            $outputFile = Join-Path $outputDir '月度销售汇总.xlsx'
            $scriptCols = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$cols = (`$data[0].PSObject.Properties | Select-Object -ExpandProperty Name) -join ','
Write-Output `$cols
"@
            $colResult = Invoke-ToolProcessExcel @{ script = $scriptCols }
            $colResult.status | Should -Be 'ok'
            $colResult.output | Should -Match '月份'
            $colResult.output | Should -Match '销售额'
            $colResult.output | Should -Match '订单数'
        }

        It 'Sales values are positive numbers' {
            $outputFile = Join-Path $outputDir '月度销售汇总.xlsx'
            $scriptVal = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$neg = (`$data | Where-Object { [double]`$_.销售额 -lt 0 }).Count
Write-Output "negative=`$neg"
"@
            $valResult = Invoke-ToolProcessExcel @{ script = $scriptVal }
            $valResult.status | Should -Be 'ok'
            $valResult.output | Should -Match 'negative=0'
        }
    }
}
