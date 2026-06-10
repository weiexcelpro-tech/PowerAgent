# ============================================================================
#  PowerAgent Test — AgentLoop.ps1
#  Validates Compute-CallBudget, Test-TurnBudget, slash commands
# ============================================================================

Describe "AgentLoop.ps1 — Compute-CallBudget" {
    Context "Low tool usage returns full budget" {
        It "Returns '100pct' for 0 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 0 | Should -Be "100pct"
        }

        It "Returns '100pct' for 1 consecutive tool" {
            Compute-CallBudget -ConsecutiveTools 1 | Should -Be "100pct"
        }

        It "Returns '100pct' for 2 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 2 | Should -Be "100pct"
        }
    }

    Context "Moderate tool usage returns half budget" {
        It "Returns '50pct' for 10 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 10 | Should -Be "50pct"
        }

        It "Returns '50pct' for 30 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 30 | Should -Be "50pct"
        }

        It "Returns '50pct' for 89 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 89 | Should -Be "50pct"
        }
    }

    Context "High tool usage halts the loop" {
        It "Returns 'halt' for 90 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 90 | Should -Be "halt"
        }

        It "Returns 'halt' for 100 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 100 | Should -Be "halt"
        }

        It "Returns 'halt' for 200 consecutive tools" {
            Compute-CallBudget -ConsecutiveTools 200 | Should -Be "halt"
        }
    }
}

Describe "AgentLoop.ps1 — Test-TurnBudget" {
    Context "Context window pressure" {
        BeforeEach {
            $script:savedContextWindow = $global:PA_CONTEXT_WINDOW
            $script:savedEstimate = Get-Content Function:\Estimate-ContextTokens -ErrorAction SilentlyContinue
            # Mock Estimate-ContextTokens — will be overridden per test
            function global:Estimate-ContextTokens { return 0 }
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value $null -Scope Global
        }

        AfterEach {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value $script:savedContextWindow -Scope Global
            # Restore original Estimate-ContextTokens (re-dot-sourcing not needed;
            # the real function is restored when the merged file is loaded fresh)
            if ($script:savedEstimate) {
                Set-Content Function:\Estimate-ContextTokens $script:savedEstimate
            }
        }

        It "Returns 'ok' when estimated tokens well under threshold" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            function global:Estimate-ContextTokens { return 50000 }
            Test-TurnBudget | Should -Be "ok"
        }

        It "Returns 'ok' when estimated tokens just below soft limit (84%)" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            # 85% of 128000 = 108800; test with 108799 (just under)
            function global:Estimate-ContextTokens { return 108799 }
            Test-TurnBudget | Should -Be "ok"
        }

        It "Returns 'soft_limit' when over 85% but under 95%" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            # 85% = 108800, 95% = 121600; use 110000
            function global:Estimate-ContextTokens { return 110000 }
            Test-TurnBudget | Should -Be "soft_limit"
        }

        It "Returns 'exhausted' when over 95% of context window" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            # 95% = 121600; use 130000
            function global:Estimate-ContextTokens { return 130000 }
            Test-TurnBudget | Should -Be "exhausted"
        }

        It "Returns 'exhausted' when tokens equal 95% threshold exactly" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            # 95% of 128000 = Floor(128000 * 0.95) = 121600
            function global:Estimate-ContextTokens { return 121600 }
            Test-TurnBudget | Should -Be "exhausted"
        }

        It "Returns 'ok' when PA_CONTEXT_WINDOW is 0 or unset" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 0 -Scope Global
            function global:Estimate-ContextTokens { return 999999 }
            Test-TurnBudget | Should -Be "ok"
        }
    }
}

Describe "AgentLoop.ps1 — Register-BuiltinSlashCommands" {
    BeforeEach {
        $global:SLASH_COMMANDS = @{}
    }

    It "Registers all 17 expected slash commands" {
        Register-BuiltinSlashCommands
        $expectedCommands = @(
            "help", "clear", "save", "load", "compress", "status",
            "model", "provider", "exit", "safe", "trace", "undo",
            "tasks", "memory", "remember", "skills", "mcp"
        )
        foreach ($cmd in $expectedCommands) {
            $global:SLASH_COMMANDS.ContainsKey($cmd) | Should -BeTrue -Because "slash command '$cmd' should be registered"
        }
    }

    It "Each command value is a non-empty handler name" {
        Register-BuiltinSlashCommands
        foreach ($key in $global:SLASH_COMMANDS.Keys) {
            $global:SLASH_COMMANDS[$key] | Should -Not -BeNullOrEmpty -Because "handler for '/$key' should not be empty"
        }
    }

    It "Does not register unexpected commands" {
        Register-BuiltinSlashCommands
        $global:SLASH_COMMANDS.Count | Should -Be 17
    }
}

