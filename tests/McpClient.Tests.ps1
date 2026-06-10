# ============================================================================
#  PowerAgent Test — McpClient.ps1
#  Validates MCP protocol primitives, transport abstraction, config loading
# ============================================================================

Describe "McpClient.ps1 — State Initialization" {
    BeforeAll {
        $script:savedNextId = $global:MCP_NEXT_REQUEST_ID
        $global:MCP_NEXT_REQUEST_ID = 1
    }
    AfterAll {
        $global:MCP_NEXT_REQUEST_ID = $script:savedNextId
    }
    It "MCP_SERVERS is an empty hashtable" {
        $global:MCP_SERVERS -is [hashtable] | Should -BeTrue
        $global:MCP_SERVERS.Count | Should -Be 0
    }

    It "MCP_CONNECTED_COUNT is 0" {
        $global:MCP_CONNECTED_COUNT | Should -Be 0
    }

    It "MCP_NEXT_REQUEST_ID is 1" {
        $global:MCP_NEXT_REQUEST_ID | Should -Be 1
    }
}

Describe "McpClient.ps1 — JSON-RPC 2.0 Primitives" {
    Context "New-McpRequest" {
        It "Creates a valid JSON-RPC request" {
            $req = New-McpRequest "initialize" @{ protocolVersion = "2024-11-05" }
            $req.jsonrpc | Should -Be "2.0"
            $req.method | Should -Be "initialize"
            $req.id | Should -BeGreaterThan 0
        }

        It "Auto-increments request ID" {
            $req1 = New-McpRequest "method1" @{}
            $req2 = New-McpRequest "method2" @{}
            $req2.id | Should -BeGreaterThan $req1.id
        }

        It "Accepts string params and parses to object" {
            $req = New-McpRequest "test" '{"key":"value"}'
            $req.params.key | Should -Be "value"
        }
    }

    Context "New-McpNotification" {
        It "Creates a valid JSON-RPC notification (no id)" {
            $notif = New-McpNotification "notifications/initialized" @{}
            $notif.jsonrpc | Should -Be "2.0"
            $notif.method | Should -Be "notifications/initialized"
            $notif.ContainsKey("id") | Should -BeFalse
        }

        It "Includes params" {
            $notif = New-McpNotification "test" @{ foo = "bar" }
            $notif.params.foo | Should -Be "bar"
        }
    }
}

Describe "McpClient.ps1 — Import-McpConfig" {
    BeforeEach {
        $global:MCP_SERVERS = @{}
        $global:_CFG = @{}
    }

    It "Parses empty mcp_servers" {
        Import-McpConfig
        $global:MCP_SERVERS.Count | Should -Be 0
    }

    It "Parses mcp_servers from environment variable" {
        $env:PA_MCP_SERVERS = '{"test_server":{"command":"npx","transport":"stdio"}}'
        Import-McpConfig
        $global:MCP_SERVERS.ContainsKey("test_server") | Should -BeTrue
        Remove-Item Env:PA_MCP_SERVERS
    }

    It "Handles invalid JSON gracefully" {
        $env:PA_MCP_SERVERS = "not valid json"
        { Import-McpConfig } | Should -Not -Throw
        Remove-Item Env:PA_MCP_SERVERS
    }
}

Describe "McpClient.ps1 — Transport Abstraction" {
    Context "Connect-McpServer" {
        It "Returns false for unknown transport" {
            $global:MCP_SERVERS["bad_transport"] = '{"transport":"weird"}'
            $result = Connect-McpServer "bad_transport"
            $result | Should -BeFalse
        }

        It "Returns false for missing config" {
            $result = Connect-McpServer "nonexistent_server"
            $result | Should -BeFalse
        }
    }
}

Describe "McpClient.ps1 — Disconnect-McpServer" {
    It "Does not throw for nonexistent server" {
        { Disconnect-McpServer "nonexistent_server" } | Should -Not -Throw
    }
}

Describe "McpClient.ps1 — MCP Status Display" {
    It "Get-McpStatus does not throw" {
        { Get-McpStatus } | Should -Not -Throw
    }

    It "Get-McpServerList does not throw" {
        { Get-McpServerList } | Should -Not -Throw
    }
}

Describe "McpClient.ps1 — Initialize-Mcp / Stop-Mcp" {
    It "Initialize-Mcp with MCP disabled returns cleanly" {
        $global:PA_MCP_ENABLED = "false"
        { Initialize-Mcp } | Should -Not -Throw
        $global:PA_MCP_ENABLED = "true"
    }

    It "Stop-Mcp does not throw with no servers" {
        { Stop-Mcp } | Should -Not -Throw
    }
}
