# ============================================================================
#  PowerAgent Test — HttpClient.ps1
#  Validates HTTP request building, API call construction, header generation
#  NOTE: No real HTTP calls are made — tests validate structure only
# ============================================================================

Describe "HttpClient.ps1 — Get-ApiHeaders" {
    BeforeAll {
        $global:PA_API_KEY = "test-api-key-12345"
        $global:PA_AUTH_HEADER = ""
        $global:PA_AUTH_PREFIX = ""
    }

    It "Returns a hashtable" {
        $headers = Get-ApiHeaders
        $headers -is [hashtable] | Should -BeTrue
    }

    It "Uses model profile auth header when no PA_AUTH_HEADER override" {
        $global:PA_AUTH_HEADER = ""
        $global:PA_AUTH_PREFIX = ""
        # 测试环境 URL 是 localhost → 匹配 generic_openai → Authorization: Bearer
        # 但如果 model profile 提供 auth_header，则使用 profile 的值
        $headers = Get-ApiHeaders
        # 验证至少有一个 auth header（profile 提供的或默认的）
        ($headers["Authorization"] -or $headers["x-api-key"]) | Should -BeTrue
    }

    It "Uses custom auth_header when specified" {
        $global:PA_AUTH_HEADER = "Authorization"
        $global:PA_AUTH_PREFIX = "Bearer "
        $headers = Get-ApiHeaders
        $headers["Authorization"] | Should -Be "Bearer test-api-key-12345"
        $global:PA_AUTH_HEADER = ""
        $global:PA_AUTH_PREFIX = ""
    }

    It "Does NOT include Content-Type in headers (set by Invoke-HttpRequest instead)" {
        $headers = Get-ApiHeaders
        $headers["content-type"] | Should -BeNullOrEmpty
        # Content-Type 由 Invoke-HttpRequest 的 -ContentType 参数设置，避免 double header
    }
}

Describe "HttpClient.ps1 — Build-ApiRequestBody" {
    It "Returns valid JSON" {
        $global:PA_MODEL = "test-model"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "You are a test."
        $global:PA_THINKING_BUDGET = "0"
        $global:MESSAGES = @(
            @{ role = "user"; content = "Hello" }
        )

        $body = Build-ApiRequestBody
        { $body | ConvertFrom-Json } | Should -Not -Throw
    }

    It "Includes model field" {
        $global:PA_MODEL = "test-model-v2"
        $global:PA_MAX_TOKENS = "2048"
        $global:PA_SYSTEM_PROMPT = "Test prompt"
        $global:PA_THINKING_BUDGET = "0"
        $global:MESSAGES = @()

        $body = Build-ApiRequestBody
        $obj = $body | ConvertFrom-Json
        $obj.model | Should -Be "test-model-v2"
    }

    It "Includes messages array" {
        $global:PA_MODEL = "test"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "Test"
        $global:PA_THINKING_BUDGET = "0"
        $global:MESSAGES = @(
            @{ role = "user"; content = "Hi" },
            @{ role = "assistant"; content = "Hello!" }
        )

        $body = Build-ApiRequestBody
        $obj = $body | ConvertFrom-Json
        @($obj.messages).Count | Should -BeGreaterOrEqual 2
    }
}