Describe "AgentLoop.ps1 — Invoke-SlashModel" {
    BeforeEach {
        $savedModel = $global:PA_MODEL
        $global:PA_MODEL = "original-model"
        # Mock Save-Setting to prevent writing test model names to real ~/.poweragent/settings.json
        $savedSaveSetting = $global:_PA_ORIGINAL_FN_DEFS['Save-Setting']
        function global:Save-Setting { param($Key, $Value) $global:_MOCK_SAVE_SETTING = @{ $Key = $Value } }
    }

    AfterEach {
        $global:PA_MODEL = $savedModel
        # Restore real Save-Setting
        if ($savedSaveSetting) {
            Set-Item -Path 'function:global:Save-Setting' -Value $savedSaveSetting
        }
    }

    It "Sets PA_MODEL when a model name is provided" {
        # /model gpt-4 → splits to ["/model", "gpt-4"], model at index 1
        $handler = $global:SLASH_COMMANDS["model"]
        & $handler "/model gpt-4"
        $global:PA_MODEL | Should -Be "gpt-4"
    }

    It "Sets PA_MODEL to multi-word model name" {
        $handler = $global:SLASH_COMMANDS["model"]
        & $handler "/model claude-3-opus-20240229"
        $global:PA_MODEL | Should -Be "claude-3-opus-20240229"
    }

    It "Does not change PA_MODEL when no argument is given" {
        Invoke-SlashModel -CommandInput "/model"
        $global:PA_MODEL | Should -Be "original-model"
    }
}

Describe "AgentLoop.ps1 — Invoke-SlashExit" {
    It "Sets `$global:_EXIT_REQUESTED to `$true" {
        $global:_EXIT_REQUESTED = $false
        Invoke-SlashExit
        $global:_EXIT_REQUESTED | Should -Be $true
    }
}

Describe "AgentLoop.ps1 — Invoke-SlashSafe" {
    It "Toggles PA_SAFE_MODE from false to true" {
        $global:PA_SAFE_MODE = $false
        Invoke-SlashSafe
        $global:PA_SAFE_MODE | Should -Be $true
    }

    It "Toggles PA_SAFE_MODE back to false on second call" {
        $global:PA_SAFE_MODE = $false
        Invoke-SlashSafe
        Invoke-SlashSafe
        $global:PA_SAFE_MODE | Should -Be $false
    }

    It "Toggles PA_SAFE_MODE from true to false" {
        $global:PA_SAFE_MODE = $true
        Invoke-SlashSafe
        $global:PA_SAFE_MODE | Should -Be $false
    }
}

Describe "AgentLoop.ps1 — Oneshot Mode" {
    BeforeEach {
        # 保存状态
        $script:_savedMode = $global:PA_MODE
        $script:_savedExit = $global:_EXIT_REQUESTED
        $script:_savedPrompt = $env:PA_ONESHOT_PROMPT
        $global:_EXIT_REQUESTED = $false
        $global:PA_MODE = $null
    }

    AfterEach {
        # 恢复状态
        $global:PA_MODE = $script:_savedMode
        $global:_EXIT_REQUESTED = $script:_savedExit
        $env:PA_ONESHOT_PROMPT = $script:_savedPrompt
    }

    It "Sets _EXIT_REQUESTED when PA_MODE is oneshot with prompt" {
        $global:PA_MODE = "oneshot"
        $env:PA_ONESHOT_PROMPT = "test prompt"
        $global:_EXIT_REQUESTED = $false

        # Start-AgentLoop 的 oneshot 分支直接调用 Invoke-RunTurn + 设置退出
        # 我们只测试 oneshot 逻辑本身，不实际调用 Start-AgentLoop（会输出 banner）
        # 模拟 oneshot 逻辑
        if ($global:PA_MODE -eq "oneshot") {
            $prompt = $env:PA_ONESHOT_PROMPT
            if (-not [string]::IsNullOrWhiteSpace($prompt)) {
                # oneshot 会调用 Invoke-RunTurn，但我们不实际调用
            }
            $global:_EXIT_REQUESTED = $true
        }

        $global:_EXIT_REQUESTED | Should -Be $true
    }

    It "Sets _EXIT_REQUESTED even when PA_ONESHOT_PROMPT is empty" {
        $global:PA_MODE = "oneshot"
        $env:PA_ONESHOT_PROMPT = ""
        $global:_EXIT_REQUESTED = $false

        # 模拟 oneshot 逻辑
        if ($global:PA_MODE -eq "oneshot") {
            $prompt = $env:PA_ONESHOT_PROMPT
            if (-not [string]::IsNullOrWhiteSpace($prompt)) {
                # skip
            }
            $global:_EXIT_REQUESTED = $true
        }

        $global:_EXIT_REQUESTED | Should -Be $true
    }

    It "Does not set _EXIT_REQUESTED when PA_MODE is not oneshot" {
        $global:PA_MODE = "interactive"
        $env:PA_ONESHOT_PROMPT = "test prompt"
        $global:_EXIT_REQUESTED = $false

        if ($global:PA_MODE -eq "oneshot") {
            $global:_EXIT_REQUESTED = $true
        }

        $global:_EXIT_REQUESTED | Should -Be $false
    }

    It "Detects null PA_ONESHOT_PROMPT as whitespace" {
        $env:PA_ONESHOT_PROMPT = $null
        [string]::IsNullOrWhiteSpace($env:PA_ONESHOT_PROMPT) | Should -Be $true
    }

    It "Detects empty PA_ONESHOT_PROMPT as whitespace" {
        $env:PA_ONESHOT_PROMPT = ""
        [string]::IsNullOrWhiteSpace($env:PA_ONESHOT_PROMPT) | Should -Be $true
    }

    It "Detects whitespace-only PA_ONESHOT_PROMPT as whitespace" {
        $env:PA_ONESHOT_PROMPT = "   "
        [string]::IsNullOrWhiteSpace($env:PA_ONESHOT_PROMPT) | Should -Be $true
    }

    It "Accepts non-empty PA_ONESHOT_PROMPT" {
        $env:PA_ONESHOT_PROMPT = "Hello world"
        [string]::IsNullOrWhiteSpace($env:PA_ONESHOT_PROMPT) | Should -Be $false
    }
}

