Describe "Scope Diagnostics - Full Suite" {
    It "Checks function visibility at HttpClient.Tests.ps1 position" {
        Write-Host "  Build-ApiRequestBody local: $(Test-Path function:Build-ApiRequestBody)"
        Write-Host "  Build-ApiRequestBody global: $(Test-Path function:global:Build-ApiRequestBody)"
        Write-Host "  Get-ApiHeaders local: $(Test-Path function:Get-ApiHeaders)"
        Write-Host "  Get-ApiHeaders global: $(Test-Path function:global:Get-ApiHeaders)"
        Write-Host "  Invoke-ApiCall local: $(Test-Path function:Invoke-ApiCall)"
        Write-Host "  Invoke-ApiCall global: $(Test-Path function:global:Invoke-ApiCall)"
        
        # Count total functions
        $allFns = Get-ChildItem function: | Where-Object { $_.Module -eq $null }
        Write-Host "  Total non-module functions: $(($allFns | Measure-Object).Count)"
        
        # List PowerAgent-related functions
        $paFns = $allFns | Where-Object { $_.Name -match 'Api|Build|Convert|Invoke-Http' }
        Write-Host "  API-related functions:"
        $paFns | ForEach-Object { Write-Host "    - $($_.Name)" }
        
        $true | Should -BeTrue
    }
}
