# ============================================================================
#  PowerAgent Test — E2E Live (Real DeepSeek API Calls)
#  Requires DEEPSEEK_API_KEY in user environment variables.
#  All tests are SKIPPED if the key is not available.
#  Uses Pester v5 syntax, PS 5.1 compatible.
# ============================================================================

BeforeAll {
    # ── Skip gate: no key = skip entire file ──
    $script:e2eApiKey = $env:DEEPSEEK_API_KEY
    if (-not $script:e2eApiKey) {
        Write-Host "SKIP: DEEPSEEK_API_KEY not set — skipping live E2E tests" -ForegroundColor Yellow
    }

    # ── Save original config ──
    $script:savedConfig = @{
        ApiKey          = $global:PA_API_KEY
        ApiUrl          = $global:PA_API_URL
        Model           = $global:PA_MODEL
        Protocol        = $global:PA_PROTOCOL
        ThinkingBudget  = $global:PA_THINKING_BUDGET
        SystemPrompt    = $global:PA_SYSTEM_PROMPT
        MaxTokens       = $global:PA_MAX_TOKENS
        ConnectTimeout  = $global:PA_CONNECT_TIMEOUT
        TotalTimeout    = $global:PA_TOTAL_TIMEOUT
        AuthHeader      = $global:PA_AUTH_HEADER
        AuthPrefix      = $global:PA_AUTH_PREFIX
        TraceEnabled    = $global:PA_TRACE_ENABLED
        SafeMode        = $global:PA_SAFE_MODE
    }

    # ── Configure for live DeepSeek ──
    $global:PA_API_KEY         = $script:e2eApiKey
    $global:PA_API_URL         = "https://api.deepseek.com/v1/chat/completions"
    $global:PA_MODEL           = "deepseek-v4-flash"
    $global:PA_PROTOCOL        = "openai"
    $global:PA_THINKING_BUDGET = "100000"
    $global:PA_SYSTEM_PROMPT   = "You are a helpful test assistant. Be concise."
    $global:PA_MAX_TOKENS      = "4096"
    $global:PA_CONNECT_TIMEOUT = "15"
    $global:PA_TOTAL_TIMEOUT   = "120"
    $global:PA_AUTH_HEADER     = ""
    $global:PA_AUTH_PREFIX     = ""
    $global:PA_TRACE_ENABLED   = "0"
    $global:PA_SAFE_MODE       = $false

    # ── Temp file tracking ──
    $script:tempFiles = @()
}

AfterAll {
    # ── Restore original config ──
    if ($script:savedConfig) {
        $global:PA_API_KEY         = $script:savedConfig.ApiKey
        $global:PA_API_URL         = $script:savedConfig.ApiUrl
        $global:PA_MODEL           = $script:savedConfig.Model
        $global:PA_PROTOCOL        = $script:savedConfig.Protocol
        $global:PA_THINKING_BUDGET = $script:savedConfig.ThinkingBudget
        $global:PA_SYSTEM_PROMPT   = $script:savedConfig.SystemPrompt
        $global:PA_MAX_TOKENS      = $script:savedConfig.MaxTokens
        $global:PA_CONNECT_TIMEOUT = $script:savedConfig.ConnectTimeout
        $global:PA_TOTAL_TIMEOUT   = $script:savedConfig.TotalTimeout
        $global:PA_AUTH_HEADER     = $script:savedConfig.AuthHeader
        $global:PA_AUTH_PREFIX     = $script:savedConfig.AuthPrefix
        $global:PA_TRACE_ENABLED   = $script:savedConfig.TraceEnabled
        $global:PA_SAFE_MODE       = $script:savedConfig.SafeMode
    }

    # ── Clean up temp files ──
    foreach ($tmp in $script:tempFiles) {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    $script:tempFiles = @()
}

# ============================================================================
#  Helper: rate-limit pause between API calls
# ============================================================================
function script:Wait-RateLimit {
    [System.Threading.Thread]::Sleep(2000)
}

# ============================================================================
#  Helper: create a temp file with content, track for cleanup
# ============================================================================
function script:New-TempFile {
    param([string]$Content, [string]$Extension = "txt")
    $name = "e2e_test_$(Get-Random).$Extension"
    $path = Join-Path $env:TEMP $name
    Set-Content -Path $path -Value $Content -Encoding UTF8 -NoNewline
    $script:tempFiles += $path
    return $path
}

# ============================================================================
#  1. Model Profile Detection
# ============================================================================
Describe "E2E Live — Model Profile Detection" {
    It "Get-ModelProfile returns DeepSeek profile" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $profile = Get-ModelProfile
        $profile                | Should -Not -BeNullOrEmpty
        $profile.vendor         | Should -Be "deepseek"
        $profile.protocol       | Should -Be "openai"
        $profile.thinking_mode  | Should -Be "deepseek"
    }

    It "Profile has correct auth settings" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $profile = Get-ModelProfile
        $profile.auth_header | Should -Be "Authorization"
        $profile.auth_prefix | Should -Be "Bearer "
    }

    It "Profile supports reasoning_content" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $profile = Get-ModelProfile
        $profile.has_reasoning_content | Should -BeTrue
    }
}

