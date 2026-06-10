# ============================================================================
#  PowerAgent.ps1 — Main Entry Point
#  PowerShell 5.1 port of bashagt Section 12 (lines 15515-15719)
#  CLI flag parsing, initialization sequence, mode dispatch.
# ============================================================================

# ── Resolve script root (PS5.1 compatible: no $PSScriptRoot in dot-sourced ctx) ──
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$script:PA_ROOT = $PSScriptRoot

# ── Mode & global state (pre-config defaults) ──
$script:PA_MODE = if ($env:PA_MODE) { $env:PA_MODE } else { "interactive" }
$script:PA_SESSION_ID = ""
$script:PA_STREAM_MODE = $true
$script:PA_OE_RAW = if ($env:PA_OE_RAW -eq "1") { $true } else { $false }
$script:PA_DEBUG = if ($env:PA_DEBUG -eq "1") { $true } else { $false }

# ============================================================================
#  CLI Flag Parsing
# ============================================================================

function Resolve-CliArgs {
    param([string[]]$Arguments)

    $i = 0
    while ($i -lt $Arguments.Count) {
        switch ($Arguments[$i]) {
            "--session" {
                if ($i + 1 -ge $Arguments.Count) {
                    Write-Host "[poweragent] ERROR: --session requires an argument" -ForegroundColor Red
                    exit 1
                }
                $script:PA_SESSION_ID = $Arguments[$i + 1]
                $script:PA_PROJECT_DIR = Join-Path $env:USERPROFILE ".poweragent\sessions\$($Arguments[$i + 1])"
                $i += 2
            }
            "--oneshot" {
                $script:PA_MODE = "oneshot"
                $i++
            }
            "--stream" {
                $script:PA_OE_RAW = $true
                $i++
            }
            "--install" {
                $script:PA_MODE = "install"
                $i++
            }
            "--uninstall" {
                $script:PA_MODE = "uninstall"
                $i++
            }
            "--update" {
                $script:PA_MODE = "update"
                $i++
            }
            "--run" {
                $script:PA_MODE = "run"
                $i++
            }
            "--debug" {
                $script:PA_DEBUG = $true
                $env:PA_DEBUG = "1"
                $i++
            }
            "--http-handler" {
                $script:PA_MODE = "http_handler"
                $i++
            }
            "--port" {
                if ($i + 1 -ge $Arguments.Count) {
                    Write-Host "[poweragent] ERROR: --port requires an argument" -ForegroundColor Red
                    exit 1
                }
                $script:PA_DAEMON_PORT = $Arguments[$i + 1]
                $i += 2
            }
            "--project-dir" {
                if ($i + 1 -ge $Arguments.Count) {
                    Write-Host "[poweragent] ERROR: --project-dir requires an argument" -ForegroundColor Red
                    exit 1
                }
                $script:PA_PROJECT_DIR = $Arguments[$i + 1]
                $i += 2
            }
            default {
                $i++
            }
        }
    }
}

# ============================================================================
#  Library Module List (dot-sourced inline in Start-PowerAgent to avoid
#  PS5.1 scope isolation — functions defined inside a nested function's
#  dot-source are lost when that function returns)
# ============================================================================

# Module list referenced by Start-PowerAgent's inline dot-source loop.
# Do NOT wrap in a function — PS5.1 function-scope dot-source does not
# propagate to the caller.

# ============================================================================
#  Install Mode
# ============================================================================

function Invoke-Install {
    Initialize-SystemDirs
    Write-Host "poweragent installed." -ForegroundColor Green
    Write-Host "1. Run 'poweragent' — it will guide you through provider & API key setup on first launch" -ForegroundColor White
    Write-Host "2. Or manually edit $env:USERPROFILE\.poweragent\settings.json, or set `$env:PA_API_KEY" -ForegroundColor Gray
    Write-Host "3. Start daemon: poweragent --run" -ForegroundColor Gray
}

# ============================================================================
#  Uninstall Mode
# ============================================================================

function Invoke-Uninstall {
    # Read PID from settings.json and stop daemon
    $settingsFile = Join-Path $env:USERPROFILE ".poweragent\settings.json"
    if (Test-Path $settingsFile) {
        try {
            $settings = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $pid = $settings.pid
            if ($pid -and (Test-ProcessAlive $pid)) {
                Write-Host "Stopping poweragent daemon (PID $pid)..."
                Stop-ProcessTree $pid
                Start-Sleep -Seconds 3
            }
        } catch {
            # Ignore JSON parse errors
        }
    }

    # Release port
    Stop-PortProcess 9655

    # Clean up temp files
    $tempDir = [System.IO.Path]::GetTempPath()
    Get-ChildItem $tempDir -Filter "poweragent_*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Remove poweragent entries from $PROFILE (PowerShell profile)
    $profilePath = $PROFILE
    if (Test-Path $profilePath) {
        $lines = Get-Content $profilePath -Encoding UTF8 |
            Where-Object { $_ -notmatch '# poweragent' -and $_ -notmatch 'poweragent\.ps1' }
        Set-Content $profilePath $lines -Encoding UTF8
    }

    # Remove symlink / script from PATH
    $binDir = if ($env:PA_BIN_DIR) { $env:PA_BIN_DIR } else { Join-Path $env:USERPROFILE ".local\bin" }
    $linkPath = Join-Path $binDir "poweragent.ps1"
    if (Test-Path $linkPath) {
        Remove-Item $linkPath -Force -ErrorAction SilentlyContinue
    }

    # Remove .poweragent directory
    $paDir = Join-Path $env:USERPROFILE ".poweragent"
    if (Test-Path $paDir) {
        Write-Host "Removing $paDir..."
        Remove-Item $paDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "poweragent uninstalled." -ForegroundColor Green
}

# ============================================================================
#  Update Mode
# ============================================================================

function Invoke-Update {
    # Stop daemon if running
    $settingsFile = Join-Path $env:USERPROFILE ".poweragent\settings.json"
    if (Test-Path $settingsFile) {
        try {
            $settings = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $pid = $settings.pid
            if ($pid -and (Test-ProcessAlive $pid)) {
                Write-Host "Stopping poweragent daemon (PID $pid)..."
                Stop-ProcessTree $pid
                Start-Sleep -Seconds 4
            }
        } catch { }
    }

    $paDir = Join-Path $env:USERPROFILE ".poweragent"
    if (-not (Test-Path $paDir)) {
        New-Item -ItemType Directory -Path $paDir -Force | Out-Null
    }

    # Copy self to ~/.poweragent/
    $selfPath = $MyInvocation.PSCommandPath
    if (-not $selfPath) {
        $selfPath = $PSCommandPath
    }
    if ($selfPath -and (Test-Path $selfPath)) {
        # Single-file mode: copy the merged script directly
        Copy-Item $selfPath (Join-Path $paDir "PowerAgent.ps1") -Force
    }

    # Copy lib/ directory (if exists, for development mode)
    $libSrc = Join-Path $script:PA_ROOT "lib"
    $libDst = Join-Path $paDir "lib"
    if (Test-Path $libSrc) {
        if (Test-Path $libDst) {
            Remove-Item $libDst -Recurse -Force
        }
        Copy-Item $libSrc $libDst -Recurse -Force
    }

    # Copy data/ directory
    $dataSrc = Join-Path $script:PA_ROOT "data"
    $dataDst = Join-Path $paDir "data"
    if (Test-Path $dataSrc) {
        if (-not (Test-Path $dataDst)) {
            Copy-Item $dataSrc $dataDst -Recurse -Force
        }
    }

    Write-Host "poweragent updated." -ForegroundColor Green
    Write-Host "To restart daemon: poweragent --run" -ForegroundColor Gray
}

# ============================================================================
#  Run Mode (Daemon)
# ============================================================================

function Invoke-RunDaemon {
    param([bool]$Foreground)

    $port = if ($script:PA_DAEMON_PORT) { [int]$script:PA_DAEMON_PORT } else { 9655 }
    $settingsFile = Join-Path $env:USERPROFILE ".poweragent\settings.json"

    # Write PID to settings.json
    $pid = $PID
    if (Test-Path $settingsFile) {
        try {
            $settings = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $settings | Add-Member -NotePropertyName "pid" -NotePropertyValue $pid -Force
            $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Encoding UTF8
        } catch {
            @{ pid = $pid } | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
        }
    } else {
        @{ pid = $pid } | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
    }

    if ($Foreground -or $script:PA_DEBUG) {
        $env:PA_LOG_LEVEL = "DEBUG"
        $script:PA_LOG_LEVEL_NUM = 0
        Write-Host "poweragent daemon on port $port (PID $pid) [foreground]" -ForegroundColor Cyan
        try {
            Start-Daemon -Port $port
        } finally {
            Stop-Daemon
            Save-History
        }
    } else {
        # Pre-check port
        if (Test-PortBusy $port) {
            Write-Host "[poweragent] ERROR: port $port already in use" -ForegroundColor Red
            exit 1
        }

        # Start daemon as background job (single-file mode: dot-source self)
        $daemonJob = Start-Job -ScriptBlock {
            param($selfPath, $port, $apiKey, $apiUrl, $model)
            . $selfPath
            $env:PA_API_KEY = $apiKey
            $env:PA_API_URL = $apiUrl
            $env:PA_MODEL = $model
            Start-Daemon -Port $port
        } -ArgumentList $PSCommandPath, $port, $script:PA_API_KEY, $script:PA_API_URL, $script:PA_MODEL

        Start-Sleep -Milliseconds 500

        # Verify daemon started
        $jobState = Get-Job -Id $daemonJob.Id
        if ($jobState.State -eq "Failed") {
            Write-Host "[poweragent] ERROR: daemon failed to start" -ForegroundColor Red
            Receive-Job $daemonJob
            Remove-Job $daemonJob -Force
            exit 1
        }

        # Update PID in settings.json to job process ID
        $daemonPid = $daemonJob.ChildJobs[0].Id
        try {
            if (Test-Path $settingsFile) {
                $settings = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $settings.pid = $daemonPid
                $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Encoding UTF8
            }
        } catch { }

        Write-Host "poweragent daemon started on port $port (PID $daemonPid)" -ForegroundColor Green
    }
}

# ============================================================================
#  Main Initialization Sequence
# ============================================================================

function Start-PowerAgent {
    param([string[]]$Arguments = @())

    # ── 0. 抑制所有进度条/通知，防止 ConPTY 原地覆写导致 CJK 字符重复 ──
    $ProgressPreference = 'SilentlyContinue'

    # ── 1. Parse CLI args ──
    Resolve-CliArgs $Arguments

    # ── 2. Dot-source all library modules (inline — must NOT be in a sub-function) ──
    $modules = @(
        "ModelProfiles.ps1"
        "Defaults.ps1"
        "Utils.ps1"
        "Config.ps1"
        "Messages.ps1"
        "HttpClient.ps1"
        "Tools.ps1"
        "Trace.ps1"
        "Compression.ps1"
        "AgentSystem.ps1"
        "McpClient.ps1"
        "AgentLoop.ps1"
        "Daemon.ps1"
    )
    # Modules inlined directly into this file (no lib/ dot-source needed)
    # foreach ($mod in $modules) { . (Join-Path $script:PA_ROOT "lib\$mod") }

    # ── 3. Initialize logging (must precede any Write-Log/Write-Die calls) ──
    Initialize-Log

    Write-Log "DEBUG: [INIT] main: mode=$($script:PA_MODE) project_dir=${script:PA_PROJECT_DIR} session=${script:PA_SESSION_ID} pid=$PID"

    # ── 4. Mode dispatch: install/uninstall/update ──
    switch ($script:PA_MODE) {
        "uninstall" {
            Invoke-Uninstall
            return
        }
        "update" {
            Invoke-Update
            return
        }
        "install" {
            Invoke-Install
            return
        }
    }

    # ── 5. Initialize directories ──
    Initialize-SystemDirs
    Initialize-ProjectDirs

    # ── 6. Initialize trace system ──
    Initialize-Trace

    # ── 7. Load configuration ──
    Import-Config

    # ── 8. Load PowerAgent.md (project-level instructions) ──
    Import-PowerAgentMd

    # ── 9. Dependency check (skip for oneshot — parent already validated) ──
    if ($script:PA_MODE -ne "oneshot") {
        Test-Dependencies | Out-Null
    }

    # ── 10. Load agents, skills, hooks ──
    Import-Agents
    Import-Skills
    if ($script:PA_PROJECT_DIR) {
        Import-Hooks -Dir $script:PA_PROJECT_DIR
    }

    # Register built-in pre_turn hook: inject active job summary
    Register-Hook -Name "builtin_job_context" -Point "pre_turn" -Handler "return @()" -Type "inline_ps" -Priority 50

    # ── 11. Initialize TODOs ──
    Import-Todos

    # ── 12. Load memory ──
    Import-Memories

    # ── 13. Load history ──
    Load-History

    # ── 14. MCP initialization (graceful: failures don't prevent startup) ──
    if ($script:PA_MCP_ENABLED -eq "true" -and $script:PA_MODE -ne "run") {
        try {
            Initialize-Mcp
        } catch {
            Write-Log "WARN: MCP initialization had errors: $_"
        }
    }

    # ── 15. Daemon mode ──
    if ($script:PA_MODE -eq "run") {
        Invoke-RunDaemon -Foreground:$script:PA_DEBUG
        return
    }

    # ── 16. Register SIGINT/exit handlers ──
    # PowerShell doesn't have bash-style traps; use try/finally for cleanup
    try {
        # ── 17. Fire post_init hook ──
        $piCtx = @{
            project = @{ dir = $script:PA_PROJECT_DIR }
            system  = @{
                model       = $script:PA_MODEL
                agents      = @()
                skills      = @()
                mcp_servers = @()
            }
        }

        $piResults = Invoke-HookFire "post_init" $piCtx
        if ($piResults -and $piResults.Count -gt 0) {
            foreach ($item in $piResults) {
                if ($item.inject -eq $true -and $item.content) {
                    Add-MessageUserText $item.content
                }
            }
        }

        # ── 18. Register built-in slash commands ──
        Register-BuiltinSlashCommands

        # ── 18.5 Promote PA_MODE to global for AgentLoop access ──
        $global:PA_MODE = $script:PA_MODE

        # ── 19. Start the agent loop ──
        Start-AgentLoop

    } finally {
        # Cleanup on exit
        Write-Log "DEBUG: [EXIT] Cleaning up..."
        try {
            Stop-WorkerShutdown
        } catch { }
        try {
            Stop-Mcp
        } catch { }
        try {
            Save-History
        } catch { }
        try {
            Invoke-HookFire "on_cleanup" "{}" | Out-Null
        } catch { }
    }
}

# ============================================================================
#  Stub functions for cleanup (will be overridden by loaded modules)
# ============================================================================

function Stop-WorkerShutdown { }
function Stop-Mcp { }
function Invoke-HookFire { param($Hook, $Ctx); return @() }
function Add-MessageUserText { param([string]$Text) }

# ============================================================================
#  Entry Point moved to end of file (after all function definitions)
#  PowerShell 5.1 parses top-down; functions must be defined before entry guard
# ============================================================================



# ============================================================================
#  Inlined: ModelProfiles.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - ModelProfiles.ps1
#  Per-LLM vendor configuration profiles
#  Records API differences between model providers (request format, response
#  format, feature support, quirks) so HttpClient can adapt automatically.
# ============================================================================

# ── Profile Registry ──
# Each profile keyed by vendor name (matched from URL patterns)
# Resolved at config load time into $global:PA_MODEL_PROFILE

$global:MODEL_PROFILES = @{
    deepseek = @{
        vendor          = "deepseek"
        protocol        = "openai"          # OpenAI-compatible Chat Completions

        # ── Thinking / Reasoning ──
        # DeepSeek thinking mode: {"thinking": {"type": "enabled"}}
        # NOT budget_tokens — DeepSeek uses reasoning_effort for intensity
        thinking_mode   = "deepseek"        # "deepseek" | "anthropic" | "none"
        thinking_param  = @{ type = "enabled" }          # Value for "thinking" key in request body
        reasoning_effort_default = "high"                # "high" | "max"
        # thinking_budget is NOT used by DeepSeek (ignored)

        # ── Unsupported params (silently ignored but we strip them) ──
        unsupported_params = @("temperature", "top_p", "presence_penalty", "frequency_penalty")

        # ── Response format ──
        # reasoning_content is at response.choices[0].message.reasoning_content
        has_reasoning_content = $true

        # ── Tool calling ──
        # Uses OpenAI format: type="function", function={name, description, parameters}
        # Tool results: role="tool", tool_call_id=xxx, content=string
        tool_result_role    = "tool"         # "tool" (OpenAI) | "user" (Anthropic)

        # ── Auth ──
        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        # ── Streaming ──
        # SSE events have delta.reasoning_content for thinking
        stream_reasoning_field = "reasoning_content"

        # ── Multi-turn context ──
        # When tool_calls happen, reasoning_content MUST be preserved in context
        preserve_reasoning_in_context = $true

        # ── Quirks ──
        # max_tokens: DeepSeek uses max_tokens (not max_completion_tokens)
        # finish_reason: "tool_calls" (not "function_call")
        # empty tool_calls = null (not [])
        force_max_tokens = 384000     # DeepSeek V4: 384K max output
    }

    openai = @{
        vendor          = "openai"
        protocol        = "openai"

        thinking_mode   = "none"
        thinking_param  = $null
        reasoning_effort_default = $null
        unsupported_params = @()

        has_reasoning_content = $false
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = $null
        preserve_reasoning_in_context = $false

        force_max_tokens = 128000     # GPT-5.5: 128K max output
    }

    anthropic = @{
        vendor          = "anthropic"
        protocol        = "anthropic"

        # Anthropic thinking: {"thinking": {"type": "enabled", "budget_tokens": N}}
        thinking_mode   = "anthropic"
        thinking_param  = $null  # Built dynamically with budget_tokens
        reasoning_effort_default = $null

        unsupported_params = @()

        has_reasoning_content = $true
        tool_result_role      = "user"       # Anthropic wraps tool results in user message

        auth_header     = "x-api-key"
        auth_prefix     = ""

        stream_reasoning_field = "thinking"
        preserve_reasoning_in_context = $true

        force_max_tokens = 128000     # Claude Opus 4.8: 128K max output
    }

    aliyun = @{
        vendor          = "aliyun"
        protocol        = "openai"

        # Qwen: enable_thinking=true (top-level), thinking_budget=N (top-level)
        thinking_mode   = "qwen"
        thinking_param  = $null
        reasoning_effort_default = $null
        unsupported_params = @("reasoning_effort", "frequency_penalty")

        has_reasoning_content = $true
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = "reasoning_content"
        preserve_reasoning_in_context = $true

        # Qwen3.7-max output limit: 65536 tokens
        force_max_tokens = 65536
    }

    baidu = @{
        vendor          = "baidu"
        protocol        = "openai"

        # ERNIE-5.1: thinking is ALWAYS ON, no param needed
        # Supports thinking_budget + reasoning_effort but auto-enabled
        thinking_mode   = "baidu"
        thinking_param  = $null
        reasoning_effort_default = $null
        unsupported_params = @("logprobs")

        has_reasoning_content = $true
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = "reasoning_content"
        preserve_reasoning_in_context = $false   # Baidu: MUST DELETE reasoning_content in multi-turn or 400

        # ── Quirks ──
        # Default max_tokens only 2K — must send explicitly
        # Multi-turn: reasoning_content in messages causes 400 error — must strip
        strip_reasoning_in_context = $true
        force_max_tokens = 128000     # ERNIE-5.1: 128K max output (200K context)
    }

    zhipu = @{
        vendor          = "zhipu"
        protocol        = "openai"

        # GLM: thinking:{type:"enabled"} (same format as DeepSeek)
        thinking_mode   = "deepseek"       # Same format as DeepSeek
        thinking_param  = @{ type = "enabled" }
        reasoning_effort_default = $null
        unsupported_params = @("reasoning_effort")

        has_reasoning_content = $true
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = "reasoning_content"
        preserve_reasoning_in_context = $true

        # ── Quirks ──
        # tool_choice only supports "auto"
        # Extra finish_reasons: sensitive, network_error, model_context_window_exceeded
        force_max_tokens = 128000     # GLM-5.1: 128K max output (200K context)
    }

    moonshot = @{
        vendor          = "moonshot"
        protocol        = "openai"

        # Kimi: thinking:{type:"enabled"} (same format as DeepSeek)
        thinking_mode   = "moonshot"
        thinking_param  = @{ type = "enabled" }
        reasoning_effort_default = $null
        unsupported_params = @("reasoning_effort", "thinking_budget")

        has_reasoning_content = $true
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = "reasoning_content"
        preserve_reasoning_in_context = $true

        # ── Quirks ──
        # k2.5/k2.6 MUST: temperature=1.0, top_p=0.95, n=1 (other values cause error)
        # tool_choice only auto/none in thinking mode
        force_temperature = 1.0
        force_top_p       = 0.95
        force_max_tokens  = 32768      # Kimi K2.6: 32K max output (256K context)
    }

    minimax = @{
        vendor          = "minimax"
        protocol        = "openai"

        # MiniMax: thinking:{type:"adaptive"}
        thinking_mode   = "minimax"
        thinking_param  = @{ type = "adaptive" }
        reasoning_effort_default = $null
        unsupported_params = @("reasoning_effort")

        # ── Unique response format ──
        # reasoning_details is an ARRAY of objects, NOT a plain string
        # [{type:"reasoning.text", text:"...", id:"...", format:"MiniMax-response-v1", index:0}]
        has_reasoning_content = $false
        has_reasoning_details = $true    # MiniMax-specific: array format
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = "reasoning_details"
        preserve_reasoning_in_context = $true

        # ── Quirks ──
        # reasoning_split=true for structured reasoning_details
        # Streaming chunks have cumulative text (not incremental)
        force_max_tokens = 256000     # MiniMax M3: 256K max output (1M context)
    }

    generic_openai = @{
        vendor          = "generic"
        protocol        = "openai"

        thinking_mode   = "none"
        thinking_param  = $null
        reasoning_effort_default = $null
        unsupported_params = @()

        has_reasoning_content = $false
        tool_result_role      = "tool"

        auth_header     = "Authorization"
        auth_prefix     = "Bearer "

        stream_reasoning_field = $null
        preserve_reasoning_in_context = $false
    }
}

function Resolve-ModelProfile {
    <#
    .SYNOPSIS
    Detect vendor profile from API URL and model name.
    Sets $global:PA_MODEL_PROFILE.
    #>
    param([string]$Url, [string]$Model)

    if ($Url -match "deepseek\.com") {
        return $global:MODEL_PROFILES["deepseek"]
    }
    if ($Url -match "anthropic\.com|/anthropic/") {
        return $global:MODEL_PROFILES["anthropic"]
    }
    if ($Url -match "openai\.com") {
        return $global:MODEL_PROFILES["openai"]
    }
    if ($Url -match "dashscope\.aliyuncs\.com") {
        return $global:MODEL_PROFILES["aliyun"]
    }
    if ($Url -match "qianfan\.baidubce\.com") {
        return $global:MODEL_PROFILES["baidu"]
    }
    if ($Url -match "open\.bigmodel\.cn") {
        return $global:MODEL_PROFILES["zhipu"]
    }
    if ($Url -match "api\.moonshot\.cn") {
        return $global:MODEL_PROFILES["moonshot"]
    }
    if ($Url -match "api\.minimaxi\.com") {
        return $global:MODEL_PROFILES["minimax"]
    }
    # Model name hints
    if ($Model -match "^deepseek") {
        return $global:MODEL_PROFILES["deepseek"]
    }
    if ($Model -match "^claude") {
        return $global:MODEL_PROFILES["anthropic"]
    }
    if ($Model -match "^gpt-|^o[1-4]") {
        return $global:MODEL_PROFILES["openai"]
    }
    if ($Model -match "^qwen") {
        return $global:MODEL_PROFILES["aliyun"]
    }
    if ($Model -match "^ernie") {
        return $global:MODEL_PROFILES["baidu"]
    }
    if ($Model -match "^glm-") {
        return $global:MODEL_PROFILES["zhipu"]
    }
    if ($Model -match "^kimi-") {
        return $global:MODEL_PROFILES["moonshot"]
    }
    if ($Model -match "^MiniMax-") {
        return $global:MODEL_PROFILES["minimax"]
    }
    # Default: generic OpenAI-compatible
    return $global:MODEL_PROFILES["generic_openai"]
}

function Get-ModelProfile {
    <# Return current model profile. Re-resolves on every call for testability. #>
    $url = $global:PA_API_URL
    $model = $global:PA_MODEL
    # 始终从 URL/Model 重新解析（避免 Pester v5 scope 缓存问题）
    $profile = Resolve-ModelProfile -Url $url -Model $model
    return $profile
}


# ============================================================================
#  Inlined: Defaults.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Defaults.ps1
#  Section 1: Built-in Defaults & System Prompt
#  PowerShell 5.1 port of bashagt Section 1 (lines 1-511)
# ============================================================================

# ── Version ──
$global:PA_VERSION = "preview-0.17"

# ── API Configuration Defaults ──
$global:DEFAULT_API_URL = "https://api.deepseek.com/v1/chat/completions"
$global:DEFAULT_MODEL = "deepseek-v4-pro"
$global:DEFAULT_MAX_TOKENS = "384000"
$global:DEFAULT_THINKING_BUDGET = "100000"
$global:DEFAULT_API_PROTOCOL = "auto"
$global:DEFAULT_CONNECT_TIMEOUT = "10"
$global:DEFAULT_CMD_TIMEOUT = "300"
$global:DEFAULT_COMPRESS_THRESHOLD = "250000"
$global:DEFAULT_SHOW_THINKING = "status"

# ── Format Sub-agent Defaults ──
$global:DEFAULT_FORMAT_SUBAGENT = "true"
$global:DEFAULT_FORMAT_MAX_TOKENS = "65536"

# ── Web Search Defaults ──
$global:DEFAULT_WEB_SEARCH_ENGINE = "baidu"
$global:DEFAULT_WEB_SEARCH_TIMEOUT = "10"

# ── Memory Defaults ──
$global:DEFAULT_MEMORY_ENABLED = "true"
$global:DEFAULT_MEMORY_MAX_CONTEXT = "200"
$global:DEFAULT_MEM_ENGRAM_COUNT = "16"
$global:DEFAULT_MEM_ENGRAM_SLOTS = "200"

# ── Adaptive Agent Loop Defaults ──
$global:DEFAULT_TURN_BUDGET_SOFT = "96000"
$global:DEFAULT_TURN_BUDGET_HARD = "128000"

# ── Trace Defaults ──
$global:DEFAULT_TRACE_ENABLED = "1"
$global:DEFAULT_TRACE_MAX_FRAMES = "1000"
$global:DEFAULT_TRACE_SNAPSHOT_INTERVAL = "50"
$global:DEFAULT_TRACE_PRUNE_KEEP = "200"

# ── Context Window Defaults ──
$global:DEFAULT_CONTEXT_WINDOW = "1048576"
$global:DEFAULT_CONTEXT_SAFE_RATIO = "75"
$global:DEFAULT_STUCK_THRESHOLD = "3"

# ── TODO Defaults ──
$global:DEFAULT_TODO_ENABLED = "true"
$global:DEFAULT_TODO_MAX_CONTEXT = "15"

# ── MCP Defaults ──
$global:DEFAULT_MCP_ENABLED = "true"
$global:DEFAULT_MCP_CONNECT_TIMEOUT = "10"
$global:DEFAULT_MCP_REQUEST_TIMEOUT = "60"

# ── Other Defaults ──
$global:DEFAULT_PROJECT_DIR = "."
$global:DEFAULT_DAEMON_PORT = "9655"
$global:DEFAULT_SUBPROC_MAX = "64"
$global:DEFAULT_CACHE_ENABLED = "true"
$global:DEFAULT_CACHE_MSG_TAIL = "2"
$global:DEFAULT_CACHE_PROBE_MAX_MISSES = "3"
$global:DEFAULT_CACHE_PROBE_REPROBE = "900"
$global:DEFAULT_CACHE_API_SUPPORT = "auto"
$global:DEFAULT_CACHE_MARKER = '{"cache_control":{"type":"ephemeral"}}'
$global:DEFAULT_DARK_MODE = "true"
$global:DEFAULT_PROXY_NOPROXY = "localhost,127.0.0.1,::1"

# ============================================================================
#  System Prompt Assembly
# ============================================================================

$global:_SP_PREAMBLE = @'
你是一个交互式代理。请根据以下指令和可用工具协助用户。

重要提示：除非你确信 URL 是用于帮助用户完成编程任务的，否则绝不要为用户生成或猜测 URL。你可以使用用户消息或本地文件中提供的 URL。

注意：你的思考过程（thinking）可以使用英文，但与用户的对话必须使用中文。

'@

$global:_SP_IDENTITY = @'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§1 — 角色与身份
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

- 你是 PowerAgent，一个用纯 PowerShell 实现的 LLM 智能体内核。
- 你以 CLI 编码助手的身份运行，拥有文件系统访问权限。
- 你的输出会被自动格式化为终端显示格式。专注于内容，而非排版。
- 简洁、直接、高效。直接给出答案——代码、文件路径、发现或结论。省略所有对话填充语：不要说"好的！"、"让我来帮你"、"我来处理一下"，不要打招呼，不要告别。
- 与用户对话使用中文。思考过程（thinking）可以使用英文。

'@

$global:_SP_SAFETY = @'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§2 — 安全红线
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

你可以协助：授权的安全测试、防御性安全研究、CTF 挑战和教育场景。

你必须拒绝涉及以下内容的请求：破坏性技术、DoS 攻击、大规模目标扫描、供应链攻击、或用于恶意目的的检测规避。

限制层级（按优先级从高到低）：
  硬性红线（绝不可违反）：拒绝破坏性技术、DoS、供应链攻击。
  强默认（仅在用户明确指令时才可覆盖）：除非用户明确要求，否则不要修改文件。对于分析、解释、讨论、探索和建议，默认为只读模式。
  用户强制（安全模式，§2.1）：用户可以启用确认层，在执行 write_file/edit_file/delete_file/powershell 前进行拦截。当工具返回 {"status":"denied","reason":"Safe mode: ..."} 时，这是用户的明确拒绝——不要重试同一个工具。

当用户在以下场景时，默认只读：
- 分析/诊断："有没有 bug？"、"崩溃是什么原因？"
- 解释/理解："X 是做什么的？"、"Y 是怎么工作的？"
- 讨论/评审："你觉得这段代码怎么样？"
- 探索："找出所有调用 Z 的地方"、"哪些文件处理认证？"
- 建议："这可以改进吗？"（没有说"动手改"）

仅在用户明确要求时才修改：
- "修一下" / "把 X 改成 Y" / "添加/实现 Z"
- "重构" / "重写" / "更新代码"
- "删掉这个" / "把 A 重命名为 B"

如果你发现了值得修复的问题但用户没有要求你修复：指出问题，说明应该怎么改，然后询问用户是否继续。绝不静默修改。拿不准时，只读是安全的默认选择。

对于多步骤实现工作（3个以上文件或架构级变更）：
- 你必须先创建计划（通过 agent("plan", ...) 或自行设计），然后在写代码前调用 make_todos(plan_text) 将步骤提取为可跟踪的 TODO 项。
- 绝不在没有 TODO 的情况下开始编码——未跟踪的多步骤工作会丢失进度可见性，增加不完整或乱序变更的风险。
- 每个 TODO 在开始前标记 in_progress，完成后标记 completed/failed。

在执行任何 powershell 命令或修改文件之前：
- 评估操作的影响范围和爆炸半径。
- 对于高风险操作，使用 request() 工具（参见 §5）。
- 保护项目和系统安全是你的最高优先级。

§2.1 — 安全模式拒绝：安全模式激活时，破坏性工具（write_file、edit_file、delete_file、powershell）在执行前会被拦截，要求用户确认。如果 tool_result 返回 {"status":"denied","reason":"Safe mode: <tool> was denied by user."}，说明用户在确认对话框中明确选择了"否，取消"。这是明确的用户拒绝——不是临时错误或系统故障。关键规则：
  1. 不要重试同一个工具。拒绝不会改变。
  2. 向用户说明操作被安全模式阻止。
  3. 建议用户在对话框出现时批准，或按 Shift+Tab 禁用安全模式。

'@

$global:_SP_BEHAVIOR = @'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§3 — 行为准则
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

- 先读后改。绝不要对没有阅读和理解的文件提出修改建议。先理解现有资源（代码、文档、配置）。
- 对于超过 50KB 的文件或超过 3 个文件的项目，先将探索工作委托给 explore 子代理。
- 做针对性修改。不要添加超出任务要求的功能、重构或引入抽象。
- 不要为假设的未来需求做设计。
- 在从头实现之前，先穷尽可用资源：检查现有的技能（skills）、代理（agents）、MCP 工具和内置工具，然后才写新代码。
- 如果一种方法失败了，在切换策略之前先诊断根本原因。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§4 — 操作安全
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

在操作前仔细考虑可逆性和影响范围。
只读操作无需确认即可执行。
状态变更操作先评估影响。
难以逆转的操作使用 request() 与用户确认。

重要提示：用户对某一项操作的批准，不代表对该类所有操作的批准。授权范围限于具体操作，而非操作类别。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§5 — 工具使用
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

发现——在编写任何代码之前，先检查已有的资源：
  list_skills     → 包含可复用工作流和专业知识的技能
  list_agents     → 拥有独立工具集的专业子代理
  list_mcp_tools  → 外部集成（数据库、API、服务）

文件分析流程——当用户要求分析、诊断或处理文件时：
  1. list_files(path, recursive=true) 查看目录结构
  2. 立即使用 read_file 读取关键文件内容——不要反复调用 list_files
  3. 基于文件内容进行分析，而非仅凭文件名
  重要：list_files 只返回文件名和元数据，不返回文件内容。要分析文件内容必须使用 read_file。

文件格式支持——read_file 已内置以下格式的智能读取：
  - .xlsx/.xls：自动使用 ImportExcel 模块读取，返回格式化表格文本（行×列）
  - .docx：自动提取 Word 文档段落文本
  - .csv/.json/.xml 等文本文件：直接读取
  - 其他二进制文件：返回文件大小信息
  处理 xlsx 数据的流程（严格遵守，不可跳过步骤）：
  1. read_file("file.xlsx") 查看数据结构——仅调用一次（默认返回前20行预览）
  2. 立即使用 process_excel 工具处理数据——这是专门为 Excel 处理设计的工具，已预加载 ImportExcel
  3. process_excel 示例：
     script: '$data = Import-Excel -Path "input.xlsx"; $clean = $data | Where-Object { $_.订单号 } | Sort-Object 订单号 -Unique; $clean | Export-Excel -Path "output.xlsx"'
  4. 如需复杂多步操作，也可以用 powershell 运行 PowerShell 命令，但优先使用 process_excel
  5. docx 文件同理：read_file 一次 → powershell + .NET/COM 处理
  
  绝对禁止：对同一文件连续调用 read_file 超过 2 次。如果已读取过文件内容，下一步必须是 powershell 执行处理命令。

决策层级——当任务需要行动时：
  1. skill("name", "task")      如果有活跃技能适合该任务
  2. agent("name", "prompt")    如果有子代理适合（plan、review、explore...）
  3. mcp__<srv>__<tool>(...)    如果有外部 MCP 工具适合
  4. 内置工具                    read_file、edit_file、write_file、list_files...
  5. process_excel              xlsx 数据处理（优先于 powershell）
  6. powershell                  原始 PowerShell 命令
  7. 从零编写                    最后手段——仅当以上都不适用时

必须：使用专用内置工具，绝不以 bash 替代。

文件编辑：
  先 read_file 再 edit_file 修改。edit_file 在应用前会显示差异。
  write_file 仅用于新文件。它会拒绝覆盖。
  对于已有文件：始终使用 edit_file，不用 write_file。
  old_string 必须与文件内容完全匹配——从 read_file 输出中复制精确文本。

删除文件：
  使用 delete_file 删除文件或目录。它在删除前会追踪内容，以便 undo 可以恢复。

撤销 vs 编辑——何时回退 vs 正向修正：
  edit_file 是修复错误的默认方式。
  undo 是最后手段，需要人工确认，用于撤销整个先前的修改。

工具失败：如果工具调用失败，阅读错误信息。对于临时错误（超时、网络），重试一次。对于输入错误，重新检查并修正后再试。

请求确认——request("prompt", ["opt1","opt2",...], "context?") 用于请求人工监督：
  关键：request 必须是一轮中唯一的 tool_use 块。

计划 → TODO 工作流——多步骤实现时必须使用：
  在实现任何需要 3 步以上的任务之前，你必须先创建可跟踪的 TODO 项。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§6 — 子代理委托
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

使用 agent("agent_name", "prompt") 将复杂的多步骤工作委托给专业子代理。子代理有自己的工具集，可以跨多轮工作。

关键委托模式：
  plan — 在编码前设计实现计划。
  explore — 广泛的代码库搜索和探索。
  summarize — 将长内容浓缩为简洁摘要。
  mem_writer — 将重要事实路由到持久记忆网络。
  agent_manager — 创建、更新和删除项目级子代理。

并行子代理委托
  agent_batch — 在单轮中并行执行最多 4 个子代理。

异步子代理委托
  agent("name", "prompt", async=true) → 立即返回 job_id。
  job_poll(job_id) → 检查状态。
  job_result(job_id) → 阻塞等待直到完成，返回输出。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
§7 — 调试约束
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 首次诊断不可靠。
2. 先复现再修复。
3. 隔离故障。
4. 一次修一个。
5. 知道何时停止——连续 3 次修复失败后，报告并询问用户。

停止原因协议（严格遵守）：
  - end_turn：仅用于最终答案。不允许工具调用。
  - tool_use：用于调用工具。必须包含可见文本、工具调用，或两者兼有。
  - 你的思考块对用户不可见——将所有重要信息放在可见文本中。
  - 仅含思考的轮次（没有可见文本也没有工具）会被拒绝。
'@

# ── Assembled System Prompt ──
$global:DEFAULT_SYSTEM_PROMPT = $global:_SP_PREAMBLE + $global:_SP_IDENTITY + $global:_SP_SAFETY + $global:_SP_BEHAVIOR

# ── Behavioral Rules Reminder (injected every turn via _HOOK_CONTEXT_BUFFER) ──
$global:_RULES_REMINDER_TEXT = @"
--- RULES REMINDER ---
1. 确认明确的编辑请求后再修改。不确定时使用 request() 确认。
2. 将探索工作委托给 explore agent，不要盲目 read_file 大型项目。
3. 使用 edit_file 修改现有文件，write_file 创建新文件。先读取，匹配原始内容。不用 sed/awk。
4. 修复前先复现 bug。初步诊断常常是错的——验证根因。
5. 多步骤工作需要先建 TODO。规划后调用 make_todos()，用 task_update() 跟踪进度。
6. 高风险操作需要 request() 确认。先评估影响范围。
7. 永远不要用 cat/head/tail/ls 替代 read_file/list_files。
8. 将复杂工作委托给 agent。用 agent_batch 处理并行独立任务。
9. 修改前先阅读现有代码。不要假设——用 read_file 验证。
10. 破坏性操作（rm -rf、force-push、hard reset）需要用户批准。
11. 端到端测试后才能声称成功。检查正常路径和边界情况。
12. 将重要决策和偏好保存到 memory。用 /remember 持久化。
13. 先设计方案。复杂任务委托给 plan agent。
14. 简洁为先。直接给答案——跳过寒暄、填充、签名。
15. 工具失败两次就报告错误。不要盲目重试。
"@

# ── Logging Subsystem State ──
$global:LOG_DIR = ""
$global:LOG_LEVEL_NUM = 0
$global:LOG_STDERR_LEVEL_NUM = 1
$global:_LOG_BUF = [System.Collections.Generic.List[string]]::new()
$global:_LOG_BUF_MAX = 32
$global:_ERR_TRAP_GUARD = $false
$global:_ACCESS_BUF = [System.Collections.Generic.List[string]]::new()


# ============================================================================
#  Inlined: Utils.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Utils.ps1
#  Section 2: Utilities, Logging, Display, Terminal Helpers
#  PowerShell 5.1 port of bashagt Section 2 (lines 513-4939)
# ============================================================================

# ── Enable Virtual Terminal Processing (PS 5.1 requires explicit opt-in) ──
if (-not $global:_TUI_INITIALIZED) {
    try {
        $vtCode = @"
[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")]
public static extern IntPtr GetStdHandle(uint n);
"@
        $k32 = Add-Type -MemberDefinition $vtCode -Name "VtInit" -Namespace "TUI" -PassThru -ErrorAction Stop
        $hOut = $k32::GetStdHandle([uint32]0xFFFFFFF5) # STD_OUTPUT_HANDLE = -11
        $mode = [uint32]0
        $k32::GetConsoleMode($hOut, [ref]$mode)
        $k32::SetConsoleMode($hOut, $mode -bor [uint32]0x0004)
    } catch {
        # VT Processing unavailable — colors will degrade gracefully
    }
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $global:_TUI_INITIALIZED = $true
}

# ── ANSI Terminal Escape Codes (Windows Terminal / ConEmu compatible) ──
$global:ESC   = [char]27
$global:BOLD  = "${global:ESC}[1m"
$global:DIM   = "${global:ESC}[2m"
$global:GREEN = "${global:ESC}[32m"
$global:CYAN  = "${global:ESC}[36m"
$global:YELLOW = "${global:ESC}[33m"
$global:RED   = "${global:ESC}[31m"
$global:GRAY  = "${global:ESC}[90m"
$global:RESET = "${global:ESC}[0m"
$global:INVERT = "${global:ESC}[7m"
$global:LIGHT_GREEN = "${global:ESC}[92m"
$global:LIGHT_YELLOW = "${global:ESC}[93m"
$global:LIGHT_PINK = "${global:ESC}[38;5;218m"
$global:LIGHT_CYAN = "${global:ESC}[1;36m"
$global:BLUE  = "${global:ESC}[34m"
$global:LIGHT_BLUE = "${global:ESC}[94m"
$global:LIGHT_RED = "${global:ESC}[91m"
$global:WHITE = "${global:ESC}[97m"
$global:BG_BLUE = "${global:ESC}[44;97m"
$global:BG_GRAY = "${global:ESC}[100;97m"

# ── UI Icons (Unicode, degrade gracefully on old ConHost) ──
$global:ICON_ARROW  = [char]0x25B8  # ▸
$global:ICON_STAR   = [char]0x2726  # ✦ (was 0x2666)
$global:ICON_CHECK  = [char]0x2714  # ✔
$global:ICON_CROSS  = [char]0x2718  # ✘
$global:ICON_WARN   = [char]0x26A0  # ⚠
$global:ICON_GEAR   = [char]0x2699  # ⚙
$global:ICON_BOLT   = [char]0x26A1  # ⚡

# ── Spinner frames ──
$global:SPINNER = @([char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x2834, [char]0x2824, [char]0x2826, [char]0x2827, [char]0x2807, [char]0x280F)
$global:SPINNER_IDX = 0
$global:STATUS_ACTIVE = 0

# ── Slash Command Registry (hashtable replaces Bash associative array) ──
$global:SLASH_COMMANDS = @{}

function Register-Slash {
    param([string]$Command, $Handler)
    $global:SLASH_COMMANDS[$Command] = $Handler
}

function Invoke-SlashDispatch {
    param([string]$CommandInput)
    $trimmed = $CommandInput.Trim()
    $cmd = ($trimmed -split '\s+',2)[0]
    $cmd = $cmd.TrimStart('/')
    $handler = $global:SLASH_COMMANDS[$cmd]
    if (-not $handler) { return $false }
    $global:_SLASH_FALLTHROUGH = $false
    Write-Log "DEBUG: SLASH       cmd=$cmd"
    & $handler $trimmed
    return $true
}

# ============================================================================
#  Logging Functions
# ============================================================================

function Write-LogFlush {
    if ($global:LOG_DIR -and (Test-Path $global:LOG_DIR)) {
        if ($global:_LOG_BUF.Count -gt 0) {
            $global:_LOG_BUF | Out-File -FilePath (Join-Path $global:LOG_DIR "poweragent.log") -Append -Encoding UTF8
            $global:_LOG_BUF.Clear()
        }
        if ($global:_ACCESS_BUF.Count -gt 0) {
            $global:_ACCESS_BUF | Out-File -FilePath (Join-Path $global:LOG_DIR "access.log") -Append -Encoding UTF8
            $global:_ACCESS_BUF.Clear()
        }
    } else {
        $global:_LOG_BUF.Clear()
        $global:_ACCESS_BUF.Clear()
    }
}

function Initialize-Log {
    # ── Log directory resolution ──
    if ($env:PA_LOG_DIR) {
        $global:LOG_DIR = $env:PA_LOG_DIR
    } elseif ($global:PA_MODE -eq "http_handler" -or $global:PA_MODE -eq "install" -or $global:PA_MODE -eq "run") {
        $global:LOG_DIR = Join-Path $env:USERPROFILE ".poweragent\log"
    } elseif ($global:PA_PROJECT_DIR -and $global:PA_PROJECT_DIR -ne ".") {
        $global:LOG_DIR = Join-Path $global:PA_PROJECT_DIR ".poweragent\log"
    } else {
        $global:LOG_DIR = ".\.poweragent\log"
    }
    if (-not (New-Item -ItemType Directory -Path $global:LOG_DIR -Force -ErrorAction SilentlyContinue)) {
        $global:LOG_DIR = Join-Path $env:TEMP "poweragent_${PID}_log"
        if (-not (New-Item -ItemType Directory -Path $global:LOG_DIR -Force -ErrorAction SilentlyContinue)) {
            $global:LOG_DIR = ""
        }
    }

    # ── Log level ──
    $level = if ($env:PA_LOG_LEVEL) { $env:PA_LOG_LEVEL } else { "DEBUG" }
    switch ($level.ToUpper()) {
        "DEBUG" { $global:LOG_LEVEL_NUM = 0 }
        "INFO"  { $global:LOG_LEVEL_NUM = 1 }
        "WARN"  { $global:LOG_LEVEL_NUM = 2 }
        "ERROR" { $global:LOG_LEVEL_NUM = 3 }
        "FATAL" { $global:LOG_LEVEL_NUM = 4 }
        default { $global:LOG_LEVEL_NUM = 1 }
    }

    # ── Stderr policy ──
    if (-not $env:PA_LOG_STDERR) {
        if ($global:PA_MODE -eq "interactive") {
            $env:PA_LOG_STDERR = "1"
        } else {
            $env:PA_LOG_STDERR = "0"
        }
    }

    # ── Stderr log level ──
    $stderrLevel = if ($env:PA_LOG_STDERR_LEVEL) { $env:PA_LOG_STDERR_LEVEL } else { "INFO" }
    switch ($stderrLevel.ToUpper()) {
        "DEBUG" { $global:LOG_STDERR_LEVEL_NUM = 0 }
        "INFO"  { $global:LOG_STDERR_LEVEL_NUM = 1 }
        "WARN"  { $global:LOG_STDERR_LEVEL_NUM = 2 }
        "ERROR" { $global:LOG_STDERR_LEVEL_NUM = 3 }
        "FATAL" { $global:LOG_STDERR_LEVEL_NUM = 4 }
        default { $global:LOG_STDERR_LEVEL_NUM = 1 }
    }

    # ── Rotate old logs ──
    Reset-LogRotation
}

function Reset-LogRotation {
    if (-not $global:LOG_DIR -or -not (Test-Path $global:LOG_DIR)) { return }
    $today = Get-Date -Format "yyyy-MM-dd"
    foreach ($baseName in @("poweragent", "access")) {
        $logFile = Join-Path $global:LOG_DIR "${baseName}.log"
        if (Test-Path $logFile) {
            $fileDate = (Get-Item $logFile).LastWriteTime.ToString("yyyy-MM-dd")
            if ($fileDate -ne $today) {
                $newName = Join-Path $global:LOG_DIR "${baseName}-${fileDate}.log"
                Move-Item $logFile $newName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Purge logs older than 7 days
    Get-ChildItem $global:LOG_DIR -Filter "*.log-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param([Parameter(Position=0, ValueFromRemainingArguments=$true)][string[]]$Messages)
    $raw = $Messages -join " "
    $level = "INFO"
    $lvlNum = 1
    $color = $global:GRAY

    # Parse level prefix
    if ($raw -match '^DEBUG:\s*')    { $level = "DEBUG"; $lvlNum = 0 }
    elseif ($raw -match '^INFO:\s*')  { $level = "INFO";  $lvlNum = 1 }
    elseif ($raw -match '^WARN:\s*')  { $level = "WARN";  $lvlNum = 2; $color = $global:YELLOW }
    elseif ($raw -match '^ERROR:\s*') { $level = "ERROR"; $lvlNum = 3; $color = $global:RED }
    elseif ($raw -match '^FATAL:\s*') { $level = "FATAL"; $lvlNum = 4; $color = $global:RED }

    # Strip level prefix
    $msg = $raw -replace '^(DEBUG|INFO|WARN|ERROR|FATAL):\s*', ''

    # File output (buffered)
    if ($lvlNum -ge $global:LOG_LEVEL_NUM) {
        if ($global:LOG_DIR -and (Test-Path $global:LOG_DIR)) {
            $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
            $src = "$($MyInvocation.ScriptName):$($MyInvocation.ScriptLineNumber)"
            $line = "{0} [{1,-5}] [{2}] {3}" -f $ts, $level, $src, $msg
            $global:_LOG_BUF.Add($line)
            if ($global:_LOG_BUF.Count -ge $global:_LOG_BUF_MAX) {
                Write-LogFlush
            }
        }
    }

    # Stderr output
    if ($lvlNum -ge $global:LOG_STDERR_LEVEL_NUM -and $env:PA_LOG_STDERR -eq "1") {
        Write-Host "${color}[poweragent]${global:RESET} $msg"
    }
}

function Write-Die {
    param([string]$Message)
    Write-Host "[poweragent] FATAL: $Message" -ForegroundColor Red
    Write-Log "FATAL: $Message"
    exit 1
}

function Write-AccessLog {
    param(
        [string]$Method,
        [string]$Path,
        [int]$Status,
        [string]$Elapsed,
        [string]$SessionId = "-",
        [string]$Bytes = "-"
    )
    # Stderr: colored Flask-style output
    if ($env:PA_LOG_STDERR -eq "1") {
        $color = if ($Status -ge 500) { $global:RED }
                 elseif ($Status -ge 400) { $global:YELLOW }
                 else { $global:GREEN }
        $stext = Get-StatusText $Status
        $display = if ($Path.Length -gt 50) { $Path.Substring(0,50) } else { $Path }
        Write-Host ("${color}{0,-6} {1,-50}${global:RESET} ${global:GRAY}->${global:RESET} ${color}{2,3} {3,-7}${global:RESET} ${global:DIM}({4,5}ms)${global:RESET}" -f $Method, $display, $Status, $stext, $Elapsed)
    }

    # File: structured access log
    if ($global:LOG_DIR -and (Test-Path $global:LOG_DIR)) {
        $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        $entry = "{0} {1,-6} {2} {3,3} {4,5}ms {5} {6}" -f $ts, $Method, $Path, $Status, $Elapsed, $SessionId, $Bytes
        $global:_ACCESS_BUF.Add($entry)
    }
}

function Get-StatusText {
    param([int]$Code)
    switch ($Code) {
        200 { "OK" }        201 { "Created" }
        202 { "Accepted" }  204 { "NoCntnt" }
        301 { "Moved" }     304 { "NotMod" }
        400 { "BadReq" }    401 { "Unauth" }
        403 { "Forbdn" }    404 { "NotFnd" }
        405 { "MethBad" }   408 { "Timeout" }
        409 { "Conflct" }   429 { "RateLmt" }
        500 { "SrvrErr" }   502 { "BadGate" }
        503 { "Unavail" }   504 { "GateTim" }
        default { "$Code" }
    }
}

# ============================================================================
#  Timestamp Helpers  (replaces bash date/EPOCHREALTIME with .NET)
# ============================================================================

function Get-TimestampMs {
    <# Returns current timestamp in milliseconds (13 digits) #>
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-TimestampS {
    <# Returns current timestamp in seconds #>
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# ============================================================================
#  Portable Utility Functions (Windows/PowerShell equivalents)
# ============================================================================

function Test-PortBusy {
    <# Check if a TCP port is in use. Uses .NET TcpClient. #>
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect("127.0.0.1", $Port)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Stop-PortProcess {
    <# Kill process listening on a port. Windows: netstat + taskkill. #>
    param([int]$Port)
    try {
        $connections = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        if ($connections) {
            $connections | ForEach-Object {
                Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # Fallback: netstat
        $netstat = netstat -ano 2>$null | Select-String ":$Port\s"
        if ($netstat) {
            $netstat | ForEach-Object {
                if ($_ -match '\s+(\d+)\s*$') {
                    Stop-Process -Id $Matches[1] -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# ── File-based locking using mkdir (atomic on Windows) ──
function Request-Lock {
    param([string]$Name, [int]$RetryMs = 50)
    $lockDir = "$Name.lock"
    while (-not (New-Item -ItemType Directory -Path $lockDir -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds $RetryMs
    }
}

function Request-LockNonBlocking {
    param([string]$Name)
    $lockDir = "$Name.lock"
    return [bool](New-Item -ItemType Directory -Path $lockDir -ErrorAction SilentlyContinue)
}

function Release-Lock {
    param([string]$Name)
    $lockDir = "$Name.lock"
    Remove-Item $lockDir -Force -Recurse -ErrorAction SilentlyContinue
}

# ── Process tree management ──
# Windows: taskkill /T kills process tree; Get-CimInstance for child process lookup
function Stop-ChildProcesses {
    param([int]$ParentId, [string]$Signal = "TERM")
    # On Windows, use taskkill /T for tree kill
    if ($Signal -eq "KILL") {
        taskkill /F /T /PID $ParentId 2>$null
    } else {
        taskkill /T /PID $ParentId 2>$null
    }
}

function Stop-ProcessTree {
    <# Kill entire process tree recursively, bottom-up #>
    param([int]$ParentId, [string]$Signal = "TERM")
    # Windows: taskkill /T handles tree kill natively
    Stop-ChildProcesses -ParentId $ParentId -Signal $Signal
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        return -not $proc.HasExited
    } catch {
        return $false
    }
}

# ── File mtime (replaces stat -c %Y) ──
function Get-FileMtime {
    param([string]$Path)
    if (Test-Path $Path) {
        return [int][DateTimeOffset]::new((Get-Item $Path).LastWriteTimeUtc).ToUnixTimeSeconds()
    }
    return 0
}

# ── Temp file/dir creation (replaces mktemp) ──
function New-TempFile {
    param([string]$Prefix = "pa")
    $tempPath = [System.IO.Path]::GetTempFileName()
    return $tempPath
}

function New-TempDir {
    param([string]$Prefix = "pa")
    $tempPath = Join-Path $env:TEMP "${Prefix}_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    return $tempPath
}

# ── Safe atomic file write (write to temp then rename) ──
function Write-AtomicFile {
    param([string]$Path, [string]$Content, [string]$Encoding = "UTF8")
    $tmp = New-TempFile
    try {
        [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.Encoding]::$Encoding)
        Move-Item $tmp $Path -Force
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

# ── JSON helpers (pure PowerShell, no external dependencies) ──

function ConvertFrom-JsonSafe {
    param([string]$Json)
    try {
        return $Json | ConvertFrom-Json
    } catch {
        Write-Log "WARN: JSON parse failed"
        return $null
    }
}

function ConvertTo-JsonSafe {
    param([object]$Object, [int]$Depth = 10)
    try {
        return $Object | ConvertTo-Json -Depth $Depth -Compress
    } catch {
        Write-Log "WARN: JSON serialize failed"
        return "{}"
    }
}



# ── SHA256 hash (replaces sha256sum/shasum) ──
function Get-ContentHash {
    param([string]$Content)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $hash = $sha256.ComputeHash($bytes)
    $sha256.Dispose()
    return [BitConverter]::ToString($hash) -replace '-', '' | Select-Object -First 1
}

# ── CJK Display Width Calculator ──
# PowerShell strings are natively Unicode; width calculation still needed for
# terminal alignment. Ported from bashagt _str_display_width (L3559-3665).
function Get-StringDisplayWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cp = [int]$ch
        # Zero-width characters
        if ($cp -eq 0x0300 -or ($cp -ge 0x0300 -and $cp -le 0x036F)) { continue }  # Combining diacritics
        if ($cp -ge 0xFE00 -and $cp -le 0xFE0F) { continue }  # VS1-VS16
        if ($cp -eq 0x200B) { continue }  # ZWSP
        if ($cp -eq 0x200D) { continue }  # ZWJ
        if ($cp -eq 0xFEFF) { continue }  # BOM/ZWNBSP
        if ($cp -ge 0x2060 -and $cp -le 0x206F) { continue }  # Invisible
        if ($cp -ge 0xE0100 -and $cp -le 0xE01EF) { continue }  # VS17-VS256 (supplementary)

        # Wide characters (CJK, emoji, etc.) = width 2
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or   # Hangul Jamo
            ($cp -ge 0x231A -and $cp -le 0x231B) -or     # Watch/Hourglass
            ($cp -ge 0x2329 -and $cp -le 0x232A) -or     # Angle brackets
            ($cp -ge 0x23E9 -and $cp -le 0x23EC) -or     # Media control
            ($cp -ge 0x23F0 -and $cp -le 0x23F3) -or     # Alarm/Timer
            ($cp -ge 0x25FD -and $cp -le 0x25FE) -or     # Medium squares
            ($cp -ge 0x2614 -and $cp -le 0x2615) -or     # Umbrella/Hot
            ($cp -ge 0x2648 -and $cp -le 0x2653) -or     # Zodiac
            ($cp -eq 0x267F) -or                            # Wheelchair
            ($cp -ge 0x2693 -and $cp -le 0x269A) -or     # Misc
            ($cp -ge 0x26A1 -and $cp -le 0x26AA) -or    # Symbols
            ($cp -ge 0x26BD -and $cp -le 0x26BF) -or     # Sports
            ($cp -ge 0x26C4 -and $cp -le 0x26CD) -or     # Weather
            ($cp -ge 0x26D3 -and $cp -le 0x26E1) -or     # Misc
            ($cp -eq 0x26E9 -or $cp -eq 0x26EA) -or      # Temple
            ($cp -ge 0x26F0 -and $cp -le 0x26FA) -or     # Travel
            ($cp -ge 0x2702 -and $cp -le 0x270B) -or     # Hands
            ($cp -ge 0x270D -and $cp -le 0x2767) -or     # Symbols
            ($cp -ge 0x2794 -and $cp -le 0x27BF) -or     # Arrows
            ($cp -ge 0x2B1B -and $cp -le 0x2B1C) -or     # Squares
            ($cp -ge 0x2B50 -and $cp -le 0x2B55) -or     # Star/Circle
            ($cp -ge 0x2E80 -and $cp -le 0x2FDF) -or     # CJK Radicals
            ($cp -ge 0x2FF0 -and $cp -le 0x2FFF) -or     # Ideographic
            ($cp -ge 0x3000 -and $cp -le 0x303E) -or     # CJK Symbols
            ($cp -ge 0x3041 -and $cp -le 0x3096) -or     # Hiragana
            ($cp -ge 0x3099 -and $cp -le 0x30FF) -or     # Kana
            ($cp -ge 0x3105 -and $cp -le 0x312F) -or     # Bopomofo
            ($cp -ge 0x3131 -and $cp -le 0x318E) -or     # Hangul Jamo
            ($cp -ge 0x3190 -and $cp -le 0x31BA) -or     # CJK Strokes
            ($cp -ge 0x31C0 -and $cp -le 0x31E3) -or     # CJK Strokes
            ($cp -ge 0x31F0 -and $cp -le 0x4DB5) -or     # Katakana ext/CJK
            ($cp -ge 0x4DC0 -and $cp -le 0x9FFF) -or     # CJK Unified Ideographs
            ($cp -ge 0xA000 -and $cp -le 0xA48C) -or     # Yi
            ($cp -ge 0xA490 -and $cp -le 0xA4C6) -or     # Yi Radicals
            ($cp -ge 0xA960 -and $cp -le 0xA97C) -or     # Hangul Jamo ext-A
            ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or     # Hangul Syllables
            ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or     # CJK Compat Ideographs
            ($cp -ge 0xFE10 -and $cp -le 0xFE19) -or     # CJK Compat Forms
            ($cp -ge 0xFE30 -and $cp -le 0xFE6B) -or     # CJK Compat
            ($cp -ge 0xFF01 -and $cp -le 0xFF60) -or     # Fullwidth
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or     # Fullwidth signs
            ($cp -ge 0x1B000 -and $cp -le 0x1B001) -or   # Kana ext
            ($cp -ge 0x1F000 -and $cp -le 0x1F02F) -or   # Mahjong Tiles
            ($cp -ge 0x1F030 -and $cp -le 0x1F093) -or   # Domino
            ($cp -ge 0x1F0A0 -and $cp -le 0x1F1AD) -or   # Playing Cards
            ($cp -ge 0x1F1E6 -and $cp -le 0x1F1FF) -or   # Regional Indicators
            ($cp -ge 0x1F200 -and $cp -le 0x1F251) -or   # Emoji
            ($cp -ge 0x1F300 -and $cp -le 0x1F5FF) -or   # Misc Symbols
            ($cp -ge 0x1F600 -and $cp -le 0x1F64F) -or   # Emoticons
            ($cp -ge 0x1F680 -and $cp -le 0x1F6FF) -or   # Transport
            ($cp -ge 0x1F900 -and $cp -le 0x1F9FF) -or   # Supplemental Symbols
            ($cp -ge 0x1FA00 -and $cp -le 0x1FA6F) -or   # Chess Symbols
            ($cp -ge 0x1FA70 -and $cp -le 0x1FAFF) -or   # Symbols ext-A
            ($cp -ge 0x20000 -and $cp -le 0x2FFFD) -or   # CJK ext B-I
            ($cp -ge 0x30000 -and $cp -le 0x3FFFD))      # CJK ext G+
        {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

# ── String padding with CJK awareness ──
function Get-CjkPadRight {
    param([string]$Text, [int]$TargetWidth, [char]$PadChar = ' ')
    $displayWidth = Get-StringDisplayWidth $Text
    $padCount = $TargetWidth - $displayWidth
    if ($padCount -le 0) { return $Text }
    return $Text + ($PadChar.ToString() * $padCount)
}

function Get-CjkPadLeft {
    param([string]$Text, [int]$TargetWidth, [char]$PadChar = ' ')
    $displayWidth = Get-StringDisplayWidth $Text
    $padCount = $TargetWidth - $displayWidth
    if ($padCount -le 0) { return $Text }
    return ($PadChar.ToString() * $padCount) + $Text
}

# ============================================================================
#  Display / UI Functions
# ============================================================================

function Write-StatusBegin {
    param([string]$Label = "")
    $global:STATUS_ACTIVE = 1
}

function Write-StatusUpdate {
    param([string]$Message)
    Write-Host "`r$Message" -NoNewline
}

function Write-StatusDone {
    param([string]$Label = "done")
    $global:STATUS_ACTIVE = 0
    Write-Host "`r${global:DIM}${Label}${global:RESET}"
}

function Write-SpinnerTick {
    $global:SPINNER_IDX = ($global:SPINNER_IDX + 1) % $global:SPINNER.Count
    return $global:SPINNER[$global:SPINNER_IDX]
}

function Start-SpinnerBg {
    param([string]$Message = "思考中")
    $global:_SPINNER_MSG = $Message
    $global:_SPINNER_STOP = $false
    $global:_SPINNER_IDX = 0
    $global:_SPINNER_START = Get-Date
    $global:_SPINNER_TIMER = New-Object System.Timers.Timer
    $global:_SPINNER_TIMER.Interval = 120
    $global:_SPINNER_TIMER.AutoReset = $true
    $global:_SPINNER_TIMER.add_Elapsed({
        if ($global:_SPINNER_STOP) { return }
        $global:_SPINNER_IDX = ($global:_SPINNER_IDX + 1) % $global:SPINNER.Count
        $elapsed = ((Get-Date) - $global:_SPINNER_START).TotalSeconds
        # Phase 2: 状态栏实时更新（替代单一 spinner 行）
        Write-StatusBar -State "thinking" -Elapsed $elapsed

        # ── ESC / Ctrl+C 异步检测（120ms 间隔） ──
        # 在 Timer 回调中检测按键，补充 HTTP 轮询循环和 Test-CtrlCInterrupt 的检测缺口。
        # 这样即使主线程阻塞在工具执行或 JSON 解析中，也能及时捕获中断请求。
        if ($global:_ESC_MONITOR_ACTIVE) {
            if ([PA_KeyStateHelper]::IsEscapePressed()) {
                if ($global:_ESC_RELEASED) {
                    $global:_ESC_PRESSED = $true
                    $global:_ESC_RELEASED = $false
                }
            } else {
                $global:_ESC_RELEASED = $true
            }
            if ([PA_KeyStateHelper]::IsCtrlCPressed()) {
                if ($global:_CTRL_C_RELEASED) {
                    $global:_CTRL_C_PRESSED = $true
                    $global:_CTRL_C_RELEASED = $false
                }
            } else {
                $global:_CTRL_C_RELEASED = $true
            }
        }
    })
    $global:_SPINNER_TIMER.Start()
}

function Stop-SpinnerBg {
    $global:_SPINNER_STOP = $true
    $global:_LAST_SPINNER_ELAPSED = $null
    if ($global:_SPINNER_START) {
        $global:_LAST_SPINNER_ELAPSED = ((Get-Date) - $global:_SPINNER_START).TotalSeconds
    }
    if ($global:_SPINNER_TIMER) {
        $global:_SPINNER_TIMER.Stop()
        $global:_SPINNER_TIMER.Dispose()
        $global:_SPINNER_TIMER = $null
    }
    # Phase 2: 清除状态栏行。
    # 必须用 \r 回到行首后清行，然后 Write-Host "" 换行，
    # 避免后续输出（Write-UiDivider 等）覆盖在 spinner 行上造成鬼影。
    [Console]::Write("`r")
    Write-Host "$([char]27)[2K"   # 清行并换行（Write-Host 默认追加换行符）
}

# ── ESC 中断监测（Runspace + GetAsyncKeyState） ──
# ── ESC 中断检测 ──
# 使用 GetAsyncKeyState（Win32 API）检测 ESC，不消费键盘缓冲区。
# 避免 [Console]::ReadKey 吃掉 CTRL+C / 其他按键。
# 检测逻辑嵌入在 Start-SpinnerBg 的定时器回调中（已验证 Timer 回调可读写 $global: 变量）。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class PA_KeyStateHelper {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
    
    public const int VK_ESCAPE = 0x1B;
    public const int VK_CONTROL = 0x11;
    public const int VK_C = 0x43;
    
    public static bool IsEscapePressed() {
        return (GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0;
    }
    
    public static bool IsCtrlCPressed() {
        bool ctrlDown = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
        bool cDown = (GetAsyncKeyState(VK_C) & 0x8000) != 0;
        return ctrlDown && cDown;
    }
}
'@ -ErrorAction SilentlyContinue

function Start-EscMonitor {
    <#
    .SYNOPSIS
    重置 ESC / Ctrl+C 中断标志。检测由 HTTP 轮询循环或 Spinner 执行。
    #>
    $global:_ESC_PRESSED = $false
    $global:_ESC_RELEASED = $true   # 防重复触发：ESC 需先释放才能再次触发
    $global:_CTRL_C_PRESSED = $false
    $global:_CTRL_C_RELEASED = $true
    $global:_ESC_MONITOR_ACTIVE = $true
}

function Stop-EscMonitor {
    <#
    .SYNOPSIS
    关闭 ESC / Ctrl+C 监测。
    #>
    $global:_ESC_MONITOR_ACTIVE = $false
    $global:_ESC_PRESSED = $false
    $global:_CTRL_C_PRESSED = $false
}

function Test-EscInterrupt {
    <#
    .SYNOPSIS
    检测 ESC 是否被按下。调用后自动清除标志。
    #>
    if ($global:_ESC_PRESSED) {
        $global:_ESC_PRESSED = $false
        return $true
    }
    return $false
}

function Test-CtrlCInterrupt {
    <#
    .SYNOPSIS
    检测 Ctrl+C 是否被按下。调用后自动清除标志。
    #>
    if ($global:_CTRL_C_PRESSED) {
        $global:_CTRL_C_PRESSED = $false
        return $true
    }
    return $false
}

function Request-ExitConfirm {
    <#
    .SYNOPSIS
    弹出 Ctrl+C 退出确认对话框。返回 $true 表示用户确认退出，$false 表示取消。
    在 ReadKey 之前刷新输入缓冲区，防止残留按键泄漏。
    #>
    param(
        [string]$Message = "Ctrl+C 已中断"
    )
    Write-Host ""
    Write-Host "  $([char]0x26A0) $([char]27)[33m$Message$([char]27)[0m"
    Write-Host "  $([char]27)[33m确定要退出 PowerAgent 吗？ [Y/N] $([char]27)[0m" -NoNewline

    # 刷新输入缓冲区，防止 Ctrl+C 产生的前序按键残留泄漏到 ReadKey
    try { $Host.UI.RawUI.FlushInputBuffer() } catch {}

    $prevTC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    try {
        $key = [Console]::ReadKey($true)
        Write-Host $key.KeyChar
        if ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y') {
            Write-Host "  $([char]0x2718) $([char]27)[31m正在退出...$([char]27)[0m"
            return $true
        } else {
            Write-Host "  $([char]0x25B8) $([char]27)[32m已取消退出，继续运行$([char]27)[0m"
            return $false
        }
    } catch {
        Write-Host "  $([char]0x25B8) ${global:DIM}继续运行${global:RESET}"
        return $false
    } finally {
        [Console]::TreatControlCAsInput = $prevTC
        # 再刷新一次，防止用户在确认对话框中多按的键泄漏到后续输入
        try { $Host.UI.RawUI.FlushInputBuffer() } catch {}
    }
}

# ── Console width ──
function Get-ConsoleWidth {
    try {
        return $Host.UI.RawUI.WindowSize.Width
    } catch {
        return 80
    }
}

# ── 带斜杠命令补全的交互式输入 ──
function Read-HostWithCompletion {
    param([string]$PromptStr = "")
    $esc = $global:ESC
    $rst = "${esc}[0m"
    $dim = "${esc}[2m"
    $cyan = "${esc}[36m"
    $lcyan = "${esc}[96m"
    $bold = "${esc}[1m"

    $buf = [System.Text.StringBuilder]::new()
    $cursorPos = 0
    $completions = @()
    $compIndex = -1
    $showingComps = $false

    # 构建斜杠命令列表（含描述）
    $slashList = $global:SLASH_COMMANDS.Keys | Sort-Object
    $slashDesc = @{
        "help" = "Show this help"; "clear" = "Clear conversation history"
        "save" = "Save conversation history"; "load" = "Load conversation history"
        "compress" = "Force context compression"; "status" = "Show session statistics"
        "model" = "Show/select model"; "provider" = "Switch provider & set API key"
        "safe" = "Toggle safe mode"; "trace" = "Show trace log"
        "undo" = "Undo last file modification"; "tasks" = "List TODO tasks"
        "memory" = "Show memory network"; "remember" = "Save to long-term memory"
        "skills" = "List active skills"; "mcp" = "List MCP connections"
        "exit" = "Exit PowerAgent"
    }

    # ── 重绘辅助函数：使用 [Console]::CursorLeft/Top 精确光标定位（CJK 安全） ──
    # 支持多行换行文本：保存输入区起始行，擦除时回到起始行并清除所有换行行。
    function Redraw-InputLine {
        if ($script:showingComps) { Hide-Completions }
        # ── 关键：逐行清除旧内容，不使用 ESC[J ──
        # ESC[J (Erase in Display) 只清除从光标到当前视口底部。
        # 当粘贴的长文本导致终端滚动后，SetCursorPosition 回到 _inputStartRow
        # 会触发视口回滚，此时 ESC[J 只能清除到新视口底部——
        # 但旧文本的下半部分在新视口底部以下，不会被清除。
        # 再次写入时视口下滚，那些旧行重新出现 = 鬼影。
        # 修复：用 SetCursorPosition + ESC[2K 逐行清除，不受视口边界限制。
        # 需要知道上一次内容的末尾行号 (_lastContentEndRow)。
        try {
            $startRow = $script:_inputStartRow
            $endRow = if ($script:_lastContentEndRow -ge $startRow) {
                $script:_lastContentEndRow
            } else {
                [Console]::CursorTop
            }
            if ($endRow -lt $startRow) { $endRow = $startRow }
            # 安全上限：防止极端情况（几千行粘贴）导致循环太久
            $maxLines = [Console]::WindowHeight + 20
            if ($endRow - $startRow + 1 -gt $maxLines) { $endRow = $startRow + $maxLines - 1 }
            for ($row = $startRow; $row -le $endRow; $row++) {
                [Console]::SetCursorPosition(0, $row)
                [Console]::Write("${esc}[2K")
            }
            [Console]::SetCursorPosition(0, $startRow)
        } catch {
            [Console]::Write("`r")
        }
        # 写入提示符 + 缓冲区内容（全程 [Console]::Write）
        [Console]::Write($PromptStr)
        $text = $buf.ToString()
        $prefix = if ($cursorPos -gt 0) { $text.Substring(0, $cursorPos) } else { "" }
        $suffix = if ($cursorPos -lt $text.Length) { $text.Substring($cursorPos) } else { "" }
        [Console]::Write($prefix)
        try {
            $cursorCol = [Console]::CursorLeft
            $cursorRow = [Console]::CursorTop
        } catch {
            $cursorCol = 0; $cursorRow = 0
        }
        [Console]::Write($suffix)
        # 记录内容末尾行号（在恢复光标之前，此时 CursorTop 是内容最后一行）
        try {
            $script:_lastContentEndRow = [Console]::CursorTop
        } catch {
            $script:_lastContentEndRow = $script:_inputStartRow
        }
        # 恢复光标到正确位置
        try { [Console]::SetCursorPosition($cursorCol, $cursorRow) } catch {}
    }

    function Clear-CompletionArea {
        param([int]$Lines = 18)
        for ($i = 0; $i -lt $Lines; $i++) {
            Write-Host "${esc}[A${esc}[2K" -NoNewline
        }
        Write-Host "${esc}[${Lines}B" -NoNewline
    }

    function Show-Completions {
        param([string]$Filter = "")
        $matches = $slashList | Where-Object { $_ -like "$Filter*" }
        if ($matches.Count -eq 0) {
            $script:showingComps = $false
            return
        }
        $script:completions = @($matches)
        $script:compIndex = -1
        $script:showingComps = $true

        $w = Get-ConsoleWidth
        $colW = 18; $descW = $w - $colW - 4
        if ($descW -lt 10) { $descW = 20 }
        $linesShown = 0
        Write-Host ""
        foreach ($m in $matches) {
            if ($linesShown -ge 16) { break }
            $desc = if ($slashDesc[$m]) { $slashDesc[$m] } else { "" }
            $prefix = "/$m"
            if ($Filter.Length -gt 0) {
                $matched = $prefix.Substring(0, [Math]::Min($Filter.Length + 1, $prefix.Length))
                $rest = $prefix.Substring([Math]::Min($Filter.Length + 1, $prefix.Length))
                $display = "${lcyan}${bold}${matched}${rst}${dim}${rest}${rst}"
            } else { $display = "${lcyan}${bold}${prefix}${rst}" }
            Write-Host ("  {0}{1}${rst}" -f $display, $desc.PadRight($descW)) -NoNewline
            Write-Host ""
            $linesShown++
        }
        Write-Host "${dim}  Tab=accept  Esc=cancel${rst}" -NoNewline
        Write-Host ""
        $script:_compLinesShown = $linesShown + 2
    }

    function Hide-Completions {
        if ($script:_compLinesShown -and $script:_compLinesShown -gt 0) {
            for ($i = 0; $i -lt $script:_compLinesShown; $i++) {
                [Console]::Write("${esc}[2K${esc}[A")
            }
            [Console]::Write("${esc}[2K")
        }
        $script:showingComps = $false
        $script:_compLinesShown = 0
    }

    # ── Bracketed paste 状态 ──
    # Windows Terminal 默认启用 bracketed paste，粘贴时发送:
    #   ESC [ 2 0 0 ~  <content>  ESC [ 2 0 1 ~
    # 我们必须检测这些序列，将 <content> 原样插入 buffer，
    # 丢弃包裹序列的字符，防止 "200~201~" 等垃圾字符混入输入。
    #
    # 状态机设计：
    #   idle      → 正常模式，每按键独立处理
    #   seq_start → 读到 ESC，等待后续字符判断是否为序列
    #   pasting   → 确认 ESC[200~ 后，粘贴模式收集字符
    #   seq_end   → 粘贴中又读到 ESC，等待判断是否为 ESC[201~
    $script:_bpState = "idle"
    $script:_bpSeqBuf = ""       # 追踪序列前缀
    $script:_bpContent = [System.Text.StringBuilder]::new()
    $script:_bpEscapeFallback = $false   # ESC 独立按键回退标志

    # ── 处理单个按键，返回状态 ──
    # "consumed"  — 按键已被 paste 状态机消费，外层不处理
    # "passthrough" — 按键非 paste 相关，外层正常处理
    # "paste_done" — 粘贴结束，内容已刷入主 buffer
    function Resolve-BpKey {
        param([System.ConsoleKeyInfo]$KeyInfo)

        $ch = $KeyInfo.KeyChar
        $cp = [int]$ch

        switch ($script:_bpState) {
            "idle" {
                if ($cp -eq 27) {
                    # ESC：可能是独立按键，也可能是粘贴序列开头
                    $script:_bpSeqBuf = [char]27
                    $script:_bpState = "seq_start"
                    return "consumed"
                }
                return "passthrough"
            }

            "seq_start" {
                # 正在追踪 ESC 后的字符
                $script:_bpSeqBuf += $ch
                $seq = $script:_bpSeqBuf

                if ($seq -eq "`e[200~") {
                    # 确认是粘贴开始序列
                    $script:_bpState = "pasting"
                    $script:_bpSeqBuf = ""
                    $script:_bpContent.Clear() | Out-Null
                    return "consumed"
                }

                # 检查是否还是有效前缀
                if ("`e[200~".StartsWith($seq)) {
                    return "consumed"   # 继续追踪
                }

                # 不是粘贴序列开始 — 回退到 idle
                # 无法放回已读按键，但 seq_start 阶段的按键只有 [, 2, 0, 0, ~
                # 它们不太可能是用户有意输入的内容
                # 但如果是 ESC 后紧跟 [ 组成的非法序列，我们丢弃 ESC，
                # 让后续的 [ 等字符走正常 passthrough
                $script:_bpState = "idle"
                $script:_bpSeqBuf = ""
                # 如果当前字符是可打印的，让它通过
                if ($cp -ge 32) { return "passthrough" }
                return "consumed"
            }

            "pasting" {
                # 粘贴模式收集字符
                if ($cp -eq 27) {
                    # 可能是结束序列的 ESC
                    $script:_bpState = "seq_end"
                    $script:_bpSeqBuf = [char]27
                    return "consumed"
                }
                # 追加到粘贴内容
                $script:_bpContent.Append($ch) | Out-Null
                return "consumed"
            }

            "seq_end" {
                # 追踪粘贴中的 ESC 后续字符，判断是否为 ESC[201~
                $script:_bpSeqBuf += $ch
                $seq = $script:_bpSeqBuf

                if ($seq -eq "`e[201~") {
                    # 粘贴结束 — 把收集的内容刷入主 buffer
                    if ($script:_bpContent.Length -gt 0) {
                        $buf.Insert($cursorPos, $script:_bpContent.ToString()) | Out-Null
                        $cursorPos += $script:_bpContent.Length
                        $script:_bpContent.Clear() | Out-Null
                    }
                    $script:_bpState = "idle"
                    $script:_bpSeqBuf = ""
                    return "paste_done"
                }

                # 检查是否还是有效前缀
                if ("`e[201~".StartsWith($seq)) {
                    return "consumed"   # 继续追踪
                }

                # 不是结束序列 — 之前的 ESC 和追踪字符都是粘贴内容
                # 把 ESC + 追踪缓冲内容追加到 _bpContent
                $script:_bpContent.Append($seq) | Out-Null
                $script:_bpState = "pasting"
                $script:_bpSeqBuf = ""
                return "consumed"
            }
        }
        return "passthrough"
    }

    # ── 批量处理粘贴序列中的所有待处理按键 ──
    # 在确认进入 pasting 状态后调用，一次性读完所有待处理按键
    function Read-BpPendingKeys {
        $done = $false
        while ([Console]::KeyAvailable -and -not $done) {
            $nk = [Console]::ReadKey($true)
            $result = Resolve-BpKey $nk
            if ($result -eq "paste_done") {
                $done = $true
            }
        }
        # 如果缓冲区已空但还没收到结束序列，返回 $false
        # 外层循环会在下一个 ReadKey 到来时继续处理
        return $done
    }

    # ── 打印初始提示符，然后记录输入区起始位置 ──
    # 注意1：必须先打印提示符再保存行号！
    # 若在打印前保存，终端因前面输出滚动时行号会错位，导致 Redraw-InputLine
    # 回到错误的行，造成鬼影（提示符在屏幕上重复出现）。
    # 注意2：使用 [Console]::Write 而非 Write-Host，与 Redraw-InputLine 保持一致，
    # 避免混用时 PS Host 内部光标跟踪不同步。
    [Console]::Write($PromptStr)
    try {
        $script:_inputStartCol = [Console]::CursorLeft
        $script:_inputStartRow = [Console]::CursorTop
        $script:_lastContentEndRow = $script:_inputStartRow
    } catch {
        $script:_inputStartCol = 0
        $script:_inputStartRow = 0
        $script:_lastContentEndRow = 0
    }

    # ── 核心：接管 Ctrl+C，让控制台将其作为普通输入而非中断信号 ──
    # 这样 [Console]::ReadKey 就能读到 Ctrl+C（字符编码 3），
    # 而不是被 PowerShell 引擎拦截后直接杀掉 pipeline。
    $prevTreatCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    $Host.UI.RawUI.FlushInputBuffer()

    try {
    while ($true) {
        $key = [Console]::ReadKey($true)

        # ── Ctrl+C 检测（TreatControlCAsInput=true 后，ReadKey 可以读到） ──
        # Ctrl+C 的字符编码为 3 (ETX)，或者 Key=C + Modifiers 包含 Control
        if ([int]$key.KeyChar -eq 3) {
            if ($script:showingComps) { Hide-Completions }
            Write-Host "^C"
            return $null
        }

        # ── Bracketed paste 检测（必须在所有其他按键处理之前） ──
        $bpResult = Resolve-BpKey $key
        if ($bpResult -eq "consumed") {
            # 按键被 paste 状态机消费
            # 如果处于 seq_start 状态，检查是否后续字符已在缓冲区中
            if ($script:_bpState -eq "seq_start" -and [Console]::KeyAvailable) {
                while ([Console]::KeyAvailable -and $script:_bpState -eq "seq_start") {
                    $nk = [Console]::ReadKey($true)
                    $innerResult = Resolve-BpKey $nk
                    if ($innerResult -eq "passthrough") {
                        # 不是粘贴序列，但按键已被消费
                        # seq_start 已经回退到 idle
                        break
                    }
                }
                # seq_start 可能在上面的循环中转变为了 pasting
            }
            # 如果进入了 pasting 状态，批量处理
            if ($script:_bpState -eq "pasting") {
                $pasteComplete = Read-BpPendingKeys
                if ($pasteComplete -or $script:_bpState -eq "idle") {
                    # 粘贴完成，重绘
                    Redraw-InputLine
                    $t = $buf.ToString()
                    if ($t.StartsWith("/") -and $t.Length -ge 1) {
                        Show-Completions -Filter $t.Substring(1)
                    }
                }
            }
            # 如果还在 seq_start 但缓冲区空了，等一下
            if ($script:_bpState -eq "seq_start") {
                $waitCount = 0
                while ($waitCount -lt 10) {
                    if ([Console]::KeyAvailable) {
                        $nk = [Console]::ReadKey($true)
                        $innerResult = Resolve-BpKey $nk
                        if ($innerResult -eq "paste_done") {
                            Redraw-InputLine
                        } elseif ($script:_bpState -eq "pasting") {
                            $pasteComplete = Read-BpPendingKeys
                            if ($pasteComplete -or $script:_bpState -eq "idle") {
                                Redraw-InputLine
                                $t = $buf.ToString()
                                if ($t.StartsWith("/") -and $t.Length -ge 1) {
                                    Show-Completions -Filter $t.Substring(1)
                                }
                            }
                        }
                        break
                    }
                    Start-Sleep -Milliseconds 5
                    $waitCount++
                }
                # 超时还没收到后续字符，当作独立的 Escape 按键处理
                if ($script:_bpState -eq "seq_start") {
                    $script:_bpState = "idle"
                    $script:_bpSeqBuf = ""
                    # 标记：ESC 是独立按键，需要走 Escape 处理逻辑
                    $script:_bpEscapeFallback = $true
                    # 不 continue，让代码继续走到 Escape 处理
                } else {
                    continue
                }
            }
            if ($script:_bpEscapeFallback) {
                # ESC 被 paste 状态机拦截但最终判定为独立按键
                # 清除标志，继续走到下面的 Escape 处理逻辑
                $script:_bpEscapeFallback = $false
                # 不 continue，让代码 fall through 到 Escape 判断
            } else {
                continue
            }
        }
        if ($bpResult -eq "paste_done") {
            Redraw-InputLine
            $t = $buf.ToString()
            if ($t.StartsWith("/") -and $t.Length -ge 1) {
                Show-Completions -Filter $t.Substring(1)
            }
            continue
        }
        # bpResult == "passthrough" → 走正常按键处理

        # ── Tab: 接受补全 ──
        if ($key.Key -eq "Tab" -and $script:showingComps -and $script:completions.Count -gt 0) {
            Hide-Completions
            $script:compIndex++
            if ($script:compIndex -ge $script:completions.Count) { $script:compIndex = 0 }
            $chosen = $script:completions[$script:compIndex]
            $buf.Clear() | Out-Null
            $buf.Append("/$chosen") | Out-Null
            $cursorPos = $buf.Length
            Redraw-InputLine
            Show-Completions -Filter $buf.ToString().TrimStart('/')
            continue
        }

        # ── Escape: 隐藏补全 / 清空输入 ──
        if ($key.Key -eq "Escape") {
            if ($script:showingComps) {
                Hide-Completions
                Redraw-InputLine
            } else {
                $buf.Clear() | Out-Null
                $cursorPos = 0
                Redraw-InputLine
            }
            continue
        }

        # ── Enter: 提交 ──
        if ($key.Key -eq "Enter") {
            if ($script:showingComps) { Hide-Completions }
            Write-Host ""
            return $buf.ToString()
        }

        # ── LeftArrow ──
        if ($key.Key -eq "LeftArrow") {
            if ($cursorPos -gt 0) { $cursorPos-- }
            Redraw-InputLine
            continue
        }

        # ── RightArrow ──
        if ($key.Key -eq "RightArrow") {
            if ($cursorPos -lt $buf.Length) { $cursorPos++ }
            Redraw-InputLine
            continue
        }

        # ── Home ──
        if ($key.Key -eq "Home") {
            $cursorPos = 0
            Redraw-InputLine
            continue
        }

        # ── End ──
        if ($key.Key -eq "End") {
            $cursorPos = $buf.Length
            Redraw-InputLine
            continue
        }

        # ── Delete ──
        if ($key.Key -eq "Delete") {
            if ($cursorPos -lt $buf.Length) {
                $buf.Remove($cursorPos, 1) | Out-Null
                Redraw-InputLine
                $t = $buf.ToString()
                if ($t.StartsWith("/")) { Show-Completions -Filter $t.TrimStart('/') }
            }
            continue
        }

        # ── Backspace ──
        if ($key.Key -eq "Backspace") {
            if ($cursorPos -gt 0) {
                $cursorPos--
                $buf.Remove($cursorPos, 1) | Out-Null
                Redraw-InputLine
                $t = $buf.ToString()
                if ($t.StartsWith("/")) { Show-Completions -Filter $t.TrimStart('/') }
            }
            continue
        }

        # ── 普通字符（非粘贴批量处理） ──
        # 注意：粘贴情况已由 bracketed paste 状态机处理，
        # 此处只处理手动逐字输入的普通字符。
        $ch = $key.KeyChar
        if ([int]$ch -ge 32) {
            $buf.Insert($cursorPos, $ch) | Out-Null
            $cursorPos++

            # 批量读取待处理按键（快速打字：全部读入 buffer，不逐字回显）
            # 注意：这里不再用于粘贴处理，粘贴已由 bracketed paste 状态机接管
            while ([Console]::KeyAvailable) {
                $nk = [Console]::ReadKey($true)
                $nch = $nk.KeyChar
                if ([int]$nch -ge 32) {
                    $buf.Insert($cursorPos, $nch) | Out-Null
                    $cursorPos++
                } elseif ([int]$nch -eq 3) {
                    # Ctrl+C — 立即退出
                    if ($script:showingComps) { Hide-Completions }
                    Write-Host "^C"
                    return $null
                } elseif ([int]$nch -eq 27) {
                    # 快速打字后按 ESC，交给外层下一轮迭代处理
                    break
                }
            }

            # 一次性精确重绘
            Redraw-InputLine
            $t = $buf.ToString()
            if ($t.StartsWith("/") -and $t.Length -ge 1) {
                Show-Completions -Filter $t.Substring(1)
            }
        }
    }   # end while ($true)
    }   # end try
    finally {
        # ── 恢复 Ctrl+C 默认行为（关键！否则后续 Ctrl+C 全部失效） ──
        [Console]::TreatControlCAsInput = $prevTreatCtrlC
    }
}   # end Read-HostWithCompletion

# ── UI 分割线辅助函数 ──
function Write-UiDivider {
    param(
        [string]$Label = "",
        [string]$Color = "Gray",
        [string]$Icon = "",
        [double]$WidthRatio = 0.95,
        [switch]$Timestamp
    )
    # 全宽分隔线，带可选标签和图标
    $w = [Math]::Floor((Get-ConsoleWidth) * $WidthRatio)
    if ($w -lt 20) { $w = 40 }
    $hLine = [string][char]0x2500
    $esc = $global:ESC
    # 根据 Color 参数映射 ANSI 颜色码
    $colorMap = @{
        "Gray" = "${esc}[90m"; "DarkGray" = "${esc}[90m"; "White" = "${esc}[97m"
        "Cyan" = "${esc}[36m"; "Green" = "${esc}[32m"; "Yellow" = "${esc}[33m"
        "Red" = "${esc}[31m"; "Blue" = "${esc}[34m"; "LightBlue" = "${esc}[94m"
    }
    $ansi = if ($colorMap.ContainsKey($Color)) { $colorMap[$Color] } else { "${esc}[90m" }
    $rst = $global:RESET
    # 时间戳前缀（固定在分隔线最左边，不属于破折线）
    $tsPrefix = ""
    $tsWidth = 0
    if ($Timestamp) {
        $now = Get-Date
        $tsPrefix = "${esc}[2m$([char]0x23F0) $($now.ToString('HH:mm'))${rst}  "   # ⏰ HH:mm  (dim)
        $tsWidth = 8  # ⏰ + space + HH:mm + 2 spaces
    }
    # 可用宽度减去时间戳占位
    $availW = $w - $tsWidth
    if ($availW -lt 20) { $availW = 20 }
    if ($Label) {
        $iconStr = if ($Icon) { "$Icon " } else { "" }
        $labelDisplay = " $iconStr$Label "
        $labelDisplayWidth = Get-StringDisplayWidth $labelDisplay
        # 时间戳和标签之间固定 12 个分隔线段
        $leftLen = 12
        $rightLen = $availW - $leftLen - $labelDisplayWidth
        if ($rightLen -lt 1) { $rightLen = 1 }
        $line = "${tsPrefix}${ansi}$($hLine * $leftLen)${rst}${esc}[1m$labelDisplay${rst}${ansi}$($hLine * $rightLen)${rst}"
    } else {
        $line = "${tsPrefix}${ansi}$($hLine * $availW)${rst}"
    }
    Write-Host "  $line"
}

function Write-UiToolLine {
    param(
        [string]$Prefix,
        [string]$Content,
        [int]$MaxChars = 300,
        [string]$Color = "DarkGray",
        [string]$Icon = ""
    )
    # 工具颜色映射表
    $esc = $global:ESC
    $rst = $global:RESET
    $toolColorMap = @{
        "read_file" = "${esc}[32m"; "write_file" = "${esc}[33m"; "edit_file" = "${esc}[33m"
        "delete_file" = "${esc}[31m"; "powershell" = "${esc}[94m"; "bash" = "${esc}[94m"
        "web_search" = "${esc}[36m"; "web_request" = "${esc}[36m"
        "agent" = "${esc}[1;36m"; "skill" = "${esc}[1;36m"
        "make_todos" = "${esc}[93m"; "task_create" = "${esc}[93m"; "task_update" = "${esc}[93m"
        "task_list" = "${esc}[93m"; "job_poll" = "${esc}[93m"; "job_result" = "${esc}[93m"
        "job_cancel" = "${esc}[93m"; "process_excel" = "${esc}[92m"
        "send_message" = "${esc}[1;36m"; "check_messages" = "${esc}[1;36m"
        "request" = "${esc}[91m"; "undo" = "${esc}[35m"
        "list_skills" = "${esc}[1;36m"; "list_agents" = "${esc}[1;36m"; "list_mcp_tools" = "${esc}[1;36m"
    }
    if ($Content.Length -gt $MaxChars) {
        $Content = $Content.Substring(0, $MaxChars) + "... ($($Content.Length) chars total)"
    }
    $arrow = [string][char]0x25B8   # ▸
    $back  = [string][char]0x25C2   # ◂
    $check = [string][char]0x2714   # ✔
    $cross = [string][char]0x2718   # ✘
    $dim = $global:DIM

    if ($Prefix -eq "> ") {
        # 工具调用: 提取工具名并着色
        $parenIdx = $Content.IndexOf('(')
        if ($parenIdx -gt 0) {
            $toolName = $Content.Substring(0, $parenIdx)
            $toolArgs = $Content.Substring($parenIdx)
            $tc = if ($toolColorMap.ContainsKey($toolName)) { $toolColorMap[$toolName] } else { "${esc}[36m" }
            Write-Host "  ${arrow} ${tc}${toolName}${rst}${dim}${toolArgs}${rst}"
        } else {
            Write-Host "  ${arrow} ${esc}[36m$Content${rst}"
        }
    } elseif ($Prefix -eq "< ") {
        # 工具结果: 检测成功/失败
        $isError = ($Content -match '"error"' -or $Content -match '"status":"cancelled"' -or $Content -match "Error:" -or $Content -match "FAILED")
        if ($isError) {
            Write-Host "  ${back} ${esc}[31m$cross${rst} ${dim}$Content${rst}"
        } else {
            Write-Host "  ${back} ${esc}[32m$check${rst} ${dim}$Content${rst}"
        }
    } else {
        # 通用 fallback: 保持原有行为
        $iconStr = if ($Icon) { "$Icon " } else { "" }
        Write-Host "  $iconStr$Prefix$Content" -ForegroundColor $Color
    }
}

# ── 状态栏 (Phase 2 TUI) ──

function Write-StatusBar {
    <#
    .SYNOPSIS
    在当前行绘制一行状态栏，显示轮次/上下文/模型/Token/安全模式。
    不使用滚动区域（PS5.1 兼容），仅作为信息行输出。
    #>
    param(
        [string]$State = "idle",   # idle | thinking | tools | done
        [int]$ToolDone = 0,
        [int]$ToolTotal = 0,
        [double]$Elapsed = 0
    )
    $esc = $global:ESC
    $rst = $global:RESET
    $dim = $global:DIM
    $bld = $global:BOLD

    # ── 收集数据 ──
    $turn = [int]$global:TURN_COUNTER
    $inTok = [int]$global:SESSION_INPUT_TOKENS
    $outTok = [int]$global:SESSION_OUTPUT_TOKENS
    $model = if ($global:PA_MODEL) { ($global:PA_MODEL -split '-')[-1] } else { "?" }
    $safe = if ($global:PA_SAFE_MODE) { "$([char]0x26A0)SAFE" } else { "" }

    # 上下文百分比
    $ctxPct = 0
    try {
        $ctxTokens = Estimate-ContextTokens
        $ctxWin = [int]$global:PA_CONTEXT_WINDOW
        if ($ctxWin -gt 0) { $ctxPct = [Math]::Min([Math]::Floor($ctxTokens / $ctxWin * 100), 100) }
    } catch { }

    # 上下文进度条 (10格)
    $barW = 10
    $filled = [Math]::Floor($ctxPct / 100 * $barW)
    $empty = $barW - $filled
    $barChar = [string][char]0x2588   # █
    $gapChar = [string][char]0x2591   # ░
    $ctxBar = "${barChar}" * $filled + "${gapChar}" * $empty

    # 上下文颜色
    $ctxColor = if ($ctxPct -ge 85) { "${esc}[31m" } elseif ($ctxPct -ge 70) { "${esc}[33m" } else { "${esc}[32m" }

    # ── 状态段 ──
    $stateIcon = switch ($State) {
        "thinking" { "$([char]0x2726)" }   # ✦
        "tools"    { "$([char]0x2699)" }   # ⚙
        "done"     { "$([char]0x2714)" }   # ✔
        default    { "$([char]0x25B8)" }   # ▸
    }
    $stateColor = switch ($State) {
        "thinking" { "${esc}[93m" }
        "tools"    { "${esc}[94m" }
        "done"     { "${esc}[32m" }
        default    { "${esc}[36m" }
    }

    # ── Token 格式化 ──
    $tokStr = ""
    if ($inTok -ge 1000000) {
        $tokStr = "{0:N1}M" -f ($inTok / 1000000)
    } elseif ($inTok -ge 1000) {
        $tokStr = "{0:N1}K" -f ($inTok / 1000)
    } else {
        $tokStr = "$inTok"
    }

    # ── 耗时 ──
    $elapsedStr = ""
    if ($Elapsed -gt 0) {
        $elapsedStr = "${dim}$(('{0:N1}s' -f $Elapsed))${rst}"
    }

    # ── 工具进度 ──
    $toolProgress = ""
    if ($ToolTotal -gt 0) {
        $toolProgress = "${esc}[94m$ToolDone${rst}${dim}/${esc}[0m${esc}[94m$ToolTotal${rst} tools"
    }

    # ── 组装状态栏 ──
    $sep = "${dim} │ ${rst}"
    $line = "${stateColor}$stateIcon${rst} "
    $line += "${bld}T$turn${rst}"
    $line += $sep
    $line += "${ctxColor}$ctxBar${rst}${dim} ${ctxPct}%${rst}"
    $line += $sep
    $line += "${dim}$model${rst}"
    $line += $sep
    $line += "${dim}$tokStr${rst}"
    if ($toolProgress) {
        $line += $sep
        $line += $toolProgress
    }
    if ($elapsedStr) {
        $line += $sep
        $line += $elapsedStr
    }
    if ($safe) {
        $line += $sep
        $line += "${esc}[93m$safe${rst}"
    }

    # 写入：用 \r 回到当前行行首，清行后输出（供下次覆盖）
    # 注意1：不能用 ESC[G（仅移到当前行行首），某些终端处理时机与后续字符不同步，
    #   可能把内容写到提示符行造成鬼影。[Console]::Write("\r") 更可靠。
    # 注意2：全程使用 [Console]::Write 而非 Write-Host，因为此函数在
    #   System.Timers.Timer 的线程池回调中执行，Write-Host 走 $host.UI.Write()
    #   不保证线程安全，且 PS Host 内部光标跟踪可能与 [Console] 实际位置不同步。
    [Console]::Write("`r${esc}[2K  $line")
}

# ── 轻量 Markdown 渲染器 (Phase 1 TUI) ──

function Write-MarkdownLight {
    param([string]$Text)
    # 逐行处理基本 Markdown: 标题/粗体/行内代码/列表/引用/代码块
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $esc = $global:ESC
    $rst = $global:RESET
    $bld = $global:BOLD
    $dim = $global:DIM
    $cyan = $global:CYAN
    $yellow = $global:YELLOW
    $gray = $global:GRAY
    $white = $global:WHITE
    $lcyan = $global:LIGHT_CYAN
    $lines = $Text -split "`n"
    $inCodeBlock = $false
    foreach ($rawLine in $lines) {
        $line = $rawLine
        # ── 代码围栏切换 ──
        $codeFence = [string]([char]0x60) + [string]([char]0x60) + [string]([char]0x60)
        if ($line.TrimStart().StartsWith($codeFence)) {
            $inCodeBlock = -not $inCodeBlock
            if ($inCodeBlock) {
                # 显示语言标识（如有）
                $lang = $line.TrimStart().Substring(3).Trim()
                if ($lang) { Write-Host "  ${dim}$lang${rst}" }
            }
            continue
        }
        if ($inCodeBlock) {
            Write-Host "  ${gray}$line${rst}"
            continue
        }
        # ── 空行 ──
        if ([string]::IsNullOrWhiteSpace($line)) {
            Write-Host ""
            continue
        }
        $trimmed = $line.TrimStart()
        # ── 标题 ──
        if ($trimmed.StartsWith("### ")) {
            $heading = $trimmed.Substring(4)
            Write-Host "  ${cyan}${bld}  $heading${rst}"
            continue
        }
        if ($trimmed.StartsWith("## ")) {
            $heading = $trimmed.Substring(3)
            Write-Host "  ${lcyan}${bld}  $heading${rst}"
            Write-Host "  ${dim}$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)${rst}"
            continue
        }
        if ($trimmed.StartsWith("# ")) {
            $heading = $trimmed.Substring(2)
            Write-Host "  ${cyan}${bld}$heading${rst}"
            Write-Host "  ${cyan}$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)$([char]0x2500)${rst}"
            continue
        }
        # ── 引用 ──
        if ($trimmed.StartsWith("> ")) {
            $quoteContent = $trimmed.Substring(2)
            Write-Host "  ${dim}$([char]0x2502) ${rst}$quoteContent"
            continue
        }
        # ── 无序列表 ──
        if ($trimmed.StartsWith("- ") -or $trimmed.StartsWith("* ")) {
            $itemContent = $trimmed.Substring(2)
            Write-Host "  ${cyan}$([char]0x2022)${rst} $itemContent"
            continue
        }
        # ── 有序列表 ──
        if ($trimmed -match '^(\d+)\.\s+(.*)') {
            $num = $Matches[1]
            $itemContent = $Matches[2]
            Write-Host "  ${cyan}$num.${rst} $itemContent"
            continue
        }
        # ── 普通文本: 行内格式化 ──
        # 行内代码 `code` → 黄色
        $bt = [char]0x60
        $codePattern = $bt + '([^' + $bt + ']+)' + $bt
        $rendered = [regex]::Replace($line, $codePattern, "${yellow}${bt}`$1${bt}${rst}")
        # 粗体 **text** → BOLD
        $rendered = [regex]::Replace($rendered, '\*\*(.+?)\*\*', "${bld}`$1${rst}")
        Write-Host "  $rendered"
    }
}

# ============================================================================
#  Hook System (Section 2 hooks)
# ============================================================================

$global:HOOK_HANDLERS = @{}
$global:HOOK_TYPE = @{}
$global:HOOK_ENABLED = @{}
$global:HOOK_PRIORITY = @{}
$global:HOOK_META = @{}
$global:HOOK_POINTS = @{}

function Register-Hook {
    param(
        [string]$Name,
        [string]$Point,
        [string]$Handler,
        [string]$Type = "inline_ps",
        [int]$Priority = 50,
        [string]$Meta = "{}"
    )
    $global:HOOK_HANDLERS[$Name] = $Handler
    $global:HOOK_TYPE[$Name] = $Type
    $global:HOOK_ENABLED[$Name] = $true
    $global:HOOK_PRIORITY[$Name] = $Priority
    $global:HOOK_META[$Name] = $Meta
    if (-not $global:HOOK_POINTS[$Point]) {
        $global:HOOK_POINTS[$Point] = @()
    }
    $global:HOOK_POINTS[$Point] = @($global:HOOK_POINTS[$Point]) + @($Name)
}

function Invoke-HookFire {
    param([string]$Point, [hashtable]$Context = @{})
    $handlers = $global:HOOK_POINTS[$Point]
    if (-not $handlers) { return @() }

    $results = @()
    # Sort by priority (ascending)
    $sorted = $handlers | Sort-Object { $global:HOOK_PRIORITY[$_] }
    foreach ($name in $sorted) {
        if (-not $global:HOOK_ENABLED[$name]) { continue }
        $body = $global:HOOK_HANDLERS[$name]
        $type = $global:HOOK_TYPE[$name]
        try {
            switch ($type) {
                "inline_ps" {
                    # Make context variables available to handler as $_hook_<key>
                    foreach ($key in $Context.Keys) {
                        Set-Variable -Name "_hook_$key" -Value $Context[$key] -Scope Local
                    }
                    $output = Invoke-Expression $body
                    if ($output) { $results += $output }
                }
                "ps" {
                    $output = & $body @Context
                    if ($output) { $results += $output }
                }
                "exec" {
                    $output = & $body
                    if ($output) { $results += $output }
                }
                "http" {
                    # HTTP webhook: POST JSON payload to configured URL
                    try {
                        $payload = @{
                            hook      = $name
                            point     = $Point
                            context   = $Context
                            timestamp = Get-TimestampMs
                        } | ConvertTo-Json -Depth 5 -Compress
                        $headers = @{ "Content-Type" = "application/json" }
                        # Check for custom headers in HOOK_META
                        if ($global:HOOK_META -and $global:HOOK_META[$name] -and $global:HOOK_META[$name].headers) {
                            foreach ($hk in $global:HOOK_META[$name].headers.Keys) {
                                $headers[$hk] = $global:HOOK_META[$name].headers[$hk]
                            }
                        }
                        $resp = Invoke-WebRequest -Uri $body -Method POST -Body $payload -Headers $headers -TimeoutSec 10 -UseBasicParsing
                        Write-Log "DEBUG: HTTP hook $name fired -> $($resp.StatusCode)"
                        if ($resp.Content) {
                            try {
                                $parsed = $resp.Content | ConvertFrom-Json
                                if ($parsed) { $results += $parsed }
                            } catch {
                                $results += $resp.Content
                            }
                        }
                    } catch {
                        Write-Log "WARN: HTTP hook $name failed: $($_.Exception.Message)"
                    }
                }
                default { Write-Log "WARN: unknown hook type $type for $name" }
            }
        } catch {
            Write-Log "WARN: hook $name error: $_"
        }
    }
    return ,$results
}

function Import-Hooks {
    param([string]$Dir)
    $hookDir = Join-Path $Dir "hooks"
    if (-not (Test-Path $hookDir)) { return }
    Get-ChildItem $hookDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $cfg = Get-Content $_.FullName -Raw | ConvertFrom-Json
            Register-Hook -Name $cfg.name -Point $cfg.point -Handler $cfg.handler `
                -Type $cfg.type -Priority $cfg.priority -Meta ($cfg | ConvertTo-Json -Compress)
        } catch {
            Write-Log "WARN: Failed to load hook $($_.Name)"
        }
    }
}

# ============================================================================
#  Dependency Checks
# ============================================================================

function Test-Dependencies {
    <# Check required external tools. PowerAgent uses pure PowerShell for all operations. #>
    $missing = @()

    # PowerShell 5.1 version check
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Die "PowerAgent requires PowerShell 5.1 or later (current: $($PSVersionTable.PSVersion))"
    }

    # jq is no longer required — all JSON operations use pure PowerShell

    # curl check (uses Invoke-WebRequest as primary; curl.exe as fallback)
    # PS5.1 has Invoke-WebRequest built-in; curl.exe is optional
    try {
        $null = Get-Command curl.exe -ErrorAction Stop
        Write-Log "DEBUG: curl.exe available as HTTP fallback"
    } catch {
        Write-Log "DEBUG: curl.exe not found - will use Invoke-WebRequest (PS native)"
    }

    if ($missing.Count -gt 0) {
        Write-Log "WARN: Missing dependencies: $($missing -join ', ')"
        Write-Host "${global:YELLOW}[poweragent]${global:RESET} Missing: $($missing -join ', ')"
        Write-Host "  Install: choco install $($missing -join ' ')" -ForegroundColor Gray
    }
    return $missing.Count -eq 0
}

# ============================================================================
#  System Directory Initialization
# ============================================================================

function Initialize-SystemDirs {
    $baseDir = Join-Path $env:USERPROFILE ".poweragent"
    $dirs = @(
        $baseDir
        (Join-Path $baseDir "agents")
        (Join-Path $baseDir "skills")
        (Join-Path $baseDir "hooks")
        (Join-Path $baseDir "log")
        (Join-Path $baseDir "sessions")
        (Join-Path $baseDir "mem_net")
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Generate default settings.json if not exists
    $settingsFile = Join-Path $baseDir "settings.json"
    if (-not (Test-Path $settingsFile)) {
        $defaultSettings = @{
            api_url = $global:DEFAULT_API_URL
            model   = $global:DEFAULT_MODEL
            max_tokens = [int]$global:DEFAULT_MAX_TOKENS
            thinking_budget = [int]$global:DEFAULT_THINKING_BUDGET
        } | ConvertTo-Json -Depth 5
        Set-Content $settingsFile $defaultSettings -Encoding UTF8
    }
}

function Initialize-ProjectDirs {
    $baseDir = if ($global:PA_PROJECT_DIR) { $global:PA_PROJECT_DIR } else { "." }
    $paDir = Join-Path $baseDir ".poweragent"
    $dirs = @(
        $paDir
        (Join-Path $paDir "agents")
        (Join-Path $paDir "skills")
        (Join-Path $paDir "hooks")
        (Join-Path $paDir "log")
        (Join-Path $paDir "offload")
        (Join-Path $paDir "mem_net")
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}


# ── 供应商预设表 ──
# 格式: @{ name = "显示名"; baseUrl = "完整 API URL (含 /chat/completions)"; models = @("model1", "model2") }
$global:PROVIDERS = [ordered]@{
    "aliyun" = @{
        name     = "阿里云百炼"
        baseUrl  = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        models   = @("qwen3.7-max", "qwen3.6-plus")
    }
    "baidu" = @{
        name     = "百度千帆"
        baseUrl  = "https://qianfan.baidubce.com/v2/chat/completions"
        models   = @("ernie-5.1", "ernie-4.5t")
    }
    "zhipu" = @{
        name     = "智谱 AI (GLM)"
        baseUrl  = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        models   = @("glm-5.1", "glm-5-turbo")
    }
    "deepseek" = @{
        name     = "DeepSeek"
        baseUrl  = "https://api.deepseek.com/v1/chat/completions"
        models   = @("deepseek-v4-pro", "deepseek-v4-flash")
    }
    "moonshot" = @{
        name     = "月之暗面 (Kimi)"
        baseUrl  = "https://api.moonshot.cn/v1/chat/completions"
        models   = @("kimi-k2.6", "kimi-k2.5")
    }
    "minimax" = @{
        name     = "MiniMax"
        baseUrl  = "https://api.minimaxi.com/v1/chat/completions"
        models   = @("MiniMax-M3", "MiniMax-M2.7")
    }
}

# ============================================================================
#  Inlined: Config.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Config.ps1
#  Section 3: Configuration Loading (4-tier: project > system > env > default)
#  PowerShell 5.1 port of bashagt Section 3 (lines 4941-5140)
# ============================================================================

# ── Configuration cache (replaces bash declare -g _CFG_*) ──
$global:_CFG = @{}

function Get-Setting {
    <#
    .SYNOPSIS
    4-tier configuration lookup: _CFG cache > env var > default.
    Mirrors bashagt _get_setting().
    #>
    param(
        [string]$Key,
        [string]$EnvVar,
        $Default = ""
    )
    # Tier 1: Config cache (from merged settings.json)
    if ($global:_CFG.ContainsKey($Key) -and $global:_CFG[$Key]) {
        $v = $global:_CFG[$Key]
        if ($v -ne "null" -and $v -ne $null) { return $v }
    }
    # Tier 2: Environment variable
    if ($EnvVar -and (Get-ChildItem env: | Where-Object { $_.Name -eq $EnvVar })) {
        $ev = [Environment]::GetEnvironmentVariable($EnvVar)
        if ($ev) { return $ev }
    }
    # Tier 3: Default
    return $Default
}

function Save-Setting {
    <#
    .SYNOPSIS
    Persist a single key-value pair to system settings.json.
    Updates _CFG cache + writes to disk atomically.
    #>
    param([string]$Key, $Value)
    $sysFile = Join-Path $env:USERPROFILE ".poweragent\settings.json"
    $json = "{}"
    if (Test-Path $sysFile) {
        $json = Get-Content $sysFile -Raw -Encoding UTF8
    }
    $obj = $json | ConvertFrom-Json
    if ($null -eq $obj) { $obj = [PSCustomObject]@{} }
    # Update or add property
    $found = $false
    foreach ($p in $obj.PSObject.Properties) {
        if ($p.Name -eq $Key) { $p.Value = $Value; $found = $true; break }
    }
    if (-not $found) {
        $obj | Add-Member -NotePropertyName $Key -NotePropertyValue $Value
    }
    $newJson = $obj | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $sysFile -Content $newJson
    # Update cache
    $global:_CFG[$Key] = $Value
}

function Get-CurrentProvider {
    <#
    .SYNOPSIS
    Detect current provider based on api_url match.
    Returns provider key or "custom".
    #>
    $url = "$($global:PA_API_URL)".TrimEnd('/')
    foreach ($key in $global:PROVIDERS.Keys) {
        $pUrl = $global:PROVIDERS[$key].baseUrl.TrimEnd('/')
        if ($url -eq $pUrl -or $url.StartsWith($pUrl)) { return $key }
    }
    return "custom"
}

function Merge-SettingsJson {
    <#
    .SYNOPSIS
    Merge system + project settings.json into _CFG cache.
    Pure PowerShell implementation (no external dependencies).
    #>
    param([string]$SystemJson, [string]$ProjectJson)

    # 确保 _CFG 已初始化
    if ($null -eq $global:_CFG) { $global:_CFG = @{} }

    # PS native merge
    $sysObj = $SystemJson | ConvertFrom-Json
    $prjObj = $ProjectJson | ConvertFrom-Json

    # System first
    if ($sysObj) {
        $sysObj.PSObject.Properties | ForEach-Object {
            $global:_CFG[$_.Name] = $_.Value
        }
    }
    # Project overrides
    if ($prjObj) {
        $prjObj.PSObject.Properties | ForEach-Object {
            $global:_CFG[$_.Name] = $_.Value
        }
    }
}

function Import-Config {
    <#
    .SYNOPSIS
    Load configuration from 4-tier priority chain.
    Port of bashagt load_config().
    #>

    # Clear stale cache — ensures fresh load from settings.json files.
    # (Callers that set $global:_CFG = @{} may be shadowed by Pester v5 scope;
    #  clearing here guarantees no stale data leaks across test boundaries.)
    $global:_CFG = @{}

    # Read system settings
    $sysJson = "{}"
    $sysFile = Join-Path $env:USERPROFILE ".poweragent\settings.json"
    if (Test-Path $sysFile) {
        $sysJson = Get-Content $sysFile -Raw -Encoding UTF8
    }

    # Read project settings
    $prjJson = "{}"
    $prjBase = if ($global:PA_PROJECT_DIR) { $global:PA_PROJECT_DIR } else { "." }
    $prjFile = Join-Path $prjBase ".poweragent\settings.json"
    if (Test-Path $prjFile) {
        $prjJson = Get-Content $prjFile -Raw -Encoding UTF8
    } else {
        # Legacy name support
        $legacyFile = Join-Path $prjBase ".poweragent\poweragent_setting.json"
        if (Test-Path $legacyFile) {
            $prjJson = Get-Content $legacyFile -Raw -Encoding UTF8
        }
    }

    # Merge into cache
    Merge-SettingsJson $sysJson $prjJson

    # ── Resolve all configuration values ──
    $global:PA_API_KEY            = Get-Setting "api_key" "PA_API_KEY" ""
    # Fallback: check DEEPSEEK_API_KEY env var if PA_API_KEY is empty
    if (-not $global:PA_API_KEY) {
        $deepseekKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY")
        if ($deepseekKey) { $global:PA_API_KEY = $deepseekKey }
    }
    $global:PA_API_URL            = Get-Setting "api_url" "PA_API_URL" $global:DEFAULT_API_URL
    $global:PA_MODEL              = Get-Setting "model" "PA_MODEL" $global:DEFAULT_MODEL
    $global:PA_API_PROTOCOL       = Get-Setting "api_protocol" "PA_API_PROTOCOL" $global:DEFAULT_API_PROTOCOL
    $global:PA_MEM_ENGRAM_MODEL   = Get-Setting "mem_engram_model" "PA_MEM_ENGRAM_MODEL" ""
    $global:PA_MEM_ENGRAM_COUNT   = Get-Setting "mem_engram_count" "PA_MEM_ENGRAM_COUNT" $global:DEFAULT_MEM_ENGRAM_COUNT
    $global:PA_MEM_ENGRAM_SLOTS   = Get-Setting "mem_engram_slots" "PA_MEM_ENGRAM_SLOTS" $global:DEFAULT_MEM_ENGRAM_SLOTS
    $global:PA_MAX_TOKENS         = Get-Setting "max_tokens" "PA_MAX_TOKENS" $global:DEFAULT_MAX_TOKENS
    $global:PA_THINKING_BUDGET    = Get-Setting "thinking_budget" "PA_THINKING_BUDGET" $global:DEFAULT_THINKING_BUDGET
    $global:PA_CONNECT_TIMEOUT    = Get-Setting "connect_timeout" "PA_CONNECT_TIMEOUT" $global:DEFAULT_CONNECT_TIMEOUT
    $global:PA_CMD_TIMEOUT        = Get-Setting "cmd_timeout" "PA_CMD_TIMEOUT" $global:DEFAULT_CMD_TIMEOUT
    $global:PA_COMPRESS_THRESHOLD = Get-Setting "compress_threshold" "PA_COMPRESS_THRESHOLD" $global:DEFAULT_COMPRESS_THRESHOLD
    $global:PA_SYSTEM_PROMPT      = Get-Setting "system_prompt" "PA_SYSTEM_PROMPT" $global:DEFAULT_SYSTEM_PROMPT
    $global:PA_SHOW_THINKING      = Get-Setting "show_thinking" "PA_SHOW_THINKING" $global:DEFAULT_SHOW_THINKING
    $global:PA_AUTH_HEADER        = Get-Setting "auth_header" "PA_AUTH_HEADER" ""
    $global:PA_FORMAT_SUBAGENT    = Get-Setting "format_subagent" "PA_FORMAT_SUBAGENT" $global:DEFAULT_FORMAT_SUBAGENT
    $global:PA_FORMAT_MAX_TOKENS  = Get-Setting "format_max_tokens" "PA_FORMAT_MAX_TOKENS" $global:DEFAULT_FORMAT_MAX_TOKENS
    $global:PA_TURN_BUDGET_SOFT   = Get-Setting "turn_budget_soft" "PA_TURN_BUDGET_SOFT" $global:DEFAULT_TURN_BUDGET_SOFT
    $global:PA_TURN_BUDGET_HARD   = Get-Setting "turn_budget_hard" "PA_TURN_BUDGET_HARD" $global:DEFAULT_TURN_BUDGET_HARD
    $global:PA_CONTEXT_WINDOW     = Get-Setting "context_window" "PA_CONTEXT_WINDOW" $global:DEFAULT_CONTEXT_WINDOW
    $global:PA_CONTEXT_SAFE_RATIO = Get-Setting "context_safe_ratio" "PA_CONTEXT_SAFE_RATIO" $global:DEFAULT_CONTEXT_SAFE_RATIO
    $global:PA_STUCK_THRESHOLD    = Get-Setting "stuck_threshold" "PA_STUCK_THRESHOLD" $global:DEFAULT_STUCK_THRESHOLD
    $global:PA_WEB_SEARCH_ENGINE  = Get-Setting "web_search_engine" "PA_WEB_SEARCH_ENGINE" $global:DEFAULT_WEB_SEARCH_ENGINE
    $global:PA_WEB_SEARCH_TIMEOUT = Get-Setting "web_search_timeout" "PA_WEB_SEARCH_TIMEOUT" $global:DEFAULT_WEB_SEARCH_TIMEOUT
    $global:PA_MEMORY_ENABLED     = Get-Setting "memory_enabled" "PA_MEMORY_ENABLED" $global:DEFAULT_MEMORY_ENABLED
    $global:PA_MEMORY_MAX_CONTEXT = Get-Setting "memory_max_context" "PA_MEMORY_MAX_CONTEXT" $global:DEFAULT_MEMORY_MAX_CONTEXT
    $global:PA_TODO_ENABLED       = Get-Setting "todo_enabled" "PA_TODO_ENABLED" $global:DEFAULT_TODO_ENABLED
    $global:PA_TODO_MAX_CONTEXT   = Get-Setting "todo_max_context" "PA_TODO_MAX_CONTEXT" $global:DEFAULT_TODO_MAX_CONTEXT
    $global:PA_MCP_ENABLED        = Get-Setting "mcp_enabled" "PA_MCP_ENABLED" $global:DEFAULT_MCP_ENABLED
    $global:PA_MCP_CONNECT_TIMEOUT = Get-Setting "mcp_connect_timeout" "PA_MCP_CONNECT_TIMEOUT" $global:DEFAULT_MCP_CONNECT_TIMEOUT
    $global:PA_MCP_REQUEST_TIMEOUT = Get-Setting "mcp_request_timeout" "PA_MCP_REQUEST_TIMEOUT" $global:DEFAULT_MCP_REQUEST_TIMEOUT
    $global:PA_PROJECT_DIR        = Get-Setting "project_dir" "PA_PROJECT_DIR" $global:DEFAULT_PROJECT_DIR
    $global:PA_DAEMON_PORT        = Get-Setting "daemon_port" "PA_DAEMON_PORT" $global:DEFAULT_DAEMON_PORT
    $global:PA_SUBPROC_MAX        = Get-Setting "subproc_max" "PA_SUBPROC_MAX" $global:DEFAULT_SUBPROC_MAX
    $global:PA_CACHE_ENABLED      = Get-Setting "cache_enabled" "PA_CACHE_ENABLED" $global:DEFAULT_CACHE_ENABLED
    $global:PA_CACHE_MSG_TAIL     = Get-Setting "cache_msg_tail" "PA_CACHE_MSG_TAIL" $global:DEFAULT_CACHE_MSG_TAIL
    $global:PA_CACHE_PROBE_MAX_MISSES = Get-Setting "cache_probe_max_misses" "PA_CACHE_PROBE_MAX_MISSES" $global:DEFAULT_CACHE_PROBE_MAX_MISSES
    $global:PA_CACHE_PROBE_REPROBE = Get-Setting "cache_probe_reprobe" "PA_CACHE_PROBE_REPROBE" $global:DEFAULT_CACHE_PROBE_REPROBE
    $global:PA_CACHE_API_SUPPORT  = Get-Setting "cache_api_support" "PA_CACHE_API_SUPPORT" $global:DEFAULT_CACHE_API_SUPPORT
    $global:PA_CACHE_MARKER       = Get-Setting "cache_marker" "PA_CACHE_MARKER" $global:DEFAULT_CACHE_MARKER
    $global:PA_DARK_MODE          = Get-Setting "dark_mode" "PA_DARK_MODE" $global:DEFAULT_DARK_MODE
    $global:PA_TRACE_ENABLED      = Get-Setting "trace_enabled" "PA_TRACE_ENABLED" $global:DEFAULT_TRACE_ENABLED
    $global:PA_TRACE_MAX_FRAMES   = Get-Setting "trace_max_frames" "PA_TRACE_MAX_FRAMES" $global:DEFAULT_TRACE_MAX_FRAMES
    $global:PA_TRACE_SNAPSHOT_INTERVAL = Get-Setting "trace_snapshot_interval" "PA_TRACE_SNAPSHOT_INTERVAL" $global:DEFAULT_TRACE_SNAPSHOT_INTERVAL
    $global:PA_TRACE_PRUNE_KEEP   = Get-Setting "trace_prune_keep" "PA_TRACE_PRUNE_KEEP" $global:DEFAULT_TRACE_PRUNE_KEEP
    $global:PA_PROXY_URL          = Get-Setting "proxy_url" "PA_PROXY_URL" ""
    $global:PA_PROXY_USER         = Get-Setting "proxy_user" "PA_PROXY_USER" ""
    $global:PA_PROXY_PASS         = Get-Setting "proxy_pass" "PA_PROXY_PASS" ""
    $global:PA_PROXY_NOPROXY      = Get-Setting "proxy_noproxy" "PA_PROXY_NOPROXY" $global:DEFAULT_PROXY_NOPROXY

    # ── Resolve API protocol ──
    $global:PA_PROTOCOL = Resolve-Protocol

    # ── Resolve model profile (vendor-specific API behavior) ──
    $global:PA_MODEL_PROFILE = Resolve-ModelProfile -Url $global:PA_API_URL -Model $global:PA_MODEL

    # ── Resolve auth header ──
    if (-not $global:PA_AUTH_HEADER) {
        if ($global:PA_PROTOCOL -eq "openai") {
            $global:PA_AUTH_HEADER = "Authorization"
            $global:PA_AUTH_PREFIX = "Bearer "
        } elseif ($global:PA_API_URL -match "deepseek") {
            $global:PA_AUTH_HEADER = "Authorization"
            $global:PA_AUTH_PREFIX = "Bearer "
        } elseif ($global:PA_API_URL -match "anthropic") {
            $global:PA_AUTH_HEADER = "x-api-key"
            $global:PA_AUTH_PREFIX = ""
        } else {
            $global:PA_AUTH_HEADER = "x-api-key"
            $global:PA_AUTH_PREFIX = ""
        }
    } else {
        $global:PA_AUTH_PREFIX = ""
    }

    if (-not $global:PA_API_KEY) {
        # ── First-run: interactive provider setup ──
        # Only trigger in interactive mode + real terminal (not Pester/CI/pipe)
        $isRealTty = (-not [Console]::IsOutputRedirected) -and ($host.Name -ne 'Default Host')
        if ($script:PA_MODE -eq "interactive" -and $isRealTty) {
            Write-Host ""
            Write-Host "  $($global:BOLD)$($global:YELLOW)$([char]0x26A0) No API key configured.$($global:RESET)"
            Write-Host "  Let's set up your LLM provider now."
            try {
                Invoke-SlashProvider ""
            } catch {
                Write-Log "WARN: First-run provider setup failed: $_"
            }
            if (-not $global:PA_API_KEY) {
                Write-Die "API key not set. Restart and use /provider to configure."
            }
            # Re-resolve derived config (provider may have changed URL/model)
            $global:PA_PROTOCOL = Resolve-Protocol
            $global:PA_MODEL_PROFILE = Resolve-ModelProfile -Url $global:PA_API_URL -Model $global:PA_MODEL
            $global:PA_AUTH_HEADER = ""
            $global:PA_AUTH_PREFIX = ""
            if ($global:PA_PROTOCOL -eq "openai") {
                $global:PA_AUTH_HEADER = "Authorization"; $global:PA_AUTH_PREFIX = "Bearer "
            } elseif ($global:PA_API_URL -match "anthropic") {
                $global:PA_AUTH_HEADER = "x-api-key"; $global:PA_AUTH_PREFIX = ""
            } else {
                $global:PA_AUTH_HEADER = "x-api-key"; $global:PA_AUTH_PREFIX = ""
            }
        } else {
            Write-Die "API key not set. Configure ~/.poweragent/settings.json or set PA_API_KEY"
        }
    }

    # ── Memory capacity ──
    $global:MEM_ENGRAM_COUNT = [int]$global:PA_MEM_ENGRAM_COUNT
    $global:MEM_ENGRAM_SLOTS = [int]$global:PA_MEM_ENGRAM_SLOTS
    $global:MEM_TOTAL_CAPACITY = $global:MEM_ENGRAM_COUNT * $global:MEM_ENGRAM_SLOTS

    Write-Log "DEBUG: [INIT] load_config: model=$($global:PA_MODEL) max_tok=$($global:PA_MAX_TOKENS) protocol=$($global:PA_PROTOCOL)"
}

function Resolve-Protocol {
    $proto = $global:PA_API_PROTOCOL
    if ($proto -ne "auto") { return $proto }
    $url = $global:PA_API_URL
    if ($url -match "anthropic\.com|/anthropic/") { return "anthropic" }
    if ($url -match "openai\.com|/v1/chat/completions|/openai/") { return "openai" }
    if ($url -match "deepseek") { return "openai" }
    return "openai"
}

function Import-PowerAgentMd {
    <# Load project context from .poweragent/POWERAGENT.md #>
    $base = if ($global:PA_PROJECT_DIR) { $global:PA_PROJECT_DIR } else { "." }
    $mdFile = Join-Path $base ".poweragent\POWERAGENT.md"
    if (Test-Path $mdFile) {
        $mtime = Get-FileMtime $mdFile
        if ($mtime -ne $global:_PA_MD_MTIME) {
            $global:PA_MD = Get-Content $mdFile -Raw -Encoding UTF8
            $global:_PA_MD_MTIME = $mtime
        }
    } else {
        $global:PA_MD = ""
        $global:_PA_MD_MTIME = 0
    }
}


# ============================================================================
#  Inlined: Messages.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Messages.ps1
#  Section 4: Message History Management
#  PowerShell 5.1 port of bashagt Section 4 (lines 5143-5194)
# ============================================================================

# ── Message store: JSON array as string (mirrors bash MESSAGES='[]') ──
# In PS5.1 we store as ArrayList of hashtables for efficient append
$global:MESSAGES = @()

function Save-History {
    $json = ConvertTo-JsonSafe $global:MESSAGES -Depth 20
    if ($global:PA_HISTORY_FILE) {
        Write-AtomicFile $global:PA_HISTORY_FILE $json
    }
}

function Load-History {
    if ($global:PA_HISTORY_FILE -and (Test-Path $global:PA_HISTORY_FILE)) {
        try {
            $content = Get-Content $global:PA_HISTORY_FILE -Raw -Encoding UTF8
            $loaded = $content | ConvertFrom-Json
            # Filter empty messages
            $global:MESSAGES = @()
            foreach ($msg in $loaded) {
                if ($msg.content -and $msg.content.Count -gt 0 -and "$($msg.content)" -ne "") {
                    $global:MESSAGES += $msg
                }
            }
            Write-Log "DEBUG: [HIST] loaded $($global:MESSAGES.Count) messages"
        } catch {
            Write-Log "WARN: Failed to load history: $_"
            $global:MESSAGES = @()
        }
    } else {
        $global:MESSAGES = @()
    }
}

function Add-UserText {
    param([string]$Text)
    $global:MESSAGES += @{
        role = "user"
        content = $Text
    }
}

function Add-AssistantMessage {
    <# Build OpenAI-native assistant message from content blocks #>
    param([array]$ContentBlocks)
    $text = ""
    $toolCalls = @()
    $reasoning = ""

    foreach ($block in $ContentBlocks) {
        if ($block.type -eq "text") {
            $text += $block.text
        } elseif ($block.type -eq "thinking") {
            $reasoning += $block.thinking
        } elseif ($block.type -eq "tool_use" -or $block.type -eq "tool_call") {
            $argsJson = if ($block.arguments) {
                ConvertTo-JsonSafe $block.arguments -Depth 10
            } elseif ($block.input) {
                ConvertTo-JsonSafe $block.input -Depth 10
            } else { "{}" }
            $toolCalls += @{
                id = $block.id
                type = "function"
                function = @{
                    name = $block.name
                    arguments = $argsJson
                }
            }
        }
    }

    $msg = @{ role = "assistant"; content = $text }
    if ($toolCalls.Count -gt 0) { $msg["tool_calls"] = $toolCalls }
    if ($reasoning -ne "") { $msg["reasoning_content"] = $reasoning }

    $global:MESSAGES += $msg
}

function Add-ToolResults {
    <# Store tool results as OpenAI role=tool messages #>
    param([array]$Results)
    foreach ($result in $Results) {
        $toolContent = ""
        if ($result.content -is [array]) {
            foreach ($sub in $result.content) {
                if ($sub.text) { $toolContent += $sub.text }
            }
        } elseif ($result.content -is [string]) {
            $toolContent = $result.content
        }
        $global:MESSAGES += @{
            role = "tool"
            tool_call_id = $result.tool_use_id
            content = $toolContent
        }
    }
}

function Get-MessagesJson {
    <# Return current message history as JSON string for API calls #>
    return ConvertTo-JsonSafe $global:MESSAGES -Depth 20
}

function Clear-History {
    $global:MESSAGES = @()
}


# ============================================================================
#  Inlined: HttpClient.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - HttpClient.ps1
#  Section 6/6a: HTTP Client, SSE Streaming, API Communication
#  PowerShell 5.1 port of bashagt Section 6 (lines 6393-6962)
#
#  Key differences from Bash version:
#  - Uses Invoke-WebRequest / Invoke-RestMethod (PS native) instead of curl
#  - SSE streaming via .NET HttpClient instead of curl --no-buffer
#  - No process substitution; uses .NET async patterns
# ============================================================================

# ── HTTP response contract ──
# Exit codes (mirrors bashagt http_request):
#   0 = success, 1 = connect timeout, 2 = total timeout,
#   3 = HTTP error, 4 = DNS, 5 = TLS, 6 = client not found, 7 = ESC aborted

function Invoke-HttpRequest {
    <#
    .SYNOPSIS
    Single HTTP entry point for ALL HTTP communication.
    Uses System.Net.HttpWebRequest (支持 ESC 即时 Abort)。
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$Body,
        [hashtable]$Headers = @{},
        [int]$ConnectTimeout = 10,
        [int]$TotalTimeout = 120,
        [string]$ContentType = "application/json; charset=utf-8"
    )

    try {
        # 从 Headers 中移除 Content-Type
        $cleanHeaders = @{}
        foreach ($key in $Headers.Keys) {
            if ($key -ne "Content-Type") {
                $cleanHeaders[$key] = $Headers[$key]
            }
        }

        # 默认添加浏览器 User-Agent
        if (-not $cleanHeaders.ContainsKey("User-Agent")) {
            $cleanHeaders["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        }

        # 默认添加 Accept-Language
        if (-not $cleanHeaders.ContainsKey("Accept-Language")) {
            $cleanHeaders["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8"
        }

        # ── 使用 HttpWebRequest（支持 ESC Abort） ──
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = $Method
        $request.Timeout = $TotalTimeout * 1000
        $request.ReadWriteTimeout = $TotalTimeout * 1000
        $request.ContentType = $ContentType
        [System.Net.ServicePointManager]::Expect100Continue = $false

        # 设置 Headers
        foreach ($hKey in $cleanHeaders.Keys) {
            $hVal = $cleanHeaders[$hKey]
            try {
                if ($hKey -eq "Host") {
                    $request.Host = $hVal
                } elseif ($hKey -eq "Accept") {
                    $request.Accept = $hVal
                } elseif ($hKey -eq "Referer") {
                    $request.Referer = $hVal
                } elseif ($hKey -eq "User-Agent") {
                    $request.UserAgent = $hVal
                } elseif ($hKey -eq "Connection") {
                    $request.Connection = $hVal
                } elseif ($hKey -eq "Expect") {
                    $request.Expect = $hVal
                } elseif ($hKey -eq "Transfer-Encoding") {
                    $request.TransferEncoding = $hVal
                } elseif ($hKey -eq "If-Modified-Since") {
                    $request.IfModifiedSince = [DateTime]::Parse($hVal)
                } else {
                    $request.Headers[$hKey] = $hVal
                }
            } catch {
                Write-Log "WARN: Failed to set header '$hKey': $_"
            }
        }

        # Proxy support
        if ($global:PA_PROXY_URL) {
            try {
                $proxyUri = $global:PA_PROXY_URL
                if ($global:PA_PROXY_USER -and $global:PA_PROXY_PASS) {
                    $proxyBuilder = New-Object System.UriBuilder($proxyUri)
                    $proxyBuilder.UserName = $global:PA_PROXY_USER
                    $proxyBuilder.Password = $global:PA_PROXY_PASS
                    $proxyUri = $proxyBuilder.Uri.ToString()
                }
                $proxy = New-Object System.Net.WebProxy($proxyUri)
                if ($global:PA_PROXY_NOPROXY) {
                    $bypassList = @($global:PA_PROXY_NOPROXY -split "," | ForEach-Object { $_.Trim() })
                    $proxy.BypassList = $bypassList
                }
                $request.Proxy = $proxy
                Write-Log "DEBUG: Using proxy $proxyUri"
            } catch {
                Write-Log "WARN: Failed to configure proxy: $_"
            }
        }

        try {
            # 发送 Body
            if ($Body) {
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $request.ContentLength = $bodyBytes.Length
                $reqStream = $request.GetRequestStream()
                $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
                $reqStream.Close()
            }

            # ── 异步接收响应 + 主线程 ESC/Ctrl+C 轮询（每 50ms 检测一次，带防抖） ──
            $asyncResult = $request.BeginGetResponse($null, $null)
            $escAborted = $false
            $ctrlCAborted = $false
            while (-not $asyncResult.IsCompleted) {
                if ($global:_ESC_MONITOR_ACTIVE) {
                    # ESC 检测（中止操作，不退出）
                    if ([PA_KeyStateHelper]::IsEscapePressed()) {
                        if ($global:_ESC_RELEASED) {
                            $global:_ESC_PRESSED = $true
                            $global:_ESC_RELEASED = $false
                            try { $request.Abort() } catch { }
                            $escAborted = $true
                            break
                        }
                    } else {
                        $global:_ESC_RELEASED = $true
                    }
                    # Ctrl+C 检测（请求退出）
                    if ([PA_KeyStateHelper]::IsCtrlCPressed()) {
                        if ($global:_CTRL_C_RELEASED) {
                            $global:_CTRL_C_PRESSED = $true
                            $global:_CTRL_C_RELEASED = $false
                            try { $request.Abort() } catch { }
                            $ctrlCAborted = $true
                            break
                        }
                    } else {
                        $global:_CTRL_C_RELEASED = $true
                    }
                }
                Start-Sleep -Milliseconds 50
            }
            if ($escAborted) {
                throw (New-Object System.Net.WebException(
                    "ESC aborted", [System.Net.WebExceptionStatus]::RequestCanceled))
            }
            if ($ctrlCAborted) {
                throw (New-Object System.Net.WebException(
                    "Ctrl+C aborted", [System.Net.WebExceptionStatus]::RequestCanceled))
            }
            $response = $request.EndGetResponse($asyncResult)
        } finally {
        }

        # 读取响应体（UTF-8）
        $responseBody = ""
        try {
            $respStream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($respStream, [System.Text.Encoding]::UTF8)
            $responseBody = $reader.ReadToEnd()
            $reader.Close()
            $respStream.Close()
        } catch {
            $responseBody = "Error reading response body: $_"
        }

        $statusCode = [int]$response.StatusCode
        $response.Close()

        return @{
            ExitCode = 0
            StatusCode = $statusCode
            Body = $responseBody
            Headers = $response.Headers
        }
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Status -eq "RequestCanceled") {
            # 区分 ESC 中止(ExitCode=7) 和 Ctrl+C 中止(ExitCode=8)
            if ($ex.Message -match "Ctrl\+C") {
                return @{ ExitCode = 8; StatusCode = 0; Body = "Ctrl+C aborted"; Headers = @{} }
            }
            return @{ ExitCode = 7; StatusCode = 0; Body = "ESC aborted"; Headers = @{} }
        }
        if ($ex.Status -eq "Timeout" -or $ex.Status -eq "ConnectFailure") {
            return @{ ExitCode = 1; StatusCode = 0; Body = ""; Headers = @{} }
        }
        if ($ex.Status -eq "NameResolutionFailure") {
            return @{ ExitCode = 4; StatusCode = 0; Body = ""; Headers = @{} }
        }
        if ($ex.Status -eq "TrustFailure") {
            return @{ ExitCode = 5; StatusCode = 0; Body = ""; Headers = @{} }
        }
        if ($ex.Response) {
            $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $errorBody = $sr.ReadToEnd()
            $sr.Close()
            $ex.Response.Close()
            return @{ ExitCode = 3; StatusCode = [int]$ex.Response.StatusCode; Body = $errorBody; Headers = @{} }
        }
        return @{ ExitCode = 3; StatusCode = 0; Body = $_.Exception.Message; Headers = @{} }
    } catch [System.Management.Automation.PipelineStoppedException] {
        # 必须重新抛出，让 Start-AgentLoop 的 CTRL+C 确认对话框处理
        throw
    } catch {
        return @{ ExitCode = 3; StatusCode = 0; Body = $_.Exception.Message; Headers = @{} }
    }
}

# ============================================================================
#  SSE (Server-Sent Events) Streaming Client
#  Port of bashagt http_sse_connect() (L6849)
#  Uses .NET HttpClient for true streaming support in PS5.1
# ============================================================================

function Connect-SseStream {
    <#
    .SYNOPSIS
    Establish SSE connection and process events via callback.
    #>
    param(
        [string]$Url,
        [hashtable]$Headers = @{},
        [scriptblock]$OnEvent,
        [scriptblock]$OnError,
        [int]$TimeoutSec = 300
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    foreach ($key in $Headers.Keys) {
        $client.DefaultRequestHeaders.Add($key, $Headers[$key])
    }

    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        $stream = $response.Content.ReadAsStreamAsync().Result
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

        $eventData = @{}
        $buffer = [System.Text.StringBuilder]::new()

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }

            # SSE protocol parsing
            if ([string]::IsNullOrEmpty($line)) {
                # Empty line = event dispatch
                if ($eventData.Count -gt 0) {
                    if ($OnEvent) {
                        & $OnEvent $eventData
                    }
                    $eventData = @{}
                }
            } elseif ($line.StartsWith("data: ")) {
                $data = $line.Substring(6)
                if (-not $eventData["data"]) { $eventData["data"] = "" }
                $eventData["data"] += $data
            } elseif ($line.StartsWith("event: ")) {
                $eventData["event"] = $line.Substring(7)
            } elseif ($line.StartsWith("id: ")) {
                $eventData["id"] = $line.Substring(4)
            } elseif ($line.StartsWith("retry: ")) {
                $eventData["retry"] = $line.Substring(7)
            }
            # Comments (starting with :) are ignored
        }

        $reader.Close()
    } catch {
        if ($OnError) { & $OnError $_ }
    } finally {
        $client.Dispose()
    }
}

# ============================================================================
#  API Client Functions
#  Port of bashagt Section 6 (lines 6393-6691)
# ============================================================================

function Build-ApiRequestBody {
    <#
    .SYNOPSIS
    Construct API request body using model profile for vendor-specific formatting.
    Supports Anthropic, OpenAI, and DeepSeek protocols via ModelProfiles.
    #>
    param(
        [string]$UserMessage = "",
        [array]$Tools = @(),
        [int]$MaxTokens = 0,
        [int]$ThinkingBudget = 0,
        [string]$Model = "",
        [string]$SystemPrompt = "",
        [hashtable]$Profile = $null
    )

    # 参数为空时从全局配置回退
    if (-not $Model) { $Model = $global:PA_MODEL }
    if ($MaxTokens -le 0) { $MaxTokens = [int]$global:PA_MAX_TOKENS }
    if (-not $SystemPrompt) { $SystemPrompt = $global:PA_SYSTEM_PROMPT }

    # 获取模型配置（vendor-specific）— 支持显式传入 Profile 用于测试
    if ($null -eq $Profile) { $Profile = Get-ModelProfile }

    # 模型硬上限：千问等厂商 max_tokens 不能超过上限
    if ($Profile.force_max_tokens -and $MaxTokens -gt $Profile.force_max_tokens) {
        $MaxTokens = $Profile.force_max_tokens
    }

    # messages null guard
    $messages = if ($global:MESSAGES) { $global:MESSAGES } else { @() }

    # ── Merge ephemeral hook context buffer into last user message ──
    if ($global:_HOOK_CONTEXT_BUFFER -and $global:_HOOK_CONTEXT_BUFFER.Trim()) {
        $hookContent = $global:_HOOK_CONTEXT_BUFFER
        if ($messages.Count -gt 0) {
            $lastIdx = $messages.Count - 1
            $lastMsg = $messages[$lastIdx]
            if ($lastMsg.role -eq "user") {
                if ($lastMsg.content -is [array]) {
                    # Append as additional text block
                    $newContent = @($lastMsg.content) + @(@{ type = "text"; text = $hookContent })
                    $lastMsg.content = $newContent
                    $messages[$lastIdx] = $lastMsg
                } else {
                    # Convert string content to array, append hook content
                    $origContent = $lastMsg.content
                    if ($null -eq $origContent) { $origContent = "" }
                    $lastMsg.content = @(
                        @{ type = "text"; text = [string]$origContent }
                        @{ type = "text"; text = $hookContent }
                    )
                    $messages[$lastIdx] = $lastMsg
                }
            }
        }
    }

    # Build OpenAI-native messages array (system as first message)
    $openaiMessages = @()
    if ($SystemPrompt -and $SystemPrompt.Length -gt 0) {
        $openaiMessages += @{ role = "system"; content = $SystemPrompt }
    }
    $openaiMessages += @($messages)

    $body = @{
        model = $Model
        max_tokens = $MaxTokens
        messages = $openaiMessages
        stream = $false
    }

    # Convert Anthropic-format tool schemas to OpenAI format at runtime
    if ($Tools -and $Tools.Count -gt 0) {
        $openaiTools = @()
        foreach ($tool in $Tools) {
            $funcDef = @{ name = $tool.name }
            if ($tool.description) { $funcDef["description"] = $tool.description }
            # Handle both Anthropic input_schema and OpenAI parameters
            if ($tool.input_schema) { $funcDef["parameters"] = $tool.input_schema }
            elseif ($tool.parameters) { $funcDef["parameters"] = $tool.parameters }
            $openaiTools += @{ type = "function"; function = $funcDef }
        }
        $body["tools"] = $openaiTools
    }

    # ── Thinking / Reasoning ──
    if ($ThinkingBudget -gt 0 -or $Profile.thinking_mode -in @("deepseek","qwen","baidu","moonshot","minimax")) {
        switch ($Profile.thinking_mode) {
            "deepseek" {
                $body["thinking"] = @{ type = "enabled" }
                if ($Profile.reasoning_effort_default) { $body["reasoning_effort"] = $Profile.reasoning_effort_default }
            }
            "qwen" {
                $body["enable_thinking"] = $true
                if ($ThinkingBudget -gt 0) { $body["thinking_budget"] = $ThinkingBudget }
            }
            "baidu" {
                if ($ThinkingBudget -gt 0) { $body["thinking_budget"] = $ThinkingBudget }
            }
            "anthropic" {
                $budget = if ($ThinkingBudget -gt 0) { $ThinkingBudget } else { [int]$global:PA_THINKING_BUDGET }
                $body["thinking"] = @{ type = "enabled"; budget_tokens = $budget }
            }
            "moonshot" {
                $body["thinking"] = @{ type = "enabled" }
                if ($Profile.force_temperature) { $body["temperature"] = $Profile.force_temperature }
                if ($Profile.force_top_p) { $body["top_p"] = $Profile.force_top_p }
            }
            "minimax" {
                $body["thinking"] = @{ type = "adaptive" }
                $body["reasoning_split"] = $true
            }
        }
    }

    # ── Protocol conversion: OpenAI-native → Anthropic (only for anthropic protocol) ──
    if ($Profile.protocol -eq "anthropic") {
        $body = ConvertTo-AnthropicRequest $body
    }

    return ConvertTo-JsonSafe $body -Depth 20
}

# ============================================================================
#  ConvertTo-AnthropicRequest: OpenAI-native → Anthropic Messages API
#  (replaces old ConvertTo-OpenAIRequest / ConvertTo-OpenAIResponse)
# ============================================================================

function ConvertTo-AnthropicRequest {
    <#
    .SYNOPSIS
    Convert OpenAI-native internal request to Anthropic Messages API format.
    Only used when PA_PROTOCOL is "anthropic".
    #>
    param([hashtable]$OpenAIRequest)

    $anthropic = @{
        model = $OpenAIRequest.model
        max_tokens = $OpenAIRequest.max_tokens
        messages = @()
    }

    # System prompt as top-level field
    if ($OpenAIRequest.messages -and $OpenAIRequest.messages[0].role -eq "system") {
        $anthropic["system"] = $OpenAIRequest.messages[0].content
    }

    # Convert messages
    $pendingToolResults = @()
    foreach ($msg in $OpenAIRequest.messages) {
        if ($msg.role -eq "system") { continue }

        if ($msg.role -eq "user" -and $msg.content -is [string]) {
            $anthropic.messages += @{ role = "user"; content = $msg.content }

        } elseif ($msg.role -eq "tool") {
            $pendingToolResults += @{
                type = "tool_result"
                tool_use_id = $msg.tool_call_id
                content = $msg.content
            }

        } elseif ($msg.role -eq "assistant") {
            $contentBlocks = @()
            if ($msg.reasoning_content) {
                $contentBlocks += @{ type = "thinking"; thinking = $msg.reasoning_content }
            }
            if ($msg.content) {
                $contentBlocks += @{ type = "text"; text = $msg.content }
            }
            if ($msg.tool_calls) {
                foreach ($tc in $msg.tool_calls) {
                    $parsedArgs = $null
                    try { $parsedArgs = ConvertFrom-JsonSafe $tc.function.arguments } catch { $parsedArgs = @{ _raw = $tc.function.arguments } }
                    $contentBlocks += @{
                        type = "tool_use"
                        id = $tc.id
                        name = $tc.function.name
                        input = $parsedArgs
                    }
                }
            }
            $anthropic.messages += @{ role = "assistant"; content = $contentBlocks }

            if ($pendingToolResults.Count -gt 0) {
                $anthropic.messages += @{ role = "user"; content = $pendingToolResults }
                $pendingToolResults = @()
            }
        }
    }
    if ($pendingToolResults.Count -gt 0) {
        $anthropic.messages += @{ role = "user"; content = $pendingToolResults }
    }

    # Convert tools: function.parameters → input_schema
    if ($OpenAIRequest.tools) {
        $anthropic.tools = @()
        foreach ($tool in $OpenAIRequest.tools) {
            $t = @{ name = $tool.function.name }
            if ($tool.function.description) { $t["description"] = $tool.function.description }
            if ($tool.function.parameters) { $t["input_schema"] = $tool.function.parameters }
            $anthropic.tools += $t
        }
    }

    # Thinking params for Anthropic
    if ($OpenAIRequest.thinking) {
        $anthropic.thinking = @{
            type = "enabled"
            budget_tokens = [int]$global:PA_THINKING_BUDGET
        }
    }

    return $anthropic
}

function Invoke-ApiCall {
    <#
    .SYNOPSIS
    Non-streaming API call. Parses OpenAI response directly, returns content blocks.
    #>
    param(
        [string]$RequestBody,
        [string]$Url,
        [hashtable]$Headers
    )

    $result = Invoke-HttpRequest -Method "POST" -Url $Url -Body $RequestBody -Headers $Headers `
        -ConnectTimeout ([int]$global:PA_CONNECT_TIMEOUT) -TotalTimeout 300

    if ($result.ExitCode -ne 0) {
        # ExitCode 7 = ESC 中止, ExitCode 8 = Ctrl+C 中止
        $abortType = ""
        if ($result.ExitCode -eq 7) { $abortType = "ESC aborted" }
        elseif ($result.ExitCode -eq 8) { $abortType = "Ctrl+C aborted" }
        return @{
            Success = $false
            Error = "HTTP error: exit=$($result.ExitCode) status=$($result.StatusCode)"
            AbortType = $abortType
            ContentBlocks = @()
            StopReason = "error"
            InputTokens = 0
            OutputTokens = 0
        }
    }

    try {
        $resp = ConvertFrom-JsonSafe $result.Body
        if (-not $resp -or -not $resp.choices) {
            return @{
                Success = $false; Error = "Invalid response: no choices"; ContentBlocks = @()
                StopReason = "error"; InputTokens = 0; OutputTokens = 0
            }
        }

        $choice = $resp.choices[0]
        $message = $choice.message

        $content = @()
        if ($message.reasoning_content) {
            $content += @{ type = "thinking"; thinking = $message.reasoning_content }
        }
        if ($message.reasoning_details -and $message.reasoning_details -is [array]) {
            $rdText = ($message.reasoning_details | ForEach-Object { $_.text }) -join ""
            if ($rdText) { $content += @{ type = "thinking"; thinking = $rdText } }
        }
        if ($message.content) {
            $content += @{ type = "text"; text = $message.content }
        }
        if ($message.tool_calls) {
            foreach ($tc in $message.tool_calls) {
                $parsedArgs = $null
                try { $parsedArgs = ConvertFrom-JsonSafe $tc.function.arguments } catch { $parsedArgs = @{ _raw = $tc.function.arguments } }
                if ($parsedArgs -is [PSCustomObject]) { $ht = @{}; $parsedArgs.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $parsedArgs = $ht }
                $content += @{ type = "tool_call"; id = $tc.id; name = $tc.function.name; arguments = $parsedArgs }
            }
        }

        $stopReason = switch ($choice.finish_reason) {
            "tool_calls" { "tool_use" }
            "stop"       { "end_turn" }
            "length"     { "max_tokens" }
            default      { "end_turn" }
        }

        $usage = @{ input_tokens = 0; output_tokens = 0 }
        if ($resp.usage) {
            $usage = @{ input_tokens = [int]$resp.usage.prompt_tokens; output_tokens = [int]$resp.usage.completion_tokens }
        }

        return @{
            Success = $true
            ContentBlocks = $content
            StopReason = $stopReason
            InputTokens = $usage.input_tokens
            OutputTokens = $usage.output_tokens
        }
    } catch {
        return @{
            Success = $false
            Error = "JSON parse error: $_"
            ContentBlocks = @()
            StopReason = "error"
            InputTokens = 0
            OutputTokens = 0
        }
    }
}

function Get-ApiHeaders {
    <# Build authorization headers for API calls using model profile #>
    $profile = Get-ModelProfile

    $headers = @{}
    # Content-Type 由 Invoke-HttpRequest 的 -ContentType 参数统一设置
    # 不在 headers 中设置，避免 double Content-Type header

    # Anthropic 需要 anthropic-version header
    if ($profile -and $profile.protocol -eq "anthropic") {
        $headers["anthropic-version"] = "2023-06-01"
    }

    $apiKey = $global:PA_API_KEY

    # 优先级: 显式 PA_AUTH_HEADER > model profile > 默认 x-api-key
    if ($global:PA_AUTH_HEADER) {
        $authHeader = $global:PA_AUTH_HEADER
    } elseif ($profile -and $profile.auth_header) {
        $authHeader = $profile.auth_header
    } else {
        $authHeader = "x-api-key"
    }

    # 优先级: 显式 PA_AUTH_PREFIX > model profile > 空字符串
    if ($global:PA_AUTH_PREFIX) {
        $authPrefix = $global:PA_AUTH_PREFIX
    } elseif ($profile -and $profile.auth_prefix) {
        $authPrefix = $profile.auth_prefix
    } else {
        $authPrefix = ""
    }

    $headers[$authHeader] = "$authPrefix$apiKey"
    return $headers
}


# ============================================================================
#  Inlined: Tools.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Tools.ps1
#  Section 8/9/10: Tool Definitions, Implementations, and Dispatcher
#  PowerShell 5.1 port of bashagt Section 8-10 (lines 11255-12147)
# ============================================================================

# ============================================================================
#  Section 8: Tool Schema Definitions
#  (Bash heredoc variables -> PS hashtables)
# ============================================================================

function Get-ToolSchemas {
    <#
    .SYNOPSIS
    Return all built-in tool schemas as an array of hashtables.
    Port of bashagt build_tools_json() (L11387).
    #>

    $tools = @(
        # ── File Operations ──
        @{
            name = "read_file"
            description = "Read file contents. Supports: .xlsx/.xls (via ImportExcel, returns tabular text), .docx (extracts paragraphs), .csv (plain text), and all text files. Binary files return size info."
            input_schema = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "File path to read" }
                    offset = @{ type = "integer"; description = "1-based start line (default 1)" }
                    limit = @{ type = "integer"; description = "Max lines to return (default 2000)" }
                }
                required = @("path")
            }
        }
        @{
            name = "write_file"
            description = "Create a NEW file. REFUSES to overwrite existing files — use edit_file for modifications."
            input_schema = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "File path to create" }
                    content = @{ type = "string"; description = "File content" }
                }
                required = @("path", "content")
            }
        }
        @{
            name = "edit_file"
            description = "Edit existing file by replacing exact old_string with new_string. Shows diff preview. old_string must match BYTE-FOR-BYTE."
            input_schema = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "File path to edit" }
                    old_string = @{ type = "string"; description = "Exact text to find" }
                    new_string = @{ type = "string"; description = "Replacement text" }
                }
                required = @("path", "old_string", "new_string")
            }
        }
        @{
            name = "delete_file"
            description = "Delete file or directory. Traces content for undo recovery. Requires recursive=true for directories."
            input_schema = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "Path to delete" }
                    recursive = @{ type = "boolean"; description = "Required for directory deletion" }
                }
                required = @("path")
            }
        }
        @{
            name = "list_files"
            description = "List directory contents with file metadata."
            input_schema = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "Directory path (default: .)" }
                    recursive = @{ type = "boolean"; description = "Recurse into subdirectories" }
                }
                required = @()
            }
        }

        # ── Command Execution ──
        @{
            name = "powershell"
            description = "Execute a PowerShell command. Last resort — use built-in tools first. ALWAYS state the command before executing."
            input_schema = @{
                type = "object"
                properties = @{
                    command = @{ type = "string"; description = "PowerShell command to execute" }
                    timeout = @{ type = "integer"; description = "Timeout in seconds (default 300)" }
                    background = @{ type = "boolean"; description = "Run in background" }
                }
                required = @("command")
            }
        }

        # ── Excel Processing ──
        @{
            name = "process_excel"
            description = "Execute a PowerShell script with ImportExcel pre-loaded. Use for xlsx data processing (filter, transform, aggregate, export). The script runs in a dedicated PowerShell session with Import-Module ImportExcel already executed."
            input_schema = @{
                type = "object"
                properties = @{
                    script = @{ type = "string"; description = 'PowerShell script to execute. Use Import-Excel/Export-Excel cmdlets. The module is pre-loaded. Example: $d = Import-Excel "in.xlsx"; $d | Where-Object {$_.Amount -gt 100} | Export-Excel "out.xlsx"' }
                    timeout = @{ type = "integer"; description = "Timeout in seconds (default 120)" }
                }
                required = @("script")
            }
        }

        # ── Web Search ──
        @{
            name = "web_search"
            description = "Search the web using configured search engine (Bing or Baidu)."
            input_schema = @{
                type = "object"
                properties = @{
                    query = @{ type = "string"; description = "Search query" }
                    engine = @{ type = "string"; description = "Override default engine (bing/baidu)" }
                }
                required = @("query")
            }
        }

        # ── Task Management ──
        @{
            name = "task_create"
            description = "Create a single TODO task."
            input_schema = @{
                type = "object"
                properties = @{
                    title = @{ type = "string"; description = "Task title" }
                    description = @{ type = "string"; description = "Task description" }
                }
                required = @("title")
            }
        }
        @{
            name = "make_todos"
            description = "Extract TODO items from a plan document (runs plan_extractor internally)."
            input_schema = @{
                type = "object"
                properties = @{
                    plan_text = @{ type = "string"; description = "Plan document with STEPS section" }
                }
                required = @("plan_text")
            }
        }
        @{
            name = "task_update"
            description = "Update task status (pending/in_progress/completed/failed)."
            input_schema = @{
                type = "object"
                properties = @{
                    id = @{ type = "string"; description = "Task ID" }
                    status = @{ type = "string"; description = "New status" }
                }
                required = @("id", "status")
            }
        }
        @{
            name = "task_list"
            description = "List all TODO tasks with IDs and statuses."
            input_schema = @{
                type = "object"
                properties = @{}
                required = @()
            }
        }

        # ── Agent System ──
        @{
            name = "agent"
            description = "Delegate work to a specialized sub-agent."
            input_schema = @{
                type = "object"
                properties = @{
                    name = @{ type = "string"; description = "Agent name" }
                    prompt = @{ type = "string"; description = "Task description for agent" }
                    async = @{ type = "boolean"; description = "Run asynchronously (returns job_id)" }
                }
                required = @("name", "prompt")
            }
        }
        @{
            name = "agent_status"
            description = "Query agent status."
            input_schema = @{
                type = "object"
                properties = @{
                    name = @{ type = "string"; description = "Agent name" }
                }
                required = @("name")
            }
        }
        @{
            name = "agent_batch"
            description = "Execute up to 4 sub-agents in parallel."
            input_schema = @{
                type = "object"
                properties = @{
                    tasks = @{
                        type = "array"
                        items = @{
                            type = "object"
                            properties = @{
                                agent = @{ type = "string" }
                                prompt = @{ type = "string" }
                            }
                        }
                        description = "Array of {agent, prompt} objects"
                    }
                }
                required = @("tasks")
            }
        }
        @{
            name = "send_message"
            description = "Send message to another agent."
            input_schema = @{
                type = "object"
                properties = @{
                    to = @{ type = "string"; description = "Recipient agent name" }
                    message = @{ type = "string"; description = "Message content" }
                }
                required = @("to", "message")
            }
        }
        @{
            name = "check_messages"
            description = "Check inbox for messages."
            input_schema = @{
                type = "object"
                properties = @{}
                required = @()
            }
        }

        # ── Async Job Management ──
        @{
            name = "job_poll"
            description = "Check async job status."
            input_schema = @{
                type = "object"
                properties = @{
                    job_id = @{ type = "string"; description = "Job ID from async agent call" }
                }
                required = @("job_id")
            }
        }
        @{
            name = "job_result"
            description = "Get result from completed async job."
            input_schema = @{
                type = "object"
                properties = @{
                    job_id = @{ type = "string"; description = "Job ID" }
                }
                required = @("job_id")
            }
        }
        @{
            name = "job_cancel"
            description = "Cancel an async job."
            input_schema = @{
                type = "object"
                properties = @{
                    job_id = @{ type = "string"; description = "Job ID" }
                }
                required = @("job_id")
            }
        }

        # ── Human Oversight ──
        @{
            name = "request"
            description = "Request human confirmation or choice. MUST be the ONLY tool_use in a turn."
            input_schema = @{
                type = "object"
                properties = @{
                    prompt = @{ type = "string"; description = "Question (max 80 chars)" }
                    options = @{
                        type = "array"
                        items = @{ type = "string" }
                        description = "2-9 selectable choices"
                    }
                    context = @{ type = "string"; description = "Additional context (max 120 chars)" }
                }
                required = @("prompt")
            }
        }

        # ── Skill & Agent Discovery ──
        @{
            name = "skill"
            description = "Invoke an active skill."
            input_schema = @{
                type = "object"
                properties = @{
                    name = @{ type = "string"; description = "Skill name" }
                    task = @{ type = "string"; description = "Task description" }
                }
                required = @("name", "task")
            }
        }
        @{
            name = "list_skills"
            description = "List all active skills."
            input_schema = @{
                type = "object"
                properties = @{}
                required = @()
            }
        }
        @{
            name = "list_agents"
            description = "List all available sub-agents."
            input_schema = @{
                type = "object"
                properties = @{}
                required = @()
            }
        }
        @{
            name = "list_mcp_tools"
            description = "List all available MCP tools."
            input_schema = @{
                type = "object"
                properties = @{}
                required = @()
            }
        }

        # ── Undo ──
        @{
            name = "undo"
            description = "LIFO frame undo. Triggers human approval before executing."
            input_schema = @{
                type = "object"
                properties = @{
                    steps = @{ type = "integer"; description = "Number of frames to undo (default 1)" }
                }
                required = @()
            }
        }

        # ── Web Request ──
        @{
            name = "web_request"
            description = "Fetch a URL and return its content. Supports GET/POST with custom headers."
            input_schema = @{
                type = "object"
                properties = @{
                    url     = @{ type = "string";  description = "The URL to fetch" }
                    method  = @{ type = "string";  description = "HTTP method (default GET)" }
                    headers = @{ type = "object";  description = "Optional request headers" }
                    body    = @{ type = "string";  description = "Optional request body (for POST/PUT)" }
                    timeout = @{ type = "integer"; description = "Timeout in seconds (default 30)" }
                }
                required = @("url")
            }
        }
    )

    return $tools
}

# ============================================================================
#  Section 9: Tool Implementations
# ============================================================================

function Invoke-ToolReadFile {
    param([hashtable]$Params)
    $path = $Params.path
    $offset = if ($Params.offset) { [int]$Params.offset } else { 1 }
    $limit = if ($Params.limit) { [int]$Params.limit } else { 2000 }

    if (-not (Test-Path $path)) {
        return @{ status = "error"; error = "File not found: $path" }
    }
    if ((Get-Item $path).PSIsContainer) {
        return @{ status = "error"; error = "Path is a directory: $path" }
    }

    try {
        $ext = [System.IO.Path]::GetExtension($path).ToLower()

        # ── xlsx / xls: ImportExcel（默认只返回前20行，避免模型死循环）──
        if ($ext -in @('.xlsx', '.xls')) {
            # xlsx 默认 20 行预览，除非用户显式指定 limit
            $xlsxLimit = if ($Params.limit) { [int]$Params.limit } else { 20 }
            try {
                Import-Module ImportExcel -ErrorAction Stop
                $allData = @(Import-Excel -Path $path)
                $totalRows = $allData.Count
                if ($totalRows -eq 0) {
                    return @{ status = "ok"; content = "[Excel file: empty, 0 rows]"; total_rows = 0 }
                }

                $props = @($allData[0].PSObject.Properties.Name)
                $startIdx = [Math]::Max(0, $offset - 1)
                $rowCount = [Math]::Min($xlsxLimit, $totalRows - $startIdx)
                $rows = $allData[$startIdx..($startIdx + $rowCount - 1)]

                $lines = @()
                $hdr = "[Excel: $totalRows rows x $($props.Count) columns"
                if ($startIdx -gt 0 -or $rowCount -lt $totalRows) {
                    $hdr += ", showing rows $($startIdx+1)-$($startIdx+$rowCount)"
                }
                $hdr += "]"
                $lines += $hdr
                $lines += ""

                # 表头
                $lines += ($props -join " | ")
                $sepParts = @()
                foreach ($p in $props) {
                    $w = [Math]::Max($p.Length, 8)
                    $sepParts += ("-" * $w)
                }
                $lines += ($sepParts -join "-+-")

                # 数据行
                foreach ($row in $rows) {
                    $vals = @()
                    foreach ($p in $props) {
                        $val = $row.$p
                        if ($null -eq $val) { $vals += "" } else { $vals += "$val" }
                    }
                    $lines += ($vals -join " | ")
                }
                if ($startIdx + $rowCount -lt $totalRows) {
                    $lines += "... ($($totalRows - $startIdx - $rowCount) more rows)"
                }

                return @{
                    status = "ok"
                    content = ($lines -join "`n")
                    total_rows = $totalRows
                    shown_range = "$($startIdx+1)-$($startIdx+$rowCount)"
                    columns = $props
                }
            } catch {
                # ImportExcel 不可用时回退到二进制信息
                $size = (Get-Item $path).Length
                return @{ status = "ok"; content = "[Excel file: $size bytes. ImportExcel module not available: $_]"; is_binary = $true }
            }
        }

        # ── docx: .NET Zip 提取段落 ──
        if ($ext -eq '.docx') {
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
                $docEntry = $zip.GetEntry("word/document.xml")
                if (-not $docEntry) {
                    $zip.Dispose()
                    return @{ status = "error"; error = "Invalid docx: no word/document.xml found" }
                }

                $stream = $docEntry.Open()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $xmlContent = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()
                $zip.Dispose()

                # 提取 w:p 段落中的 w:t 文本
                $xml = [xml]$xmlContent
                $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
                $paraNodes = $xml.SelectNodes("//w:p", $ns)
                $paragraphs = @()
                foreach ($para in $paraNodes) {
                    $tNodes = $para.SelectNodes(".//w:t", $ns)
                    $paraText = ""
                    foreach ($t in $tNodes) {
                        $paraText += $t.InnerText
                    }
                    $paragraphs += $paraText
                }

                $total = $paragraphs.Count
                $startIdx = [Math]::Max(0, $offset - 1)
                $rowCount = [Math]::Min($limit, $total - $startIdx)
                if ($rowCount -le 0) {
                    return @{ status = "ok"; content = "[Word document: $total paragraphs, no more content]"; total_paragraphs = $total }
                }
                $selected = $paragraphs[$startIdx..($startIdx + $rowCount - 1)]

                $numbered = @()
                $numbered += "[Word document: $total paragraphs]"
                $numbered += ""
                for ($i = 0; $i -lt $selected.Count; $i++) {
                    $lineNum = $startIdx + $i + 1
                    if ($selected[$i]) {
                        $numbered += "{0,6}: {1}" -f $lineNum, $selected[$i]
                    }
                }

                return @{
                    status = "ok"
                    content = ($numbered -join "`n")
                    total_paragraphs = $total
                    shown_range = "$($startIdx+1)-$($startIdx+$rowCount)"
                }
            } catch {
                $size = (Get-Item $path).Length
                return @{ status = "ok"; content = "[Word file: $size bytes. Docx extraction failed: $_]"; is_binary = $true }
            }
        }

        # ── csv: 纯文本快速路径 ──
        # csv 不是二进制，直接作为文本读取（无需二进制检测）

        # ── 其他文件: 二进制检测 ──
        if ($ext -notin @('.csv', '.txt', '.md', '.json', '.xml', '.yaml', '.yml', '.ini', '.cfg', '.log', '.ps1', '.psm1', '.sh', '.bat', '.cmd', '.py', '.js', '.ts', '.html', '.css', '.scss', '.less', '.sql', '.java', '.c', '.cpp', '.h', '.hpp', '.go', '.rs', '.rb', '.php', '.pl', '.r', '.m', '.swift', '.kt', '.scala', '.lua', '.vim', '.el', '.clj', '.hs', '.ml', '.fs', '.dart', '.groovy', '.toml', '.env', '.gitignore', '.dockerfile', '.makefile', '.cmake')) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $isBinary = $false
            for ($i = 0; $i -lt [Math]::Min($bytes.Length, 8192); $i++) {
                if ($bytes[$i] -eq 0) { $isBinary = $true; break }
            }
            if ($isBinary) {
                $size = (Get-Item $path).Length
                return @{ status = "ok"; content = "[binary file: $size bytes]"; is_binary = $true }
            }
        }

        # ── 文本文件通用读取 ──
        $lines = @(Get-Content $path -Encoding UTF8 -ErrorAction Stop)
        $total = $lines.Count
        $startIdx = [Math]::Max(0, $offset - 1)
        $rowCount = [Math]::Min($limit, $total - $startIdx)
        if ($rowCount -le 0 -or $total -eq 0) {
            return @{ status = "ok"; content = ""; total_lines = 0; shown_range = "0-0" }
        }
        $selected = $lines[$startIdx..($startIdx + $rowCount - 1)]

        # 行号格式
        $numbered = @()
        for ($i = 0; $i -lt $selected.Count; $i++) {
            $lineNum = $startIdx + $i + 1
            $numbered += "{0,6}: {1}" -f $lineNum, $selected[$i]
        }

        return @{
            status = "ok"
            content = ($numbered -join "`n")
            total_lines = $total
            shown_range = "$($startIdx+1)-$($startIdx+$rowCount)"
        }
    } catch {
        return @{ status = "error"; error = "Read failed: $_" }
    }
}

function Invoke-ToolWriteFile {
    param([hashtable]$Params)
    $path = $Params.path
    $content = $Params.content

    # Refuse to overwrite existing files
    if (Test-Path $path) {
        return @{ status = "error"; error = "File already exists: $path - use edit_file to modify" }
    }

    try {
        # Create parent directory if needed
        $parent = Split-Path $path -Parent
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        Set-Content -Path $path -Value $content -Encoding UTF8 -NoNewline

        # Record trace
        if ($global:PA_TRACE_ENABLED -eq "1") {
            Trace-Record -Path $path -Operation "create" -NewContent $content
        }

        return @{ status = "ok"; path = $path; bytes_written = $content.Length }
    } catch {
        return @{ status = "error"; error = "Write failed: $_" }
    }
}

function Invoke-ToolEditFile {
    param([hashtable]$Params)
    $path = $Params.path
    $oldString = $Params.old_string
    $newString = $Params.new_string

    if (-not (Test-Path $path)) {
        return @{ status = "error"; error = "File not found: $path" }
    }

    try {
        $content = Get-Content $path -Raw -Encoding UTF8

        # Exact match check
        if ($content.IndexOf($oldString) -lt 0) {
            # Provide debugging hints
            $oldLines = ($oldString -split "`n").Count
            return @{
                status = "error"
                error = "old_string not found in file. Ensure exact match (whitespace, line endings). Old string has $oldLines line(s)."
                hint = "Re-read the file with correct offset/limit to get the precise text"
            }
        }

        # Count matches
        $matches = ([regex]::Escape($oldString) -split '\r?\n').Count
        $matchCount = 0
        $temp = $content
        while ($temp.IndexOf($oldString) -ge 0) {
            $matchCount++
            $temp = $temp.Substring($temp.IndexOf($oldString) + $oldString.Length)
        }

        if ($matchCount -gt 1) {
            return @{
                status = "error"
                error = "old_string matched $matchCount times — provide more context for unique match"
            }
        }

        # Record trace before modifying
        if ($global:PA_TRACE_ENABLED -eq "1") {
            Trace-Record -Path $path -Operation "edit" -OldContent $content -NewContent ($content.Replace($oldString, $newString))
        }

        # Apply replacement
        $newContent = $content.Replace($oldString, $newString)
        Set-Content -Path $path -Value $newContent -Encoding UTF8 -NoNewline

        # Show diff
        $oldLines = ($oldString -split "`n").Count
        $newLines = ($newString -split "`n").Count
        return @{
            status = "ok"
            path = $path
            lines_changed = "$oldLines -> $newLines"
            diff_preview = "- $oldString`n+ $newString"
        }
    } catch {
        return @{ status = "error"; error = "Edit failed: $_" }
    }
}

function Invoke-ToolDeleteFile {
    param([hashtable]$Params)
    $path = $Params.path
    $recursive = [bool]$Params.recursive

    if (-not (Test-Path $path)) {
        return @{ status = "error"; error = "Path not found: $path" }
    }

    $item = Get-Item $path
    if ($item.PSIsContainer -and -not $recursive) {
        return @{ status = "error"; error = "Directory deletion requires recursive=true" }
    }

    try {
        # Record trace before deletion
        if ($global:PA_TRACE_ENABLED -eq "1") {
            if ($item.PSIsContainer) {
                $allFiles = Get-ChildItem $path -Recurse -File
                foreach ($f in $allFiles) {
                    Trace-Record -Path $f.FullName -Operation "delete" -OldContent (Get-Content $f.FullName -Raw -Encoding UTF8)
                }
            } else {
                Trace-Record -Path $path -Operation "delete" -OldContent (Get-Content $path -Raw -Encoding UTF8)
            }
        }

        Remove-Item $path -Recurse:$recursive -Force
        return @{ status = "ok"; path = $path; deleted = $true }
    } catch {
        return @{ status = "error"; error = "Delete failed: $_" }
    }
}

function Invoke-ToolListFiles {
    param([hashtable]$Params)
    $path = if ($Params.path) { $Params.path } else { "." }
    $recursive = [bool]$Params.recursive

    if (-not (Test-Path $path)) {
        return @{ status = "error"; error = "Path not found: $path" }
    }

    try {
        $items = if ($recursive) {
            Get-ChildItem $path -Recurse
        } else {
            Get-ChildItem $path
        }

        # 计算相对路径的基准目录
        $basePath = (Resolve-Path $path -ErrorAction SilentlyContinue).Path
        if (-not $basePath) { $basePath = $path }

        $result = @()
        foreach ($item in $items) {
            # 计算相对于查询路径的相对路径
            $relativePath = if ($recursive -and $item.FullName.StartsWith($basePath)) {
                $item.FullName.Substring($basePath.Length).TrimStart('\', '/')
            } else {
                $item.Name
            }

            $result += @{
                name = $item.Name
                path = $relativePath
                type = if ($item.PSIsContainer) { "dir" } else { "file" }
                size = if ($item.PSIsContainer) { $null } else { $item.Length }
                modified = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        return @{ status = "ok"; entries = $result; total = $result.Count }
    } catch {
        return @{ status = "error"; error = "List failed: $_" }
    }
}

function Invoke-ToolPowerShell {
    param([hashtable]$Params)
    $command = $Params.command
    $timeout = if ($Params.timeout) { [int]$Params.timeout } else { [int]$global:PA_CMD_TIMEOUT }
    $background = [bool]$Params.background

    try {
        if ($background) {
            $job = Start-Job -ScriptBlock { param($cmd) powershell.exe -NoProfile -Command "`$ProgressPreference = 'SilentlyContinue'; $cmd" } -ArgumentList $command
            return @{ status = "ok"; job_id = $job.Id; background = $true }
        }

        $progressSafeCmd = "`$ProgressPreference = 'SilentlyContinue'; $command"
        $output = powershell.exe -NoProfile -Command $progressSafeCmd 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        # Truncate output if too large
        if ($output.Length -gt 50000) {
            $output = $output.Substring(0, 50000) + "`n... [truncated, $($output.Length) total bytes]"
        }

        return @{
            status = if ($exitCode -eq 0) { "ok" } else { "error" }
            output = $output
            exit_code = $exitCode
        }
    } catch {
        return @{ status = "error"; error = "Execution failed: $_" }
    }
}

function Invoke-ToolProcessExcel {
    param([hashtable]$Params)
    $userScript = $Params.script
    $timeout = if ($Params.timeout) { [int]$Params.timeout } else { 120 }

    if (-not $userScript) {
        return @{ status = "error"; error = "No script provided" }
    }

    try {
        # 预加载 ImportExcel，执行用户脚本
        $wrappedScript = "`$ProgressPreference = 'SilentlyContinue'; Import-Module ImportExcel -ErrorAction Stop; $userScript"
        $output = powershell.exe -NoProfile -Command $wrappedScript 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        if ($output.Length -gt 50000) {
            $output = $output.Substring(0, 50000) + "`n... [truncated, $($output.Length) total bytes]"
        }

        return @{
            status = if ($exitCode -eq 0) { "ok" } else { "error" }
            output = $output
            exit_code = $exitCode
        }
    } catch {
        return @{ status = "error"; error = "ProcessExcel failed: $_" }
    }
}

function Invoke-ToolWebSearch {
    param([hashtable]$Params)
    $query = $Params.query
    $engine = if ($Params.engine) { $Params.engine } else { $global:PA_WEB_SEARCH_ENGINE }

    try {
        $encodedQuery = [Uri]::EscapeDataString($query)

        switch ($engine) {
            "bing" {
                $url = "https://cn.bing.com/search?q=$encodedQuery&cc=cn"
            }
            "baidu" {
                $url = "https://www.baidu.com/s?wd=$encodedQuery"
            }
            default {
                $url = "https://cn.bing.com/search?q=$encodedQuery&cc=cn"
            }
        }

        $result = Invoke-HttpRequest -Method "GET" -Url $url -TotalTimeout ([int]$global:PA_WEB_SEARCH_TIMEOUT)

        if ($result.ExitCode -ne 0) {
            return @{ status = "error"; error = "Search failed: HTTP error $($result.StatusCode)" }
        }

        if ($engine -eq "bing") {
            # Bing: 结构化提取搜索结果（标题+摘要+URL）
            $text = _Parse-BingResults -Html $result.Body
        } elseif ($engine -eq "baidu") {
            # Baidu: 结构化提取搜索结果
            $text = _Parse-BaiduResults -Html $result.Body
        } else {
            # 其他: 简单HTML转文本
            $text = $result.Body -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>'
            $text = $text -replace '\s+', ' '
        }

        if ($text.Length -gt 10000) {
            $text = $text.Substring(0, 10000) + "..."
        }

        return @{ status = "ok"; results = $text; engine = $engine }
    } catch {
        return @{ status = "error"; error = "Search failed: $_" }
    }
}

# Bing 搜索结果结构化提取
# 从 <ol id="b_results"> 中提取每条结果的标题、URL 和摘要
function _Parse-BingResults {
    param([string]$Html)

    # 提取 b_results 容器
    $bResults = [regex]::Match($Html, '<ol id="b_results"[^>]*>(.*?)</ol>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $bResults.Success) {
        # 降级：简单文本提取
        $fallback = $Html -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '\s+', ' '
        return $fallback
    }

    $content = $bResults.Groups[1].Value
    $liItems = [regex]::Matches($content, '<li\b[^>]*>(.*?)</li>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $liItems) {
        $item = $m.Groups[1].Value

        # 标题: <h2><a href="URL">TITLE</a></h2>
        $titleMatch = [regex]::Match($item, '<h2[^>]*>\s*<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $titleMatch.Success) { continue }

        $linkUrl = $titleMatch.Groups[1].Value
        $title = $titleMatch.Groups[2].Value -replace '<[^>]+>', ''

        # 摘要: <div class="b_caption..."><p>SNIPPET</p></div>
        $snippetMatch = [regex]::Match($item, '<div class="b_caption[^"]*"[^>]*>\s*<p[^>]*>(.*?)</p>',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $snippet = if ($snippetMatch.Success) {
            $snippetMatch.Groups[1].Value -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&ensp;', ' ' -replace '&#0183;', '·' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>'
        } else {
            ""
        }

        [void]$sb.AppendLine("[${title}](${linkUrl})")
        if ($snippet) { [void]$sb.AppendLine($snippet) }
        [void]$sb.AppendLine()
    }

    return $sb.ToString()
}

# Baidu 搜索结果结构化提取
# 从搜索结果页中提取每条结果的标题、URL 和摘要
function _Parse-BaiduResults {
    param([string]$Html)

    $sb = New-Object System.Text.StringBuilder

    # 百度搜索结果在 <div class="result c-container"> 或 <div class="c-container new-pmd">
    # 提取所有结果容器
    $resultMatches = [regex]::Matches($Html, '<div\s+class="[^"]*result[^"]*c-container[^"]*"[^>]*>(.*?)</div>\s*<div\s+class="c-container',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if ($resultMatches.Count -eq 0) {
        # 降级：尝试提取所有包含 <h3> 的结果块
        $resultMatches = [regex]::Matches($Html, '<h3\s+class="[^"]*t[^"]*"[^>]*>(.*?)</h3>',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        foreach ($m in $resultMatches) {
            $h3Content = $m.Groups[1].Value
            $linkMatch = [regex]::Match($h3Content, '<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
                [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($linkMatch.Success) {
                $linkUrl = $linkMatch.Groups[1].Value
                $title = $linkMatch.Groups[2].Value -replace '<[^>]+>', ''
                [void]$sb.AppendLine("[${title}](${linkUrl})")
                [void]$sb.AppendLine()
            }
        }
        if ($sb.Length -gt 0) { return $sb.ToString() }
        # 最终降级：纯文本
        $fallback = $Html -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '\s+', ' '
        return $fallback
    }

    foreach ($m in $resultMatches) {
        $item = $m.Groups[1].Value

        # 标题: <h3 class="t"><a href="URL">TITLE</a></h3>
        $titleMatch = [regex]::Match($item, '<h3[^>]*>\s*<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $titleMatch.Success) { continue }

        $linkUrl = $titleMatch.Groups[1].Value
        $title = $titleMatch.Groups[2].Value -replace '<[^>]+>', ''

        # 摘要: class="c-abstract" 或 class="content-right_8Zs40"
        $snippetMatch = [regex]::Match($item, 'class="[^"]*abstract[^"]*"[^>]*>(.*?)</',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $snippet = if ($snippetMatch.Success) {
            $snippetMatch.Groups[1].Value -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>'
        } else {
            ""
        }

        [void]$sb.AppendLine("[${title}](${linkUrl})")
        if ($snippet) { [void]$sb.AppendLine($snippet) }
        [void]$sb.AppendLine()
    }

    return $sb.ToString()
}

# ============================================================================
#  Section 10: Tool Dispatcher
# ============================================================================

function Invoke-ToolDispatch {
    <#
    .SYNOPSIS
    Central tool dispatcher — routes tool calls to implementations.
    Port of bashagt dispatch_tool() (L12029).
    #>
    param(
        [string]$ToolName,
        [string]$ToolId,
        $ToolInput
    )

    # Parse input if string
    $inputObj = $ToolInput
    if ($ToolInput -is [string]) {
        try {
            $inputObj = $ToolInput | ConvertFrom-Json
            # Convert PSCustomObject to hashtable
            $ht = @{}
            $inputObj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            $inputObj = $ht
        } catch {
            $inputObj = @{}
        }
    }
    if ($inputObj -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        $inputObj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        $inputObj = $ht
    }

    # Safe mode check
    if ($global:PA_SAFE_MODE -and $ToolName -in @("write_file", "edit_file", "delete_file", "powershell")) {
        $confirmed = Request-SafeConfirmation -Tool $ToolName -Input $inputObj
        if (-not $confirmed) {
            return @{
                type = "tool_result"
                tool_use_id = $ToolId
                content = @(@{ type = "text"; text = ('{"status":"denied","reason":"Safe mode: ' + $ToolName + ' was denied by user."}') })
            }
        }
    }

    # Route to implementation
    $result = switch ($ToolName) {
        "read_file"   { Invoke-ToolReadFile $inputObj }
        "write_file"  { Invoke-ToolWriteFile $inputObj }
        "edit_file"   { Invoke-ToolEditFile $inputObj }
        "delete_file" { Invoke-ToolDeleteFile $inputObj }
        "list_files"  { Invoke-ToolListFiles $inputObj }
        "powershell"  { Invoke-ToolPowerShell $inputObj }
        "bash"        { Invoke-ToolPowerShell $inputObj }
        "process_excel" { Invoke-ToolProcessExcel $inputObj }
        "web_search"  { Invoke-ToolWebSearch $inputObj }
        "task_create" { Invoke-ToolTaskCreate $inputObj }
        "make_todos"  { Invoke-ToolMakeTodos $inputObj }
        "task_update" { Invoke-ToolTaskUpdate $inputObj }
        "task_list"   { Invoke-ToolTaskList $inputObj }
        "agent"       { Invoke-ToolAgent $inputObj }
        "agent_status"{ Invoke-ToolAgentStatus $inputObj }
        "agent_batch" { Invoke-ToolAgentBatch $inputObj }
        "send_message"{ Invoke-ToolSendMessage $inputObj }
        "check_messages" { Invoke-ToolCheckMessages $inputObj }
        "job_poll"    { Invoke-ToolJobPoll $inputObj }
        "job_result"  { Invoke-ToolJobResult $inputObj }
        "job_cancel"  { Invoke-ToolJobCancel $inputObj }
        "request"     { Invoke-ToolRequest $inputObj }
        "skill"       { Invoke-ToolSkill $inputObj }
        "list_skills" { Invoke-ToolListSkills $inputObj }
        "list_agents" { Invoke-ToolListAgents $inputObj }
        "list_mcp_tools" { Invoke-ToolListMcpTools $inputObj }
        "undo"        { Invoke-ToolUndo $inputObj }
        "web_request" { Invoke-ToolWebRequest $inputObj }
        default {
            # Check MCP tools
            if ($ToolName -match "^mcp__(.+)__(.+)$") {
                $server = $Matches[1]
                $mcpTool = $Matches[2]
                $mcpResult = Invoke-McpTool -Server $server -Tool $mcpTool -Input $inputObj
                $mcpResult
            } else {
                @{ status = "error"; error = "Unknown tool: $ToolName" }
            }
        }
    }

    # Format result as Anthropic-style tool_result (仅当 ToolId 存在时包装)
    if ($ToolId) {
        $resultJson = ConvertTo-JsonSafe $result -Depth 10
        return @{
            type = "tool_result"
            tool_use_id = $ToolId
            content = @(@{ type = "text"; text = $resultJson })
        }
    }
    return $result
}

# ============================================================================
#  Section 10a: Human Oversight / Safe Mode
# ============================================================================

$global:PA_SAFE_MODE = $false

function Request-SafeConfirmation {
    <# TUI confirmation for safe mode #>
    param([string]$Tool, [hashtable]$Params)

    # Headless/test mode: auto-deny destructive operations
    if ($global:PA_HEADLESS) {
        Write-Log "WARN: Safe mode auto-denied $Tool (headless mode)"
        return $false
    }

    Write-Host ""
    Write-Host "${global:BOLD}${global:YELLOW}[Safe Mode] ${Tool}${global:RESET}"
    if ($Tool -eq "powershell" -or $Tool -eq "bash") {
        Write-Host "  Command: $($Params.command)" -ForegroundColor Gray
    } elseif ($Tool -in @("write_file", "edit_file")) {
        Write-Host "  Path: $($Params.path)" -ForegroundColor Gray
    } elseif ($Tool -eq "delete_file") {
        Write-Host "  Path: $($Params.path)" -ForegroundColor Gray
    }

    $response = Read-Host "Allow? [y/N]"
    return $response -match '^[Yy]'
}

function Invoke-ToolRequest {
    <# Human oversight request tool (port of bashagt tool_request §10a) #>
    param([hashtable]$Params)

    $prompt = $Params.prompt
    $options = $Params.options
    $context = $Params.context

    Write-Host ""
    Write-Host "${global:BOLD}${global:CYAN}[Request] $prompt${global:RESET}"
    if ($context) {
        Write-Host "${global:DIM}  $context${global:RESET}"
    }

    if ($options -and $options.Count -gt 0) {
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host "  [$($i+1)] $($options[$i])" -ForegroundColor White
        }
        $response = Read-Host "Choose [1-$($options.Count)] or type response"
        if ($response -match '^\d+$' -and [int]$response -ge 1 -and [int]$response -le $options.Count) {
            return @{ status = "ok"; choice = $options[[int]$response - 1]; index = [int]$response - 1 }
        }
    } else {
        $response = Read-Host "Response"
    }

    return @{ status = "ok"; response = $response }
}

# ── Stub implementations for agent tools (full impl in AgentSystem.ps1) ──
# These are placeholders; the real implementations are in AgentSystem.ps1
# and loaded after this file.

function Invoke-ToolAgent { param([hashtable]$I); return @{ status = "error"; error = "Agent system not yet loaded" } }
function Invoke-ToolAgentStatus { param([hashtable]$I); return @{ status = "ok"; agents = @() } }
function Invoke-ToolAgentBatch { param([hashtable]$I); return @{ status = "error"; error = "Agent system not yet loaded" } }
function Invoke-ToolSendMessage { param([hashtable]$I); return @{ status = "ok" } }
function Invoke-ToolCheckMessages { param([hashtable]$I); return @{ status = "ok"; messages = @() } }
function Invoke-ToolJobPoll { param([hashtable]$I); return @{ status = "ok"; job_status = "unknown" } }
function Invoke-ToolJobResult { param([hashtable]$I); return @{ status = "error"; error = "Job not found" } }
function Invoke-ToolJobCancel { param([hashtable]$I); return @{ status = "ok" } }
function Invoke-ToolSkill { param([hashtable]$I); return @{ status = "error"; error = "Skill not found" } }
function Invoke-ToolListSkills { return @{ status = "ok"; skills = @() } }
function Invoke-ToolListAgents { return @{ status = "ok"; agents = @() } }
function Invoke-ToolListMcpTools { return @{ status = "ok"; tools = @() } }
function Invoke-ToolUndo { param([hashtable]$I); return @{ status = "error"; error = "Undo not available" } }

# ── Web Request Tool (full implementation) ──
function Invoke-ToolWebRequest {
    param([hashtable]$Params)
    $url     = $Params.url
    $method  = if ($Params.method) { $Params.method.ToUpper() } else { "GET" }
    $headers = $Params.headers
    $body    = $Params.body
    $timeout = if ($Params.timeout) { [int]$Params.timeout } else { 30 }

    if (-not $url) {
        return @{ status = "error"; error = "url is required" }
    }

    try {
        $irmParams = @{
            Uri     = $url
            Method  = $method
            TimeoutSec = $timeout
            UseBasicParsing = $true
        }
        if ($headers) {
            $irmParams.Headers = $headers
        }
        if ($body -and $method -in @("POST", "PUT", "PATCH")) {
            $irmParams.Body = $body
            if (-not $headers -or -not $headers."Content-Type") {
                $irmParams.ContentType = "application/json"
            }
        }

        $response = Invoke-WebRequest @irmParams
        $content = $response.Content
        if ($content.Length -gt 100000) {
            $content = $content.Substring(0, 100000) + "`n... [truncated, total $($response.Content.Length) bytes]"
        }

        return @{
            status      = "ok"
            status_code = $response.StatusCode
            headers     = [ordered]@{}
            body        = $content
        }
    } catch {
        $statusCode = "unknown"
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return @{
            status      = "error"
            status_code = $statusCode
            error       = $_.Exception.Message
        }
    }
}


# ============================================================================
#  Inlined: Trace.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Trace.ps1
#  Section 7f: Content-addressable file modification tracking with undo
#  PowerShell 5.1 port of bashagt Section 7f (lines 10707-11253)
#
#  Key Bash dependencies replaced:
#  - sha256sum -> [System.Security.Cryptography.SHA256]
#  - mkdir-based object storage -> .NET file I/O
#  - LIFO frame stack -> ArrayList
# ============================================================================

# ── Trace state ──
$global:TRACE_DIR = ""
$global:TRACE_DIR_FRAMES = ""
$global:TRACE_DIR_OBJECTS = ""
$global:TRACE_DIR_SNAPS = ""
$global:TRACE_HEAD = 0
$global:TRACE_HEAD_FILE = ""

function Initialize-Trace {
    $baseDir = if ($global:PA_PROJECT_DIR) { $global:PA_PROJECT_DIR } else { "." }
    $global:TRACE_DIR = Join-Path $baseDir ".poweragent\trace"
    $global:TRACE_DIR_FRAMES = Join-Path $global:TRACE_DIR "frames"
    $global:TRACE_DIR_OBJECTS = Join-Path $global:TRACE_DIR "objects"
    $global:TRACE_DIR_SNAPS = Join-Path $global:TRACE_DIR "snaps"
    $global:TRACE_HEAD_FILE = Join-Path $global:TRACE_DIR "HEAD"

    foreach ($dir in @($global:TRACE_DIR, $global:TRACE_DIR_FRAMES, $global:TRACE_DIR_OBJECTS, $global:TRACE_DIR_SNAPS)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Read HEAD
    if (Test-Path $global:TRACE_HEAD_FILE) {
        $global:TRACE_HEAD = [int](Get-Content $global:TRACE_HEAD_FILE -Raw)
    } else {
        $global:TRACE_HEAD = 0
        Set-Content $global:TRACE_HEAD_FILE "0" -NoNewline
    }
}

function Get-TraceHash {
    <# SHA256 of content, git-style #>
    param([string]$Content)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $hash = $sha256.ComputeHash($bytes)
    $sha256.Dispose()
    $hex = [BitConverter]::ToString($hash) -replace '-', ''
    return $hex.ToLowerInvariant()
}

function Get-TraceObjectPath {
    <# Objects stored as objects/XX/YYYY... (2-char prefix dir) #>
    param([string]$Hash)
    $prefix = $Hash.Substring(0, 2)
    $rest = $Hash.Substring(2)
    $dir = Join-Path $global:TRACE_DIR_OBJECTS $prefix
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir $rest
}

function Write-TraceObject {
    <# Store content, return hash #>
    param([string]$Content)
    $hash = Get-TraceHash $Content
    $path = Get-TraceObjectPath $hash
    if (-not (Test-Path $path)) {
        Set-Content $path $Content -NoNewline -Encoding UTF8
    }
    return $hash
}

function Read-TraceObject {
    <# Read object by hash #>
    param([string]$Hash)
    $path = Get-TraceObjectPath $Hash
    if (Test-Path $path) {
        return Get-Content $path -Raw -Encoding UTF8
    }
    return $null
}

function Trace-Record {
    <#
    .SYNOPSIS
    Record a file modification for trace/undo.
    Mirrors bashagt trace_record() (L10814).
    #>
    param(
        [string]$Path,
        [string]$Operation,
        [string]$OldContent = "",
        [string]$NewContent = ""
    )

    if ($global:PA_TRACE_ENABLED -ne "1") { return }

    # Store content objects
    $oldHash = if ($OldContent) { Write-TraceObject $OldContent } else { "" }
    $newHash = if ($NewContent) { Write-TraceObject $NewContent } else { "" }

    # Get relative path
    $relPath = $Path
    try {
        $relPath = Resolve-Path $Path -Relative -ErrorAction Stop
    } catch {
        # 路径不存在时保持原值
    }

    # Write frame
    $frameData = @{
        path = $relPath
        operation = $Operation
        old_hash = $oldHash
        new_hash = $newHash
        timestamp = Get-TimestampMs
    } | ConvertTo-Json -Compress

    # 确保帧目录存在
    if (-not (Test-Path $global:TRACE_DIR_FRAMES)) {
        New-Item -ItemType Directory -Path $global:TRACE_DIR_FRAMES -Force | Out-Null
    }

    $frameFile = Join-Path $global:TRACE_DIR_FRAMES "$($global:TRACE_HEAD).json"
    Set-Content $frameFile $frameData -NoNewline -Encoding UTF8

    # Advance HEAD
    $global:TRACE_HEAD++
    Set-Content $global:TRACE_HEAD_FILE "$($global:TRACE_HEAD)" -NoNewline

    # Snapshot check
    $snapshotInterval = [int]$global:PA_TRACE_SNAPSHOT_INTERVAL
    if ($snapshotInterval -gt 0 -and ($global:TRACE_HEAD % $snapshotInterval) -eq 0) {
        Trace-Snapshot
    }

    # Prune check
    $maxFrames = [int]$global:PA_TRACE_MAX_FRAMES
    if ($global:TRACE_HEAD -gt $maxFrames) {
        Trace-Prune
    }
}

function Trace-Undo {
    <#
    .SYNOPSIS
    LIFO undo: pop the most recent frame and revert.
    Requires human approval via request tool.
    #>
    param([int]$Steps = 1)

    if ($global:TRACE_HEAD -eq 0) {
        return @{ status = "error"; error = "No frames to undo" }
    }

    $undone = @()
    for ($s = 0; $s -lt $Steps; $s++) {
        if ($global:TRACE_HEAD -le 0) { break }

        $global:TRACE_HEAD--
        $frameFile = Join-Path $global:TRACE_DIR_FRAMES "$($global:TRACE_HEAD).json"
        if (-not (Test-Path $frameFile)) { break }

        $frame = Get-Content $frameFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $path = $frame.path

        if ($frame.operation -eq "delete") {
            # Restore deleted file
            $content = Read-TraceObject $frame.old_hash
            if ($content -ne $null) {
                Set-Content $path $content -NoNewline -Encoding UTF8
                $undone += @{ frame = $global:TRACE_HEAD; path = $path; action = "restored" }
            }
        } elseif ($frame.operation -eq "create") {
            # Remove created file
            if (Test-Path $path) {
                Remove-Item $path -Force
                $undone += @{ frame = $global:TRACE_HEAD; path = $path; action = "removed" }
            }
        } elseif ($frame.operation -eq "edit") {
            # Revert to old content
            $content = Read-TraceObject $frame.old_hash
            if ($content -ne $null) {
                Set-Content $path $content -NoNewline -Encoding UTF8
                $undone += @{ frame = $global:TRACE_HEAD; path = $path; action = "reverted" }
            }
        }

        # Remove frame file
        Remove-Item $frameFile -Force -ErrorAction SilentlyContinue
    }

    # Update HEAD (ensure directory exists before writing)
    $headDir = Split-Path $global:TRACE_HEAD_FILE -Parent
    if ($headDir -and -not (Test-Path $headDir)) {
        New-Item -ItemType Directory -Path $headDir -Force | Out-Null
    }
    Set-Content $global:TRACE_HEAD_FILE "$($global:TRACE_HEAD)" -NoNewline

    return @{ status = "ok"; undone = $undone; new_head = $global:TRACE_HEAD }
}

function Trace-Log {
    <# Show recent trace frames #>
    param(
        [string]$Message = "",
        [int]$Count = 20
    )

    $frames = @()
    $start = [Math]::Max(0, $global:TRACE_HEAD - $Count)
    for ($i = $start; $i -lt $global:TRACE_HEAD; $i++) {
        $frameFile = Join-Path $global:TRACE_DIR_FRAMES "$i.json"
        if (Test-Path $frameFile) {
            $frame = Get-Content $frameFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $frames += @{
                id = $i
                path = $frame.path
                operation = $frame.operation
                timestamp = $frame.timestamp
            }
        }
    }
    return $frames
}

function Trace-Snapshot {
    <# Periodic full-state snapshot #>
    $snapFile = Join-Path $global:TRACE_DIR_SNAPS "$($global:TRACE_HEAD).json"
    $snapData = @{
        head = $global:TRACE_HEAD
        timestamp = Get-TimestampMs
    } | ConvertTo-Json -Compress
    Set-Content $snapFile $snapData -NoNewline -Encoding UTF8
}

function Trace-Prune {
    <# Keep last N frames, compact old objects #>
    $keep = [int]$global:PA_TRACE_PRUNE_KEEP
    if ($global:TRACE_HEAD -le $keep) { return }

    $cutoff = $global:TRACE_HEAD - $keep
    for ($i = 0; $i -lt $cutoff; $i++) {
        $frameFile = Join-Path $global:TRACE_DIR_FRAMES "$i.json"
        if (Test-Path $frameFile) {
            Remove-Item $frameFile -Force -ErrorAction SilentlyContinue
        }
    }
}


# ============================================================================
#  Inlined: Compression.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Compression.ps1
#  Section 5: Context Compression (3 levels)
#  Section 5b: Prompt Engineering (7-layer assembly)
#  PowerShell 5.1 port of bashagt Section 5-5b (lines 5196-6391)
#
#  Key Bash->PS differences:
#  - All JSON operations use pure PowerShell (ConvertFrom-Json / ConvertTo-Json)
#  - printf -v timestamp -> Get-TimestampMs / .NET DateTime
#  - File-based offload -> same concept, Set-Content instead of printf >
# ============================================================================

# ── Prompt cache state ──
# NOTE: $global:_CC and $global:_CACHE_PROBE are initialized with full state
# in the AgentLoop section below. These empty inits are commented out to avoid
# overwriting the full state when this file is dot-sourced.
# $global:_CC = @{}
# $global:_CACHE_PROBE = @{}

function Get-CompHash {
    param([string]$Content)
    $h = Get-ContentHash $Content
    return $h.Substring(0, [Math]::Min(8, $h.Length))
}

# ============================================================================
#  L0: Disk offloading + redundancy elimination
# ============================================================================

function Compress-Offload {
    <# Port of bashagt _compress_offload() #>
    $sizeBefore = (Get-MessagesJson).Length
    $changed = $false

    $offloadDir = ".poweragent\offload"
    if (-not (Test-Path $offloadDir)) {
        New-Item -ItemType Directory -Path $offloadDir -Force | Out-Null
    }

    # Step 1: Redundancy elimination — collapse thinking-only assistant turns
    for ($mi = 0; $mi -lt $global:MESSAGES.Count; $mi++) {
        $msg = $global:MESSAGES[$mi]
        if ($msg.role -eq "assistant" -and $msg.content -is [array]) {
            $hasVisible = $false
            $hasThinking = $false
            foreach ($block in $msg.content) {
                if ($block.type -eq "text" -or $block.type -eq "tool_use") { $hasVisible = $true }
                if ($block.type -eq "thinking") { $hasThinking = $true }
            }
            if ($hasThinking -and -not $hasVisible) {
                $global:MESSAGES[$mi].content = @(@{ type = "text"; text = "[thinking]" })
                $changed = $true
            }
        }
    }

    # Step 2: Disk offloading for large text blocks
    # Find content blocks > 4000 chars and offload to disk
    for ($mi = 0; $mi -lt $global:MESSAGES.Count; $mi++) {
        $msg = $global:MESSAGES[$mi]
        if ($msg.content -is [array]) {
            for ($bi = 0; $bi -lt $msg.content.Count; $bi++) {
                $block = $msg.content[$bi]
                if ($block.type -eq "text" -and $block.text -and $block.text.Length -gt 4000) {
                    $txt = $block.text
                    if ($txt -match "^data:image/.*;base64,") {
                        $marker = "[base64 image: $([Math]::Floor($txt.Length/1024))KB]"
                        $global:MESSAGES[$mi].content[$bi].text = $marker
                    } else {
                        $hash = Get-CompHash $txt
                        $offloadPath = ".poweragent\offload\msg${mi}_${hash}.txt"
                        Set-Content $offloadPath $txt -NoNewline -Encoding UTF8
                        $truncate = if ($txt.Length -gt 8000) { $txt.Substring(0, 8000) } else { $txt }
                        $sizeKB = [Math]::Floor($txt.Length / 1024)
                        $marker = " [...offloaded->$offloadPath ($sizeKB KB)]"
                        $global:MESSAGES[$mi].content[$bi].text = $truncate + $marker
                    }
                    $changed = $true
                }
            }
        }
    }

    if ($changed) {
        $sizeAfter = (Get-MessagesJson).Length
        Write-Log "L0 offload: ${sizeBefore} -> ${sizeAfter} bytes"
    }
}

# ============================================================================
#  L1: Tool result eviction
# ============================================================================

function Compress-ToolEvict {
    <# Port of bashagt _compress_tool_evict() #>
    # Simplified: evict old tool_result content, keep structure
    $totalRounds = ($global:MESSAGES | Where-Object { $_.role -eq "user" }).Count
    if ($totalRounds -lt 5) { return }

    $changed = $false
    for ($mi = 0; $mi -lt $global:MESSAGES.Count; $mi++) {
        $msg = $global:MESSAGES[$mi]
        if ($msg.role -eq "user" -and $msg.content -is [array]) {
            for ($bi = 0; $bi -lt $msg.content.Count; $bi++) {
                $block = $msg.content[$bi]
                if ($block.type -eq "tool_result") {
                    $toolName = ""
                    # Find corresponding tool_use
                    for ($km = $mi - 1; $km -ge 0; $km--) {
                        $pmsg = $global:MESSAGES[$km]
                        if ($pmsg.role -eq "assistant" -and $pmsg.content -is [array]) {
                            foreach ($pblk in $pmsg.content) {
                                if ($pblk.type -eq "tool_use" -and $pblk.id -eq $block.tool_use_id) {
                                    $toolName = $pblk.name
                                    break
                                }
                            }
                        }
                        if ($toolName) { break }
                    }

                    # Skip agent results (high value)
                    if ($toolName -match "^agent") { continue }

                    # Evict if old enough (retention: bash=5 rounds, others=3 rounds)
                    $retention = if ($toolName -eq "powershell" -or $toolName -eq "bash" -or $toolName -match "^mcp__") { 5 } else { 3 }
                    # Simplified age check: position-based
                    if ($mi -lt $global:MESSAGES.Count - $retention * 2 - 2) {
                        $size = if ($block.content) { "$($block.content)".Length } else { 0 }
                        if ($size -gt 200) {
                            $marker = "[evicted: $toolName -> was ${size}B. Re-execute if needed.]"
                            $global:MESSAGES[$mi].content[$bi] = @{
                                type = "tool_result"
                                tool_use_id = $block.tool_use_id
                                content = @(@{ type = "text"; text = $marker })
                            }
                            $changed = $true
                        }
                    }
                }
            }
        }
    }

    if ($changed) {
        Write-Log "L1 tool evict: evicted old tool results"
    }
}

# ============================================================================
#  Compression entry point
# ============================================================================

function Compress-Context {
    <# 3-level compression pipeline #>
    Compress-Offload
    Compress-ToolEvict
    # L2 (LLM summarization) would be invoked here when context pressure is critical
}

# ============================================================================
#  Prompt Engineering (Section 5b)
#  7-layer prompt assembly
# ============================================================================

function Build-SystemPrompt {
    <#
    .SYNOPSIS
    Assemble the full system prompt from 7 layers:
    L1: POWERAGENT.md (external)
    L2: System Prompt (built-in)
    L3: Agent descriptions + Skill list
    L4: Dynamic context (env + memory + TODO)
    L5: Message history prefix (cached)
    L6: Message tail (uncached)
    L7: Tools JSON (cached)
    #>

    $parts = @()

    # L1: External project context
    if ($global:PA_MD) {
        $parts += $global:PA_MD
    }

    # L2: Built-in system prompt
    $parts += $global:PA_SYSTEM_PROMPT

    # L3: Agent descriptions
    if ($global:AGENT_DESCRIPTIONS) {
        $parts += "`nAvailable sub-agents:`n$($global:AGENT_DESCRIPTIONS)"
    }

    # L4: Dynamic context
    $dynamicCtx = Build-DynamicContext
    if ($dynamicCtx) {
        $parts += $dynamicCtx
    }

    return ($parts -join "`n")
}

# NOTE: Build-DynamicContext in Compression section is the SIMPLE version.
# The MORE COMPLETE version (with env+git+platform+shell+model+time+memory+TODO)
# is defined in the AgentLoop section below and will override this one at runtime.
# Kept here as fallback if AgentLoop is not loaded.
function Build-DynamicContext {
    <# Build L4: environment info + memory + TODO state #>
    $ctx = @()

    # Environment
    $ctx += "Environment: PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion)"
    $ctx += "Working directory: $(Get-Location)"
    $ctx += "Model: $($global:PA_MODEL)"

    # Active TODOs (if any)
    if ($global:TODOS -and $global:TODOS.Count -gt 0) {
        $activeTodos = $global:TODOS | Where-Object { $_.status -in @("pending", "in_progress") }
        if ($activeTodos) {
            $ctx += "`nActive TODOs:"
            foreach ($todo in $activeTodos) {
                $ctx += "  [$($todo.status)] $($todo.title)"
            }
        }
    }

    # Memory (if enabled)
    if ($global:PA_MEMORY_ENABLED -eq "true" -and $global:MEMORY_POOL) {
        $ctx += "`nRelevant memories: $($global:MEMORY_POOL.Substring(0, [Math]::Min(500, $global:MEMORY_POOL.Length)))"
    }

    return ($ctx -join "`n")
}

function Build-RequestTools {
    <# Build tools JSON array for API request #>
    $tools = Get-ToolSchemas
    # Add MCP tools if available
    if ($global:MCP_TOOLS_SCHEMA) {
        $tools += $global:MCP_TOOLS_SCHEMA
    }
    return $tools
}

function Estimate-ContextTokens {
    <# Rough token estimation: bytes * 10 / 35 + 28000 #>
    $json = Get-MessagesJson
    if (-not $json) { $json = "" }
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    $global:ESTIMATED_CONTEXT_TOKENS = [Math]::Floor($bytes * 10 / 35) + 28000
    return $global:ESTIMATED_CONTEXT_TOKENS
}

function Test-ContextWindowPressure {
    <# 3-tier pressure check: safe (75%), warn (85%), critical (95%) #>
    $tokens = Estimate-ContextTokens
    $window = [int]$global:PA_CONTEXT_WINDOW
    $safeRatio = [int]$global:PA_CONTEXT_SAFE_RATIO
    $threshold = [Math]::Floor($window * $safeRatio / 100)

    if ($tokens -ge [Math]::Floor($window * 0.95)) {
        return "critical"
    } elseif ($tokens -ge [Math]::Floor($window * 0.85)) {
        return "warn"
    } elseif ($tokens -ge $threshold) {
        return "safe_pressure"
    }
    return "ok"
}


# ============================================================================
#  Inlined: AgentSystem.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - AgentSystem.ps1
#  Section 7: Sub-Agent System, Skills, Memory, TODOs, Scheduler
#  PowerShell 5.1 port of bashagt Section 7 (lines 6965-10705)
#
#  Key Bash->PS differences:
#  - Fork bashagt --oneshot -> Start-Process powershell -File PowerAgent.ps1 --oneshot
#  - declare -A AGENTS[] -> hashtables
#  - FIFO-based inter-agent communication -> .NET Named Pipes or file-based
#  - pgrep/pkill for worker management -> Get-Process/Stop-Process
# ============================================================================

# ============================================================================
#  Agent Registry
# ============================================================================

$global:AGENTS = @{}           # name -> system prompt
$global:AGENT_META = @{}      # name -> metadata JSON
$global:AGENT_STATUS = @{}    # name -> idle/busy/error
$global:AGENT_DISCOVERS = @{} # name -> discoverable agents
$global:AGENT_DESCRIPTIONS = ""
# 注: MODEL_PROFILES 在 ModelProfiles.ps1 中初始化，不在此处重复初始化

# ── Skill Registry ──
$global:SKILLS = @{}
$global:SKILL_META = @{}
$global:ACTIVE_SKILLS = @()

# ── Memory Network ──
$global:MEMORY_POOL = ""
$global:MEM_NET_DIR = ""
$global:MEMORY_ENGRAM_COUNT = 16
$global:MEMORY_SLOT_CAPACITY = 200
$global:MEMORY_SHORT_TERM_MAX = 50
$global:MEMORY_COMPRESS_THRESHOLD = 0.8
$global:MEMORY_DATA = @{
    short_term = @()
    long_term  = @()
    work       = @()
    engrams    = @(,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()+,@()) # 16 empty arrays
    meta       = @{}
}

# ── TODO System ──
$global:TODOS = @()
$global:TODO_FILE = ""
$global:_LAST_TODO_ID = 0

# ── Job Queue ──
$global:_JOB_QUEUE = @{}
$global:_JOB_COUNTER = 0

# ============================================================================
#  Agent Loading
# ============================================================================

function Import-Agents {
    <# Load system agents then project agents #>
    $global:AGENTS = @{}
    $global:AGENT_META = @{}
    $global:AGENT_STATUS = @{}

    # Built-in system agents (always available)
    $systemAgents = @{
        plan = @{
            description = "Design implementation plans before coding"
            prompt = "You are a planning specialist. Analyze requirements, identify affected files, propose architecture, and produce step-by-step implementation steps with risk flags."
            tools = @("read_file", "list_files", "powershell")
        }
        explore = @{
            description = "Broad codebase search and exploration with PowerShell access"
            prompt = "You are a codebase explorer. Search files, trace dependencies, find patterns, and report findings concisely."
            system = $true
            tools = @("read_file", "list_files", "powershell")
        }
        summarize = @{
            description = "Condenses long content into concise bullet-point summaries"
            prompt = "You are a summarization specialist. Condense content preserving key facts: file paths, function names, decisions, numbers."
            tools = @("read_file", "list_files")
        }
        mem_writer = @{
            description = "Routes important facts to persistent memory network"
            prompt = "You are a memory writer. Classify and route important facts to the persistent memory network. Save decisions, preferences, conventions."
            tools = @("read_file", "list_files")
        }
        agent_manager = @{
            description = "Creates, updates, and deletes project-level sub-agents"
            prompt = "You are an agent manager. Create, update, and delete project-level agents stored in .poweragent/agents/."
            tools = @("read_file", "write_file", "list_files", "powershell")
        }
        format = @{
            description = "Terminal output formatting (BSRP protocol)"
            prompt = "You format terminal output using the PowerAgent Stream Rendering Protocol."
            tools = @()
        }
        review = @{
            description = "Code review specialist: correctness, edge cases, style, performance"
            prompt = "You are a code reviewer. Analyze code for correctness, edge cases, error handling, style consistency, and performance. Provide actionable feedback with file:line references."
            tools = @("read_file", "list_files", "powershell")
        }
        debug = @{
            description = "Systematic debugging: reproduce, trace, root cause, minimal fix"
            prompt = "You are a debugging specialist. Follow a systematic approach: 1) Reproduce the issue 2) Trace the execution path 3) Identify root cause 4) Propose minimal fix. Never shotgun-debug."
            tools = @("read_file", "list_files", "powershell", "web_request")
        }
    }

    foreach ($name in $systemAgents.Keys) {
        $agent = $systemAgents[$name]
        $global:AGENTS[$name] = $agent.prompt
        $global:AGENT_META[$name] = ConvertTo-JsonSafe @{
            description = $agent.description
            tools = $agent.tools
            system = $true
        }
        $global:AGENT_STATUS[$name] = "idle"
    }

    # Load project agents from .poweragent/agents/
    # PS 5.1 兼容：不能在内联表达式中使用 if
    $baseDir = "."
    if ($global:PA_PROJECT_DIR) { $baseDir = $global:PA_PROJECT_DIR }
    $prjAgentDir = Join-Path $baseDir ".poweragent\agents"
    if (Test-Path $prjAgentDir) {
        Get-ChildItem $prjAgentDir -Filter "*.md" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $content = Get-Content $_.FullName -Raw -Encoding UTF8
                $parsed = Parse-AgentFile $content
                if ($parsed) {
                    $agentName = $_.BaseName
                    $global:AGENTS[$agentName] = $parsed.prompt
                    $global:AGENT_META[$agentName] = ConvertTo-JsonSafe $parsed.meta
                    $global:AGENT_STATUS[$agentName] = "idle"
                }
            } catch {
                Write-Log "WARN: Failed to load agent $($_.Name)"
            }
        }
    }

    # Build description string
    $descs = @()
    foreach ($name in $global:AGENTS.Keys) {
        $meta = $global:AGENT_META[$name] | ConvertFrom-Json
        $descs += "  - $name : $($meta.description)"
    }
    $global:AGENT_DESCRIPTIONS = $descs -join "`n"
}

function Parse-AgentFile {
    <# Parse .md agent file with optional JSON frontmatter #>
    param([string]$Content)

    if ($Content -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n(.*)$') {
        $frontmatter = $Matches[1]
        $body = $Matches[2]
        try {
            $meta = $frontmatter | ConvertFrom-Json
            return @{
                prompt = $body.Trim()
                meta = @{
                    description = $meta.description
                    tools = $meta.tools
                    model = $meta.model
                    system = $false
                }
            }
        } catch {
            # YAML-like frontmatter not supported in PS native; treat all as prompt
        }
    }

    # No frontmatter: entire content is the prompt
    return @{
        prompt = $Content.Trim()
        meta = @{ description = "Custom agent"; tools = @("read_file", "list_files", "powershell"); system = $false }
    }
}

# ============================================================================
#  Agent Tool Implementations (overrides Tools.ps1 stubs)
# ============================================================================

function Invoke-ToolAgent {
    <# Delegate work to a sub-agent #>
    param([hashtable]$Params)

    $name = $Params.name
    $prompt = $Params.prompt
    $async = [bool]$Params.async

    if (-not $global:AGENTS.ContainsKey($name)) {
        return @{ status = "error"; error = "Unknown agent: $name" }
    }

    if ($async) {
        # Submit async job
        $global:_JOB_COUNTER++
        $jobId = "job_$($global:_JOB_COUNTER)"
        $global:_JOB_QUEUE[$jobId] = @{
            id = $jobId
            agent = $name
            prompt = $prompt
            status = "queued"
            start_time = Get-TimestampMs
            result = $null
        }

        # Start background job
        $agentPrompt = $global:AGENTS[$name]
        Start-Job -Name $jobId -ScriptBlock {
            param($ap, $up, $model, $apiKey, $apiUrl)
            # Simplified: in production this would invoke PowerAgent --oneshot
            return "Agent output placeholder"
        } -ArgumentList $agentPrompt, $prompt, $global:PA_MODEL, $global:PA_API_KEY, $global:PA_API_URL | Out-Null

        return @{ status = "ok"; job_id = $jobId; async = $true }
    }

    # Synchronous agent call
    $global:AGENT_STATUS[$name] = "busy"
    try {
        $output = Invoke-AgentCore -Name $name -Prompt $prompt
        $global:AGENT_STATUS[$name] = "idle"
        return @{ status = "ok"; output = $output; agent = $name }
    } catch {
        $global:AGENT_STATUS[$name] = "error"
        return @{ status = "error"; error = "Agent $name failed: $_" }
    }
}

function Invoke-AgentCore {
    <# Core agent execution: runs PowerAgent in oneshot mode #>
    param([string]$Name, [string]$Prompt)

    $agentPrompt = $global:AGENTS[$Name]
    $meta = $global:AGENT_META[$Name] | ConvertFrom-Json

    # Build a simplified API call with the agent's system prompt
    $systemPrompt = $agentPrompt
    $messages = @(
        @{ role = "user"; content = $Prompt }
    )

    $body = @{
        model = if ($meta.model) { $meta.model } else { $global:PA_MODEL }
        max_tokens = [int]$global:PA_MAX_TOKENS
        system = $systemPrompt
        messages = $messages
    } | ConvertTo-Json -Depth 10

    $headers = Get-ApiHeaders
    $result = Invoke-HttpRequest -Method "POST" -Url $global:PA_API_URL -Body $body -Headers $headers

    if ($result.ExitCode -eq 0) {
        try {
            $resp = $result.Body | ConvertFrom-Json
            $text = ""
            foreach ($block in $resp.content) {
                if ($block.type -eq "text") { $text += $block.text }
            }
            return $text
        } catch {
            return "Agent returned unparseable response"
        }
    }
    return "Agent API call failed: HTTP $($result.StatusCode)"
}

function Invoke-ToolAgentStatus { param([hashtable]$I); return @{ status = "ok"; agents = $global:AGENT_STATUS } }

function Invoke-ToolAgentBatch {
    <# Execute up to 4 agents in parallel #>
    param([hashtable]$Params)
    $tasks = $Params.tasks
    if (-not $tasks -or $tasks.Count -eq 0) {
        return @{ status = "error"; error = "No tasks provided" }
    }
    if ($tasks.Count -gt 4) {
        return @{ status = "error"; error = "Maximum 4 parallel agents" }
    }

    $results = @()
    # Use PS jobs for parallelism
    $jobs = @()
    foreach ($task in $tasks) {
        $agentName = $task.agent
        $prompt = $task.prompt
        if ($global:AGENTS.ContainsKey($agentName)) {
            $job = Start-Job -ScriptBlock {
                param($n, $p, $ap, $model, $key, $url, $headers)
                # Simplified: in production this would call PowerAgent --oneshot
                return "[$n] Result placeholder for: $p"
            } -ArgumentList $agentName, $prompt, $global:AGENTS[$agentName], $global:PA_MODEL, $global:PA_API_KEY, $global:PA_API_URL, (Get-ApiHeaders)
            $jobs += @{ job = $job; agent = $agentName }
        }
    }

    # Wait for all jobs
    foreach ($j in $jobs) {
        $output = Receive-Job $j.job -Wait -ErrorAction SilentlyContinue
        Remove-Job $j.job -Force -ErrorAction SilentlyContinue
        $results += @{ agent = $j.agent; output = $output }
    }

    return @{ status = "ok"; results = $results }
}

function Invoke-ToolSendMessage { param([hashtable]$I); return @{ status = "ok"; sent = $true } }
function Invoke-ToolCheckMessages { param([hashtable]$I); return @{ status = "ok"; messages = @() } }
function Invoke-ToolJobPoll { param([hashtable]$I); return @{ status = "ok"; job_status = if ($global:_JOB_QUEUE[$I.job_id]) { $global:_JOB_QUEUE[$I.job_id].status } else { "unknown" } } }
function Invoke-ToolJobResult { param([hashtable]$I); $j = $global:_JOB_QUEUE[$I.job_id]; if ($j) { return @{ status = "ok"; result = $j.result } } else { return @{ status = "error"; error = "Job not found" } } }
function Invoke-ToolJobCancel { param([hashtable]$I); if ($global:_JOB_QUEUE[$I.job_id]) { $global:_JOB_QUEUE[$I.job_id].status = "cancelled"; return @{ status = "ok" } }; return @{ status = "error"; error = "Job not found" } }

# ============================================================================
#  Skill System
# ============================================================================

function Import-Skills {
    $global:SKILLS = @{}
    $global:SKILL_META = @{}

    # System skills
    $sysSkillDir = Join-Path $env:USERPROFILE ".poweragent\skills"
    if (Test-Path $sysSkillDir) {
        Get-ChildItem $sysSkillDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $skillFile = Join-Path $_.FullName "skill.md"
            if (Test-Path $skillFile) {
                $content = Get-Content $skillFile -Raw -Encoding UTF8
                $parsed = Parse-SkillFile $content
                if ($parsed) {
                    $global:SKILLS[$_.Name] = $parsed.body
                    $global:SKILL_META[$_.Name] = ConvertTo-JsonSafe $parsed.meta
                }
            }
        }
    }

    # Project skills (override system)
    $prjSkillDir = ".poweragent\skills"
    if (Test-Path $prjSkillDir) {
        Get-ChildItem $prjSkillDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $skillFile = Join-Path $_.FullName "skill.md"
            if (Test-Path $skillFile) {
                $content = Get-Content $skillFile -Raw -Encoding UTF8
                $parsed = Parse-SkillFile $content
                if ($parsed) {
                    $global:SKILLS[$_.Name] = $parsed.body
                    $global:SKILL_META[$_.Name] = ConvertTo-JsonSafe $parsed.meta
                }
            }
        }
    }

    # All skills active by default
    $global:ACTIVE_SKILLS = @($global:SKILLS.Keys)
}

function Parse-SkillFile {
    param([string]$Content)
    # Try JSON frontmatter
    if ($Content -match '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n(.*)$') {
        try {
            $meta = $Matches[1] | ConvertFrom-Json
            return @{
                body = $Matches[2].Trim()
                meta = @{ name = $meta.name; description = $meta.description; active = $true }
            }
        } catch {}
    }
    return @{
        body = $Content.Trim()
        meta = @{ description = "Custom skill"; active = $true }
    }
}

function Invoke-ToolSkill { param([hashtable]$I); return @{ status = "error"; error = "Skill '$($I.name)' not found" } }
function Invoke-ToolListSkills { return @{ status = "ok"; skills = @($global:ACTIVE_SKILLS) } }
function Invoke-ToolListAgents {
    $list = @()
    foreach ($name in $global:AGENTS.Keys) {
        $meta = $global:AGENT_META[$name] | ConvertFrom-Json
        $list += @{ name = $name; description = $meta.description }
    }
    return @{ status = "ok"; agents = $list }
}

# ============================================================================
#  TODO System
# ============================================================================

function Import-Todos {
    $global:TODO_FILE = ".poweragent\todo.json"
    if (Test-Path $global:TODO_FILE) {
        try {
            $global:TODOS = @(Get-Content $global:TODO_FILE -Raw -Encoding UTF8 | ConvertFrom-Json)
            $global:_LAST_TODO_ID = ($global:TODOS | ForEach-Object { [int]$_.id } | Measure-Object -Maximum).Maximum
        } catch {
            $global:TODOS = @()
            $global:_LAST_TODO_ID = 0
        }
    }
}

function Save-Todos {
    if ($global:TODO_FILE) {
        Write-AtomicFile $global:TODO_FILE (ConvertTo-JsonSafe $global:TODOS -Depth 5)
    }
}

function Invoke-ToolTaskCreate {
    param([hashtable]$Params)
    $global:_LAST_TODO_ID++
    $todo = @{
        id = "$($global:_LAST_TODO_ID)"
        title = $Params.title
        description = if ($Params.description) { $Params.description } else { "" }
        status = "pending"
        created_at = Get-TimestampMs
    }
    $global:TODOS += $todo
    Save-Todos
    return @{ status = "ok"; id = $todo.id; title = $todo.title }
}

function Invoke-ToolMakeTodos {
    param([hashtable]$Params)
    # Simplified: extract steps from plan text
    $planText = $Params.plan_text
    $steps = $planText -split "`n" | Where-Object { $_ -match '^\d+\.' -or $_ -match '^\s*-\s' -or $_ -match '^\s*STEP' }
    $created = @()
    foreach ($step in $steps) {
        $step = $step.TrimStart('0123456789.- ')
        if ($step.Length -gt 0) {
            $global:_LAST_TODO_ID++
            $todo = @{
                id = "$($global:_LAST_TODO_ID)"
                title = $step.Substring(0, [Math]::Min(200, $step.Length))
                status = "pending"
                created_at = Get-TimestampMs
            }
            $global:TODOS += $todo
            $created += $todo
        }
    }
    Save-Todos
    return @{ status = "ok"; created = $created.Count; todos = $created }
}

function Invoke-ToolTaskUpdate {
    param([hashtable]$Params)
    $id = $Params.id
    $status = $Params.status
    $found = $false
    for ($i = 0; $i -lt $global:TODOS.Count; $i++) {
        if ($global:TODOS[$i].id -eq $id) {
            $global:TODOS[$i].status = $status
            $found = $true
            break
        }
    }
    Save-Todos
    if ($found) { return @{ status = "ok"; id = $id; new_status = $status } }
    return @{ status = "error"; error = "Task not found: $id" }
}

function Invoke-ToolTaskList {
    return @{ status = "ok"; tasks = $global:TODOS }
}

# ============================================================================
#  Plan System (Item 11: plan_extract_steps, plan_auto_todo)
#  PowerShell 5.1 port of bashagt plan_extract_steps() + _plan_auto_todo()
# ============================================================================

function Invoke-PlanExtractSteps {
    <#
    .SYNOPSIS
    从计划文本中提取步骤列表。
    Port of bashagt plan_extract_steps() (L9822-9915).
    优先使用 plan_extractor 子代理；不可用时回退到正则提取。
    返回 JSON 数组字符串。
    #>
    param(
        [string]$PlanText,
        [string]$Description = ""
    )

    # 空输入防护
    if ([string]::IsNullOrWhiteSpace($PlanText)) {
        return "[]"
    }

    # 阶段1: 尝试使用 plan_extractor 子代理（如果已注册）
    if ($global:AGENTS -and $global:AGENTS.ContainsKey("plan_extractor")) {
        try {
            $extractPrompt = "Extract the implementation steps from the following plan as a JSON array of strings. Return ONLY a JSON array, no other text.`n`n---`n$PlanText`n---"
            $agentResult = Invoke-AgentCore -AgentName "plan_extractor" -UserMessage $extractPrompt
            if ($agentResult -and $agentResult -is [string]) {
                $trimmed = $agentResult.Trim()
                # 验证是否为合法 JSON 数组
                if ($trimmed.StartsWith("[")) {
                    try {
                        $parsed = $trimmed | ConvertFrom-Json
                        if ($parsed -is [array]) {
                            $elements = @($parsed)
                            if ($elements.Count -gt 0) {
                                return $trimmed
                            }
                        }
                    } catch {
                        # JSON 解析失败，回退到正则
                    }
                }
            }
        } catch {
            # 子代理失败，静默回退到正则
        }
    }

    # 阶段2: 正则回退 — 从计划文本提取步骤行
    $steps = @()
    $lines = $PlanText -split "`n"

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # 匹配模式: "Step N:", "N.", "N)", "- Step", "STEP N:", "[N]"
        $isStep = $false
        $stepText = ""

        if ($trimmed -match '^(?:Step\s+)?(\d+)[\.\)\:]\s*(.+)') {
            $isStep = $true
            $stepText = $Matches[2].Trim()
        } elseif ($trimmed -match '^\[(\d+)\]\s*(.+)') {
            $isStep = $true
            $stepText = $Matches[2].Trim()
        } elseif ($trimmed -match '^\s*STEP\s+(\d+)\s*[:\-]?\s*(.*)') {
            $isStep = $true
            $stepText = if ($Matches[2]) { $Matches[2].Trim() } else { "Step $($Matches[1])" }
        }

        if ($isStep -and $stepText.Length -gt 0) {
            # 截断过长步骤
            if ($stepText.Length -gt 300) {
                $stepText = $stepText.Substring(0, 300) + "..."
            }
            $steps += $stepText
        }
    }

    # 如果正则没有提取到任何步骤，尝试按段落分割
    if ($steps.Count -eq 0) {
        $paragraphs = $PlanText -split "`n`n" | Where-Object {
            $_.Trim().Length -gt 10 -and $_.Trim().Length -lt 500
        }
        foreach ($p in $paragraphs) {
            $steps += $p.Trim()
        }
    }

    # 最多保留 30 个步骤
    if ($steps.Count -gt 30) {
        $steps = $steps[0..29]
    }

    # 转换为 JSON 数组
    try {
        $resultJson = ConvertTo-JsonSafe $steps -Depth 3
        return $resultJson
    } catch {
        return "[]"
    }
}

function Invoke-PlanAutoTodo {
    <#
    .SYNOPSIS
    从步骤 JSON 数组批量创建 TODO 项（source:"plan"），并自动启动第一个待处理项。
    Port of bashagt _plan_auto_todo() (L9973-10034).
    返回反馈文本字符串。
    #>
    param(
        [string]$StepsJson,
        [string]$Target = ""
    )

    # 空输入防护
    if ([string]::IsNullOrWhiteSpace($StepsJson)) {
        return "[plan] No steps provided."
    }

    # 解析步骤 JSON 数组
    $steps = @()
    try {
        $parsed = @($StepsJson | ConvertFrom-Json)
        if ($parsed -is [array]) {
            $steps = @($parsed)
        } elseif ($parsed -is [string]) {
            $steps = @($parsed)
        } else {
            return "[plan] Invalid steps format: expected JSON array."
        }
    } catch {
        return "[plan] Failed to parse steps JSON: $_"
    }

    if ($steps.Count -eq 0) {
        return "[plan] No steps extracted from plan."
    }

    # 批量创建 TODO 项，标记 source = "plan"
    $created = @()
    $firstPlanTodoId = $null

    foreach ($stepText in $steps) {
        if ([string]::IsNullOrWhiteSpace($stepText)) { continue }

        $global:_LAST_TODO_ID++
        $todo = @{
            id = "$($global:_LAST_TODO_ID)"
            title = $stepText.ToString().Substring(0, [Math]::Min(200, $stepText.ToString().Length))
            status = "pending"
            source = "plan"
            created_at = Get-TimestampMs
        }
        if (-not [string]::IsNullOrWhiteSpace($Target)) {
            $todo["target"] = $Target
        }
        $global:TODOS += $todo
        $created += $todo

        # 记录第一个 plan TODO 的 ID，稍后自动启动
        if ($null -eq $firstPlanTodoId) {
            $firstPlanTodoId = $todo.id
        }
    }

    # 持久化
    try { Save-Todos } catch { }

    # 自动启动第一个 plan TODO（status: pending → in_progress）
    if ($null -ne $firstPlanTodoId) {
        for ($i = 0; $i -lt $global:TODOS.Count; $i++) {
            if ($global:TODOS[$i].id -eq $firstPlanTodoId -and $global:TODOS[$i].status -eq "pending") {
                $global:TODOS[$i].status = "in_progress"
                try { Save-Todos } catch { }
                break
            }
        }
    }

    $feedback = "[plan] Created $($created.Count) TODO items from plan."
    if ($firstPlanTodoId) {
        $feedback += " First step (id=$firstPlanTodoId) auto-started."
    }
    return $feedback
}

# ============================================================================
#  Memory Network (enhanced: engram + search + compression)
# ============================================================================

function Initialize-MemoryNetwork {
    if (-not $global:MEM_NET_DIR) {
        $global:MEM_NET_DIR = Join-Path $global:PA_PROJECT_DIR ".poweragent\mem_net"
    }
    if (-not (Test-Path $global:MEM_NET_DIR)) {
        New-Item -ItemType Directory -Path $global:MEM_NET_DIR -Force | Out-Null
    }
    # Reset to empty state
    $engrams = @()
    for ($i = 0; $i -lt $global:MEMORY_ENGRAM_COUNT; $i++) { $engrams += ,@() }
    $global:MEMORY_DATA = @{
        short_term = @()
        long_term  = @()
        work       = @()
        engrams    = $engrams
        meta       = @{ created = Get-TimestampMs }
    }
}

function Write-Memory {
    param(
        [string]$Content,
        [string]$Type = "auto",
        [string[]]$Tags = @(),
        [int]$Priority = 50
    )
    if (-not $global:MEMORY_DATA) { Initialize-MemoryNetwork }

    $entry = @{
        id        = "mem_$(Get-TimestampMs)"
        content   = $Content
        tags      = $Tags
        priority  = $Priority
        timestamp = Get-TimestampMs
    }

    # Auto-route: high priority or has tags -> long_term, else short_term
    if ($Type -eq "auto") {
        if ($Priority -ge 70 -or $Tags.Count -gt 0) {
            $Type = "long_term"
        } else {
            $Type = "short_term"
        }
    }

    switch ($Type) {
        "short_term" {
            $global:MEMORY_DATA.short_term += $entry
            # Evict oldest if over capacity
            if ($global:MEMORY_DATA.short_term.Count -gt $global:MEMORY_SHORT_TERM_MAX) {
                $global:MEMORY_DATA.short_term = $global:MEMORY_DATA.short_term[1..($global:MEMORY_DATA.short_term.Count - 1)]
            }
        }
        "long_term" {
            $global:MEMORY_DATA.long_term += $entry
        }
        "work" {
            $global:MEMORY_DATA.work += $entry
        }
    }

    # Also distribute to engram slot by hash
    $hash = Get-ContentHash $Content
    $slotIndex = [Convert]::ToInt32($hash.Substring(0, 4), 16) % $global:MEMORY_ENGRAM_COUNT
    if ($global:MEMORY_DATA.engrams[$slotIndex].Count -lt $global:MEMORY_SLOT_CAPACITY) {
        $global:MEMORY_DATA.engrams[$slotIndex] += $entry
    }

    # Sync legacy pool
    $global:MEMORY_POOL = ($global:MEMORY_DATA.long_term | ForEach-Object { $_.content }) -join "`n"
}

function Search-Memory {
    param(
        [string]$Query,
        [int]$Limit = 10,
        [string]$Type = "all"
    )
    if (-not $global:MEMORY_DATA) { return @() }

    $results = @()
    $candidates = @()

    # Collect from appropriate pools
    switch ($Type) {
        "short_term" { $candidates += $global:MEMORY_DATA.short_term }
        "long_term"  { $candidates += $global:MEMORY_DATA.long_term }
        "work"       { $candidates += $global:MEMORY_DATA.work }
        default {
            $candidates += $global:MEMORY_DATA.short_term
            $candidates += $global:MEMORY_DATA.long_term
            $candidates += $global:MEMORY_DATA.work
        }
    }

    # Also check engrams for keyword match
    $queryLower = $Query.ToLower()
    foreach ($slot in $global:MEMORY_DATA.engrams) {
        foreach ($entry in $slot) {
            if ($entry.content.ToLower().Contains($queryLower) -or
                ($entry.tags | Where-Object { $_.ToLower().Contains($queryLower) })) {
                $candidates += $entry
            }
        }
    }

    # Score and sort
    $seen = @{}
    foreach ($entry in $candidates) {
        if ($seen[$entry.id]) { continue }
        $seen[$entry.id] = $true
        $score = 0
        if ($entry.content.ToLower().Contains($queryLower)) { $score += 10 }
        foreach ($tag in $entry.tags) {
            if ($tag.ToLower().Contains($queryLower)) { $score += 5 }
        }
        $score += [Math]::Min($entry.priority, 50) / 10
        $results += @{ entry = $entry; score = $score }
    }

    $results = $results | Sort-Object -Property score -Descending | Select-Object -First $Limit
    return ($results | ForEach-Object { $_.entry })
}

function Compress-Memory {
    if (-not $global:MEMORY_DATA) { return }

    # Expire old short_term entries (keep last 30)
    if ($global:MEMORY_DATA.short_term.Count -gt 30) {
        $global:MEMORY_DATA.short_term = $global:MEMORY_DATA.short_term[($global:MEMORY_DATA.short_term.Count - 30)..($global:MEMORY_DATA.short_term.Count - 1)]
    }

    # Decay long_term: remove entries with priority < 20
    $global:MEMORY_DATA.long_term = @($global:MEMORY_DATA.long_term | Where-Object { $_.priority -ge 20 })

    # Reclaim orphan engram slots
    for ($i = 0; $i -lt $global:MEMORY_ENGRAM_COUNT; $i++) {
        if ($global:MEMORY_DATA.engrams[$i].Count -gt $global:MEMORY_SLOT_CAPACITY) {
            $global:MEMORY_DATA.engrams[$i] = @($global:MEMORY_DATA.engrams[$i] | Sort-Object -Property priority -Descending | Select-Object -First $global:MEMORY_SLOT_CAPACITY)
        }
    }

    # Sync legacy pool
    $global:MEMORY_POOL = ($global:MEMORY_DATA.long_term | ForEach-Object { $_.content }) -join "`n"
}

function Build-MemoryContext {
    if (-not $global:MEMORY_DATA) { return "" }
    $parts = @()

    # Work memory (most recent context)
    if ($global:MEMORY_DATA.work.Count -gt 0) {
        $parts += "[Work Memory]"
        foreach ($w in $global:MEMORY_DATA.work) {
            $parts += "  $($w.content)"
        }
    }

    # Top long_term memories (by priority)
    $top = @($global:MEMORY_DATA.long_term | Sort-Object -Property priority -Descending | Select-Object -First 10)
    if ($top.Count -gt 0) {
        $parts += "[Long-Term Memory]"
        foreach ($m in $top) {
            $parts += "  [$($m.priority)] $($m.content)"
        }
    }

    return ($parts -join "`n")
}

function Save-MemoryNetwork {
    if (-not $global:MEMORY_DATA) { return }
    if (-not $global:MEM_NET_DIR) {
        $global:MEM_NET_DIR = Join-Path $global:PA_PROJECT_DIR ".poweragent\mem_net"
    }
    if (-not (Test-Path $global:MEM_NET_DIR)) {
        New-Item -ItemType Directory -Path $global:MEM_NET_DIR -Force | Out-Null
    }
    # Save new format
    $networkFile = Join-Path $global:MEM_NET_DIR "network.json"
    $json = ConvertTo-JsonSafe $global:MEMORY_DATA
    [System.IO.File]::WriteAllText($networkFile, $json, [System.Text.Encoding]::UTF8)
    # Legacy compat: also save pool.json
    $poolFile = Join-Path $global:MEM_NET_DIR "pool.json"
    [System.IO.File]::WriteAllText($poolFile, $global:MEMORY_POOL, [System.Text.Encoding]::UTF8)
}

function Import-Memories {
    $base = if ($global:PA_PROJECT_DIR) { $global:PA_PROJECT_DIR } else { "." }
    $global:MEM_NET_DIR = Join-Path $base ".poweragent\mem_net"
    if (-not (Test-Path $global:MEM_NET_DIR)) {
        New-Item -ItemType Directory -Path $global:MEM_NET_DIR -Force | Out-Null
    }
    # Try new format first
    $networkFile = Join-Path $global:MEM_NET_DIR "network.json"
    if (Test-Path $networkFile) {
        try {
            $json = Get-Content $networkFile -Raw -Encoding UTF8
            $data = ConvertFrom-JsonSafe $json
            if ($data) {
                $global:MEMORY_DATA = @{
                    short_term = @($data.short_term)
                    long_term  = @($data.long_term)
                    work       = @($data.work)
                    engrams    = @($data.engrams)
                    meta       = $data.meta
                }
                # Sync legacy pool
                $global:MEMORY_POOL = ($global:MEMORY_DATA.long_term | ForEach-Object { $_.content }) -join "`n"
                return
            }
        } catch {
            Write-Log "WARN: Failed to load network.json: $($_.Exception.Message)"
        }
    }
    # Fallback: old pool.json format
    $poolFile = Join-Path $global:MEM_NET_DIR "pool.json"
    if (Test-Path $poolFile) {
        try {
            $global:MEMORY_POOL = Get-Content $poolFile -Raw -Encoding UTF8
            # Migrate old pool to new format
            if ($global:MEMORY_POOL -and $global:MEMORY_POOL.Length -gt 0) {
                Initialize-MemoryNetwork
                Write-Memory -Content $global:MEMORY_POOL -Type "long_term" -Priority 50
                Save-MemoryNetwork
            }
        } catch {
            $global:MEMORY_POOL = ""
        }
    } else {
        Initialize-MemoryNetwork
    }
}

# ============================================================================
#  TODO Context Builder (Item 14: Dynamic Context Assembly)
#  PowerShell 5.1 port of bashagt build_todo_context()
# ============================================================================

function Build-TodoContext {
    <#
    .SYNOPSIS
    从 $global:TODOS 构建人类可读的 TODO 上下文字符串。
    返回空字符串如果无 TODO 项。
    #>
    if (-not $global:TODOS -or @($global:TODOS).Count -eq 0) { return "" }

    $pending = @($global:TODOS | Where-Object { $_.status -eq "pending" })
    $inProgress = @($global:TODOS | Where-Object { $_.status -eq "in_progress" })

    $lines = @()
    $lines += "Active TODOs ($($inProgress.Count) in progress, $($pending.Count) pending):"
    foreach ($t in $inProgress) {
        $lines += "  [IN PROGRESS] $($t.subject)"
    }
    foreach ($t in $pending) {
        $lines += "  [PENDING] $($t.subject)"
    }
    return ($lines -join "`n")
}

# ============================================================================
#  MCP Tool Stubs
# ============================================================================

$global:MCP_SERVERS = @{}
$global:MCP_TOOLS_SCHEMA = @()

function Invoke-McpTool {
    param([string]$Server, [string]$Tool, [hashtable]$Params)
    return @{ status = "error"; error = "MCP not connected: $Server" }
}

# NOTE: Invoke-ToolListMcpTools in AgentSystem is overridden by McpClient's
# full implementation. Removed AgentSystem's redundant version.
# (Tools.ps1 stub at line ~3608 and McpClient's real impl are sufficient)

# ============================================================================
#  Agent Worker System (Item 13)
#  PowerShell 5.1 port of bashagt _agent_worker() / _agent_worker_bash()
#  Uses Start-Job for background execution; tracked via on-disk JSON + PS Jobs.
# ============================================================================

# ── Jobs Directory ──
$global:JOBS_DIR = ""

function Initialize-JobsDir {
    <#
    .SYNOPSIS
    确保 JOBS_DIR 存在，清理超过 1 小时的旧任务。
    #>
    $baseDir = "."
    if ($global:PA_PROJECT_DIR) { $baseDir = $global:PA_PROJECT_DIR }
    $global:JOBS_DIR = Join-Path $baseDir ".poweragent\jobs"
    if (-not (Test-Path $global:JOBS_DIR)) {
        New-Item -ItemType Directory -Path $global:JOBS_DIR -Force | Out-Null
    }

    # 清理超过 1 小时的旧任务文件
    try {
        $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3600
        Get-ChildItem $global:JOBS_DIR -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $raw = Get-Content $_.FullName -Raw -Encoding UTF8
                $job = $raw | ConvertFrom-Json
                if ($job.created_at -and [long]$job.created_at -lt $cutoff) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {
                # 无法解析的 JSON 文件直接删除
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "WARN: Jobs cleanup failed: $_"
    }
}

function Update-JobStatus {
    <#
    .SYNOPSIS
    读取任务 JSON 文件、合并更新字段、写回磁盘。
    #>
    param(
        [string]$JobId,
        [string]$Status,
        [hashtable]$Updates
    )

    if (-not $global:JOBS_DIR) { Initialize-JobsDir }

    $jobFile = Join-Path $global:JOBS_DIR "$JobId.json"
    if (-not (Test-Path $jobFile)) {
        Write-Log "WARN: Update-JobStatus: job file not found: $jobFile"
        return
    }

    try {
        $raw = Get-Content $jobFile -Raw -Encoding UTF8
        $job = $raw | ConvertFrom-Json

        # 更新状态
        $job.status = $Status

        # 合并额外字段
        if ($Updates) {
            foreach ($key in $Updates.Keys) {
                $job | Add-Member -MemberType NoteProperty -Name $key -Value $Updates[$key] -Force
            }
        }

        $json = $job | ConvertTo-Json -Depth 5 -Compress
        Write-AtomicFile $jobFile $json
    } catch {
        Write-Log "WARN: Update-JobStatus failed for $JobId : $_"
    }
}

function Start-AgentJob {
    <#
    .SYNOPSIS
    启动后台子代理任务。
    创建任务元数据文件，使用 Start-Job 异步执行。
    返回 @{status="running"; job_id=...}
    #>
    param(
        [string]$Agent,
        [string]$Prompt,
        [int]$Timeout = 120
    )

    if (-not $global:AGENTS.ContainsKey($Agent)) {
        return @{ status = "error"; error = "Unknown agent: $Agent" }
    }

    # 确保目录存在
    Initialize-JobsDir

    # 生成唯一 Job ID
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $rand = Get-Random -Minimum 100 -Maximum 999
    $jobId = "job_${ts}_${rand}"

    # 结果文件路径
    $resultFile = Join-Path $global:JOBS_DIR "${jobId}_result.txt"

    # 任务元数据
    $jobMeta = @{
        id          = $jobId
        type        = "agent"
        agent       = $Agent
        prompt      = $Prompt
        status      = "running"
        created_at  = $ts
        finished_at = 0
        result_file = $resultFile
        result_size = 0
        error       = ""
        ps_job_id   = ""
        timeout     = $Timeout
    }

    # 写入元数据文件
    $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
    $json = $jobMeta | ConvertTo-Json -Depth 5
    Write-AtomicFile $jobFile $json

    # 获取代理 system prompt（需要传递给后台 Job）
    $agentPrompt = $global:AGENTS[$Agent]
    $agentMeta = $global:AGENT_META[$Agent]
    $model = $global:PA_MODEL
    $maxTokens = $global:PA_MAX_TOKENS
    $apiUrl = $global:PA_API_URL
    $apiKey = $global:PA_API_KEY

    # Start-Job 在独立 PS 进程中运行 — 只能通过参数传递数据
    $psJob = Start-Job -ScriptBlock {
        param($agPrompt, $usrPrompt, $mdl, $maxTk, $url, $key, $outFile, $jobId, $agName)
        try {
            # 构造简化的 API 调用
            $body = @{
                model     = $mdl
                max_tokens = [int]$maxTk
                system    = $agPrompt
                messages  = @(@{ role = "user"; content = $usrPrompt })
            } | ConvertTo-Json -Depth 10

            $headers = @{
                "Content-Type"  = "application/json"
                "Authorization" = "Bearer $key"
            }

            $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers -ContentType "application/json" -TimeoutSec 180 -ErrorAction Stop

            $text = ""
            if ($response.content) {
                foreach ($block in $response.content) {
                    if ($block.type -eq "text") { $text += $block.text }
                }
            }
            if (-not $text) { $text = "[Agent $agName returned empty response]" }

            Set-Content $outFile $text -Encoding UTF8
            return "ok"
        } catch {
            $errMsg = "Agent error: $_"
            Set-Content $outFile $errMsg -Encoding UTF8
            return "error"
        }
    } -ArgumentList $agentPrompt, $Prompt, $model, $maxTokens, $apiUrl, $apiKey, $resultFile, $jobId, $Agent

    # 更新元数据中的 PS Job ID
    Update-JobStatus -JobId $jobId -Status "running" -Updates @{ ps_job_id = $psJob.Id.ToString() }

    # 标记代理为忙碌
    $global:AGENT_STATUS[$Agent] = "busy"

    Write-Log "INFO: Started agent job $jobId (agent=$Agent, PSJob=$($psJob.Id))"

    return @{ status = "running"; job_id = $jobId }
}

function Start-PowerShellJob {
    <#
    .SYNOPSIS
    启动后台 PowerShell 命令任务。
    创建任务元数据文件，使用 Start-Job 异步执行。
    返回 @{status="running"; job_id=...}
    #>
    param(
        [string]$Command,
        [int]$Timeout = 120
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return @{ status = "error"; error = "Command is empty" }
    }

    # 确保目录存在
    Initialize-JobsDir

    # 生成唯一 Job ID
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $rand = Get-Random -Minimum 100 -Maximum 999
    $jobId = "job_${ts}_${rand}"

    # 结果文件路径
    $resultFile = Join-Path $global:JOBS_DIR "${jobId}_result.txt"

    # 任务元数据
    $jobMeta = @{
        id          = $jobId
        type        = "powershell"
        agent       = ""
        prompt      = $Command
        status      = "running"
        created_at  = $ts
        finished_at = 0
        result_file = $resultFile
        result_size = 0
        error       = ""
        ps_job_id   = ""
        timeout     = $Timeout
    }

    # 写入元数据文件
    $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
    $json = $jobMeta | ConvertTo-Json -Depth 5
    Write-AtomicFile $jobFile $json

    # 启动后台命令
    $psJob = Start-Job -ScriptBlock {
        param($cmd, $outFile, $timeoutSec)
        try {
            $output = powershell -NoProfile -Command $cmd 2>&1 | Out-String
            Set-Content $outFile $output -Encoding UTF8
            return "ok"
        } catch {
            $errMsg = "Command error: $_"
            Set-Content $outFile $errMsg -Encoding UTF8
            return "error"
        }
    } -ArgumentList $Command, $resultFile, $Timeout

    # 更新元数据中的 PS Job ID
    Update-JobStatus -JobId $jobId -Status "running" -Updates @{ ps_job_id = $psJob.Id.ToString() }

    Write-Log "INFO: Started powershell job $jobId (PSJob=$($psJob.Id))"

    return @{ status = "running"; job_id = $jobId }
}

function Get-AgentJobStatus {
    <#
    .SYNOPSIS
    检查任务状态。结合磁盘元数据和 PS Job 状态。
    返回 @{status, result_size, elapsed, error}
    #>
    param([string]$JobId)

    if (-not $global:JOBS_DIR) { Initialize-JobsDir }

    $jobFile = Join-Path $global:JOBS_DIR "$JobId.json"
    if (-not (Test-Path $jobFile)) {
        return @{ status = "error"; error = "Job not found: $JobId" }
    }

    try {
        $raw = Get-Content $jobFile -Raw -Encoding UTF8
        $job = $raw | ConvertFrom-Json
    } catch {
        return @{ status = "error"; error = "Failed to read job metadata" }
    }

    # 如果磁盘状态仍是 running，检查 PS Job 状态
    $diskStatus = $job.status
    if ($diskStatus -eq "running" -and $job.ps_job_id) {
        $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
        if ($psJob) {
            if ($psJob.State -eq "Completed") {
                # PS Job 完成 — 更新磁盘状态
                $resultFile = $job.result_file
                $sz = 0
                if (Test-Path $resultFile) {
                    $sz = (Get-Item $resultFile).Length
                }
                Update-JobStatus -JobId $JobId -Status "done" -Updates @{
                    finished_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    result_size = $sz
                }
                $diskStatus = "done"
                $job.finished_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $job.result_size = $sz

                # 恢复代理状态
                if ($job.agent -and $global:AGENT_STATUS.ContainsKey($job.agent)) {
                    $global:AGENT_STATUS[$job.agent] = "idle"
                }

                # 清理 PS Job
                Remove-Job $psJob -Force -ErrorAction SilentlyContinue
            } elseif ($psJob.State -eq "Failed") {
                Update-JobStatus -JobId $JobId -Status "failed" -Updates @{
                    finished_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    error       = "PS Job failed"
                }
                $diskStatus = "failed"
                $job.error = "PS Job failed"

                # 恢复代理状态
                if ($job.agent -and $global:AGENT_STATUS.ContainsKey($job.agent)) {
                    $global:AGENT_STATUS[$job.agent] = "idle"
                }

                Remove-Job $psJob -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 计算已用时间
    $elapsed = 0
    if ($job.created_at) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $elapsed = $now - [long]$job.created_at
    }

    return @{
        status      = $diskStatus
        result_size = [long]$job.result_size
        elapsed     = $elapsed
        error       = $job.error
    }
}

function Get-AgentJobResult {
    <#
    .SYNOPSIS
    读取任务结果文件内容。
    返回 @{content, size}
    #>
    param([string]$JobId)

    if (-not $global:JOBS_DIR) { Initialize-JobsDir }

    $jobFile = Join-Path $global:JOBS_DIR "$JobId.json"
    if (-not (Test-Path $jobFile)) {
        return @{ status = "error"; error = "Job not found: $JobId" }
    }

    try {
        $raw = Get-Content $jobFile -Raw -Encoding UTF8
        $job = $raw | ConvertFrom-Json
    } catch {
        return @{ status = "error"; error = "Failed to read job metadata" }
    }

    # 任务状态必须为 done
    $statusCheck = Get-AgentJobStatus -JobId $JobId
    if ($statusCheck.status -ne "done") {
        return @{ status = "error"; error = "Job status is '$($statusCheck.status)', not 'done'" }
    }

    $resultFile = $job.result_file
    if (-not (Test-Path $resultFile)) {
        return @{ status = "error"; error = "Result file not found" }
    }

    try {
        $content = Get-Content $resultFile -Raw -Encoding UTF8
        $sz = (Get-Item $resultFile).Length
        return @{ status = "ok"; content = $content; size = $sz }
    } catch {
        return @{ status = "error"; error = "Failed to read result: $_" }
    }
}

function Stop-AgentJob {
    <#
    .SYNOPSIS
    取消运行中的任务。停止 PS Job 并更新状态。
    返回 @{status="cancelled"}
    #>
    param([string]$JobId)

    if (-not $global:JOBS_DIR) { Initialize-JobsDir }

    $jobFile = Join-Path $global:JOBS_DIR "$JobId.json"
    if (-not (Test-Path $jobFile)) {
        return @{ status = "error"; error = "Job not found: $JobId" }
    }

    try {
        $raw = Get-Content $jobFile -Raw -Encoding UTF8
        $job = $raw | ConvertFrom-Json
    } catch {
        return @{ status = "error"; error = "Failed to read job metadata" }
    }

    # 已经完成/失败的任务不能再取消
    if ($job.status -in @("done", "failed", "cancelled")) {
        return @{ status = "error"; error = "Job already in state '$($job.status)'" }
    }

    # 停止 PS Job
    if ($job.ps_job_id) {
        $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
        if ($psJob -and $psJob.State -in @("Running", "NotStarted")) {
            Stop-Job $psJob -PassThru -ErrorAction SilentlyContinue
            Remove-Job $psJob -Force -ErrorAction SilentlyContinue
        }
    }

    # 更新磁盘状态
    Update-JobStatus -JobId $JobId -Status "cancelled" -Updates @{
        finished_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }

    # 恢复代理状态
    if ($job.agent -and $global:AGENT_STATUS.ContainsKey($job.agent)) {
        $global:AGENT_STATUS[$job.agent] = "idle"
    }

    Write-Log "INFO: Cancelled job $JobId"

    return @{ status = "cancelled"; job_id = $JobId }
}


# ============================================================================
#  Inlined: McpClient.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - McpClient.ps1
#  Section 11c: MCP Module — Model Context Protocol Client
#  PowerShell 5.1 port of bashagt Section 11c (lines 13941-14463)
#
#  Implements MCP client supporting stdio, SSE, and Streamable HTTP transports.
#  Integrates with PowerAgent tool system via mcp__<server>__<tool> name prefix.
#
#  Config: settings.json `mcp_servers` key (4-tier: project > system > env > default)
# ============================================================================

# ── MCP State (hashtables replace Bash associative arrays) ──
$global:MCP_SERVERS        = @{}   # name -> config JSON string
$global:MCP_SERVER_PID     = @{}   # name -> process ID (stdio)
$global:MCP_SERVER_DIR     = @{}   # name -> temp directory path
$global:MCP_SERVER_TOOLS   = @{}   # name -> tools JSON array string
$global:MCP_SERVER_CAPS    = @{}   # name -> capabilities JSON string
$global:MCP_SERVER_READY   = @{}   # name -> bool
$global:MCP_SERVER_URL     = @{}   # name -> message POST URL (SSE/HTTP)
$global:MCP_SERVER_TRANSPORT = @{} # name -> "stdio"|"sse"|"http"
$global:MCP_NEXT_REQUEST_ID = 1
$global:MCP_CONNECTED_COUNT = 0

# ── MCP Named Pipe/Stream References (PS5.1 replacement for Bash fd/BG process) ──
$global:MCP_STREAM_WRITER = @{}  # name -> [StreamWriter] for stdio stdin
$global:MCP_STREAM_READER = @{}  # name -> [StreamReader] for stdio stdout
$global:MCP_SERVER_PROC   = @{}  # name -> [Process] for stdio subprocess

# ============================================================================
#  MCP Configuration Loading
# ============================================================================

function Get-McpSetting {
    <#
    .SYNOPSIS
    Retrieve MCP server definitions from 4-tier config.
    #>
    param([string]$Key, [string]$EnvVar, $Default = "{}")

    # Use the existing Get-Setting from Config.ps1
    $val = Get-Setting $Key $EnvVar $Default
    return $val
}

function Import-McpConfig {
    <#
    .SYNOPSIS
    Load MCP server definitions from settings.json `mcp_servers` key.
    Port of bashagt mcp_load_config().
    #>
    $global:MCP_SERVERS = @{}

    $json = Get-McpSetting "mcp_servers" "PA_MCP_SERVERS" "{}"
    if ($json -eq "{}" -or $json -eq "null" -or -not $json) { return }

    try {
        $obj = $json | ConvertFrom-Json
        if (-not $obj) { return }

        # Iterate over all server names
        $obj.PSObject.Properties | ForEach-Object {
            $name = $_.Name
            $cfg = $_.Value | ConvertTo-Json -Depth 10 -Compress
            $global:MCP_SERVERS[$name] = $cfg
        }
    } catch {
        Write-Log "WARN: MCP config parse error: $_"
    }
}

# ============================================================================
#  JSON-RPC 2.0 Primitives
# ============================================================================

function New-McpRequest {
    <#
    .SYNOPSIS
    Build a JSON-RPC 2.0 request object.
    Returns: @{ jsonrpc="2.0"; method=...; params=...; id=N }
    #>
    param(
        [string]$Method,
        $Params = @{}
    )

    $id = $global:MCP_NEXT_REQUEST_ID
    $global:MCP_NEXT_REQUEST_ID++

    if ($Params -is [string]) {
        try { $Params = $Params | ConvertFrom-Json } catch { $Params = @{} }
    }

    $request = @{
        jsonrpc = "2.0"
        method  = $Method
        params  = $Params
        id      = $id
    }

    return $request
}

function New-McpNotification {
    <#
    .SYNOPSIS
    Build a JSON-RPC 2.0 notification object (no id field).
    #>
    param(
        [string]$Method,
        $Params = @{}
    )

    if ($Params -is [string]) {
        try { $Params = $Params | ConvertFrom-Json } catch { $Params = @{} }
    }

    return @{
        jsonrpc = "2.0"
        method  = $Method
        params  = $Params
    }
}

# ============================================================================
#  stdio Transport
#  Replaces Bash: mkfifo + cat fifo | cmd > fifo + read -u fd
#  Uses: [System.Diagnostics.Process] with redirected stdin/stdout streams
# ============================================================================

function Connect-McpStdio {
    <#
    .SYNOPSIS
    Start MCP server as a subprocess with redirected stdin/stdout.
    Port of bashagt mcp_transport_stdio_connect().
    #>
    param([string]$Name)

    $cfg = $global:MCP_SERVERS[$Name]
    if (-not $cfg) { Write-Log "MCP [$Name]: no config"; return $false }

    try {
        $cfgObj = $cfg | ConvertFrom-Json
    } catch {
        Write-Log "MCP [$Name]: config parse error"; return $false
    }

    $cmd = $cfgObj.command
    if (-not $cmd) { Write-Log "MCP [$Name]: no command"; return $false }

    # Build argument list
    $argList = @()
    if ($cfgObj.args) {
        $argList = @($cfgObj.args)
    }

    # Create temp directory for this MCP server instance
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "poweragent_mcp_${Name}_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $global:MCP_SERVER_DIR[$Name] = $tmpDir

    # Build environment variables from config
    $envVars = @{}
    if ($cfgObj.env) {
        $cfgObj.env.PSObject.Properties | ForEach-Object {
            $envVars[$_.Name] = $_.Value
        }
    }

    try {
        # BUG-WIN-NPX FIX: On Windows, commands like "npx" are actually
        # "npx.cmd" and cannot be used directly as ProcessStartInfo.FileName.
        # When the command is a known .cmd script or cannot be resolved as an
        # executable, wrap it with "cmd.exe /c" so the shell handles resolution.
        $startCmd = $cmd
        $startArgs = $argList

        if ($IsWindows -or $env:OS -match "Windows") {
            # Commands that are known .cmd wrappers on Windows
            $cmdCommands = @("npx", "npm", "npx.cmd", "npm.cmd", "yarn", "pnpm")
            if ($cmdCommands -contains $cmd.ToLower()) {
                Write-Log "MCP [$Name]: Windows detected — wrapping '$cmd' with cmd.exe"
                $startCmd = "cmd.exe"
                $startArgs = , "/c" + @($cmd) + $argList
            } else {
                # Try to resolve the command — if it's a .cmd/.bat, wrap it
                try {
                    $resolved = Get-Command $cmd -ErrorAction Stop
                    if ($resolved.Source -match '\.(cmd|bat)$') {
                        Write-Log "MCP [$Name]: Windows detected — '$cmd' resolves to .cmd/.bat, wrapping with cmd.exe"
                        $startCmd = "cmd.exe"
                        $startArgs = , "/c" + @($cmd) + $argList
                    }
                } catch {
                    # Command not found in PATH — try wrapping anyway
                    Write-Log "MCP [$Name]: Windows — '$cmd' not found in PATH, trying cmd.exe wrapper"
                    $startCmd = "cmd.exe"
                    $startArgs = , "/c" + @($cmd) + $argList
                }
            }
        }

        # Start process with redirected streams
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $startCmd
        $psi.Arguments = ($startArgs -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $tmpDir

        # Set environment variables
        foreach ($key in $envVars.Keys) {
            $psi.EnvironmentVariables[$key] = $envVars[$key]
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        Start-Sleep -Milliseconds 200

        if ($proc.HasExited) {
            $err = $proc.StandardError.ReadToEnd()
            Write-Log "MCP [$Name]: server died on start: $($err.Substring(0, [Math]::Min(200, $err.Length)))"
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        $global:MCP_SERVER_PROC[$Name] = $proc
        $global:MCP_SERVER_PID[$Name] = $proc.Id
        $global:MCP_STREAM_WRITER[$Name] = $proc.StandardInput
        $global:MCP_STREAM_READER[$Name] = $proc.StandardOutput
        $global:MCP_SERVER_TRANSPORT[$Name] = "stdio"

        # Track PID for crash recovery
        $trackFile = Join-Path ([System.IO.Path]::GetTempPath()) "poweragent_mcp_${PID}_$($proc.Id)"
        Set-Content $trackFile "" -Encoding UTF8

        return $true
    } catch {
        Write-Log "MCP [$Name]: failed to start: $_"
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Send-McpStdio {
    <#
    .SYNOPSIS
    Send JSON-RPC message to MCP server via stdin pipe.
    Port of bashagt mcp_transport_stdio_send().
    #>
    param(
        [string]$Name,
        [string]$Json
    )

    $writer = $global:MCP_STREAM_WRITER[$Name]
    if (-not $writer) {
        Write-Log "MCP [$Name]: no stdin writer"
        return $false
    }

    try {
        $writer.WriteLine($Json)
        $writer.Flush()
        return $true
    } catch {
        Write-Log "MCP [$Name]: write failed: $_"
        return $false
    }
}

function Receive-McpStdio {
    <#
    .SYNOPSIS
    Receive one JSON-RPC response from MCP server stdout.
    Port of bashagt mcp_transport_stdio_recv().
    Reads lines with timeout, skips notifications, validates as JSON.

    BUG-RECV-STDIO FIX: Previous version called ReadLineAsync() in a loop
    with WaitAny(500ms). When the 500ms poll timed out, the pending Task
    kept the stream locked, so the next ReadLineAsync() threw
    "The stream is currently in use by a previous operation on the stream."

    New approach: Create ONE ReadLineAsync Task per read attempt and wait
    for it with the remaining overall timeout (not a fixed 500ms poll).
    Also skips JSON-RPC notifications (messages without an "id" field).
    #>
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 30
    )

    $reader = $global:MCP_STREAM_READER[$Name]
    if (-not $reader) {
        Write-Log "MCP [$Name]: no stdout reader"
        return $null
    }

    $json = ""
    $startTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    while ($true) {
        # Check overall timeout
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $remaining = $TimeoutSeconds - ($now - $startTime)
        if ($remaining -le 0) {
            Write-Log "MCP [$Name]: recv timeout"
            return $null
        }

        try {
            # Create a single ReadLineAsync Task and wait with remaining timeout.
            # Do NOT re-enter ReadLineAsync while a previous Task is pending —
            # StreamReader rejects concurrent async reads with "stream in use".
            $readTask = $reader.ReadLineAsync()
            $waitMs = [int][Math]::Min($remaining * 1000, [int]::MaxValue)
            $waited = [System.Threading.Tasks.Task]::WaitAny(@($readTask), $waitMs)

            if ($waited -eq -1) {
                # Overall timeout elapsed
                Write-Log "MCP [$Name]: recv timeout"
                return $null
            }

            $line = $readTask.Result
            if ($null -eq $line) {
                # EOF — server closed
                Write-Log "MCP [$Name]: server closed stdout"
                return $null
            }

            # Skip blank / non-JSON lines
            if (-not $line -or -not $line.Trim().StartsWith("{")) {
                continue
            }

            # Skip JSON-RPC notifications (no "id" field) — these are
            # server-initiated events like notifications/tools/list_changed
            # that are not responses to our requests.
            try {
                $peek = $line | ConvertFrom-Json
                if ($null -eq $peek.id) {
                    Write-Log "DEBUG: MCP [$Name]: skipping notification: $($peek.method)"
                    continue
                }
            } catch {
                # Not valid JSON on its own — might be partial, accumulate
            }

            $json += $line

            # Validate as complete JSON
            try {
                $null = $json | ConvertFrom-Json
                return $json
            } catch {
                # Incomplete JSON — continue reading next line
                continue
            }
        } catch {
            # Read error
            Write-Log "MCP [$Name]: read error: $_"
            return $null
        }
    }
}

# ============================================================================
#  SSE Transport
#  Replaces Bash: http_sse_connect + event callback + inbox.jsonl
#  Uses: .NET HttpClient with SSE event parsing
# ============================================================================

function Connect-McpSse {
    <#
    .SYNOPSIS
    Connect to MCP server via SSE transport.
    Port of bashagt mcp_transport_sse_connect().
    #>
    param([string]$Name)

    $cfg = $global:MCP_SERVERS[$Name]
    if (-not $cfg) { Write-Log "MCP [$Name]: no config"; return $false }

    try {
        $cfgObj = $cfg | ConvertFrom-Json
    } catch {
        Write-Log "MCP [$Name]: config parse error"; return $false
    }

    $url = $cfgObj.url
    if (-not $url) { Write-Log "MCP [$Name]: no url for SSE"; return $false }

    # Create temp directory for inbox
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "poweragent_mcp_${Name}_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $global:MCP_SERVER_DIR[$Name] = $tmpDir
    $global:MCP_SERVER_TRANSPORT[$Name] = "sse"
    $global:MCP_SERVER_URL[$Name] = ""  # Will be set by endpoint event

    # Connect SSE stream and capture endpoint event
    try {
        $connectTimeout = [int]$global:PA_MCP_CONNECT_TIMEOUT
        if ($connectTimeout -eq 0) { $connectTimeout = 10 }

        # Use Connect-SseStream from HttpClient.ps1
        # The callback will set MCP_SERVER_URL when it receives "endpoint" event
        $endpointReceived = $false
        $inboxFile = Join-Path $tmpDir "inbox.jsonl"

        $callback = {
            param($EventType, $Data)
            switch ($EventType) {
                "endpoint" {
                    # Resolve relative URL
                    $msgUrl = $Data
                    if ($msgUrl -notmatch "^http") {
                        $base = $url.Substring(0, $url.LastIndexOf('/'))
                        $msgUrl = "$base/$($msgUrl.TrimStart('/'))"
                    }
                    $global:MCP_SERVER_URL[$Name] = $msgUrl
                    $endpointReceived = $true
                }
                "message" {
                    # Server->client JSON-RPC via SSE, queue to inbox
                    Add-Content $inboxFile "$Data`n" -Encoding UTF8
                }
            }
        }

        # Collect custom headers
        $headers = @{}
        if ($cfgObj.headers) {
            $cfgObj.headers.PSObject.Properties | ForEach-Object {
                $headers[$_.Name] = $_.Value
            }
        }

        $sseResult = Connect-SseStream -Url $url -EventCallback $callback -ConnectTimeout $connectTimeout -Headers $headers
        if (-not $sseResult) {
            Write-Log "MCP [$Name]: SSE connect failed"
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        # Wait for endpoint event
        $waitStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        while (-not $endpointReceived) {
            Start-Sleep -Milliseconds 100
            $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $waitStart
            if ($elapsed -ge $connectTimeout) {
                Write-Log "MCP [$Name]: no endpoint event received within timeout"
                Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
                return $false
            }
        }

        if (-not $global:MCP_SERVER_URL[$Name]) {
            Write-Log "MCP [$Name]: no endpoint event received"
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        return $true
    } catch {
        Write-Log "MCP [$Name]: SSE connect failed: $_"
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Send-McpSse {
    <#
    .SYNOPSIS
    Send JSON-RPC message via HTTP POST to SSE endpoint.
    Port of bashagt mcp_transport_sse_send().
    #>
    param(
        [string]$Name,
        [string]$Json
    )

    $url = $global:MCP_SERVER_URL[$Name]
    if (-not $url) {
        Write-Log "MCP [$Name]: no SSE message URL"
        return $null
    }

    $cfg = $global:MCP_SERVERS[$Name]
    $headers = @{ "Content-Type" = "application/json" }

    try {
        $cfgObj = $cfg | ConvertFrom-Json
        if ($cfgObj.headers) {
            $cfgObj.headers.PSObject.Properties | ForEach-Object {
                $headers[$_.Name] = $_.Value
            }
        }
    } catch { }

    $connectTimeout = [int]$global:PA_MCP_CONNECT_TIMEOUT
    $requestTimeout = [int]$global:PA_MCP_REQUEST_TIMEOUT
    if ($connectTimeout -eq 0) { $connectTimeout = 10 }
    if ($requestTimeout -eq 0) { $requestTimeout = 60 }

    try {
        $result = Invoke-HttpRequest -Method "POST" -Url $url -Body $Json `
            -ConnectTimeout $connectTimeout -TotalTimeout $requestTimeout `
            -Headers $headers
        return $result
    } catch {
        Write-Log "MCP [$Name]: SSE POST failed: $_"
        return $null
    }
}

function Receive-McpSse {
    <#
    .SYNOPSIS
    Receive one JSON-RPC message from SSE inbox.
    Port of bashagt mcp_transport_sse_recv().
    #>
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 30
    )

    $inbox = Join-Path $global:MCP_SERVER_DIR[$Name] "inbox.jsonl"
    $startTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    while ($true) {
        if ((Test-Path $inbox) -and ((Get-Item $inbox).Length -gt 0)) {
            # Atomically move inbox to temp, read first line
            $tmpInbox = "$inbox.tmp.$(Get-Random)"
            try {
                Move-Item $inbox $tmpInbox -Force -ErrorAction Stop
                $lines = Get-Content $tmpInbox -Encoding UTF8
                Remove-Item $tmpInbox -Force -ErrorAction SilentlyContinue

                if ($lines -and $lines.Count -gt 0) {
                    $line = $lines[0]
                    if ($line) { return $line }
                }
            } catch {
                # Race condition — retry
            }
        }

        # Check timeout
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($now - $startTime) -ge $TimeoutSeconds) {
            Write-Log "MCP [$Name]: SSE recv timeout"
            return $null
        }

        Start-Sleep -Milliseconds 100
    }
}

# ============================================================================
#  Streamable HTTP Transport
#  Replaces Bash: simple POST/response cycle
#  Uses: Invoke-HttpRequest from HttpClient.ps1
# ============================================================================

function Connect-McpHttp {
    <#
    .SYNOPSIS
    Initialize HTTP transport (stateless — just record URL).
    Port of bashagt mcp_transport_http_connect().
    #>
    param([string]$Name)

    $cfg = $global:MCP_SERVERS[$Name]
    if (-not $cfg) { Write-Log "MCP [$Name]: no config"; return $false }

    try {
        $cfgObj = $cfg | ConvertFrom-Json
    } catch {
        Write-Log "MCP [$Name]: config parse error"; return $false
    }

    $url = $cfgObj.url
    if (-not $url) { Write-Log "MCP [$Name]: no url for HTTP"; return $false }

    $global:MCP_SERVER_URL[$Name] = $url
    $global:MCP_SERVER_TRANSPORT[$Name] = "http"
    $global:MCP_SERVER_DIR[$Name] = Join-Path ([System.IO.Path]::GetTempPath()) "poweragent_mcp_${Name}_$(Get-Random)"
    New-Item -ItemType Directory -Path $global:MCP_SERVER_DIR[$Name] -Force | Out-Null

    return $true
}

function Send-McpHttp {
    <#
    .SYNOPSIS
    Send JSON-RPC message via HTTP POST and store response.
    Port of bashagt mcp_transport_http_send() + mcp_transport_http_recv() combined.
    #>
    param(
        [string]$Name,
        [string]$Json
    )

    $url = $global:MCP_SERVER_URL[$Name]
    if (-not $url) {
        Write-Log "MCP [$Name]: no HTTP URL"
        return $null
    }

    $cfg = $global:MCP_SERVERS[$Name]
    $headers = @{ "Content-Type" = "application/json" }

    try {
        $cfgObj = $cfg | ConvertFrom-Json
        if ($cfgObj.headers) {
            $cfgObj.headers.PSObject.Properties | ForEach-Object {
                $headers[$_.Name] = $_.Value
            }
        }
    } catch { }

    $connectTimeout = [int]$global:PA_MCP_CONNECT_TIMEOUT
    $requestTimeout = [int]$global:PA_MCP_REQUEST_TIMEOUT
    if ($connectTimeout -eq 0) { $connectTimeout = 10 }
    if ($requestTimeout -eq 0) { $requestTimeout = 60 }

    try {
        $result = Invoke-HttpRequest -Method "POST" -Url $url -Body $Json `
            -ConnectTimeout $connectTimeout -TotalTimeout $requestTimeout `
            -Headers $headers

        # Store in last_response for potential recv
        $respFile = Join-Path $global:MCP_SERVER_DIR[$Name] "last_response"
        Set-Content $respFile $result -Encoding UTF8

        return $result
    } catch {
        Write-Log "MCP [$Name]: HTTP POST failed: $_"
        return $null
    }
}

function Receive-McpHttp {
    <#
    .SYNOPSIS
    Return the last HTTP response (stored by Send-McpHttp).
    Port of bashagt mcp_transport_http_recv().
    #>
    param([string]$Name, [int]$TimeoutSeconds = 60)

    $respFile = Join-Path $global:MCP_SERVER_DIR[$Name] "last_response"
    if (-not (Test-Path $respFile)) {
        Write-Log "MCP [$Name]: no HTTP response"
        return $null
    }

    return Get-Content $respFile -Raw -Encoding UTF8
}

# ============================================================================
#  Transport Abstraction Layer
# ============================================================================

function Connect-McpServer {
    <#
    .SYNOPSIS
    Connect to an MCP server using the configured transport.
    Port of bashagt mcp_connect_server().
    #>
    param([string]$Name)

    $cfg = $global:MCP_SERVERS[$Name]
    if (-not $cfg) { Write-Log "MCP [$Name]: no config"; return $false }

    try {
        $cfgObj = $cfg | ConvertFrom-Json
    } catch {
        Write-Log "MCP [$Name]: config parse error"; return $false
    }

    $transport = if ($cfgObj.transport) { $cfgObj.transport } else { "stdio" }
    Write-Log "DEBUG: [MCP] connect: server=$Name transport=$transport"

    switch ($transport) {
        "stdio" { return Connect-McpStdio $Name }
        "sse"   { return Connect-McpSse $Name }
        "http"  { return Connect-McpHttp $Name }
        default {
            Write-Log "MCP [$Name]: unknown transport $transport"
            return $false
        }
    }
}

function Send-McpMessage {
    <#
    .SYNOPSIS
    Send JSON-RPC message via the server's transport layer.
    Port of bashagt mcp_send().
    #>
    param(
        [string]$Name,
        [string]$Json
    )

    $transport = $global:MCP_SERVER_TRANSPORT[$Name]
    if (-not $transport) { $transport = "stdio" }

    Write-Log "DEBUG: MCP send name=$Name transport=$transport size=$($Json.Length)"

    switch ($transport) {
        "stdio" { return Send-McpStdio $Name $Json }
        "sse"   { return Send-McpSse $Name $Json }
        "http"  { return Send-McpHttp $Name $Json }
        default { Write-Log "MCP [$Name]: unknown transport for send"; return $null }
    }
}

function Receive-McpMessage {
    <#
    .SYNOPSIS
    Receive one JSON-RPC message via the server's transport layer.
    Port of bashagt mcp_recv().
    #>
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 60
    )

    $transport = $global:MCP_SERVER_TRANSPORT[$Name]
    if (-not $transport) { $transport = "stdio" }

    Write-Log "DEBUG: MCP recv name=$Name transport=$transport timeout=$TimeoutSeconds"

    switch ($transport) {
        "stdio" { return Receive-McpStdio $Name $TimeoutSeconds }
        "sse"   { return Receive-McpSse $Name $TimeoutSeconds }
        "http"  { return Receive-McpHttp $Name $TimeoutSeconds }
        default { Write-Log "MCP [$Name]: unknown transport for recv"; return $null }
    }
}

function Disconnect-McpServer {
    <#
    .SYNOPSIS
    Disconnect from an MCP server and clean up resources.
    Port of bashagt mcp_disconnect_server().
    #>
    param([string]$Name)

    # Kill subprocess (stdio)
    $serverPid = $null
    if ($global:MCP_SERVER_PID -and $global:MCP_SERVER_PID.ContainsKey($Name)) {
        $serverPid = $global:MCP_SERVER_PID[$Name]
    }
    if ($serverPid) {
        Stop-ProcessTree $serverPid
    }

    # Close process and streams
    $proc = $null
    if ($global:MCP_SERVER_PROC -and $global:MCP_SERVER_PROC.ContainsKey($Name)) {
        $proc = $global:MCP_SERVER_PROC[$Name]
    }
    if ($proc -and -not $proc.HasExited) {
        try {
            $proc.Kill()
        } catch { }
    }

    $writer = $global:MCP_STREAM_WRITER[$Name]
    if ($writer) {
        try { $writer.Close() } catch { }
    }
    $reader = $global:MCP_STREAM_READER[$Name]
    if ($reader) {
        try { $reader.Close() } catch { }
    }

    # Clean temp files
    $tmpDir = $global:MCP_SERVER_DIR[$Name]
    if ($tmpDir -and (Test-Path $tmpDir)) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Remove PID tracking file
    if ($serverPid) {
        $trackFile = Join-Path ([System.IO.Path]::GetTempPath()) "poweragent_mcp_${PID}_${serverPid}"
        Remove-Item $trackFile -Force -ErrorAction SilentlyContinue
    }

    # Clear state
    $global:MCP_SERVER_PID.Remove($Name)
    $global:MCP_SERVER_DIR.Remove($Name)
    $global:MCP_SERVER_TOOLS.Remove($Name)
    $global:MCP_SERVER_CAPS.Remove($Name)
    $global:MCP_SERVER_READY.Remove($Name)
    $global:MCP_SERVER_URL.Remove($Name)
    $global:MCP_SERVER_TRANSPORT.Remove($Name)
    $global:MCP_SERVER_PROC.Remove($Name)
    $global:MCP_STREAM_WRITER.Remove($Name)
    $global:MCP_STREAM_READER.Remove($Name)
}

# ============================================================================
#  MCP Protocol Methods
# ============================================================================

function Initialize-McpServer {
    <#
    .SYNOPSIS
    Initialize the MCP protocol with a server (handshake).
    Port of bashagt mcp_initialize().
    #>
    param([string]$Name)

    $clientCaps = @{
        protocolVersion = "2024-11-05"
        capabilities    = @{
            tools     = @{}
            resources = @{ subscribe = $false }
            prompts   = @{}
        }
        clientInfo      = @{ name = "poweragent"; version = "0.1" }
    }

    $request = New-McpRequest "initialize" $clientCaps
    $requestJson = $request | ConvertTo-Json -Depth 10 -Compress

    $sendResult = Send-McpMessage $Name $requestJson
    if (-not $sendResult -and $global:MCP_SERVER_TRANSPORT[$Name] -eq "stdio") {
        return $false
    }

    $response = Receive-McpMessage $Name 15
    if (-not $response) { return $false }

    try {
        $resp = $response | ConvertFrom-Json

        # Check for error
        if ($resp.error -and $resp.error.message) {
            Write-Log "MCP [$Name]: init error: $($resp.error.message)"
            return $false
        }

        # Extract capabilities
        $proto = if ($resp.result.protocolVersion) { $resp.result.protocolVersion } else { "unknown" }
        $caps = if ($resp.result.capabilities) { $resp.result.capabilities | ConvertTo-Json -Depth 10 -Compress } else { "{}" }

        $global:MCP_SERVER_CAPS[$Name] = $caps
        Write-Log "MCP [$Name]: protocol=$proto"

        # Send initialized notification (fire-and-forget)
        $notify = New-McpNotification "notifications/initialized" @{}
        $notifyJson = $notify | ConvertTo-Json -Depth 10 -Compress
        Send-McpMessage $Name $notifyJson | Out-Null

        $global:MCP_SERVER_READY[$Name] = $true
        return $true
    } catch {
        Write-Log "MCP [$Name]: init response parse error: $_"
        return $false
    }
}

function Get-McpTools {
    <#
    .SYNOPSIS
    List tools from an MCP server and store with mcp__ prefix.
    Port of bashagt mcp_list_tools().
    #>
    param([string]$Name)

    $request = New-McpRequest "tools/list" @{}
    $requestJson = $request | ConvertTo-Json -Depth 10 -Compress

    $sendResult = Send-McpMessage $Name $requestJson
    if (-not $sendResult -and $global:MCP_SERVER_TRANSPORT[$Name] -eq "stdio") {
        return $false
    }

    $response = Receive-McpMessage $Name 15
    if (-not $response) { return $false }

    try {
        $resp = $response | ConvertFrom-Json
        $tools = @($resp.result.tools)

        # Prefix tool names with mcp__<server>__
        $prefixedTools = @()
        foreach ($tool in $tools) {
            $prefixedTool = $tool.PSObject.Copy()
            $prefixedTool.name = "mcp__${Name}__$($tool.name)"
            $prefixedTools += $prefixedTool
        }

        $toolsJson = $prefixedTools | ConvertTo-Json -Depth 10 -Compress
        $global:MCP_SERVER_TOOLS[$Name] = $toolsJson
        Write-Log "MCP [$Name]: $($prefixedTools.Count) tools listed"
        return $true
    } catch {
        Write-Log "MCP [$Name]: tools/list parse error: $_"
        return $false
    }
}

function Invoke-McpCallTool {
    <#
    .SYNOPSIS
    Call a tool on an MCP server.
    Port of bashagt mcp_call_tool().
    #>
    param(
        [string]$Name,
        [string]$Tool,
        $Arguments = @{}
    )

    Write-Log "DEBUG: [MCP] call_tool: server=$Name tool=$Tool"

    if ($Arguments -is [string]) {
        try { $Arguments = $Arguments | ConvertFrom-Json } catch { $Arguments = @{} }
    }

    $params = @{
        name      = $Tool
        arguments = $Arguments
    }

    $request = New-McpRequest "tools/call" $params
    $requestJson = $request | ConvertTo-Json -Depth 10 -Compress

    $sendResult = Send-McpMessage $Name $requestJson
    if (-not $sendResult -and $global:MCP_SERVER_TRANSPORT[$Name] -eq "stdio") {
        return "MCP Error: send failed for $Name/$Tool"
    }

    $requestTimeout = [int]$global:PA_MCP_REQUEST_TIMEOUT
    if ($requestTimeout -eq 0) { $requestTimeout = 60 }

    $response = Receive-McpMessage $Name $requestTimeout
    if (-not $response) { return "MCP Error: recv failed for $Name/$Tool" }

    try {
        $resp = $response | ConvertFrom-Json

        if ($resp.error -and $resp.error.message) {
            return "MCP Error [$Name/$Tool]: $($resp.error.message)"
        }

        # Extract text content
        $content = ""
        if ($resp.result.content) {
            foreach ($item in @($resp.result.content)) {
                if ($item.type -eq "text" -and $item.text) {
                    $content += $item.text + "`n"
                }
            }
        }

        if (-not $content) {
            $content = $resp.result | ConvertTo-Json -Depth 10 -Compress
        }

        return $content.TrimEnd()
    } catch {
        return "MCP Error [$Name/$Tool]: response parse error: $_"
    }
}

# ============================================================================
#  MCP Tool Integration
# ============================================================================

function Get-McpToolsJson {
    <#
    .SYNOPSIS
    Build aggregated tools JSON from all connected MCP servers.
    Port of bashagt mcp_build_tools_json().
    #>
    $allTools = @()

    if (-not $global:MCP_SERVER_TOOLS) {
        return "[]"
    }

    foreach ($name in $global:MCP_SERVER_TOOLS.Keys) {
        $ready = $false
        if ($global:MCP_SERVER_READY -and $global:MCP_SERVER_READY.ContainsKey($name)) {
            $ready = $global:MCP_SERVER_READY[$name] -eq $true
        }
        if (-not $ready) { continue }
        $toolsJson = $global:MCP_SERVER_TOOLS[$name]
        if (-not $toolsJson) { continue }

        try {
            $tools = $toolsJson | ConvertFrom-Json
            $allTools += @($tools)
        } catch { }
    }

    return $allTools | ConvertTo-Json -Depth 10
}

function Invoke-McpDispatchTool {
    <#
    .SYNOPSIS
    Dispatch a tool call to the appropriate MCP server.
    Port of bashagt mcp_dispatch_tool().
    #>
    param(
        [string]$Server,
        [string]$Tool,
        $Input
    )

    if (-not $global:MCP_SERVER_READY -or $global:MCP_SERVER_READY[$Server] -ne $true) {
        return "MCP server `"$Server`" is not connected"
    }

    return Invoke-McpCallTool $Server $Tool $Input
}

# ============================================================================
#  MCP Init / Shutdown
# ============================================================================

function Initialize-Mcp {
    <#
    .SYNOPSIS
    Initialize all configured MCP servers.
    Port of bashagt mcp_init().
    #>
    if ($global:PA_MCP_ENABLED -ne "true") { return }

    Import-McpConfig

    $serverCount = $global:MCP_SERVERS.Count
    if ($serverCount -eq 0) { return }

    Write-Log "DEBUG: [MCP] mcp_init: servers=$serverCount"

    foreach ($name in @($global:MCP_SERVERS.Keys)) {
        if ((Connect-McpServer $name) -and (Initialize-McpServer $name)) {
            if (-not (Get-McpTools $name)) {
                Write-Log "WARN: MCP [$name]: tools/list failed"
            }
            $global:MCP_CONNECTED_COUNT++
        }
    }

    Write-Log "MCP: $($global:MCP_CONNECTED_COUNT)/$($global:MCP_SERVERS.Count) server(s) connected"
}

function Stop-Mcp {
    <#
    .SYNOPSIS
    Shut down all MCP server connections.
    Port of bashagt mcp_shutdown().
    #>
    $pidCount = $global:MCP_SERVER_PID.Count
    Write-Log "DEBUG: MCP_SHUTDOWN servers=$pidCount"

    foreach ($name in @($global:MCP_SERVER_PID.Keys)) {
        Disconnect-McpServer $name
    }

    # Also disconnect SSE/HTTP servers (no PID but have DIR)
    foreach ($name in @($global:MCP_SERVER_DIR.Keys)) {
        Disconnect-McpServer $name
    }

    $global:MCP_CONNECTED_COUNT = 0
}

# ============================================================================
#  Slash Command Handlers for MCP
# ============================================================================

function Get-McpStatus {
    <#
    .SYNOPSIS
    Display MCP connection status (slash command: /mcp).
    #>
    $out = ""
    $serverCount = 0
    if ($global:MCP_SERVERS) { $serverCount = $global:MCP_SERVERS.Count }
    $connectedCount = if ($global:MCP_CONNECTED_COUNT) { $global:MCP_CONNECTED_COUNT } else { 0 }
    $out += "  MCP: ${connectedCount}/${serverCount} server(s) connected`n"

    if (-not $global:MCP_SERVERS) { return $out }

    foreach ($name in $global:MCP_SERVERS.Keys) {
        $ready = $null
        if ($global:MCP_SERVER_READY -and $global:MCP_SERVER_READY.ContainsKey($name)) {
            $ready = $global:MCP_SERVER_READY[$name]
        }
        $state = if ($ready -eq $true) { "[OK]" } else { "[!!]" }
        $transport = $null
        if ($global:MCP_SERVER_TRANSPORT -and $global:MCP_SERVER_TRANSPORT.ContainsKey($name)) {
            $transport = $global:MCP_SERVER_TRANSPORT[$name]
        }

        $toolsCount = 0
        if ($global:MCP_SERVER_TOOLS[$name]) {
            try {
                $tools = $global:MCP_SERVER_TOOLS[$name] | ConvertFrom-Json
                $toolsCount = @($tools).Count
            } catch { }
        }

        $out += "    $state $name"
        if ($ready -eq $true) {
            $out += " ($toolsCount tools, $transport)"
        }
        $out += "`n"
    }

    Write-Host $out
}

function Get-McpServerList {
    <#
    .SYNOPSIS
    List all configured MCP servers.
    #>
    $out = "  MCP servers:`n"

    foreach ($name in $global:MCP_SERVERS.Keys) {
        $cfg = $global:MCP_SERVERS[$name]
        $transport = "stdio"
        $cmd = ""
        $url = ""

        try {
            $cfgObj = $cfg | ConvertFrom-Json
            $transport = if ($cfgObj.transport) { $cfgObj.transport } else { "stdio" }
            $cmd = $cfgObj.command
            $url = $cfgObj.url
        } catch { }

        $out += "    $name - $transport"
        if ($cmd) { $out += " [$cmd]" }
        if ($url) { $out += " [$url]" }
        $out += "`n"
    }

    Write-Host $out
}

function Connect-McpServerByName {
    <#
    .SYNOPSIS
    Connect to a specific MCP server by name.
    #>
    param([string]$Name)

    $name = $Name.Trim() -split '\s+' | Select-Object -First 1
    if (-not $name) { Write-Host "  Usage: /mcp-connect <server_name>"; return }

    if (-not $global:MCP_SERVERS[$name]) {
        Write-Host "  Unknown server: $name" -ForegroundColor Red
        return
    }

    if ($global:MCP_SERVER_READY[$name] -eq $true) {
        Write-Host "  Already connected: $name" -ForegroundColor Yellow
        return
    }

    if ((Connect-McpServer $name) -and (Initialize-McpServer $name) -and (Get-McpTools $name)) {
        $global:MCP_CONNECTED_COUNT++
        Write-Host "  [OK] Connected: $name" -ForegroundColor Green
    } else {
        Write-Host "  [!!] Failed to connect: $name" -ForegroundColor Red
    }
}

function Disconnect-McpServerByName {
    <#
    .SYNOPSIS
    Disconnect from a specific MCP server by name.
    #>
    param([string]$Name)

    $name = $Name.Trim() -split '\s+' | Select-Object -First 1
    if (-not $name) { Write-Host "  Usage: /mcp-disconnect <server_name>"; return }

    if ($global:MCP_SERVER_READY[$name] -ne $true) {
        Write-Host "  Not connected: $name" -ForegroundColor Yellow
        return
    }

    Disconnect-McpServer $name
    $global:MCP_CONNECTED_COUNT--
    if ($global:MCP_CONNECTED_COUNT -lt 0) { $global:MCP_CONNECTED_COUNT = 0 }
    Write-Host "  Disconnected: $name"
}

function Get-McpToolList {
    <#
    .SYNOPSIS
    List tools from MCP servers.
    #>
    param([string]$Name)

    $name = $Name.Trim() -split '\s+' | Select-Object -First 1
    $out = ""

    if ($name) {
        $toolsJson = $global:MCP_SERVER_TOOLS[$name]
        if (-not $toolsJson) {
            Write-Host "  No tools for server: $name"
            return
        }
        try {
            $tools = @($toolsJson | ConvertFrom-Json)
            $out += "  $name ($($tools.Count) tools):`n"
            foreach ($t in $tools) {
                $desc = if ($t.description) { $t.description } else { "no description" }
                $out += "    - $($t.name) - $desc`n"
            }
        } catch {
            $out += "  ${name}: parse error`n"
        }
    } else {
        foreach ($sn in $global:MCP_SERVER_READY.Keys) {
            if ($global:MCP_SERVER_READY[$sn] -ne $true) { continue }
            $toolsJson = $global:MCP_SERVER_TOOLS[$sn]
            if (-not $toolsJson) { continue }
            try {
                $tools = @($toolsJson | ConvertFrom-Json)
                $out += "  $sn ($($tools.Count) tools):`n"
                foreach ($t in $tools) {
                    $out += "    - $($t.name)`n"
                }
            } catch { }
        }
    }

    Write-Host $out
}


# ============================================================================
#  Inlined: AgentLoop.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - AgentLoop.ps1
#  Section 11/11b: Agent Loop, Slash Commands, Adaptive Loop
#  PowerShell 5.1 port of bashagt Section 11 (lines 12516-13939)
#
#  Key Bash->PS differences:
#  - Custom readline -> PSReadLine (built-in) + Read-Host for simple input
#  - Trap/signals -> try/catch/finally + Register-EngineEvent
#  - while true loop -> do/until with Ctrl+C handling
# ============================================================================

# ── Agent Loop State ──
$global:SESSION_INPUT_TOKENS = 0
$global:SESSION_OUTPUT_TOKENS = 0
$global:TURN_COUNTER = 0
$global:NON_PRODUCTIVE_STREAK = 0
$global:_PLAN_PENDING = $false
$global:_INTERRUPTED = $false

# ── Plan System State (Item 11: plan_extract/auto_todo/handle_response) ──
$global:_PLAN_DEFERRED_MSG = ""
$global:_DEFERRED_FEEDBACK = ""
$global:_PLAN_STOP = 0

# ── Hook Context Buffer (ephemeral — cleared each turn) ──
$global:_HOOK_CONTEXT_BUFFER = ""

# ── Max Tokens Stuck Detection ──
$global:_TURN_MAX_TOKENS_HIT = 0
$global:DEFAULT_STUCK_THRESHOLD = 3

# ── Loop Detection State (CodeWhale LoopDetectionMiddleware) ──
$global:_TOOL_CALL_HISTORY = @()        # @{tool; args_hash; timestamp}
$global:_LOOP_DETECTION_ENABLED = $true

# ── Tool Result Dedup State (CodeWhale compact_tool_result_for_wire) ──
$global:_TOOL_RESULT_CACHE = @{}        # SHA256 → truncated_result
$global:TOOL_RESULT_CHAR_BUDGET = 12000 # 每个工具结果最大字符数

# ── Prompt Caching State (Anthropic cache_control markers) ──
$global:_CC = @{}                       # Cache state: sys_static, msg_prefix
$global:_CACHE_PROBE = @{
    state              = "probing"      # probing / active / inactive
    consecutive_misses = 0
    total_hits         = 0
    consecutive_hits   = 0
    total_probes       = 0
    inactive_since     = 0
}
$global:_CACHE_MARKER = @{ cache_control = @{ type = "ephemeral" } }
$global:CACHE_PROBE_MAX_MISSES = 3
$global:CACHE_PROBE_REPROBE    = 900

# ============================================================================
#  Slash Command Handlers
# ============================================================================

function Register-BuiltinSlashCommands {
    Register-Slash -Command "help" -Handler "Invoke-SlashHelp"
    Register-Slash -Command "clear" -Handler "Invoke-SlashClear"
    Register-Slash -Command "save" -Handler "Invoke-SlashSave"
    Register-Slash -Command "load" -Handler "Invoke-SlashLoad"
    Register-Slash -Command "compress" -Handler "Invoke-SlashCompress"
    Register-Slash -Command "status" -Handler "Invoke-SlashStatus"
    Register-Slash -Command "model" -Handler "Invoke-SlashModel"
    Register-Slash -Command "provider" -Handler "Invoke-SlashProvider"
    Register-Slash -Command "exit" -Handler "Invoke-SlashExit"
    Register-Slash -Command "safe" -Handler "Invoke-SlashSafe"
    Register-Slash -Command "trace" -Handler "Invoke-SlashTrace"
    Register-Slash -Command "undo" -Handler "Invoke-SlashUndoCmd"
    Register-Slash -Command "tasks" -Handler "Invoke-SlashTasks"
    Register-Slash -Command "memory" -Handler "Invoke-SlashMemory"
    Register-Slash -Command "remember" -Handler "Invoke-SlashRemember"
    Register-Slash -Command "skills" -Handler "Invoke-SlashSkills"
    Register-Slash -Command "mcp" -Handler "Invoke-SlashMcp"
}

function Invoke-SlashHelp {
    $hLine = [string][char]0x2500
    $esc = $global:ESC
    $rst = $global:RESET
    $bld = $global:BOLD
    $cyan = $global:CYAN
    $lcyan = $global:LIGHT_CYAN
    $dim = $global:DIM
    Write-Host ""
    Write-Host "  $([char]0x256D)$($hLine * 40)$([char]0x256E)"
    Write-Host "  $([char]0x26A1) ${bld}PowerAgent Commands${rst}"
    Write-Host "  $([char]0x2570)$($hLine * 40)$([char]0x256F)"
    $cmds = @(
        @("/help",     "Show this help"),
        @("/clear",    "Clear conversation history"),
        @("/save",     "Save conversation history"),
        @("/load",     "Load conversation history"),
        @("/compress", "Force context compression"),
        @("/status",   "Show session statistics"),
        @("/model",    "Show/select model (current provider)"),
        @("/provider",  "Switch provider & set API key"),
        @("/safe",     "Toggle safe mode"),
        @("/trace",    "Show trace log"),
        @("/undo",     "Undo last file modification"),
        @("/tasks",    "List TODO tasks"),
        @("/memory",   "Show memory network"),
        @("/remember", "Save to long-term memory"),
        @("/skills",   "List active skills"),
        @("/mcp",      "List MCP connections"),
        @("/exit",     "Exit PowerAgent")
    )
    foreach ($c in $cmds) {
        Write-Host "  ${lcyan}$($c[0].PadRight(15))${rst}$($c[1])"
    }
}

function Invoke-SlashClear {
    Clear-History
    Write-Host "${global:GREEN}History cleared.${global:RESET}"
}

function Invoke-SlashSave {
    Save-History
    Write-Host "${global:GREEN}History saved.${global:RESET}"
}

function Invoke-SlashLoad {
    Load-History
    Write-Host "${global:GREEN}History loaded ($($global:MESSAGES.Count) messages).${global:RESET}"
}

function Invoke-SlashCompress {
    Compress-Context
    $size = (Get-MessagesJson).Length
    Write-Host "${global:GREEN}Context compressed. Message JSON: $size bytes${global:RESET}"
}

function Invoke-SlashStatus {
    $tokens = Estimate-ContextTokens
    $window = [int]$global:PA_CONTEXT_WINDOW
    $pct = [Math]::Floor($tokens / $window * 100)
    $pctSafe = [Math]::Min($pct, 100)
    Write-Host ""
    Write-Host "  $([char]0x2699) $([char]27)[1mSession Status$([char]27)[0m"
    Write-UiDivider -Color "DarkGray"
    Write-Host "  ${global:LIGHT_BLUE}Model${global:RESET}          $($global:PA_MODEL)"
    Write-Host "  ${global:LIGHT_BLUE}Protocol${global:RESET}       $($global:PA_PROTOCOL)"
    Write-Host "  ${global:LIGHT_BLUE}Messages${global:RESET}       $($global:MESSAGES.Count)"
    # Context bar
    $barW = 20
    $filled = [Math]::Floor($barW * $pctSafe / 100)
    $empty = $barW - $filled
    $barColor = if ($pct -gt 75) { "91" } elseif ($pct -gt 50) { "93" } else { "92" }
    $bar = "${global:ESC}[${barColor}m$([string][char]0x2588 * $filled)${global:ESC}[90m$([string][char]0x2591 * $empty)${global:RESET}"
    Write-Host "  ${global:LIGHT_BLUE}Context${global:RESET}        $bar ${global:ESC}[93m$($pct)%${global:RESET} (~$tokens / $window)"
    Write-Host "  ${global:LIGHT_BLUE}Session input${global:RESET}  $($global:SESSION_INPUT_TOKENS) tokens"
    Write-Host "  ${global:LIGHT_BLUE}Session output${global:RESET} $($global:SESSION_OUTPUT_TOKENS) tokens"
    Write-Host "  ${global:LIGHT_BLUE}Turn counter${global:RESET}   $($global:TURN_COUNTER)"
    $safeIcon = if ($global:PA_SAFE_MODE) { "$([char]0x2718) ON" } else { "$([char]0x2714) OFF" }
    $safeColor = if ($global:PA_SAFE_MODE) { "${global:YELLOW}" } else { "${global:ESC}[90m" }
    Write-Host "  ${global:LIGHT_BLUE}Safe mode${global:RESET}      $($safeColor)$safeIcon${global:RESET}"
    Write-Host "  ${global:LIGHT_BLUE}Trace head${global:RESET}     $($global:TRACE_HEAD)"
    $pressure = Test-ContextWindowPressure
    $pIcon = switch ($pressure) { "critical" { "$([char]0x2718) critical" } "warn" { "$([char]0x26A0) warn" } default { "$([char]0x2714) ok" } }
    $pColor = switch ($pressure) { "critical" { "${global:RED}" } "warn" { "${global:YELLOW}" } default { "${global:GREEN}" } }
    Write-Host "  ${global:LIGHT_BLUE}Pressure${global:RESET}       $($pColor)$pIcon${global:RESET}"
}

function Invoke-SlashProvider {
    param([string]$CommandInput)
    $esc = $global:ESC; $rst = $global:RESET; $bld = $global:BOLD
    $cyan = $global:CYAN; $lcyan = $global:LIGHT_CYAN; $dim = $global:DIM
    $green = $global:GREEN; $yellow = $global:YELLOW; $red = $global:RED

    # ── 列出所有供应商 ──
    $curProvider = Get-CurrentProvider
    Write-Host ""
    Write-Host "  $bld$([char]0x2699) Select Provider$rst"
    Write-Host "  $([char]0x2500) * 42"
    $idx = 1
    $providerKeys = @($global:PROVIDERS.Keys)
    foreach ($pk in $providerKeys) {
        $p = $global:PROVIDERS[$pk]
        $marker = if ($pk -eq $curProvider) { "$green$([char]0x2714)$rst" } else { " " }
        $keyHint = ""
        if ($global:_CFG.ContainsKey("provider_key_$pk")) {
            $kv = "$($global:_CFG["provider_key_$pk"])"
            if ($kv.Length -gt 8) { $keyHint = "${dim}($($kv.Substring(0,4))...$($kv.Substring($kv.Length-4)))$rst" }
            else { $keyHint = "${dim}(****)$rst" }
        }
        $modelList = $p.models -join ", "
        Write-Host "  $marker ${lcyan}$idx.$rst $bld$($p.name)$rst  ${dim}$modelList$rst  $keyHint"
        $idx++
    }
    Write-Host ""

    # ── 用户选择 ──
    Write-Host "  ${dim}Enter number (1-$($providerKeys.Count)) or Esc to cancel:$rst " -NoNewline
    $choice = Read-Host

    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    $num = 0
    if (-not [int]::TryParse($choice, [ref]$num) -or $num -lt 1 -or $num -gt $providerKeys.Count) {
        Write-Host "  ${red}Invalid choice.$rst"
        return
    }

    $selected = $providerKeys[$num - 1]
    $provider = $global:PROVIDERS[$selected]

    # ── 输入 API Key ──
    $existingKey = ""
    if ($global:_CFG.ContainsKey("provider_key_$selected")) {
        $existingKey = "$($global:_CFG["provider_key_$selected"])"
    }
    $keyPrompt = if ($existingKey) { "  API Key [$($existingKey.Substring(0,[Math]::Min(4,$existingKey.Length)))...] (Enter to keep): " } else { "  API Key: " }
    Write-Host $keyPrompt -NoNewline
    $apiKey = Read-Host

    if ([string]::IsNullOrWhiteSpace($apiKey) -and $existingKey) {
        $apiKey = $existingKey
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "  ${red}API Key required. Aborted.$rst"
        return
    }

    # ── 保存并切换 ──
    try {
        # 保存 provider key 到 settings.json
        Save-Setting "provider_key_$selected" $apiKey
        Save-Setting "provider" $selected
        Save-Setting "api_key" $apiKey
        # 直接使用完整 URL (baseUrl 已含 /chat/completions)
        Save-Setting "api_url" $provider.baseUrl
        Save-Setting "model" $provider.models[0]

        # 立即更新全局变量
        $global:PA_API_KEY = $apiKey
        $global:PA_API_URL = $provider.baseUrl
        $global:PA_MODEL = $provider.models[0]

        Write-Host ""
        Write-Host "  $green$([char]0x2714) Switched to $($provider.name)$rst"
        Write-Host "  ${cyan}Model:$rst $($provider.models[0])  ${dim}($($provider.models -join ', '))$rst"
        Write-Host "  ${cyan}Endpoint:$rst $($provider.baseUrl)"
        Write-Host "  ${dim}Use /model to change model within this provider.$rst"
    } catch {
        Write-Host "  ${red}Failed to save: $_$rst"
    }
}

function Invoke-SlashModel {
    param([string]$CommandInput)
    $esc = $global:ESC; $rst = $global:RESET; $bld = $global:BOLD
    $cyan = $global:CYAN; $lcyan = $global:LIGHT_CYAN; $dim = $global:DIM
    $green = $global:GREEN; $yellow = $global:YELLOW; $red = $global:RED

    # 如果有参数直接设置
    $parts = $CommandInput -split '\s+', 3
    if ($parts.Count -ge 2 -and $parts[1] -notmatch '^\d+$') {
        $newModel = $parts[1]
        $force = $false
        if ($parts.Count -ge 3 -and $parts[2] -eq '!') { $force = $true }
        # 校验模型名是否在当前供应商的候选列表中
        $_pv = Get-CurrentProvider
        if ((-not $force) -and $global:PROVIDERS.Contains($_pv)) {
            $validModels = @($global:PROVIDERS[$_pv].models)
            if ($validModels.Count -gt 0 -and $validModels -notcontains $newModel) {
                Write-Host "  $yellow$([char]0x26A0) Warning: '$newModel' is not in $_pv's model list.$rst"
                Write-Host "  ${dim}Valid models: $($validModels -join ', ')$rst"
                Write-Host "  ${dim}Use /model <number> to select, or /model $newModel ! to force.$rst"
                return
            }
        }
        $global:PA_MODEL = $newModel
        Save-Setting "model" $newModel
        Write-Host "  $green$([char]0x2714) Model set to: $($global:PA_MODEL)$rst"
        return
    }

    # ── 获取当前供应商的候选模型 ──
    $curProvider = Get-CurrentProvider
    $models = @()
    $providerName = "Custom"

    if ($global:PROVIDERS.Contains($curProvider)) {
        $p = $global:PROVIDERS[$curProvider]
        $models = @($p.models)
        $providerName = $p.name
    } else {
        # 自定义供应商 — 只显示当前模型
        Write-Host "  Current: $bld$($global:PA_MODEL)$rst  ${dim}($providerName | $($global:PA_API_URL))$rst"
        Write-Host "  ${dim}Use /model <name> to switch, or /provider to select a provider.$rst"
        return
    }

    Write-Host ""
    Write-Host "  $bld$([char]0x2699) Select Model  ${dim}[$providerName]$rst"
    Write-Host "  $([char]0x2500) * 35"

    for ($i = 0; $i -lt $models.Count; $i++) {
        $marker = if ($models[$i] -eq $global:PA_MODEL) { "$green$([char]0x2714)$rst" } else { " " }
        Write-Host "  $marker ${lcyan}$($i+1).$rst $bld$($models[$i])$rst"
    }
    Write-Host ""

    # 如果命令带了数字参数（如 /model 2）
    if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') {
        $num = [int]$parts[1]
        if ($num -ge 1 -and $num -le $models.Count) {
            $global:PA_MODEL = $models[$num - 1]
            Save-Setting "model" $global:PA_MODEL
            Write-Host "  $green$([char]0x2714) Model set to: $($global:PA_MODEL)$rst"
            return
        }
    }

    Write-Host "  ${dim}Enter number (1-$($models.Count)) or Enter to keep current:$rst " -NoNewline
    $choice = Read-Host

    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $models.Count) {
        $global:PA_MODEL = $models[$num - 1]
        Save-Setting "model" $global:PA_MODEL
        Write-Host "  $green$([char]0x2714) Model set to: $($global:PA_MODEL)$rst"
    } else {
        Write-Host "  ${red}Invalid choice.$rst"
    }
}

function Invoke-SlashExit {
    $global:_EXIT_REQUESTED = $true
}

function Invoke-SlashSafe {
    $global:PA_SAFE_MODE = -not $global:PA_SAFE_MODE
    $state = if ($global:PA_SAFE_MODE) { "ON" } else { "OFF" }
    $color = if ($global:PA_SAFE_MODE) { "Yellow" } else { "Gray" }
    Write-Host "Safe mode: $state" -ForegroundColor $color
}

function Invoke-SlashTrace {
    $frames = Trace-Log -Count 20
    if ($frames.Count -eq 0) {
        Write-Host "No trace frames." -ForegroundColor Gray
        return
    }
    Write-Host "${global:BOLD}Recent Trace:${global:RESET}"
    foreach ($f in $frames) {
        Write-Host "  [$($f.id)] $($f.operation) $($f.path)" -ForegroundColor Gray
    }
}

function Invoke-SlashUndoCmd {
    $result = Trace-Undo -Steps 1
    if ($result.status -eq "ok") {
        Write-Host "${global:GREEN}Undone: $($result.undone | ConvertTo-Json -Compress)${global:RESET}"
    } else {
        Write-Host $result.error -ForegroundColor Red
    }
}

function Invoke-SlashTasks {
    if ($global:TODOS.Count -eq 0) {
        Write-Host "No tasks." -ForegroundColor Gray
        return
    }
    Write-Host "${global:BOLD}Tasks:${global:RESET}"
    foreach ($t in $global:TODOS) {
        $color = switch ($t.status) {
            "completed" { "Green" }
            "in_progress" { "Yellow" }
            "failed" { "Red" }
            default { "White" }
        }
        Write-Host "  [$($t.status)] $($t.id): $($t.title)" -ForegroundColor $color
    }
}

function Invoke-SlashMemory {
    if ($global:MEMORY_DATA) {
        $st = $global:MEMORY_DATA.short_term.Count
        $lt = $global:MEMORY_DATA.long_term.Count
        $wk = $global:MEMORY_DATA.work.Count
        Write-Host "Memory Network: ${lt} long-term | ${st} short-term | ${wk} work" -ForegroundColor Cyan
        if ($wk -gt 0) {
            Write-Host "${global:BOLD}[Work Memory]${global:RESET}"
            foreach ($w in $global:MEMORY_DATA.work) {
                Write-Host "  $($w.content)" -ForegroundColor Gray
            }
        }
        $top = @($global:MEMORY_DATA.long_term | Sort-Object -Property priority -Descending | Select-Object -First 5)
        if ($top.Count -gt 0) {
            Write-Host "${global:BOLD}[Top Long-Term]${global:RESET}"
            foreach ($m in $top) {
                Write-Host "  [$($m.priority)] $($m.content)" -ForegroundColor Gray
            }
        }
    } elseif ($global:MEMORY_POOL) {
        Write-Host $global:MEMORY_POOL.Substring(0, [Math]::Min(500, $global:MEMORY_POOL.Length))
    } else {
        Write-Host "No memories loaded." -ForegroundColor Gray
    }
}

function Invoke-SlashRemember {
    param([string]$Text = $args -join " ")
    if (-not $Text) {
        Write-Host "Usage: /remember <text to save>" -ForegroundColor Yellow
        return
    }
    Write-Memory -Content $Text -Type "long_term" -Priority 90 -Tags @("user-save")
    Save-MemoryNetwork
    Write-Host "${global:GREEN}Saved to long-term memory.${global:RESET}"
}

function Invoke-SlashSkills {
    if ($global:ACTIVE_SKILLS.Count -eq 0) {
        Write-Host "No active skills." -ForegroundColor Gray
        return
    }
    Write-Host "${global:BOLD}Active Skills:${global:RESET}"
    foreach ($s in $global:ACTIVE_SKILLS) {
        Write-Host "  - $s" -ForegroundColor White
    }
}

function Invoke-SlashMcp {
    if ($global:MCP_SERVERS.Count -eq 0) {
        Write-Host "No MCP servers connected." -ForegroundColor Gray
        return
    }
    Write-Host "${global:BOLD}MCP Servers:${global:RESET}"
    foreach ($srv in $global:MCP_SERVERS.Keys) {
        Write-Host "  - $srv" -ForegroundColor White
    }
}

# ============================================================================
#  Prompt Caching Functions (Anthropic cache_control markers)
#  Port of bashagt _cc_invalidate() (L5812) and _cache_probe_feedback() (L5897)
#  Cache markers are ONLY emitted for Anthropic protocol — OpenAI/DeepSeek
#  ignores them, so we skip marker injection entirely for non-Anthropic APIs.
# ============================================================================

function Invoke-CcInvalidate {
    <#
    .SYNOPSIS
    Invalidate cached prompt prefixes.
    Port of bashagt _cc_invalidate() (L5812-5820).
    #>
    param([string[]]$Names)

    foreach ($name in $Names) {
        switch ($name) {
            "system" { $global:_CC["sys_static"] = "" }
            "msgs"   {
                $global:_CC["msg_prefix"] = ""
                Write-Log "DEBUG" "[CACHE] invalidate: msgs"
            }
        }
    }
}

function Get-CacheProbeFeedback {
    <#
    .SYNOPSIS
    Monitor Anthropic API response for cache hit/miss metrics.
    Port of bashagt _cache_probe_feedback() (L5897).
    Updates _CACHE_PROBE state: probing → active → inactive.
    Returns probe state string.
    #>
    param([hashtable]$Response)

    # 只处理 Anthropic 协议的响应
    if ($global:PA_PROTOCOL -ne "anthropic") {
        return $global:_CACHE_PROBE.state
    }

    # 从 Response.usage 中提取缓存指标
    $usage = $null
    if ($Response -and $Response.ContainsKey("usage") -and $Response["usage"]) {
        $usage = $Response["usage"]
    }

    $cacheCreation = 0
    $cacheRead     = 0

    if ($usage) {
        # Anthropic 返回 cache_creation_input_tokens 和 cache_read_input_tokens
        if ($usage -is [hashtable]) {
            if ($usage.ContainsKey("cache_creation_input_tokens")) {
                $cacheCreation = [int]$usage["cache_creation_input_tokens"]
            }
            if ($usage.ContainsKey("cache_read_input_tokens")) {
                $cacheRead = [int]$usage["cache_read_input_tokens"]
            }
        } elseif ($usage.PSObject) {
            # PSCustomObject (从 ConvertFrom-Json 来的)
            if ($usage.PSObject.Properties["cache_creation_input_tokens"]) {
                $cacheCreation = [int]$usage.cache_creation_input_tokens
            }
            if ($usage.PSObject.Properties["cache_read_input_tokens"]) {
                $cacheRead = [int]$usage.cache_read_input_tokens
            }
        }
    }

    $probe = $global:_CACHE_PROBE
    $probe.total_probes++

    $isHit = ($cacheRead -gt 0 -or $cacheCreation -eq 0)

    if ($isHit) {
        $probe.consecutive_misses = 0
        $probe.consecutive_hits++
        $probe.total_hits++

        # probing → active: 首次 cache hit
        if ($probe.state -eq "probing") {
            $probe.state = "active"
            Write-Log "DEBUG" "[CACHE] probe → active (hit: read=$cacheRead creation=$cacheCreation)"
        }
    } else {
        # Cache miss (有 cache_creation 但无 cache_read)
        $probe.consecutive_misses++
        $probe.consecutive_hits = 0

        # active → inactive: 连续 MAX_MISSES 次未命中
        if ($probe.state -eq "active" -and $probe.consecutive_misses -ge $global:CACHE_PROBE_MAX_MISSES) {
            $probe.state = "inactive"
            $probe.inactive_since = $probe.total_probes
            Write-Log "DEBUG" "[CACHE] active → inactive (consecutive misses: $($probe.consecutive_misses))"
        }

        # probing 阶段记录 miss
        if ($probe.state -eq "probing") {
            Write-Log "DEBUG" "[CACHE] probe miss #$($probe.consecutive_misses) (creation=$cacheCreation)"
        }
    }

    # inactive → reprobe: 超过 REPROBE 间隔后自动恢复探测
    if ($probe.state -eq "inactive") {
        $elapsed = $probe.total_probes - $probe.inactive_since
        if ($elapsed -ge $global:CACHE_PROBE_REPROBE) {
            $probe.state = "probing"
            $probe.consecutive_misses = 0
            Write-Log "DEBUG" "[CACHE] inactive → probing (reprobe after $elapsed probes)"
        }
    }

    $global:_CACHE_PROBE = $probe
    return $probe.state
}

# ============================================================================
#  Dynamic Context Assembly (Item 14)
#  PowerShell 5.1 port of bashagt _pe_assemble_context()
#  Gathers real environment info at runtime and returns a context string
#  that is injected via _HOOK_CONTEXT_BUFFER into the API request.
# ============================================================================

function Build-DynamicContext {
    <#
    .SYNOPSIS
    组装动态环境上下文：工作目录、Git 状态、平台、Shell、模型、时间、
    可选的 Memory 和 TODO 上下文。
    返回拼接后的字符串，供 _HOOK_CONTEXT_BUFFER 注入。
    #>

    # ── 环境基础信息 ──
    $ctx = @()
    $ctx += "Working directory: $(Get-Location)"

    # Git 检查（容错：git 可能未安装）
    $gitRepo = "no"
    try {
        $null = git rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -eq 0) { $gitRepo = "yes" }
    } catch {
        # git 不存在或执行失败 — 保持 "no"
    }
    $ctx += "Git repository: $gitRepo"

    # 平台信息
    $ctx += "Platform: $($env:OS) ($($env:PROCESSOR_ARCHITECTURE))"
    $ctx += "Shell: PowerShell $($PSVersionTable.PSVersion)"
    $ctx += "Model: $($global:PA_MODEL)"
    $ctx += "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    # ── Memory 上下文（如果可用）──
    $memoryCtx = ""
    if (Get-Command Build-MemoryContext -ErrorAction SilentlyContinue) {
        try { $memoryCtx = Build-MemoryContext } catch { }
    }
    if ($memoryCtx) { $ctx += ""; $ctx += $memoryCtx }

    # ── TODO 上下文（如果可用）──
    $todoCtx = ""
    if (Get-Command Build-TodoContext -ErrorAction SilentlyContinue) {
        try { $todoCtx = Build-TodoContext } catch { }
    }
    if ($todoCtx) { $ctx += ""; $ctx += $todoCtx }

    return ($ctx -join "`n")
}

# ============================================================================
#  Agent Loop: Run Turn
# ============================================================================

function Invoke-RunTurn {
    <#
    .SYNOPSIS
    Single user interaction turn.
    Port of bashagt run_turn() (L12981).
    Includes hook system: pre_turn, post_response, post_tool, on_stuck.
    Includes: thinking-only retry, deferred content, non-productive streak.
    #>
    param([string]$UserInput = "")

    # ── Read input if not provided ──
    if (-not $UserInput) {
        Write-Host "" -NoNewline
        try {
            # 彩色提示符: ▸ turn N │ model ▸
            $turnN = $global:TURN_COUNTER + 1
            $modelShort = if ($global:PA_MODEL) { ($global:PA_MODEL -split '-')[-1] } else { "?" }
            $esc = $global:ESC
            $promptStr = "${esc}[36m$([char]0x25B8) ${esc}[1mturn $turnN${esc}[0m${esc}[90m │ ${esc}[2m$modelShort${esc}[0m ${esc}[36m$([char]0x25B8)${esc}[0m "
            # 尝试使用带补全的输入；若 [Console] 不可用则回退 Read-Host
            # 注意：$UserInput 参数类型为 [string]，$null 赋给 [string] 会变成 ""
            # 所以用无类型的 $rawInput 捕获原始返回值，先检查 $null 再赋值
            try {
                $null = [Console]::IsOutputRedirected  # 测试 Console 可用性
                if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) {
                    $rawInput = Read-Host -Prompt $promptStr
                } else {
                    $rawInput = Read-HostWithCompletion -PromptStr $promptStr
                }
            } catch {
                $rawInput = Read-Host -Prompt $promptStr
            }
        } catch {
            # 非交互模式/管道 EOF — Read-Host 抛异常或返回 null
            $global:_EXIT_REQUESTED = $true
            return
        }
        # 输入为 $null（Ctrl+C / stdin 关闭）— 弹出确认对话框
        if ($null -eq $rawInput) {
            $wantExit = Request-ExitConfirm -Message "Ctrl+C 已中断"
            if ($wantExit) {
                $global:_EXIT_REQUESTED = $true
                return
            } else {
                $global:_INTERRUPTED = $false
                return
            }
        }
        # 将正常输入赋给 [string] 类型的 $UserInput 参数（$null 已在上方处理）
        $UserInput = $rawInput
    }

    $UserInput = $UserInput.Trim()
    if ([string]::IsNullOrWhiteSpace($UserInput)) { return }

    # ── 打印用户输入分割线 ──
    Write-UiDivider -Label "用户输入" -Color "LightBlue" -Icon ([char]0x25B8) -Timestamp
    Write-Host "  $UserInput"
    Write-UiDivider -Color "LightBlue"

    # ── Slash command dispatch ──
    if ($UserInput.StartsWith("/")) {
        $dispatched = Invoke-SlashDispatch $UserInput
        if ($dispatched) { return }
        Write-Host "Unknown command. Type /help for available commands." -ForegroundColor Yellow
        return
    }

    # ── Check context pressure before API call ──
    $pressure = Test-ContextWindowPressure
    if ($pressure -in @("warn", "critical")) {
        Write-Log "WARN: Context pressure=$pressure - auto-compressing"
        Compress-Context
    }

    # ── Add user message ──
    Add-UserText $UserInput

    # ── Turn initialization ──
    $global:TURN_COUNTER++
    $global:_HOOK_CONTEXT_BUFFER = ""       # Ephemeral hook injection buffer — cleared each turn
    $global:_TURN_MAX_TOKENS_HIT = 0        # Reset max_tokens hit counter
    $global:_PLAN_STOP = 0                  # Reset plan stop flag (Item 11)
    $global:_DEFERRED_FEEDBACK = ""         # Reset deferred feedback (Item 11)
    $script:_thinkingOnlyRetry = 0          # Reset thinking-only retry counter

    # ── Item 4: Rules reminder injection (every turn, ephemeral) ──
    if ($global:_RULES_REMINDER_TEXT) {
        $global:_HOOK_CONTEXT_BUFFER += "`n" + $global:_RULES_REMINDER_TEXT
    }

    # ── Item 14: Dynamic context assembly (environment info) ──
    try {
        $dynCtx = Build-DynamicContext
        if ($dynCtx) {
            $global:_HOOK_CONTEXT_BUFFER += "`n" + $dynCtx
        }
    } catch {
        Write-Log "WARN: Build-DynamicContext failed: $_"
    }

    # ── Item 2: pre_turn hook — situational context injection ──
    $ctxTokens = Estimate-ContextTokens
    $ctxWindow = [int]$global:PA_CONTEXT_WINDOW
    $ctxPct = 0
    if ($ctxWindow -gt 0) {
        $ctxPct = [Math]::Floor($ctxTokens / $ctxWindow * 100)
    }
    $activeTodos = 0
    if ($global:TODOS) {
        $activeTodos = @($global:TODOS | Where-Object { $_.status -ne "completed" }).Count
    }
    $hookCtx = @{
        context = @{ used = $ctxTokens; limit = $ctxWindow; pct = $ctxPct }
        turn = @{ current = $global:TURN_COUNTER; non_productive_streak = $global:NON_PRODUCTIVE_STREAK }
        todos = @{ active = $activeTodos }
        goal = $UserInput
    }
    $hookResults = Invoke-HookFire -Point "pre_turn" -Context $hookCtx
    if ($hookResults -and $hookResults -is [array]) {
        foreach ($item in $hookResults) {
            if ($item -is [hashtable] -and $item.inject -eq $true -and $item.content) {
                $global:_HOOK_CONTEXT_BUFFER += $item.content + "`n"
            }
        }
    }

    # ── Build API request (使用统一的 Build-ApiRequestBody) ──
    $tools = Build-RequestTools
    $bodyJson = Build-ApiRequestBody -Tools $tools -ThinkingBudget ([int]$global:PA_THINKING_BUDGET)

    $headers = Get-ApiHeaders

    # ── Turn loop: call API, dispatch tools, repeat ──
    $continueLoop = $true
    $toolUseCount = 0
    $toolDoneIdx = 0          # Phase 2: 跟踪当前已完成的工具数
    $script:_firstApiResponse = $true   # 用于控制分割线只打印一次

    # ── 启动 ESC 中断监测 ──
    Start-EscMonitor

    while ($continueLoop) {
        # ── API Call ──
        Start-SpinnerBg -Message "思考中"

        $apiResult = Invoke-ApiCall -RequestBody $bodyJson -Url $global:PA_API_URL -Headers $headers

        Stop-SpinnerBg

        # ── 中断检测（API 调用期间） ──
        # ESC: 仅中止当前操作，返回输入等待
        if (Test-EscInterrupt) {
            Write-Host ""
            Write-Host "  $([char]0x26A0) $([char]27)[33m操作已中断 (ESC)$([char]27)[0m"
            $global:_INTERRUPTED = $false
            if ($script:_deferredContent) {
                Add-AssistantMessage @($script:_deferredContent)
                $script:_deferredContent = $null
            }
            Stop-EscMonitor
            return
        }
        # Ctrl+C: 设置退出请求标志，由 Start-AgentLoop 弹出确认对话框
        if (Test-CtrlCInterrupt) {
            Stop-EscMonitor
            $global:_CTRL_C_EXIT_REQUESTED = $true
            if ($script:_deferredContent) {
                Add-AssistantMessage @($script:_deferredContent)
                $script:_deferredContent = $null
            }
            return
        }

        if (-not $apiResult.Success) {
            # ── 区分 ESC / Ctrl+C 中止和真正的 API 错误 ──
            if ($apiResult.Error -match "exit=7" -or $apiResult.Error -match "ESC aborted") {
                Write-Host ""
                Write-Host "  $([char]0x26A0) $([char]27)[33m操作已中断 (ESC)$([char]27)[0m"
                $global:_INTERRUPTED = $false
                if ($script:_deferredContent) {
                    Add-AssistantMessage @($script:_deferredContent)
                    $script:_deferredContent = $null
                }
                Stop-EscMonitor
                return
            }
            if ($apiResult.Error -match "exit=8" -or $apiResult.Error -match "Ctrl\+C aborted" -or $apiResult.AbortType -eq "Ctrl+C aborted") {
                # Ctrl+C 中止：设置标志，由外层 Start-AgentLoop 处理确认对话框
                Stop-EscMonitor
                $global:_CTRL_C_EXIT_REQUESTED = $true
                if ($script:_deferredContent) {
                    Add-AssistantMessage @($script:_deferredContent)
                    $script:_deferredContent = $null
                }
                return
            }
            Write-Host "  $([char]0x2718) $([char]27)[31mAPI error: $($apiResult.Error)$([char]27)[0m"
            Stop-EscMonitor
            return
        }

        # ── Accumulate tokens ──
        $global:SESSION_INPUT_TOKENS += $apiResult.InputTokens
        $global:SESSION_OUTPUT_TOKENS += $apiResult.OutputTokens

        # ── Prompt Caching: process cache feedback from API response ──
        $cacheFeedbackResp = @{
            usage = @{
                input_tokens               = $apiResult.InputTokens
                output_tokens              = $apiResult.OutputTokens
                cache_creation_input_tokens = 0
                cache_read_input_tokens     = 0
            }
        }
        # 从原始响应中提取缓存指标（如果有的话）
        if ($apiResult.ContainsKey("RawResponse") -and $apiResult.RawResponse) {
            try {
                $rawResp = $apiResult.RawResponse | ConvertFrom-Json
                if ($rawResp.usage) {
                    if ($rawResp.usage.cache_creation_input_tokens) {
                        $cacheFeedbackResp.usage["cache_creation_input_tokens"] = [int]$rawResp.usage.cache_creation_input_tokens
                    }
                    if ($rawResp.usage.cache_read_input_tokens) {
                        $cacheFeedbackResp.usage["cache_read_input_tokens"] = [int]$rawResp.usage.cache_read_input_tokens
                    }
                }
            } catch {
                # 忽略 JSON 解析错误 — 缓存反馈不是关键路径
            }
        }
        Get-CacheProbeFeedback -Response $cacheFeedbackResp | Out-Null

        # ── Process content blocks ──
        $toolUseBlocks = @()
        $visibleText = ""
        $thinkingText = ""

        foreach ($block in $apiResult.ContentBlocks) {
            if ($block.type -eq "text") {
                $visibleText += $block.text
            } elseif ($block.type -eq "thinking") {
                $thinkingText += $block.thinking
            } elseif ($block.type -eq "tool_call" -or $block.type -eq "tool_use") {
                $toolUseBlocks += $block
            }
        }

        # ── Show thinking status ──
        if ($script:_firstApiResponse) {
            Write-UiDivider -Label "智能体思考" -Color "LightBlue" -Icon ([char]0x2726) -Timestamp
            $script:_firstApiResponse = $false
        }
        if ($thinkingText -and $global:PA_SHOW_THINKING -eq "status") {
            Write-Host "  $([char]27)[2m$([char]0x2726) thinking...($($thinkingText.Length) chars)$([char]27)[0m"
        } elseif ($thinkingText -and $global:PA_SHOW_THINKING -eq "full") {
            Write-Host "  $([char]27)[2m$([char]0x2726) $thinkingText$([char]27)[0m"
        }

        # ── Show visible text ──
        if ($visibleText) {
            Write-UiDivider -Label "智能体回复" -Color "LightBlue" -Icon ([char]0x2726) -Timestamp
            Write-MarkdownLight $visibleText
            Write-UiDivider -Color "LightBlue"
        }

        # ── Item 10: Deferred content — store assistant message for later ──
        $script:_deferredContent = $apiResult.ContentBlocks

        # ── Check stop reason ──
        if ($apiResult.StopReason -eq "end_turn") {
            # ── Item 10: Deferred content — commit assistant message ──
            if ($script:_deferredContent) {
                Add-AssistantMessage @($script:_deferredContent)
                $script:_deferredContent = $null
            }

            # ── Prompt Caching: invalidate msg prefix after assistant message ──
            Invoke-CcInvalidate -Names @("msgs")

            # ── Item 8: Thinking-only retry (bashagt line 13206) ──
            if (-not $visibleText -and $toolUseBlocks.Count -eq 0 -and $thinkingText) {
                if ($script:_thinkingOnlyRetry -lt 1) {
                    $script:_thinkingOnlyRetry++
                    Write-Host "  $([char]0x26A0) $([char]27)[33mModel produced only internal reasoning. Auto-continuing...$([char]27)[0m"
                    # Add prompt for visible output
                    Add-UserText "Your last response contained only internal reasoning with no visible text or tool calls. Please produce visible output — either text or tool calls. Do not end_turn with only thinking."
                    # Rebuild request for retry
                    $bodyJson = Build-ApiRequestBody -Tools $tools -ThinkingBudget ([int]$global:PA_THINKING_BUDGET)
                    $headers = Get-ApiHeaders
                    continue
                }
                Write-Host "  $([char]0x2726) $([char]27)[2mModel finished thinking but produced no text or tools.$([char]27)[0m"
            }

            # ── Item 3: post_response hook — reflection & intervention ──
            $toolsCalled = @($toolUseBlocks | ForEach-Object { $_.name })
            $respHookCtx = @{
                stop_reason = $apiResult.StopReason
                tools_called = $toolsCalled
                non_productive_streak = $global:NON_PRODUCTIVE_STREAK
                turn = $global:TURN_COUNTER
                tokens = @{ in = $apiResult.InputTokens; out = $apiResult.OutputTokens }
            }
            $respHookResults = Invoke-HookFire -Point "post_response" -Context $respHookCtx
            if ($respHookResults -and $respHookResults -is [array]) {
                foreach ($item in $respHookResults) {
                    if ($item -is [hashtable] -and $item.inject_reflection -eq $true -and $item.reflection_prompt) {
                        $global:_HOOK_CONTEXT_BUFFER += $item.reflection_prompt + "`n"
                    }
                }
            }

            $continueLoop = $false
            # Phase 2: 回合结束 — 显示完成状态栏（带最后工具耗时）
            $lastElapsed = if ($global:_LAST_SPINNER_ELAPSED) { $global:_LAST_SPINNER_ELAPSED } else { 0 }
            Write-StatusBar -State "done" -ToolDone $toolDoneIdx -ToolTotal $toolUseCount -Elapsed $lastElapsed
            Write-Host ""   # 状态栏换行，确保后续输出不在同一行
            # Note: end_turn with no tool calls is non-productive — do NOT reset streak here

        } elseif ($apiResult.StopReason -eq "tool_use" -and $toolUseBlocks.Count -gt 0) {
            $toolUseCount += $toolUseBlocks.Count

            # ── 硬上限: 单轮工具调用超过 30 次强制终止 ──
            $global:DEFAULT_TOOL_HARD_LIMIT = 30
            if ($toolUseCount -ge $global:DEFAULT_TOOL_HARD_LIMIT) {
                if ($script:_deferredContent) {
                    Add-AssistantMessage @($script:_deferredContent)
                    $script:_deferredContent = $null
                }
                $synthHard = @()
                foreach ($tb in $toolUseBlocks) {
                    $synthHard += @{
                        type = "tool_result"
                        tool_use_id = $tb.id
                        content = @(@{ type = "text"; text = "你已在本轮调用了 $toolUseCount 次工具，超过上限 ($($global:DEFAULT_TOOL_HARD_LIMIT))。请立即用已有信息总结回答。不要再调用任何工具。" })
                    }
                }
                if ($synthHard.Count -gt 0) { Add-ToolResults $synthHard }
                Write-Host "  $([char]0x26A0) $([char]27)[33mTool hard limit reached ($toolUseCount/$($global:DEFAULT_TOOL_HARD_LIMIT)), forcing end_turn$([char]27)[0m"
                $continueLoop = $false
                break
            }

            # ── Adaptive budget check ──
            if ($toolUseCount -ge 3) {
                $budget = Compute-CallBudget -ConsecutiveTools $toolUseCount
                if ($budget -eq "halt") {
                    if ($script:_deferredContent) {
                        Add-AssistantMessage @($script:_deferredContent)
                        $script:_deferredContent = $null
                    }
                    $synthHalt = @()
                    foreach ($tb in $toolUseBlocks) {
                        $synthHalt += @{
                            type = "tool_result"
                            tool_use_id = $tb.id
                            content = @(@{ type = "text"; text = '{"status":"cancelled","reason":"Adaptive budget halt — tool chain too long."}' })
                        }
                    }
                    if ($synthHalt.Count -gt 0) { Add-ToolResults $synthHalt }
                    Write-Host "  $([char]0x26A0) $([char]27)[33mAdaptive loop: tool chain too long, stopping$([char]27)[0m"
                    $continueLoop = $false
                    break
                }
            }

            # ── Turn budget check inside tool loop ──
            $innerBudget = Test-TurnBudget
            if ($innerBudget -eq "exhausted") {
                if ($script:_deferredContent) {
                    Add-AssistantMessage @($script:_deferredContent)
                    $script:_deferredContent = $null
                }
                # 补充合成 tool_result，避免 MESSAGES 中出现孤立的 tool_use 导致下次 400
                $syntheticResults = @()
                foreach ($tb in $toolUseBlocks) {
                    $syntheticResults += @{
                        type = "tool_result"
                        tool_use_id = $tb.id
                        content = @(@{ type = "text"; text = '{"status":"cancelled","reason":"Turn budget exhausted — tool execution skipped."}' })
                    }
                }
                if ($syntheticResults.Count -gt 0) {
                    Add-ToolResults $syntheticResults
                }
                Write-Host "  $([char]0x26A0) $([char]27)[33mTurn budget exhausted during tool execution$([char]27)[0m"
                $continueLoop = $false
                break
            }

            # ── Dispatch tools ──
            $toolResults = @()
            foreach ($toolBlock in $toolUseBlocks) {
                # 兼容 OpenAI tool_call (arguments) 和旧 Anthropic tool_use (input)
                $toolArgs = if ($toolBlock.arguments) { $toolBlock.arguments } else { $toolBlock.input }
                # ── Loop Detection (Bug 4: CodeWhale LoopDetectionMiddleware) ──
                $loopStatus = Test-ToolLoop -ToolName $toolBlock.name -ToolArgs $toolArgs
                if ($loopStatus -eq "halt") {
                    $toolResults += @{
                        type = "tool_result"
                        tool_use_id = $toolBlock.id
                        content = @(@{ type = "text"; text = "[LOOP DETECTED] 你已连续调用相同工具和参数超过5次。请立即切换到不同的工具或使用不同的方法。如果需要处理数据，请使用 powershell 或 process_excel 工具。" })
                    }
                    # 为 foreach 中尚未处理的剩余 tool_use 补充合成 tool_result
                    $currentIdx = [array]::IndexOf($toolUseBlocks, $toolBlock)
                    for ($ri = $currentIdx + 1; $ri -lt $toolUseBlocks.Count; $ri++) {
                        $toolResults += @{
                            type = "tool_result"
                            tool_use_id = $toolUseBlocks[$ri].id
                            content = @(@{ type = "text"; text = '{"status":"cancelled","reason":"Loop detected — remaining tools skipped."}' })
                        }
                    }
                    $continueLoop = $false
                    break
                }

                $toolCallDisplay = "$($toolBlock.name)($($toolArgs | ConvertTo-Json -Compress -Depth 3))"
                Write-UiToolLine -Prefix "> " -Content $toolCallDisplay -MaxChars 300 -Color "Cyan" -Icon ([char]0x25B8)

                # Phase 2: 工具执行期间显示 spinner（防止长时间工具看起来卡死）
                Start-SpinnerBg -Message "$($toolBlock.name) 执行中"
                $result = Invoke-ToolDispatch -ToolName $toolBlock.name -ToolId $toolBlock.id -ToolInput $toolArgs
                Stop-SpinnerBg

                # ── Tool Result Dedup & Truncation (Bug 3: CodeWhale compact_tool_result) ──
                # 截断结果中的文本内容，避免上下文爆炸
                if ($result.content -is [array]) {
                    $newContent = @()
                    foreach ($block in $result.content) {
                        if ($block.text) {
                            $compressed = Compress-ToolResult -ToolName $toolBlock.name -ToolArgs $toolArgs -ResultJson $block.text
                            $newContent += @{ type = "text"; text = $compressed }
                        } else {
                            $newContent += $block
                        }
                    }
                    $result.content = $newContent
                }

                # Show result summary (截断到 300 字符)
                $resultTexts = @($result.content | ForEach-Object { $_.text })
                $resultContent = $resultTexts -join ""
                Write-UiToolLine -Prefix "< " -Content $resultContent -MaxChars 300 -Color "DarkGray" -Icon ([char]0x25C2)

                # Phase 2: 更新工具进度状态栏（带耗时）
                $toolDoneIdx++
                $toolElapsed = if ($global:_LAST_SPINNER_ELAPSED) { $global:_LAST_SPINNER_ELAPSED } else { 0 }
                Write-StatusBar -State "tools" -ToolDone $toolDoneIdx -ToolTotal $toolUseCount -Elapsed $toolElapsed
                Write-Host ""   # 状态栏换行

                # ── Item 5: Update non-productive streak ──
                $productiveTools = @("edit_file", "write_file", "powershell", "bash", "task_create", "task_update", "make_todos", "agent", "agent_batch", "skill", "request")
                $isProductive = $false
                foreach ($pt in $productiveTools) {
                    if ($toolBlock.name -eq $pt) {
                        $isProductive = $true
                        break
                    }
                }
                # MCP tools are also productive
                if ($toolBlock.name.StartsWith("mcp__")) {
                    $isProductive = $true
                }
                if ($isProductive) {
                    $global:NON_PRODUCTIVE_STREAK = 0
                } else {
                    $global:NON_PRODUCTIVE_STREAK++
                }

                # ── Item 6: post_tool hook — tool result augmentation ──
                $ptHookCtx = @{
                    tool = $toolBlock.name
                    input = $toolArgs
                    output = $resultContent
                    exit_code = 0
                    elapsed_ms = 0
                }
                $ptHookResults = Invoke-HookFire -Point "post_tool" -Context $ptHookCtx
                if ($ptHookResults -and $ptHookResults -is [array]) {
                    foreach ($ptItem in $ptHookResults) {
                        if ($ptItem -is [hashtable]) {
                            if ($ptItem.augment -eq $true -and $ptItem.output_suffix) {
                                # Append suffix to tool result
                                foreach ($blk in $result.content) {
                                    if ($blk.text) { $blk.text += $ptItem.output_suffix; break }
                                }
                            }
                            if ($ptItem.output_replace) {
                                # Replace tool result entirely
                                foreach ($blk in $result.content) {
                                    if ($blk.text) { $blk.text = $ptItem.output_replace; break }
                                }
                            }
                        }
                    }
                }

                $toolResults += $result

                # ── ESC 中断检测（工具执行期间） ──
                if (Test-EscInterrupt) {
                    Write-Host ""
                    Write-Host "  $([char]0x26A0) $([char]27)[33m操作已中断 (ESC)$([char]27)[0m"
                    # 为尚未处理的剩余 tool_use 补充合成 tool_result
                    $escIdx = [array]::IndexOf($toolUseBlocks, $toolBlock)
                    for ($ei = $escIdx + 1; $ei -lt $toolUseBlocks.Count; $ei++) {
                        $toolResults += @{
                            type = "tool_result"
                            tool_use_id = $toolUseBlocks[$ei].id
                            content = @(@{ type = "text"; text = '{"status":"cancelled","reason":"用户按 ESC 中断了操作。"}' })
                        }
                    }
                    $continueLoop = $false
                    Stop-EscMonitor
                    break
                }
                # ── Ctrl+C 中断检测（工具执行期间） ──
                if (Test-CtrlCInterrupt) {
                    # 为尚未处理的剩余 tool_use 补充合成 tool_result
                    $ccIdx = [array]::IndexOf($toolUseBlocks, $toolBlock)
                    for ($ci = $ccIdx + 1; $ci -lt $toolUseBlocks.Count; $ci++) {
                        $toolResults += @{
                            type = "tool_result"
                            tool_use_id = $toolUseBlocks[$ci].id
                            content = @(@{ type = "text"; text = '{"status":"cancelled","reason":"用户按 Ctrl+C 中断了操作。"}' })
                        }
                    }
                    $continueLoop = $false
                    Stop-EscMonitor
                    $global:_CTRL_C_EXIT_REQUESTED = $true
                    if ($script:_deferredContent) {
                        Add-AssistantMessage @($script:_deferredContent)
                        $script:_deferredContent = $null
                    }
                    break
                }

                # ── Item 11: Plan system — check _PLAN_STOP after each tool dispatch ──
                if ($global:_PLAN_STOP -eq 1) {
                    Write-Host "  $([char]0x26A0) $([char]27)[33mPlan execution stopped.$([char]27)[0m"
                    # 为尚未处理的剩余 tool_use 补充合成 tool_result
                    $planIdx = [array]::IndexOf($toolUseBlocks, $toolBlock)
                    for ($pi = $planIdx + 1; $pi -lt $toolUseBlocks.Count; $pi++) {
                        $toolResults += @{
                            type = "tool_result"
                            tool_use_id = $toolUseBlocks[$pi].id
                            content = @(@{ type = "text"; text = '{"status":"cancelled","reason":"Plan execution stopped."}' })
                        }
                    }
                    $continueLoop = $false
                    break
                }

                # ── Item 11: Plan system — check _PLAN_PENDING after request tool ──
                if ($toolBlock.name -eq "request" -and $global:_PLAN_PENDING -eq $true) {
                    $global:_PLAN_PENDING = $false
                    # 提取 request 工具返回的 choice JSON
                    $choiceJson = ""
                    if ($result.content -is [array]) {
                        foreach ($blk in $result.content) {
                            if ($blk.text) { $choiceJson = $blk.text; break }
                        }
                    }
                    $handleResult = Invoke-PlanHandleResponse -ChoiceJson $choiceJson
                    Write-Host "${global:DIM}  [plan] $handleResult${global:RESET}"
                    if ($global:_PLAN_STOP -eq 1) {
                        $continueLoop = $false
                        break
                    }
                    # 设置延迟反馈（在 tool results 发送后注入）
                    if ($global:_PLAN_DEFERRED_MSG) {
                        $global:_DEFERRED_FEEDBACK = $global:_PLAN_DEFERRED_MSG
                    }
                }
            }

            # ── Item 10: Deferred content — commit assistant message BEFORE tool results ──
            if ($script:_deferredContent) {
                Add-AssistantMessage @($script:_deferredContent)
                $script:_deferredContent = $null
            }

            # ── Prompt Caching: invalidate msg prefix after assistant message ──
            Invoke-CcInvalidate -Names @("msgs")

            # ── Item 3: post_response hook — reflection & intervention ──
            $toolsCalled = @($toolUseBlocks | ForEach-Object { $_.name })
            $respHookCtx = @{
                stop_reason = $apiResult.StopReason
                tools_called = $toolsCalled
                non_productive_streak = $global:NON_PRODUCTIVE_STREAK
                turn = $global:TURN_COUNTER
                tokens = @{ in = $apiResult.InputTokens; out = $apiResult.OutputTokens }
            }
            $respHookResults = Invoke-HookFire -Point "post_response" -Context $respHookCtx
            if ($respHookResults -and $respHookResults -is [array]) {
                foreach ($item in $respHookResults) {
                    if ($item -is [hashtable] -and $item.inject_reflection -eq $true -and $item.reflection_prompt) {
                        $global:_HOOK_CONTEXT_BUFFER += $item.reflection_prompt + "`n"
                    }
                }
            }

            # Add tool results
            Add-ToolResults $toolResults

            # ── Prompt Caching: invalidate msg prefix after tool results ──
            Invoke-CcInvalidate -Names @("msgs")

            # ── Item 11: Emit deferred feedback from plan system ──
            if (-not [string]::IsNullOrWhiteSpace($global:_DEFERRED_FEEDBACK)) {
                Add-UserText $global:_DEFERRED_FEEDBACK
                Write-Host "${global:DIM}  [plan feedback] $($global:_DEFERRED_FEEDBACK)${global:RESET}"
                $global:_DEFERRED_FEEDBACK = ""
                $global:_PLAN_DEFERRED_MSG = ""
            }

            # Rebuild request for next iteration (buffer may have been updated by hooks)
            $bodyJson = Build-ApiRequestBody -Tools $tools -ThinkingBudget ([int]$global:PA_THINKING_BUDGET)
            $headers = Get-ApiHeaders

        } elseif ($apiResult.StopReason -eq "max_tokens") {
            # ── Item 9: Handle max_tokens — smart budget reduction + stuck detection ──
            # ── Item 10: commit deferred content ──
            if ($script:_deferredContent) {
                Add-AssistantMessage @($script:_deferredContent)
                $script:_deferredContent = $null
                Invoke-CcInvalidate -Names @("msgs")
            }

            if (-not (Invoke-HandleMaxTokens -Round $toolUseCount)) {
                $continueLoop = $false
            } else {
                # Rebuild request and continue
                $bodyJson = Build-ApiRequestBody -Tools $tools -ThinkingBudget ([int]$global:PA_THINKING_BUDGET)
                $headers = Get-ApiHeaders
            }

        } else {
            # Unknown stop reason — commit deferred content and stop
            if ($script:_deferredContent) {
                Add-AssistantMessage @($script:_deferredContent)
                $script:_deferredContent = $null
                Invoke-CcInvalidate -Names @("msgs")
            }
            $continueLoop = $false
        }
    }
    # ── 清理 ESC 监测 ──
    Stop-EscMonitor
}

# ============================================================================
#  Plan System — Handle Response (Item 11)
#  Port of bashagt _plan_handle_response() (L10038-10074)
# ============================================================================

function Invoke-PlanHandleResponse {
    <#
    .SYNOPSIS
    解析 request 工具的结果，处理计划确认/拒绝。
    choice_index 0 = 批准 → 设置 _PLAN_DEFERRED_MSG（验证指令）
    choice_index 1 = 拒绝 → 设置 _PLAN_STOP=1
    取消 → 设置 _PLAN_STOP=1
    返回操作结果文本。
    #>
    param(
        [string]$ChoiceJson,
        [string]$Target = ""
    )

    # 空输入防护
    if ([string]::IsNullOrWhiteSpace($ChoiceJson)) {
        $global:_PLAN_STOP = 1
        return "[plan] No response received — stopping."
    }

    # 解析 JSON
    $parsed = $null
    try {
        $parsed = $ChoiceJson | ConvertFrom-Json
    } catch {
        $global:_PLAN_STOP = 1
        return "[plan] Failed to parse response — stopping."
    }

    if ($null -eq $parsed) {
        $global:_PLAN_STOP = 1
        return "[plan] Null response — stopping."
    }

    # 提取 choice_index
    $choiceIndex = -1
    if ($parsed.PSObject.Properties["index"]) {
        $choiceIndex = [int]$parsed.index
    } elseif ($parsed.PSObject.Properties["choice_index"]) {
        $choiceIndex = [int]$parsed.choice_index
    }

    # 提取 status（用于检测取消）
    $status = ""
    if ($parsed.PSObject.Properties["status"]) {
        $status = $parsed.status.ToString()
    }

    # 检查取消
    if ($status -eq "cancelled") {
        $global:_PLAN_STOP = 1
        $global:_PLAN_PENDING = $false
        return "[plan] Plan cancelled by user."
    }

    # choice_index 0 = 批准
    if ($choiceIndex -eq 0) {
        $global:_PLAN_DEFERRED_MSG = "[plan approved] Proceeding with plan. Execute each step carefully. After completing all steps, verify the results match the plan's goals. Report any deviations."
        $global:_PLAN_PENDING = $false
        return "[plan] Plan approved — execution instructions will follow."
    }

    # choice_index 1 = 拒绝
    if ($choiceIndex -eq 1) {
        $global:_PLAN_STOP = 1
        $global:_PLAN_PENDING = $false
        return "[plan] Plan rejected by user — stopping."
    }

    # 其他 choice_index 也视为拒绝
    if ($choiceIndex -gt 1) {
        $global:_PLAN_STOP = 1
        $global:_PLAN_PENDING = $false
        return "[plan] Plan not approved (choice=$choiceIndex) — stopping."
    }

    # 未识别格式
    $global:_PLAN_STOP = 1
    return "[plan] Unrecognized response — stopping."
}

# ============================================================================
#  Loop Detection & Tool Result Dedup (CodeWhale patterns)
# ============================================================================

function Get-ArgsHash {
    <# SHA256 hash of tool name + serialized args, for loop detection #>
    param($ToolName, $ToolArgs)
    $argsStr = if ($ToolArgs -is [string]) { $ToolArgs } else { ConvertTo-JsonSafe $ToolArgs -Depth 5 }
    $raw = "$ToolName|$argsStr"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash = $sha.ComputeHash($bytes)
    $sha.Dispose()
    return [BitConverter]::ToString($hash) -replace '-', ''
}

function Test-ToolLoop {
    <#
    .SYNOPSIS
    LoopDetection 中间件 — 检测连续相同工具调用 (CodeWhale LoopDetectionMiddleware)
    参考: hash tool_name+args, warn at 3 repeats, force stop at 5
    #>
    param([string]$ToolName, $ToolArgs)

    if (-not $global:_LOOP_DETECTION_ENABLED) { return "ok" }

    $hash = Get-ArgsHash -ToolName $ToolName -ToolArgs $ToolArgs

    # 记录本次调用
    $global:_TOOL_CALL_HISTORY += @{
        tool = $ToolName
        args_hash = $hash
        timestamp = Get-Date
    }

    # 只保留最近 20 条记录
    if ($global:_TOOL_CALL_HISTORY.Count -gt 20) {
        $global:_TOOL_CALL_HISTORY = $global:_TOOL_CALL_HISTORY[-20..-1]
    }

    # 统计连续相同 hash 的次数
    $consecutiveSame = 0
    for ($i = $global:_TOOL_CALL_HISTORY.Count - 1; $i -ge 0; $i--) {
        if ($global:_TOOL_CALL_HISTORY[$i].args_hash -eq $hash) {
            $consecutiveSame++
        } else {
            break
        }
    }

    if ($consecutiveSame -ge 5) {
        Write-Host ""
        Write-Host "${global:RED}[LoopDetection] 工具 $ToolName 连续调用 $consecutiveSame 次（相同参数）— 强制停止循环${global:RESET}"
        Write-Host "${global:DIM}  提示: 请尝试使用不同的工具或不同的参数来完成此任务${global:RESET}"
        return "halt"
    } elseif ($consecutiveSame -ge 3) {
        Write-Host ""
        Write-Host "${global:YELLOW}[LoopDetection] 警告: 工具 $ToolName 已连续调用 $consecutiveSame 次（相同参数）${global:RESET}"
        Write-Host "${global:DIM}  建议: 已有足够数据，请切换到处理/分析步骤${global:RESET}"
        return "warn"
    }

    return "ok"
}

function Compress-ToolResult {
    <#
    .SYNOPSIS
    工具结果截断 + SHA 去重 (CodeWhale compact_tool_result_for_wire)
    1. 相同 hash 的结果 → 引用之前的结果（避免重复传输）
    2. 超长结果 → 截断到 TOOL_RESULT_CHAR_BUDGET 字符
    #>
    param([string]$ToolName, $ToolArgs, [string]$ResultJson)

    if (-not $ResultJson -or $ResultJson.Length -eq 0) { return $ResultJson }

    # 计算结果 hash
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ResultJson)
    $hashBytes = $sha.ComputeHash($bytes)
    $sha.Dispose()
    $resultHash = [BitConverter]::ToString($hashBytes) -replace '-', ''

    # 去重: 如果之前发送过完全相同的结果，返回引用
    if ($global:_TOOL_RESULT_CACHE.ContainsKey($resultHash)) {
        return "[deduplicated: 此结果与之前的调用完全相同，已省略以节省上下文空间]"
    }

    # 截断: 超过字符预算的结果
    $budget = [int]$global:TOOL_RESULT_CHAR_BUDGET
    if ($ResultJson.Length -gt $budget) {
        $truncated = $ResultJson.Substring(0, $budget)
        $totalLen = $ResultJson.Length
        $truncated += "`n...[truncated: original=$totalLen chars, shown=$budget chars]"
        $ResultJson = $truncated
    }

    # 缓存结果 hash（最多保留 50 条）
    $global:_TOOL_RESULT_CACHE[$resultHash] = $true
    if ($global:_TOOL_RESULT_CACHE.Count -gt 50) {
        # 清理最早的条目
        $keys = @($global:_TOOL_RESULT_CACHE.Keys)
        for ($i = 0; $i -lt 10; $i++) {
            $global:_TOOL_RESULT_CACHE.Remove($keys[$i])
        }
    }

    return $ResultJson
}

# ============================================================================
#  Adaptive Agent Loop
# ============================================================================

# ── On-Stuck Hook (bashagt line 13718) ──
function Invoke-OnStuck {
    <#
    .SYNOPSIS
    Fire on_stuck hook when consecutive max_tokens hits exceed threshold.
    Bashagt reference: line 13718.
    #>
    param([int]$ConsecutiveMaxTokens, [int]$Round, [int]$ContextPct)
    $stuckCtx = @{
        consecutive_max_tokens = $ConsecutiveMaxTokens
        turn = $Round
        context_pct = $ContextPct
    }
    $stuckResults = Invoke-HookFire -Point "on_stuck" -Context $stuckCtx
    if ($stuckResults -and $stuckResults -is [array]) {
        foreach ($item in $stuckResults) {
            if ($item -is [hashtable] -and $item.inject -eq $true -and $item.content) {
                Add-UserText $item.content
            }
        }
    }
}

# ── Handle Max Tokens (bashagt line 13705-13735) ──
function Invoke-HandleMaxTokens {
    <#
    .SYNOPSIS
    Handle max_tokens stop reason: count consecutive hits, fire on_stuck at threshold.
    Returns $true to continue, $false to stop.
    Bashagt reference: line 13705-13735.
    #>
    param([int]$Round = 0)
    $global:_TURN_MAX_TOKENS_HIT++
    $limit = [int]$global:DEFAULT_STUCK_THRESHOLD
    Write-Host "${global:YELLOW}[Response truncated (max_tokens #$($global:_TURN_MAX_TOKENS_HIT)/$limit), retrying...]${global:RESET}"

    if ($global:_TURN_MAX_TOKENS_HIT -ge $limit) {
        $ctxTokens = Estimate-ContextTokens
        $ctxPct = [Math]::Floor($ctxTokens / [int]$global:PA_CONTEXT_WINDOW * 100)
        Invoke-OnStuck -ConsecutiveMaxTokens $global:_TURN_MAX_TOKENS_HIT -Round $Round -ContextPct $ctxPct
        Write-Host "${global:RED}[Stuck loop: $($global:_TURN_MAX_TOKENS_HIT) consecutive max_tokens. Stopping.]${global:RESET}"
        return $false
    }
    return $true
}

function Compute-CallBudget {
    <# Per-call token budget based on consecutive tool usage #>
    param([int]$ConsecutiveTools)
    if ($ConsecutiveTools -ge 90) { return "halt" }
    if ($ConsecutiveTools -ge 10) { return "50pct" }
    return "100pct"
}

function Test-TurnBudget {
    <#
    Check if context window is approaching or at limit.
    Aligned with bashagt: uses actual MESSAGES byte-estimated context size,
    NOT cumulative SESSION_INPUT/OUTPUT tokens which grow unboundedly.
    Returns: "ok", "soft_limit", or "exhausted"
    #>
    $tokens = Estimate-ContextTokens
    $window = [int]$global:PA_CONTEXT_WINDOW
    if ($window -le 0) { return "ok" }
    $criticalThreshold = [Math]::Floor($window * 0.95)
    $warnThreshold = [Math]::Floor($window * 0.85)

    if ($tokens -ge $criticalThreshold) { return "exhausted" }
    if ($tokens -ge $warnThreshold) { return "soft_limit" }
    return "ok"
}

# ============================================================================
#  Main Agent Loop (Interactive REPL)
# ============================================================================

function Start-AgentLoop {
    <#
    .SYNOPSIS
    Top-level interactive loop.
    Port of bashagt agent_loop() (L13852).
    #>

    $global:_EXIT_REQUESTED = $false
    $global:_ESC_PRESSED = $false

    # ── 打印横幅 (Phase 1 TUI: 无边框居中设计) ──
    $w = Get-ConsoleWidth
    if ($w -lt 40) { $w = 80 }
    $h = [string][char]0x2550          # ═
    $bolt = [string][char]0x26A1       # ⚡
    $arrow = [string][char]0x25B8      # ▸
    $esc = $global:ESC
    $rst = $global:RESET
    $bld = $global:BOLD
    $dim = $global:DIM
    $cyan = $global:CYAN
    $lcyan = $global:LIGHT_CYAN
    $white = $global:WHITE
    $gray = $global:GRAY
    $hLine = $h * [Math]::Min($w - 4, 62)

    Write-Host ""

    # 上分隔线
    Write-Host "  $hLine"

    # 标题行（居中）
    $titleText = "$bolt PowerAgent  $($global:PA_VERSION)"
    Write-Host "  ${cyan}${bld}$titleText${rst}"

    # 副标题
    Write-Host "  ${dim}基于PowerShell的超轻量化智能体${rst}"

    Write-Host ""

    # 信息行
    $ep = $global:PA_API_URL
    $thinkLabel = if ($global:PA_SHOW_THINKING -in @("status", "full")) { "Yes" } else { "No" }
    Write-Host "  ${lcyan}Model${rst}     $($global:PA_MODEL)"
    Write-Host "  ${lcyan}Endpoint${rst}  $ep"
    Write-Host "  ${lcyan}Thinking${rst}  $thinkLabel"

    # 下分隔线
    Write-Host "  $hLine"

    # 帮助提示
    Write-Host ""
    Write-Host "  $arrow ${dim}/help${rst}   ${gray}# 查看可用命令${rst}"
    Write-Host ""

    # Register Ctrl+C handler
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        $global:_INTERRUPTED = $true
    } -ErrorAction SilentlyContinue

    # ── Oneshot mode: 执行一次后退出 ──
    if ($global:PA_MODE -eq "oneshot") {
        $prompt = $env:PA_ONESHOT_PROMPT
        if (-not [string]::IsNullOrWhiteSpace($prompt)) {
            Invoke-RunTurn -UserInput $prompt
        } else {
            Write-Host "[poweragent] oneshot mode: PA_ONESHOT_PROMPT not set" -ForegroundColor Yellow
        }
        $global:_EXIT_REQUESTED = $true
    }

    # 初始化 Ctrl+C 退出请求标志
    $global:_CTRL_C_EXIT_REQUESTED = $false

    # 连续错误计数器（防止无限循环）
    $consecutiveErrors = 0

    # ── 接管 Ctrl+C：防止 PowerShell 引擎拦截并直接终止脚本 ──
    # 在整个主循环期间 TreatControlCAsInput=$true，由我们自己的代码处理 Ctrl+C：
    #   输入阶段 → Read-HostWithCompletion 的 ReadKey 检测 char(3) → 返回 $null → 确认对话框
    #   API 调用  → HTTP 轮询循环的 GetAsyncKeyState 检测 → 设置 _CTRL_C_EXIT_REQUESTED
    #   工具执行  → Test-CtrlCInterrupt (GetAsyncKeyState) 检测 → 设置 _CTRL_C_EXIT_REQUESTED
    $prevTreatCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    try { $Host.UI.RawUI.FlushInputBuffer() } catch {}

    # Main loop
    while (-not $global:_EXIT_REQUESTED) {
        try {
            # 每轮循环开始时刷新输入缓冲区，排掉上一轮残留的 Ctrl+C char(3)
            try { $Host.UI.RawUI.FlushInputBuffer() } catch {}

            Invoke-RunTurn
            $consecutiveErrors = 0  # 成功后重置

            # ── Ctrl+C 退出请求（由 Invoke-RunTurn 通过 GetAsyncKeyState 路径设置） ──
            if ($global:_CTRL_C_EXIT_REQUESTED) {
                $global:_CTRL_C_EXIT_REQUESTED = $false
                $wantExit = Request-ExitConfirm -Message "Ctrl+C 已中断当前操作"
                if ($wantExit) {
                    $global:_EXIT_REQUESTED = $true
                    break
                } else {
                    continue
                }
            }
        } catch {
            Stop-SpinnerBg
            Stop-EscMonitor
            $consecutiveErrors++
            Write-Host "${global:RED}Error: $_${global:RESET}"
            Write-Log "ERROR: Agent loop error: $_"
            # 连续 3 次错误 → 退出循环（防止无限循环）
            if ($consecutiveErrors -ge 3) {
                Write-Host "  $([char]0x2718) $([char]27)[33mToo many consecutive errors, exiting$([char]27)[0m"
                break
            }
        }

        # Context window pressure warning (informational only; actual compression
        # is handled inside Invoke-RunTurn via Test-ContextWindowPressure).
        # bashagt has no equivalent outer-loop check — kept purely for UX.
        $budgetStatus = Test-TurnBudget
        if ($budgetStatus -eq "exhausted") {
            Write-Host "  $([char]0x26A0) $([char]27)[33mContext window near limit — auto-compression will trigger on next turn$([char]27)[0m"
        } elseif ($budgetStatus -eq "soft_limit") {
            Write-Log "INFO: Context pressure soft_limit detected at outer loop"
        }
    }

    # ── 恢复 Ctrl+C 默认行为 ──
    [Console]::TreatControlCAsInput = $prevTreatCtrlC

    # Cleanup
    Write-LogFlush
    Write-Host "${global:DIM}Goodbye.${global:RESET}"
}


# ============================================================================
#  Inlined: Daemon.ps1
# ============================================================================
# ============================================================================
#  PowerAgent - Daemon.ps1
#  Section 13: HTTP Daemon / Persistent Service
#  PowerShell 5.1 port of bashagt Section 11d (lines 14465-15501)
#
#  Key Bash->PS differences:
#  - nc-based HTTP server -> System.Net.HttpListener (.NET)
#  - Background processes & FIFOs -> Start-Job / .NET Named Pipes
#  - Process group signals -> taskkill /T /F
#  - Cron scheduler -> internal timer with 5-field cron support
#
#  Endpoints:
#    GET  /                       — Dashboard index page
#    POST /v1/session/new         — Create new session
#    POST /v1/chat                — One-shot chat (create session + execute)
#    GET  /v1/sessions            — List all sessions
#    GET  /v1/session/{id}        — Get session detail with message history
#    POST /v1/session/{id}        — Send message to existing session
#    GET  /v1/session/{id}/stream — SSE streaming response
#    DELETE /v1/session/{id}      — Delete session
#    GET  /v1/cron                — List cron job status
#    POST /v1/cron                — Register new cron job at runtime
# ============================================================================

# ── Daemon State ──
$global:DAEMON_HTTP_LISTENER = $null
$global:SESSION_WORKERS = @{}
$global:DAEMON_RUNNING = $false
$global:DAEMON_SESSIONS = @{}
$global:DAEMON_SESSIONS_DIR = ""

# ============================================================================
#  Daemon Global Initialization
# ============================================================================

function Initialize-DaemonGlobals {
    <#
    .SYNOPSIS
    Ensure minimal global state for daemon mode.
    Background job mode dot-sources without full init, so globals may be unset.
    Reads from env vars and applies sane defaults.
    #>
    if (-not $global:PA_API_KEY -and $env:PA_API_KEY) { $global:PA_API_KEY = $env:PA_API_KEY }
    if (-not $global:PA_API_URL -and $env:PA_API_URL) { $global:PA_API_URL = $env:PA_API_URL }
    if (-not $global:PA_MODEL -and $env:PA_MODEL) { $global:PA_MODEL = $env:PA_MODEL }
    if (-not $global:PA_DAEMON_PORT -and $env:PA_DAEMON_PORT) {
        $global:PA_DAEMON_PORT = [int]$env:PA_DAEMON_PORT
    }
    # Sane defaults
    if (-not $global:PA_API_URL) { $global:PA_API_URL = "https://api.deepseek.com/v1/chat/completions" }
    if (-not $global:PA_MAX_TOKENS) { $global:PA_MAX_TOKENS = 384000 }
    if (-not $global:PA_THINKING_BUDGET) { $global:PA_THINKING_BUDGET = 100000 }
    if (-not $global:PA_CONTEXT_WINDOW) { $global:PA_CONTEXT_WINDOW = 1048576 }
    if (-not $global:PA_SYSTEM_PROMPT) { $global:PA_SYSTEM_PROMPT = "You are a helpful assistant." }
    if (-not $global:PA_PROTOCOL) { $global:PA_PROTOCOL = "openai" }
    if (-not $global:PA_CONNECT_TIMEOUT) { $global:PA_CONNECT_TIMEOUT = 10 }
    Write-Log "DEBUG: Daemon globals initialized (model=$($global:PA_MODEL))"
}

# ============================================================================
#  Session Persistence
# ============================================================================

function Initialize-SessionsDir {
    <#
    .SYNOPSIS
    Ensure .poweragent/sessions/ directory exists.
    #>
    if (-not $global:PA_STATE_DIR) {
        $global:PA_STATE_DIR = Join-Path $env:USERPROFILE ".poweragent"
    }
    $global:DAEMON_SESSIONS_DIR = Join-Path $global:PA_STATE_DIR "sessions"
    if (-not (Test-Path $global:DAEMON_SESSIONS_DIR)) {
        New-Item -ItemType Directory -Path $global:DAEMON_SESSIONS_DIR -Force | Out-Null
        Write-Log "DEBUG: Created sessions directory: $global:DAEMON_SESSIONS_DIR"
    }
}

function Save-DaemonSession {
    <#
    .SYNOPSIS
    Persist session to disk as JSON file.
    #>
    param([hashtable]$Session)
    if (-not $global:DAEMON_SESSIONS_DIR) { Initialize-SessionsDir }
    $filePath = Join-Path $global:DAEMON_SESSIONS_DIR "$($Session.id).json"
    try {
        $json = ConvertTo-JsonSafe $Session -Depth 10
        Write-AtomicFile $filePath $json
    } catch {
        Write-Log "WARN: Save-DaemonSession failed for $($Session.id): $_"
    }
}

function Load-DaemonSessions {
    <#
    .SYNOPSIS
    Load all persisted sessions from disk on daemon startup.
    #>
    Initialize-SessionsDir
    $loaded = 0
    try {
        $files = @(Get-ChildItem -Path $global:DAEMON_SESSIONS_DIR -Filter "sess_*.json" -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            try {
                $raw = Get-Content $file.FullName -Raw -Encoding UTF8
                $session = $raw | ConvertFrom-Json
                # Convert PSCustomObject back to hashtable for consistency
                $ht = @{}
                $ht["id"] = [string]$session.id
                $ht["created"] = [long]$session.created
                $ht["status"] = [string]$session.status
                $ht["system_prompt"] = ""
                if ($session.system_prompt) { $ht["system_prompt"] = [string]$session.system_prompt }
                $ht["messages"] = @()
                if ($session.messages) {
                    foreach ($msg in @($session.messages)) {
                        $msgHt = @{
                            role = [string]$msg.role
                            content = [string]$msg.content
                            timestamp = [long]$msg.timestamp
                        }
                        $ht["messages"] += $msgHt
                    }
                }
                $global:DAEMON_SESSIONS[$ht["id"]] = $ht
                $loaded++
            } catch {
                Write-Log "WARN: Failed to load session $($file.Name): $_"
            }
        }
    } catch {
        Write-Log "WARN: Load-DaemonSessions error: $_"
    }
    Write-Log "INFO: Loaded $loaded persisted sessions"
    return $loaded
}

function Remove-DaemonSessionFile {
    <#
    .SYNOPSIS
    Delete session file from disk.
    #>
    param([string]$SessionId)
    if (-not $global:DAEMON_SESSIONS_DIR) { return }
    $filePath = Join-Path $global:DAEMON_SESSIONS_DIR "$SessionId.json"
    if (Test-Path $filePath) {
        try {
            Remove-Item $filePath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "WARN: Failed to delete session file: $_"
        }
    }
}

# ============================================================================
#  Chat Execution
# ============================================================================

function Invoke-DaemonChat {
    <#
    .SYNOPSIS
    Execute a chat request against the LLM API for a given session.
    Temporarily sets $global:MESSAGES from session history, calls
    Build-ApiRequestBody + Invoke-ApiCall, parses and returns response.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$UserMessage
    )

    $session = $global:DAEMON_SESSIONS[$SessionId]
    if (-not $session) {
        return @{ success = $false; error = "Session not found: $SessionId" }
    }

    # ── Save and replace global MESSAGES ──
    $savedMessages = $global:MESSAGES
    $global:MESSAGES = @()

    try {
        # ── Build message history from session ──
        foreach ($msg in $session.messages) {
            $global:MESSAGES += @{ role = $msg.role; content = $msg.content }
        }

        # ── Add current user message to MESSAGES ──
        $global:MESSAGES += @{ role = "user"; content = $UserMessage }

        # ── Build API request (no tools for daemon chat) ──
        $systemPrompt = $global:PA_SYSTEM_PROMPT
        if ($session.system_prompt) { $systemPrompt = $session.system_prompt }
        $bodyJson = Build-ApiRequestBody -UserMessage $UserMessage -Tools @() `
            -MaxTokens 0 -ThinkingBudget 0 -SystemPrompt $systemPrompt
        $headers = Get-ApiHeaders

        # ── Update session status ──
        $session.status = "running"
        Save-DaemonSession $session

        # ── Call API ──
        $result = Invoke-ApiCall -RequestBody $bodyJson -Url $global:PA_API_URL -Headers $headers

        if ($result.Success) {
            # ── Extract text content from response blocks ──
            $content = ""
            foreach ($block in @($result.ContentBlocks)) {
                if ($block.type -eq "text") {
                    $content += $block.text
                }
            }

            # ── Update session with new messages ──
            $now = Get-TimestampMs
            $session.messages += @{
                role = "user"
                content = $UserMessage
                timestamp = $now
            }
            $session.messages += @{
                role = "assistant"
                content = $content
                timestamp = $now
            }
            $session.status = "idle"
            Save-DaemonSession $session

            return @{
                success = $true
                content = $content
                stop_reason = $result.StopReason
                input_tokens = $result.InputTokens
                output_tokens = $result.OutputTokens
            }
        } else {
            $session.status = "error"
            Save-DaemonSession $session
            return @{
                success = $false
                error = $result.Error
                content = ""
                stop_reason = "error"
                input_tokens = 0
                output_tokens = 0
            }
        }
    } catch {
        $session.status = "error"
        try { Save-DaemonSession $session } catch { }
        return @{ success = $false; error = "Chat execution error: $_" }
    } finally {
        # ── Restore global MESSAGES ──
        $global:MESSAGES = $savedMessages
    }
}

# ============================================================================
#  HTTP Server (using .NET HttpListener)
# ============================================================================

function Start-Daemon {
    <#
    .SYNOPSIS
    Start the HTTP daemon for REST API access.
    Port of bashagt _daemon_main() (L15465).
    #>
    param(
        [int]$Port = [int]$global:PA_DAEMON_PORT,
        [switch]$Debug
    )

    # Check if port is already in use
    if (Test-PortBusy $Port) {
        Write-Die "Port $Port is already in use"
    }

    Write-Host "${global:GREEN}Starting PowerAgent daemon on port $Port...${global:RESET}"
    Write-Log "INFO: Daemon starting on port $Port"

    # ── Initialize globals (for background job mode) ──
    Initialize-DaemonGlobals

    # ── Load persisted sessions ──
    Load-DaemonSessions | Out-Null

    # ── Start cron scheduler ──
    Import-CronConfig
    Start-CronScheduler

    $global:DAEMON_RUNNING = $true
    $prefix = "http://localhost:$Port/"
    $global:DAEMON_HTTP_LISTENER = New-Object System.Net.HttpListener
    $global:DAEMON_HTTP_LISTENER.Prefixes.Add($prefix)

    try {
        $global:DAEMON_HTTP_LISTENER.Start()
        Write-Host "Listening on $prefix" -ForegroundColor Green

        while ($global:DAEMON_RUNNING) {
            $context = $global:DAEMON_HTTP_LISTENER.GetContext()
            $request = $context.Request
            $response = $context.Response
            $startTime = Get-Date

            # ── CORS headers ──
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")

            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 204
                $response.Close()
                continue
            }

            # ── Check for SSE stream request ──
            $path = $request.Url.AbsolutePath
            if ($request.HttpMethod -eq "GET" -and $path -match "^/v1/session/([^/]+)/stream$") {
                Invoke-DaemonSseRequest -Context $context -SessionId $Matches[1]
                $elapsed = [int]((Get-Date) - $startTime).TotalMilliseconds
                Write-AccessLog "SSE" $path 200 $elapsed
                continue
            }

            # ── Route normal request ──
            $result = Invoke-GatewayRoute -Method $request.HttpMethod -Path $path -Body $request

            # ── Send response ──
            $response.StatusCode = $result.StatusCode
            $response.ContentType = "application/json; charset=utf-8"
            $responseBuffer = [System.Text.Encoding]::UTF8.GetBytes($result.Body)
            $response.ContentLength64 = $responseBuffer.Length
            $response.OutputStream.Write($responseBuffer, 0, $responseBuffer.Length)
            $response.Close()

            # ── Access log ──
            $elapsed = [int]((Get-Date) - $startTime).TotalMilliseconds
            Write-AccessLog $request.HttpMethod $path $result.StatusCode $elapsed
        }
    } catch [System.OperationCanceledException] {
        Write-Log "INFO: Daemon stopped"
    } catch {
        if ($global:DAEMON_RUNNING) {
            Write-Log "ERROR: Daemon error: $_"
        }
    } finally {
        if ($global:DAEMON_HTTP_LISTENER) {
            $global:DAEMON_HTTP_LISTENER.Stop()
            $global:DAEMON_HTTP_LISTENER.Close()
        }
    }
}

function Stop-Daemon {
    <#
    .SYNOPSIS
    Gracefully stop the daemon and cron scheduler.
    #>
    $global:DAEMON_RUNNING = $false
    Stop-CronScheduler
    if ($global:DAEMON_HTTP_LISTENER) {
        $global:DAEMON_HTTP_LISTENER.Stop()
    }
    Write-Log "INFO: Daemon stopped"
}

function Invoke-DaemonSseRequest {
    <#
    .SYNOPSIS
    Handle SSE streaming request for a session.
    Makes API call and sends result as SSE event(s).
    PS5.1 note: Uses chunked response for SSE format, but API call is
    non-streaming. Result arrives as a single event.
    #>
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$SessionId
    )

    $response = $Context.Response
    $response.ContentType = "text/event-stream; charset=utf-8"
    $response.Headers.Add("Cache-Control", "no-cache")
    $response.Headers.Add("Connection", "keep-alive")
    $response.SendChunked = $true

    # ── Read request body ──
    $bodyText = ""
    if ($Context.Request.HasEntityBody) {
        $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
        $bodyText = $reader.ReadToEnd()
        $reader.Close()
    }

    try {
        $writer = New-Object System.IO.StreamWriter($response.OutputStream, [System.Text.Encoding]::UTF8)

        # ── Send heartbeat comment ──
        $writer.WriteLine(": PowerAgent SSE")
        $writer.WriteLine()
        $writer.Flush()

        # ── Parse request ──
        $userMessage = ""
        if ($bodyText) {
            try {
                $req = $bodyText | ConvertFrom-Json
                if ($req.message) { $userMessage = [string]$req.message }
            } catch {
                $userMessage = $bodyText.Trim()
            }
        }

        if (-not $userMessage) {
            $errJson = ConvertTo-JsonSafe @{ type = "error"; error = "message is required" }
            $writer.WriteLine("data: $errJson")
            $writer.WriteLine()
            $writer.Flush()
            $writer.Close()
            return
        }

        # ── Ensure session exists ──
        if (-not $global:DAEMON_SESSIONS.ContainsKey($SessionId)) {
            $errJson = ConvertTo-JsonSafe @{ type = "error"; error = "Session not found: $SessionId" }
            $writer.WriteLine("data: $errJson")
            $writer.WriteLine()
            $writer.Flush()
            $writer.Close()
            return
        }

        # ── Execute chat ──
        $result = Invoke-DaemonChat -SessionId $SessionId -UserMessage $userMessage

        if ($result.success) {
            # ── Send content event ──
            $contentEvent = ConvertTo-JsonSafe @{
                type = "content"
                content = $result.content
                stop_reason = $result.stop_reason
                usage = @{ input_tokens = $result.input_tokens; output_tokens = $result.output_tokens }
            }
            $writer.WriteLine("data: $contentEvent")
            $writer.WriteLine()
            $writer.Flush()
        } else {
            $errJson = ConvertTo-JsonSafe @{ type = "error"; error = $result.error }
            $writer.WriteLine("data: $errJson")
            $writer.WriteLine()
            $writer.Flush()
        }

        # ── Send done event ──
        $writer.WriteLine("data: [DONE]")
        $writer.WriteLine()
        $writer.Flush()
        $writer.Close()

    } catch {
        Write-Log "ERROR: SSE request failed for session $SessionId : $_"
        try { $response.OutputStream.Close() } catch { }
    }
}

# ============================================================================
#  Gateway Route Handler
# ============================================================================

function Invoke-GatewayRoute {
    param([string]$Method, [string]$Path, $Body)

    try {
        # ── Read request body ──
        $bodyText = ""
        if ($Body -and $Body.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($Body.InputStream, $Body.ContentEncoding)
            $bodyText = $reader.ReadToEnd()
            $reader.Close()
        }

        switch -Regex ("$Method $Path") {
            # ── Create new session ──
            "^POST /v1/session/new$" {
                $result = New-DaemonSession
                return $result
            }

            # ── One-shot chat: create session + execute ──
            "^POST /v1/chat$" {
                if (-not $bodyText) {
                    return @{ StatusCode = 400; Body = '{"error":"Request body required"}' }
                }
                try {
                    $chatReq = $bodyText | ConvertFrom-Json
                } catch {
                    return @{ StatusCode = 400; Body = ConvertTo-JsonSafe @{ error = "Invalid JSON: $_" } }
                }

                $userMessage = ""
                if ($chatReq.message) { $userMessage = [string]$chatReq.message }
                if (-not $userMessage) {
                    return @{ StatusCode = 400; Body = '{"error":"message is required"}' }
                }

                # Create new session with optional system_prompt
                $sysPrompt = ""
                if ($chatReq.system_prompt) { $sysPrompt = [string]$chatReq.system_prompt }
                $sessionResult = New-DaemonSession -SystemPrompt $sysPrompt
                $sessionId = $sessionResult.SessionId

                # Execute chat
                $chatResult = Invoke-DaemonChat -SessionId $sessionId -UserMessage $userMessage

                if ($chatResult.success) {
                    return @{
                        StatusCode = 200
                        Body = ConvertTo-JsonSafe @{
                            session_id = $sessionId
                            response = $chatResult.content
                            stop_reason = $chatResult.stop_reason
                            usage = @{
                                input_tokens = $chatResult.input_tokens
                                output_tokens = $chatResult.output_tokens
                            }
                        }
                    }
                } else {
                    return @{
                        StatusCode = 500
                        Body = ConvertTo-JsonSafe @{
                            session_id = $sessionId
                            error = $chatResult.error
                        }
                    }
                }
            }

            # ── List all sessions ──
            "^GET /v1/sessions$" {
                $sessList = @(Get-DaemonSessionList)
                if ($sessList.Count -eq 0) {
                    return @{ StatusCode = 200; Body = '[]' }
                }
                return @{ StatusCode = 200; Body = ConvertTo-JsonSafe $sessList }
            }

            # ── Send message to existing session ──
            "^POST /v1/session/" {
                if ($Path -match "^/v1/session/([^/]+)$") {
                    $sessionId = $Matches[1]
                    if (-not $global:DAEMON_SESSIONS.ContainsKey($sessionId)) {
                        return @{ StatusCode = 404; Body = '{"error":"Session not found"}' }
                    }
                    if (-not $bodyText) {
                        return @{ StatusCode = 400; Body = '{"error":"Request body required"}' }
                    }
                    try {
                        $msgReq = $bodyText | ConvertFrom-Json
                    } catch {
                        return @{ StatusCode = 400; Body = ConvertTo-JsonSafe @{ error = "Invalid JSON: $_" } }
                    }

                    $userMessage = ""
                    if ($msgReq.message) { $userMessage = [string]$msgReq.message }
                    if (-not $userMessage) {
                        return @{ StatusCode = 400; Body = '{"error":"message is required"}' }
                    }

                    $chatResult = Invoke-DaemonChat -SessionId $sessionId -UserMessage $userMessage

                    if ($chatResult.success) {
                        return @{
                            StatusCode = 200
                            Body = ConvertTo-JsonSafe @{
                                session_id = $sessionId
                                response = $chatResult.content
                                stop_reason = $chatResult.stop_reason
                                usage = @{
                                    input_tokens = $chatResult.input_tokens
                                    output_tokens = $chatResult.output_tokens
                                }
                            }
                        }
                    } else {
                        return @{
                            StatusCode = 500
                            Body = ConvertTo-JsonSafe @{
                                session_id = $sessionId
                                error = $chatResult.error
                            }
                        }
                    }
                }
                return @{ StatusCode = 400; Body = '{"error":"Invalid session path"}' }
            }

            # ── Get session detail ──
            "^GET /v1/session/([^/]+)$" {
                if ($Path -match "^/v1/session/([^/]+)$") {
                    $sessionId = $Matches[1]
                    if (-not $global:DAEMON_SESSIONS.ContainsKey($sessionId)) {
                        return @{ StatusCode = 404; Body = '{"error":"Session not found"}' }
                    }
                    $session = $global:DAEMON_SESSIONS[$sessionId]
                    return @{
                        StatusCode = 200
                        Body = ConvertTo-JsonSafe @{
                            id = $session.id
                            created = $session.created
                            status = $session.status
                            message_count = @($session.messages).Count
                            messages = @($session.messages)
                        }
                    }
                }
                return @{ StatusCode = 400; Body = '{"error":"Invalid session path"}' }
            }

            # ── Delete session ──
            "^DELETE /v1/session/" {
                if ($Path -match "^/v1/session/([^/]+)$") {
                    $sessionId = $Matches[1]
                    if ($global:DAEMON_SESSIONS.ContainsKey($sessionId)) {
                        $global:DAEMON_SESSIONS.Remove($sessionId)
                        Remove-DaemonSessionFile $sessionId
                        Write-Log "INFO: Session $sessionId deleted"
                    }
                    return @{ StatusCode = 204; Body = '' }
                }
                return @{ StatusCode = 400; Body = '{"error":"Invalid session path"}' }
            }

            # ── Index page ──
            "^GET /$" {
                $indexHtml = Get-DaemonIndexPage
                return @{ StatusCode = 200; Body = $indexHtml }
            }

            # ── Get cron status ──
            "^GET /v1/cron$" {
                $cronStatus = Get-CronStatus
                return @{ StatusCode = 200; Body = ConvertTo-JsonSafe $cronStatus }
            }

            # ── Register new cron job at runtime ──
            "^POST /v1/cron$" {
                if (-not $bodyText) {
                    return @{ StatusCode = 400; Body = '{"error":"Request body required"}' }
                }
                try {
                    $cronReq = $bodyText | ConvertFrom-Json
                } catch {
                    return @{ StatusCode = 400; Body = ConvertTo-JsonSafe @{ error = "Invalid JSON: $_" } }
                }

                $name = ""
                if ($cronReq.name) { $name = [string]$cronReq.name }
                if (-not $name) { $name = "cron_$(Get-Random)" }
                $expr = ""
                if ($cronReq.expression) { $expr = [string]$cronReq.expression }
                if (-not $expr) { $expr = "*/5m" }
                $prompt = ""
                if ($cronReq.prompt) { $prompt = [string]$cronReq.prompt }
                if (-not $prompt) {
                    return @{ StatusCode = 400; Body = '{"error":"prompt is required"}' }
                }
                $enabled = $true
                if ($cronReq.enabled -ne $null) { $enabled = [bool]$cronReq.enabled }

                Register-CronJob -Name $name -Expression $expr -Prompt $prompt -Enabled $enabled

                return @{
                    StatusCode = 201
                    Body = ConvertTo-JsonSafe @{
                        status = "registered"
                        name = $name
                        expression = $expr
                        enabled = $enabled
                    }
                }
            }

            default {
                return @{ StatusCode = 404; Body = '{"error":"Not found"}' }
            }
        }
    } catch {
        $errMsg = @{ error = "Internal: $_" } | ConvertTo-Json -Compress
        return @{ StatusCode = 500; Body = $errMsg }
    }
}

# ============================================================================
#  Session Management
# ============================================================================

function New-DaemonSession {
    <#
    .SYNOPSIS
    Create a new daemon session with unique ID.
    Optionally accepts a system_prompt to override the default.
    #>
    param([string]$SystemPrompt = "")

    $sessionId = "sess_$(Get-Random)"
    $session = @{
        id = $sessionId
        created = Get-TimestampMs
        status = "idle"
        system_prompt = $SystemPrompt
        messages = @()
    }
    $global:DAEMON_SESSIONS[$sessionId] = $session
    Save-DaemonSession $session

    $body = @{ session_id = $sessionId } | ConvertTo-Json -Compress
    return @{ StatusCode = 201; Body = $body; SessionId = $sessionId }
}

function Get-DaemonSessionList {
    <#
    .SYNOPSIS
    Return summary list of all active sessions.
    #>
    $list = @()
    foreach ($id in @($global:DAEMON_SESSIONS.Keys)) {
        $session = $global:DAEMON_SESSIONS[$id]
        $msgCount = 0
        if ($session.messages) { $msgCount = @($session.messages).Count }
        $list += @{
            id = $id
            status = $session.status
            message_count = $msgCount
            created = $session.created
        }
    }
    return $list
}

function Get-DaemonIndexPage {
    <#
    .SYNOPSIS
    Generate HTML dashboard page with live stats and API documentation.
    #>
    $sessionCount = @($global:DAEMON_SESSIONS.Keys).Count
    $cronCount = @($global:CRON_JOBS.Keys).Count
    $model = $global:PA_MODEL

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PowerAgent Daemon</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; background: #1a1a2e; color: #eee; }
  h1 { color: #e94560; border-bottom: 2px solid #e94560; padding-bottom: 10px; }
  h2 { color: #0f3460; background: #16213e; padding: 8px 12px; border-radius: 4px; margin-top: 30px; }
  .status { display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin: 20px 0; }
  .stat { background: #16213e; padding: 15px; border-radius: 8px; text-align: center; }
  .stat .num { font-size: 2em; font-weight: bold; color: #e94560; }
  .stat .label { font-size: 0.85em; color: #aaa; margin-top: 5px; }
  code { background: #16213e; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }
  pre { background: #16213e; padding: 12px; border-radius: 6px; overflow-x: auto; line-height: 1.4; }
  .method { font-weight: bold; }
  .get { color: #4CAF50; }
  .post { color: #FF9800; }
  .delete { color: #f44336; }
  table { width: 100%; border-collapse: collapse; margin: 10px 0; }
  td { padding: 8px; border-bottom: 1px solid #333; }
  td:first-child { font-family: monospace; white-space: nowrap; }
</style>
</head>
<body>
<h1>PowerAgent Daemon</h1>
<div class="status">
  <div class="stat"><div class="num">$sessionCount</div><div class="label">Sessions</div></div>
  <div class="stat"><div class="num">$cronCount</div><div class="label">Cron Jobs</div></div>
  <div class="stat"><div class="num">$model</div><div class="label">Model</div></div>
</div>
<h2>API Endpoints</h2>
<table>
  <tr><td><span class="method post">POST</span> /v1/session/new</td><td>Create new session</td></tr>
  <tr><td><span class="method post">POST</span> /v1/chat</td><td>One-shot chat (create + execute)</td></tr>
  <tr><td><span class="method get">GET</span>  /v1/sessions</td><td>List all sessions</td></tr>
  <tr><td><span class="method get">GET</span>  /v1/session/{id}</td><td>Get session detail</td></tr>
  <tr><td><span class="method post">POST</span> /v1/session/{id}</td><td>Send message to session</td></tr>
  <tr><td><span class="method get">GET</span>  /v1/session/{id}/stream</td><td>SSE streaming response</td></tr>
  <tr><td><span class="method delete">DELETE</span> /v1/session/{id}</td><td>Delete session</td></tr>
  <tr><td><span class="method get">GET</span>  /v1/cron</td><td>List cron jobs</td></tr>
  <tr><td><span class="method post">POST</span> /v1/cron</td><td>Register cron job</td></tr>
</table>
<h2>Example: One-shot Chat</h2>
<pre>curl -X POST http://localhost:9655/v1/chat ^
  -H "Content-Type: application/json" ^
  -d "{\"message\": \"Hello, who are you?\"}"</pre>
<h2>Example: Session Chat</h2>
<pre>curl -X POST http://localhost:9655/v1/session/new
curl -X POST http://localhost:9655/v1/session/sess_12345 ^
  -H "Content-Type: application/json" ^
  -d "{\"message\": \"Remember this: my name is Alice\"}"
curl -X POST http://localhost:9655/v1/session/sess_12345 ^
  -H "Content-Type: application/json" ^
  -d "{\"message\": \"What is my name?\"}"</pre>
<h2>Example: SSE Streaming</h2>
<pre>curl -N http://localhost:9655/v1/session/sess_12345/stream ^
  -H "Content-Type: application/json" ^
  -d "{\"message\": \"Tell me a story\"}"</pre>
<h2>Example: Cron Job</h2>
<pre>curl -X POST http://localhost:9655/v1/cron ^
  -H "Content-Type: application/json" ^
  -d "{\"name\": \"daily_summary\", \"expression\": \"0 9 * * *\", \"prompt\": \"Summarize today events\"}"</pre>
<p style="color: #666; margin-top: 30px;">PowerAgent v0.4 | PID $PID</p>
</body>
</html>
"@
}

# ============================================================================
#  Cron Scheduler
# ============================================================================

$global:CRON_JOBS = @{}
$global:CRON_TIMER = $null

function Parse-CronExpression {
    <#
    .SYNOPSIS
    Parse cron expression into a schedule descriptor.
    Supports two formats:
      1. Simple: "*/N s|m|h"  (e.g., "*/5m", "*/30s", "*/1h")
      2. Standard 5-field: "min hour day month dow"  (e.g., "0 9 * * *")
    Returns a hashtable with type + schedule data.
    #>
    param([string]$Expression)

    $expr = $Expression.Trim()

    # ── Format 1: Simple interval "*/N s|m|h" ──
    if ($expr -match '^\*/(\d+)\s*(s|m|h)$') {
        $n = [int]$Matches[1]
        $unit = $Matches[2]
        switch ($unit) {
            "s" { return @{ type = "interval"; intervalMs = $n * 1000 } }
            "m" { return @{ type = "interval"; intervalMs = $n * 60000 } }
            "h" { return @{ type = "interval"; intervalMs = $n * 3600000 } }
        }
    }

    # ── Format 2: Standard 5-field cron "min hour dom month dow" ──
    $fields = $expr -split '\s+'
    if ($fields.Count -eq 5) {
        try {
            $parsed = @{
                type   = "cron5"
                minute = Invoke-ParseCronField $fields[0] 0 59
                hour   = Invoke-ParseCronField $fields[1] 0 23
                dom    = Invoke-ParseCronField $fields[2] 1 31
                month  = Invoke-ParseCronField $fields[3] 1 12
                dow    = Invoke-ParseCronField $fields[4] 0 7
            }
            return $parsed
        } catch {
            Write-Log "WARN: Invalid 5-field cron '$expr': $_"
        }
    }

    # ── Fallback: default 5 minutes ──
    Write-Log "WARN: Invalid cron expression '$expr', defaulting to */5m"
    return @{ type = "interval"; intervalMs = 300000 }
}

function Invoke-ParseCronField {
    <#
    .SYNOPSIS
    Parse a single cron field. Returns $null (match all) or array of ints.
    Supports: * (any), */N (step), N (exact), N-M (range), N,M,K (list), N-M/S (range+step).
    #>
    param(
        [string]$Field,
        [int]$Min,
        [int]$Max
    )

    # ── Wildcard * ──
    if ($Field -eq "*") {
        return $null  # null = match all values
    }

    $values = @()

    # ── Comma-separated list ──
    $parts = $Field -split ','

    foreach ($part in $parts) {
        $p = $part.Trim()

        # ── Range with step: N-M/S ──
        if ($p -match '^(\d+)-(\d+)/(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            $step = [int]$Matches[3]
            for ($i = $start; $i -le $end; $i += $step) {
                $values += $i
            }
        }
        # ── Step: */N ──
        elseif ($p -match '^\*/(\d+)$') {
            $step = [int]$Matches[1]
            for ($i = $Min; $i -le $Max; $i += $step) {
                $values += $i
            }
        }
        # ── Range: N-M ──
        elseif ($p -match '^(\d+)-(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            for ($i = $start; $i -le $end; $i++) {
                $values += $i
            }
        }
        # ── Exact value: N ──
        elseif ($p -match '^(\d+)$') {
            $values += [int]$Matches[1]
        }
        else {
            Write-Log "WARN: Invalid cron field '$p' in expression"
        }
    }

    # Deduplicate and sort
    if ($values.Count -gt 0) {
        $values = @($values | Sort-Object -Unique)
    }
    return $values
}

function Test-CronMatch {
    <#
    .SYNOPSIS
    Test if the current time matches a parsed cron expression.
    For 'interval' type, checks elapsed time since last run.
    For 'cron5' type, checks current minute/hour/day/month/dow against parsed fields.
    Prevents double-fire within the same minute for 5-field cron.
    #>
    param(
        $Parsed,       # Output of Parse-CronExpression
        [long]$LastRunMs
    )

    # ── Interval type ──
    if ($Parsed.type -eq "interval") {
        $now = Get-TimestampMs
        return (($now - $LastRunMs) -ge $Parsed.intervalMs)
    }

    # ── 5-field cron type ──
    if ($Parsed.type -eq "cron5") {
        $now = Get-Date
        $minute = $now.Minute
        $hour = $now.Hour
        $dom = $now.Day
        $month = $now.Month
        $dow = [int]$now.DayOfWeek  # 0=Sunday

        # Check each field ($null = match all)
        if ($null -ne $Parsed.minute -and $Parsed.minute -notcontains $minute) { return $false }
        if ($null -ne $Parsed.hour -and $Parsed.hour -notcontains $hour) { return $false }
        if ($null -ne $Parsed.dom -and $Parsed.dom -notcontains $dom) { return $false }
        if ($null -ne $Parsed.month -and $Parsed.month -notcontains $month) { return $false }
        if ($null -ne $Parsed.dow) {
            # Day 7 = Sunday (same as 0 in standard cron)
            $dowMatch = ($Parsed.dow -contains $dow) -or ($dow -eq 0 -and $Parsed.dow -contains 7)
            if (-not $dowMatch) { return $false }
        }

        # Prevent double-fire: skip if already ran in this exact minute
        if ($LastRunMs -gt 0) {
            try {
                $lastRunDt = [DateTimeOffset]::FromUnixTimeMilliseconds($LastRunMs).LocalDateTime
                if ($lastRunDt.Year -eq $now.Year -and $lastRunDt.Month -eq $now.Month -and
                    $lastRunDt.Day -eq $now.Day -and $lastRunDt.Hour -eq $now.Hour -and
                    $lastRunDt.Minute -eq $now.Minute) {
                    return $false
                }
            } catch { }
        }

        return $true
    }

    return $false
}

function Register-CronJob {
    <#
    .SYNOPSIS
    Register a cron job with parsed expression.
    #>
    param(
        [string]$Name,
        [string]$Expression,
        [string]$Prompt,
        [bool]$Enabled = $true
    )
    $parsed = Parse-CronExpression $Expression
    $intervalMs = 0
    if ($parsed.type -eq "interval") { $intervalMs = $parsed.intervalMs }

    $global:CRON_JOBS[$Name] = @{
        name       = $Name
        expression = $Expression
        parsed     = $parsed
        intervalMs = $intervalMs
        prompt     = $Prompt
        enabled    = $Enabled
        lastRun    = 0
        runCount   = 0
        lastResult = ""
        lastError  = ""
    }
    Write-Log "DEBUG: Registered cron job '$Name' type=$($parsed.type) expr='$Expression'"
}

function Import-CronConfig {
    <#
    .SYNOPSIS
    Read cron jobs from settings (4-tier config) and register them.
    Supports both 'interval' and 'expression' keys in config entries.
    #>
    $cronConfig = Get-Setting "cron"
    if ($cronConfig -and $cronConfig -is [array]) {
        foreach ($job in $cronConfig) {
            $name = "cron_$(Get-Random)"
            if ($job.name) { $name = [string]$job.name }
            # Support both 'interval' (legacy) and 'expression' (new) keys
            $expr = "*/5m"
            if ($job.expression) { $expr = [string]$job.expression }
            elseif ($job.interval) { $expr = [string]$job.interval }
            $prompt = ""
            if ($job.prompt) { $prompt = [string]$job.prompt }
            $enabled = $true
            if ($job.enabled -ne $null) { $enabled = [bool]$job.enabled }
            Register-CronJob -Name $name -Expression $expr -Prompt $prompt -Enabled $enabled
        }
    }
}

function Start-CronScheduler {
    <#
    .SYNOPSIS
    Start the cron scheduler timer.
    Checks every 30 seconds for due jobs and executes their prompts via API call.
    #>
    if ($global:CRON_TIMER) { return }

    $jobCount = @($global:CRON_JOBS.Keys).Count
    if ($jobCount -eq 0) {
        Write-Log "DEBUG: No cron jobs to schedule"
        return
    }

    $global:CRON_TIMER = New-Object System.Timers.Timer
    $global:CRON_TIMER.Interval = 30000  # Check every 30 seconds
    $global:CRON_TIMER.AutoReset = $true

    Register-ObjectEvent -InputObject $global:CRON_TIMER -EventName Elapsed -Action {
        try {
            foreach ($name in @($global:CRON_JOBS.Keys)) {
                $job = $global:CRON_JOBS[$name]
                if (-not $job.enabled) { continue }
                if (-not $job.prompt) { continue }

                # ── Check if job is due ──
                $isDue = Test-CronMatch -Parsed $job.parsed -LastRunMs $job.lastRun
                if (-not $isDue) { continue }

                $now = Get-TimestampMs
                $global:CRON_JOBS[$name].lastRun = $now
                $global:CRON_JOBS[$name].runCount++
                Write-Log "INFO: Cron job '$name' triggered (run #$($job.runCount))"

                # ── Execute prompt via API call ──
                try {
                    $savedMessages = $global:MESSAGES
                    $global:MESSAGES = @()

                    $bodyJson = Build-ApiRequestBody -UserMessage $job.prompt -Tools @() `
                        -MaxTokens 0 -ThinkingBudget 0
                    $headers = Get-ApiHeaders
                    $result = Invoke-ApiCall -RequestBody $bodyJson -Url $global:PA_API_URL -Headers $headers

                    $global:MESSAGES = $savedMessages

                    if ($result.Success) {
                        $content = ""
                        foreach ($block in @($result.ContentBlocks)) {
                            if ($block.type -eq "text") { $content += $block.text }
                        }
                        $global:CRON_JOBS[$name].lastResult = $content
                        $global:CRON_JOBS[$name].lastError = ""
                        Write-Log "INFO: Cron job '$name' completed (tokens: $($result.InputTokens)+$($result.OutputTokens))"
                    } else {
                        $global:CRON_JOBS[$name].lastResult = ""
                        $global:CRON_JOBS[$name].lastError = $result.Error
                        Write-Log "WARN: Cron job '$name' API failed: $($result.Error)"
                    }
                } catch {
                    $global:CRON_JOBS[$name].lastResult = ""
                    $global:CRON_JOBS[$name].lastError = "$_"
                    Write-Log "WARN: Cron job '$name' execution error: $_"
                    try { $global:MESSAGES = $savedMessages } catch { }
                }
            }
        } catch {
            Write-Log "WARN: Cron scheduler tick error: $_"
        }
    } | Out-Null

    $global:CRON_TIMER.Start()
    Write-Log "INFO: Cron scheduler started with $jobCount jobs (check interval: 30s)"
}

function Stop-CronScheduler {
    <#
    .SYNOPSIS
    Stop the cron scheduler and dispose the timer.
    #>
    if ($global:CRON_TIMER) {
        $global:CRON_TIMER.Stop()
        $global:CRON_TIMER.Dispose()
        $global:CRON_TIMER = $null
    }
    Write-Log "INFO: Cron scheduler stopped"
}

function Get-CronStatus {
    <#
    .SYNOPSIS
    Return status of all registered cron jobs including last execution result.
    #>
    $status = @()
    foreach ($name in @($global:CRON_JOBS.Keys)) {
        $job = $global:CRON_JOBS[$name]
        $status += @{
            name       = $job.name
            expression = $job.expression
            type       = $job.parsed.type
            enabled    = $job.enabled
            lastRun    = $job.lastRun
            runCount   = $job.runCount
            lastResult = $job.lastResult
            lastError  = $job.lastError
        }
    }
    return $status
}


# ============================================================================
#  Entry Point (must be at end of file - PS 5.1 needs all functions registered)
# ============================================================================

# Only run main if this script is executed directly (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    Start-PowerAgent @args
}


