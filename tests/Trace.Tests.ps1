# ============================================================================
#  PowerAgent Test — Trace.ps1
#  Validates content-addressable file tracking and undo operations
# ============================================================================

Describe "Trace.ps1 — Initialize-Trace" {
    It "Does not throw" {
        { Initialize-Trace } | Should -Not -Throw
    }
}

Describe "Trace.ps1 — Hash Functions" {
    Context "Get-TraceHash" {
        It "Returns consistent SHA256 hash for same content" {
            $hash1 = Get-TraceHash "test content"
            $hash2 = Get-TraceHash "test content"
            $hash1 | Should -Be $hash2
        }

        It "Returns different hashes for different content" {
            $hash1 = Get-TraceHash "content A"
            $hash2 = Get-TraceHash "content B"
            $hash1 | Should -Not -Be $hash2
        }

        It "Returns 64-character hex string (SHA256)" {
            $hash = Get-TraceHash "test"
            $hash.Length | Should -Be 64
            $hash | Should -Match "^[0-9a-f]{64}$"
        }
    }
}

Describe "Trace.ps1 — Trace-Record / Read-TraceObject" {
    BeforeAll {
        $global:PA_TRACE_ENABLED = "1"
        $testDir = Join-Path $env:TEMP "poweragent_test_trace_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_PROJECT_DIR = $testDir
        $paDir = Join-Path $testDir ".poweragent"
        New-Item -ItemType Directory -Path (Join-Path $paDir "trace") -Force | Out-Null
        Initialize-Trace
    }

    AfterAll {
        Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Records a trace entry" {
        { Trace-Record "test_op" "test_file.txt" "original content" } | Should -Not -Throw
    }

    It "Reads a traced object" {
        Trace-Record "test_op2" "read_test.txt" "read content"
        $hash = Get-TraceHash "read content"
        $result = Read-TraceObject $hash
        $result | Should -Be "read content"
    }
}

Describe "Trace.ps1 — Trace-Undo" {
    It "Does not throw for empty trace" {
        { Trace-Undo 0 } | Should -Not -Throw
    }
}

Describe "Trace.ps1 — Trace-Log" {
    It "Does not throw" {
        { Trace-Log "Test trace log message" } | Should -Not -Throw
    }
}

# ============================================================================
#  NEW: Extended Trace tests — Snapshot, Prune, Log with data, Undo with data
#  ============================================================================

Describe "Trace.ps1 — Trace-Snapshot" {
    BeforeAll {
        $global:PA_TRACE_ENABLED = "1"
        $global:PA_TRACE_SNAPSHOT_INTERVAL = "0"
        $global:PA_TRACE_MAX_FRAMES = "1000"
        $global:PA_TRACE_PRUNE_KEEP = "100"
        $testDir = Join-Path $env:TEMP "poweragent_test_snap_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_PROJECT_DIR = $testDir
        Initialize-Trace
    }

    AfterAll {
        Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Does not throw" {
        { Trace-Snapshot } | Should -Not -Throw
    }

    It "Creates a snapshot file in TRACE_DIR_SNAPS" {
        Trace-Snapshot
        $snapFiles = Get-ChildItem -Path $global:TRACE_DIR_SNAPS -Filter "*.json"
        $snapFiles.Count | Should -BeGreaterOrEqual 1
    }

    It "Snapshot file contains valid JSON with head and timestamp fields" {
        Trace-Snapshot
        $snapFile = Get-ChildItem -Path $global:TRACE_DIR_SNAPS -Filter "*.json" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $snapFile | Should -Not -BeNullOrEmpty
        $data = Get-Content -Path $snapFile.FullName -Raw | ConvertFrom-Json
        $data.head | Should -Not -BeNullOrEmpty
        $data.timestamp | Should -Not -BeNullOrEmpty
    }
}

