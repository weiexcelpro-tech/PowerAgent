# ============================================================================
#  PowerAgent Test — Messages.ps1
#  Validates message history save/load operations
# ============================================================================

Describe "Messages.ps1 — Save-History / Load-History" {
    BeforeEach {
        $global:MESSAGES = @(
            @{ role = "user"; content = "Hello" },
            @{ role = "assistant"; content = "Hi there!" }
        )
        $global:PA_HISTORY_FILE = Join-Path $env:TEMP "poweragent_test_history_$(Get-Random).json"
    }

    AfterEach {
        if ($global:PA_HISTORY_FILE -and (Test-Path $global:PA_HISTORY_FILE)) {
            Remove-Item $global:PA_HISTORY_FILE -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Save-History" {
        It "Creates a JSON file" {
            Save-History
            Test-Path $global:PA_HISTORY_FILE | Should -BeTrue
        }

        It "File contains valid JSON" {
            Save-History
            $content = Get-Content $global:PA_HISTORY_FILE -Raw -Encoding UTF8
            { $content | ConvertFrom-Json } | Should -Not -Throw
        }

        It "File contains the correct number of messages" {
            Save-History
            $content = Get-Content $global:PA_HISTORY_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
            @($content).Count | Should -Be 2
        }
    }

    Context "Load-History" {
        It "Restores messages from file" {
            Save-History
            $global:MESSAGES = @()
            Load-History
            $global:MESSAGES.Count | Should -Be 2
        }

        It "Preserves message content" {
            Save-History
            $global:MESSAGES = @()
            Load-History
            $global:MESSAGES[0].content | Should -Be "Hello"
            $global:MESSAGES[1].content | Should -Be "Hi there!"
        }

        It "Does not throw when file does not exist" {
            $global:PA_HISTORY_FILE = Join-Path $env:TEMP "nonexistent_$(Get-Random).json"
            { Load-History } | Should -Not -Throw
        }
    }
}

Describe "Messages.ps1 — Get-MessagesJson" {
    It "Returns valid JSON from message array" {
        $global:MESSAGES = @(
            @{ role = "user"; content = "Test" }
        )
        $json = Get-MessagesJson
        { $json | ConvertFrom-Json } | Should -Not -Throw
    }
}

# ============================================================================
#  NEW: Additional Messages Tests
# ============================================================================

Describe "Messages.ps1 — Add-UserText" {
    BeforeEach {
        $global:MESSAGES = @()
    }

    It "Appends user message to `$global:MESSAGES" {
        Add-UserText "Hello from user"
        $global:MESSAGES.Count | Should -Be 1
    }

    It "Message has role 'user'" {
        Add-UserText "Hello"
        $global:MESSAGES[0].role | Should -Be "user"
    }

    It "Message has correct content" {
        Add-UserText "Test message content"
        $global:MESSAGES[0].content | Should -Be "Test message content"
    }

    It "Appends multiple messages in order" {
        Add-UserText "first"
        Add-UserText "second"
        $global:MESSAGES.Count | Should -Be 2
        $global:MESSAGES[0].content | Should -Be "first"
        $global:MESSAGES[1].content | Should -Be "second"
    }

    It "Does not modify existing messages" {
        $global:MESSAGES = @(@{ role = "system"; content = "init" })
        Add-UserText "user msg"
        $global:MESSAGES.Count | Should -Be 2
        $global:MESSAGES[0].role | Should -Be "system"
    }
}

Describe "Messages.ps1 — Add-AssistantMessage" {
    BeforeEach {
        $global:MESSAGES = @()
    }

    It "Appends assistant message" {
        $blocks = @(
            @{ type = "text"; text = "response text" }
        )
        Add-AssistantMessage $blocks
        $global:MESSAGES.Count | Should -Be 1
    }

    It "Message has role 'assistant'" {
        $blocks = @(@{ type = "text"; text = "hi" })
        Add-AssistantMessage $blocks
        $global:MESSAGES[0].role | Should -Be "assistant"
    }

    It "Text content is extracted from blocks" {
        $blocks = @(
            @{ type = "text"; text = "part1" },
            @{ type = "text"; text = "part2" }
        )
        Add-AssistantMessage $blocks
        $global:MESSAGES[0].content | Should -Be "part1part2"
    }

    It "Tool use blocks are stored in tool_calls field" {
        $blocks = @(
            @{ type = "text"; text = "response text" },
            @{ type = "tool_use"; id = "t1"; name = "powershell"; input = @{ command = "dir" } }
        )
        Add-AssistantMessage $blocks
        $global:MESSAGES[0].tool_calls | Should -Not -BeNullOrEmpty
        @($global:MESSAGES[0].tool_calls).Count | Should -Be 1
        $global:MESSAGES[0].tool_calls[0].function.name | Should -Be "powershell"
    }
}

Describe "Messages.ps1 — Add-ToolResults" {
    BeforeEach {
        $global:MESSAGES = @()
    }

    It "Appends tool results to `$global:MESSAGES" {
        $results = @(
            @{ type = "tool_result"; tool_use_id = "t1"; content = "output" }
        )
        Add-ToolResults $results
        $global:MESSAGES.Count | Should -Be 1
    }

    It "Message has role 'tool' (tool results go as tool messages)" {
        $results = @(@{ type = "tool_result"; tool_use_id = "t1"; content = "out" })
        Add-ToolResults $results
        $global:MESSAGES[0].role | Should -Be "tool"
    }

    It "Preserves tool result content as string" {
        $results = @(@{ type = "tool_result"; tool_use_id = "t1"; content = @(@{ type = "text"; text = "stdout here" }) })
        Add-ToolResults $results
        $global:MESSAGES[0].content | Should -Be "stdout here"
    }

    It "Handles multiple tool results creating separate messages" {
        $results = @(
            @{ type = "tool_result"; tool_use_id = "t1"; content = @(@{ type = "text"; text = "out1" }) },
            @{ type = "tool_result"; tool_use_id = "t2"; content = @(@{ type = "text"; text = "out2" }) }
        )
        Add-ToolResults $results
        $global:MESSAGES.Count | Should -Be 2
        $global:MESSAGES[0].tool_call_id | Should -Be "t1"
        $global:MESSAGES[0].content | Should -Be "out1"
        $global:MESSAGES[1].tool_call_id | Should -Be "t2"
        $global:MESSAGES[1].content | Should -Be "out2"
    }
}

Describe "Messages.ps1 — Clear-History" {
    It "Resets `$global:MESSAGES to empty array" {
        $global:MESSAGES = @(
            @{ role = "user"; content = "a" },
            @{ role = "assistant"; content = "b" },
            @{ role = "user"; content = "c" }
        )
        $global:MESSAGES.Count | Should -Be 3
        Clear-History
        $global:MESSAGES.Count | Should -Be 0
    }

    It "After clear, Count is 0" {
        $global:MESSAGES = @(@{ role = "user"; content = "x" })
        Clear-History
        $global:MESSAGES.Count | Should -Be 0
    }

    It "Does not throw on already empty history" {
        $global:MESSAGES = @()
        { Clear-History } | Should -Not -Throw
        $global:MESSAGES.Count | Should -Be 0
    }

    It "Allows new messages after clear" {
        $global:MESSAGES = @(@{ role = "user"; content = "old" })
        Clear-History
        Add-UserText "new message"
        $global:MESSAGES.Count | Should -Be 1
        $global:MESSAGES[0].content | Should -Be "new message"
    }
}
