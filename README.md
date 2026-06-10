
# PowerAgent v0.8

> ⚡ 单文件 PowerShell 5.1 AI 智能体 — 零依赖，开箱即用

PowerAgent 是一个基于 LLM 的终端智能体，以**纯 PowerShell 5.1** 编写，全部代码集中在单个文件 `PowerAgent.ps1` 中。无需包管理器、无需构建系统、无需安装额外依赖。

- **LLM 后端**：支持 9 种 API 协议适配（DeepSeek / Qwen / ERNIE / GLM / Kimi / MiniMax / OpenAI / Anthropic / Generic OpenAI）
- **运行平台**：Windows 10/11（PowerShell 5.1，不需要 PS 7+）
- **文件规模**：~11,100 行，259 个函数，13 个内联模块
- **版本**：`preview-0.17`

---

## 目录

- [功能亮点](#功能亮点)
- [v0.8 更新日志](#v08-更新日志)
- [系统要求](#系统要求)
- [快速安装](#快速安装)
- [配置 API Key](#配置-api-key)
- [启动与使用](#启动与使用)
- [多供应商支持](#多供应商支持)
- [内置斜杠命令](#内置斜杠命令)
- [TUI 美化](#tui-美化)
- [配置说明](#配置说明)
- [MCP 服务器配置](#mcp-服务器配置)
- [目录结构](#目录结构)
- [内置工具](#内置工具)
- [测试](#测试)
- [常见问题](#常见问题)

---

## 功能亮点

| 特性            | 说明                                           |
| ------------- | -------------------------------------------- |
| **零依赖**       | 纯 PowerShell 5.1，无需 npm/pip/choco            |
| **单文件架构**     | ~11,100 行，259 个函数，13 个模块内联                   |
| **多供应商支持**    | 9 家模型供应商一键切换，自动适配 API 差异                     |
| **27 个内置工具**  | 文件 I/O、PowerShell 执行、Web 搜索、Excel 处理、子智能体委派等 |
| **TUI 美化**    | 彩色 banner、分隔线、Markdown 渲染、状态栏、斜杠命令自动补全       |
| **子智能体系统**    | 委派任务给子智能体并行处理                                |
| **MCP 协议支持**  | stdio/SSE/HTTP 三种传输方式                        |
| **HTTP 守护进程** | REST API + SSE 流式输出 + Cron 定时任务              |
| **文件修改追踪**    | 类 Git 内容寻址存储，支持一键撤销（undo）                    |
| **上下文压缩**     | 3 级策略：磁盘卸载 → 工具结果淘汰 → 历史摘要                   |
| **记忆网络**      | 长期记忆存储与检索，跨会话保持上下文                           |
| **Skill 扩展**  | 自定义技能模块，按需加载                                 |
| **Bracketed Paste** | 原生支持终端粘贴，自动检测并正确处理粘贴序列                    |

---

## v0.8 更新日志

### Ghosting Fix — 终端粘贴多行内容后光标重绘鬼影修复

**问题**：在 Windows Terminal 中粘贴多行文本后，按左/右箭头键移动光标时，提示符和输入内容会在屏幕上重复出现（鬼影现象）。

**根因**：`Redraw-InputLine` 使用 `ESC[J`（Erase in Display）清除旧内容。当粘贴的长文本导致终端缓冲区滚动后，`SetCursorPosition` 回到输入起始行会触发视口回滚，但 `ESC[J` 只能清除到当前视口底部——旧文本的下半部分在新视口底部以下，不会被清除。再次写入时视口下滚，那些旧行重新出现。

**修复**：

| 修改点 | 说明 |
|--------|------|
| `Redraw-InputLine` | 用逐行 `SetCursorPosition` + `ESC[2K` 替代 `ESC[J`，引入 `_lastContentEndRow` 追踪内容末尾行号，不受视口边界限制 |
| `Redraw-InputLine` | 全程使用 `[Console]::Write` 替代 `Write-Host`，避免 PS5.1 Host 内部光标跟踪与 `[Console]` 不同步 |
| `Write-StatusBar` | 合并为单行 `[Console]::Write("\r${esc}[2K ...")`，Timer 线程回调中不再调用线程不安全的 `Write-Host` |
| `Hide-Completions` | `Write-Host` → `[Console]::Write`，与 Redraw-InputLine 统一 API 体系 |
| 初始提示符打印 | `Write-Host $PromptStr -NoNewline` → `[Console]::Write($PromptStr)`，与 Redraw 保持一致 |

---

## 系统要求

| 项目         | 要求                            |
| ---------- | ----------------------------- |
| 操作系统       | Windows 10 / 11               |
| PowerShell | 5.1 及以上（系统自带）                 |
| 网络         | 能访问所选供应商的 API 端点              |
| 可选         | `curl.exe`（系统已内置，HTTP 请求备用方案） |

---

## 快速安装

### 方式一：CMD 启动器（推荐）

```cmd
cd C:\path\to\PowerAgent-v0.8
power --install
```

### 方式二：Git Bash / WSL

```bash
cd /c/path/to/PowerAgent-v0.8
bash power.sh --install
```

### 方式三：直接运行

```powershell
cd C:\path\to\PowerAgent-v0.8
powershell -ExecutionPolicy Bypass -File .\PowerAgent.ps1 --install
```

---

## 配置 API Key

### 方式一：交互式配置（推荐）

启动 PowerAgent 后，输入 `/provider` 命令，从 6 家供应商中选择并输入 API Key：

```
/provider
  1. 阿里云百炼    qwen3.7-max, qwen3.6-plus
  2. 百度千帆       ernie-5.1, ernie-4.5t
  3. 智谱 AI (GLM)  glm-5.1, glm-5-turbo
✔ 4. DeepSeek      deepseek-v4-pro, deepseek-v4-flash
  5. 月之暗面 (Kimi) kimi-k2.6, kimi-k2.5
  6. MiniMax        MiniMax-M3, MiniMax-M2.7
```

选号后输入 API Key 即可自动保存并切换。

### 方式二：编辑配置文件

编辑 `~/.poweragent/settings.json`：

```json
{
  "api_key": "sk-your-api-key",
  "api_url": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
  "model": "qwen3.7-max"
}
```

### 方式三：环境变量

```powershell
$env:PA_API_KEY = "sk-your-api-key"
```

---

## 启动与使用

### 交互模式

```cmd
power
```

彩色终端界面：

```
  ══════════════════════════════════════════════════════════════
  ⚡ PowerAgent  preview-0.17
  基于PowerShell的超轻量化智能体

  Model     deepseek-v4-pro
  Endpoint  https://api.deepseek.com/v1/chat/completions
  Thinking  Yes
  ══════════════════════════════════════════════════════════════

  ▸ /help   # 查看可用命令

▸ turn 1 │ pro ▸ 你好
```

**斜杠命令自动补全**：输入 `/` 自动显示所有命令列表，继续打字实时过滤，Tab 循环选择。

### 守护进程模式

```cmd
power --run
```

默认监听 `http://localhost:9655`，提供 10 个 REST 端点。支持 Dashboard（浏览器访问 `/`）。

### 一次性执行

```cmd
echo "解释这段代码" | power
```

---

## 多供应商支持

PowerAgent 内置 9 家模型供应商的 API 适配（OpenAI 兼容格式），一键切换：

| 供应商          | 模型                                 | 上下文  | 最大输出 |
| ------------ | ---------------------------------- | ---- | ---- |
| **DeepSeek** | deepseek-v4-pro, deepseek-v4-flash | 1M   | 384K |
| **阿里云百炼**    | qwen3.7-max, qwen3.6-plus          | 1M   | 64K  |
| **百度千帆**     | ernie-5.1, ernie-4.5t              | 128K | 128K |
| **智谱 AI**    | glm-5.1, glm-5-turbo               | 200K | 128K |
| **月之暗面**     | kimi-k2.6, kimi-k2.5               | 256K | 32K  |
| **MiniMax**  | MiniMax-M3, MiniMax-M2.7           | 1M   | 256K |
| **OpenAI**   | gpt-4o, gpt-4o-mini                | 128K | 16K  |
| **Anthropic** | claude-sonnet-4-20250514             | 200K | 8K   |

**自动适配**：

- Thinking（深度思考）模式：每家自动使用正确的参数格式（`enable_thinking`、`thinking:{type:"enabled"}` 等）
- max_tokens 上限：超出模型限制自动截断，避免 400 错误
- 多轮对话 reasoning：百度自动删除 reasoning_content，其他自动保留
- MiniMax 特有的 `reasoning_details[]` 数组格式自动转换为标准 thinking 块

**命令**：

- `/provider`：交互式选择供应商并配置 API Key
- `/model`：在当前供应商的候选模型间切换

---

## 内置斜杠命令

| 命令                      | 说明                        |
| ----------------------- | ------------------------- |
| `/help`                 | 显示所有可用命令                  |
| `/clear`                | 清空对话历史                    |
| `/save` / `/load`       | 保存/加载对话历史                 |
| `/compress`             | 手动触发上下文压缩                 |
| `/status`               | 显示会话状态（模型、上下文占用、Token 用量） |
| `/model`                | 查看/切换当前模型（交互式选择）          |
| `/provider`             | 切换供应商并配置 API Key          |
| `/safe`                 | 切换安全模式（只读）                |
| `/trace` / `/undo`      | 查看追踪日志 / 撤销文件修改           |
| `/tasks`                | 列出 TODO 任务                |
| `/memory` / `/remember` | 查看记忆 / 保存长期记忆             |
| `/skills` / `/mcp`      | 列出技能 / MCP 连接             |
| `/exit`                 | 退出 PowerAgent             |

> **提示**：输入 `/` 会自动弹出命令列表，支持 Tab 补全。

---

## TUI 美化

PowerAgent v0.8 提供完整的终端美化：

- **彩色 Banner**：启动时显示模型信息，分隔线
- **时间戳**：用户输入和智能体回复自动标注时间
- **Markdown 渲染**：AI 回复支持标题、粗体、行内代码、列表、引用、代码块渲染
- **工具调用着色**：27 种工具各分配独立颜色（如 read_file=绿、powershell=蓝、delete_file=红）
- **状态栏**：显示轮次、上下文占比、模型、Token 用量、执行耗时
- **Spinner 计时**：API 调用时显示实时的思考耗时
- **工具硬上限**：单轮超过 30 次工具调用自动终止，防止无限循环

---

## 配置说明

### 配置优先级

```
项目 .poweragent/settings.json > 系统 ~/.poweragent/settings.json > 环境变量 > 硬编码默认值
```

### 核心配置

```json
{
  "api_key": "sk-your-key",
  "api_url": "https://api.deepseek.com/v1/chat/completions",
  "model": "deepseek-v4-flash",
  "max_tokens": 384000,
  "thinking_budget": 100000,
  "compress_threshold": 250000,
  "show_thinking": "status",
  "context_window": 1048576,
  "daemon_port": 9655
}
```

### 环境变量

| 变量             | 说明       | 默认值                       |
| -------------- | -------- | ------------------------- |
| `PA_API_KEY`   | API Key  | —                         |
| `PA_API_URL`   | API 端点   | DeepSeek Chat Completions |
| `PA_MODEL`     | 模型名称     | `deepseek-v4-flash`       |
| `PA_MODE`      | 启动模式     | `interactive`             |
| `PA_DEBUG`     | 调试模式     | —                         |
| `PA_LOG_LEVEL` | 日志级别     | `INFO`                    |
| `PA_SAFE_MODE` | 安全模式（只读） | —                         |
| `PA_HEADLESS`  | 无头模式     | —                         |

---

## MCP 服务器配置

编辑 `settings.json` 中的 `mcp_servers` 字段：

```json
{
  "mcp_servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:\\Users\\You\\Documents"],
      "transport": "stdio"
    }
  }
}
```

支持的传输方式：`stdio`（本地命令行）| `sse`（远程 SSE 流式）| `http`（远程 HTTP）

---

## 目录结构

```
PowerAgent-v0.8/
├── PowerAgent.ps1            # 主程序（~11,100 行，单文件）
├── power.bat                 # CMD 启动器
├── power.sh                  # Git Bash / WSL 启动器
├── README.md                 # 本文件
├── AGENTS.md                 # AI Agent 知识库（代码架构参考）
├── data/
│   ├── settings.json         # 默认配置模板
│   ├── tool_schemas.json     # 工具 JSON Schema
│   └── mcp_servers_template.json
├── tests/                    # Pester v5 测试套件
│   ├── run_tests.ps1         # 测试运行器
│   ├── *.Tests.ps1           # 测试文件
│   └── TC01~TC11/            # 场景测试数据
└── .poweragent/              # 运行时状态（自动生成，不入库）
```

---

## 内置工具

PowerAgent 提供 **27 个内置工具**：

| #     | 工具                                                                  | 说明              |
| ----- | ------------------------------------------------------------------- | --------------- |
| 1-5   | `read_file`, `write_file`, `edit_file`, `delete_file`, `list_files` | 文件 I/O          |
| 6     | `powershell`                                                        | PowerShell 命令执行 |
| 7     | `process_excel`                                                     | Excel 读写        |
| 8     | `web_search`                                                        | Web 搜索          |
| 9     | `web_request`                                                       | HTTP 请求         |
| 10-12 | `task_create`, `make_todos`, `task_update`, `task_list`             | 任务管理            |
| 13-15 | `agent`, `agent_status`, `agent_batch`                              | 子智能体委派          |
| 16-17 | `send_message`, `check_messages`                                    | 消息通信            |
| 18-20 | `job_poll`, `job_result`, `job_cancel`                              | 异步作业            |
| 21    | `request`                                                           | 高风险操作确认         |
| 22-25 | `skill`, `list_skills`, `list_agents`, `list_mcp_tools`             | 技能与发现           |
| 26    | `undo`                                                              | 撤销文件修改          |

工具优先级（智能体选择顺序）：

```
skill > agent > mcp 工具 > 内置工具 > process_excel > powershell > 从零写文件
```

---

## 测试

**框架**：Pester v5（首次运行自动安装）

```cmd
power --test                           # 全部测试
.\tests\run_tests.ps1 -TestFile "Tools"  # 指定模块
.\tests\run_tests.ps1 -Verbose           # 详细输出
```

Live 测试（API 调用）受 `$env:DEEPSEEK_API_KEY` 控制，未设置时自动跳过。

---

## 常见问题

### Q: 如何切换到其他供应商？

输入 `/provider`，从列表中选择供应商，输入 API Key 即可。切换后 `/model` 可在该供应商的候选模型间选择。

### Q: 如何查看日志？

```cmd
power --debug
type ~/.poweragent/log/poweragent.log
```

### Q: 启动时提示 ExecutionPolicy 错误？

```powershell
# 方式一：临时绕过
powershell -ExecutionPolicy Bypass -File .\PowerAgent.ps1

# 方式二：仅对当前进程设置
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 方式三：如果从网络下载的文件被标记
Unblock-File -Path .\PowerAgent.ps1
```

### Q: 粘贴多行文本后光标移动出现鬼影？

v0.8 已修复此问题。如果仍遇到，请确保使用 Windows Terminal 或支持 ANSI 序列的现代终端模拟器。

### Q: 如何卸载？

```cmd
power --uninstall
```

> AI生成