Describe "Trace.ps1 — Trace-Prune" {
    BeforeAll {
        $global:PA_TRACE_ENABLED = "1"
        $global:PA_TRACE_SNAPSHOT_INTERVAL = "0"
        $global:PA_TRACE_MAX_FRAMES = "1000"
        $testDir = Join-Path $env:TEMP "poweragent_test_prune_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_PROJECT_DIR = $testDir
        Initialize-Trace
    }

    AfterAll {
        Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Does not throw" {
        # 创建几帧，然后执行 prune
        $global:PA_TRACE_PRUNE_KEEP = "100"
        for ($i = 0; $i -lt 3; $i++) {
            Trace-Record "op_$i" "file_$i.txt" "content $i"
        }
        { Trace-Prune } | Should -Not -Throw
    }

    It "Removes frames below cutoff keeping last N" {
        # 重置 trace 状态，创建全新的环境
        $testDir2 = Join-Path $env:TEMP "poweragent_test_prune2_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir2 -Force | Out-Null
        try {
            $global:PA_PROJECT_DIR = $testDir2
            Initialize-Trace

            $global:PA_TRACE_PRUNE_KEEP = "2"
            # 创建 5 帧
            for ($i = 0; $i -lt 5; $i++) {
                Trace-Record "prune_op_$i" "prune_file_$i.txt" "prune content $i"
            }

            # HEAD 应该是 5
            $global:TRACE_HEAD | Should -Be 5

            # 执行 prune，保留最后 2 帧
            Trace-Prune

            # 前 3 帧 (0,1,2) 应该被删除
            $remaining = Get-ChildItem -Path $global:TRACE_DIR_FRAMES -Filter "*.json"
            $remaining.Count | Should -Be 2

            # 验证剩余的是第 3 和第 4 帧（HEAD-2 和 HEAD-1）
            $remainingNames = $remaining.Name | Sort-Object
            $remainingNames | Should -Contain "3.json"
            $remainingNames | Should -Contain "4.json"
        } finally {
            Remove-Item $testDir2 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Trace.ps1 — Trace-Log with data" {
    BeforeAll {
        $global:PA_TRACE_ENABLED = "1"
        $global:PA_TRACE_SNAPSHOT_INTERVAL = "0"
        $global:PA_TRACE_MAX_FRAMES = "1000"
        $global:PA_TRACE_PRUNE_KEEP = "100"
        $testDir = Join-Path $env:TEMP "poweragent_test_logdata_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_PROJECT_DIR = $testDir
        Initialize-Trace
    }

    AfterAll {
        Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns empty result when no frames exist" {
        $result = Trace-Log -Count 20
        # Trace-Log returns $null for empty, not @() — wrap in @()
        @($result).Count | Should -Be 0
    }

    It "Returns frames after Trace-Record calls" {
        Trace-Record "log_op" "log_file.txt" "log content"
        $result = Trace-Log -Count 20
        @($result).Count | Should -BeGreaterOrEqual 1
    }

    It "Frames have id, path, operation, timestamp properties" {
        Trace-Record -Path "prop_file.txt" -Operation "prop_op" -OldContent "prop content"
        $result = Trace-Log -Count 20
        $frames = @($result)
        # Find the frame we just created (should be the last one)
        $frame = $frames[-1]
        $frame.id | Should -Not -BeNullOrEmpty
        # Verify frame has the expected properties
        $frame.path | Should -Not -BeNullOrEmpty
        $frame.operation | Should -Not -BeNullOrEmpty
        $frame.timestamp | Should -Not -BeNullOrEmpty
        # Verify specific values: operation should match what we recorded
        $frame.operation | Should -Be "prop_op"
    }

    It "Respects Count parameter" {
        # 创建 10 帧
        for ($i = 0; $i -lt 10; $i++) {
            Trace-Record "count_op_$i" "count_file_$i.txt" "count content $i"
        }
        $result = Trace-Log -Count 5
        @($result).Count | Should -Be 5
    }
}

Describe "Trace.ps1 — Trace-Undo with data" {
    BeforeAll {
        $global:PA_TRACE_ENABLED = "1"
        $global:PA_TRACE_SNAPSHOT_INTERVAL = "0"
        $global:PA_TRACE_MAX_FRAMES = "1000"
        $global:PA_TRACE_PRUNE_KEEP = "100"
        $testDir = Join-Path $env:TEMP "poweragent_test_undodata_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $global:PA_PROJECT_DIR = $testDir
        Initialize-Trace
    }

    AfterAll {
        Remove-Item $global:PA_PROJECT_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns error status when no frames exist (HEAD=0)" {
        # 全新的 trace 环境，HEAD=0
        $result = Trace-Undo
        $result.status | Should -Be "error"
        $result.error | Should -Not -BeNullOrEmpty
    }

    It "Undoes a single edit operation and restores original content" {
        $undoDir = Join-Path $env:TEMP "poweragent_test_undo_edit_$(Get-Random)"
        New-Item -ItemType Directory -Path $undoDir -Force | Out-Null
        try {
            $testFile = Join-Path $undoDir "edit_test.txt"
            $originalContent = "original line"
            Set-Content $testFile $originalContent -NoNewline -Encoding UTF8

            # 保存当前 trace 状态
            $savedProjectDir = $global:PA_PROJECT_DIR
            $global:PA_PROJECT_DIR = $undoDir
            Initialize-Trace

            # 记录编辑操作
            Trace-Record $testFile "edit" $originalContent "modified line"

            # 验证 HEAD 已经推进
            $global:TRACE_HEAD | Should -Be 1

            # 执行撤销
            $result = Trace-Undo

            $result.status | Should -Be "ok"

            # 验证文件内容已恢复
            $restored = Get-Content $testFile -Raw -Encoding UTF8
            $restored | Should -Be $originalContent

            # 恢复全局状态
            $global:PA_PROJECT_DIR = $savedProjectDir
            Initialize-Trace
        } finally {
            Remove-Item $undoDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns status ok and correct undone count" {
        $ctDir = Join-Path $env:TEMP "poweragent_test_undo_ct_$(Get-Random)"
        New-Item -ItemType Directory -Path $ctDir -Force | Out-Null
        try {
            $savedProjectDir = $global:PA_PROJECT_DIR
            $global:PA_PROJECT_DIR = $ctDir
            Initialize-Trace

            # 记录 3 帧
            for ($i = 0; $i -lt 3; $i++) {
                Trace-Record "undo_ct_file_$i.txt" "edit" "old_$i" "new_$i"
            }

            # 撤销 2 步
            $result = Trace-Undo -Steps 2
            $result.status | Should -Be "ok"
            @($result.undone).Count | Should -Be 2
            $result.new_head | Should -Be 1

            $global:PA_PROJECT_DIR = $savedProjectDir
            Initialize-Trace
        } finally {
            Remove-Item $ctDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Trace.ps1 — Trace round-trip (record -> read -> undo)" {
    It "Full lifecycle: create file, record edit, undo, verify original content" {
        $rtDir = Join-Path $env:TEMP "poweragent_test_rt_$(Get-Random)"
        New-Item -ItemType Directory -Path $rtDir -Force | Out-Null
        try {
            $testFile = Join-Path $rtDir "roundtrip.txt"
            $originalContent = "version 1"
            Set-Content $testFile $originalContent -NoNewline -Encoding UTF8

            $savedProjectDir = $global:PA_PROJECT_DIR
            $global:PA_PROJECT_DIR = $rtDir
            Initialize-Trace

            # Step 1: Record edit
            Trace-Record $testFile "edit" $originalContent "version 2"

            # Step 2: Verify frame was recorded
            $global:TRACE_HEAD | Should -Be 1

            # Step 3: Read the trace object to verify old content is stored
            $hash = Get-TraceHash $originalContent
            $stored = Read-TraceObject $hash
            $stored | Should -Be $originalContent

            # Step 4: Undo the edit
            $result = Trace-Undo
            $result.status | Should -Be "ok"

            # Step 5: Verify original content restored
            $final = Get-Content $testFile -Raw -Encoding UTF8
            $final | Should -Be $originalContent

            # Step 6: HEAD should be back to 0
            $global:TRACE_HEAD | Should -Be 0

            # Restore global state
            $global:PA_PROJECT_DIR = $savedProjectDir
            Initialize-Trace
        } finally {
            Remove-Item $rtDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
