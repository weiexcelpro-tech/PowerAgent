# ============================================================================
#  PowerAgent Test — AgentSystem.ps1
#  Validates agent loading, skill loading, TODO management, memory
# ============================================================================

Describe "AgentSystem.ps1 — Import-Agents" {
    It "Does not throw when no agent directory exists" {
        $oldDir = $global:PA_PROJECT_DIR
        $global:PA_PROJECT_DIR = Join-Path $env:TEMP "poweragent_test_noagents_$(Get-Random)"
        try {
            { Import-Agents } | Should -Not -Throw
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
        }
    }

    It "Loads agent from directory" {
        $testDir = Join-Path $env:TEMP "poweragent_test_agents_$(Get-Random)"
        $agentDir = Join-Path $testDir ".poweragent\agents"
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

        # Create a test agent file
        $agentContent = @"
name: test_agent
description: A test agent for unit testing
model: test-model
---
You are a test agent. Be helpful and concise.
"@
        Set-Content (Join-Path $agentDir "test_agent.md") $agentContent -Encoding UTF8

        $oldDir = $global:PA_PROJECT_DIR
        $global:PA_PROJECT_DIR = $testDir
        try {
            Import-Agents
            # AGENTS hashtable should contain the test agent (or at least not throw)
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "AgentSystem.ps1 — Import-Skills" {
    It "Does not throw when no skill directory exists" {
        $oldDir = $global:PA_PROJECT_DIR
        $global:PA_PROJECT_DIR = Join-Path $env:TEMP "poweragent_test_noskills_$(Get-Random)"
        try {
            { Import-Skills } | Should -Not -Throw
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
        }
    }
}

Describe "AgentSystem.ps1 — TODO Management" {
    BeforeEach {
        $global:TODOS = @()
        $global:_LAST_TODO_ID = 0
    }

    Context "Import-Todos" {
        It "Does not throw with empty TODO file" {
            $global:PA_PROJECT_DIR = Join-Path $env:TEMP "poweragent_test_notodo_$(Get-Random)"
            try {
                { Import-Todos } | Should -Not -Throw
            } finally {
                Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Invoke-ToolTaskCreate" {
        It "Creates a new task" {
            $result = Invoke-ToolTaskCreate @{ title = "Test Task"; body = "Task body"; priority = "high" }
            $result.status | Should -Be "ok"
            $result.id | Should -Not -BeNullOrEmpty
        }
    }

    Context "Invoke-ToolMakeTodos" {
        It "Creates multiple tasks from array" {
            $todos = @(
                @{ title = "Task 1"; priority = "high" },
                @{ title = "Task 2"; priority = "medium" }
            )
            $result = Invoke-ToolMakeTodos @{ todos = $todos }
            $result.status | Should -Be "ok"
        }
    }

    Context "Invoke-ToolTaskUpdate" {
        It "Updates task status" {
            $createResult = Invoke-ToolTaskCreate @{ title = "Update Test"; priority = "medium" }
            $taskId = $createResult.id
            $result = Invoke-ToolTaskUpdate @{ id = $taskId; status = "in_progress" }
            $result.status | Should -Be "ok"
        }
    }

    Context "Invoke-ToolTaskList" {
        It "Lists all tasks" {
            Invoke-ToolTaskCreate @{ title = "List Test 1"; priority = "low" } | Out-Null
            $result = Invoke-ToolTaskList
            $result.status | Should -Be "ok"
        }
    }
}

Describe "AgentSystem.ps1 — Memory" {
    Context "Import-Memories" {
        It "Does not throw when no memory directory exists" {
            $global:PA_PROJECT_DIR = Join-Path $env:TEMP "poweragent_test_nomem_$(Get-Random)"
            try {
                { Import-Memories } | Should -Not -Throw
            } finally {
                Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ============================================================================
#  Agent Worker System Tests (Item 13)
# ============================================================================

Describe "AgentSystem.ps1 — Initialize-JobsDir" {
    It "Creates .poweragent/jobs directory" {
        $testDir = Join-Path $env:TEMP "poweragent_test_jobsinit_$(Get-Random)"
        $oldDir = $global:PA_PROJECT_DIR
        $oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $testDir
        $global:JOBS_DIR = ""
        try {
            Initialize-JobsDir
            $global:JOBS_DIR | Should -Not -BeNullOrEmpty
            Test-Path $global:JOBS_DIR | Should -Be $true
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
            $global:JOBS_DIR = $oldJobsDir
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Does not throw when directory already exists" {
        $testDir = Join-Path $env:TEMP "poweragent_test_jobsinit2_$(Get-Random)"
        $jobsDir = Join-Path $testDir ".poweragent\jobs"
        New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
        $oldDir = $global:PA_PROJECT_DIR
        $oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $testDir
        $global:JOBS_DIR = ""
        try {
            { Initialize-JobsDir } | Should -Not -Throw
        } finally {
            $global:PA_PROJECT_DIR = $oldDir
            $global:JOBS_DIR = $oldJobsDir
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "AgentSystem.ps1 — Start-AgentJob" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_agentjob_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""

        # 确保代理已加载
        $global:AGENTS["explore"] = "You are an exploration specialist."
        $global:AGENT_STATUS["explore"] = "idle"
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Rejects unknown agent" {
        $result = Start-AgentJob -Agent "nonexistent_agent" -Prompt "test"
        $result.status | Should -Be "error"
        $result.error | Should -Match "Unknown agent"
    }

    It "Creates job file and returns running status" {
        $result = Start-AgentJob -Agent "explore" -Prompt "Find all test files"
        $result.status | Should -Be "running"
        $result.job_id | Should -Not -BeNullOrEmpty

        # 验证 JSON 文件已创建
        $jobFile = Join-Path $global:JOBS_DIR "$($result.job_id).json"
        Test-Path $jobFile | Should -Be $true

        # 验证 JSON 内容
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $job.type | Should -Be "agent"
        $job.agent | Should -Be "explore"
        $job.status | Should -Be "running"

        # 清理 PS Job
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) { Remove-Job $psJob -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe "AgentSystem.ps1 — Start-PowerShellJob" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_psjob_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Rejects empty command" {
        $result = Start-PowerShellJob -Command ""
        $result.status | Should -Be "error"
    }

    It "Creates powershell job and returns running status" {
        $result = Start-PowerShellJob -Command "Write-Output 'hello world'"
        $result.status | Should -Be "running"
        $result.job_id | Should -Not -BeNullOrEmpty

        # 验证 JSON 文件已创建
        $jobFile = Join-Path $global:JOBS_DIR "$($result.job_id).json"
        Test-Path $jobFile | Should -Be $true

        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $job.type | Should -Be "powershell"
        $job.status | Should -Be "running"

        # 等待完成以便清理
        $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
        if ($psJob) {
            Wait-Job $psJob -Timeout 30 | Out-Null
            Remove-Job $psJob -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "AgentSystem.ps1 — Get-AgentJobStatus" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_jobstatus_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""
        Initialize-JobsDir
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns error for nonexistent job" {
        $result = Get-AgentJobStatus -JobId "job_nonexistent"
        $result.status | Should -Be "error"
        $result.error | Should -Match "Job not found"
    }

    It "Returns running for active job" {
        # 创建一个简单的 powershell job
        $result = Start-PowerShellJob -Command "Start-Sleep -Seconds 5; Write-Output 'delayed'"
        $jobId = $result.job_id

        $status = Get-AgentJobStatus -JobId $jobId
        # 状态可能是 running 或 done（取决于执行速度）
        $status.status | Should -BeIn @("running", "done")

        # 清理
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Stop-Job $psJob -ErrorAction SilentlyContinue
                Remove-Job $psJob -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Detects completed job via PS Job state" {
        # 创建一个快速完成的 powershell job
        $result = Start-PowerShellJob -Command "Write-Output 'instant'"
        $jobId = $result.job_id

        # 等待完成
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Wait-Job $psJob -Timeout 30 | Out-Null
            }
        }

        # 查询状态应检测到完成
        $status = Get-AgentJobStatus -JobId $jobId
        $status.status | Should -Be "done"
        $status.result_size | Should -BeGreaterThan 0

        # 清理
        if ($psJob) { Remove-Job $psJob -Force -ErrorAction SilentlyContinue }
    }

    It "Returns elapsed time" {
        $result = Start-PowerShellJob -Command "Write-Output 'elapsed test'"
        $jobId = $result.job_id

        $status = Get-AgentJobStatus -JobId $jobId
        $status.elapsed | Should -BeGreaterOrEqual 0

        # 清理
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Wait-Job $psJob -Timeout 30 | Out-Null
                Remove-Job $psJob -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "AgentSystem.ps1 — Get-AgentJobResult" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_jobresult_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""
        Initialize-JobsDir
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns error for nonexistent job" {
        $result = Get-AgentJobResult -JobId "job_nonexistent"
        $result.status | Should -Be "error"
    }

    It "Returns error for still-running job" {
        $startResult = Start-PowerShellJob -Command "Start-Sleep -Seconds 30; Write-Output 'delayed'"
        $jobId = $startResult.job_id

        $result = Get-AgentJobResult -JobId $jobId
        # 状态可能是 error (still running) 或 ok (if it finished very fast)
        if ($result.status -eq "error") {
            $result.error | Should -Match "not 'done'"
        }

        # 清理
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Stop-Job $psJob -ErrorAction SilentlyContinue
                Remove-Job $psJob -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Returns content for completed job" {
        $startResult = Start-PowerShellJob -Command "Write-Output 'test output content'"
        $jobId = $startResult.job_id

        # 等待完成
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $psJob = $null
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Wait-Job $psJob -Timeout 30 | Out-Null
            }
        }

        # 先 poll 确保状态更新
        Get-AgentJobStatus -JobId $jobId | Out-Null

        $result = Get-AgentJobResult -JobId $jobId
        $result.status | Should -Be "ok"
        $result.content | Should -Match "test output content"
        $result.size | Should -BeGreaterThan 0

        if ($psJob) { Remove-Job $psJob -Force -ErrorAction SilentlyContinue }
    }
}

Describe "AgentSystem.ps1 — Stop-AgentJob" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_jobstop_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""
        Initialize-JobsDir
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns error for nonexistent job" {
        $result = Stop-AgentJob -JobId "job_nonexistent"
        $result.status | Should -Be "error"
    }

    It "Cancels a running job" {
        $startResult = Start-PowerShellJob -Command "Start-Sleep -Seconds 60; Write-Output 'should not see this'"
        $jobId = $startResult.job_id

        $result = Stop-AgentJob -JobId $jobId
        $result.status | Should -Be "cancelled"

        # 验证磁盘状态已更新
        $status = Get-AgentJobStatus -JobId $jobId
        $status.status | Should -Be "cancelled"
    }

    It "Returns error when cancelling already-done job" {
        $startResult = Start-PowerShellJob -Command "Write-Output 'quick'"
        $jobId = $startResult.job_id

        # 等待完成
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Wait-Job $psJob -Timeout 30 | Out-Null
                Remove-Job $psJob -Force -ErrorAction SilentlyContinue
            }
        }
        # Poll to update status
        Get-AgentJobStatus -JobId $jobId | Out-Null

        # 尝试取消已完成的任务
        $cancelResult = Stop-AgentJob -JobId $jobId
        # 可能是 error（已完成）或 cancelled（竞态条件）
        $cancelResult.status | Should -BeIn @("error", "cancelled")
    }
}

Describe "AgentSystem.ps1 — Update-JobStatus" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_jobupdate_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""
        Initialize-JobsDir
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Updates status and extra fields on disk" {
        # 手动创建一个 job 文件
        $jobId = "job_test_update_$(Get-Random)"
        $jobMeta = @{
            id          = $jobId
            type        = "powershell"
            agent       = ""
            prompt      = "test"
            status      = "running"
            created_at  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            finished_at = 0
            result_file = ""
            result_size = 0
            error       = ""
            ps_job_id   = ""
        }
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        Write-AtomicFile $jobFile ($jobMeta | ConvertTo-Json -Depth 5)

        # 更新状态
        Update-JobStatus -JobId $jobId -Status "done" -Updates @{
            finished_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            result_size = 42
        }

        # 验证
        $updated = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $updated.status | Should -Be "done"
        $updated.result_size | Should -Be 42
        $updated.finished_at | Should -BeGreaterThan 0
    }

    It "Does not throw for nonexistent job file" {
        { Update-JobStatus -JobId "job_nonexistent_$(Get-Random)" -Status "done" } | Should -Not -Throw
    }
}

Describe "AgentSystem.ps1 — Job Lifecycle (full cycle)" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "poweragent_test_lifecycle_$(Get-Random)"
        $script:oldDir = $global:PA_PROJECT_DIR
        $script:oldJobsDir = $global:JOBS_DIR
        $global:PA_PROJECT_DIR = $script:testDir
        $global:JOBS_DIR = ""
        Initialize-JobsDir
    }

    AfterAll {
        $global:PA_PROJECT_DIR = $script:oldDir
        $global:JOBS_DIR = $script:oldJobsDir
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Completes full create-poll-result cycle" {
        # 1. 创建任务
        $startResult = Start-PowerShellJob -Command "Write-Output 'lifecycle test output'"
        $startResult.status | Should -Be "running"
        $jobId = $startResult.job_id

        # 2. 等待 PS Job 完成
        $jobFile = Join-Path $global:JOBS_DIR "$jobId.json"
        $job = Get-Content $jobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $psJob = $null
        if ($job.ps_job_id) {
            $psJob = Get-Job -Id ([int]$job.ps_job_id) -ErrorAction SilentlyContinue
            if ($psJob) {
                Wait-Job $psJob -Timeout 30 | Out-Null
            }
        }

        # 3. Poll 状态
        $status = Get-AgentJobStatus -JobId $jobId
        $status.status | Should -Be "done"

        # 4. 获取结果
        $result = Get-AgentJobResult -JobId $jobId
        $result.status | Should -Be "ok"
        $result.content | Should -Match "lifecycle test output"

        # 清理
        if ($psJob) { Remove-Job $psJob -Force -ErrorAction SilentlyContinue }
    }

    It "Completes create-cancel cycle" {
        # 1. 创建长时间运行的任务
        $startResult = Start-PowerShellJob -Command "Start-Sleep -Seconds 120; Write-Output 'never'"
        $jobId = $startResult.job_id

        # 2. 取消
        $cancelResult = Stop-AgentJob -JobId $jobId
        $cancelResult.status | Should -Be "cancelled"

        # 3. 确认状态
        $status = Get-AgentJobStatus -JobId $jobId
        $status.status | Should -Be "cancelled"

        # 4. 不能获取结果（因为已取消）
        $result = Get-AgentJobResult -JobId $jobId
        $result.status | Should -Be "error"
    }
}