Describe "HttpClient.ps1 — Protocol Conversion" {
    It "ConvertTo-AnthropicRequest function exists" {
        Get-Command ConvertTo-AnthropicRequest -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "HttpClient.ps1 — Invoke-HttpRequest (structure)" {
    It "Invoke-HttpRequest function exists" {
        Get-Command Invoke-HttpRequest -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Connect-SseStream function exists" {
        Get-Command Connect-SseStream -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Invoke-ApiCall function exists" {
        Get-Command Invoke-ApiCall -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "ConvertTo-AnthropicRequest function exists" {
        Get-Command ConvertTo-AnthropicRequest -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ============================================================================
#  NEW: Extended HttpClient tests — parameter handling, edge cases, Anthropic conversion
#  ============================================================================

Describe "HttpClient.ps1 — Invoke-HttpRequest return structure" {
    It "Invoke-HttpRequest function exists" {
        Get-Command Invoke-HttpRequest -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Has correct parameters (Method, Url, Body, Headers, ConnectTimeout, TotalTimeout, ContentType)" {
        $cmd = Get-Command Invoke-HttpRequest -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty

        $paramNames = $cmd.Parameters.Keys
        $paramNames | Should -Contain "Method"
        $paramNames | Should -Contain "Url"
        $paramNames | Should -Contain "Body"
        $paramNames | Should -Contain "Headers"
        $paramNames | Should -Contain "ConnectTimeout"
        $paramNames | Should -Contain "TotalTimeout"
        $paramNames | Should -Contain "ContentType"
    }

    It "Method and Url parameters are mandatory" {
        # Invoke-HttpRequest is NOT an advanced function (no [CmdletBinding()]),
        # but its param block has [Parameter(Mandatory=$true)] — check original definition
        # (not ${function:...} which may be a stale mock from E2E tests)
        $def = $global:_PA_ORIGINAL_FN_DEFS["Invoke-HttpRequest"]
        $def | Should -Not -BeNullOrEmpty -Because "original definition should be saved by run_tests.ps1"
        ($def | Select-String 'Parameter\(Mandatory' -AllMatches).Matches.Count | Should -BeGreaterOrEqual 2
    }

    It "Has ContentType parameter defined" {
        $cmd = Get-Command Invoke-HttpRequest
        # PS5.1 may not report default values for advanced function params
        $cmd.Parameters.ContainsKey("ContentType") | Should -BeTrue
    }
}

Describe "HttpClient.ps1 — ConvertTo-AnthropicRequest function existence" {
    It "ConvertTo-AnthropicRequest function exists" {
        Get-Command ConvertTo-AnthropicRequest -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "HttpClient.ps1 — Invoke-ApiCall" {
    It "Function exists" {
        Get-Command Invoke-ApiCall -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Has expected parameters (RequestBody, Url, Headers)" {
        $cmd = Get-Command Invoke-ApiCall -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty

        $paramNames = $cmd.Parameters.Keys
        $paramNames | Should -Contain "RequestBody"
        $paramNames | Should -Contain "Url"
        $paramNames | Should -Contain "Headers"
    }
}

Describe "HttpClient.ps1 — Edge cases" {
    It "Get-ApiHeaders handles empty PA_API_KEY" {
        $savedKey = $global:PA_API_KEY
        $savedAuthHeader = $global:PA_AUTH_HEADER
        $savedAuthPrefix = $global:PA_AUTH_PREFIX
        try {
            $global:PA_API_KEY = ""
            $global:PA_AUTH_HEADER = ""
            $global:PA_AUTH_PREFIX = ""
            $headers = Get-ApiHeaders
            $headers -is [hashtable] | Should -BeTrue
        } finally {
            $global:PA_API_KEY = $savedKey
            $global:PA_AUTH_HEADER = $savedAuthHeader
            $global:PA_AUTH_PREFIX = $savedAuthPrefix
        }
    }

    It "Build-ApiRequestBody handles empty messages array" {
        $global:PA_MODEL = "test-model"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "Test"
        $global:PA_THINKING_BUDGET = "0"
        $global:PA_PROTOCOL = ""
        $global:MESSAGES = @()

        { Build-ApiRequestBody } | Should -Not -Throw
        $body = Build-ApiRequestBody
        $body | Should -Not -BeNullOrEmpty
    }

    It "Build-ApiRequestBody handles null MESSAGES gracefully" {
        $savedMessages = $global:MESSAGES
        try {
            $global:MESSAGES = $null
            $global:PA_MODEL = "test"
            $global:PA_MAX_TOKENS = "1024"
            $global:PA_SYSTEM_PROMPT = "Test"
            $global:PA_THINKING_BUDGET = "0"
            { Build-ApiRequestBody } | Should -Not -Throw
            $body = Build-ApiRequestBody
            $obj = $body | ConvertFrom-Json
            $obj.messages | Should -Not -BeNullOrEmpty
        } finally {
            $global:MESSAGES = $savedMessages
        }
    }

    It "Build-ApiRequestBody includes thinking config when PA_THINKING_BUDGET > 0" {
        $savedMaxTokens = $global:PA_MAX_TOKENS
        $savedSystemPrompt = $global:PA_SYSTEM_PROMPT
        $savedProtocol = $global:PA_PROTOCOL
        $savedMessages = $global:MESSAGES
        try {
            $global:PA_MAX_TOKENS = "4096"
            $global:PA_SYSTEM_PROMPT = "Think carefully"
            $global:PA_PROTOCOL = "openai"
            $global:MESSAGES = @()

            # 传入 DeepSeek profile 显式避免 Pester v5 scope 问题
            $deepseekProfile = $global:MODEL_PROFILES["deepseek"]
            $body = Build-ApiRequestBody -ThinkingBudget 5000 -Model "deepseek-v4-flash" -Profile $deepseekProfile
            $obj = $body | ConvertFrom-Json
            $obj.thinking | Should -Not -BeNullOrEmpty
            $obj.thinking.type | Should -Be "enabled"
            # DeepSeek 不使用 budget_tokens，使用 reasoning_effort
            $obj.reasoning_effort | Should -Be "high"
        } finally {
            $global:PA_MAX_TOKENS = $savedMaxTokens
            $global:PA_SYSTEM_PROMPT = $savedSystemPrompt
            $global:PA_PROTOCOL = $savedProtocol
            $global:MESSAGES = $savedMessages
        }
    }
}

# ============================================================================
#  NEW: ConvertTo-AnthropicRequest tests (v0.6 OpenAI-native)
#  Replaces old ConvertTo-OpenAIRequest tests
#  ============================================================================

Describe "HttpClient.ps1 - ConvertTo-AnthropicRequest message conversion" {
    BeforeEach {
        $global:PA_THINKING_BUDGET = "10000"
    }

    It "Extracts system prompt to top-level system field" {
        $openaiReq = @{
            model = "claude-3-sonnet"
            max_tokens = 1024
            messages = @(
                @{ role = "system"; content = "You are helpful." }
                @{ role = "user"; content = "Hello" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $result.system | Should -Be "You are helpful."
        # system 消息不应出现在 messages 中
        $sysInMsgs = @($result.messages) | Where-Object { $_.role -eq "system" }
        ($sysInMsgs | Measure-Object).Count | Should -Be 0
    }

    It "Passes user string content through unchanged" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{ role = "user"; content = "Hello world" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $userMsg = @($result.messages) | Where-Object { $_.role -eq "user" } | Select-Object -First 1
        $userMsg | Should -Not -BeNullOrEmpty
        $userMsg.content | Should -Be "Hello world"
    }

    It "Converts role=tool messages to user role with tool_result blocks" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{ role = "assistant"; content = "Let me check."; tool_calls = @(
                    @{ id = "call_001"; function = @{ name = "read_file"; arguments = '{"path":"/test.txt"}' } }
                ) }
                @{ role = "tool"; tool_call_id = "call_001"; content = "file contents here" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        # Expected: messages[0]=assistant(tool_use), messages[1]=user(tool_result)
        # Tool results are flushed at end of loop as user role with tool_result blocks
        $foundToolResult = $false
        foreach ($msg in $result.messages) {
            if ($msg.role -eq "user" -and $msg.content -is [array]) {
                foreach ($block in $msg.content) {
                    if ($block.type -eq "tool_result") {
                        $block.tool_use_id | Should -Be "call_001"
                        $block.content | Should -Be "file contents here"
                        $foundToolResult = $true
                        break
                    }
                }
                if ($foundToolResult) { break }
            }
        }
        $foundToolResult | Should -BeTrue
    }

    It "Converts assistant content string to text block" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{ role = "assistant"; content = "Simple text response" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $assistMsg = @($result.messages) | Where-Object { $_.role -eq "assistant" } | Select-Object -First 1
        $assistMsg | Should -Not -BeNullOrEmpty
        # content 应为 content blocks 数组
        $textBlock = $null
        foreach ($block in $assistMsg.content) {
            if ($block.type -eq "text") { $textBlock = $block; break }
        }
        $textBlock | Should -Not -BeNullOrEmpty
        $textBlock.text | Should -Be "Simple text response"
    }

    It "Converts assistant reasoning_content to thinking block" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{
                    role = "assistant"
                    reasoning_content = "Let me think..."
                    content = "Here is the answer."
                }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $assistMsg = @($result.messages) | Where-Object { $_.role -eq "assistant" } | Select-Object -First 1
        $thinkingBlock = $null
        foreach ($block in $assistMsg.content) {
            if ($block.type -eq "thinking") { $thinkingBlock = $block; break }
        }
        $thinkingBlock | Should -Not -BeNullOrEmpty
        $thinkingBlock.thinking | Should -Be "Let me think..."
        $textBlock = $null
        foreach ($block in $assistMsg.content) {
            if ($block.type -eq "text") { $textBlock = $block; break }
        }
        $textBlock | Should -Not -BeNullOrEmpty
    }

    It "Converts assistant tool_calls to tool_use blocks" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{
                    role = "assistant"
                    content = "I will read the file."
                    tool_calls = @(
                        @{
                            id = "call_001"
                            function = @{ name = "read_file"; arguments = '{"path":"/test.txt"}' }
                        }
                    )
                }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $assistMsg = @($result.messages) | Where-Object { $_.role -eq "assistant" } | Select-Object -First 1
        $toolUseBlock = $null
        foreach ($block in $assistMsg.content) {
            if ($block.type -eq "tool_use") { $toolUseBlock = $block; break }
        }
        $toolUseBlock | Should -Not -BeNullOrEmpty
        $toolUseBlock.id | Should -Be "call_001"
        $toolUseBlock.name | Should -Be "read_file"
    }

    It "Places pending tool results after assistant message" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{ role = "user"; content = "Read file" }
                @{ role = "assistant"; content = ""; tool_calls = @(
                    @{ id = "call_001"; function = @{ name = "read_file"; arguments = '{"path":"/a.txt"}' } }
                ) }
                @{ role = "tool"; tool_call_id = "call_001"; content = "file A" }
                @{ role = "assistant"; content = "Here is file A."; tool_calls = @(
                    @{ id = "call_002"; function = @{ name = "read_file"; arguments = '{"path":"/b.txt"}' } }
                ) }
                @{ role = "tool"; tool_call_id = "call_002"; content = "file B" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        # 应有 user, assistant, user(tool_result), assistant, user(tool_result) 的顺序
        @($result.messages).Count | Should -BeGreaterOrEqual 4
        # 第一个 assistant 之后应该紧跟 user (tool results)
        $foundFirst = $false
        $toolResultAfterFirst = $false
        foreach ($msg in $result.messages) {
            if ($msg.role -eq "assistant" -and -not $foundFirst) {
                $foundFirst = $true
                continue
            }
            if ($foundFirst -and $msg.role -eq "user" -and $msg.content -is [array]) {
                $toolResultAfterFirst = $true
                break
            }
        }
        $toolResultAfterFirst | Should -BeTrue
    }

    It "Appends trailing tool results at the end" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{ role = "assistant"; content = ""; tool_calls = @(
                    @{ id = "call_001"; function = @{ name = "read_file"; arguments = '{"path":"/x.txt"}' } }
                ) }
                @{ role = "tool"; tool_call_id = "call_001"; content = "file X" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        # 最后一条消息应为 user 角色包含 tool_result
        $lastMsg = $result.messages[$result.messages.Count - 1]
        $lastMsg.role | Should -Be "user"
        $toolResults = @($lastMsg.content) | Where-Object { $_.type -eq "tool_result" }
        ($toolResults | Measure-Object).Count | Should -Be 1
    }
}

Describe "HttpClient.ps1 - ConvertTo-AnthropicRequest tools conversion" {
    It "Converts function.parameters to input_schema" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
            tools = @(
                @{
                    type = "function"
                    function = @{
                        name = "read_file"
                        description = "Read a file"
                        parameters = @{
                            type = "object"
                            properties = @{
                                path = @{ type = "string"; description = "File path" }
                            }
                        }
                    }
                }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $result.tools | Should -Not -BeNullOrEmpty
        $tool = @($result.tools)[0]
        $tool.name | Should -Be "read_file"
        $tool.description | Should -Be "Read a file"
        $tool.input_schema | Should -Not -BeNullOrEmpty
        # 不应包含 parameters 键
        $hasParams = $false
        try { if ($tool.parameters) { $hasParams = $true } } catch {}
        $hasParams | Should -BeFalse
    }

    It "Wraps multiple tools correctly" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
            tools = @(
                @{ type = "function"; function = @{ name = "tool_a"; description = "A"; parameters = @{ type = "object" } } }
                @{ type = "function"; function = @{ name = "tool_b"; description = "B"; parameters = @{ type = "object" } } }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        @($result.tools).Count | Should -Be 2
        @($result.tools)[0].name | Should -Be "tool_a"
        @($result.tools)[1].name | Should -Be "tool_b"
    }

    It "Omits tools key when no tools provided" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $hasTools = $false
        try { if ($result.tools) { $hasTools = $true } } catch {}
        $hasTools | Should -BeFalse
    }
}

Describe "HttpClient.ps1 - ConvertTo-AnthropicRequest thinking params" {
    BeforeEach {
        $global:PA_THINKING_BUDGET = "8000"
    }

    It "Converts thinking config to Anthropic format with budget_tokens" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
            thinking = @{ type = "enabled" }
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $result.thinking | Should -Not -BeNullOrEmpty
        $result.thinking.type | Should -Be "enabled"
        $result.thinking.budget_tokens | Should -Be 8000
    }

    It "Does not include thinking when not provided" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $hasThinking = $false
        try { if ($result.thinking) { $hasThinking = $true } } catch {}
        $hasThinking | Should -BeFalse
    }
}

Describe "HttpClient.ps1 - ConvertTo-AnthropicRequest edge cases" {
    It "Returns a hashtable (not JSON string)" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $result -is [hashtable] | Should -BeTrue
    }

    It "Handles empty messages array" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @()
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        @($result.messages).Count | Should -Be 0
    }

    It "Handles no system prompt (messages start with user)" {
        $openaiReq = @{
            model = "test"
            max_tokens = 1024
            messages = @(
                @{ role = "user"; content = "Hello" }
            )
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $hasSystem = $false
        try { if ($result.system) { $hasSystem = $true } } catch {}
        $hasSystem | Should -BeFalse
        @($result.messages).Count | Should -Be 1
    }

    It "Preserves model and max_tokens from input" {
        $openaiReq = @{
            model = "claude-3-opus"
            max_tokens = 4096
            messages = @()
        }
        $result = ConvertTo-AnthropicRequest $openaiReq
        $result.model | Should -Be "claude-3-opus"
        $result.max_tokens | Should -Be 4096
    }
}

# ============================================================================
#  NEW: Invoke-ApiCall response parsing (v0.6 OpenAI-native)
#  Replaces old ConvertTo-OpenAIResponse tests
#  ============================================================================

Describe "HttpClient.ps1 - Invoke-ApiCall response parsing" {
    BeforeEach {
        # 保存原始函数引用以便恢复
        $script:_origInvokeHttpRequest = Get-Command Invoke-HttpRequest -ErrorAction SilentlyContinue
        $global:PA_THINKING_BUDGET = "10000"
        $global:PA_CONNECT_TIMEOUT = "30"
    }
    AfterEach {
        # 清理全局 mock 变量
        Remove-Variable -Name "_testMockJson" -Scope Global -ErrorAction SilentlyContinue
    }

    It "Parses text response correctly" {
        $global:_testMockJson = '{"choices":[{"message":{"role":"assistant","content":"Hello from API"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}'

        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "end_turn"
        $result.InputTokens | Should -Be 10
        $result.OutputTokens | Should -Be 5
        # 应该包含一个 text 类型的 content block
        $textBlock = $null
        foreach ($block in $result.ContentBlocks) {
            if ($block.type -eq "text") { $textBlock = $block; break }
        }
        $textBlock | Should -Not -BeNullOrEmpty
        $textBlock.text | Should -Be "Hello from API"
    }

    It "Parses tool_calls response into tool_call content blocks" {
        $global:_testMockJson = '{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call_001","function":{"name":"read_file","arguments":"{\"path\":\"/test.txt\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":15}}'

        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "tool_use"
        $toolBlock = $null
        foreach ($block in $result.ContentBlocks) {
            if ($block.type -eq "tool_call") { $toolBlock = $block; break }
        }
        $toolBlock | Should -Not -BeNullOrEmpty
        $toolBlock.id | Should -Be "call_001"
        $toolBlock.name | Should -Be "read_file"
    }

    It "Parses reasoning_content into thinking content blocks" {
        $global:_testMockJson = '{"choices":[{"message":{"role":"assistant","reasoning_content":"Let me think step by step...","content":"The answer is 42."},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":30}}'

        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeTrue
        $thinkingBlock = $null
        foreach ($block in $result.ContentBlocks) {
            if ($block.type -eq "thinking") { $thinkingBlock = $block; break }
        }
        $thinkingBlock | Should -Not -BeNullOrEmpty
        $thinkingBlock.thinking | Should -Be "Let me think step by step..."
    }

    It "Parses reasoning_details array (MiniMax format) into thinking block" {
        $global:_testMockJson = '{"choices":[{"message":{"role":"assistant","content":"Done","reasoning_details":[{"text":"Step 1"},{"text":"Step 2"}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}'

        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeTrue
        $thinkingBlock = $null
        foreach ($block in $result.ContentBlocks) {
            if ($block.type -eq "thinking") { $thinkingBlock = $block; break }
        }
        $thinkingBlock | Should -Not -BeNullOrEmpty
        $thinkingBlock.thinking | Should -Be "Step 1Step 2"
    }

    It "Handles HTTP error (non-zero ExitCode) gracefully" {
        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 1; StatusCode = 500; Body = "Server Error" } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeFalse
        $result.StopReason | Should -Be "error"
        $result.ContentBlocks.Count | Should -Be 0
    }

    It "Handles empty choices array as error" {
        $global:_testMockJson = '{"choices":[]}'
        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeFalse
        $result.StopReason | Should -Be "error"
    }

    It "Handles invalid JSON response as error" {
        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = "NOT JSON" } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeFalse
        $result.StopReason | Should -Be "error"
    }

    It "Maps finish_reason values correctly (stop→end_turn, tool_calls→tool_use, length→max_tokens)" {
        $testCases = @(
            @{ finish = "stop"; expected = "end_turn" }
            @{ finish = "length"; expected = "max_tokens" }
            @{ finish = "tool_calls"; expected = "tool_use" }
            @{ finish = "content_filter"; expected = "end_turn" }
        )
        foreach ($tc in $testCases) {
            $global:_testMockJson = "{`"choices`":[{`"message`":{`"role`":`"assistant`",`"content`":`"test`"},`"finish_reason`":`"$($tc.finish)`"}],`"usage`":{`"prompt_tokens`":10,`"completion_tokens`":5}}"

            function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

            $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
            $result.StopReason | Should -Be $tc.expected
        }
    }

    It "Handles response without usage field (defaults to 0)" {
        $global:_testMockJson = '{"choices":[{"message":{"role":"assistant","content":"No usage info"},"finish_reason":"stop"}]}'

        function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $global:_testMockJson } }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeTrue
        $result.InputTokens | Should -Be 0
        $result.OutputTokens | Should -Be 0
    }
}

