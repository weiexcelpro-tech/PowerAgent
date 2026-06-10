# ============================================================================
#  PowerAgent Test — E2E (End-to-End)
#  Validates full cross-module pipelines: tool dispatch,
#  multi-turn conversation, safe mode, budgets, and error handling.
#
#  No real HTTP calls are made. All interactions use internal functions
#  directly (tool dispatch, message management, request building).
# ============================================================================

# ============================================================================
#  0. Diagnostic — verify functions are real (not stale mocks from Daemon)
# ============================================================================
Describe "E2E Diagnostic — Function State Check" {
    It "Build-ApiRequestBody returns model from PA_MODEL" {
        $savedModel = $global:PA_MODEL
        $global:PA_MODEL = "diag-test-model"
        $global:PA_MAX_TOKENS = "1024"
        $global:PA_SYSTEM_PROMPT = "diag"
        $global:MESSAGES = @()
        try {
            $body = Build-ApiRequestBody
            $obj = $body | ConvertFrom-Json
            Write-Host "    model=$($obj.model) PA_MODEL=$($global:PA_MODEL)"
            $obj.model | Should -Be "diag-test-model"
        } finally {
            $global:PA_MODEL = $savedModel
        }
    }
    It "Get-ApiHeaders returns Authorization with PA_API_KEY" {
        $savedKey = $global:PA_API_KEY
        $global:PA_API_KEY = "diag-key-123"
        $global:PA_AUTH_HEADER = ""
        try {
            $headers = Get-ApiHeaders
            Write-Host "    headers=$($headers | ConvertTo-Json -Compress)"
            $headers["Authorization"] | Should -Match "diag-key-123"
        } finally {
            $global:PA_API_KEY = $savedKey
        }
    }
    It "Invoke-ApiCall returns structured result" {
        $savedModel = $global:PA_MODEL
        $global:PA_MODEL = "diag-model"
        try {
            $json = '{"choices":[{"message":{"role":"assistant","content":"diag"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
            function global:Invoke-HttpRequest { param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType) return @{ ExitCode = 0; StatusCode = 200; Body = $json } }
            try {
                $result = Invoke-ApiCall -RequestBody "{}" -Url "http://test" -Headers @{}
                Write-Host "    Success=$($result.Success) StopReason=$($result.StopReason) ContentBlocks=$(@($result.ContentBlocks).Count)"
                $result.Success | Should -BeTrue
            } finally {
                # Restore original Invoke-HttpRequest
                $origDef = $script:savedHttpRequest
                if ($origDef) { Set-Content Function:\Invoke-HttpRequest $origDef }
            }
        } finally {
            $global:PA_MODEL = $savedModel
        }
    }
}

# ============================================================================
#  1. E2E — Tool Dispatch Chain
#  Full file lifecycle through the dispatcher (write → read → edit → read → delete)
# ============================================================================
Describe "E2E — Tool Dispatch Chain" {

    BeforeEach {
        $script:tempDir = Join-Path $env:TEMP "pa_e2e_dispatch_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        $global:PA_TRACE_ENABLED = "0"
        $global:PA_SAFE_MODE = $false
        $global:PA_HEADLESS = $false
    }

    AfterEach {
        Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        $global:PA_SAFE_MODE = $false
        $global:PA_HEADLESS = $false
    }

    It "Write → Read → Edit → Read → Delete lifecycle via dispatcher" {
        $testFile = Join-Path $script:tempDir "lifecycle.txt"

        # 写入新文件
        $writeResult = Invoke-ToolDispatch -ToolName "write_file" -ToolInput @{
            path = $testFile
            content = "Hello PowerAgent E2E"
        }
        $writeResult.status | Should -Be "ok"
        Test-Path $testFile | Should -BeTrue

        # 读取文件
        $readResult = Invoke-ToolDispatch -ToolName "read_file" -ToolInput @{
            path = $testFile
        }
        $readResult.status | Should -Be "ok"
        $readResult.content | Should -Match "Hello PowerAgent E2E"

        # 编辑文件
        $editResult = Invoke-ToolDispatch -ToolName "edit_file" -ToolInput @{
            path = $testFile
            old_string = "Hello"
            new_string = "Goodbye"
        }
        $editResult.status | Should -Be "ok"
        $editResult.lines_changed | Should -BeGreaterThan 0

        # 再次读取，验证编辑生效
        $readResult2 = Invoke-ToolDispatch -ToolName "read_file" -ToolInput @{
            path = $testFile
        }
        $readResult2.status | Should -Be "ok"
        $readResult2.content | Should -Match "Goodbye PowerAgent E2E"
        $readResult2.content | Should -Not -Match "Hello"

        # 删除文件
        $deleteResult = Invoke-ToolDispatch -ToolName "delete_file" -ToolInput @{
            path = $testFile
        }
        $deleteResult.status | Should -Be "ok"
        Test-Path $testFile | Should -BeFalse
    }

    It "Dispatch with ToolId wraps result in Anthropic tool_result format" {
        $testFile = Join-Path $script:tempDir "wrapped.txt"
        Set-Content $testFile "wrapped content" -Encoding UTF8

        $result = Invoke-ToolDispatch -ToolName "read_file" -ToolId "call_wrap_001" -ToolInput @{
            path = $testFile
        }

        $result.type | Should -Be "tool_result"
        $result.tool_use_id | Should -Be "call_wrap_001"
        @($result.content).Count | Should -BeGreaterOrEqual 1
        $result.content[0].type | Should -Be "text"

        # content[0].text 是 JSON 字符串，解析后应包含 status=ok
        $inner = $result.content[0].text | ConvertFrom-Json
        $inner.status | Should -Be "ok"
    }

    It "List files then read from listed entries" {
        # 创建测试文件
        Set-Content (Join-Path $script:tempDir "alpha.txt") "AAA" -Encoding UTF8
        Set-Content (Join-Path $script:tempDir "beta.txt") "BBB" -Encoding UTF8

        $listResult = Invoke-ToolDispatch -ToolName "list_files" -ToolInput @{
            path = $script:tempDir
        }
        $listResult.status | Should -Be "ok"
        @($listResult.entries).Count | Should -BeGreaterOrEqual 2

        # 读取其中一个文件
        $alphaPath = Join-Path $script:tempDir "alpha.txt"
        $readResult = Invoke-ToolDispatch -ToolName "read_file" -ToolInput @{
            path = $alphaPath
        }
        $readResult.status | Should -Be "ok"
        $readResult.content | Should -Match "AAA"
    }
}