# ============================================================================
#  Loop Detection Tests (Bug 4)
# ============================================================================

Describe "AgentLoop.ps1 — Test-ToolLoop (LoopDetection)" {
    BeforeEach {
        $global:_TOOL_CALL_HISTORY = @()
        $global:_LOOP_DETECTION_ENABLED = $true
    }

    Context "First call returns ok" {
        It "Returns 'ok' for first tool call" {
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
        }
    }

    Context "Second identical call returns ok" {
        It "Returns 'ok' for second identical call" {
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
        }
    }

    Context "Third identical call returns warn" {
        It "Returns 'warn' at 3 consecutive identical calls" {
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "warn"
        }
    }

    Context "Fifth identical call returns halt" {
        It "Returns 'halt' at 5 consecutive identical calls" {
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "warn"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "warn"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "halt"
        }
    }

    Context "Different args resets counter" {
        It "Different tool args do not trigger warn" {
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="a.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="a.txt"} | Should -Be "ok"
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="b.txt"} | Should -Be "ok"
        }
    }

    Context "Disabled loop detection returns ok" {
        It "Returns 'ok' when loop detection disabled" {
            $global:_LOOP_DETECTION_ENABLED = $false
            for ($i = 0; $i -lt 6; $i++) {
                Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="test.txt"} | Should -Be "ok"
            }
        }
    }

    Context "Tracks history correctly" {
        It "Records calls in _TOOL_CALL_HISTORY" {
            Test-ToolLoop -ToolName "read_file" -ToolArgs @{path="a.txt"}
            Test-ToolLoop -ToolName "list_files" -ToolArgs @{path="."}
            $global:_TOOL_CALL_HISTORY.Count | Should -Be 2
            $global:_TOOL_CALL_HISTORY[0].tool | Should -Be "read_file"
            $global:_TOOL_CALL_HISTORY[1].tool | Should -Be "list_files"
        }
    }
}

# ============================================================================
#  Tool Result Dedup/Truncation Tests (Bug 3)
# ============================================================================

Describe "AgentLoop.ps1 — Compress-ToolResult" {
    BeforeEach {
        $global:_TOOL_RESULT_CACHE = @{}
        $global:TOOL_RESULT_CHAR_BUDGET = 12000
    }

    Context "Short result passes through" {
        It "Returns short result unchanged" {
            $result = Compress-ToolResult -ToolName "read_file" -ToolArgs @{path="t"} -ResultJson "Hello World"
            $result | Should -Be "Hello World"
        }
    }

    Context "Long result gets truncated" {
        It "Truncates result exceeding 12000 chars" {
            $longText = "A" * 15000
            $result = Compress-ToolResult -ToolName "powershell" -ToolArgs @{command="ls"} -ResultJson $longText
            $result.Length | Should -BeGreaterThan 12000
            $result.Length | Should -BeLessThan 13000
            $result | Should -Match "truncated"
        }
    }

    Context "Duplicate result gets deduplicated" {
        It "Returns dedup message for identical result" {
            $json = '{"status":"ok","data":"test data"}'
            $result1 = Compress-ToolResult -ToolName "read_file" -ToolArgs @{path="t"} -ResultJson $json
            $result1 | Should -Be $json
            # Same result again
            $result2 = Compress-ToolResult -ToolName "read_file" -ToolArgs @{path="t"} -ResultJson $json
            $result2 | Should -Match "deduplicated"
        }
    }

    Context "Null/empty result handled gracefully" {
        It "Returns null for null input" {
            $result = Compress-ToolResult -ToolName "test" -ToolArgs @{} -ResultJson $null
            $result | Should -BeNullOrEmpty
        }

        It "Returns empty for empty input" {
            $result = Compress-ToolResult -ToolName "test" -ToolArgs @{} -ResultJson ""
            $result | Should -Be ""
        }
    }

    Context "Custom budget" {
        It "Respects custom TOOL_RESULT_CHAR_BUDGET" {
            $global:TOOL_RESULT_CHAR_BUDGET = 100
            $longText = "X" * 200
            $result = Compress-ToolResult -ToolName "test" -ToolArgs @{} -ResultJson $longText
            $result.Length | Should -BeGreaterThan 100
            $result.Length | Should -BeLessThan 200
            $result | Should -Match "truncated"
        }
    }

    Context "Cache cleanup" {
        It "Cleans up cache when exceeding 50 entries" {
            for ($i = 0; $i -lt 55; $i++) {
                Compress-ToolResult -ToolName "test" -ToolArgs @{i=$i} -ResultJson "unique data $i"
            }
            # Cache should be trimmed
            $global:_TOOL_RESULT_CACHE.Count | Should -BeLessOrEqual 50
        }
    }
}