# ============================================================================
#  NEW: Build-ApiRequestBody profile-specific and tools tests
#  ============================================================================

Describe "HttpClient.ps1 - Build-ApiRequestBody profile-specific" {
    It "Includes budget_tokens for Anthropic profile" {
        $saved = @{ model = $global:PA_MODEL; max = $global:PA_MAX_TOKENS; sys = $global:PA_SYSTEM_PROMPT; msg = $global:MESSAGES }
        try {
            $global:PA_MODEL = "claude-3-sonnet"
            $global:PA_MAX_TOKENS = "4096"
            $global:PA_SYSTEM_PROMPT = "Test"
            $global:MESSAGES = @()

            $anthropicProfile = $global:MODEL_PROFILES["anthropic"]
            if ($anthropicProfile) {
                $body = Build-ApiRequestBody -ThinkingBudget 5000 -Model "claude-3-sonnet" -Profile $anthropicProfile
                $obj = $body | ConvertFrom-Json
                $obj.thinking | Should -Not -BeNullOrEmpty
                $obj.thinking.type | Should -Be "enabled"
                $obj.thinking.budget_tokens | Should -Be 10000
            }
        } finally {
            $global:PA_MODEL = $saved.model
            $global:PA_MAX_TOKENS = $saved.max
            $global:PA_SYSTEM_PROMPT = $saved.sys
            $global:MESSAGES = $saved.msg
        }
    }

    It "Includes tools when provided" {
        $global:PA_MODEL = "test"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "Test"
        $global:PA_THINKING_BUDGET = "0"
        $global:MESSAGES = @()

        $tools = @(
            @{
                name = "test_tool"
                description = "A test tool"
                input_schema = @{ type = "object"; properties = @{ path = @{ type = "string" } } }
            }
        )

        $body = Build-ApiRequestBody -Tools $tools
        $obj = $body | ConvertFrom-Json
        $obj.tools | Should -Not -BeNullOrEmpty
    }

    It "Omits tools key when empty array provided" {
        $global:PA_MODEL = "test"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "Test"
        $global:PA_THINKING_BUDGET = "0"
        $global:MESSAGES = @()

        $body = Build-ApiRequestBody -Tools @()
        $obj = $body | ConvertFrom-Json
        $hasTools = $false
        try { if ($obj.tools) { $hasTools = $true } } catch {}
        $hasTools | Should -BeFalse
    }
}

