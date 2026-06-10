# ============================================================================
#  PowerAgent Test — McpClient Integration
#  Comprehensive MCP tests using @modelcontextprotocol/server-everything
#  Covers: JSON-RPC, config, transport, handshake, tools, dispatch, cleanup
#
#  BUGS FOUND (tracked in test descriptions):
#   BUG-WIN-NPX: Connect-McpStdio uses bare "npx" as ProcessStartInfo.FileName
#                 which fails on Windows (npx is npx.cmd, not an .exe). FIXED —
#                 Connect-McpStdio now detects .cmd commands on Windows and wraps
#                 them with "cmd.exe /c" automatically.
#   BUG-RECV-STDIO: Receive-McpStdio ReadLineAsync+WaitAny(500ms) pattern
#                    re-entered ReadLineAsync while previous Task was pending,
#                    causing "stream currently in use" exception. FIXED —
#                    now uses single Task with remaining-timeout wait.
#   BUG-ARGS-RESERVED: Invoke-McpCallTool used $Args as parameter name,
#                       which collides with PowerShell's automatic $args variable,
#                       causing hashtable arguments to be received as Object[]
#                       and server to reject with "expected record, received array".
#                       FIXED — renamed parameter to $Arguments.
# ============================================================================

# ── Helper: Start server-everything as a subprocess ──
function script:Start-McpTestServer {
    param(
        [int]$WaitSeconds = 8
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    # Windows: npx is npx.cmd, must use cmd.exe as wrapper
    if ($IsWindows -or $env:OS -match "Windows") {
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c npx -y @modelcontextprotocol/server-everything stdio"
    } else {
        $psi.FileName = "npx"
        $psi.Arguments = "-y @modelcontextprotocol/server-everything stdio"
    }

    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Seconds $WaitSeconds

    if ($proc.HasExited) {
        $err = $proc.StandardError.ReadToEnd()
        return @{ Success = $false; Process = $null; Error = $err }
    }

    return @{ Success = $true; Process = $proc; Error = "" }
}

# ── Helper: Send JSON-RPC and read ONE response line ──
function script:Send-JsonRpc {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Json,
        [int]$ReadTimeoutMs = 8000
    )

    $Process.StandardInput.WriteLine($Json)
    $Process.StandardInput.Flush()

    # Read with timeout — keep trying until we get a valid JSON line
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($ReadTimeoutMs)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $readTask = $Process.StandardOutput.ReadLineAsync()
        $remaining = [int][Math]::Max(100, ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
        $waited = [System.Threading.Tasks.Task]::WaitAny(@($readTask), $remaining)
        if ($waited -ge 0) {
            $line = $readTask.Result
            if ($line -and $line.Trim().StartsWith("{")) {
                return $line
            }
            # Skip non-JSON lines (blank lines, stderr bleed)
            continue
        }
        break
    }
    return $null
}

# ── Helper: Read multiple response lines until we find the one matching id ──
function script:Send-JsonRpcReadUntilId {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Json,
        [int]$TargetId,
        [int]$TimeoutMs = 15000
    )

    $Process.StandardInput.WriteLine($Json)
    $Process.StandardInput.Flush()

    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $readTask = $Process.StandardOutput.ReadLineAsync()
        $remaining = [int][Math]::Max(100, ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)
        $waited = [System.Threading.Tasks.Task]::WaitAny(@($readTask), $remaining)
        if ($waited -ge 0) {
            $line = $readTask.Result
            if ($line -and $line.Trim().StartsWith("{")) {
                try {
                    $parsed = $line | ConvertFrom-Json
                    if ($parsed.id -eq $TargetId) {
                        return $line
                    }
                } catch { }
                # Not our response — skip (could be a notification)
                continue
            }
            continue
        }
        break
    }
    return $null
}

# ── Helper: Build JSON-RPC request ──
function script:Build-JsonRpcRequest {
    param([string]$Method, $Params, [int]$Id = 1)
    $req = @{ jsonrpc = "2.0"; method = $Method; id = $Id }
    if ($null -ne $Params) { $req["params"] = $Params }
    return $req | ConvertTo-Json -Depth 10 -Compress
}

