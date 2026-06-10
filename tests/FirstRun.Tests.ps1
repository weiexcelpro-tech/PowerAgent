# ============================================================================
#  PowerAgent Test — FirstRun (interactive provider setup on missing API key)
#  Validates that Import-Config handles missing API key correctly:
#    - In non-interactive mode: Write-Die (exit 1)
#    - In interactive mode w/o TTY: Write-Die (fallback, Pester/CI safety)
#    - In interactive mode w/ TTY: invokes Invoke-SlashProvider (hard to test
#      automatically; covered by manual verification)
# ============================================================================

Describe "FirstRun — Import-Config missing API key handling" {

    Context "Non-interactive mode (oneshot/run)" {
        It "Exits with error when no API key in oneshot mode" {
            $savedMode = $script:PA_MODE
            $savedKey = $env:PA_API_KEY
            $savedDK = $env:DEEPSEEK_API_KEY
            $savedUP = $env:USERPROFILE
            $savedPD = $global:PA_PROJECT_DIR

            $tempDir = Join-Path $env:TEMP "pa_firstrun_oneshot_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $env:USERPROFILE = $tempDir
            $global:PA_PROJECT_DIR = $tempDir
            $env:PA_API_KEY = $null
            $env:DEEPSEEK_API_KEY = $null
            $script:PA_MODE = "oneshot"

            try {
                # Import-Config should call Write-Die which does exit 1
                # In Pester, we need to run in a separate process to test exit
                $paFile = Join-Path (Split-Path $PSScriptRoot -Parent) "PowerAgent.ps1"
                $result = & pwsh -NoProfile -Command @"
                    . '$paFile'
                    `$env:USERPROFILE = '$tempDir'
                    `$global:PA_PROJECT_DIR = '$tempDir'
                    `$env:PA_API_KEY = ''
                    `$env:DEEPSEEK_API_KEY = ''
                    `$script:PA_MODE = 'oneshot'
                    Import-Config
                    Write-Output 'SHOULD_NOT_REACH'
"@
                $LASTEXITCODE | Should -Be 1
                $result | Should -Not -Match 'SHOULD_NOT_REACH'
            } finally {
                $script:PA_MODE = $savedMode
                if ($savedKey) { $env:PA_API_KEY = $savedKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
                if ($savedDK) { $env:DEEPSEEK_API_KEY = $savedDK } else { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
                $env:USERPROFILE = $savedUP
                $global:PA_PROJECT_DIR = $savedPD
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Interactive mode without TTY (Pester/CI)" {
        It "Exits with error — not a real terminal, fallback to Write-Die" {
            # In Pester, [Console]::IsOutputRedirected is always $true
            # so the first-run interactive path should NOT be triggered
            $savedMode = $script:PA_MODE
            $savedKey = $env:PA_API_KEY
            $savedDK = $env:DEEPSEEK_API_KEY
            $savedUP = $env:USERPROFILE
            $savedPD = $global:PA_PROJECT_DIR

            $tempDir = Join-Path $env:TEMP "pa_firstrun_interactive_notty_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $env:USERPROFILE = $tempDir
            $global:PA_PROJECT_DIR = $tempDir
            $env:PA_API_KEY = $null
            $env:DEEPSEEK_API_KEY = $null
            $script:PA_MODE = "interactive"

            try {
                $paFile2 = Join-Path (Split-Path $PSScriptRoot -Parent) "PowerAgent.ps1"
                $result = & pwsh -NoProfile -Command @"
                    . '$paFile2'
                    `$env:USERPROFILE = '$tempDir'
                    `$global:PA_PROJECT_DIR = '$tempDir'
                    `$env:PA_API_KEY = ''
                    `$env:DEEPSEEK_API_KEY = ''
                    `$script:PA_MODE = 'interactive'
                    Import-Config
                    Write-Output 'SHOULD_NOT_REACH'
"@
                # Non-TTY should also die since Invoke-SlashProvider won't be called
                $LASTEXITCODE | Should -Be 1
                $result | Should -Not -Match 'SHOULD_NOT_REACH'
            } finally {
                $script:PA_MODE = $savedMode
                if ($savedKey) { $env:PA_API_KEY = $savedKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
                if ($savedDK) { $env:DEEPSEEK_API_KEY = $savedDK } else { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
                $env:USERPROFILE = $savedUP
                $global:PA_PROJECT_DIR = $savedPD
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "API key present — no FirstRun trigger" {
        It "Does not trigger FirstRun when PA_API_KEY env var is set" {
            $savedKey = $env:PA_API_KEY
            $savedDK = $env:DEEPSEEK_API_KEY
            $savedUP = $env:USERPROFILE
            $savedPD = $global:PA_PROJECT_DIR

            $tempDir = Join-Path $env:TEMP "pa_firstrun_haskey_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $env:USERPROFILE = $tempDir
            $global:PA_PROJECT_DIR = $tempDir
            $env:PA_API_KEY = "test-key-firstrun-check"
            $env:DEEPSEEK_API_KEY = $null

            try {
                { Import-Config } | Should -Not -Throw
                $global:PA_API_KEY | Should -Be "test-key-firstrun-check"
            } finally {
                if ($savedKey) { $env:PA_API_KEY = $savedKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
                if ($savedDK) { $env:DEEPSEEK_API_KEY = $savedDK } else { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
                $env:USERPROFILE = $savedUP
                $global:PA_PROJECT_DIR = $savedPD
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Does not trigger FirstRun when DEEPSEEK_API_KEY env var is set" {
            $savedKey = $env:PA_API_KEY
            $savedDK = $env:DEEPSEEK_API_KEY
            $savedUP = $env:USERPROFILE
            $savedPD = $global:PA_PROJECT_DIR

            $tempDir = Join-Path $env:TEMP "pa_firstrun_dkkey_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $env:USERPROFILE = $tempDir
            $global:PA_PROJECT_DIR = $tempDir
            $env:PA_API_KEY = $null
            $env:DEEPSEEK_API_KEY = "sk-deepseek-fallback-test"

            try {
                { Import-Config } | Should -Not -Throw
                $global:PA_API_KEY | Should -Be "sk-deepseek-fallback-test"
            } finally {
                if ($savedKey) { $env:PA_API_KEY = $savedKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
                if ($savedDK) { $env:DEEPSEEK_API_KEY = $savedDK } else { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
                $env:USERPROFILE = $savedUP
                $global:PA_PROJECT_DIR = $savedPD
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Config cache isolation" {
        It "Import-Config clears stale _CFG cache on entry" {
            # Seed _CFG with stale data
            $global:_CFG["api_key"] = "stale-key-from-previous-test"

            $savedKey = $env:PA_API_KEY
            $savedDK = $env:DEEPSEEK_API_KEY
            $savedUP = $env:USERPROFILE
            $savedPD = $global:PA_PROJECT_DIR

            $tempDir = Join-Path $env:TEMP "pa_firstrun_cache_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $env:USERPROFILE = $tempDir
            $global:PA_PROJECT_DIR = $tempDir
            $env:PA_API_KEY = "fresh-env-key"
            $env:DEEPSEEK_API_KEY = $null

            try {
                Import-Config
                $global:PA_API_KEY | Should -Be "fresh-env-key"
            } finally {
                if ($savedKey) { $env:PA_API_KEY = $savedKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
                if ($savedDK) { $env:DEEPSEEK_API_KEY = $savedDK } else { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
                $env:USERPROFILE = $savedUP
                $global:PA_PROJECT_DIR = $savedPD
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
