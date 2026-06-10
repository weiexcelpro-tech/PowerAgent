# ============================================================================
#  PowerAgent Test — Compression.ps1
#  Validates context compression, prompt building, token estimation
# ============================================================================

Describe "Compression.ps1 — Get-CompHash" {
    It "Returns consistent hash for same input" {
        $h1 = Get-CompHash "test input"
        $h2 = Get-CompHash "test input"
        $h1 | Should -Be $h2
    }

    It "Returns different hash for different input" {
        $h1 = Get-CompHash "A"
        $h2 = Get-CompHash "B"
        $h1 | Should -Not -Be $h2
    }
}

Describe "Compression.ps1 — Estimate-ContextTokens" {
    It "Returns positive number for non-empty messages" {
        $global:MESSAGES = @(
            @{ role = "user"; content = "Hello world, this is a test." }
        )
        $tokens = Estimate-ContextTokens
        $tokens | Should -BeGreaterThan 0
    }

    It "Returns base offset for empty messages" {
        $global:MESSAGES = @()
        $tokens = Estimate-ContextTokens
        $tokens | Should -BeGreaterThan 0
    }

    It "Estimation increases with more messages" {
        $global:MESSAGES = @(
            @{ role = "user"; content = "Short" }
        )
        $tokens1 = Estimate-ContextTokens
        $global:MESSAGES = @(
            @{ role = "user"; content = "A" * 1000 }
        )
        $tokens2 = Estimate-ContextTokens
        $tokens2 | Should -BeGreaterThan $tokens1
    }
}

Describe "Compression.ps1 — Build-SystemPrompt" {
    It "Returns non-empty string" {
        $prompt = Build-SystemPrompt
        $prompt | Should -Not -BeNullOrEmpty
    }

    It "Includes system prompt content" {
        $global:PA_SYSTEM_PROMPT = "You are a helpful assistant."
        $prompt = Build-SystemPrompt
        $prompt | Should -Match "helpful assistant"
    }
}

Describe "Compression.ps1 — Build-DynamicContext" {
    It "Returns a string" {
        $ctx = Build-DynamicContext
        $ctx | Should -Not -BeNullOrEmpty
    }

    It "Includes model name" {
        $global:PA_MODEL = "test-model-v1"
        $ctx = Build-DynamicContext
        $ctx | Should -Match "test-model-v1"
    }
}

Describe "Compression.ps1 — Test-ContextWindowPressure" {
    It "Returns a valid pressure level string" {
        $global:MESSAGES = @()
        $global:PA_CONTEXT_WINDOW = "200000"
        $global:PA_CONTEXT_SAFE_RATIO = "75"
        $result = Test-ContextWindowPressure
        $result | Should -BeIn @("ok", "safe_pressure", "warn", "critical")
    }
}

Describe "Compression.ps1 — Compress-Offload" {
    It "Does not throw with empty messages" {
        $global:MESSAGES = @()
        { Compress-Offload } | Should -Not -Throw
    }
}

Describe "Compression.ps1 — Compress-ToolEvict" {
    It "Does not throw with empty messages" {
        $global:MESSAGES = @()
        { Compress-ToolEvict } | Should -Not -Throw
    }
}

Describe "Compression.ps1 — Compress-Context" {
    It "Does not throw with empty messages" {
        $global:MESSAGES = @()
        { Compress-Context } | Should -Not -Throw
    }

    It "Does not throw with sample messages" {
        $global:MESSAGES = @(
            @{ role = "user"; content = "Hello" },
            @{ role = "assistant"; content = "Hi!" },
            @{ role = "user"; content = "How are you?" },
            @{ role = "assistant"; content = "I'm doing great!" }
        )
        { Compress-Context } | Should -Not -Throw
    }
}

# ============================================================================
#  NEW: Additional coverage for Compression.ps1
# ============================================================================