# ============================================================================
#  1. JSON-RPC 2.0 Primitives — Extended
# ============================================================================
Describe "McpClient — JSON-RPC 2.0 Primitives (Extended)" {
    BeforeAll {
        $savedNextId = $global:MCP_NEXT_REQUEST_ID
        $global:MCP_NEXT_REQUEST_ID = 1
    }
    AfterAll {
        $global:MCP_NEXT_REQUEST_ID = $savedNextId
    }

    Context "New-McpRequest" {
        It "Creates request with empty params defaults to empty hashtable" {
            $req = New-McpRequest "test"
            $req.params -is [hashtable] | Should -BeTrue
            $req.params.Count | Should -Be 0
        }

        It "Auto-increments ID sequentially" {
            $req1 = New-McpRequest "m1" @{}
            $req2 = New-McpRequest "m2" @{}
            $req3 = New-McpRequest "m3" @{}
            $req2.id | Should -Be ($req1.id + 1)
            $req3.id | Should -Be ($req2.id + 1)
        }

        It "Handles JSON string params with nested objects" {
            $jsonParams = '{"level1":{"level2":"value","arr":[1,2,3]}}'
            $req = New-McpRequest "test" $jsonParams
            $req.params.level1.level2 | Should -Be "value"
            @($req.params.level1.arr).Count | Should -Be 3
        }

        It "Handles invalid JSON string params gracefully (falls back to empty)" {
            $req = New-McpRequest "test" "not-json{{{"
            $req.params -is [hashtable] | Should -BeTrue
        }

        It "Sets jsonrpc version to 2.0" {
            $req = New-McpRequest "test" @{}
            $req.jsonrpc | Should -Be "2.0"
        }

        It "Preserves method name" {
            $req = New-McpRequest "tools/call" @{}
            $req.method | Should -Be "tools/call"
        }
    }

    Context "New-McpNotification" {
        It "Does NOT contain an id field" {
            $notif = New-McpNotification "notifications/initialized" @{}
            $notif.ContainsKey("id") | Should -BeFalse
        }

        It "Preserves params with multiple keys" {
            $notif = New-McpNotification "test" @{ a = 1; b = "two"; c = $true }
            $notif.params.a | Should -Be 1
            $notif.params.b | Should -Be "two"
            $notif.params.c | Should -Be $true
        }

        It "Converts to valid JSON without id" {
            $notif = New-McpNotification "test" @{}
            $json = $notif | ConvertTo-Json -Depth 5
            $json | Should -Not -Match '"id"'
            $json | Should -Match '"jsonrpc"'
            $json | Should -Match '"method"'
        }
    }
}

# ============================================================================
#  2. MCP Config Loading — Extended Edge Cases
# ============================================================================
Describe "McpClient — Config Loading (Extended)" {
    BeforeEach {
        $global:MCP_SERVERS = @{}
        $savedEnvMcp = $env:PA_MCP_SERVERS
    }
    AfterEach {
        $env:PA_MCP_SERVERS = $savedEnvMcp
    }

    It "Parses multiple servers from environment" {
        $env:PA_MCP_SERVERS = '{"srv1":{"command":"cmd1","transport":"stdio"},"srv2":{"command":"cmd2","transport":"http","url":"http://localhost:3000"}}'
        Import-McpConfig
        $global:MCP_SERVERS.Count | Should -Be 2
        $global:MCP_SERVERS.ContainsKey("srv1") | Should -BeTrue
        $global:MCP_SERVERS.ContainsKey("srv2") | Should -BeTrue
    }

    It "Preserves server config with env vars" {
        $env:PA_MCP_SERVERS = '{"test_server":{"command":"npx","args":["-y","some-mcp"],"env":{"API_KEY":"secret123"},"transport":"stdio"}}'
        Import-McpConfig
        $cfg = $global:MCP_SERVERS["test_server"] | ConvertFrom-Json
        $cfg.command | Should -Be "npx"
        @($cfg.args).Count | Should -Be 2
        $cfg.env.API_KEY | Should -Be "secret123"
    }

    It "Handles null mcp_servers value" {
        $env:PA_MCP_SERVERS = "null"
        Import-McpConfig
        $global:MCP_SERVERS.Count | Should -Be 0
    }

    It "Handles empty string mcp_servers" {
        $env:PA_MCP_SERVERS = ""
        Import-McpConfig
        $global:MCP_SERVERS.Count | Should -Be 0
    }

    It "Handles deeply nested server config" {
        $env:PA_MCP_SERVERS = '{"deep":{"command":"test","transport":"http","url":"http://x","headers":{"Authorization":"Bearer tok","X-Custom":"val"}}}'
        Import-McpConfig
        $cfg = $global:MCP_SERVERS["deep"] | ConvertFrom-Json
        $cfg.headers.Authorization | Should -Be "Bearer tok"
        $cfg.headers."X-Custom" | Should -Be "val"
    }
}