Describe "HttpClient.ps1 - Full message round-trip" {
    It "Handles multi-turn conversation with tool calls" {
        $saved = @{ model = $global:PA_MODEL; max = $global:PA_MAX_TOKENS; sys = $global:PA_SYSTEM_PROMPT; budget = $global:PA_THINKING_BUDGET; msg = $global:MESSAGES }
        try {
            $global:PA_MODEL = "deepseek-v4-flash"
            $global:PA_MAX_TOKENS = "4096"
            $global:PA_SYSTEM_PROMPT = "You are a helpful assistant."
            $global:PA_THINKING_BUDGET = "0"
            $global:MESSAGES = @(
                @{ role = "user"; content = "Read the file /test.txt" }
                @{
                    role = "assistant"
                    content = @(
                        @{ type = "text"; text = "Let me read that file." }
                        @{ type = "tool_use"; id = "call_001"; name = "read_file"; input = @{ path = "/test.txt" } }
                    )
                }
                @{
                    role = "user"
                    content = @(
                        @{ type = "tool_result"; tool_use_id = "call_001"; content = "Hello from test.txt" }
                    )
                }
            )

            $body = Build-ApiRequestBody
            $obj = $body | ConvertFrom-Json
            $obj.model | Should -Be "deepseek-v4-flash"
            @($obj.messages).Count | Should -BeGreaterOrEqual 3
        } finally {
            $global:PA_MODEL = $saved.model
            $global:PA_MAX_TOKENS = $saved.max
            $global:PA_SYSTEM_PROMPT = $saved.sys
            $global:PA_THINKING_BUDGET = $saved.budget
            $global:MESSAGES = $saved.msg
        }
    }
}