Describe "Compression.ps1 — Build-RequestTools" {
    Context "Base tool schemas" {
        It "Returns non-null result" {
            $tools = Build-RequestTools
            $tools | Should -Not -BeNullOrEmpty
        }

        It "Returns tool schemas with at least one entry" {
            $tools = Build-RequestTools
            $tools.Count | Should -BeGreaterThan 0
        }
    }

    Context "MCP tool integration" {
        BeforeAll {
            $script:_savedMcp = $global:MCP_TOOLS_SCHEMA
        }
        AfterAll {
            $global:MCP_TOOLS_SCHEMA = $script:_savedMcp
        }

        It "Includes MCP tools when `$global:MCP_TOOLS_SCHEMA is set" {
            $global:MCP_TOOLS_SCHEMA = @(
                @{ name = "mcp_test_tool"; type = "function" }
            )
            $tools = Build-RequestTools
            $mcpNames = @($tools | Where-Object { $_.name -eq "mcp_test_tool" })
            $mcpNames.Count | Should -BeGreaterThan 0
        }

        It "Returns only base tools when MCP_TOOLS_SCHEMA is null" {
            $global:MCP_TOOLS_SCHEMA = $null
            $tools = Build-RequestTools
            $tools | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Compression.ps1 — Estimate-ContextTokens edge cases" {
    Context "Empty and boundary inputs" {
        It "Returns exactly 28000 for empty messages" {
            $global:MESSAGES = @()
            $tokens = Estimate-ContextTokens
            $tokens | Should -Be 28000
        }

        It "Returns larger value for messages with long content" {
            $global:MESSAGES = @(
                @{ role = "user"; content = "x" * 5000 }
            )
            $tokens = Estimate-ContextTokens
            $tokens | Should -BeGreaterThan 28000
        }

        It "Sets `$global:ESTIMATED_CONTEXT_TOKENS as side effect" {
            $global:MESSAGES = @()
            $null = Estimate-ContextTokens
            $global:ESTIMATED_CONTEXT_TOKENS | Should -Be 28000
        }
    }
}

Describe "Compression.ps1 — Test-ContextWindowPressure edge cases" {
    Context "Threshold boundaries" {
        BeforeAll {
            $script:_savedWindow = $global:PA_CONTEXT_WINDOW
            $script:_savedSafe = $global:PA_CONTEXT_SAFE_RATIO
        }
        AfterAll {
            $global:PA_CONTEXT_WINDOW = $script:_savedWindow
            $global:PA_CONTEXT_SAFE_RATIO = $script:_savedSafe
        }

        It "Returns critical when context exceeds 95 percent of window" {
            # Base offset is 28000, so with PA_CONTEXT_WINDOW=28000, empty messages hit critical
            $global:PA_CONTEXT_WINDOW = "28000"
            $global:PA_CONTEXT_SAFE_RATIO = "75"
            $global:MESSAGES = @()
            $result = Test-ContextWindowPressure
            $result | Should -Be "critical"
        }

        It "Returns ok when context is well under threshold" {
            $global:PA_CONTEXT_WINDOW = "200000"
            $global:PA_CONTEXT_SAFE_RATIO = "75"
            $global:MESSAGES = @()
            $result = Test-ContextWindowPressure
            $result | Should -Be "ok"
        }
    }
}

Describe "Compression.ps1 — Compress-Offload with messages" {
    Context "Messages containing tool_use content blocks" {
        It "Does not throw with tool-result messages" {
            $global:MESSAGES = @(
                @{ role = "assistant"; content = @(
                    @{ type = "tool_use"; id = "tu_001"; name = "powershell"; input = @{ command = "ls" } }
                ) },
                @{ role = "user"; content = @(
                    @{ type = "tool_result"; tool_use_id = "tu_001"; content = @(
                        @{ type = "text"; text = "file1.txt`nfile2.txt" }
                    ) }
                ) }
            )
            { Compress-Offload } | Should -Not -Throw
        }
    }
}

Describe "Compression.ps1 — Compress-ToolEvict with tool messages" {
    Context "Messages containing tool_use blocks" {
        It "Does not throw with messages containing tool_use blocks" {
            # Build enough messages to pass the 5-round guard (>5 user messages)
            $global:MESSAGES = @()
            for ($i = 1; $i -le 6; $i++) {
                $global:MESSAGES += @{ role = "user"; content = @(
                    @{ type = "tool_result"; tool_use_id = "tu_$i"; content = @(
                        @{ type = "text"; text = ("Result output line " * 50) }
                    ) }
                ) }
                $global:MESSAGES += @{ role = "assistant"; content = @(
                    @{ type = "tool_use"; id = "tu_$i"; name = "powershell"; input = @{ command = "echo $i" } }
                ) }
            }
            { Compress-ToolEvict } | Should -Not -Throw
        }
    }
}