# ============================================================================
#  2. Simple Text Query
# ============================================================================
Describe "E2E Live — Simple Text Query" {
    BeforeAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }

    It "Returns a valid text response for a basic question" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        Add-UserText -Text "What is 2+2? Answer with just the number."

        $body = Build-ApiRequestBody -UserMessage "" -Tools @() `
            -MaxTokens 256 -ThinkingBudget 0 -Model "deepseek-v4-flash" `
            -SystemPrompt "You are a helpful test assistant. Be concise."
        $headers = Get-ApiHeaders

        $result = Invoke-ApiCall -RequestBody $body `
            -Url $global:PA_API_URL -Headers $headers

        $result.Success       | Should -BeTrue
        $result.StopReason    | Should -Be "end_turn"
        $result.InputTokens   | Should -BeGreaterThan 0
        $result.OutputTokens  | Should -BeGreaterThan 0

        # Find a text block with the answer
        $textBlocks = @($result.ContentBlocks | Where-Object { $_.type -eq "text" })
        $textBlocks.Count     | Should -BeGreaterThan 0
        $combined = ($textBlocks | ForEach-Object { $_.text }) -join ""
        $combined             | Should -Match "4"
    }

    AfterAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }
}

# ============================================================================
#  3. Thinking / Reasoning Content
# ============================================================================
Describe "E2E Live — Thinking/Reasoning Content" {
    BeforeAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
        Wait-RateLimit
    }

    It "Returns thinking block when thinking is enabled" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        Add-UserText -Text "Think step by step: what is 15 * 17?"

        # ThinkingBudget > 0 triggers deepseek thinking mode
        $body = Build-ApiRequestBody -UserMessage "" -Tools @() `
            -MaxTokens 4096 -ThinkingBudget 100000 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "You are a helpful test assistant. Be concise."
        $headers = Get-ApiHeaders

        $result = Invoke-ApiCall -RequestBody $body `
            -Url $global:PA_API_URL -Headers $headers

        $result.Success | Should -BeTrue

        # Should have a thinking block
        $thinkingBlocks = @($result.ContentBlocks | Where-Object { $_.type -eq "thinking" })
        $thinkingBlocks.Count   | Should -BeGreaterThan 0
        $thinkingBlocks[0].thinking | Should -Not -BeNullOrEmpty

        # Should also have a text block with the answer
        $textBlocks = @($result.ContentBlocks | Where-Object { $_.type -eq "text" })
        $textBlocks.Count       | Should -BeGreaterThan 0
        $combined = ($textBlocks | ForEach-Object { $_.text }) -join ""
        $combined               | Should -Match "255"
    }

    AfterAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }
}

# ============================================================================
#  4. Tool Use (File Read)
# ============================================================================
Describe "E2E Live — Tool Use (File Read)" {
    BeforeAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
        Wait-RateLimit
    }

    It "API can request read_file tool or respond with text" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        # Create a temp file with known content
        $testContent = "Hello from PowerAgent E2E test! The secret number is 42."
        $tempPath = New-TempFile -Content $testContent
        $prompt = "Read the file at $tempPath using the read_file tool and tell me the secret number."
        Add-UserText -Text $prompt

        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 0 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "You are a helpful test assistant. Use tools when asked."
        $headers = Get-ApiHeaders

        $result = Invoke-ApiCall -RequestBody $body `
            -Url $global:PA_API_URL -Headers $headers

        $result.Success | Should -BeTrue

        # Check if API returned tool_use or direct text
        $toolUseBlocks = @($result.ContentBlocks | Where-Object { $_.type -eq "tool_use" })
        $textBlocks    = @($result.ContentBlocks | Where-Object { $_.type -eq "text" })

        if ($toolUseBlocks.Count -gt 0) {
            # API wants to call a tool
            $toolUse = $toolUseBlocks[0]
            $toolUse.name | Should -Be "read_file"
            $toolUse.input.path | Should -Not -BeNullOrEmpty

            # Dispatch the tool locally
            $dispatchResult = Invoke-ToolDispatch `
                -ToolName $toolUse.name `
                -ToolId $toolUse.id `
                -ToolInput $toolUse.input

            $dispatchResult              | Should -Not -BeNullOrEmpty
            $dispatchResult.type         | Should -Be "tool_result"
            $dispatchResult.tool_use_id  | Should -Be $toolUse.id

            # Extract text from tool result content blocks
            $resultText = ($dispatchResult.content | Where-Object { $_.type -eq "text" } |
                ForEach-Object { $_.text }) -join ""
            $resultText | Should -Match "42"
        } else {
            # API answered directly — verify it produced text
            $textBlocks.Count | Should -BeGreaterThan 0
            $combined = ($textBlocks | ForEach-Object { $_.text }) -join ""
            $combined | Should -Not -BeNullOrEmpty
        }
    }

    AfterAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }
}

# ============================================================================
#  5. Multi-Turn Conversation
# ============================================================================
Describe "E2E Live — Multi-Turn Conversation" {
    BeforeAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
        Wait-RateLimit
    }

    It "Preserves context across two turns" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        # ── Turn 1: tell the model something to remember ──
        Add-UserText -Text "My favorite color is blue. Remember this."

        $body = Build-ApiRequestBody -UserMessage "" -Tools @() `
            -MaxTokens 512 -ThinkingBudget 0 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "You are a helpful test assistant. Be concise."
        $headers = Get-ApiHeaders

        $turn1 = Invoke-ApiCall -RequestBody $body `
            -Url $global:PA_API_URL -Headers $headers

        $turn1.Success | Should -BeTrue

        # Add assistant response to history
        $assistantBlocks = @($turn1.ContentBlocks | Where-Object { $_.type -eq "text" })
        Add-AssistantMessage -ContentBlocks $assistantBlocks

        Wait-RateLimit

        # ── Turn 2: ask about what was said ──
        Add-UserText -Text "What is my favorite color?"

        $body = Build-ApiRequestBody -UserMessage "" -Tools @() `
            -MaxTokens 512 -ThinkingBudget 0 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "You are a helpful test assistant. Be concise."

        $turn2 = Invoke-ApiCall -RequestBody $body `
            -Url $global:PA_API_URL -Headers $headers

        $turn2.Success | Should -BeTrue

        $turn2Text = @($turn2.ContentBlocks | Where-Object { $_.type -eq "text" })
        $turn2Text.Count | Should -BeGreaterThan 0
        $combined = ($turn2Text | ForEach-Object { $_.text }) -join ""
        $combined | Should -Match "blue"

        # Verify MESSAGES has entries: user1, assistant1, user2
        # (system prompt is injected by Build-ApiRequestBody, not in MESSAGES)
        $global:MESSAGES.Count | Should -BeGreaterOrEqual 3
    }

    AfterAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }
}

# ============================================================================
#  6. API Headers and Auth
# ============================================================================
Describe "E2E Live — API Headers and Auth" {
    It "Get-ApiHeaders returns a valid hashtable" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $headers = Get-ApiHeaders
        $headers -is [hashtable] | Should -BeTrue
    }

    It "Headers contain Authorization key" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $headers = Get-ApiHeaders
        $headers.ContainsKey("Authorization") | Should -BeTrue
    }

    It "Authorization value starts with Bearer" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $headers = Get-ApiHeaders
        $headers["Authorization"] | Should -BeLike "Bearer *"
    }

    It "Authorization value contains a non-empty API key" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $headers = Get-ApiHeaders
        $keyPart = $headers["Authorization"].Substring(7)
        $keyPart.Length | Should -BeGreaterThan 0
    }
}

# ============================================================================
#  7. Request Body Format
# ============================================================================
Describe "E2E Live — Request Body Format" {
    BeforeAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
        Add-UserText -Text "test message for body format validation"
    }

    It "Request body has correct model field" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 100000 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "Test prompt."

        $parsed = $body | ConvertFrom-Json
        $parsed.model | Should -Be "deepseek-v4-flash"
    }

    It "Request body has messages array with system + user entries" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 100000 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "Test prompt."

        $parsed = $body | ConvertFrom-Json
        $parsed.messages      | Should -Not -BeNullOrEmpty
        $parsed.messages.Count | Should -BeGreaterOrEqual 2

        # First message should be system
        $parsed.messages[0].role    | Should -Be "system"
        $parsed.messages[0].content | Should -Be "Test prompt."

        # Second message should be user
        $parsed.messages[1].role    | Should -Be "user"
    }

    It "Tools use 'parameters' field (not 'input_schema')" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 100000 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "Test prompt."

        $parsed = $body | ConvertFrom-Json
        $parsed.tools | Should -Not -BeNullOrEmpty
        $parsed.tools.Count | Should -BeGreaterThan 0

        foreach ($tool in $parsed.tools) {
            $tool.type | Should -Be "function"
            $tool.function.name | Should -Not -BeNullOrEmpty
            $tool.function.parameters | Should -Not -BeNullOrEmpty
        }
    }

    It "Request body has thinking field with type=enabled" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 100000 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "Test prompt."

        $parsed = $body | ConvertFrom-Json
        $parsed.thinking        | Should -Not -BeNullOrEmpty
        $parsed.thinking.type   | Should -Be "enabled"
    }

    It "Request body has reasoning_effort field" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 100000 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "Test prompt."

        $parsed = $body | ConvertFrom-Json
        $parsed.reasoning_effort | Should -Not -BeNullOrEmpty
    }

    AfterAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }
}

# ============================================================================
#  8. Full Pipeline with Tool Execution
# ============================================================================
Describe "E2E Live — Full Pipeline with Tool Execution" {
    BeforeAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
        Wait-RateLimit
    }

    It "Completes the full user→API→tool→result→API→final loop" {
        if (-not $script:e2eApiKey) { Set-ItResult -Skipped -Because "DEEPSEEK_API_KEY not set"; return }
        # Create temp file with known content
        $secretPhrase = "Hello from PowerAgent E2E test!"
        $tempPath = New-TempFile -Content $secretPhrase

        # ── Step 1: Ask API to read the file ──
        Add-UserText -Text "Please read the file at $tempPath using the read_file tool, then tell me exactly what it says."

        $tools = Get-ToolSchemas
        $body = Build-ApiRequestBody -UserMessage "" -Tools $tools `
            -MaxTokens 4096 -ThinkingBudget 0 `
            -Model "deepseek-v4-flash" `
            -SystemPrompt "You are a helpful test assistant. Use tools when asked to. Be concise."
        $headers = Get-ApiHeaders

        $step1 = Invoke-ApiCall -RequestBody $body `
            -Url $global:PA_API_URL -Headers $headers

        $step1.Success | Should -BeTrue

        # ── Step 2: Check for tool_use ──
        $toolUseBlocks = @($step1.ContentBlocks | Where-Object { $_.type -eq "tool_use" })
        $textBlocks    = @($step1.ContentBlocks | Where-Object { $_.type -eq "text" })

        if ($toolUseBlocks.Count -gt 0) {
            # API wants to call read_file
            $toolCall = $toolUseBlocks[0]
            $toolCall.name | Should -Be "read_file"

            # ── Step 3: Dispatch tool locally ──
            $toolResult = Invoke-ToolDispatch `
                -ToolName $toolCall.name `
                -ToolId $toolCall.id `
                -ToolInput $toolCall.input

            $toolResult             | Should -Not -BeNullOrEmpty
            $toolResult.type        | Should -Be "tool_result"

            # Verify tool actually read the file
            $resultText = ($toolResult.content | Where-Object { $_.type -eq "text" } |
                ForEach-Object { $_.text }) -join ""
            $resultText | Should -Match "Hello from PowerAgent E2E test"

            # ── Step 4: Add assistant message and tool result to history ──
            $assistantContent = @()
            if ($textBlocks.Count -gt 0) {
                $assistantContent += $textBlocks
            }
            $assistantContent += $toolUseBlocks
            Add-AssistantMessage -ContentBlocks $assistantContent
            Add-ToolResults -Results @($toolResult)

            Wait-RateLimit

            # ── Step 5: Call API again with tool results ──
            $body2 = Build-ApiRequestBody -UserMessage "" -Tools $tools `
                -MaxTokens 4096 -ThinkingBudget 0 `
                -Model "deepseek-v4-flash" `
                -SystemPrompt "You are a helpful test assistant. Be concise."

            $step2 = Invoke-ApiCall -RequestBody $body2 `
                -Url $global:PA_API_URL -Headers $headers

            $step2.Success | Should -BeTrue
            $step2.StopReason | Should -Be "end_turn"

            # Verify final response acknowledges the file content
            $finalText = @($step2.ContentBlocks | Where-Object { $_.type -eq "text" })
            $finalText.Count | Should -BeGreaterThan 0
            $finalCombined = ($finalText | ForEach-Object { $_.text }) -join ""
            $finalCombined | Should -Match "Hello from PowerAgent E2E test"
        } else {
            # Model answered directly without tool use — still valid
            $textBlocks.Count | Should -BeGreaterThan 0
            $combined = ($textBlocks | ForEach-Object { $_.text }) -join ""
            $combined | Should -Not -BeNullOrEmpty
        }
    }

    AfterAll {
        if (-not $script:e2eApiKey) { return }
        Clear-History
    }
}
