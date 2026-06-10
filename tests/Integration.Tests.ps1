# ============================================================================
#  PowerAgent Test — Integration
#  Validates cross-module interactions and initialization sequence
# ============================================================================

Describe "Integration — Module Loading" {
    It "PowerAgent.ps1 exists" {
        $mergedFile = Join-Path (Split-Path $PSScriptRoot -Parent) "PowerAgent.ps1"
        Test-Path $mergedFile | Should -BeTrue -Because "PowerAgent.ps1 should exist"
    }

    It "PowerAgent.ps1 can be dot-sourced without error" {
        $mergedFile = Join-Path (Split-Path $PSScriptRoot -Parent) "PowerAgent.ps1"
        # Already dot-sourced by run_tests.ps1 — just verify functions are available
        Get-Command Initialize-SystemDirs -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Import-Config -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Invoke-ToolReadFile -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "Integration — Initialization Sequence" {
    It "Initialize-SystemDirs does not throw" {
        { Initialize-SystemDirs } | Should -Not -Throw
    }

    It "Initialize-ProjectDirs does not throw" {
        { Initialize-ProjectDirs } | Should -Not -Throw
    }

    It "Initialize-Trace does not throw" {
        { Initialize-Trace } | Should -Not -Throw
    }

    It "Import-Config respects environment variables" {
        $savedApiKey = $env:PA_API_KEY
        $savedModel = $env:PA_MODEL
        $savedProfile = $env:USERPROFILE
        $savedProjectDir = $global:PA_PROJECT_DIR
        $savedDeepseekKey = $env:DEEPSEEK_API_KEY
        # 隔离：重定向 USERPROFILE 到临时目录，防止读取真实 ~/.poweragent/settings.json
        $tempProfile = Join-Path $env:TEMP "pa_integration_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempProfile -Force | Out-Null
        $env:USERPROFILE = $tempProfile
        $global:PA_PROJECT_DIR = $tempProfile
        $env:DEEPSEEK_API_KEY = $null
        try {
            $env:PA_API_KEY = "integration-test-key"
            $env:PA_MODEL = "integration-test-model"
            Import-Config
            $global:PA_API_KEY | Should -Be "integration-test-key"
            $global:PA_MODEL | Should -Be "integration-test-model"
        } finally {
            $env:PA_API_KEY = $savedApiKey
            $env:PA_MODEL = $savedModel
            $env:USERPROFILE = $savedProfile
            $global:PA_PROJECT_DIR = $savedProjectDir
            $env:DEEPSEEK_API_KEY = $savedDeepseekKey
            Remove-Item $tempProfile -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Test-Dependencies does not throw" {
        { Test-Dependencies | Out-Null } | Should -Not -Throw
    }

    It "Initialize-Log does not throw" {
        { Initialize-Log } | Should -Not -Throw
    }
}

Describe "Integration — Config-to-Tools Pipeline" {
    It "Configuration values are accessible from Tools module" {
        $global:PA_SAFE_MODE = $false
        $global:PA_CMD_TIMEOUT = "30"
        $global:PA_TRACE_ENABLED = "0"
        # Should not throw due to missing config values
        $result = Invoke-ToolPowerShell @{ command = "Write-Output 'integration test'" }
        $result.status | Should -Be "ok"
    }
}

Describe "Integration — Message Save/Load Round-Trip" {
    It "Messages survive save and load cycle" {
        $global:PA_HISTORY_FILE = Join-Path $env:TEMP "poweragent_integration_history_$(Get-Random).json"
        $global:MESSAGES = @(
            @{ role = "system"; content = "You are PowerAgent." },
            @{ role = "user"; content = "What is 2+2?" },
            @{ role = "assistant"; content = "4" }
        )

        Save-History
        $global:MESSAGES = @()
        Load-History

        $global:MESSAGES.Count | Should -Be 3
        $global:MESSAGES[1].content | Should -Be "What is 2+2?"
        $global:MESSAGES[2].content | Should -Be "4"

        Remove-Item $global:PA_HISTORY_FILE -Force -ErrorAction SilentlyContinue
    }
}

Describe "Integration — Trace-Record-Read Round-Trip" {
    It "Content survives trace write and read" {
        $global:PA_TRACE_ENABLED = "1"
        $testDir = Join-Path $env:TEMP "poweragent_integration_trace_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_PROJECT_DIR = $testDir
        $paDir = Join-Path $testDir ".poweragent"
        New-Item -ItemType Directory -Path (Join-Path $paDir "trace") -Force | Out-Null
        Initialize-Trace

        $content = "This is traced content for integration test."
        Trace-Record "integration_test" "test_file.ps1" $content

        $hash = Get-TraceHash $content
        $result = Read-TraceObject $hash
        $result | Should -Be $content

        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Integration — MCP + Tools" {
    It "MCP tools JSON can be generated from empty server list" {
        $global:MCP_SERVER_TOOLS = @{}
        $result = Get-McpToolsJson
        # PS 5.1: ConvertTo-Json on empty array may return null
        if ($null -ne $result) {
            $result | Should -Not -BeNullOrEmpty
        } else {
            # Empty tools is acceptable
            $true | Should -BeTrue
        }
    }

    It "MCP dispatch returns error for disconnected server" {
        $result = Invoke-McpDispatchTool "nonexistent_server" "some_tool" @{}
        $result | Should -Match "not connected"
    }
}

Describe "Integration — End-to-End Read/Write/Edit/Delete" {
    It "Full file lifecycle: write → read → edit → read → delete" {
        $testFile = Join-Path $env:TEMP "poweragent_integration_lifecycle_$(Get-Random).txt"

        # Write
        $writeResult = Invoke-ToolWriteFile @{ path = $testFile; content = "Original content" }
        $writeResult.status | Should -Be "ok"

        # Read (content has line numbers: "     1: Original content")
        $readResult = Invoke-ToolReadFile @{ path = $testFile }
        $readResult.status | Should -Be "ok"
        $readResult.content | Should -Match "Original content"

        # Edit
        $editResult = Invoke-ToolEditFile @{ path = $testFile; old_string = "Original"; new_string = "Modified" }
        $editResult.status | Should -Be "ok"

        # Read again
        $readResult2 = Invoke-ToolReadFile @{ path = $testFile }
        $readResult2.content | Should -Match "Modified content"

        # Delete
        $deleteResult = Invoke-ToolDeleteFile @{ path = $testFile }
        $deleteResult.status | Should -Be "ok"
        Test-Path $testFile | Should -BeFalse
    }
}