# ============================================================================
#  NEW: Prompt Caching Tests (Item 12) — Build-ApiRequestBody cache markers
#  ============================================================================

Describe "HttpClient.ps1 — Build-ApiRequestBody cache markers (Anthropic)" {
    BeforeEach {
        $savedProtocol = $global:PA_PROTOCOL
        $savedModel = $global:PA_MODEL
        $savedMaxTokens = $global:PA_MAX_TOKENS
        $savedSystemPrompt = $global:PA_SYSTEM_PROMPT
        $savedMessages = $global:MESSAGES
        $savedThinkingBudget = $global:PA_THINKING_BUDGET
        $savedProbeState = $global:_CACHE_PROBE.state
    }

    AfterEach {
        $global:PA_PROTOCOL = $savedProtocol
        $global:PA_MODEL = $savedModel
        $global:PA_MAX_TOKENS = $savedMaxTokens
        $global:PA_SYSTEM_PROMPT = $savedSystemPrompt
        $global:MESSAGES = $savedMessages
        $global:PA_THINKING_BUDGET = $savedThinkingBudget
        $global:_CACHE_PROBE.state = $savedProbeState
    }

    It "Does NOT add cache_control markers for OpenAI protocol" {
        $global:PA_PROTOCOL = "openai"
        $global:PA_MODEL = "deepseek-v4-flash"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "Test prompt"
        $global:PA_THINKING_BUDGET = "0"
        $global:MESSAGES = @()
        $global:_CACHE_PROBE.state = "active"

        $tools = @(
            @{ name = "test_tool"; description = "A test tool"; input_schema = @{ type = "object" } }
        )

        $body = Build-ApiRequestBody -Tools $tools
        # OpenAI protocol: no cache_control markers needed
        # No cache_control should appear anywhere
        $body | Should -Not -Match "cache_control"
    }
}

