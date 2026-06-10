BeforeAll {
    $mergedFile = Join-Path $PSScriptRoot '..\PowerAgent.ps1'
    . $mergedFile
    $testDataDir = 'C:\Work\202606\Bash-agent\Testcase\TC03-图表生成\原始数据'
    $outputDir = Join-Path $PSScriptRoot '_tc03_output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
}
AfterAll {
    if (Test-Path (Join-Path $PSScriptRoot '_tc03_output')) {
        Remove-Item (Join-Path $PSScriptRoot '_tc03_output') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'TC03 - Chart Generation' {
    Context 'Sales analysis with chart via ProcessExcel' {
        It 'Creates aggregated data with chart successfully' {
            $inputFile = Join-Path $testDataDir '销售数据.xlsx'
            $outputFile = Join-Path $outputDir '销售数据_分公司销售量版.xlsx'

            $script = @"
`$data = ImportExcel\Import-Excel -Path '$inputFile'
`$byCompany = `$data | ForEach-Object {
    [PSCustomObject]@{
        公司    = `$_.公司
        销售额  = [double]::Parse(`$_.销售额.ToString())
    }
} | Group-Object 公司 | ForEach-Object {
    [PSCustomObject]@{
        公司   = `$_.Name
        销售额 = [math]::Round((`$_.Group | Measure-Object 销售额 -Sum).Sum, 2)
    }
} | Sort-Object 销售额 -Descending

`$chartDef = New-ExcelChartDefinition -XRange 'A2:A20' -YRange 'B2:B20' `
    -ChartType Line -Title '分公司销售额对比' -NoLegend

`$byCompany | Export-Excel -Path '$outputFile' -AutoSize -ExcelChart `$chartDef
Write-Output "Companies: `$(`$byCompany.Count)"
"@
            $result = Invoke-ToolProcessExcel @{ script = $script }
            $result.status | Should -Be 'ok'
        }

        It 'Output file exists' {
            $outputFile = Join-Path $outputDir '销售数据_分公司销售量版.xlsx'
            Test-Path $outputFile | Should -BeTrue
        }

        It 'Contains data for all 10 companies' {
            $outputFile = Join-Path $outputDir '销售数据_分公司销售量版.xlsx'
            $scriptCount = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
Write-Output "rows=`$(`$data.Count)"
"@
            $cnt = Invoke-ToolProcessExcel @{ script = $scriptCount }
            $cnt.status | Should -Be 'ok'
            if ($cnt.output -match 'rows=(\d+)') {
                [int]$r = $Matches[1]
                $r | Should -BeGreaterOrEqual 10
            }
        }

        It 'Data can be read back correctly' {
            $outputFile = Join-Path $outputDir '销售数据_分公司销售量版.xlsx'
            $scriptRead = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$cols = (`$data[0].PSObject.Properties | Select-Object -ExpandProperty Name) -join ','
Write-Output `$cols
"@
            $readResult = Invoke-ToolProcessExcel @{ script = $scriptRead }
            $readResult.status | Should -Be 'ok'
            $readResult.output | Should -Match '公司'
            $readResult.output | Should -Match '销售额'
        }

        It 'Sales values are positive and reasonable' {
            $outputFile = Join-Path $outputDir '销售数据_分公司销售量版.xlsx'
            $scriptVal = @"
`$data = ImportExcel\Import-Excel -Path '$outputFile'
`$neg = (`$data | Where-Object { [double]`$_.销售额 -lt 0 }).Count
`$total = (`$data | Measure-Object -Property 销售额 -Sum).Sum
Write-Output "negative=`$neg total=`$([math]::Round(`$total,2))"
"@
            $valResult = Invoke-ToolProcessExcel @{ script = $scriptVal }
            $valResult.status | Should -Be 'ok'
            $valResult.output | Should -Match 'negative=0'
        }
    }
}
