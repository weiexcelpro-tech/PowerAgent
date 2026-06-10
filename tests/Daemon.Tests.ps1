# ============================================================================
#  PowerAgent Test — Daemon.ps1
#  Validates HTTP REST API, session persistence, chat execution,
#  SSE streaming, cron scheduler (interval + 5-field)
# ============================================================================

# ── Test helper: restore original function definitions after mocking ──
# run_tests.ps1 saves original definitions in $global:_PA_ORIGINAL_FN_DEFS
# BEFORE promoting to global scope (PS5.1's .Definition returns empty after promotion).
# Mock cleanup restores from these originals so later test files keep access.
# Uses $global: scope because Pester v5 isolates $script: scope in Describe/Context/It

function script:Save-FnDef {
    param([string[]]$Names)
    # No-op: definitions already saved by run_tests.ps1 before promotion
    # Keeping function signature for compatibility with existing calls
}

function script:Restore-FnDefs {
    param([string[]]$Names)
    foreach ($name in $Names) {
        if ($global:_PA_ORIGINAL_FN_DEFS -and $global:_PA_ORIGINAL_FN_DEFS[$name]) {
            Set-Item -Path "function:global:$name" -Value $global:_PA_ORIGINAL_FN_DEFS[$name] -ErrorAction SilentlyContinue
        }
    }
}

# ── Test helper: create a mock session in $global:DAEMON_SESSIONS ──
function script:New-TestSession {
    param(
        [string]$Id = "sess_test_$(Get-Random)",
        [string]$SystemPrompt = "",
        [hashtable[]]$Messages = @()
    )
    $session = @{
        id = $Id
        created = Get-TimestampMs
        status = "idle"
        system_prompt = $SystemPrompt
        messages = $Messages
    }
    $global:DAEMON_SESSIONS[$Id] = $session
    return $session
}

# ============================================================================
#  1. Initialize-DaemonGlobals
# ============================================================================
Describe "Daemon — Initialize-DaemonGlobals" {
    BeforeEach {
        $savedApiKey = $global:PA_API_KEY
        $savedApiUrl = $global:PA_API_URL
        $savedModel = $global:PA_MODEL
        $savedPort = $global:PA_DAEMON_PORT
        $savedMaxTokens = $global:PA_MAX_TOKENS
        $savedThinking = $global:PA_THINKING_BUDGET
        $savedCtxWin = $global:PA_CONTEXT_WINDOW
        $savedSysPrompt = $global:PA_SYSTEM_PROMPT
        $savedProtocol = $global:PA_PROTOCOL
        $savedTimeout = $global:PA_CONNECT_TIMEOUT
    }
    AfterEach {
        $global:PA_API_KEY = $savedApiKey
        $global:PA_API_URL = $savedApiUrl
        $global:PA_MODEL = $savedModel
        $global:PA_DAEMON_PORT = $savedPort
        $global:PA_MAX_TOKENS = $savedMaxTokens
        $global:PA_THINKING_BUDGET = $savedThinking
        $global:PA_CONTEXT_WINDOW = $savedCtxWin
        $global:PA_SYSTEM_PROMPT = $savedSysPrompt
        $global:PA_PROTOCOL = $savedProtocol
        $global:PA_CONNECT_TIMEOUT = $savedTimeout
    }

    It "Sets PA_API_KEY from env var when global is empty" {
        $global:PA_API_KEY = ""
        $env:PA_API_KEY = "env-test-key-$(Get-Random)"
        Initialize-DaemonGlobals
        $global:PA_API_KEY | Should -Be $env:PA_API_KEY
        $env:PA_API_KEY = "test-key-12345"  # restore
    }

    It "Sets PA_API_URL from env var when global is empty" {
        $global:PA_API_URL = ""
        $env:PA_API_URL = "http://test-url:9999/api"
        Initialize-DaemonGlobals
        $global:PA_API_URL | Should -Be "http://test-url:9999/api"
        $env:PA_API_URL = "http://localhost:9999/v1/messages"  # restore
    }

    It "Applies sane default for PA_API_URL when both global and env are empty" {
        $global:PA_API_URL = ""
        $savedEnv = $env:PA_API_URL
        $env:PA_API_URL = ""
        Initialize-DaemonGlobals
        $global:PA_API_URL | Should -Match "deepseek"
        $env:PA_API_URL = $savedEnv
    }

    It "Does not overwrite existing global values" {
        $global:PA_MAX_TOKENS = 99999
        Initialize-DaemonGlobals
        $global:PA_MAX_TOKENS | Should -Be 99999
    }

    It "Sets PA_MAX_TOKENS default when not set" {
        $global:PA_MAX_TOKENS = $null
        Initialize-DaemonGlobals
        $global:PA_MAX_TOKENS | Should -Be 384000
    }

    It "Sets PA_CONTEXT_WINDOW default when not set" {
        $global:PA_CONTEXT_WINDOW = $null
        Initialize-DaemonGlobals
        $global:PA_CONTEXT_WINDOW | Should -Be 1048576
    }

    It "Sets PA_PROTOCOL default when not set" {
        $global:PA_PROTOCOL = $null
        Initialize-DaemonGlobals
        $global:PA_PROTOCOL | Should -Be "openai"
    }
}