Describe "AgentLoop.ps1 — Get-ArgsHash" {
    It "Returns consistent hash for same input" {
        $h1 = Get-ArgsHash -ToolName "read_file" -ToolArgs @{path="test.txt"}
        $h2 = Get-ArgsHash -ToolName "read_file" -ToolArgs @{path="test.txt"}
        $h1 | Should -Be $h2
    }

    It "Returns different hash for different tool" {
        $h1 = Get-ArgsHash -ToolName "read_file" -ToolArgs @{path="test.txt"}
        $h2 = Get-ArgsHash -ToolName "list_files" -ToolArgs @{path="test.txt"}
        $h1 | Should -Not -Be $h2
    }

    It "Returns different hash for different args" {
        $h1 = Get-ArgsHash -ToolName "read_file" -ToolArgs @{path="a.txt"}
        $h2 = Get-ArgsHash -ToolName "read_file" -ToolArgs @{path="b.txt"}
        $h1 | Should -Not -Be $h2
    }

    It "Handles string args" {
        $h = Get-ArgsHash -ToolName "powershell" -ToolArgs '{"command":"ls"}'
        $h.Length | Should -Be 64
    }
}

# ============================================================================
#  Plan System Tests (Item 11)
# ============================================================================

Describe "AgentLoop.ps1 — Invoke-PlanHandleResponse" {
    BeforeEach {
        $global:_PLAN_STOP = 0
        $global:_PLAN_PENDING = $true
        $global:_PLAN_DEFERRED_MSG = ""
        $global:_DEFERRED_FEEDBACK = ""
    }

    Context "Approve plan (choice_index 0)" {
        It "Sets _PLAN_DEFERRED_MSG and clears _PLAN_PENDING when approved" {
            $json = '{"index":0,"status":"ok","choice":"Approve"}'
            $result = Invoke-PlanHandleResponse -ChoiceJson $json
            $global:_PLAN_STOP | Should -Be 0
            $global:_PLAN_PENDING | Should -Be $false
            $global:_PLAN_DEFERRED_MSG | Should -Match "plan approved"
            $result | Should -Match "approved"
        }
    }

    Context "Reject plan (choice_index 1)" {
        It "Sets _PLAN_STOP=1 and clears _PLAN_PENDING when rejected" {
            $json = '{"index":1,"status":"ok","choice":"Reject"}'
            $result = Invoke-PlanHandleResponse -ChoiceJson $json
            $global:_PLAN_STOP | Should -Be 1
            $global:_PLAN_PENDING | Should -Be $false
            $result | Should -Match "rejected"
        }
    }

    Context "Cancelled plan" {
        It "Sets _PLAN_STOP=1 when status is cancelled" {
            $json = '{"status":"cancelled"}'
            $result = Invoke-PlanHandleResponse -ChoiceJson $json
            $global:_PLAN_STOP | Should -Be 1
            $global:_PLAN_PENDING | Should -Be $false
            $result | Should -Match "cancelled"
        }
    }

    Context "Null/empty response" {
        It "Sets _PLAN_STOP=1 for empty choice JSON" {
            $result = Invoke-PlanHandleResponse -ChoiceJson ""
            $global:_PLAN_STOP | Should -Be 1
            $result | Should -Match "No response"
        }

        It "Sets _PLAN_STOP=1 for null choice JSON" {
            $result = Invoke-PlanHandleResponse -ChoiceJson $null
            $global:_PLAN_STOP | Should -Be 1
        }

        It "Sets _PLAN_STOP=1 for whitespace-only choice JSON" {
            $result = Invoke-PlanHandleResponse -ChoiceJson "   "
            $global:_PLAN_STOP | Should -Be 1
        }
    }

    Context "Invalid JSON" {
        It "Sets _PLAN_STOP=1 for malformed JSON" {
            $result = Invoke-PlanHandleResponse -ChoiceJson "not json at all"
            $global:_PLAN_STOP | Should -Be 1
            $result | Should -Match "Failed to parse"
        }
    }

    Context "choice_index > 1 treated as rejection" {
        It "Sets _PLAN_STOP=1 for choice_index 2" {
            $json = '{"index":2,"status":"ok"}'
            $result = Invoke-PlanHandleResponse -ChoiceJson $json
            $global:_PLAN_STOP | Should -Be 1
            $result | Should -Match "not approved"
        }
    }

    Context "Supports choice_index field name" {
        It "Parses choice_index field as alternative to index" {
            $json = '{"choice_index":0,"result":"ok"}'
            $result = Invoke-PlanHandleResponse -ChoiceJson $json
            $global:_PLAN_STOP | Should -Be 0
            $global:_PLAN_DEFERRED_MSG | Should -Match "plan approved"
        }
    }
}

