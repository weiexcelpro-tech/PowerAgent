# ============================================================================
#  PowerAgent Test — Config.ps1
#  Validates 4-tier config loading, merge, settings resolution
# ============================================================================

Describe "Config.ps1 — Get-Setting" {
    BeforeAll {
        $global:_CFG = @{}
    }

    Context "Environment variable fallback" {
        It "Returns env var value when no cache entry" {
            $env:PA_TEST_GETSETTING = "from-env"
            $result = Get-Setting "nonexistent_key" "PA_TEST_GETSETTING" "default-value"
            $result | Should -Be "from-env"
            Remove-Item Env:PA_TEST_GETSETTING
        }

        It "Returns default when no cache or env" {
            $result = Get-Setting "nonexistent_key_$(Get-Random)" "PA_NONEXISTENT_VAR_$(Get-Random)" "fallback"
            $result | Should -Be "fallback"
        }
    }

    Context "Cache priority" {
        It "Cache value overrides env var" {
            $global:_CFG["test_key"] = "from-cache"
            $env:PA_TEST_CACHE = "from-env"
            $result = Get-Setting "test_key" "PA_TEST_CACHE" "default"
            $result | Should -Be "from-cache"
            Remove-Item Env:PA_TEST_CACHE
            $global:_CFG.Remove("test_key")
        }
    }

    Context "Null handling" {
        It "Treats 'null' string as empty, falls through to env" {
            $global:_CFG["test_null"] = "null"
            $env:PA_TEST_NULL = "from-env"
            $result = Get-Setting "test_null" "PA_TEST_NULL" "default"
            $result | Should -Be "from-env"
            Remove-Item Env:PA_TEST_NULL
            $global:_CFG.Remove("test_null")
        }
    }
}

Describe "Config.ps1 — Merge-SettingsJson" {
    Context "System + Project merge" {
        It "Merges two JSON objects" {
            $global:_CFG = @{}
            Merge-SettingsJson '{"a":1,"b":"sys"}' '{"b":"prj","c":3}'
            $global:_CFG["a"] | Should -Be 1
            $global:_CFG["b"] | Should -Be "prj"
            $global:_CFG["c"] | Should -Be 3
        }

        It "Handles empty system config" {
            $global:_CFG = @{}
            Merge-SettingsJson '{}' '{"x":42}'
            $global:_CFG["x"] | Should -Be 42
        }

        It "Handles empty project config" {
            $global:_CFG = @{}
            Merge-SettingsJson '{"x":42}' '{}'
            $global:_CFG["x"] | Should -Be 42
        }

        It "Handles both empty" {
            $global:_CFG = @{}
            Merge-SettingsJson '{}' '{}'
            $global:_CFG.Count | Should -Be 0
        }
    }

    Context "Complex nested merge" {
        It "Merges nested mcp_servers" {
            $global:_CFG = @{}
            $sysJson = '{"mcp_servers":{"fs":{"command":"npx","transport":"stdio"}}}'
            $prjJson = '{"mcp_servers":{"remote":{"url":"http://x","transport":"sse"}}}'
            Merge-SettingsJson $sysJson $prjJson
            # Project key overrides system for same key; both should exist
            $global:_CFG.ContainsKey("mcp_servers") | Should -BeTrue
        }
    }
}

Describe "Config.ps1 — Import-Config" {
    It "Does not throw when no settings files exist" {
        # Save and override project dir to temp location
        $oldDir = $global:PA_PROJECT_DIR
        $savedApiKey = $env:PA_API_KEY
        $env:PA_API_KEY = "test-key-for-config"
        $global:PA_PROJECT_DIR = Join-Path $env:TEMP "poweragent_test_nosettings_$(Get-Random)"
        try {
            { Import-Config } | Should -Not -Throw
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
            if ($savedApiKey) { $env:PA_API_KEY = $savedApiKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
        }
    }

    It "Sets PA_API_KEY from environment" {
        $savedApiKey = $env:PA_API_KEY
        $savedDeepseekKey = $env:DEEPSEEK_API_KEY
        $savedProjectDir = $global:PA_PROJECT_DIR
        $savedUserProfile = $env:USERPROFILE
        $env:PA_API_KEY = "test-key-config"
        $env:DEEPSEEK_API_KEY = $null
        # Redirect both project and system dirs to temp to avoid reading real settings
        $tempDir = Join-Path $env:TEMP "poweragent_test_importconfig_$(Get-Random)"
        $global:PA_PROJECT_DIR = $tempDir
        $env:USERPROFILE = $tempDir
        $global:_CFG = @{}
        try {
            Import-Config
            $global:PA_API_KEY | Should -Be "test-key-config"
        } finally {
            if ($savedApiKey) { $env:PA_API_KEY = $savedApiKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
            if ($savedDeepseekKey) { $env:DEEPSEEK_API_KEY = $savedDeepseekKey } else { Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
            $global:PA_PROJECT_DIR = $savedProjectDir
            $env:USERPROFILE = $savedUserProfile
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Sets PA_MODEL from environment or default" {
        $savedApiKey = $env:PA_API_KEY
        $global:_CFG = @{}
        $env:PA_API_KEY = "test-key-for-config"
        $env:PA_MODEL = ""
        try {
            Import-Config
            $global:PA_MODEL | Should -Not -BeNullOrEmpty
        } finally {
            if ($savedApiKey) { $env:PA_API_KEY = $savedApiKey } else { Remove-Item Env:PA_API_KEY -ErrorAction SilentlyContinue }
        }
    }
}

Describe "Config.ps1 — Import-PowerAgentMd" {
    It "Does not throw when no PowerAgent.md exists" {
        $oldDir = $global:PA_PROJECT_DIR
        $global:PA_PROJECT_DIR = Join-Path $env:TEMP "poweragent_test_nomd_$(Get-Random)"
        try {
            { Import-PowerAgentMd } | Should -Not -Throw
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
        }
    }

    It "Loads PowerAgent.md content into PA_MD" {
        $testDir = Join-Path $env:TEMP "poweragent_test_md_$(Get-Random)"
        $paDir = Join-Path $testDir ".poweragent"
        New-Item -ItemType Directory -Path $paDir -Force | Out-Null
        Set-Content (Join-Path $paDir "PowerAgent.md") "# Test Instructions`nBe helpful." -Encoding UTF8

        $oldDir = $global:PA_PROJECT_DIR
        $global:PA_PROJECT_DIR = $testDir
        $global:PA_MD = ""
        try {
            Import-PowerAgentMd
            $global:PA_MD | Should -Match "Test Instructions"
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