# ============================================================================
#  2. Session Persistence
# ============================================================================
Describe "Daemon — Initialize-SessionsDir" {
    It "Creates sessions directory under PA_STATE_DIR" {
        $testDir = Join-Path $env:TEMP "pa_test_sessdir_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $savedStateDir = $global:PA_STATE_DIR
        $global:PA_STATE_DIR = $testDir

        try {
            Initialize-SessionsDir
            $global:DAEMON_SESSIONS_DIR | Should -Be (Join-Path $testDir "sessions")
            Test-Path $global:DAEMON_SESSIONS_DIR | Should -Be $true
        } finally {
            $global:PA_STATE_DIR = $savedStateDir
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Does not throw when directory already exists" {
        $testDir = Join-Path $env:TEMP "pa_test_sessdir_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $savedStateDir = $global:PA_STATE_DIR
        $global:PA_STATE_DIR = $testDir
        try {
            { Initialize-SessionsDir } | Should -Not -Throw
        } finally {
            $global:PA_STATE_DIR = $savedStateDir
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Daemon — Save-DaemonSession / Load-DaemonSessions / Remove-DaemonSessionFile" {
    BeforeAll {
        $testDir = Join-Path $env:TEMP "pa_test_persist_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $savedStateDir = $global:PA_STATE_DIR
        $global:PA_STATE_DIR = $testDir
        $savedSessions = $global:DAEMON_SESSIONS
        $global:DAEMON_SESSIONS = @{}
        Initialize-SessionsDir
    }
    AfterAll {
        $global:PA_STATE_DIR = $savedStateDir
        $global:DAEMON_SESSIONS = $savedSessions
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Save-DaemonSession writes a JSON file" {
        $session = New-TestSession -Id "sess_persist_001"
        Save-DaemonSession $session
        $filePath = Join-Path $global:DAEMON_SESSIONS_DIR "sess_persist_001.json"
        Test-Path $filePath | Should -Be $true
        $raw = Get-Content $filePath -Raw -Encoding UTF8
        $raw | Should -Match "sess_persist_001"
    }

    It "Save-DaemonSession persists messages" {
        $session = New-TestSession -Id "sess_persist_002" -Messages @(
            @{ role = "user"; content = "Hello"; timestamp = 1000 }
            @{ role = "assistant"; content = "Hi!"; timestamp = 1001 }
        )
        Save-DaemonSession $session
        $filePath = Join-Path $global:DAEMON_SESSIONS_DIR "sess_persist_002.json"
        $raw = Get-Content $filePath -Raw -Encoding UTF8
        $raw | Should -Match "Hello"
        $raw | Should -Match "Hi!"
    }

    It "Load-DaemonSessions loads saved sessions into DAEMON_SESSIONS" {
        $global:DAEMON_SESSIONS = @{}
        $session = New-TestSession -Id "sess_load_001"
        Save-DaemonSession $session
        # Clear in-memory
        $global:DAEMON_SESSIONS = @{}
        $loaded = Load-DaemonSessions
        $loaded | Should -BeGreaterOrEqual 1
        $global:DAEMON_SESSIONS.ContainsKey("sess_load_001") | Should -Be $true
    }

    It "Load-DaemonSessions converts PSCustomObject messages to hashtables" {
        $global:DAEMON_SESSIONS = @{}
        $session = New-TestSession -Id "sess_load_002" -Messages @(
            @{ role = "user"; content = "test message"; timestamp = 1234 }
        )
        Save-DaemonSession $session
        $global:DAEMON_SESSIONS = @{}
        Load-DaemonSessions | Out-Null
        $loaded = $global:DAEMON_SESSIONS["sess_load_002"]
        $loaded | Should -Not -BeNullOrEmpty
        @($loaded.messages).Count | Should -Be 1
        $loaded.messages[0].role | Should -Be "user"
        $loaded.messages[0].content | Should -Be "test message"
    }

    It "Load-DaemonSessions preserves system_prompt" {
        $global:DAEMON_SESSIONS = @{}
        $session = New-TestSession -Id "sess_load_003" -SystemPrompt "Custom system prompt"
        Save-DaemonSession $session
        $global:DAEMON_SESSIONS = @{}
        Load-DaemonSessions | Out-Null
        $loaded = $global:DAEMON_SESSIONS["sess_load_003"]
        $loaded.system_prompt | Should -Be "Custom system prompt"
    }

    It "Remove-DaemonSessionFile deletes the JSON file" {
        $session = New-TestSession -Id "sess_del_001"
        Save-DaemonSession $session
        $filePath = Join-Path $global:DAEMON_SESSIONS_DIR "sess_del_001.json"
        Test-Path $filePath | Should -Be $true
        Remove-DaemonSessionFile "sess_del_001"
        Test-Path $filePath | Should -Be $false
    }

    It "Remove-DaemonSessionFile does not throw on non-existent file" {
        { Remove-DaemonSessionFile "sess_nonexistent_999" } | Should -Not -Throw
    }

    It "Save + Load roundtrip preserves session status" {
        $global:DAEMON_SESSIONS = @{}
        $session = New-TestSession -Id "sess_roundtrip"
        $session.status = "idle"
        Save-DaemonSession $session
        $global:DAEMON_SESSIONS = @{}
        Load-DaemonSessions | Out-Null
        $loaded = $global:DAEMON_SESSIONS["sess_roundtrip"]
        $loaded.status | Should -Be "idle"
    }
}

# ============================================================================
#  3. New-DaemonSession
# ============================================================================
Describe "Daemon — New-DaemonSession" {
    BeforeEach {
        $savedSessions = $global:DAEMON_SESSIONS
        $global:DAEMON_SESSIONS = @{}
        $savedStateDir = $global:PA_STATE_DIR
        $savedSessDir = $global:DAEMON_SESSIONS_DIR
        # Use temp dir for persistence
        $testDir = Join-Path $env:TEMP "pa_test_newsess_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_STATE_DIR = $testDir
        $global:DAEMON_SESSIONS_DIR = $null  # Force Initialize-SessionsDir to recalculate
    }
    AfterEach {
        $global:DAEMON_SESSIONS = $savedSessions
        Remove-Item $global:PA_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
        $global:PA_STATE_DIR = $savedStateDir
        $global:DAEMON_SESSIONS_DIR = $savedSessDir
    }

    It "Creates entry in DAEMON_SESSIONS" {
        New-DaemonSession
        $global:DAEMON_SESSIONS.Count | Should -Be 1
    }

    It "Returns StatusCode 201" {
        $result = New-DaemonSession
        $result.StatusCode | Should -Be 201
    }

    It "Returns body containing session_id" {
        $result = New-DaemonSession
        $parsed = $result.Body | ConvertFrom-Json
        $parsed.session_id | Should -Not -BeNullOrEmpty
    }

    It "Returns SessionId property" {
        $result = New-DaemonSession
        $result.SessionId | Should -Not -BeNullOrEmpty
        $result.SessionId | Should -Match "^sess_"
    }

    It "Session has status 'idle'" {
        New-DaemonSession | Out-Null
        $sessionId = $global:DAEMON_SESSIONS.Keys | Select-Object -First 1
        $global:DAEMON_SESSIONS[$sessionId].status | Should -Be "idle"
    }

    It "Session has created timestamp" {
        New-DaemonSession | Out-Null
        $sessionId = $global:DAEMON_SESSIONS.Keys | Select-Object -First 1
        $global:DAEMON_SESSIONS[$sessionId].created | Should -BeGreaterThan 0
    }

    It "Creates unique session IDs across multiple calls" {
        $r1 = New-DaemonSession
        $r2 = New-DaemonSession
        $r1.SessionId | Should -Not -Be $r2.SessionId
    }

    It "Accepts SystemPrompt parameter" {
        $result = New-DaemonSession -SystemPrompt "Custom system prompt"
        $session = $global:DAEMON_SESSIONS[$result.SessionId]
        $session.system_prompt | Should -Be "Custom system prompt"
    }

    It "Default SystemPrompt is empty string" {
        $result = New-DaemonSession
        $session = $global:DAEMON_SESSIONS[$result.SessionId]
        $session.system_prompt | Should -Be ""
    }

    It "Persists session to disk" {
        $result = New-DaemonSession
        $filePath = Join-Path $global:DAEMON_SESSIONS_DIR "$($result.SessionId).json"
        Test-Path $filePath | Should -Be $true
    }
}

# ============================================================================
#  4. Get-DaemonSessionList
# ============================================================================
Describe "Daemon — Get-DaemonSessionList" {
    BeforeEach {
        $savedSessions = $global:DAEMON_SESSIONS
        $global:DAEMON_SESSIONS = @{}
    }
    AfterEach {
        $global:DAEMON_SESSIONS = $savedSessions
    }

    It "Returns empty list when no sessions exist" {
        $list = Get-DaemonSessionList
        @($list).Count | Should -Be 0
    }

    It "Returns one entry after creating a session" {
        New-TestSession -Id "sess_list_1"
        $list = Get-DaemonSessionList
        @($list).Count | Should -Be 1
    }

    It "Each entry has id, status, message_count, created" {
        $session = New-TestSession -Id "sess_list_2" -Messages @(
            @{ role = "user"; content = "hi"; timestamp = 1 }
        )
        $list = Get-DaemonSessionList
        $entry = @($list)[0]
        $entry.id | Should -Be "sess_list_2"
        $entry.status | Should -Be "idle"
        $entry.message_count | Should -Be 1
        $entry.created | Should -BeGreaterThan 0
    }

    It "message_count is 0 for empty session" {
        New-TestSession -Id "sess_list_3"
        $list = Get-DaemonSessionList
        $entry = @($list) | Where-Object { $_.id -eq "sess_list_3" }
        $entry.message_count | Should -Be 0
    }
}

# ============================================================================
#  5. Invoke-DaemonChat (mocked API)
# ============================================================================
Describe "Daemon — Invoke-DaemonChat" {
    BeforeAll {
        # Mock Invoke-ApiCall to avoid real HTTP requests
        $global:mockApiResult = $null
        # Save original function definitions before mocking
        Save-FnDef -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
    }
    # Safety net: restore all mocked functions after this Describe finishes,
    # in case any It block's try/finally fails to restore
    AfterAll {
        Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
    }
    BeforeEach {
        $savedSessions = $global:DAEMON_SESSIONS
        $global:DAEMON_SESSIONS = @{}
        $savedMessages = $global:MESSAGES
        $global:MESSAGES = @()
        $savedStateDir = $global:PA_STATE_DIR
        $savedSessDir = $global:DAEMON_SESSIONS_DIR
        $testDir = Join-Path $env:TEMP "pa_test_chat_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_STATE_DIR = $testDir
        $global:DAEMON_SESSIONS_DIR = $null

        # Setup mock
        $global:mockApiResult = @{
            Success = $true
            ContentBlocks = @(@{ type = "text"; text = "Mock AI response" })
            StopReason = "end_turn"
            InputTokens = 50
            OutputTokens = 20
        }
    }
    AfterEach {
        $global:DAEMON_SESSIONS = $savedSessions
        $global:MESSAGES = $savedMessages
        Remove-Item $global:PA_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
        $global:PA_STATE_DIR = $savedStateDir
        $global:DAEMON_SESSIONS_DIR = $savedSessDir
    }

    It "Returns error for non-existent session" {
        $result = Invoke-DaemonChat -SessionId "sess_nonexistent" -UserMessage "test"
        $result.success | Should -Be $false
        $result.error | Should -Match "Session not found"
    }

    It "Calls API and returns success result" {
        # Override Invoke-ApiCall with mock
        $originalCmd = Get-Command Invoke-ApiCall -ErrorAction SilentlyContinue
        function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) $global:mockApiResult }
        function global:Get-ApiHeaders { @{ "Authorization" = "Bearer test" } }
        function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }

        try {
            New-TestSession -Id "sess_chat_001"
            $result = Invoke-DaemonChat -SessionId "sess_chat_001" -UserMessage "Hello"
            $result.success | Should -Be $true
            $result.content | Should -Be "Mock AI response"
            $result.stop_reason | Should -Be "end_turn"
            $result.input_tokens | Should -Be 50
            $result.output_tokens | Should -Be 20
        } finally {
            # Restore original functions (scope fix: don't Remove-Item)
            Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
        }
    }

    It "Appends user and assistant messages to session" {
        function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) $global:mockApiResult }
        function global:Get-ApiHeaders { @{ "Authorization" = "Bearer test" } }
        function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }

        try {
            New-TestSession -Id "sess_chat_002"
            Invoke-DaemonChat -SessionId "sess_chat_002" -UserMessage "Hello" | Out-Null
            $session = $global:DAEMON_SESSIONS["sess_chat_002"]
            @($session.messages).Count | Should -Be 2
            $session.messages[0].role | Should -Be "user"
            $session.messages[0].content | Should -Be "Hello"
            $session.messages[1].role | Should -Be "assistant"
            $session.messages[1].content | Should -Be "Mock AI response"
        } finally {
            Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
        }
    }

    It "Sets session status to idle on success" {
        function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) $global:mockApiResult }
        function global:Get-ApiHeaders { @{ "Authorization" = "Bearer test" } }
        function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }

        try {
            New-TestSession -Id "sess_chat_003"
            Invoke-DaemonChat -SessionId "sess_chat_003" -UserMessage "Hi" | Out-Null
            $global:DAEMON_SESSIONS["sess_chat_003"].status | Should -Be "idle"
        } finally {
            Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
        }
    }

    It "Sets session status to error on API failure" {
        $global:mockApiResult = @{
            Success = $false
            Error = "Connection refused"
        }
        function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) $global:mockApiResult }
        function global:Get-ApiHeaders { @{ "Authorization" = "Bearer test" } }
        function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }

        try {
            New-TestSession -Id "sess_chat_004"
            $result = Invoke-DaemonChat -SessionId "sess_chat_004" -UserMessage "Hello"
            $result.success | Should -Be $false
            $result.error | Should -Match "Connection refused"
            $global:DAEMON_SESSIONS["sess_chat_004"].status | Should -Be "error"
        } finally {
            Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
        }
    }

    It "Restores global MESSAGES after call" {
        function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) $global:mockApiResult }
        function global:Get-ApiHeaders { @{ "Authorization" = "Bearer test" } }
        function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }

        try {
            $global:MESSAGES = @(@{ role = "system"; content = "original" })
            New-TestSession -Id "sess_chat_005"
            Invoke-DaemonChat -SessionId "sess_chat_005" -UserMessage "test" | Out-Null
            $global:MESSAGES.Count | Should -Be 1
            $global:MESSAGES[0].content | Should -Be "original"
        } finally {
            Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
        }
    }

    It "Preserves existing message history in session" {
        function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) $global:mockApiResult }
        function global:Get-ApiHeaders { @{ "Authorization" = "Bearer test" } }
        function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }

        try {
            New-TestSession -Id "sess_chat_006" -Messages @(
                @{ role = "user"; content = "Previous question"; timestamp = 100 }
                @{ role = "assistant"; content = "Previous answer"; timestamp = 101 }
            )
            Invoke-DaemonChat -SessionId "sess_chat_006" -UserMessage "Follow up" | Out-Null
            $session = $global:DAEMON_SESSIONS["sess_chat_006"]
            @($session.messages).Count | Should -Be 4  # 2 existing + user + assistant
        } finally {
            Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody")
        }
    }
}

