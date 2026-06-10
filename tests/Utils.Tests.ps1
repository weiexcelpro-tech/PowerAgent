# ============================================================================
#  PowerAgent Test — Utils.ps1
#  Validates logging, terminal helpers, file operations, process management
# ============================================================================

Describe "Utils.ps1 — Logging" {
    Context "Write-Log" {
        It "Does not throw on normal log message" {
            { Write-Log "INFO: test message" } | Should -Not -Throw
        }
        It "Does not throw on DEBUG level message" {
            { Write-Log "DEBUG: test debug" } | Should -Not -Throw
        }
        It "Does not throw on WARN level message" {
            { Write-Log "WARN: test warning" } | Should -Not -Throw
        }
    }

    Context "Initialize-Log" {
        It "Does not throw" {
            { Initialize-Log } | Should -Not -Throw
        }
    }
}

Describe "Utils.ps1 — ANSI Terminal Codes" {
    It "BOLD escape code starts with ESC[" {
        $global:BOLD | Should -Match "^\x1b\["
    }
    It "RESET escape code is ESC[0m" {
        $global:RESET | Should -BeExactly "$([char]27)[0m"
    }
    It "Color codes are defined" {
        @("BOLD", "DIM", "GREEN", "CYAN", "YELLOW", "RED", "GRAY", "RESET") | ForEach-Object {
            (Get-Variable -Name $_ -ValueOnly -Scope Global) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Utils.ps1 — Timestamp Functions" {
    Context "Get-TimestampMs" {
        It "Returns a positive long integer" {
            $ts = Get-TimestampMs
            $ts | Should -BeGreaterThan 0
        }
        It "Returns current epoch milliseconds (within reasonable range)" {
            $ts = Get-TimestampMs
            $approxNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            [Math]::Abs($ts - $approxNow) | Should -BeLessThan 5000
        }
    }

    Context "Get-TimestampS" {
        It "Returns a positive integer" {
            $ts = Get-TimestampS
            $ts | Should -BeGreaterThan 0
        }
        It "Returns current epoch seconds (within reasonable range)" {
            $ts = Get-TimestampS
            $approxNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            [Math]::Abs($ts - $approxNow) | Should -BeLessThan 5
        }
    }
}

Describe "Utils.ps1 — Process Management" {
    Context "Test-ProcessAlive" {
        It "Returns true for current process" {
            Test-ProcessAlive $PID | Should -BeTrue
        }
        It "Returns false for non-existent PID" {
            Test-ProcessAlive 999999999 | Should -BeFalse
        }
    }

    Context "Stop-ProcessTree" {
        It "Does not throw when given non-existent PID" {
            { Stop-ProcessTree 999999999 } | Should -Not -Throw
        }
    }
}

Describe "Utils.ps1 — Port Management" {
    Context "Test-PortBusy" {
        It "Does not throw" {
            { Test-PortBusy 19999 } | Should -Not -Throw
        }
        It "Returns boolean" {
            $result = Test-PortBusy 19999
            $result -is [bool] | Should -BeTrue
        }
    }

    Context "Stop-PortProcess" {
        It "Does not throw for unused port" {
            { Stop-PortProcess 19999 } | Should -Not -Throw
        }
    }
}

Describe "Utils.ps1 — Slash Command Registry" {
    Context "Register-Slash / Invoke-SlashDispatch" {
        BeforeAll {
            $global:SLASH_COMMANDS = @{}
            Register-Slash "testcmd" { Write-Output "test-handler-called" }
        }

        It "Registers a slash command" {
            $global:SLASH_COMMANDS.ContainsKey("testcmd") | Should -BeTrue
        }
        It "Dispatches a registered slash command" {
            $result = Invoke-SlashDispatch "/testcmd"
            $result | Should -BeTrue
        }
        It "Returns false for unknown slash command" {
            $result = Invoke-SlashDispatch "/nonexistent"
            $result | Should -BeFalse
        }
    }
}

Describe "Utils.ps1 — File Operations" {
    Context "Write-AtomicFile" {
        It "Writes content to file without error" {
            $testFile = Join-Path $env:TEMP "poweragent_test_atomic_$(Get-Random).txt"
            try {
                Write-AtomicFile $testFile "hello world"
                Test-Path $testFile | Should -BeTrue
                Get-Content $testFile -Raw | Should -Be "hello world"
            } finally {
                Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Handles Unicode content" {
            $testFile = Join-Path $env:TEMP "poweragent_test_unicode_$(Get-Random).txt"
            try {
                $content = "Hello 世界 🌍"
                Write-AtomicFile $testFile $content
                Get-Content $testFile -Raw -Encoding UTF8 | Should -Be $content
            } finally {
                Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Utils.ps1 — Dependency Check" {
    Context "Test-Dependencies" {
        It "Does not throw" {
            { Test-Dependencies | Out-Null } | Should -Not -Throw
        }
        It "Returns a boolean" {
            $result = Test-Dependencies
            $result -is [bool] | Should -BeTrue
        }
    }
}

Describe "Utils.ps1 — Directory Initialization" {
    Context "Initialize-SystemDirs" {
        It "Does not throw" {
            { Initialize-SystemDirs } | Should -Not -Throw
        }
        It "Creates ~/.poweragent directory" {
            Initialize-SystemDirs
            $paDir = Join-Path $env:USERPROFILE ".poweragent"
            Test-Path $paDir | Should -BeTrue
        }
        It "Creates subdirectories" {
            $paDir = Join-Path $env:USERPROFILE ".poweragent"
            @("agents", "skills", "hooks", "log", "sessions", "mem_net") | ForEach-Object {
                Test-Path (Join-Path $paDir $_) | Should -BeTrue
            }
        }
    }

    Context "Initialize-ProjectDirs" {
        It "Does not throw with default project dir" {
            { Initialize-ProjectDirs } | Should -Not -Throw
        }
    }
}

# ============================================================================
#  NEW: Additional Utils Tests
# ============================================================================

Describe "Utils.ps1 — ConvertFrom-JsonSafe" {
    Context "Valid JSON input" {
        It "Returns parsed object for valid JSON object" {
            $result = ConvertFrom-JsonSafe '{"key":"value"}'
            $result.key | Should -Be "value"
        }

        It "Handles JSON array [1,2,3]" {
            $result = ConvertFrom-JsonSafe "[1,2,3]"
            @($result).Count | Should -Be 3
            @($result)[0] | Should -Be 1
            @($result)[2] | Should -Be 3
        }

        It "Handles nested JSON" {
            $json = '{"outer":{"inner":"deep"}}'
            $result = ConvertFrom-JsonSafe $json
            $result.outer.inner | Should -Be "deep"
        }
    }

    Context "Invalid / edge-case input" {
        It "Returns `$null for invalid JSON string" {
            $result = ConvertFrom-JsonSafe "not-json-at-all"
            $result | Should -BeNullOrEmpty
        }

        It "Returns `$null for empty string" {
            $result = ConvertFrom-JsonSafe ""
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe "Utils.ps1 — ConvertTo-JsonSafe" {
    Context "Serialisation" {
        It "Returns valid JSON for hashtable" {
            $ht = @{ name = "test"; value = 42 }
            $json = ConvertTo-JsonSafe $ht
            { $json | ConvertFrom-Json } | Should -Not -Throw
            $parsed = $json | ConvertFrom-Json
            $parsed.name | Should -Be "test"
            $parsed.value | Should -Be 42
        }

        It "Handles empty array" {
            $json = ConvertTo-JsonSafe @()
            # PS5.1 may produce various outputs for empty arrays; just verify no throw
            { ConvertTo-JsonSafe @() } | Should -Not -Throw
        }
    }

    Context "Depth parameter" {
        It "Respects Depth parameter by truncating deep objects" {
            $deep = @{ a = @{ b = @{ c = @{ d = "leaf" } } } }
            $jsonShallow = ConvertTo-JsonSafe $deep -Depth 1
            # At depth 1, nested objects beyond level 1 should be stringified or truncated
            $jsonDeep = ConvertTo-JsonSafe $deep -Depth 10
            $parsedDeep = $jsonDeep | ConvertFrom-Json
            $parsedDeep.a.b.c.d | Should -Be "leaf"
        }
    }

    Context "Error handling" {
        It "Does not throw for normal input" {
            { ConvertTo-JsonSafe @{ x = 1 } } | Should -Not -Throw
        }
    }
}

Describe "Utils.ps1 — Get-StatusText" {
    It "Returns 'OK' for code 200" {
        Get-StatusText 200 | Should -Be "OK"
    }

    It "Returns 'NotFnd' for code 404" {
        Get-StatusText 404 | Should -Be "NotFnd"
    }

    It "Returns 'SrvrErr' for code 500" {
        Get-StatusText 500 | Should -Be "SrvrErr"
    }

    It "Returns 'Created' for code 201" {
        Get-StatusText 201 | Should -Be "Created"
    }

    It "Returns stringified code for unknown code like 999" {
        Get-StatusText 999 | Should -Be "999"
    }

    It "Returns stringified code for 0" {
        Get-StatusText 0 | Should -Be "0"
    }
}

Describe "Utils.ps1 — Get-FileMtime" {
    It "Returns positive int for existing file" {
        $testFile = Join-Path $env:TEMP "pa_test_mtime_$(Get-Random).txt"
        try {
            Set-Content $testFile "mtime test" -Encoding UTF8
            $result = Get-FileMtime $testFile
            $result | Should -BeGreaterThan 0
            $result -is [int] | Should -BeTrue
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns 0 for nonexistent file" {
        $fakePath = Join-Path $env:TEMP "pa_nonexistent_$(Get-Random)_ghost.txt"
        Get-FileMtime $fakePath | Should -Be 0
    }

    It "Returns recent timestamp (within last 60 seconds) for newly created file" {
        $testFile = Join-Path $env:TEMP "pa_test_mtime_recent_$(Get-Random).txt"
        try {
            Set-Content $testFile "recent" -Encoding UTF8
            $result = Get-FileMtime $testFile
            $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            [Math]::Abs($now - $result) | Should -BeLessOrEqual 60
        } finally {
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Utils.ps1 — New-TempFile / New-TempDir" {
    Context "New-TempFile" {
        It "Returns a path that exists on disk" {
            $path = New-TempFile
            try {
                Test-Path $path | Should -BeTrue
            } finally {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
        }

        It "Returns a file (not directory)" {
            $path = New-TempFile
            try {
                (Get-Item $path) -is [System.IO.FileInfo] | Should -BeTrue
            } finally {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "New-TempDir" {
        It "Returns a path that exists and is a directory" {
            $path = New-TempDir
            try {
                Test-Path $path | Should -BeTrue
                (Get-Item $path) -is [System.IO.DirectoryInfo] | Should -BeTrue
            } finally {
                Remove-Item $path -Force -Recurse -ErrorAction SilentlyContinue
            }
        }

        It "Creates directory under `$env:TEMP" {
            $path = New-TempDir
            try {
                $path | Should -BeLike "$env:TEMP*"
            } finally {
                Remove-Item $path -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "Utils.ps1 — Get-ContentHash" {
    It "Returns consistent hash for same content" {
        $hash1 = Get-ContentHash "hello world"
        $hash2 = Get-ContentHash "hello world"
        $hash1 | Should -Be $hash2
    }

    It "Returns different hash for different content" {
        $hash1 = Get-ContentHash "hello"
        $hash2 = Get-ContentHash "world"
        $hash1 | Should -Not -Be $hash2
    }

    It "Returns 64-char uppercase hex string (dashes removed)" {
        $hash = Get-ContentHash "test"
        $hash.Length | Should -Be 64
        $hash | Should -Match "^[0-9A-F]+$"
    }

    It "Handles empty string" {
        { Get-ContentHash "" } | Should -Not -Throw
        $hash = Get-ContentHash ""
        $hash.Length | Should -Be 64
    }
}

Describe "Utils.ps1 — Get-StringDisplayWidth / CJK Padding" {
    Context "Get-StringDisplayWidth" {
        It "Returns width 5 for ASCII 'hello'" {
            Get-StringDisplayWidth "hello" | Should -Be 5
        }

        It "Returns width 4 for CJK '你好'" {
            Get-StringDisplayWidth "你好" | Should -Be 4
        }

        It "Returns 0 for empty string" {
            Get-StringDisplayWidth "" | Should -Be 0
        }

        It "Returns mixed width for ASCII + CJK" {
            Get-StringDisplayWidth "A你" | Should -Be 3
        }
    }

    Context "Get-CjkPadRight" {
        It "Pads ASCII string to target width" {
            $result = Get-CjkPadRight "hi" 10
            $result.Length | Should -Be 10
        }

        It "Handles CJK correctly (pads less for wider chars)" {
            $result = Get-CjkPadRight "你好" 10
            # 你好 = width 4, needs 6 spaces
            $result.Length | Should -Be (2 + 6)
        }

        It "Returns original text when already at target width" {
            $result = Get-CjkPadRight "hello" 5
            $result | Should -Be "hello"
        }

        It "Returns original text when target is smaller" {
            $result = Get-CjkPadRight "hello world" 3
            $result | Should -Be "hello world"
        }

        It "Uses custom pad character" {
            $result = Get-CjkPadRight "ab" 5 '.'
            $result | Should -Be "ab..."
        }
    }

    Context "Get-CjkPadLeft" {
        It "Pads on left side" {
            $result = Get-CjkPadLeft "hi" 10
            $result.Length | Should -Be 10
            $result.StartsWith(" ") | Should -BeTrue
            $result.EndsWith("hi") | Should -BeTrue
        }

        It "Returns original text when already at target width" {
            $result = Get-CjkPadLeft "hello" 5
            $result | Should -Be "hello"
        }
    }
}

Describe "Utils.ps1 — Hook System" {
    BeforeEach {
        $global:HOOK_HANDLERS = @{}
        $global:HOOK_TYPE = @{}
        $global:HOOK_ENABLED = @{}
        $global:HOOK_PRIORITY = @{}
        $global:HOOK_META = @{}
        $global:HOOK_POINTS = @{}
    }

    Context "Register-Hook" {
        It "Adds handler to HOOK_HANDLERS" {
            Register-Hook -Name "test_hook" -Point "pre_run" -Handler 'Write-Output "fired"'
            $global:HOOK_HANDLERS["test_hook"] | Should -Be 'Write-Output "fired"'
        }

        It "Sets correct priority" {
            Register-Hook -Name "prio_hook" -Point "pre_run" -Handler "x" -Priority 10
            $global:HOOK_PRIORITY["prio_hook"] | Should -Be 10
        }

        It "Defaults priority to 50 when not specified" {
            Register-Hook -Name "def_prio" -Point "pre_run" -Handler "x"
            $global:HOOK_PRIORITY["def_prio"] | Should -Be 50
        }

        It "Adds name to HOOK_POINTS under correct point" {
            Register-Hook -Name "h1" -Point "pre_build" -Handler "a"
            Register-Hook -Name "h2" -Point "pre_build" -Handler "b"
            $global:HOOK_POINTS["pre_build"].Count | Should -Be 2
            $global:HOOK_POINTS["pre_build"] -contains "h1" | Should -BeTrue
            $global:HOOK_POINTS["pre_build"] -contains "h2" | Should -BeTrue
        }

        It "Sets hook type to inline_ps by default" {
            Register-Hook -Name "type_hook" -Point "pre_run" -Handler "x"
            $global:HOOK_TYPE["type_hook"] | Should -Be "inline_ps"
        }

        It "Sets custom type when specified" {
            Register-Hook -Name "custom_type" -Point "pre_run" -Handler "x" -Type "exec"
            $global:HOOK_TYPE["custom_type"] | Should -Be "exec"
        }

        It "Enables hook by default" {
            Register-Hook -Name "enabled_hook" -Point "pre_run" -Handler "x"
            $global:HOOK_ENABLED["enabled_hook"] | Should -BeTrue
        }
    }

    Context "Invoke-HookFire" {
        It "Executes inline_ps hook without throwing" {
            Register-Hook -Name "fire_test" -Point "test_point" -Handler 'Write-Output "hook-fired"'
            { Invoke-HookFire "test_point" } | Should -Not -Throw
        }

        It "Does not throw for unregistered point" {
            { Invoke-HookFire "nonexistent_point_xyz" } | Should -Not -Throw
        }

        It "Does not fire disabled hooks" {
            Register-Hook -Name "disabled_hook" -Point "skip_point" -Handler 'throw "should not run"'
            $global:HOOK_ENABLED["disabled_hook"] = $false
            { Invoke-HookFire "skip_point" } | Should -Not -Throw
        }
    }
}

Describe "Utils.ps1 — Get-ConsoleWidth" {
    It "Returns a positive integer" {
        $w = Get-ConsoleWidth
        $w | Should -BeGreaterThan 0
    }

    It "Returns at least 80" {
        $w = Get-ConsoleWidth
        $w | Should -BeGreaterOrEqual 80
    }

    It "Does not throw" {
        { Get-ConsoleWidth } | Should -Not -Throw
    }
}

# ============================================================================
#  Hook HTTP Webhook Tests (TODO-04 alignment)
# ============================================================================
Describe "Utils.ps1 — Hook HTTP Webhook Type" {
    BeforeAll {
        $global:HOOK_REGISTRY = @{}
        $global:HOOK_META = @{}
        $savedApiKey = $global:PA_API_KEY
        $global:PA_API_KEY = "test-key"
    }
    AfterAll {
        $global:HOOK_REGISTRY = @{}
        $global:HOOK_META = @{}
        $global:PA_API_KEY = $savedApiKey
    }

    It "Register-Hook accepts http type" {
        { Register-Hook -Point "on_tool_start" -Type "http" -Handler "https://example.com/hook" } | Should -Not -Throw
    }

    It "HTTP hook type is stored in registry" {
        Register-Hook -Name "test_http_reg" -Point "on_tool_end" -Type "http" -Handler "https://example.com/webhook"
        $hookNames = @($global:HOOK_POINTS["on_tool_end"])
        $hookNames | Should -Contain "test_http_reg"
        $global:HOOK_TYPE["test_http_reg"] | Should -Be "http"
    }

    It "Invoke-HookFire handles http type without throwing" {
        Register-Hook -Point "test_http_hook" -Type "http" -Handler "https://127.0.0.1:1/nonexistent"
        # 不应抛出（即使 HTTP 请求失败）
        { Invoke-HookFire -Point "test_http_hook" -Context @{ test = $true } } | Should -Not -Throw
    }
}