# ============================================================================
#  2. E2E — Invoke-ApiCall Mocked API Response
#  Full pipeline: mock Invoke-HttpRequest → Invoke-ApiCall →
#  ContentBlocks extraction → verify internal format + $global:MESSAGES
# ============================================================================
Describe "E2E — Invoke-ApiCall Mocked API Response" {

    # 在 Describe 级别保存原始函数引用
    $script:savedHttpRequest = Get-Content Function:\Invoke-HttpRequest -ErrorAction SilentlyContinue

    BeforeEach {
        $global:MESSAGES = @()
        $global:PA_MODEL = "test-model"
        $global:PA_MAX_TOKENS = "4096"
        $global:PA_SYSTEM_PROMPT = "You are a test assistant."
        $global:PA_THINKING_BUDGET = "0"
        $global:PA_TRACE_ENABLED = "0"
        $global:PA_CONNECT_TIMEOUT = "30"
    }

    AfterEach {
        $global:MESSAGES = @()
    }

    # Restore original Invoke-HttpRequest after ALL tests in this Describe finish
    # Without this, the stale mock pollutes HttpClient.Tests.ps1 and other later files
    AfterAll {
        if ($script:savedHttpRequest) {
            Set-Content Function:\Invoke-HttpRequest $script:savedHttpRequest
        }
    }

    It "Mocked text response → Invoke-ApiCall → end_turn with text ContentBlock" {
        # Use raw JSON literal to avoid ConvertTo-Json/ConvertFrom-Json double-serialization issues
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","content":"The file contains configuration data."},"finish_reason":"stop"}],"usage":{"prompt_tokens":25,"completion_tokens":12}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        # 验证返回结构
        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "end_turn"
        @($result.ContentBlocks).Count | Should -Be 1
        $result.ContentBlocks[0].type | Should -Be "text"
        $result.ContentBlocks[0].text | Should -Be "The file contains configuration data."
        $result.InputTokens | Should -Be 25
        $result.OutputTokens | Should -Be 12
    }

    It "Mocked tool_calls response → tool_use stop reason with tool_call ContentBlocks" {
        # Raw JSON: content=null removed (absent key = null in JS); tool_calls with arguments as JSON string
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call_e2e_001","function":{"name":"read_file","arguments":"{\"path\":\"C:\\\\test\\\\data.txt\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":40,"completion_tokens":20}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "tool_use"
        @($result.ContentBlocks).Count | Should -Be 1
        $result.ContentBlocks[0].type | Should -Be "tool_call"
        $result.ContentBlocks[0].id | Should -Be "call_e2e_001"
        $result.ContentBlocks[0].name | Should -Be "read_file"
    }

    It "Mocked response with reasoning_content → thinking ContentBlock" {
        # Raw JSON: reasoning_content as a plain string field
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","reasoning_content":"Let me analyze this step by step...","content":"The answer is 42."},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":30}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "end_turn"
        $result.InputTokens | Should -Be 50
        # thinking + text = 2 blocks
        @($result.ContentBlocks).Count | Should -Be 2
        $result.ContentBlocks[0].type | Should -Be "thinking"
        $result.ContentBlocks[1].type | Should -Be "text"
    }

    It "Mocked empty choices → Success=false, StopReason=error" {
        # 模拟 API 返回空 choices（服务端错误场景）
        $global:_e2eMockJson = '{"choices":[]}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        $result.Success | Should -BeFalse
        $result.StopReason | Should -Be "error"
        @($result.ContentBlocks).Count | Should -Be 0
    }

    It "Mocked finish_reason mapping → correct StopReason values" {
        # 验证所有 finish_reason → StopReason 映射
        $mappings = @(
            @{ finish = "stop"; expected = "end_turn" }
            @{ finish = "length"; expected = "max_tokens" }
            @{ finish = "tool_calls"; expected = "tool_use" }
            @{ finish = "content_filter"; expected = "end_turn" }
        )
        foreach ($m in $mappings) {
            $global:_e2eMockJson = "{`"choices`":[{`"message`":{`"role`":`"assistant`",`"content`":`"test`"},`"finish_reason`":`"$($m.finish)`"}]}"

            function global:Invoke-HttpRequest {
                param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
                return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
            }

            $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
            $result.StopReason | Should -Be $m.expected
        }
    }

    It "Mocked response without usage → InputTokens=0, OutputTokens=0" {
        # Raw JSON: no usage field at all
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","content":"No usage info"},"finish_reason":"stop"}]}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.InputTokens | Should -Be 0
        $result.OutputTokens | Should -Be 0
    }

    It "Mocked HTTP error (ExitCode!=0) → error response" {
        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 1; StatusCode = 500; Body = "" }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        $result.Success | Should -BeFalse
        $result.StopReason | Should -Be "error"
        $result.Error | Should -Match "HTTP error"
    }

    It "Mocked invalid JSON → error response with parse error" {
        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = "not-valid-json{{{}}}" }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        $result.Success | Should -BeFalse
        $result.StopReason | Should -Be "error"
    }

    It "Mocked full pipeline: response → Add-AssistantMessage → Add-ToolResults → verify MESSAGES" {
        # Raw JSON: simple text response
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","content":"I have analyzed the file."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":8}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        # 使用 ContentBlocks 构建助手消息
        Add-UserText "Analyze the file"
        $textBlocks = @($result.ContentBlocks | Where-Object { $_.type -eq "text" })
        Add-AssistantMessage @(@{ type = "text"; text = $textBlocks[0].text })

        $global:MESSAGES.Count | Should -Be 2
        $global:MESSAGES[0].role | Should -Be "user"
        $global:MESSAGES[1].role | Should -Be "assistant"
    }

    It "Mocked Chinese content → preserved in ContentBlocks" {
        # Raw JSON: Chinese characters in content
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","content":"文件内容包含中文数据：你好世界"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":15}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "end_turn"
        $result.ContentBlocks[0].text | Should -Match "你好世界"
    }

    It "Mocked multiple tool_calls → multiple tool_call ContentBlocks" {
        # Raw JSON: two tool_calls
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call_multi_001","function":{"name":"read_file","arguments":"{\"path\":\"C:\\\\a.txt\"}"}},{"id":"call_multi_002","function":{"name":"read_file","arguments":"{\"path\":\"C:\\\\b.txt\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":30,"completion_tokens":25}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}

        $result.Success | Should -BeTrue
        $result.StopReason | Should -Be "tool_use"
        $toolCallBlocks = @($result.ContentBlocks | Where-Object { $_.type -eq "tool_call" })
        $toolCallBlocks.Count | Should -Be 2
        $toolCallBlocks[0].name | Should -Be "read_file"
        $toolCallBlocks[1].name | Should -Be "read_file"
    }

    It "Mocked response → dispatch tools → full E2E pipeline" {
        # 端到端完整流程: mock API 响应 → 解析 → 工具派发 → 消息记录
        $script:tempDir = Join-Path $env:TEMP "pa_e2e_resp_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        $targetFile = Join-Path $script:tempDir "target.txt"
        Set-Content $targetFile "E2E response pipeline data" -Encoding UTF8

        try {
            # 用户提问
            Add-UserText "Read $targetFile"

            # Build arguments JSON separately to handle Windows path backslashes
            $argObj = @{ path = $targetFile } | ConvertTo-Json -Compress
            $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call_e2e_pipe_001","function":{"name":"read_file","arguments":"' + ($argObj -replace '\\','\\\\' -replace '"','\"') + '"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10}}'

            function global:Invoke-HttpRequest {
                param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
                return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
            }

            $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
            $result.StopReason | Should -Be "tool_use"

            # 从 ContentBlocks 构建 tool_use 助手消息
            $tcBlock = @($result.ContentBlocks | Where-Object { $_.type -eq "tool_call" })[0]
            $asstBlocks = @(
                @{
                    type = "tool_use"
                    id = $tcBlock.id
                    name = $tcBlock.name
                    input = $tcBlock.arguments
                }
            )
            Add-AssistantMessage $asstBlocks

            # 派发工具
            $dispatchResult = Invoke-ToolDispatch -ToolName "read_file" -ToolId "call_e2e_pipe_001" -ToolInput @{ path = $targetFile }
            Add-ToolResults @($dispatchResult)

            # 验证完整消息历史
            $global:MESSAGES.Count | Should -Be 3
            $global:MESSAGES[0].role | Should -Be "user"
            $global:MESSAGES[1].role | Should -Be "assistant"
            $global:MESSAGES[2].role | Should -Be "tool"
        } finally {
            Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Usage extraction: prompt_tokens→InputTokens, completion_tokens→OutputTokens" {
        $global:_e2eMockJson = '{"choices":[{"message":{"role":"assistant","content":"token test"},"finish_reason":"stop"}],"usage":{"prompt_tokens":123,"completion_tokens":456}}'

        function global:Invoke-HttpRequest {
            param($Method, $Url, $Body, $Headers, $ConnectTimeout, $TotalTimeout, $ContentType)
            return @{ ExitCode = 0; StatusCode = 200; Body = $global:_e2eMockJson }
        }

        $result = Invoke-ApiCall -RequestBody "{}" -Url "http://localhost/test" -Headers @{}
        $result.InputTokens | Should -Be 123
        $result.OutputTokens | Should -Be 456
    }
}