# ============================================================================
#  6. Invoke-GatewayRoute (all 10 endpoints)
# ============================================================================
Describe "Daemon — Invoke-GatewayRoute" {
    BeforeAll {
        # Save original function definitions before mocking
        Save-FnDef -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody", "Invoke-DaemonChat")
    }
    # Safety net: restore all mocked functions after this Describe finishes
    AfterAll {
        Restore-FnDefs -Names @("Invoke-ApiCall", "Get-ApiHeaders", "Build-ApiRequestBody", "Invoke-DaemonChat")
    }
    BeforeEach {
        $savedSessions = $global:DAEMON_SESSIONS
        $global:DAEMON_SESSIONS = @{}
        $global:CRON_JOBS = @{}
        $savedStateDir = $global:PA_STATE_DIR
        $savedSessDir = $global:DAEMON_SESSIONS_DIR
        $testDir = Join-Path $env:TEMP "pa_test_gw_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_STATE_DIR = $testDir
        $global:DAEMON_SESSIONS_DIR = $null  # Force recalculation
    }
    AfterEach {
        $global:DAEMON_SESSIONS = $savedSessions
        $global:PA_STATE_DIR = $savedStateDir
        $global:DAEMON_SESSIONS_DIR = $savedSessDir
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "POST /v1/session/new" {
        It "Returns 201" {
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/session/new" -Body $null
            $result.StatusCode | Should -Be 201
        }

        It "Creates session in DAEMON_SESSIONS" {
            Invoke-GatewayRoute -Method "POST" -Path "/v1/session/new" -Body $null | Out-Null
            @($global:DAEMON_SESSIONS.Keys).Count | Should -Be 1
        }

        It "Body contains session_id" {
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/session/new" -Body $null
            $result.Body | Should -Match '"session_id"'
        }
    }

    Context "POST /v1/chat" {
        It "Returns 400 when body is empty" {
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/chat" -Body $null
            $result.StatusCode | Should -Be 400
        }

        It "Returns 400 when message is missing" {
            $body = @{ foo = "bar" } | ConvertTo-Json
            $mockBody = @{ HasEntityBody = $true; InputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body)); ContentEncoding = [System.Text.Encoding]::UTF8 }
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/chat" -Body $mockBody
            $result.StatusCode | Should -Be 400
        }

        It "Calls Invoke-DaemonChat with valid body" {
            # Mock chat execution
            function global:Invoke-DaemonChat {
                param($SessionId, $UserMessage)
                return @{ success = $true; content = "AI says hi"; stop_reason = "end_turn"; input_tokens = 10; output_tokens = 5 }
            }
            function global:Get-ApiHeaders { @{} }
            function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }
            function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) @{ Success = $true; ContentBlocks = @(); StopReason = "end_turn"; InputTokens = 0; OutputTokens = 0 } }

            try {
                $body = @{ message = "Hello" } | ConvertTo-Json
                $mockBody = @{ HasEntityBody = $true; InputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body)); ContentEncoding = [System.Text.Encoding]::UTF8 }
                $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/chat" -Body $mockBody
                $result.StatusCode | Should -Be 200
                $result.Body | Should -Match "session_id"
                $result.Body | Should -Match "AI says hi"
            } finally {
                Restore-FnDefs -Names @("Invoke-DaemonChat", "Get-ApiHeaders", "Build-ApiRequestBody", "Invoke-ApiCall")
            }
        }
    }

    Context "GET /v1/sessions" {
        It "Returns 200" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/sessions" -Body $null
            $result.StatusCode | Should -Be 200
        }

        It "Returns JSON body" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/sessions" -Body $null
            $result.Body | Should -Not -BeNullOrEmpty
        }
    }

    Context "POST /v1/session/{id}" {
        It "Returns 404 for non-existent session" {
            $body = @{ message = "test" } | ConvertTo-Json
            $mockBody = @{ HasEntityBody = $true; InputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body)); ContentEncoding = [System.Text.Encoding]::UTF8 }
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/session/sess_fake" -Body $mockBody
            $result.StatusCode | Should -Be 404
        }

        It "Returns 400 when body is empty for existing session" {
            New-TestSession -Id "sess_gw_001"
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/session/sess_gw_001" -Body $null
            $result.StatusCode | Should -Be 400
        }

        It "Executes chat for existing session with valid body" {
            function global:Invoke-DaemonChat {
                param($SessionId, $UserMessage)
                return @{ success = $true; content = "Session response"; stop_reason = "end_turn"; input_tokens = 10; output_tokens = 5 }
            }
            function global:Get-ApiHeaders { @{} }
            function global:Build-ApiRequestBody { param($UserMessage, $Tools, $MaxTokens, $ThinkingBudget, $SystemPrompt) "{}" }
            function global:Invoke-ApiCall { param($RequestBody, $Url, $Headers) @{ Success = $true; ContentBlocks = @(); StopReason = "end_turn"; InputTokens = 0; OutputTokens = 0 } }

            try {
                New-TestSession -Id "sess_gw_002"
                $body = @{ message = "Hello session" } | ConvertTo-Json
                $mockBody = @{ HasEntityBody = $true; InputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body)); ContentEncoding = [System.Text.Encoding]::UTF8 }
                $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/session/sess_gw_002" -Body $mockBody
                $result.StatusCode | Should -Be 200
                $result.Body | Should -Match "Session response"
            } finally {
                Restore-FnDefs -Names @("Invoke-DaemonChat", "Get-ApiHeaders", "Build-ApiRequestBody", "Invoke-ApiCall")
            }
        }
    }

    Context "GET /v1/session/{id}" {
        It "Returns 404 for non-existent session" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/session/sess_nope" -Body $null
            $result.StatusCode | Should -Be 404
        }

        It "Returns session detail with messages" {
            New-TestSession -Id "sess_detail_001" -Messages @(
                @{ role = "user"; content = "Q1"; timestamp = 100 }
                @{ role = "assistant"; content = "A1"; timestamp = 101 }
            )
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/session/sess_detail_001" -Body $null
            $result.StatusCode | Should -Be 200
            $result.Body | Should -Match "sess_detail_001"
            $result.Body | Should -Match "Q1"
            $result.Body | Should -Match "A1"
        }

        It "Returns message_count in response" {
            New-TestSession -Id "sess_detail_002" -Messages @(
                @{ role = "user"; content = "hi"; timestamp = 100 }
            )
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/session/sess_detail_002" -Body $null
            $result.Body | Should -Match "message_count"
        }
    }

    Context "DELETE /v1/session/{id}" {
        It "Returns 204" {
            $result = Invoke-GatewayRoute -Method "DELETE" -Path "/v1/session/sess_any" -Body $null
            $result.StatusCode | Should -Be 204
        }

        It "Removes session from DAEMON_SESSIONS" {
            New-TestSession -Id "sess_del_gw"
            @($global:DAEMON_SESSIONS.Keys).Count | Should -Be 1
            Invoke-GatewayRoute -Method "DELETE" -Path "/v1/session/sess_del_gw" -Body $null | Out-Null
            $global:DAEMON_SESSIONS.ContainsKey("sess_del_gw") | Should -Be $false
        }
    }

    Context "GET / (index page)" {
        It "Returns 200 with HTML" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/" -Body $null
            $result.StatusCode | Should -Be 200
            $result.Body | Should -Match "(?i)<html"
        }

        It "Contains PowerAgent branding" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/" -Body $null
            $result.Body | Should -Match "PowerAgent"
        }

        It "Contains all endpoint paths" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/" -Body $null
            $result.Body | Should -Match "/v1/session/new"
            $result.Body | Should -Match "/v1/chat"
            $result.Body | Should -Match "/v1/sessions"
            $result.Body | Should -Match "/v1/session/"
            $result.Body | Should -Match "/v1/cron"
        }

        It "Contains session and cron counts" {
            New-TestSession -Id "sess_idx"
            $result = Invoke-GatewayRoute -Method "GET" -Path "/" -Body $null
            $result.Body | Should -Match "Sessions"
            $result.Body | Should -Match "Cron Jobs"
        }
    }

    Context "GET /v1/cron" {
        It "Returns 200 with cron status" {
            $global:CRON_JOBS = @{
                "test-job" = @{ name = "test-job"; expression = "*/5m"; parsed = @{ type = "interval"; intervalMs = 300000 }; prompt = "test"; lastRun = 0; runCount = 0; enabled = $true; lastResult = ""; lastError = "" }
            }
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/cron" -Body $null
            $result.StatusCode | Should -Be 200
            $result.Body | Should -Match "test-job"
        }
    }

    Context "POST /v1/cron" {
        It "Returns 400 when body is empty" {
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/cron" -Body $null
            $result.StatusCode | Should -Be 400
        }

        It "Returns 400 when prompt is missing" {
            $body = @{ name = "no-prompt"; expression = "*/1m" } | ConvertTo-Json
            $mockBody = @{ HasEntityBody = $true; InputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body)); ContentEncoding = [System.Text.Encoding]::UTF8 }
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/cron" -Body $mockBody
            $result.StatusCode | Should -Be 400
        }

        It "Registers cron job and returns 201" {
            $body = @{ name = "test-cron-reg"; expression = "*/10m"; prompt = "test cron prompt" } | ConvertTo-Json
            $mockBody = @{ HasEntityBody = $true; InputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($body)); ContentEncoding = [System.Text.Encoding]::UTF8 }
            $result = Invoke-GatewayRoute -Method "POST" -Path "/v1/cron" -Body $mockBody
            $result.StatusCode | Should -Be 201
            $result.Body | Should -Match "registered"
            $result.Body | Should -Match "test-cron-reg"
            $global:CRON_JOBS.ContainsKey("test-cron-reg") | Should -Be $true
        }
    }

    Context "Unknown routes" {
        It "Returns 404 for GET /nonexistent" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/nonexistent" -Body $null
            $result.StatusCode | Should -Be 404
        }

        It "Returns 404 for GET /v1/unknown" {
            $result = Invoke-GatewayRoute -Method "GET" -Path "/v1/unknown" -Body $null
            $result.StatusCode | Should -Be 404
        }
    }
}