# ============================================================================
#  3. Transport Abstraction — Unit Tests
# ============================================================================
Describe "McpClient — Transport Abstraction (Unit)" {
    Context "Connect-McpServer dispatch" {
        BeforeEach {
            $global:MCP_SERVERS = @{}
        }

        It "Returns false for missing server config" {
            Connect-McpServer "nonexistent" | Should -BeFalse
        }

        It "Returns false for unknown transport type" {
            $global:MCP_SERVERS["bad"] = '{"transport":"websocket"}'
            Connect-McpServer "bad" | Should -BeFalse
        }

        It "Returns false for stdio with missing command" {
            $global:MCP_SERVERS["nocmd"] = '{"transport":"stdio","args":["-y","something"]}'
            Connect-McpServer "nocmd" | Should -BeFalse
        }

        It "Returns false for SSE with missing URL" {
            $global:MCP_SERVERS["nourl"] = '{"transport":"sse"}'
            Connect-McpServer "nourl" | Should -BeFalse
        }

        It "Returns false for HTTP with missing URL" {
            $global:MCP_SERVERS["nohttpurl"] = '{"transport":"http"}'
            Connect-McpServer "nohttpurl" | Should -BeFalse
        }
    }

    Context "Disconnect-McpServer" {
        It "Does not throw for nonexistent server" {
            { Disconnect-McpServer "ghost" } | Should -Not -Throw
        }

        It "Cleans up all state entries for a connected server" {
            $name = "test_cleanup"
            $global:MCP_SERVER_PID[$name] = -1
            $global:MCP_SERVER_DIR[$name] = Join-Path $env:TEMP "poweragent_mcp_${name}_dummy"
            $global:MCP_SERVER_TOOLS[$name] = "[]"
            $global:MCP_SERVER_CAPS[$name] = "{}"
            $global:MCP_SERVER_READY[$name] = $true
            $global:MCP_SERVER_URL[$name] = "http://dummy"
            $global:MCP_SERVER_TRANSPORT[$name] = "http"
            $global:MCP_SERVER_PROC[$name] = $null
            $global:MCP_STREAM_WRITER[$name] = $null
            $global:MCP_STREAM_READER[$name] = $null

            Disconnect-McpServer $name

            $global:MCP_SERVER_PID.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_DIR.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_TOOLS.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_CAPS.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_READY.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_URL.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_TRANSPORT.ContainsKey($name) | Should -BeFalse
            $global:MCP_SERVER_PROC.ContainsKey($name) | Should -BeFalse
            $global:MCP_STREAM_WRITER.ContainsKey($name) | Should -BeFalse
            $global:MCP_STREAM_READER.ContainsKey($name) | Should -BeFalse
        }
    }
}