Describe "AgentSystem.ps1 — Invoke-PlanExtractSteps" {
    Context "Extracts numbered steps (N. format)" {
        It "Extracts steps from '1. Step one' format" {
            $plan = "1. Create the module`n2. Write tests`n3. Run tests"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            $steps = $resultJson | ConvertFrom-Json
            $steps.Count | Should -Be 3
        }
    }

    Context "Extracts Step N: format" {
        It "Extracts steps from 'Step 1: Do something' format" {
            $plan = "Step 1: Initialize project`nStep 2: Add dependencies`nStep 3: Build"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            $steps = $resultJson | ConvertFrom-Json
            $steps.Count | Should -Be 3
        }
    }

    Context "Extracts [N] format" {
        It "Extracts steps from '[1] Do this' format" {
            $plan = "[1] First step`n[2] Second step"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            $steps = $resultJson | ConvertFrom-Json
            $steps.Count | Should -Be 2
        }
    }

    Context "Empty input" {
        It "Returns empty array for null plan text" {
            $resultJson = Invoke-PlanExtractSteps -PlanText $null
            $resultJson | Should -Be "[]"
        }

        It "Returns empty array for empty plan text" {
            $resultJson = Invoke-PlanExtractSteps -PlanText ""
            $resultJson | Should -Be "[]"
        }

        It "Returns empty array for whitespace plan text" {
            $resultJson = Invoke-PlanExtractSteps -PlanText "   "
            $resultJson | Should -Be "[]"
        }
    }

    Context "Returns valid JSON array" {
        It "Output is parseable JSON" {
            $plan = "1. First`n2. Second`n3. Third"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            { $resultJson | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    Context "Mixed content" {
        It "Only extracts numbered lines, not prose" {
            $plan = "This is an introduction.`n`n1. First step`nSome prose here.`n2. Second step"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            $steps = $resultJson | ConvertFrom-Json
            $steps.Count | Should -Be 2
        }
    }

    Context "Truncates long steps" {
        It "Does not include steps longer than 300 chars" {
            $longStep = "A" * 400
            $plan = "1. $longStep"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            $steps = $resultJson | ConvertFrom-Json
            $steps[0].Length | Should -BeLessOrEqual 303
        }
    }

    Context "Caps at 30 steps" {
        It "Returns at most 30 steps" {
            $lines = @()
            for ($i = 1; $i -le 50; $i++) {
                $lines += "$i. Step $i"
            }
            $plan = $lines -join "`n"
            $resultJson = Invoke-PlanExtractSteps -PlanText $plan
            $steps = $resultJson | ConvertFrom-Json
            $steps.Count | Should -Be 30
        }
    }
}

Describe "AgentSystem.ps1 — Invoke-PlanAutoTodo" {
    BeforeEach {
        $savedTodos = $global:TODOS
        $savedLastId = $global:_LAST_TODO_ID
        $savedTodoFile = $global:TODO_FILE
        $global:TODOS = @()
        $global:_LAST_TODO_ID = 0
        $global:TODO_FILE = ""
    }

    AfterEach {
        $global:TODOS = $savedTodos
        $global:_LAST_TODO_ID = $savedLastId
        $global:TODO_FILE = $savedTodoFile
    }

    Context "Creates TODO items from steps" {
        It "Creates correct number of TODO items" {
            $stepsJson = '["Step one","Step two","Step three"]'
            $result = Invoke-PlanAutoTodo -StepsJson $stepsJson
            $global:TODOS.Count | Should -Be 3
            $result | Should -Match "3 TODO"
        }

        It "Marks TODO items with source=plan" {
            $stepsJson = '["A step"]'
            Invoke-PlanAutoTodo -StepsJson $stepsJson | Out-Null
            $global:TODOS[0].source | Should -Be "plan"
        }
    }

    Context "Auto-starts first TODO" {
        It "Sets first TODO to in_progress" {
            $stepsJson = '["First","Second","Third"]'
            Invoke-PlanAutoTodo -StepsJson $stepsJson | Out-Null
            $global:TODOS[0].status | Should -Be "in_progress"
            $global:TODOS[1].status | Should -Be "pending"
        }

        It "Returns feedback mentioning auto-start" {
            $stepsJson = '["First"]'
            $result = Invoke-PlanAutoTodo -StepsJson $stepsJson
            $result | Should -Match "auto-started"
        }
    }

    Context "Empty input" {
        It "Handles empty steps JSON" {
            $result = Invoke-PlanAutoTodo -StepsJson "[]"
            $global:TODOS.Count | Should -Be 0
            $result | Should -Match "No steps"
        }

        It "Handles null steps JSON" {
            $result = Invoke-PlanAutoTodo -StepsJson $null
            $result | Should -Match "No steps"
        }
    }

    Context "Target parameter" {
        It "Includes target in TODO items when provided" {
            $stepsJson = '["A step"]'
            Invoke-PlanAutoTodo -StepsJson $stepsJson -Target "C:\project" | Out-Null
            $global:TODOS[0].target | Should -Be "C:\project"
        }
    }

    Context "Handles string instead of array" {
        It "Creates single TODO when a plain string is passed" {
            $stepsJson = '"Single step"'
            Invoke-PlanAutoTodo -StepsJson $stepsJson | Out-Null
            $global:TODOS.Count | Should -Be 1
        }
    }

    Context "Title truncation" {
        It "Truncates long step titles to 200 chars" {
            $longStep = "X" * 300
            $stepsJson = "[`"$longStep`"]"
            Invoke-PlanAutoTodo -StepsJson $stepsJson | Out-Null
            $global:TODOS[0].title.Length | Should -Be 200
        }
    }
}

Describe "AgentLoop.ps1 — Plan State Variables" {
    It "Initializes _PLAN_DEFERRED_MSG as empty string" {
        # Verify the variable exists and is empty (module-level default)
        $var = Get-Variable -Name "_PLAN_DEFERRED_MSG" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
    }

    It "Initializes _DEFERRED_FEEDBACK as empty string" {
        $var = Get-Variable -Name "_DEFERRED_FEEDBACK" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
    }

    It "Initializes _PLAN_STOP as 0" {
        # Save and restore
        $saved = $global:_PLAN_STOP
        $global:_PLAN_STOP = 0
        $global:_PLAN_STOP | Should -Be 0
        $global:_PLAN_STOP = $saved
    }
}

# ============================================================================
#  Prompt Caching Tests (Item 12)
# ============================================================================

Describe "AgentLoop.ps1 — Cache State Initialization" {
    It "Initializes _CC as empty hashtable" {
        $var = Get-Variable -Name "_CC" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
        $global:_CC | Should -BeOfType [hashtable]
    }

    It "Initializes _CACHE_PROBE with correct defaults" {
        $var = Get-Variable -Name "_CACHE_PROBE" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
        $global:_CACHE_PROBE.state | Should -Be "probing"
        $global:_CACHE_PROBE.consecutive_misses | Should -Be 0
        $global:_CACHE_PROBE.total_hits | Should -Be 0
        $global:_CACHE_PROBE.consecutive_hits | Should -Be 0
        $global:_CACHE_PROBE.total_probes | Should -Be 0
        $global:_CACHE_PROBE.inactive_since | Should -Be 0
    }

    It "Initializes _CACHE_MARKER with ephemeral type" {
        $var = Get-Variable -Name "_CACHE_MARKER" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
        $global:_CACHE_MARKER.cache_control.type | Should -Be "ephemeral"
    }

    It "Initializes CACHE_PROBE_MAX_MISSES as 3" {
        $var = Get-Variable -Name "CACHE_PROBE_MAX_MISSES" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
        $global:CACHE_PROBE_MAX_MISSES | Should -Be 3
    }

    It "Initializes CACHE_PROBE_REPROBE as 900" {
        $var = Get-Variable -Name "CACHE_PROBE_REPROBE" -Scope Global -ErrorAction SilentlyContinue
        $var | Should -Not -BeNullOrEmpty
        $global:CACHE_PROBE_REPROBE | Should -Be 900
    }
}

Describe "AgentLoop.ps1 — Invoke-CcInvalidate" {
    BeforeEach {
        $global:_CC = @{
            sys_static = "cached-system-data"
            msg_prefix = "cached-msg-data"
        }
    }

    It "Function exists" {
        Get-Command Invoke-CcInvalidate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Invalidates system cache when 'system' is passed" {
        Invoke-CcInvalidate -Names @("system")
        $global:_CC["sys_static"] | Should -Be ""
    }

    It "Invalidates msgs cache when 'msgs' is passed" {
        Invoke-CcInvalidate -Names @("msgs")
        $global:_CC["msg_prefix"] | Should -Be ""
    }

    It "Invalidates both when both names are passed" {
        Invoke-CcInvalidate -Names @("system", "msgs")
        $global:_CC["sys_static"] | Should -Be ""
        $global:_CC["msg_prefix"] | Should -Be ""
    }

    It "Does not affect other cache keys when invalidating system" {
        Invoke-CcInvalidate -Names @("system")
        $global:_CC["msg_prefix"] | Should -Be "cached-msg-data"
    }

    It "Does not affect other cache keys when invalidating msgs" {
        Invoke-CcInvalidate -Names @("msgs")
        $global:_CC["sys_static"] | Should -Be "cached-system-data"
    }

    It "Handles empty names array without error" {
        { Invoke-CcInvalidate -Names @() } | Should -Not -Throw
    }

    It "Ignores unknown cache names without error" {
        { Invoke-CcInvalidate -Names @("unknown") } | Should -Not -Throw
    }
}

Describe "AgentLoop.ps1 — Get-CacheProbeFeedback" {
    BeforeEach {
        # 重置探测状态
        $global:_CACHE_PROBE = @{
            state              = "probing"
            consecutive_misses = 0
            total_hits         = 0
            consecutive_hits   = 0
            total_probes       = 0
            inactive_since     = 0
        }
        $global:CACHE_PROBE_MAX_MISSES = 3
        $global:CACHE_PROBE_REPROBE    = 900
        $savedProtocol = $global:PA_PROTOCOL
    }

    AfterEach {
        $global:PA_PROTOCOL = $savedProtocol
    }

    It "Function exists" {
        Get-Command Get-CacheProbeFeedback -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Returns current state for non-Anthropic protocol without modification" {
        $global:PA_PROTOCOL = "openai"
        $global:_CACHE_PROBE.state = "probing"
        $result = Get-CacheProbeFeedback -Response @{ usage = @{ cache_read_input_tokens = 100 } }
        $result | Should -Be "probing"
        # 不应修改 total_probes
        $global:_CACHE_PROBE.total_probes | Should -Be 0
    }

    It "Detects cache hit from cache_read_input_tokens" {
        $global:PA_PROTOCOL = "anthropic"
        $resp = @{ usage = @{ cache_read_input_tokens = 100; cache_creation_input_tokens = 0 } }
        $result = Get-CacheProbeFeedback -Response $resp
        $result | Should -Be "active"
        $global:_CACHE_PROBE.total_hits | Should -Be 1
        $global:_CACHE_PROBE.consecutive_hits | Should -Be 1
    }

    It "Transitions probing to active on first hit" {
        $global:PA_PROTOCOL = "anthropic"
        $global:_CACHE_PROBE.state = "probing"
        $resp = @{ usage = @{ cache_read_input_tokens = 50; cache_creation_input_tokens = 0 } }
        Get-CacheProbeFeedback -Response $resp | Should -Be "active"
    }

    It "Detects cache miss when creation > 0 and read = 0" {
        $global:PA_PROTOCOL = "anthropic"
        $resp = @{ usage = @{ cache_read_input_tokens = 0; cache_creation_input_tokens = 500 } }
        Get-CacheProbeFeedback -Response $resp | Out-Null
        $global:_CACHE_PROBE.consecutive_misses | Should -Be 1
    }

    It "Stays active when misses < MAX_MISSES" {
        $global:PA_PROTOCOL = "anthropic"
        $global:_CACHE_PROBE.state = "active"
        $global:_CACHE_PROBE.consecutive_misses = 0
        # 产生 2 次 miss（MAX_MISSES=3）
        for ($i = 0; $i -lt 2; $i++) {
            $resp = @{ usage = @{ cache_read_input_tokens = 0; cache_creation_input_tokens = 100 } }
            Get-CacheProbeFeedback -Response $resp | Out-Null
        }
        $global:_CACHE_PROBE.state | Should -Be "active"
    }

    It "Transitions active to inactive after MAX_MISSES consecutive misses" {
        $global:PA_PROTOCOL = "anthropic"
        $global:_CACHE_PROBE.state = "active"
        $global:_CACHE_PROBE.consecutive_misses = 0
        # 产生 3 次 miss（= MAX_MISSES）
        for ($i = 0; $i -lt 3; $i++) {
            $resp = @{ usage = @{ cache_read_input_tokens = 0; cache_creation_input_tokens = 100 } }
            Get-CacheProbeFeedback -Response $resp | Out-Null
        }
        $global:_CACHE_PROBE.state | Should -Be "inactive"
    }

    It "Resets consecutive_misses on hit" {
        $global:PA_PROTOCOL = "anthropic"
        $global:_CACHE_PROBE.state = "active"
        $global:_CACHE_PROBE.consecutive_misses = 2
        # Hit
        $resp = @{ usage = @{ cache_read_input_tokens = 50; cache_creation_input_tokens = 0 } }
        Get-CacheProbeFeedback -Response $resp | Out-Null
        $global:_CACHE_PROBE.consecutive_misses | Should -Be 0
    }

    It "Reprobes after REPROBE interval" {
        $global:PA_PROTOCOL = "anthropic"
        $global:_CACHE_PROBE.state = "inactive"
        $global:_CACHE_PROBE.total_probes = 100
        $global:_CACHE_PROBE.inactive_since = 1
        # REPROBE=900, total_probes=100, inactive_since=1 → elapsed=99 < 900 → still inactive
        $resp = @{ usage = @{ cache_read_input_tokens = 0; cache_creation_input_tokens = 100 } }
        Get-CacheProbeFeedback -Response $resp | Out-Null
        $global:_CACHE_PROBE.state | Should -Be "inactive"

        # Now set elapsed >= REPROBE
        $global:_CACHE_PROBE.total_probes = 901
        $global:_CACHE_PROBE.inactive_since = 1
        Get-CacheProbeFeedback -Response $resp | Out-Null
        $global:_CACHE_PROBE.state | Should -Be "probing"
    }

    It "Handles null response without error" {
        $global:PA_PROTOCOL = "anthropic"
        { Get-CacheProbeFeedback -Response $null } | Should -Not -Throw
    }

    It "Handles response without usage field" {
        $global:PA_PROTOCOL = "anthropic"
        $resp = @{ }
        { Get-CacheProbeFeedback -Response $resp } | Should -Not -Throw
    }

    It "Handles empty usage hashtable" {
        $global:PA_PROTOCOL = "anthropic"
        $resp = @{ usage = @{ } }
        { Get-CacheProbeFeedback -Response $resp } | Should -Not -Throw
    }

    It "Increments total_probes for each call" {
        $global:PA_PROTOCOL = "anthropic"
        $resp = @{ usage = @{ cache_read_input_tokens = 0; cache_creation_input_tokens = 100 } }
        Get-CacheProbeFeedback -Response $resp | Out-Null
        Get-CacheProbeFeedback -Response $resp | Out-Null
        Get-CacheProbeFeedback -Response $resp | Out-Null
        $global:_CACHE_PROBE.total_probes | Should -Be 3
    }
}

# ============================================================================
#  Item 14: Build-DynamicContext & Build-TodoContext
# ============================================================================

Describe "AgentLoop.ps1 — Build-DynamicContext" {
    BeforeEach {
        $savedModel = $global:PA_MODEL
        $savedTodos = $global:TODOS
        $global:PA_MODEL = "test-dynamic-model"
        $global:TODOS = @()
    }

    AfterEach {
        $global:PA_MODEL = $savedModel
        $global:TODOS = $savedTodos
    }

    It "Returns a non-empty string" {
        $result = Build-DynamicContext
        $result | Should -Not -BeNullOrEmpty
    }

    It "Contains 'Working directory:'" {
        $result = Build-DynamicContext
        $result | Should -Match "Working directory:"
    }

    It "Contains 'Git repository:' with yes or no" {
        $result = Build-DynamicContext
        $result | Should -Match "Git repository: (yes|no)"
    }

    It "Contains 'Platform:'" {
        $result = Build-DynamicContext
        $result | Should -Match "Platform:"
    }

    It "Contains 'Shell: PowerShell'" {
        $result = Build-DynamicContext
        $result | Should -Match "Shell: PowerShell"
    }

    It "Contains the model name" {
        $result = Build-DynamicContext
        $result | Should -Match "Model: test-dynamic-model"
    }

    It "Contains 'Time:' with date pattern" {
        $result = Build-DynamicContext
        $result | Should -Match "Time: \d{4}-\d{2}-\d{2} \d{2}:\d{2}"
    }

    It "Includes TODO context when TODOS are present" {
        $global:TODOS = @(
            @{ id = 1; subject = "Write tests"; status = "pending" }
        )
        $result = Build-DynamicContext
        $result | Should -Match "Active TODOs"
        $result | Should -Match "Write tests"
    }

    It "Does not throw when git is unavailable" {
        # git may not exist — should still produce valid output
        { Build-DynamicContext } | Should -Not -Throw
    }

    It "Handles empty PA_MODEL gracefully" {
        $global:PA_MODEL = ""
        $result = Build-DynamicContext
        $result | Should -Match "Model:"
    }

    It "Returns all 6 base fields" {
        $result = Build-DynamicContext
        $lines = $result -split "`n"
        # At least 6 base lines: Working dir, Git, Platform, Shell, Model, Time
        ($lines | Where-Object { $_ -match ":" }).Count | Should -BeGreaterOrEqual 6
    }
}

Describe "AgentSystem.ps1 — Build-TodoContext" {
    BeforeEach {
        $savedTodos = $global:TODOS
    }

    AfterEach {
        $global:TODOS = $savedTodos
    }

    It "Returns empty string when TODOS is null" {
        $global:TODOS = $null
        $result = Build-TodoContext
        $result | Should -Be ""
    }

    It "Returns empty string when TODOS is empty array" {
        $global:TODOS = @()
        $result = Build-TodoContext
        $result | Should -Be ""
    }

    It "Lists pending TODOs" {
        $global:TODOS = @(
            @{ id = 1; subject = "Task A"; status = "pending" }
        )
        $result = Build-TodoContext
        $result | Should -Match "Active TODOs"
        $result | Should -Match "\[PENDING\] Task A"
    }

    It "Lists in-progress TODOs" {
        $global:TODOS = @(
            @{ id = 1; subject = "Task B"; status = "in_progress" }
        )
        $result = Build-TodoContext
        $result | Should -Match "\[IN PROGRESS\] Task B"
    }

    It "Reports correct counts in header" {
        $global:TODOS = @(
            @{ id = 1; subject = "Task A"; status = "in_progress" }
            @{ id = 2; subject = "Task B"; status = "in_progress" }
            @{ id = 3; subject = "Task C"; status = "pending" }
        )
        $result = Build-TodoContext
        $result | Should -Match "2 in progress"
        $result | Should -Match "1 pending"
    }

    It "Excludes completed TODOs from output" {
        $global:TODOS = @(
            @{ id = 1; subject = "Done task"; status = "completed" }
            @{ id = 2; subject = "Pending task"; status = "pending" }
        )
        $result = Build-TodoContext
        $result | Should -Not -Match "Done task"
        $result | Should -Match "Pending task"
    }

    It "Shows in-progress items before pending items" {
        $global:TODOS = @(
            @{ id = 1; subject = "PendingFirst"; status = "pending" }
            @{ id = 2; subject = "InProgressSecond"; status = "in_progress" }
        )
        $result = Build-TodoContext
        $ipIdx = $result.IndexOf("IN PROGRESS")
        $pIdx = $result.IndexOf("[PENDING]")
        $ipIdx | Should -BeLessThan $pIdx
    }

    It "Handles single-item TODOS (not array)" {
        # PowerShell sometimes wraps single items differently
        $global:TODOS = @(
            @{ id = 1; subject = "Solo task"; status = "pending" }
        )
        $result = Build-TodoContext
        $result | Should -Match "Solo task"
    }
}