# ============================================================================
#  7. Get-DaemonIndexPage
# ============================================================================
Describe "Daemon — Get-DaemonIndexPage" {
    BeforeEach {
        $savedSessions = $global:DAEMON_SESSIONS
        $global:DAEMON_SESSIONS = @{}
        $savedCron = $global:CRON_JOBS
        $global:CRON_JOBS = @{}
    }
    AfterEach {
        $global:DAEMON_SESSIONS = $savedSessions
        $global:CRON_JOBS = $savedCron
    }

    It "Returns non-empty string" {
        $html = Get-DaemonIndexPage
        $html | Should -Not -BeNullOrEmpty
    }

    It "Contains HTML structure" {
        $html = Get-DaemonIndexPage
        $html | Should -Match "(?i)<html"
        $html | Should -Match "(?i)</html>"
    }

    It "Shows 0 sessions when empty" {
        $html = Get-DaemonIndexPage
        $html | Should -Match ">0<"
    }

    It "Shows session count" {
        New-TestSession -Id "sess_page_1"
        New-TestSession -Id "sess_page_2"
        $html = Get-DaemonIndexPage
        $html | Should -Match ">2<"
    }

    It "Contains curl examples" {
        $html = Get-DaemonIndexPage
        $html | Should -Match "curl"
    }
}