# ============================================================================
#  4. MCP Protocol Handshake — Live Integration (single session)
# ============================================================================
Describe "McpClient — Live MCP Handshake (server-everything)" -Tag "McpLive" {
    BeforeAll {
        $npxCmd = Get-Command npx -ErrorAction SilentlyContinue
        if (-not $npxCmd) {
            return  # All tests in this Describe will be skipped
        }

        $script:serverResult = Start-McpTestServer -WaitSeconds 8
        if (-not $script:serverResult.Success) {
            Write-Host "  [SKIP] Could not start server-everything" -ForegroundColor Yellow
            return
        }
        $script:serverProc = $script:serverResult.Process
        $script:rpcId = 0

        # Perform ONE initialize handshake
        $script:rpcId++
        $initReq = Build-JsonRpcRequest "initialize" @{
            protocolVersion = "2024-11-05"
            capabilities    = @{ tools = @{} }
            clientInfo      = @{ name = "poweragent-test"; version = "0.1" }
        } $script:rpcId
        $initResp = Send-JsonRpc $script:serverProc $initReq 10000
        $script:initObj = if ($initResp) { $initResp | ConvertFrom-Json } else { $null }

        # Send initialized notification
        $notif = @{ jsonrpc = "2.0"; method = "notifications/initialized"; params = @{} } | ConvertTo-Json -Compress
        $script:serverProc.StandardInput.WriteLine($notif)
        $script:serverProc.StandardInput.Flush()
        Start-Sleep -Milliseconds 300
    }

    AfterAll {
        if ($script:serverProc -and -not $script:serverProc.HasExited) {
            try { $script:serverProc.Kill() } catch { }
            try { $script:serverProc.WaitForExit(3000) } catch { }
        }
    }

    It "Initialize response is valid JSON" {
        if (-not $script:serverResult.Success) { Set-ItResult -Skipped -Because "Server not available" }
        $script:initObj | Should -Not -BeNullOrEmpty
    }

    It "Protocol version is 2024-11-05" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:initObj.result.protocolVersion | Should -Be "2024-11-05"
    }

    It "Server info name is mcp-servers/everything" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:initObj.result.serverInfo.name | Should -Be "mcp-servers/everything"
    }

    It "Server advertises tools capability" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:initObj.result.capabilities.tools | Should -Not -BeNullOrEmpty
    }

    It "Server advertises resources capability" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:initObj.result.capabilities.resources | Should -Not -BeNullOrEmpty
    }

    It "tools/list returns echo tool" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:rpcId++
        $toolsReq = Build-JsonRpcRequest "tools/list" @{} $script:rpcId
        $toolsResp = Send-JsonRpcReadUntilId $script:serverProc $toolsReq $script:rpcId
        $toolsResp | Should -Not -BeNullOrEmpty
        $toolsObj = $toolsResp | ConvertFrom-Json
        $names = @($toolsObj.result.tools) | ForEach-Object { $_.name }
        $names | Should -Contain "echo"
    }

    It "tools/call echo returns the message" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:rpcId++
        $echoReq = Build-JsonRpcRequest "tools/call" @{
            name      = "echo"
            arguments = @{ message = "PowerAgent test echo" }
        } $script:rpcId
        $echoResp = Send-JsonRpcReadUntilId $script:serverProc $echoReq $script:rpcId
        $echoResp | Should -Not -BeNullOrEmpty
        $echoObj = $echoResp | ConvertFrom-Json
        $text = ($echoObj.result.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join ""
        $text | Should -Match "PowerAgent test echo"
    }

    It "tools/call get-sum returns correct sum" {
        if (-not $script:initObj) { Set-ItResult -Skipped -Because "Init failed" }
        $script:rpcId++
        $sumReq = Build-JsonRpcRequest "tools/call" @{
            name      = "get-sum"
            arguments = @{ a = 42; b = 58 }
        } $script:rpcId
        $sumResp = Send-JsonRpcReadUntilId $script:serverProc $sumReq $script:rpcId
        $sumResp | Should -Not -BeNullOrEmpty
        $sumObj = $sumResp | ConvertFrom-Json
        $text = ($sumObj.result.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join ""
        $text | Should -Match "100"
    }
}