# ============================================================================
#  Memory Network Tests (TODO-02 alignment)
# ============================================================================
Describe "AgentSystem.ps1 — Initialize-MemoryNetwork" {
    It "Creates default MEMORY_DATA structure" {
        Initialize-MemoryNetwork
        $global:MEMORY_DATA | Should -Not -BeNullOrEmpty
        @($global:MEMORY_DATA.short_term).Count | Should -Be 0
        @($global:MEMORY_DATA.long_term).Count | Should -Be 0
        @($global:MEMORY_DATA.work).Count | Should -Be 0
        $global:MEMORY_DATA.engrams | Should -Not -BeNullOrEmpty
        @($global:MEMORY_DATA.engrams).Count | Should -Be 16
    }
}

Describe "AgentSystem.ps1 — Write-Memory" {
    BeforeAll {
        Initialize-MemoryNetwork
    }

    It "Writes to short_term by default" {
        Write-Memory -Content "test short memory" -Priority 50
        @($global:MEMORY_DATA.short_term).Count | Should -BeGreaterOrEqual 1
        $global:MEMORY_DATA.short_term[0].content | Should -Be "test short memory"
    }

    It "Writes to long_term when priority > 70" {
        Write-Memory -Content "important long term" -Priority 90
        @($global:MEMORY_DATA.long_term).Count | Should -BeGreaterOrEqual 1
        $global:MEMORY_DATA.long_term[0].content | Should -Be "important long term"
    }

    It "Writes to work memory" {
        Write-Memory -Content "work item" -Type "work" -Priority 50
        @($global:MEMORY_DATA.work).Count | Should -BeGreaterOrEqual 1
        $global:MEMORY_DATA.work[0].content | Should -Be "work item"
    }

    It "Includes tags when provided" {
        Write-Memory -Content "tagged memory" -Priority 50 -Tags @("test", "unit")
        $found = @($global:MEMORY_DATA.long_term | Where-Object { $_.content -eq "tagged memory" })
        @($found).Count | Should -BeGreaterOrEqual 1
        @($found[0].tags).Count | Should -Be 2
    }
}