# ============================================================================
#  8. Stop-Daemon
# ============================================================================
Describe "Daemon — Stop-Daemon" {
    It "Sets DAEMON_RUNNING to false" {
        $global:DAEMON_RUNNING = $true
        Stop-Daemon
        $global:DAEMON_RUNNING | Should -Be $false
    }

    It "Leaves DAEMON_RUNNING as false when already stopped" {
        $global:DAEMON_RUNNING = $false
        Stop-Daemon
        $global:DAEMON_RUNNING | Should -Be $false
    }
}

# ============================================================================
#  9. Cron — Parse-CronExpression
# ============================================================================
Describe "Daemon — Parse-CronExpression (interval format)" {
    It "Parses seconds interval" {
        $result = Parse-CronExpression "*/10 s"
        $result.type | Should -Be "interval"
        $result.intervalMs | Should -Be 10000
    }

    It "Parses minutes interval" {
        $result = Parse-CronExpression "*/5 m"
        $result.intervalMs | Should -Be 300000
    }

    It "Parses hours interval" {
        $result = Parse-CronExpression "*/2 h"
        $result.intervalMs | Should -Be 7200000
    }

    It "Parses compact format */5m" {
        $result = Parse-CronExpression "*/5m"
        $result.type | Should -Be "interval"
        $result.intervalMs | Should -Be 300000
    }

    It "Defaults to 5m for invalid format" {
        $result = Parse-CronExpression "invalid"
        $result.type | Should -Be "interval"
        $result.intervalMs | Should -Be 300000
    }
}

