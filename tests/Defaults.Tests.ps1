# ============================================================================
#  PowerAgent Test — Defaults.ps1
#  Validates built-in default values and system prompt generation
# ============================================================================

BeforeAll {
    # Defaults.ps1 is already dot-sourced by run_tests.ps1
}

Describe "Defaults.ps1 — Built-in Defaults" {
    Context "Version" {
        It "PA_VERSION is defined" {
            $global:PA_VERSION | Should -Not -BeNullOrEmpty
        }
        It "PA_VERSION starts with 'preview'" {
            $global:PA_VERSION | Should -BeLike "preview*"
        }
    }

    Context "API Configuration Defaults" {
        It "DEFAULT_API_URL is a valid URL" {
            $global:DEFAULT_API_URL | Should -Match "^https?://"
        }
        It "DEFAULT_MODEL is defined" {
            $global:DEFAULT_MODEL | Should -Not -BeNullOrEmpty
        }
        It "DEFAULT_MAX_TOKENS is a positive integer string" {
            [int]$global:DEFAULT_MAX_TOKENS | Should -BeGreaterThan 0
        }
        It "DEFAULT_THINKING_BUDGET is a positive integer string" {
            [int]$global:DEFAULT_THINKING_BUDGET | Should -BeGreaterThan 0
        }
        It "DEFAULT_API_PROTOCOL is one of: auto, anthropic, openai" {
            @("auto", "anthropic", "openai") | Should -Contain $global:DEFAULT_API_PROTOCOL
        }
        It "DEFAULT_CONNECT_TIMEOUT is a positive integer" {
            [int]$global:DEFAULT_CONNECT_TIMEOUT | Should -BeGreaterThan 0
        }
        It "DEFAULT_CMD_TIMEOUT is a positive integer" {
            [int]$global:DEFAULT_CMD_TIMEOUT | Should -BeGreaterThan 0
        }
        It "DEFAULT_SHOW_THINKING is one of: status, full, off" {
            @("status", "full", "off") | Should -Contain $global:DEFAULT_SHOW_THINKING
        }
    }

    Context "Compression Defaults" {
        It "DEFAULT_COMPRESS_THRESHOLD is a positive integer" {
            [int]$global:DEFAULT_COMPRESS_THRESHOLD | Should -BeGreaterThan 0
        }
    }

    Context "Memory Defaults" {
        It "DEFAULT_MEMORY_ENABLED is 'true' or 'false'" {
            @("true", "false") | Should -Contain $global:DEFAULT_MEMORY_ENABLED
        }
        It "DEFAULT_MEM_ENGRAM_COUNT is a positive integer" {
            [int]$global:DEFAULT_MEM_ENGRAM_COUNT | Should -BeGreaterThan 0
        }
    }

    Context "Context Window Defaults" {
        It "DEFAULT_CONTEXT_WINDOW is a positive integer" {
            [int]$global:DEFAULT_CONTEXT_WINDOW | Should -BeGreaterThan 0
        }
        It "DEFAULT_CONTEXT_SAFE_RATIO is between 1 and 100" {
            [int]$global:DEFAULT_CONTEXT_SAFE_RATIO | Should -BeIn (1..100)
        }
        It "DEFAULT_STUCK_THRESHOLD is a positive integer" {
            [int]$global:DEFAULT_STUCK_THRESHOLD | Should -BeGreaterThan 0
        }
    }

    Context "Trace Defaults" {
        It "DEFAULT_TRACE_ENABLED is '0' or '1'" {
            @("0", "1") | Should -Contain $global:DEFAULT_TRACE_ENABLED
        }
        It "DEFAULT_TRACE_MAX_FRAMES is a positive integer" {
            [int]$global:DEFAULT_TRACE_MAX_FRAMES | Should -BeGreaterThan 0
        }
    }

    Context "Daemon Defaults" {
        It "DEFAULT_DAEMON_PORT is a valid port number" {
            [int]$global:DEFAULT_DAEMON_PORT | Should -BeIn (1..65535)
        }
    }

    Context "MCP Defaults" {
        It "DEFAULT_MCP_ENABLED is 'true' or 'false'" {
            @("true", "false") | Should -Contain $global:DEFAULT_MCP_ENABLED
        }
    }
}