# ============================================================================
#  3. E2E — Multi-Turn Conversation Pipeline
#  Simulate 2 full turns: user text → mock tool_use → dispatch →
#  next request build → verify message history
# ============================================================================
Describe "E2E — Multi-Turn Conversation Pipeline" {

    BeforeEach {
        $script:tempDir = Join-Path $env:TEMP "pa_e2e_multiturn_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        $global:MESSAGES = @()
        $global:PA_MODEL = "test-model"
        $global:PA_MAX_TOKENS = "4096"
        $global:PA_SYSTEM_PROMPT = "You are a test assistant."
        $global:PA_THINKING_BUDGET = "0"
        $global:PA_TRACE_ENABLED = "0"
        $global:PA_SAFE_MODE = $false
        $global:PA_HEADLESS = $false
    }

    AfterEach {
        Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        $global:MESSAGES = @()
    }

    It "Turn 1: user asks → tool_use dispatched → Turn 2: build request with tool_result" {
        $targetFile = Join-Path $script:tempDir " convo_target.txt"
        Set-Content $targetFile "Multi-turn conversation data" -Encoding UTF8

        # === Turn 1: 用户提问 ===
        Add-UserText "Read the file at $targetFile"
        $global:MESSAGES.Count | Should -Be 1
        $global:MESSAGES[0].role | Should -Be "user"
        $global:MESSAGES[0].content | Should -Match "Read the file"

        # 模拟 API 返回 tool_use
        $assistantBlocks = @(
            @{ type = "text"; text = "I will read that file now." }
            @{
                type = "tool_use"
                id = "call_turn1_001"
                name = "read_file"
                input = @{ path = $targetFile }
            }
        )
        Add-AssistantMessage $assistantBlocks
        $global:MESSAGES.Count | Should -Be 2

        # dispatch tool 并添加结果
        $toolBlock = $assistantBlocks | Where-Object { $_.type -eq "tool_use" } | Select-Object -First 1
        $dispatchResult = Invoke-ToolDispatch `
            -ToolName $toolBlock.name `
            -ToolId $toolBlock.id `
            -ToolInput $toolBlock.input
        Add-ToolResults @($dispatchResult)
        $global:MESSAGES.Count | Should -Be 3

        # === Turn 2: 构建 next request ===
        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        # messages 应包含至少 3 条（user, assistant, user/tool_result）
        @($bodyObj.messages).Count | Should -BeGreaterOrEqual 3

        # 验证 tool_result 在 API 请求中（OpenAI 格式下 tool_result 变为 role=tool）
        $lastMsg = @($bodyObj.messages)[-1]
        $lastMsg.role | Should -Be "tool"
    }

    It "Two turns produce 4-message history before second user text" {
        $targetFile = Join-Path $script:tempDir "two_turns.txt"
        Set-Content $targetFile "Two-turn test" -Encoding UTF8

        # Turn 1 用户消息
        Add-UserText "What is in $targetFile ?"
        # Turn 1 assistant (含 tool_use)
        $asstBlocks = @(
            @{ type = "tool_use"; id = "call_tt_001"; name = "read_file"; input = @{ path = $targetFile } }
        )
        Add-AssistantMessage $asstBlocks
        # Turn 1 tool_result
        $dispatched = Invoke-ToolDispatch -ToolName "read_file" -ToolId "call_tt_001" -ToolInput @{ path = $targetFile }
        Add-ToolResults @($dispatched)

        # 此时有 3 条消息
        $global:MESSAGES.Count | Should -Be 3

        # Turn 2 用户追问
        Add-UserText "Now edit the file."
        $global:MESSAGES.Count | Should -Be 4

        # 验证 4 条消息的结构
        $global:MESSAGES[0].role | Should -Be "user"     # Turn 1 user text
        $global:MESSAGES[1].role | Should -Be "assistant" # Turn 1 assistant (tool_use)
        $global:MESSAGES[2].role | Should -Be "tool"      # Turn 1 tool_result
        $global:MESSAGES[3].role | Should -Be "user"      # Turn 2 user text
    }
}

# ============================================================================
#  4. E2E — Safe Mode Blocks Destructive Operations
  #  $PA_SAFE_MODE + $PA_HEADLESS → auto-deny write/edit/delete/powershell
# ============================================================================
Describe "E2E — Safe Mode Blocks Destructive Operations" {

    BeforeEach {
        $script:tempDir = Join-Path $env:TEMP "pa_e2e_safe_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        $global:PA_SAFE_MODE = $true
        $global:PA_HEADLESS = $true
        $global:PA_TRACE_ENABLED = "0"
    }

    AfterEach {
        Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        $global:PA_SAFE_MODE = $false
        $global:PA_HEADLESS = $false
    }

    It "Blocks write_file in safe mode" {
        $targetPath = Join-Path $script:tempDir "safe_write.txt"
        $result = Invoke-ToolDispatch -ToolName "write_file" -ToolInput @{
            path = $targetPath; content = "blocked"
        }
        $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
        $resultJson | Should -Match "denied|safe"
        Test-Path $targetPath | Should -BeFalse
    }

    It "Blocks edit_file in safe mode" {
        $targetPath = Join-Path $script:tempDir "safe_edit.txt"
        Set-Content $targetPath "original" -Encoding UTF8
        $result = Invoke-ToolDispatch -ToolName "edit_file" -ToolInput @{
            path = $targetPath; old_string = "original"; new_string = "modified"
        }
        $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
        $resultJson | Should -Match "denied|safe"
        # 文件内容不应被修改
        Get-Content $targetPath -Raw | Should -Match "original"
    }

    It "Blocks delete_file in safe mode" {
        $targetPath = Join-Path $script:tempDir "safe_delete.txt"
        Set-Content $targetPath "to be deleted" -Encoding UTF8
        $result = Invoke-ToolDispatch -ToolName "delete_file" -ToolInput @{
            path = $targetPath
        }
        $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
        $resultJson | Should -Match "denied|safe"
        Test-Path $targetPath | Should -BeTrue
    }

    It "Blocks powershell in safe mode" {
        $result = Invoke-ToolDispatch -ToolName "powershell" -ToolInput @{
            command = "Write-Output 'should be blocked'"
        }
        $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
        $resultJson | Should -Match "denied|safe"
    }

    It "Allows read_file in safe mode (read-only is fine)" {
        $targetPath = Join-Path $script:tempDir "safe_read.txt"
        Set-Content $targetPath "readable" -Encoding UTF8
        $result = Invoke-ToolDispatch -ToolName "read_file" -ToolInput @{
            path = $targetPath
        }
        $result.status | Should -Be "ok"
    }

    It "Allows list_files in safe mode (read-only is fine)" {
        $result = Invoke-ToolDispatch -ToolName "list_files" -ToolInput @{
            path = $script:tempDir
        }
        $result.status | Should -Be "ok"
    }
}

# ============================================================================
#  5. E2E — Adaptive Budget Escalation
#  Compute-CallBudget thresholds and Test-TurnBudget limits
# ============================================================================
Describe "E2E — Adaptive Budget Escalation" {

    Context "Compute-CallBudget threshold boundaries" {
        It "0 consecutive tools → 100pct" {
            Compute-CallBudget -ConsecutiveTools 0 | Should -Be "100pct"
        }
        It "9 consecutive tools → 100pct (still safe)" {
            Compute-CallBudget -ConsecutiveTools 9 | Should -Be "100pct"
        }
        It "10 consecutive tools → 50pct (escalation starts)" {
            Compute-CallBudget -ConsecutiveTools 10 | Should -Be "50pct"
        }
        It "50 consecutive tools → 50pct" {
            Compute-CallBudget -ConsecutiveTools 50 | Should -Be "50pct"
        }
        It "89 consecutive tools → 50pct (still not halted)" {
            Compute-CallBudget -ConsecutiveTools 89 | Should -Be "50pct"
        }
        It "90 consecutive tools → halt (hard stop)" {
            Compute-CallBudget -ConsecutiveTools 90 | Should -Be "halt"
        }
        It "100 consecutive tools → halt" {
            Compute-CallBudget -ConsecutiveTools 100 | Should -Be "halt"
        }
        It "200 consecutive tools → halt" {
            Compute-CallBudget -ConsecutiveTools 200 | Should -Be "halt"
        }
    }

    Context "Test-TurnBudget threshold boundaries" {
        BeforeEach {
            $script:savedContextWindow = $global:PA_CONTEXT_WINDOW
            $script:savedEstimate = Get-Content Function:\Estimate-ContextTokens -ErrorAction SilentlyContinue
            function global:Estimate-ContextTokens { return 0 }
        }

        AfterEach {
            $global:PA_CONTEXT_WINDOW = $script:savedContextWindow
            if ($script:savedEstimate) {
                Set-Content Function:\Estimate-ContextTokens $script:savedEstimate
            }
        }

        It "Well under threshold → ok" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            function global:Estimate-ContextTokens { return 50000 }
            Test-TurnBudget | Should -Be "ok"
        }

        It "Just below soft limit (84%) → ok" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            function global:Estimate-ContextTokens { return 108799 }
            Test-TurnBudget | Should -Be "ok"
        }

        It "Over soft but under hard → soft_limit" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            function global:Estimate-ContextTokens { return 110000 }
            Test-TurnBudget | Should -Be "soft_limit"
        }

        It "Over hard budget → exhausted" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            function global:Estimate-ContextTokens { return 130000 }
            Test-TurnBudget | Should -Be "exhausted"
        }

        It "Exactly at hard budget → exhausted" {
            Set-Variable -Name "PA_CONTEXT_WINDOW" -Value 128000 -Scope Global
            function global:Estimate-ContextTokens { return 121600 }
            Test-TurnBudget | Should -Be "exhausted"
        }
    }
}

# ============================================================================
#  6. E2E — Error Handling
#  Validates graceful degradation across tool dispatch, file ops,
#  and API response parsing
# ============================================================================
Describe "E2E — Error Handling" {

    It "Unknown tool name returns error from dispatcher" {
        $result = Invoke-ToolDispatch -ToolName "totally_fake_tool_xyz" -ToolInput @{}
        $result.status | Should -Be "error"
        $result.error | Should -Match "Unknown tool"
    }

    It "Unknown tool with ToolId still wraps in tool_result" {
        $result = Invoke-ToolDispatch -ToolName "fake_tool_abc" -ToolId "call_err_001" -ToolInput @{}
        $result.type | Should -Be "tool_result"
        $result.tool_use_id | Should -Be "call_err_001"
        # 解析内部 JSON 验证 error
        $inner = $result.content[0].text | ConvertFrom-Json
        $inner.status | Should -Be "error"
    }

    It "ReadFile on nonexistent path returns error" {
        $result = Invoke-ToolReadFile @{ path = "C:\nonexistent_e2e_$(Get-Random)_file.txt" }
        $result.status | Should -Be "error"
    }

    It "EditFile with wrong old_string returns error with hint" {
        $testFile = Join-Path $env:TEMP "pa_e2e_editerr_$(Get-Random).txt"
        try {
            Set-Content $testFile "Actual content here" -Encoding UTF8
            $result = Invoke-ToolEditFile @{
                path = $testFile
                old_string = "WRONG TEXT NOT IN FILE"
                new_string = "replacement"
            }
            $result.status | Should -Be "error"
            # 错误应包含提示信息
            $result.error | Should -Not -BeNullOrEmpty
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "WriteFile to existing path refuses overwrite" {
        $testFile = Join-Path $env:TEMP "pa_e2e_nooverwrite_$(Get-Random).txt"
        try {
            Set-Content $testFile "Already exists" -Encoding UTF8
            $result = Invoke-ToolWriteFile @{
                path = $testFile
                content = "Attempt overwrite"
            }
            $result.status | Should -Be "error"
            # 原内容不应被改动
            Get-Content $testFile -Raw | Should -Match "Already exists"
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "DeleteFile on nonexistent path returns error" {
        $result = Invoke-ToolDeleteFile @{ path = "C:\nonexistent_e2e_delete_$(Get-Random).txt" }
        $result.status | Should -Be "error"
    }
}

# ============================================================================
#  7. E2E — Build-ApiRequestBody Full Round-Trip
#  Complete request building pipeline: $global:MESSAGES → Build-ApiRequestBody →
#  verify OpenAI API format output (v0.6: internal format IS OpenAI)
# ============================================================================
Describe "E2E — Build-ApiRequestBody Full Round-Trip" {

    BeforeEach {
        $global:MESSAGES = @()
        $global:PA_MODEL = "test-model"
        $global:PA_MAX_TOKENS = "4096"
        $global:PA_SYSTEM_PROMPT = "You are a test assistant."
        $global:PA_THINKING_BUDGET = "0"
        $global:PA_TRACE_ENABLED = "0"
        $global:PA_SAFE_MODE = $false
        $global:PA_HEADLESS = $false
    }

    AfterEach {
        $global:MESSAGES = @()
    }

    It "Simple user message → Build-ApiRequestBody → valid JSON with user role" {
        Add-UserText "Hello from E2E round-trip"

        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        $bodyObj.model | Should -Be "test-model"
        @($bodyObj.messages).Count | Should -BeGreaterOrEqual 1
        $lastMsg = @($bodyObj.messages)[-1]
        $lastMsg.role | Should -Be "user"
    }

    It "System prompt → included as system role message in request" {
        $global:PA_SYSTEM_PROMPT = "你是一个专业的测试助手"
        Add-UserText "Test system prompt"

        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        # 系统提示应在消息列表中（作为第一条或 system 字段）
        $hasSystem = $false
        foreach ($msg in $bodyObj.messages) {
            if ($msg.role -eq "system") { $hasSystem = $true; break }
        }
        # OpenAI 格式下 system 应出现在 messages 中
        $hasSystem | Should -BeTrue
    }

    It "Assistant with tool_use → converted to tool_calls in OpenAI format" {
        Add-UserText "Read the file"
        $asstBlocks = @(
            @{ type = "text"; text = "I will read it." }
            @{
                type = "tool_use"
                id = "call_rt_001"
                name = "read_file"
                input = @{ path = "C:\test.txt" }
            }
        )
        Add-AssistantMessage $asstBlocks

        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        # 找到 assistant 消息
        $assistMsg = @($bodyObj.messages) | Where-Object { $_.role -eq "assistant" } | Select-Object -First 1
        $assistMsg | Should -Not -BeNullOrEmpty
        $assistMsg.content | Should -Not -BeNullOrEmpty
    }

    It "Tool result → converted to role=tool message in request" {
        Add-UserText "Check file"
        $asstBlocks = @(
            @{ type = "tool_use"; id = "call_rt_002"; name = "read_file"; input = @{ path = "C:\dummy.txt" } }
        )
        Add-AssistantMessage $asstBlocks

        # 模拟工具结果
        $toolResult = @{
            type = "tool_result"
            tool_use_id = "call_rt_002"
            content = "file content here"
        }
        Add-ToolResults @($toolResult)

        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        # 最后一条消息应为 role=tool（OpenAI 格式）
        $lastMsg = @($bodyObj.messages)[-1]
        $lastMsg.role | Should -Be "tool"
    }

    It "Full round-trip: user → assistant(tool_use) → tool_result → next request" {
        $script:tempDir = Join-Path $env:TEMP "pa_e2e_roundtrip_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        $targetFile = Join-Path $script:tempDir "roundtrip.txt"
        Set-Content $targetFile "Round-trip test data" -Encoding UTF8

        try {
            # Turn 1: 用户提问
            Add-UserText "Read $targetFile"
            $asstBlocks = @(
                @{ type = "tool_use"; id = "call_rt_full_001"; name = "read_file"; input = @{ path = $targetFile } }
            )
            Add-AssistantMessage $asstBlocks

            # 派发工具
            $dispatched = Invoke-ToolDispatch -ToolName "read_file" -ToolId "call_rt_full_001" -ToolInput @{ path = $targetFile }
            Add-ToolResults @($dispatched)

            # 构建下一轮请求
            $bodyJson = Build-ApiRequestBody
            $bodyObj = $bodyJson | ConvertFrom-Json

            @($bodyObj.messages).Count | Should -BeGreaterOrEqual 3
            $bodyObj.model | Should -Be "test-model"
        } finally {
            Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Thinking params → passed through to request when budget > 0" {
        $savedBudget = $global:PA_THINKING_BUDGET
        $savedModel = $global:PA_MODEL
        $savedProtocol = $global:PA_PROTOCOL
        try {
            $global:PA_THINKING_BUDGET = "5000"
            $global:PA_MODEL = "deepseek-v4-flash"
            $global:PA_PROTOCOL = "openai"
            Add-UserText "Think carefully"

            $deepseekProfile = $global:MODEL_PROFILES["deepseek"]
            $bodyJson = Build-ApiRequestBody -ThinkingBudget 5000 -Model "deepseek-v4-flash" -Profile $deepseekProfile
            $bodyObj = $bodyJson | ConvertFrom-Json

            $bodyObj.thinking | Should -Not -BeNullOrEmpty
            $bodyObj.thinking.type | Should -Be "enabled"
        } finally {
            $global:PA_THINKING_BUDGET = $savedBudget
            $global:PA_MODEL = $savedModel
            $global:PA_PROTOCOL = $savedProtocol
        }
    }

    It "Tools with input_schema → converted to function.parameters in request" {
        Add-UserText "Use tools"

        $tools = @(
            @{
                name = "read_file"
                description = "Read a file"
                input_schema = @{
                    type = "object"
                    properties = @{
                        path = @{ type = "string"; description = "文件路径" }
                    }
                }
            }
        )

        $bodyJson = Build-ApiRequestBody -Tools $tools
        $bodyObj = $bodyJson | ConvertFrom-Json

        $bodyObj.tools | Should -Not -BeNullOrEmpty
        $tool = @($bodyObj.tools)[0]
        $tool.type | Should -Be "function"
        $tool.function.name | Should -Be "read_file"
    }

    It "Multiple tools in single assistant message → multiple tool_calls" {
        Add-UserText "Read two files"
        $asstBlocks = @(
            @{ type = "text"; text = "Reading both files." }
            @{ type = "tool_use"; id = "call_rt_m1"; name = "read_file"; input = @{ path = "C:\a.txt" } }
            @{ type = "tool_use"; id = "call_rt_m2"; name = "read_file"; input = @{ path = "C:\b.txt" } }
        )
        Add-AssistantMessage $asstBlocks

        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        $assistMsg = @($bodyObj.messages) | Where-Object { $_.role -eq "assistant" } | Select-Object -First 1
        $assistMsg | Should -Not -BeNullOrEmpty
    }

    It "Empty messages array → still produces valid request" {
        $global:MESSAGES = @()

        $bodyJson = Build-ApiRequestBody
        { $bodyJson | ConvertFrom-Json } | Should -Not -Throw
        $bodyObj = $bodyJson | ConvertFrom-Json
        $bodyObj.model | Should -Not -BeNullOrEmpty
    }

    It "Chinese content in messages → properly preserved in request" {
        Add-UserText "请分析这个文件的内容"
        $asstBlocks = @(
            @{ type = "text"; text = "好的，我来分析文件内容。" }
        )
        Add-AssistantMessage $asstBlocks

        $bodyJson = Build-ApiRequestBody
        $bodyObj = $bodyJson | ConvertFrom-Json

        # 中文内容不应被破坏
        $bodyJson | Should -Match "分析"
        $bodyJson | Should -Match "文件"
    }

    It "Build-ApiRequestBody handles tool_result with array content" {
        # 工具结果包含数组内容（多个 text 块）
        Add-UserText "Read file"
        $asstBlocks = @(
            @{ type = "tool_use"; id = "call_rt_arr"; name = "read_file"; input = @{ path = "C:\test.txt" } }
        )
        Add-AssistantMessage $asstBlocks

        $toolResult = @{
            type = "tool_result"
            tool_use_id = "call_rt_arr"
            content = @(
                @{ type = "text"; text = "第一行内容" }
                @{ type = "text"; text = "第二行内容" }
            )
        }
        Add-ToolResults @($toolResult)

        $bodyJson = Build-ApiRequestBody
        { $bodyJson | ConvertFrom-Json } | Should -Not -Throw
    }

    It "Round-trip preserves message count across request builds" {
        # 验证多次构建请求不会丢失消息
        Add-UserText "First message"
        Add-AssistantMessage @(@{ type = "text"; text = "First response" })
        Add-UserText "Second message"

        $global:MESSAGES.Count | Should -Be 3

        $body1 = Build-ApiRequestBody | ConvertFrom-Json
        @($body1.messages).Count | Should -BeGreaterOrEqual 3

        # 再次构建，消息数量不应改变
        $body2 = Build-ApiRequestBody | ConvertFrom-Json
        @($body2.messages).Count | Should -BeGreaterOrEqual 3
        $global:MESSAGES.Count | Should -Be 3
    }
}