Describe "Daemon — Parse-CronExpression (5-field format)" {
    It "Parses 'every minute' pattern" {
        $result = Parse-CronExpression "* * * * *"
        $result.type | Should -Be "cron5"
        $result.minute | Should -BeNullOrEmpty  # null = match all
        $result.hour | Should -BeNullOrEmpty
    }

    It "Parses 'every hour at :30' pattern" {
        $result = Parse-CronExpression "30 * * * *"
        $result.type | Should -Be "cron5"
        @($result.minute) | Should -Contain 30
    }

    It "Parses '9am daily' pattern" {
        $result = Parse-CronExpression "0 9 * * *"
        $result.type | Should -Be "cron5"
        @($result.minute) | Should -Contain 0
        @($result.hour) | Should -Contain 9
    }

    It "Parses range in field" {
        $result = Parse-CronExpression "0 9-17 * * *"
        $result.hour | Should -Contain 9
        $result.hour | Should -Contain 12
        $result.hour | Should -Contain 17
    }

    It "Parses comma-separated list" {
        $result = Parse-CronExpression "0 9,12,18 * * *"
        @($result.hour).Count | Should -Be 3
        $result.hour | Should -Contain 9
        $result.hour | Should -Contain 12
        $result.hour | Should -Contain 18
    }

    It "Parses step expression */15 for minutes" {
        $result = Parse-CronExpression "*/15 * * * *"
        $result.minute | Should -Contain 0
        $result.minute | Should -Contain 15
        $result.minute | Should -Contain 30
        $result.minute | Should -Contain 45
    }
}