# ============================================================================
#  5. PowerAgent MCP Integration — Full Flow via PowerAgent functions
#     BUG-WIN-NPX is now FIXED: Connect-McpStdio auto-wraps npx on Windows.
#     BUG-ARGS-RESERVED is now FIXED: Invoke-McpCallTool uses $Arguments param.
# ============================================================================
Describe "McpClient — PowerAgent Full Integration (server-everything)" -Tag "McpLive" {
    BeforeAll {
        $npxCmd = Get-Command npx -ErrorAction SilentlyContinue
        if (-not $npxCmd) { return }

        # Reset global MCP state
        $global:MCP_SERVERS = @{}
        $global:MCP_SERVER_PID = @{}
        $global:MCP_SERVER_DIR = @{}
        $global:MCP_SERVER_TOOLS = @{}
        $global:MCP_SERVER_CAPS = @{}
        $global:MCP_SERVER_READY = @{}
        $global:MCP_SERVER_URL = @{}
        $global:MCP_SERVER_TRANSPORT = @{}
        $global:MCP_SERVER_PROC = @{}
        $global:MCP_STREAM_WRITER = @{}
        $global:MCP_STREAM_READER = @{}
        $global:MCP_CONNECTED_COUNT = 0
        $global:MCP_NEXT_REQUEST_ID = 1

        # After BUG-WIN-NPX fix, bare "npx" works on all platforms —
        # Connect-McpStdio auto-detects .cmd commands on Windows.
        $global:MCP_SERVERS["everything"] = '{"command":"npx","args":["-y","@modelcontextprotocol/server-everything","stdio"],"transport":"stdio"}'
    }

    AfterAll {
        try { Stop-Mcp } catch { }
    }

    Context "Connect-McpStdio" {
        It "Connects to server-everything via stdio" {
            $result = Connect-McpStdio "everything"
            $result | Should -BeTrue
            $global:MCP_SERVER_PROC["everything"] | Should -Not -BeNullOrEmpty
            $global:MCP_SERVER_PID["everything"] | Should -BeGreaterThan 0
            $global:MCP_SERVER_TRANSPORT["everything"] | Should -Be "stdio"
        }

        It "Creates a temp directory for the server" {
            Test-Path $global:MCP_SERVER_DIR["everything"] | Should -BeTrue
        }
    }

    Context "Initialize-McpServer" {
        It "Completes the MCP handshake successfully" {
            $result = Initialize-McpServer "everything"
            $result | Should -BeTrue
            $global:MCP_SERVER_READY["everything"] | Should -BeTrue
        }

        It "Records server capabilities" {
            $caps = $global:MCP_SERVER_CAPS["everything"]
            $caps | Should -Not -BeNullOrEmpty
            $caps | Should -Not -Be "{}"
        }
    }

    Context "Get-McpTools" {
        It "Lists tools with mcp__ prefix" {
            $result = Get-McpTools "everything"
            $result | Should -BeTrue
            $toolsJson = $global:MCP_SERVER_TOOLS["everything"]
            $toolsJson | Should -Not -BeNullOrEmpty

            $tools = @($toolsJson | ConvertFrom-Json)
            $tools.Count | Should -BeGreaterThan 0

            foreach ($tool in $tools) {
                $tool.name | Should -Match "^mcp__everything__"
            }
        }

        It "Includes the echo tool as mcp__everything__echo" {
            $toolsJson = $global:MCP_SERVER_TOOLS["everything"]
            $tools = @($toolsJson | ConvertFrom-Json)
            $names = $tools | ForEach-Object { $_.name }
            $names | Should -Contain "mcp__everything__echo"
        }
    }

    Context "Invoke-McpCallTool" {
        It "Calls echo tool and gets expected response" {
            # After BUG-ARGS-RESERVED fix ($Args → $Arguments), hashtable
            # arguments are now correctly serialized as JSON objects.
            $result = Invoke-McpCallTool "everything" "echo" @{ message = "PowerAgent MCP test echo" }
            $result | Should -Match "PowerAgent MCP test echo"
        }

        It "Calls get-sum tool and gets correct sum" {
            $result = Invoke-McpCallTool "everything" "get-sum" @{ a = 42; b = 58 }
            $result | Should -Match "100"
        }

        It "Returns error string for unknown tool" {
            $result = Invoke-McpCallTool "everything" "nonexistent_tool_xyz" @{}
            $result | Should -Match "Error"
        }
    }

    Context "Get-McpToolsJson" {
        It "Aggregates tools from all ready servers" {
            $toolsJson = Get-McpToolsJson
            $tools = @($toolsJson | ConvertFrom-Json)
            $tools.Count | Should -BeGreaterThan 0
        }
    }

    Context "Send-McpStdio / Receive-McpStdio" {
        It "Send and receive raw JSON-RPC messages" {
            $req = New-McpRequest "tools/list" @{}
            $reqJson = $req | ConvertTo-Json -Depth 10 -Compress

            $sendOk = Send-McpStdio "everything" $reqJson
            $sendOk | Should -BeTrue

            $resp = Receive-McpStdio "everything" 15
            $resp | Should -Not -BeNullOrEmpty

            $obj = $resp | ConvertFrom-Json
            $obj.result.tools | Should -Not -BeNullOrEmpty
        }
    }

    Context "Disconnect-McpServer" {
        It "Disconnects and cleans up all state" {
            $srvPid = $global:MCP_SERVER_PID["everything"]
            Disconnect-McpServer "everything"

            $global:MCP_SERVER_PID.ContainsKey("everything") | Should -BeFalse
            $global:MCP_SERVER_READY.ContainsKey("everything") | Should -BeFalse
            $global:MCP_SERVER_TRANSPORT.ContainsKey("everything") | Should -BeFalse
            $global:MCP_SERVER_PROC.ContainsKey("everything") | Should -BeFalse
        }
    }
}

