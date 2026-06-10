# tests/AGENTS.md — PowerAgent Test Suite

> Testing knowledge base for the PowerAgent-v0.4 test suite.

## Overview

- **Framework**: Pester v5 (`Install-Module Pester -MinimumVersion 5.0.0`, auto-installs)
- **Total**: ~562 `It` cases across 21 `.Tests.ps1` files, ~8187 lines of test code
- **Source under test**: Tests dot-source `PowerAgent-merged.ps1` (single merged artifact, NOT `PowerAgent.ps1`)

## How to Run

```powershell
# Full suite (from project root)
.\tests\run_tests.ps1

# Specific module
.\tests\run_tests.ps1 -TestFile "Tools"
.\tests\run_tests.ps1 -TestFile "AgentLoop"

# Verbose output
.\tests\run_tests.ps1 -Verbose

# Single file batch (for CI)
powershell -File .\tests\run_batch.ps1 Tools.Tests.ps1
```

## Test Architecture (4 Layers)

| Layer | Files | Cases | Description |
|-------|-------|-------|-------------|
| **Unit** | 12 files (1:1 with lib modules) | ~481 | Isolated function testing per module |
| **Integration** | `Integration.Tests.ps1` | 14 | Cross-module init sequence, save/load cycles |
| **E2E Mocked** | `E2E.Tests.ps1` | 39 | Full pipeline with simulated API (`ConvertTo-OpenAIResponse`) |
| **E2E Live** | `E2E.Live.Tests.ps1`, `E2E.Scenarios.Tests.ps1`, `E2E.TC01-09.Tests.ps1` | ~37+ | Real DeepSeek API calls, gated by `$env:DEEPSEEK_API_KEY` |

## Unit Test Files (Module Map)

| Test File | Lines | Describe Blocks | It Cases | Module Covered |
|-----------|-------|-----------------|----------|----------------|
| `AgentLoop.Tests.ps1` | 1110 | 19 | 126 | AgentLoop |
| `AgentSystem.Tests.ps1` | 705 | 18 | 42 | AgentSystem |
| `HttpClient.Tests.ps1` | 914 | 16 | 56 | HttpClient |
| `Utils.Tests.ps1` | 563 | 19 | 81 | Utils |
| `Tools.Tests.ps1` | 314 | 11 | 31 | Tools |
| `Trace.Tests.ps1` | 353 | 10 | 21 | Trace |
| `Compression.Tests.ps1` | 247 | 13 | 25 | Compression |
| `Messages.Tests.ps1` | 209 | 6 | 23 | Messages |
| `Daemon.Tests.ps1` | 274 | 9 | 36 | Daemon |
| `Config.Tests.ps1` | 158 | 4 | 14 | Config |
| `McpClient.Tests.ps1` | 123 | 7 | 18 | McpClient |
| `Defaults.Tests.ps1` | 94 | 1 | 20 | Defaults |

## E2E Scenario Test Cases

TC directories contain Chinese-named business scenario test data:

| Dir | Scenario | Test File |
|-----|----------|-----------|
| `TC01-数据清洗与格式化` | Data cleaning & formatting | `E2E.TC01.Tests.ps1` |
| `TC02-数据汇总` | Data aggregation | `E2E.TC02.Tests.ps1` |
| `TC03-图表生成` | Chart generation | `E2E.TC03.Tests.ps1` |
| `TC04-内容撰写与润色` | Content writing & polish | — |
| `TC05-格式调整与排版` | Format & layout | — |
| `TC06-网络信息搜集与整理` | Web info gathering | — |
| `TC07-合同审查` | Contract review | — |
| `TC08-批量文件处理` | Batch file processing | `E2E.TC08.Tests.ps1` |
| `TC09-工作空间文件整理` | Workspace file organization | `E2E.TC09.Tests.ps1` |
| `TC10-创建网页小应用` | Web app creation | — |
| `TC11-自定义skill导入` | Custom skill import | — |

## Test Conventions & Patterns

### Structure

```powershell
Describe "Module: FeatureName" {
    BeforeEach {
        $savedVar = $global:SOME_VAR        # Save global state
        $global:SOME_VAR = "test-value"      # Set test value
    }
    AfterEach {
        $global:SOME_VAR = $savedVar         # Restore
    }

    Context "Edge case description" {
        It "Should do X when Y" {
            $result | Should -Be "expected"
        }
    }
}
```

### Key Patterns

1. **Scope promotion**: Pester v5 has isolated scope. `run_tests.ps1` promotes `$script:` vars to `$global:` so tests can access them.
2. **Mocking**: Function override via `function global:FunctionName { return <mock> }` — PS5.1 compatible, NOT Pester's `Mock` keyword.
3. **Test isolation**: Uses `$env:TEMP` + `Get-Random` for temp file paths; always cleans up in `finally` blocks.
4. **CJK testing**: Dedicated blocks for Chinese file paths and content (e.g., `中文文件.txt`).
5. **Shared fixtures**: `TestData.ps1` provides `$script:TEST_MESSAGES`, `$script:TEST_AGENT_DEF`, `$script:TEST_SETTINGS_JSON`, `$script:TEST_TODO_ITEMS`.
6. **Assertions**: Pester `Should` — `-Be`, `-Match`, `-BeGreaterThan`, `-Throw`, `-Not -Throw`, `-BeNullOrEmpty`.
7. **Live test gate**: Live E2E tests auto-skip if `DEEPSEEK_API_KEY` not set.
8. **Bug regression**: Tests reference specific bugs (Bug 3: tool result truncation, Bug 4: loop detection).

### Test Environment Variables

`run_tests.ps1` sets these to prevent real side effects:

```powershell
$env:PA_API_KEY = "test-key-12345"
$env:PA_API_URL = "http://localhost:9999"
$env:PA_MCP_ENABLED = "false"
$env:PA_TRACE_ENABLED = "0"
$env:PA_MEMORY_ENABLED = "false"
$env:PA_LOG_LEVEL = "ERROR"
```

## Infrastructure Files

| File | Purpose |
|------|---------|
| `run_tests.ps1` | Main runner (101 lines). Auto-installs Pester, dot-sources, runs suite. |
| `run_batch.ps1` | Single-file runner (62 lines). For CI pipelines. |
| `TestData.ps1` | Shared test data fixtures (49 lines). |
| `_check_funcs.ps1` | Function existence checker. |
| `_check_parse.ps1` | Parse checker. |
| `_check_syntax.ps1` | Syntax checker. |
| `_fix_scope.ps1` | Temporary script to replace `$script:` with `$global:` (workaround). |
| `_run_tc01.ps1` | TC01 scenario runner. |
| `_test_minimal.ps1` | Minimal smoke test. |
| `_test_pattern.ps1` | Pattern test. |
| `_test_scope.ps1` | Scope verification test. |

## Rules

- **Never** modify `PowerAgent-merged.ps1` manually — it's a build artifact
- **Always** add tests for new functions in the corresponding `.Tests.ps1` file
- **Always** use `BeforeEach`/`AfterEach` for global state save/restore
- **Never** rely on test execution order — each `It` block must be independent
- **Always** gate live API tests with `$env:DEEPSEEK_API_KEY` check