# ============================================================================
#  10. Cron — Invoke-ParseCronField
# ============================================================================
Describe "Daemon — Invoke-ParseCronField" {
    It "Returns null for wildcard '*'" {
        $result = Invoke-ParseCronField "*" 0 59
        $result | Should -BeNullOrEmpty
    }

    It "Returns single value for exact number" {
        $result = Invoke-ParseCronField "30" 0 59
        $result | Should -Be @(30)
    }

    It "Returns range of values for N-M" {
        $result = Invoke-ParseCronField "1-5" 0 59
        $result | Should -Contain 1
        $result | Should -Contain 3
        $result | Should -Contain 5
        @($result).Count | Should -Be 5
    }

    It "Returns comma-separated values" {
        $result = Invoke-ParseCronField "1,3,5" 0 59
        @($result).Count | Should -Be 3
        $result | Should -Contain 1
        $result | Should -Contain 3
        $result | Should -Contain 5
    }

    It "Returns step values for */N" {
        $result = Invoke-ParseCronField "*/15" 0 59
        $result | Should -Contain 0
        $result | Should -Contain 15
        $result | Should -Contain 30
        $result | Should -Contain 45
    }

    It "Returns range+step for N-M/S" {
        $result = Invoke-ParseCronField "0-30/10" 0 59
        $result | Should -Contain 0
        $result | Should -Contain 10
        $result | Should -Contain 20
        $result | Should -Contain 30
    }

    It "Deduplicates values" {
        $result = Invoke-ParseCronField "5,5,5" 0 59
        @($result).Count | Should -Be 1
    }

    It "Sorts values" {
        $result = Invoke-ParseCronField "30,10,20" 0 59
        $result[0] | Should -Be 10
        $result[1] | Should -Be 20
        $result[2] | Should -Be 30
    }
}