# ============================================================================
#  6. BUG-WIN-NPX: Windows bare npx as ProcessStartInfo.FileName
#     (Fixed in Connect-McpStdio — auto-wraps npx/npm with cmd.exe /c)
# ============================================================================
Describe "McpClient — BUG-WIN-NPX: Windows npx.cmd Resolution" {
    It "Bare 'npx' cannot be used as ProcessStartInfo.FileName on Windows (OS-level)" {
        if (-not ($IsWindows -or $env:OS -match "Windows")) {
            Set-ItResult -Skipped -Because "Non-Windows platform"
        }

        # This tests the raw .NET limitation — bare "npx" still cannot be
        # ProcessStartInfo.FileName. Connect-McpStdio works around this.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "npx"
        $psi.Arguments = "--version"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true

        $started = $false
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
            $started = $true
            if ($proc -and -not $proc.HasExited) { $proc.Kill() }
        } catch {
            $started = $false
        }

        # Raw .NET still rejects bare "npx" on Windows
        $started | Should -BeFalse
    }

    It "cmd.exe /c npx works as ProcessStartInfo on Windows" {
        if (-not ($IsWindows -or $env:OS -match "Windows")) {
            Set-ItResult -Skipped -Because "Non-Windows platform"
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c npx --version"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc | Should -Not -BeNullOrEmpty
        $proc.WaitForExit(10000) | Should -BeTrue
        $proc.ExitCode | Should -Be 0
    }

    It "Connect-McpStdio with bare 'npx' command now succeeds on Windows (fix verified)" {
        if (-not ($IsWindows -or $env:OS -match "Windows")) {
            Set-ItResult -Skipped -Because "Non-Windows platform"
        }

        $saved = $global:MCP_SERVERS.Clone()
        # After BUG-WIN-NPX fix, Connect-McpStdio auto-detects "npx" on Windows
        # and wraps it with cmd.exe /c — so this should now succeed.
        $global:MCP_SERVERS["npx_test"] = '{"command":"npx","args":["--version"],"transport":"stdio"}'

        $result = Connect-McpStdio "npx_test"
        $result | Should -BeTrue

        # Cleanup
        Disconnect-McpServer "npx_test"
        $global:MCP_SERVERS = $saved
        $global:MCP_SERVERS.Remove("npx_test")
    }

    It "Connect-McpStdio with 'cmd.exe /c npx' command still succeeds on Windows" {
        if (-not ($IsWindows -or $env:OS -match "Windows")) {
            Set-ItResult -Skipped -Because "Non-Windows platform"
        }

        $global:MCP_SERVERS["cmd_npx_test"] = '{"command":"cmd.exe","args":["/c","npx","--version"],"transport":"stdio"}'

        $result = Connect-McpStdio "cmd_npx_test"
        $result | Should -BeTrue

        # Cleanup
        Disconnect-McpServer "cmd_npx_test"
        $global:MCP_SERVERS.Remove("cmd_npx_test")
    }
}

# ============================================================================
#  7. Tool Dispatch — mcp__ prefix routing
# ============================================================================
Describe "McpClient — Tool Dispatch (mcp__ prefix routing)" {
    Context "Regex parsing of mcp__<server>__<tool>" {
        It "Extracts server and tool from mcp__server__tool pattern" {
            "mcp__everything__echo" -match "^mcp__(.+)__(.+)$" | Should -BeTrue
            $Matches[1] | Should -Be "everything"
            $Matches[2] | Should -Be "echo"
        }

        It "Extracts server name with hyphens" {
            "mcp__my-server__do_thing" -match "^mcp__(.+)__(.+)$" | Should -BeTrue
            $Matches[1] | Should -Be "my-server"
            $Matches[2] | Should -Be "do_thing"
        }

        It "Does NOT match tool names without mcp__ prefix" {
            "read_file" -match "^mcp__(.+)__(.+) $" | Should -BeFalse
        }

        It "Greedy regex: mcp__a__b__c matches server=a__b, tool=c" {
            # The regex ^mcp__(.+)__(.+)$ is greedy on first capture group
            # so "a__b__c" → group1="a__b" (greedy), group2="c"
            "mcp__a__b__c" -match "^mcp__(.+)__(.+)$" | Should -BeTrue
            $Matches[1] | Should -Be "a__b"
            $Matches[2] | Should -Be "c"
        }

        It "Simple server names work correctly" {
            "mcp__fs__read" -match "^mcp__(.+)__(.+)$" | Should -BeTrue
            $Matches[1] | Should -Be "fs"
            $Matches[2] | Should -Be "read"
        }
    }

    Context "Invoke-McpDispatchTool" {
        It "Returns error when server is not connected" {
            $result = Invoke-McpDispatchTool "nonexistent" "echo" @{}
            $result | Should -Match "not connected"
        }
    }
}