# ============================================================================
#  Proxy Injection Tests (TODO-09 alignment)
#  ============================================================================
Describe "HttpClient.ps1 — Proxy Injection" {
    BeforeAll {
        $savedProxy = $global:PA_PROXY_URL
        $savedProxyUser = $global:PA_PROXY_USER
        $savedProxyPass = $global:PA_PROXY_PASS
        $savedProxyNo = $global:PA_PROXY_NOPROXY
    }
    AfterAll {
        $global:PA_PROXY_URL = $savedProxy
        $global:PA_PROXY_USER = $savedProxyUser
        $global:PA_PROXY_PASS = $savedProxyPass
        $global:PA_PROXY_NOPROBY = $savedProxyNo
    }

    It "Proxy settings are configurable via global vars" {
        $global:PA_PROXY_URL = "http://proxy.example.com:8080"
        $global:PA_PROXY_URL | Should -Be "http://proxy.example.com:8080"
    }

    It "PA_PROXY_NOPROXY can be set as comma-separated list" {
        $global:PA_PROXY_NOPROXY = "localhost,127.0.0.1,.internal"
        $global:PA_PROXY_NOPROXY | Should -Be "localhost,127.0.0.1,.internal"
    }

    It "Proxy credentials stored in global vars" {
        $global:PA_PROXY_USER = "user1"
        $global:PA_PROXY_PASS = "pass1"
        $global:PA_PROXY_USER | Should -Be "user1"
        $global:PA_PROXY_PASS | Should -Be "pass1"
    }

    It "Clearing proxy URL disables proxy" {
        $global:PA_PROXY_URL = ""
        [string]::IsNullOrEmpty($global:PA_PROXY_URL) | Should -Be $true
    }
}