# ============================================================================
#  11. Cron — Test-CronMatch
# ============================================================================
Describe "Daemon — Test-CronMatch" {
    Context "Interval type" {
        It "Returns true when interval has elapsed" {
            $parsed = @{ type = "interval"; intervalMs = 1000 }
            $lastRun = (Get-TimestampMs) - 5000  # 5s ago
            Test-CronMatch -Parsed $parsed -LastRunMs $lastRun | Should -Be $true
        }

        It "Returns false when interval has NOT elapsed" {
            $parsed = @{ type = "interval"; intervalMs = 3600000 }  # 1 hour
            $lastRun = (Get-TimestampMs) - 1000  # 1s ago
            Test-CronMatch -Parsed $parsed -LastRunMs $lastRun | Should -Be $false
        }

        It "Returns true when lastRun is 0 (never ran)" {
            $parsed = @{ type = "interval"; intervalMs = 60000 }
            Test-CronMatch -Parsed $parsed -LastRunMs 0 | Should -Be $true
        }
    }

    Context "5-field cron type" {
        It "Matches current time with wildcard pattern" {
            $parsed = @{
                type = "cron5"
                minute = $null  # match all
                hour = $null
                dom = $null
                month = $null
                dow = $null
            }
            Test-CronMatch -Parsed $parsed -LastRunMs 0 | Should -Be $true
        }

        It "Does not match when minute field excludes current minute" {
            $now = Get-Date
            $wrongMinute = ($now.Minute + 30) % 60
            $parsed = @{
                type = "cron5"
                minute = @($wrongMinute)
                hour = $null
                dom = $null
                month = $null
                dow = $null
            }
            Test-CronMatch -Parsed $parsed -LastRunMs 0 | Should -Be $false
        }

        It "Prevents double-fire within same minute" {
            $parsed = @{
                type = "cron5"
                minute = $null
                hour = $null
                dom = $null
                month = $null
                dow = $null
            }
            # Set lastRun to current time (same minute)
            $lastRun = Get-TimestampMs
            Test-CronMatch -Parsed $parsed -LastRunMs $lastRun | Should -Be $false
        }
    }
}

# ============================================================================
#  12. Cron — Register-CronJob
# ============================================================================
Describe "Daemon — Register-CronJob" {
    BeforeEach {
        $savedCron = $global:CRON_JOBS
        $global:CRON_JOBS = @{}
    }
    AfterEach {
        $global:CRON_JOBS = $savedCron
    }

    It "Registers a job with interval expression" {
        Register-CronJob -Name "test-interval" -Expression "*/5m" -Prompt "interval test"
        $global:CRON_JOBS["test-interval"] | Should -Not -BeNullOrEmpty
        $global:CRON_JOBS["test-interval"].prompt | Should -Be "interval test"
        $global:CRON_JOBS["test-interval"].enabled | Should -Be $true
    }

    It "Registers a job with 5-field expression" {
        Register-CronJob -Name "test-cron5" -Expression "0 9 * * *" -Prompt "daily at 9"
        $job = $global:CRON_JOBS["test-cron5"]
        $job | Should -Not -BeNullOrEmpty
        $job.parsed.type | Should -Be "cron5"
    }

    It "Stores parsed expression" {
        Register-CronJob -Name "test-parsed" -Expression "*/10m" -Prompt "parsed test"
        $job = $global:CRON_JOBS["test-parsed"]
        $job.parsed | Should -Not -BeNullOrEmpty
        $job.parsed.type | Should -Be "interval"
    }

    It "Initializes runCount, lastResult, lastError" {
        Register-CronJob -Name "test-fields" -Expression "*/1m" -Prompt "field test"
        $job = $global:CRON_JOBS["test-fields"]
        $job.runCount | Should -Be 0
        $job.lastResult | Should -Be ""
        $job.lastError | Should -Be ""
    }

    It "Overwrites existing job" {
        Register-CronJob -Name "test-ovr" -Expression "*/1m" -Prompt "v1"
        Register-CronJob -Name "test-ovr" -Expression "*/2m" -Prompt "v2"
        $global:CRON_JOBS["test-ovr"].prompt | Should -Be "v2"
        $global:CRON_JOBS["test-ovr"].intervalMs | Should -Be 120000
    }

    It "Respects Enabled parameter" {
        Register-CronJob -Name "test-disabled" -Expression "*/5m" -Prompt "disabled" -Enabled:$false
        $global:CRON_JOBS["test-disabled"].enabled | Should -Be $false
    }
}

# ============================================================================
#  13. Cron — Get-CronStatus
# ============================================================================
Describe "Daemon — Get-CronStatus" {
    BeforeEach {
        $savedCron = $global:CRON_JOBS
        $global:CRON_JOBS = @{}
    }
    AfterEach {
        $global:CRON_JOBS = $savedCron
    }

    It "Returns empty array when no jobs" {
        $status = Get-CronStatus
        @($status).Count | Should -Be 0
    }

    It "Returns job status with all fields" {
        Register-CronJob -Name "status-test" -Expression "*/5m" -Prompt "status"
        $status = Get-CronStatus
        @($status).Count | Should -Be 1
        $entry = @($status)[0]
        $entry.name | Should -Be "status-test"
        $entry.expression | Should -Be "*/5m"
        $entry.type | Should -Be "interval"
        $entry.enabled | Should -Be $true
        $entry.lastResult | Should -Not -Be $null  # initialized as empty string
        $entry.lastError | Should -Not -Be $null
    }

    It "Reflects execution results" {
        Register-CronJob -Name "result-test" -Expression "*/1m" -Prompt "result"
        $global:CRON_JOBS["result-test"].lastResult = "AI output"
        $global:CRON_JOBS["result-test"].runCount = 3
        $status = Get-CronStatus
        $entry = @($status)[0]
        $entry.lastResult | Should -Be "AI output"
        $entry.runCount | Should -Be 3
    }
}

# ============================================================================
#  14. Cron — Stop-CronScheduler
# ============================================================================
Describe "Daemon — Stop-CronScheduler" {
    It "Does not throw when no timer exists" {
        $global:CRON_TIMER = $null
        { Stop-CronScheduler } | Should -Not -Throw
    }
}