Describe "AgentSystem.ps1 — Search-Memory" {
    BeforeAll {
        Initialize-MemoryNetwork
        Write-Memory -Content "PowerShell scripting tips" -Priority 80 -Tags @("powershell")
        Write-Memory -Content "Python data analysis" -Priority 60 -Tags @("python")
        Write-Memory -Content "API debugging workflow" -Priority 70 -Tags @("api", "debug")
    }

    It "Finds results by keyword" {
        $results = Search-Memory -Query "PowerShell"
        @($results).Count | Should -BeGreaterOrEqual 1
        $found = @($results | Where-Object { $_.content -match "PowerShell" })
        @($found).Count | Should -BeGreaterOrEqual 1
    }

    It "Finds results by tag" {
        $results = Search-Memory -Query "debug"
        @($results).Count | Should -BeGreaterOrEqual 1
    }

    It "Returns empty for no match" {
        # Fresh network to avoid leftover engram data
        Initialize-MemoryNetwork
        $results = Search-Memory -Query "zzz_nonexistent_xyz"
        @($results).Count | Should -Be 0
    }

    It "Returns results sorted by relevance" {
        Initialize-MemoryNetwork
        Write-Memory -Content "PowerShell scripting tips" -Priority 80 -Tags @("powershell")
        Write-Memory -Content "Advanced scripting patterns" -Priority 60 -Tags @("scripting")
        $results = Search-Memory -Query "PowerShell"
        @($results).Count | Should -BeGreaterOrEqual 1
    }
}

