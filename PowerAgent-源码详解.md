---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'fa2525c1-fc9a-4964-9308-8dd0131bd0f4'
  PropagateID: 'fa2525c1-fc9a-4964-9308-8dd0131bd0f4'
  ReservedCode1: 'b0b05582-de3b-45bc-88d2-17d85663e821'
  ReservedCode2: 'b0b05582-de3b-45bc-88d2-17d85663e821'
---

# PowerAgent v0.9 源码分析文档

> 分析对象：`PowerAgent.ps1`（单文件单体架构，约 11,000 行，252 个函数）  
> 分析日期：2026-06-10

---

## 1. 整体架构概览

PowerAgent 是一个纯 PowerShell 5.1 实现的 AI Agent 运行时，采用**单文件内联架构**——将原本 13 个独立 `.ps1` 模块全部内联到一个脚本文件中。这种设计牺牲了可维护性，换取了零依赖、单文件分发的部署便利性。

### 1.1 架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PowerAgent v0.9                             │
│                                                                     │
│  ┌──────────┐  ┌──────────────┐  ┌─────────────┐  ┌────────────┐  │
│  │   CLI /   │  │    Start-    │  │   Daemon /  │  │    Cron     │  │
│  │ Bootstrap │──│ PowerAgent   │──│   HTTP API  │  │  Scheduler  │  │
│  │ (1-307)   │  │  (308-727)  │  │ (9977-11137)│  │ (10806-11137│  │
│  └──────────┘  └──────┬───────┘  └──────┬──────┘  └────────────┘  │
│                        │                  │                         │
│          ┌─────────────┼──────────────────┘                         │
│          ▼             ▼                                            │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    AgentLoop (8295-9974)                     │   │
│  │  REPL · Slash Commands · Turn Management · Loop Detection   │   │
│  └──┬──────────┬──────────┬──────────┬──────────┬─────────────┘   │
│     │          │          │          │          │                   │
│     ▼          ▼          ▼          ▼          ▼                   │
│  ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌──────────┐            │
│  │Config │ │Messages│ │Http  │ │Tools  │ │   Trace   │            │
│  │(2677- │ │(3209- │ │Client│ │(3971- │ │(5139-    │            │
│  │ 3168) │ │ 3330) │ │(3331-│ │ 5136) │ │  5395)   │            │
│  └───┬───┘ └───┬───┘ │ 3970)│ └──┬────┘ └──────────┘            │
│      │         │     └──┬───┘    │                                │
│      ▼         ▼        ▼        ▼                                 │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │              Compression (5396-5669)                         │   │
│  │  L0 Offload · L1 Eviction · Prompt Assembly · Token Budget  │   │
│  └───────────────────────┬─────────────────────────────────────┘   │
│                          │                                         │
│  ┌───────────────────────┼─────────────────────────────────────┐   │
│  │          AgentSystem (5670-6869)                            │   │
│  │  8 Agents · Skills · TODOs · Plans · Memory · Jobs         │   │
│  └───────────────────────┬─────────────────────────────────────┘   │
│                          │                                         │
│  ┌───────────────────────┼─────────────────────────────────────┐   │
│  │           McpClient (7046-8294)                             │   │
│  │  Stdio / SSE / HTTP Transports · JSON-RPC 2.0              │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │   Utils (1171-2676) · ModelProfiles (728-1170)             │   │
│  │   Logging · CJK UI · Spinner · ReadLine · FileLock · Hash  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 核心设计模式

| 模式                     | 说明                                                                              |
| ---------------------- | ------------------------------------------------------------------------------- |
| **4 层配置**              | `project > system > env > default`，由 `Get-Setting` 统一解析                         |
| **Stub-then-Override** | 文件前部定义空壳函数（463-466 行），后部模块覆盖为完整实现，确保 PS 5.1 解析顺序正确                              |
| **Hook 系统**            | `pre_turn` / `post_response` / `post_tool` / `on_stuck` 四个挂载点，支持脚本注入            |
| **多供应商抽象**             | `Build-ApiRequestBody` 统一构建请求体，Anthropic 协议走 `ConvertTo-AnthropicRequest` 转换    |
| **Thinking 模式**        | 支持 Anthropic 扩展思维、DeepSeek R1 推理，由 `PA_SHOW_THINKING` / `PA_THINKING_BUDGET` 控制 |
| **自适应循环**              | 同工具调用 3 次警告、5 次中止；max_tokens 循环检测；自动上下文压缩                                       |
| **内容寻址 Trace**         | Git 风格 SHA256 对象存储，支持文件修改的 LIFO 撤销                                              |
| **记忆网络**               | 16 槽 engram + 3 池（short_term / long_term / work），关键词 + 标签评分检索                   |

---

## 2. 模块详解

### 2.1 CLI / Bootstrap（1–307 行）

**职责**：命令行参数解析、安装/卸载/自更新/守护进程启动。

| 函数                 | 行号  | 功能                                  |
| ------------------ | --- | ----------------------------------- |
| `Resolve-CliArgs`  | 24  | 将 `@args` 解析为 mode + params         |
| `Invoke-Install`   | 109 | 安装 PowerAgent（写入 Profile shim、创建目录） |
| `Invoke-Uninstall` | 121 | 卸载 PowerAgent                       |
| `Invoke-Update`    | 175 | 从 GitHub Releases 自更新               |
| `Invoke-RunDaemon` | 232 | 以守护进程模式启动                           |

### 2.2 Start-PowerAgent（308–727 行）

**职责**：主入口函数，完成模式分发、配置导入、供应商初始化、Agent Loop 启动。

核心流程：

```
Start-PowerAgent
  ├─ Resolve-CliArgs           → 解析参数
  ├─ [install]    Invoke-Install
  ├─ [uninstall]  Invoke-Uninstall
  ├─ [update]     Invoke-Update
  ├─ [daemon]     Invoke-RunDaemon → Start-Daemon
  └─ [chat/oneshot]
       ├─ Import-Config         → 加载 55 项 PA_* 全局设置
       ├─ Import-Agents         → 注册 8 个内置子代理
       ├─ Import-Skills         → 加载系统+项目技能
       ├─ Import-Memories       → 恢复记忆网络
       ├─ Initialize-Mcp        → 连接 MCP 服务器
       ├─ Register-BuiltinSlashCommands
       └─ Start-AgentLoop       → 进入交互主循环
```

### 2.3 ModelProfiles / Defaults（728–1170 行）

**职责**：8 个 LLM 供应商的模型档案，包含 API URL、协议类型、模型列表。

| 供应商       | Key         | 协议        | 代表模型                             |
| --------- | ----------- | --------- | -------------------------------- |
| DeepSeek  | `deepseek`  | OpenAI    | deepseek-chat, deepseek-reasoner |
| OpenAI    | `openai`    | OpenAI    | gpt-4o, o3-mini                  |
| Anthropic | `anthropic` | Anthropic | claude-sonnet-4, claude-haiku-4  |
| 通义千问      | `qwen`      | OpenAI    | qwen-max, qwen-plus              |
| 文心一言      | `ernie`     | OpenAI    | ernie-4.0-8k                     |
| 智谱 GLM    | `zhipu`     | OpenAI    | glm-4-plus, glm-4-flash          |
| Moonshot  | `moonshot`  | OpenAI    | moonshot-v1-8k                   |
| MiniMax   | `minimax`   | OpenAI    | MiniMax-Text-01                  |

| 函数                     | 行号  | 功能          |
| ---------------------- | --- | ----------- |
| `Resolve-ModelProfile` | 728 | 模型名 → 供应商档案 |
| `Get-ModelProfile`     | 789 | 获取完整供应商档案   |

### 2.4 Utils（1171–2676 行）

**职责**：底层工具库，被所有上层模块依赖。涵盖日志、文件锁、CJK 宽度计算、终端 UI 渲染、ReadLine 等。

| 子域               | 函数                        | 行号        | 功能                         |
| ---------------- | ------------------------- | --------- | -------------------------- |
| **Slash 注册**     | `Register-Slash`          | 1171      | 注册斜杠命令处理器                  |
|                  | `Invoke-SlashDispatch`    | 1176      | 分发斜杠命令                     |
| **日志**           | `Write-LogFlush`          | 1193      | 刷新日志缓冲到磁盘                  |
|                  | `Initialize-Log`          | 1209      | 初始化日志文件和轮转                 |
|                  | `Write-Log`               | 1281      | 写日志条目                      |
|                  | `Write-Die`               | 1317      | 致命错误并退出                    |
|                  | `Write-AccessLog`         | 1324      | HTTP 访问日志                  |
| **时间戳**          | `Get-TimestampMs`         | 1371      | UTC 毫秒时间戳                  |
|                  | `Get-TimestampS`          | 1376      | UTC 秒时间戳                   |
| **端口/进程/锁**      | `Test-PortBusy`           | 1385      | 检测端口占用                     |
|                  | `Stop-PortProcess`        | 1398      | 杀端口占用进程                    |
|                  | `Request-Lock`            | 1422      | 阻塞式文件锁                     |
|                  | `Release-Lock`            | 1436      | 释放文件锁                      |
|                  | `Stop-ProcessTree`        | 1454      | 递归杀进程树                     |
|                  | `Test-ProcessAlive`       | 1461      | 检测进程存活                     |
| **文件/JSON/Hash** | `Write-AtomicFile`        | 1495      | 原子写文件（临时文件+重命名）            |
|                  | `ConvertFrom-JsonSafe`    | 1509      | 安全 JSON 解析                 |
|                  | `Get-ContentHash`         | 1532      | SHA256 哈希                  |
| **CJK / UI**     | `Get-StringDisplayWidth`  | 1544      | CJK 双宽字符感知的显示宽度            |
|                  | `Get-CjkPadRight/Left`    | 1625/1633 | CJK 感知的补齐                  |
|                  | `Start-SpinnerBg`         | 1666      | 后台 Spinner 线程              |
|                  | `Stop-SpinnerBg`          | 1707      | 停止 Spinner                 |
|                  | `Start-EscMonitor`        | 1754      | ESC 键监控                    |
|                  | `Read-HostWithCompletion` | 1848      | 富 readline（Tab 补全、括号粘贴、历史） |
|                  | `Write-UiDivider`         | 2360      | UI 分割线                     |
|                  | `Write-StatusBar`         | 2467      | 状态栏                        |
|                  | `Write-MarkdownLight`     | 2580      | 轻量 Markdown 终端渲染器          |

### 2.5 Config（2677–3168 行）

**职责**：Hook 系统、依赖检查、4 层配置查找、配置导入。

| 函数                       | 行号   | 功能                                        |
| ------------------------ | ---- | ----------------------------------------- |
| `Register-Hook`          | 2677 | 在挂载点注册钩子函数                                |
| `Invoke-HookFire`        | 2697 | 触发指定挂载点的所有钩子                              |
| `Import-Hooks`           | 2766 | 从 `.poweragent/hooks/` 加载钩子脚本             |
| `Test-Dependencies`      | 2785 | 检查必需依赖是否已安装                               |
| `Initialize-SystemDirs`  | 2817 | 创建系统级目录                                   |
| `Initialize-ProjectDirs` | 2848 | 创建项目级目录 `.poweragent/`                    |
| `Get-Setting`            | 2915 | 4 层配置查找（project > system > env > default） |
| `Save-Setting`           | 2940 | 保存设置到项目 settings.json                     |
| `Import-Config`          | 3011 | 加载全部 ~55 项 PA_* 全局设置                      |
| `Resolve-Protocol`       | 3169 | 从供应商解析 API 协议                             |
| `Import-PowerAgentMd`    | 3179 | 加载 POWERAGENT.md 项目上下文                    |

### 2.6 Messages（3209–3330 行）

**职责**：聊天消息的 CRUD——保存/加载/清空/追加。

| 函数                     | 行号   | 功能                        |
| ---------------------- | ---- | ------------------------- |
| `Save-History`         | 3209 | 将 MESSAGES 持久化到磁盘         |
| `Load-History`         | 3216 | 从磁盘加载 MESSAGES            |
| `Add-UserText`         | 3238 | 追加用户消息                    |
| `Add-AssistantMessage` | 3246 | 追加助手消息（支持 content blocks） |
| `Add-ToolResults`      | 3282 | 追加工具结果                    |
| `Get-MessagesJson`     | 3302 | 序列化 MESSAGES              |
| `Clear-History`        | 3307 | 清空 MESSAGES               |

### 2.7 HttpClient（3331–3970 行）

**职责**：HTTP 请求引擎，含 ESC/Ctrl+C 中断、SSE 流式、多供应商请求构建。

| 函数                           | 行号   | 功能                         |
| ---------------------------- | ---- | -------------------------- |
| `Invoke-HttpRequest`         | 3331 | 核心HTTP请求（支持中断、重试、流式）       |
| `Connect-SseStream`          | 3540 | SSE 流连接                    |
| `Build-ApiRequestBody`       | 3609 | 构建请求体（多供应商、Thinking 模式）    |
| `ConvertTo-AnthropicRequest` | 3738 | 将 OpenAI 格式转为 Anthropic 格式 |
| `Invoke-ApiCall`             | 3826 | 执行 API 调用（协议分发、流式、错误处理）    |
| `Get-ApiHeaders`             | 3919 | 构建当前供应商的请求头                |

### 2.8 Tools（3971–5136 行）

**职责**：28 个工具的 Schema 定义 + 14 个完整实现 + 若干 Stub（由 AgentSystem/McpClient 覆盖）。

**28 个内置工具**：

| 工具名                       | 实现方式             | 功能                    |
| ------------------------- | ---------------- | --------------------- |
| `read_file`               | 完整实现             | 读取文件                  |
| `write_file`              | 完整实现             | 写入文件（带 Trace 记录）      |
| `edit_file`               | 完整实现             | 搜索替换编辑文件              |
| `delete_file`             | 完整实现             | 删除文件                  |
| `list_files`              | 完整实现             | 列出目录文件                |
| `powershell`              | 完整实现             | 执行 PowerShell 命令      |
| `process_excel`           | 完整实现             | 通过 COM 操作 Excel       |
| `web_search`              | 完整实现             | 网页搜索（Bing + Baidu 解析） |
| `web_request`             | 完整实现             | HTTP 请求               |
| `request`                 | 完整实现             | 交互式多选对话框              |
| `agent`                   | Stub→AgentSystem | 委派子代理                 |
| `agent_status`            | Stub→AgentSystem | 代理状态查询                |
| `agent_batch`             | Stub→AgentSystem | 批量代理执行（最多 4 并行）       |
| `send_message`            | Stub             | 代理间通信                 |
| `check_messages`          | Stub             | 代理消息检查                |
| `job_poll/result/cancel`  | Stub→AgentSystem | 异步作业管理                |
| `skill/list_skills`       | Stub             | 技能系统                  |
| `list_agents`             | Stub→AgentSystem | 列出注册代理                |
| `list_mcp_tools`          | Stub→McpClient   | 列出 MCP 工具             |
| `undo`                    | Stub→Trace       | 文件修改撤销                |
| `task_create/update/list` | AgentSystem 实现   | TODO 任务管理             |
| `make_todos`              | AgentSystem 实现   | 从计划文本批量创建 TODO        |
| `remember`                | AgentSystem 实现   | 保存到长期记忆               |

### 2.9 Trace（5139–5395 行）

**职责**：内容寻址的文件修改追踪与撤销系统，采用 Git 风格的对象存储。

```
Trace 目录结构:
  .poweragent/trace/
    ├── HEAD          → 当前帧 ID
    ├── frames/       → 每次文件修改记录一帧
    │   ├── XX/       → SHA256 前两位
    │   │   └── YY... → JSON（文件路径、旧内容哈希、新内容哈希）
    ├── objects/      → 内容 Blob（按 SHA256 寻址）
    │   ├── XX/
    │   │   └── YY... → 原始文件内容
    └── snapshots/    → 定期全量快照
```

| 函数                  | 行号   | 功能                 |
| ------------------- | ---- | ------------------ |
| `Initialize-Trace`  | 5161 | 初始化 Trace 目录和 HEAD |
| `Write-TraceObject` | 5207 | 存储内容 Blob，返回哈希     |
| `Read-TraceObject`  | 5218 | 按哈希读取内容            |
| `Trace-Record`      | 5228 | 记录一帧文件修改           |
| `Trace-Undo`        | 5289 | LIFO 撤销：弹出帧、还原文件   |
| `Trace-Snapshot`    | 5372 | 定期全量快照             |
| `Trace-Prune`       | 5382 | 保留最近 N 帧，压缩旧对象     |

### 2.10 Compression（5396–5669 行）

**职责**：3 级上下文压缩管线 + 7 层系统提示词组装 + Token 预算管理。

**压缩管线**：

```
Compress-Context
  ├─ L0: Compress-Offload     → 磁盘卸载 + 冗余消除
  ├─ L1: Compress-ToolEvict   → 工具结果逐出
  └─ (L2: 由 L0/L1 联合完成)
```

**7 层系统提示词**：

```
Build-SystemPrompt
  ├─ Layer 1: 身份与角色定义
  ├─ Layer 2: 工作目录与环境信息
  ├─ Layer 3: 项目上下文 (POWERAGENT.md)
  ├─ Layer 4: 动态上下文 (env + git + memory + TODO)
  ├─ Layer 5: 工具使用规范
  ├─ Layer 6: 安全与边界约束
  └─ Layer 7: 输出格式指南
```

| 函数                           | 行号   | 功能                              |
| ---------------------------- | ---- | ------------------------------- |
| `Compress-Offload`           | 5429 | L0：磁盘卸载 + 去重                    |
| `Compress-ToolEvict`         | 5493 | L1：工具结果逐出                       |
| `Compress-Context`           | 5553 | 3 级压缩管线入口                       |
| `Build-SystemPrompt`         | 5565 | 7 层系统提示词组装                      |
| `Build-DynamicContext`       | 5606 | L4：动态上下文（简化版）                   |
| `Build-RequestTools`         | 5634 | 构建工具 JSON 数组（内置 + MCP）          |
| `Estimate-ContextTokens`     | 5644 | Token 估算                        |
| `Test-ContextWindowPressure` | 5653 | 3 级压力检测（safe / warn / critical） |

### 2.11 AgentSystem（5670–6869 行）

**职责**：子代理注册与调度、技能系统、TODO 管理、计划系统、记忆网络、后台作业。

**8 个内置子代理**：

| 代理              | 职责      |
| --------------- | ------- |
| `plan`          | 任务计划制定  |
| `explore`       | 代码/文件探索 |
| `summarize`     | 内容摘要    |
| `mem_writer`    | 记忆写入    |
| `agent_manager` | 代理管理    |
| `format`        | 格式化输出   |
| `review`        | 审查评审    |
| `debug`         | 调试分析    |

**记忆网络架构**：

```
MEMORY_DATA
  ├── short_term[]    → 近期对话关键信息
  ├── long_term[]     → 持久化知识
  ├── work[]          → 工作区临时数据
  ├── engrams[16]     → 16 槽哈希分布记忆
  └── meta            → 元数据（衰减参数等）
```

| 函数                            | 行号        | 功能                          |
| ----------------------------- | --------- | --------------------------- |
| `Import-Agents`               | 5730      | 加载 8 个内置代理 + 项目代理           |
| `Invoke-ToolAgent`            | 5857      | 委派子代理（同步/异步）                |
| `Invoke-AgentCore`            | 5905      | 代理核心执行（API 调用）              |
| `Invoke-ToolAgentBatch`       | 5945      | 批量代理执行（最多 4 并行）             |
| `Import-Skills`               | 5992      | 加载系统 + 项目技能                 |
| `Import-Todos` / `Save-Todos` | 6065/6078 | TODO 持久化                    |
| `Invoke-ToolMakeTodos`        | 6099      | 从计划文本批量创建 TODO              |
| `Invoke-PlanAutoTodo`         | 6250      | 从计划步骤自动生成 TODO              |
| `Initialize-MemoryNetwork`    | 6338      | 初始化记忆网络（16 engram 槽）        |
| `Write-Memory`                | 6357      | 写入记忆（自动路由到 short/long/work） |
| `Search-Memory`               | 6410      | 关键词 + 标签评分搜索                |
| `Compress-Memory`             | 6462      | 过期记忆回收                      |
| `Start-AgentJob`              | 6696      | 启动后台代理作业（Start-Job）         |
| `Get-AgentJobStatus/Result`   | 6870/6952 | 作业状态/结果查询                   |
| `Stop-AgentJob`               | 6994      | 取消运行中作业                     |

### 2.12 McpClient（7046–8294 行）

**职责**：MCP（Model Context Protocol）客户端，支持 Stdio / SSE / HTTP 三种传输协议。

```
MCP 调用链:
  Invoke-McpDispatchTool
    → Invoke-McpCallTool
      → New-McpRequest "tools/call"
      → Send-McpMessage ─┬→ Send-McpStdio   (子进程 stdin)
                         ├→ Send-McpSse     (HTTP POST)
                         └→ Send-McpHttp    (HTTP POST)
      → Receive-McpMessage ┬→ Receive-McpStdio (stdout 管道)
                           ├→ Receive-McpSse   (SSE 收件箱)
                           └→ Receive-McpHttp  (HTTP 响应)
```

| 函数                     | 行号   | 功能                    |
| ---------------------- | ---- | --------------------- |
| `Import-McpConfig`     | 7093 | 从设置加载 MCP 服务器定义       |
| `New-McpRequest`       | 7123 | 构建 JSON-RPC 2.0 请求    |
| `Connect-McpStdio`     | 7178 | Stdio 传输连接（子进程）       |
| `Connect-McpSse`       | 7423 | SSE 传输连接              |
| `Connect-McpHttp`      | 7615 | HTTP 传输连接             |
| `Connect-McpServer`    | 7714 | 传输协议无关的连接分发器          |
| `Initialize-McpServer` | 7859 | MCP 协议握手              |
| `Get-McpTools`         | 7917 | 获取 MCP 工具列表（mcp__ 前缀） |
| `Invoke-McpCallTool`   | 7958 | 调用 MCP 工具             |
| `Initialize-Mcp`       | 8079 | 初始化所有已配置的 MCP 服务器     |
| `Stop-Mcp`             | 8106 | 关闭所有 MCP 连接           |

### 2.13 AgentLoop（8295–9974 行）

**职责**：交互式 REPL 主循环、17 个斜杠命令、提示词缓存、Turn 管理、循环检测。

**17 个斜杠命令**：

| 命令          | 函数                     | 功能             |
| ----------- | ---------------------- | -------------- |
| `/help`     | `Invoke-SlashHelp`     | 显示命令列表         |
| `/clear`    | `Invoke-SlashClear`    | 清空对话历史         |
| `/save`     | `Invoke-SlashSave`     | 保存对话历史         |
| `/load`     | `Invoke-SlashLoad`     | 加载对话历史         |
| `/compress` | `Invoke-SlashCompress` | 强制上下文压缩        |
| `/status`   | `Invoke-SlashStatus`   | 会话统计           |
| `/model`    | `Invoke-SlashModel`    | 选择模型           |
| `/provider` | `Invoke-SlashProvider` | 切换供应商及 API Key |
| `/exit`     | `Invoke-SlashExit`     | 退出             |
| `/safe`     | `Invoke-SlashSafe`     | 切换安全模式         |
| `/trace`    | `Invoke-SlashTrace`    | 查看 Trace 日志    |
| `/undo`     | `Invoke-SlashUndoCmd`  | 撤销上次文件修改       |
| `/tasks`    | `Invoke-SlashTasks`    | 列出 TODO        |
| `/memory`   | `Invoke-SlashMemory`   | 查看记忆网络         |
| `/remember` | `Invoke-SlashRemember` | 保存到长期记忆        |
| `/skills`   | `Invoke-SlashSkills`   | 列出技能           |
| `/mcp`      | `Invoke-SlashMcp`      | 列出 MCP 连接状态    |

**Turn 执行流程**：

```
Invoke-RunTurn
  ├─ Read-HostWithCompletion          → 读取用户输入
  ├─ Invoke-SlashDispatch             → [如为 / 命令]
  ├─ Test-ContextWindowPressure       → 压力检测
  ├─ Compress-Context                 → [若压力 > safe]
  ├─ Add-UserText                     → 追加用户消息
  ├─ Build-DynamicContext             → 环境上下文
  ├─ Invoke-HookFire "pre_turn"       → 钩子注入
  ├─ Build-RequestTools               → 工具集
  ├─ Build-ApiRequestBody             → 请求体
  ├─ Invoke-ApiCall                   → API 调用
  │
  │  ┌─ [tool_use stop_reason] ──────┐
  │  │  Invoke-ToolDispatch           │
  │  │  Test-ToolLoop                 │  ← 循环检测
  │  │  Compress-ToolResult           │  ← 结果截断+去重
  │  │  Invoke-HookFire "post_tool"   │
  │  │  Add-AssistantMessage          │
  │  │  Add-ToolResults               │
  │  │  Build-ApiRequestBody          │  ← 重建请求体
  │  └──────── 重新调用 API ──────────┘
  │
  ├─ [end_turn] → Write-MarkdownLight → Invoke-HookFire "post_response"
  ├─ [max_tokens] → Invoke-HandleMaxTokens → Invoke-OnStuck (若阈值超限)
  └─ Test-TurnBudget → Compute-CallBudget
```

### 2.14 Daemon / Cron（9977–11137 行）

**职责**：HTTP 守护进程（HttpListener）、会话持久化、SSE 流式网关、Cron 定时任务。

**9 个 REST 端点**：

| 路由                  | 方法     | 功能        |
| ------------------- | ------ | --------- |
| `/`                 | GET    | HTML 仪表盘  |
| `/api/chat`         | POST   | 对话请求      |
| `/api/chat/stream`  | GET    | SSE 流式对话  |
| `/api/sessions`     | GET    | 列出会话      |
| `/api/sessions`     | POST   | 创建会话      |
| `/api/sessions/:id` | GET    | 获取会话详情    |
| `/api/sessions/:id` | DELETE | 删除会话      |
| `/api/status`       | GET    | 服务状态      |
| `/api/cron`         | GET    | Cron 任务状态 |

**Cron 调度器**：基于 `System.Timers.Timer`，30 秒轮询，支持 5 字段 crontab 表达式。

| 函数                        | 行号    | 功能             |
| ------------------------- | ----- | -------------- |
| `Start-Daemon`            | 10240 | 启动 HTTP 守护进程   |
| `Stop-Daemon`             | 10333 | 停止守护进程         |
| `Invoke-DaemonChat`       | 10139 | 执行会话对话         |
| `Invoke-DaemonSseRequest` | 10346 | SSE 流式请求处理     |
| `Invoke-GatewayRoute`     | 10448 | REST 路由分发      |
| `Parse-CronExpression`    | 10806 | 解析 crontab 表达式 |
| `Register-CronJob`        | 10975 | 注册 Cron 任务     |
| `Start-CronScheduler`     | 11029 | 启动 Cron 调度器    |

---

## 3. 模块间调用关系

### 3.1 依赖矩阵

> 行=调用方，列=被调用方，●=直接调用

|                      | Utils | Config | Messages | HttpClient | Tools | Trace | Compression | AgentSystem | McpClient | AgentLoop | Daemon |
| -------------------- | ----- | ------ | -------- | ---------- | ----- | ----- | ----------- | ----------- | --------- | --------- | ------ |
| **CLI/Bootstrap**    | ●     |        |          |            |       |       |             |             |           |           | ●      |
| **Start-PowerAgent** | ●     | ●      |          |            |       |       |             | ●           | ●         | ●         |        |
| **AgentLoop**        | ●     | ●      | ●        | ●          | ●     | ●     | ●           | ●           | ●         |           |        |
| **Daemon**           | ●     | ●      | ●        | ●          |       |       | ●           | ●           | ●         | ●         |        |
| **HttpClient**       | ●     | ●      |          |            |       |       | ●           |             |           |           |        |
| **Tools**            | ●     |        |          |            |       | ●     |             | ●           | ●         |           |        |
| **Compression**      | ●     | ●      | ●        |            |       |       |             | ●           |           |           |        |
| **AgentSystem**      | ●     | ●      |          | ●          |       | ●     |             |             | ●         |           |        |
| **McpClient**        | ●     | ●      |          |            |       |       |             |             |           |           |        |

### 3.2 核心调用链

**链 1：交互对话主链路**

```
Start-AgentLoop → Invoke-RunTurn
  → Read-HostWithCompletion (Utils)
  → Test-ContextWindowPressure → Compress-Context (Compression)
  → Add-UserText (Messages)
  → Build-DynamicContext → Build-SystemPrompt (Compression)
  → Invoke-HookFire "pre_turn" (Config)
  → Build-RequestTools → Build-ApiRequestBody (Compression/HttpClient)
  → Invoke-ApiCall → Invoke-HttpRequest (HttpClient)
  → [tool_use] → Invoke-ToolDispatch (Tools)
       ├─ file ops → Trace-Record (Trace)
       ├─ agent → Invoke-AgentCore (AgentSystem)
       ├─ mcp__ → Invoke-McpDispatchTool (McpClient)
       └─ todos/memory → AgentSystem functions
  → Test-ToolLoop → Compress-ToolResult (AgentLoop)
  → Add-AssistantMessage / Add-ToolResults (Messages)
  → [end_turn] → Write-MarkdownLight (Utils)
```

**链 2：守护进程对话链路**

```
Start-Daemon → HttpListener.GetContext
  → Invoke-GatewayRoute
  → Invoke-DaemonChat 或 Invoke-DaemonSseRequest
  → Invoke-RunTurn (AgentLoop, 复用同一 Turn 逻辑)
```

**链 3：MCP 工具调用链路**

```
Invoke-ToolDispatch (tool name 以 "mcp__" 开头)
  → Invoke-McpDispatchTool (McpClient)
  → Invoke-McpCallTool
  → New-McpRequest "tools/call"
  → Send-McpMessage → [Stdio|Sse|Http]Transport
  → Receive-McpMessage → [Stdio|Sse|Http]Transport
```

**链 4：文件修改与撤销链路**

```
write_file / edit_file (Tools)
  → Trace-Record (Trace) → Write-TraceObject → 记录到对象存储
/undo 斜杠命令
  → Trace-Undo (Trace) → Read-TraceObject → 还原文件内容
```

**链 5：上下文压缩链路**

```
Test-ContextWindowPressure → [safe/warn/critical]
  → Compress-Context
     ├→ Compress-Offload (L0: 磁盘卸载)
     │    → Save-History (Messages)
     └→ Compress-ToolEvict (L1: 工具结果逐出)
         → 截断大结果 + SHA 去重
```

---

## 4. 全局状态变量

### 4.1 分类汇总

| 分类                  | 变量                                                                                                                                                                                                                                       | 说明                          |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| **PA\_\* 设置（~55项）** | `PA_API_KEY`, `PA_API_URL`, `PA_MODEL`, `PA_PROTOCOL`, `PA_MAX_TOKENS`, `PA_THINKING_BUDGET`, `PA_CONTEXT_WINDOW`, `PA_SAFE_MODE`, `PA_SHOW_THINKING`, `PA_DAEMON_PORT`, `PA_MCP_ENABLED`, `PA_MODE`, `PA_VERSION`, `PA_SYSTEM_PROMPT` 等 | 由 `Import-Config` 从 4 层配置加载 |
| **消息状态**            | `MESSAGES`, `SESSION_INPUT_TOKENS`, `SESSION_OUTPUT_TOKENS`                                                                                                                                                                              | 对话历史和 Token 统计              |
| **代理系统**            | `AGENTS`, `AGENT_META`, `AGENT_STATUS`, `AGENT_DISCOVERS`                                                                                                                                                                                | 代理注册表                       |
| **技能系统**            | `SKILLS`, `SKILL_META`, `ACTIVE_SKILLS`                                                                                                                                                                                                  | 技能注册表                       |
| **记忆网络**            | `MEMORY_POOL`, `MEMORY_DATA`                                                                                                                                                                                                             | 记忆数据                        |
| **TODO 系统**         | `TODOS`, `TODO_FILE`, `_LAST_TODO_ID`                                                                                                                                                                                                    | 任务管理                        |
| **作业队列**            | `_JOB_QUEUE`, `_JOB_COUNTER`, `JOBS_DIR`                                                                                                                                                                                                 | 后台作业                        |
| **MCP 状态**          | `MCP_SERVERS`, `MCP_SERVER_PID`, `MCP_SERVER_TOOLS`, `MCP_SERVER_CAPS`, `MCP_SERVER_READY`, `MCP_NEXT_REQUEST_ID`, `MCP_CONNECTED_COUNT`, `MCP_TOOLS_SCHEMA` 等                                                                           | MCP 连接池                     |
| **Agent Loop**      | `TURN_COUNTER`, `NON_PRODUCTIVE_STREAK`, `_TOOL_CALL_HISTORY`, `_TOOL_RESULT_CACHE`, `_CC`, `_CACHE_PROBE`                                                                                                                               | 循环控制                        |
| **Trace**           | `TRACE_DIR`, `TRACE_HEAD`                                                                                                                                                                                                                | 修改追踪                        |
| **守护进程**            | `DAEMON_HTTP_LISTENER`, `DAEMON_RUNNING`, `DAEMON_SESSIONS`                                                                                                                                                                              | HTTP 服务                     |
| **Cron**            | `CRON_JOBS`, `CRON_TIMER`                                                                                                                                                                                                                | 定时任务                        |

---

## 5. 外部依赖

| 依赖类型           | 名称                                    | 用途                                    |
| -------------- | ------------------------------------- | ------------------------------------- |
| **.NET 类**     | `System.Net.HttpListener`             | HTTP 守护进程                             |
|                | `System.Diagnostics.Process`          | MCP stdio 子进程                         |
|                | `System.Security.Cryptography.SHA256` | 哈希（Trace、循环检测、记忆）                     |
|                | `System.Timers.Timer`                 | Cron 调度器                              |
|                | `[Console]`                           | 终端控制（光标、ReadKey、TreatControlCAsInput） |
| **COM 对象**     | `Excel.Application`                   | process_excel 工具                      |
| **外部命令**       | `git`                                 | 仓库检测（可选）                              |
|                | `curl`                                | 自更新下载                                 |
| **PowerShell** | `Invoke-WebRequest`                   | HTTP 请求                               |
|                | `Start-Job` / `Receive-Job`           | 后台作业                                  |
|                | `ConvertFrom-Json` / `ConvertTo-Json` | JSON 处理                               |

---

## 6. 文件系统结构

```
~/.poweragent/                        ← 系统级目录
  ├── settings.json                   ← 系统级配置
  └── logs/                           ← 日志目录

.poweragent/                          ← 项目级目录
  ├── settings.json                   ← 项目级配置
  ├── POWERAGENT.md                   ← 项目上下文
  ├── agents/                         ← 项目代理
  │   └── *.md
  ├── skills/                         ← 项目技能
  │   └── */skill.md
  ├── hooks/                          ← 钩子脚本
  │   └── *.ps1
  ├── trace/                          ← 修改追踪
  │   ├── HEAD
  │   ├── frames/XX/YY...
  │   ├── objects/XX/YY...
  │   └── snapshots/
  ├── mem_net/                        ← 记忆网络
  │   └── network.json
  ├── sessions/                       ← 守护进程会话
  │   └── *.json
  ├── jobs/                           ← 后台作业元数据
  │   └── *.json
  ├── todos.json                      ← TODO 列表
  └── history.json                    ← 对话历史
```

> 