# ============================================================================
#  8. Initialize-Mcp / Stop-Mcp — Full lifecycle
# ============================================================================
Describe "McpClient — Initialize-Mcp / Stop-Mcp Lifecycle" {
    Context "Initialize-Mcp with MCP disabled" {
        It "Skips initialization when PA_MCP_ENABLED is false" {
            $savedEnabled = $global:PA_MCP_ENABLED
            $global:PA_MCP_ENABLED = "false"
            { Initialize-Mcp } | Should -Not -Throw
            $global:PA_MCP_ENABLED = $savedEnabled
        }
    }

    Context "Stop-Mcp with no servers" {
        It "Does not throw" {
            { Stop-Mcp } | Should -Not -Throw
        }

        It "Resets connected count to 0" {
            Stop-Mcp
            $global:MCP_CONNECTED_COUNT | Should -Be 0
        }
    }

    Context "Stop-Mcp with connected servers" {
        It "Cleans up all server state" {
            $global:MCP_SERVER_PID["test_lifecycle"] = 99999
            $global:MCP_SERVER_DIR["test_lifecycle"] = Join-Path $env:TEMP "poweragent_mcp_test_lifecycle"
            New-Item -ItemType Directory -Path $global:MCP_SERVER_DIR["test_lifecycle"] -Force | Out-Null

            Stop-Mcp

            $global:MCP_SERVER_PID.ContainsKey("test_lifecycle") | Should -BeFalse
            $global:MCP_CONNECTED_COUNT | Should -Be 0
        }
    }
}

# ============================================================================
#  9. MCP Slash Commands
# ============================================================================
Describe "McpClient — Slash Commands" {
    It "Get-McpStatus does not throw with no servers" {
        $global:MCP_SERVERS = @{}
        { Get-McpStatus } | Should -Not -Throw
    }

    It "Get-McpServerList does not throw with no servers" {
        $global:MCP_SERVERS = @{}
        { Get-McpServerList } | Should -Not -Throw
    }

    It "Get-McpToolList does not throw with no tools" {
        $global:MCP_SERVER_TOOLS = @{}
        $global:MCP_SERVER_READY = @{}
        { Get-McpToolList "" } | Should -Not -Throw
    }

    It "Get-McpToolList handles nonexistent server name" {
        { Get-McpToolList "nonexistent" } | Should -Not -Throw
    }
}

# ============================================================================
#  10. Edge Cases & Error Handling
# ============================================================================
Describe "McpClient — Edge Cases & Error Handling" {
    BeforeAll {
        $script:savedNextId = $global:MCP_NEXT_REQUEST_ID
        $global:MCP_NEXT_REQUEST_ID = 1
    }
    AfterAll {
        $global:MCP_NEXT_REQUEST_ID = $script:savedNextId
    }
    Context "New-McpRequest ID management" {
        It "Request IDs are unique across calls" {
            $ids = @()
            for ($i = 0; $i -lt 50; $i++) {
                $req = New-McpRequest "test" @{}
                $ids += $req.id
            }
            ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        }
    }

    Context "JSON serialization round-trip" {
        It "Request serializes and deserializes correctly" {
            $req = New-McpRequest "tools/call" @{
                name      = "echo"
                arguments = @{ message = "test" }
            }
            $json = $req | ConvertTo-Json -Depth 10 -Compress
            $parsed = $json | ConvertFrom-Json

            $parsed.jsonrpc | Should -Be "2.0"
            $parsed.method | Should -Be "tools/call"
            $parsed.params.name | Should -Be "echo"
            $parsed.params.arguments.message | Should -Be "test"
        }
    }

    Context "Send-McpStdio with no writer" {
        It "Returns false when no stdin writer exists" {
            $global:MCP_STREAM_WRITER.Remove("nonexistent")
            $result = Send-McpStdio "nonexistent" '{"test":1}'
            $result | Should -BeFalse
        }
    }

    Context "Receive-McpStdio timeout" {
        It "Returns null when no reader exists" {
            $global:MCP_STREAM_READER.Remove("nonexistent")
            $result = Receive-McpStdio "nonexistent" 1
            $result | Should -BeNullOrEmpty
        }
    }
}