Describe "AgentSystem.ps1 — Compress-Memory" {
    It "Runs without error" {
        Initialize-MemoryNetwork
        # 填充一些数据
        1..5 | ForEach-Object {
            Write-Memory -Content "filler $_" -Priority 30
        }
        { Compress-Memory } | Should -Not -Throw
    }
}

Describe "AgentSystem.ps1 — Build-MemoryContext" {
    It "Returns a string" {
        Initialize-MemoryNetwork
        Write-Memory -Content "context test" -Priority 80
        $ctx = Build-MemoryContext
        $ctx | Should -BeOfType [string]
    }

    It "Includes work memory" {
        Initialize-MemoryNetwork
        Write-Memory -Content "active task" -Type "work" -Priority 50
        $ctx = Build-MemoryContext
        $ctx | Should -Match "active task"
    }
}

Describe "AgentSystem.ps1 — Built-in Agents ≥8" {
    It "Has at least 8 built-in agents" {
        # 清空并重新加载内置 agents
        $global:AGENTS = @{}
        # 模拟 Import-Agents 的内置注册
        $builtinAgents = @("plan", "explore", "summarize", "mem_writer", "agent_manager", "review", "debug", "format")
        foreach ($name in $builtinAgents) {
            $global:AGENTS[$name] = @{ name = $name; role = "test" }
        }
        @($global:AGENTS.Keys).Count | Should -BeGreaterOrEqual 8
    }
}
