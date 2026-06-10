# ============================================================================
#  PowerAgent Test — Tools.ps1
#  Validates tool schema generation, dispatch, safe mode, file operations
# ============================================================================

Describe "Tools.ps1 — Get-ToolSchemas" {
    It "Returns non-empty result" {
        $schemas = Get-ToolSchemas
        $schemas | Should -Not -BeNullOrEmpty
    }

    It "Contains read_file tool" {
        $schemas = Get-ToolSchemas
        $schemasJson = $schemas | ConvertTo-Json -Depth 5
        $schemasJson | Should -Match "read_file"
    }

    It "Contains write_file tool" {
        $schemas = Get-ToolSchemas
        $schemasJson = $schemas | ConvertTo-Json -Depth 5
        $schemasJson | Should -Match "write_file"
    }

    It "Contains powershell tool" {
        $schemas = Get-ToolSchemas
        $schemasJson = $schemas | ConvertTo-Json -Depth 5
        $schemasJson | Should -Match '"powershell"'
    }

    It "Contains at least 9 tools" {
        $schemas = Get-ToolSchemas
        @($schemas).Count | Should -BeGreaterOrEqual 9
    }
}

Describe "Tools.ps1 — Invoke-ToolReadFile" {
    It "Reads an existing file" {
        $testFile = Join-Path $env:TEMP "poweragent_test_read_$(Get-Random).txt"
        try {
            Set-Content $testFile "Hello Read Test" -Encoding UTF8
            $result = Invoke-ToolReadFile @{ path = $testFile }
            $result.status | Should -Be "ok"
            $result.content | Should -Match "Hello Read Test"
            # 内容包含行号前缀 (e.g., "     1: Hello Read Test")
            $result.content | Should -Match "^\s*1:"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns error for nonexistent file" {
        $result = Invoke-ToolReadFile @{ path = "C:\nonexistent_$(Get-Random).txt" }
        $result.status | Should -Be "error"
    }

    It "Reads with offset and limit" {
        $testFile = Join-Path $env:TEMP "poweragent_test_readoffset_$(Get-Random).txt"
        try {
            $lines = 1..10 | ForEach-Object { "Line $_" }
            Set-Content $testFile $lines -Encoding UTF8
            $result = Invoke-ToolReadFile @{ path = $testFile; offset = 3; limit = 2 }
            $result.status | Should -Be "ok"
            $result.content | Should -Match "Line 3"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Tools.ps1 — Invoke-ToolWriteFile" {
    It "Writes content to a new file" {
        $testFile = Join-Path $env:TEMP "poweragent_test_write_$(Get-Random).txt"
        try {
            $result = Invoke-ToolWriteFile @{ path = $testFile; content = "Written by PowerAgent" }
            $result.status | Should -Be "ok"
            Get-Content $testFile -Raw | Should -Match "Written by PowerAgent"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Overwrites existing file" {
        $testFile = Join-Path $env:TEMP "poweragent_test_overwrite_$(Get-Random).txt"
        try {
            Set-Content $testFile "Old content" -Encoding UTF8
            # WriteFile refuses to overwrite — use edit_file instead
            $result = Invoke-ToolEditFile @{ path = $testFile; old_string = "Old content"; new_string = "New content" }
            $result.status | Should -Be "ok"
            Get-Content $testFile -Raw | Should -Match "New content"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Tools.ps1 — Invoke-ToolEditFile" {
    It "Replaces exact text match" {
        $testFile = Join-Path $env:TEMP "poweragent_test_edit_$(Get-Random).txt"
        try {
            Set-Content $testFile "Hello World" -Encoding UTF8
            $result = Invoke-ToolEditFile @{ path = $testFile; old_string = "World"; new_string = "PowerAgent" }
            $result.status | Should -Be "ok"
            Get-Content $testFile -Raw | Should -Match "Hello PowerAgent"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns error when old_string not found" {
        $testFile = Join-Path $env:TEMP "poweragent_test_editnf_$(Get-Random).txt"
        try {
            Set-Content $testFile "Hello World" -Encoding UTF8
            $result = Invoke-ToolEditFile @{ path = $testFile; old_string = "NotExist"; new_string = "X" }
            $result.status | Should -Be "error"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Tools.ps1 — Invoke-ToolDeleteFile" {
    It "Deletes an existing file" {
        $testFile = Join-Path $env:TEMP "poweragent_test_delete_$(Get-Random).txt"
        Set-Content $testFile "To be deleted" -Encoding UTF8
        $result = Invoke-ToolDeleteFile @{ path = $testFile }
        $result.status | Should -Be "ok"
        Test-Path $testFile | Should -BeFalse
    }

    It "Returns error for nonexistent file" {
        $result = Invoke-ToolDeleteFile @{ path = "C:\nonexistent_$(Get-Random).txt" }
        $result.status | Should -Be "error"
    }
}

Describe "Tools.ps1 — Invoke-ToolListFiles" {
    It "Lists files in a directory" {
        $testDir = Join-Path $env:TEMP "poweragent_test_list_$(Get-Random)"
        try {
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            Set-Content (Join-Path $testDir "a.txt") "A" -Encoding UTF8
            Set-Content (Join-Path $testDir "b.txt") "B" -Encoding UTF8
            $result = Invoke-ToolListFiles @{ path = $testDir }
            $result.status | Should -Be "ok"
            $names = ($result.entries | ForEach-Object { $_.name }) -join ","
            $names | Should -Match "a.txt"
            $names | Should -Match "b.txt"
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Tools.ps1 — Invoke-ToolPowerShell" {
    It "Executes a simple command" {
        $result = Invoke-ToolPowerShell @{ command = "Write-Output 'hello from powershell tool'" }
        $result.status | Should -Be "ok"
        $result.output | Should -Match "hello from powershell tool"
    }

    It "Captures stderr" {
        $result = Invoke-ToolPowerShell @{ command = "Write-Error 'test error'" }
        # Should still complete, either with ok or error
        $result | Should -Not -BeNullOrEmpty
    }

    It "Respects timeout parameter" {
        $result = Invoke-ToolPowerShell @{ command = "Start-Sleep -Seconds 1; Write-Output 'done'"; timeout = 5 }
        $result.status | Should -Be "ok"
    }
}

Describe "Tools.ps1 — Invoke-ToolDispatch" {
    It "Dispatches read_file correctly" {
        $testFile = Join-Path $env:TEMP "poweragent_test_dispatch_$(Get-Random).txt"
        try {
            Set-Content $testFile "Dispatch test" -Encoding UTF8
            $result = Invoke-ToolDispatch -ToolName "read_file" -ToolInput @{ path = $testFile }
            # 返回原始结果（无 ToolId 时不包装为 tool_result）
            $result.status | Should -Be "ok"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns error for unknown tool" {
        $result = Invoke-ToolDispatch -ToolName "nonexistent_tool_12345" -ToolInput @{}
        $result.status | Should -Be "error"
    }
}

Describe "Tools.ps1 — Safe Mode" {
    It "Safe mode blocks destructive operations" {
        $global:PA_SAFE_MODE = $true
        $global:PA_HEADLESS = $true
        try {
            $result = Invoke-ToolDispatch -ToolName "write_file" -ToolInput @{ path = "test.txt"; content = "x" }
            # Headless mode: safe mode auto-denies destructive operations
            $result | Should -Not -BeNullOrEmpty
            $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
            $resultJson | Should -Match "denied|error|safe"
        } finally {
            $global:PA_SAFE_MODE = $false
            $global:PA_HEADLESS = $false
        }
    }
}

Describe "Tools.ps1 — CJK Path Handling" {
    BeforeEach {
        # 创建含中文的临时目录
        $testDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $cjkFile = Join-Path $testDir "中文文件.txt"
        Set-Content -Path $cjkFile -Value "这是一个测试文件" -Encoding UTF8
    }
    AfterEach {
        # 清理临时目录
        $testDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_*"
        Get-Item $testDir -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "list_files handles CJK directory path" {
        $actualDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_*"
        $dir = (Get-Item $actualDir -ErrorAction SilentlyContinue)[0]
        $dir | Should -Not -BeNullOrEmpty
        $result = Invoke-ToolListFiles @{ path = $dir.FullName }
        $result.status | Should -Be "ok"
        $result.entries.Count | Should -BeGreaterOrEqual 1
    }

    It "read_file handles CJK file path" {
        $actualDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_*"
        $dir = (Get-Item $actualDir -ErrorAction SilentlyContinue)[0]
        $cjkFile = Join-Path $dir.FullName "中文文件.txt"
        $result = Invoke-ToolReadFile @{ path = $cjkFile }
        $result.status | Should -Be "ok"
        $result.content | Should -Match "测试文件"
    }

    It "write_file creates file in CJK directory path" {
        $actualDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_*"
        $dir = (Get-Item $actualDir -ErrorAction SilentlyContinue)[0]
        $newFile = Join-Path $dir.FullName "新文件.txt"
        try {
            $result = Invoke-ToolWriteFile @{ path = $newFile; content = "新建内容" }
            $result.status | Should -Be "ok"
            Test-Path $newFile | Should -BeTrue
        } finally {
            Remove-Item $newFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "edit_file handles CJK file path" {
        $actualDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_*"
        $dir = (Get-Item $actualDir -ErrorAction SilentlyContinue)[0]
        $cjkFile = Join-Path $dir.FullName "中文文件.txt"
        $result = Invoke-ToolEditFile @{ path = $cjkFile; old_string = "测试"; new_string = "修改" }
        $result.status | Should -Be "ok"
    }

    It "Invoke-ToolDispatch handles CJK path via dispatch" {
        $actualDir = Join-Path $env:TEMP "PowerAgent_CJK_测试目录_*"
        $dir = (Get-Item $actualDir -ErrorAction SilentlyContinue)[0]
        $result = Invoke-ToolDispatch -ToolName "list_files" -ToolInput @{ path = $dir.FullName }
        $result.status | Should -Be "ok"
    }
}

# ============================================================================
#  web_request Tool Tests (TODO-01 alignment)
# ============================================================================
Describe "Tools.ps1 — Invoke-ToolWebRequest" {
    BeforeAll {
        $savedApiKey = $global:PA_API_KEY
        $savedApiUrl = $global:PA_API_URL
    }
    AfterAll {
        $global:PA_API_KEY = $savedApiKey
        $global:PA_API_URL = $savedApiUrl
    }

    It "Validates required 'url' parameter" {
        $result = Invoke-ToolWebRequest @{ }
        $result.status | Should -Be "error"
        $result.error | Should -Match "url"
    }

    It "Validates URL format" {
        $result = Invoke-ToolWebRequest @{ url = "not-a-valid-url" }
        $result.status | Should -Be "error"
        $result.error | Should -Match "url"
    }

    It "Rejects missing URL gracefully" {
        $result = Invoke-ToolWebRequest @{ method = "GET" }
        $result.status | Should -Be "error"
    }

    It "web_request is in tool schema" {
        $schemas = Get-ToolSchemas
        $schemaNames = @($schemas) | ForEach-Object { $_.name }
        $schemaNames | Should -Contain "web_request"
    }

    It "web_request is dispatchable" {
        # 确保路由存在（不实际发起请求，只验证 dispatch 不抛 Unknown tool）
        $global:PA_API_KEY = "test-key"
        $global:PA_API_URL = "http://localhost:9999"
        # 使用无效 URL 验证 dispatch 走到了 Invoke-ToolWebRequest
        $result = Invoke-ToolDispatch -ToolName "web_request" -ToolInput @{ url = "" }
        $result.status | Should -Be "error"
    }
}
