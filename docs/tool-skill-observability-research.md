# Agent 工具与 Skill 使用统计可行性调研

> 日期：2026-09-08
>
> 范围：TokenTracker 已支持的 Claude Code、Kimi Code、Codex、DSH、Pi、opencode、Hermes Agent。
>
> 方法：检查现有扫描器、只抽样本机日志的事件类型/字段名（不读取或保存提示词正文），并核对官方文档和原始 GitHub 仓库。

## 结论

可行，而且适合在 TokenTracker 现有的“本地、被动、增量扫描”架构上实现。

- **Tool 调用：七个 agent 都可统计名称和次数。** 多数数据源还有 call ID、开始/结束、成功/失败或结果事件。
- **Skill 调用：不能用一个全局口径宣称 100% 精确。** Claude Code、Kimi、DSH、opencode、Hermes 的本机数据出现了明确的 `Skill` / `skill` / `skill_view` 工具事件；Codex 当前通常表现为读取 `SKILL.md` 或通过外层 `exec` 运行读取命令，只能标为 `derived`；Pi 的格式能容纳任意 `toolCall`，但本机样本未观察到专门的 skill 工具。
- **应将“Skill 被发现/可用”、“Skill 文件被加载”、“Skill 被实际采用”分开。** Agent Skills 规范只定义目录和渐进加载，没有统一的运行时 invocation telemetry。
- **建议 MVP 不先装 hook、不代理 MCP、不保存工具参数/输出正文。** 先被动解析现有本地日志，只存名称、时间、状态、关联 ID 和来源置信度，隐私风险和对 agent 行为的影响最小。

## 当前 TokenTracker 的差距

当前 schema v2 只有 `usage_events`、累计快照、扫描游标和会话标题，没有 agent activity 表（`tokentracker/db.py:19-50`）。

现有扫描器也刻意只取 token/cost：

- Claude 没有 `usage` 就返回，因此 `tool_use` / `tool_result` 会被跳过（`tokentracker/scanners/claude.py:44-68`）。
- Codex 只处理 `token_count` 或兼容 usage 字段，`response_item` 工具事件没有入库（`tokentracker/scanners/codex.py:204-280`）。
- opencode 只读 `session` 累计数，未读 `part.data` 的 tool part（`tokentracker/scanners/opencode.py:38-58`）。
- Kimi 只处理 `turn.step.completed` usage，跳过同一 journal 中的 `tool.call.started` / `tool.result`（`tokentracker/scanners/kimi.py:67-106`）。
- Pi 只处理带 usage 的 message，它的 `toolCall` / `toolResult` content part 没有入库（`tokentracker/scanners/pi.py:65-101`）。

这不是数据缺失，而是现有实现尚未抽取。

## 七个 agent 的实际可观测性

| Agent | Tool 数据源 | Tool 口径 | Skill 口径 | 可信度/主要风险 |
|---|---|---|---|---|
| Claude Code | JSONL `assistant.message.content[].tool_use` + tool result | 名称、call ID、调用/结果可精确配对 | `name=Skill`, `input.skill` | `exact`；日志本身未必总有 duration，可选 hook 补足 |
| Codex | rollout `response_item` 中的 function/custom tool call 与 output | 外层调用精确；当前桌面版许多操作被封在 `custom_tool_call(name=exec)` 中，内层 `tools.*` 要解析 payload | 无统一明确的 activation 事件；可从 `SKILL.md` 读取和路径推断 | Tool `exact/derived` 并存；Skill 只能 `derived` |
| Kimi Code | journal `tool.call.started` + `tool.result` | 名称、toolCallId、时间可配对 | `name=Skill`, `args.skill` | `exact`；需兼容字段名版本变化 |
| DSH | zstd JSONL `tool/call` + `tool/result` | `data.name`, `callId`, turn/step | `data.name=skill`，参数内是 skill 名 | `exact`；应以 `tool/call` 为主，不重复统计 delta/chunks |
| Pi | message content 中 `toolCall` + `toolResult` | 名称、参数、返回可配对 | 若客户端产生专门 skill tool 则可精确；当前本机样本未出现 | Tool `exact`；Skill `unknown/unsupported` 不能当 0 |
| opencode | SQLite `part.data` JSON，`type=tool` | `tool`、`callID`、`state.status`、`state.time` | `tool=skill`, `state.input.name` | `exact`；不能只读当前 `session` 表 |
| Hermes Agent | SQLite `messages.tool_calls` / `tool_name` | assistant call 与 tool role 结果可关联 | 本机数据有 `skill_view` | `exact`；JSON 列的字段需容错 |

### 口径要求

1. `tool_call_count` 只统计发起事件，不把 started、delta、completed、result 重复算四次。
2. 以 call ID 配对结果；只有调用没有结果时是 `unknown`，不能自动标为 failed。
3. `skill_use_count` 只统计加载/调用事件；skill 的 scripts 内部又调用 Bash/Read 等工具，工具调用仍应单独统计。
4. 一个会话里多次加载同一 skill：同时提供“调用次数”和“使用过的去重 skill 数”。
5. `0` 与 `unknown` 必须区分：扫描器没能力观察 skill 时，不能显示“未使用”。

## 建议数据模型

不要把 activity 硬塞进 token 账本 `usage_events`。新建独立表，再用会话 ID 和 turn ID 关联：

```sql
CREATE TABLE agent_activity_events (
    id INTEGER PRIMARY KEY,
    agent TEXT NOT NULL,
    session_id TEXT NOT NULL DEFAULT '',
    turn_id TEXT NOT NULL DEFAULT '',
    event_kind TEXT NOT NULL,       -- tool_call | skill_use
    name TEXT NOT NULL,
    namespace TEXT NOT NULL DEFAULT '', -- MCP server / built-in / skill provider
    call_id TEXT NOT NULL DEFAULT '',
    parent_call_id TEXT NOT NULL DEFAULT '',
    started_at INTEGER,
    ended_at INTEGER,
    duration_ms INTEGER,
    status TEXT NOT NULL DEFAULT 'unknown', -- success | error | denied | unknown
    source_kind TEXT NOT NULL,
    confidence TEXT NOT NULL DEFAULT 'exact', -- exact | derived
    input_hash TEXT NOT NULL DEFAULT '',
    output_hash TEXT NOT NULL DEFAULT '',
    src_key TEXT NOT NULL,
    UNIQUE(agent, src_key)
);
```

默认不存原始 arguments/result，只存 hash 用于去重和追查。原始参数可包含命令、文件路径、凭据或用户数据；OpenTelemetry 规范也把 tool arguments/result 标为 opt-in 且明确警告敏感性。

### 建议的归一化层

每个扫描器额外产出统一 `ActivityEvent`，不改变现有 usage 计算逻辑。应在名称上保留两层：

- `raw_name`：源数据名，例如 `Bash`、`execute_code`、`mcp__github__search`。
- `canonical_name`：用于跨 agent 汇总，例如 `shell`、`file.read`、`file.edit`、`web.search`、`mcp.github.search`。

展示时默认用 raw name，跨平台图表才用 canonical name，否则容易错误合并语义不同的工具。

## 推荐 MVP

### Phase 0：格式固定与验收样本

- 为七个平台各制作一组脱敏 fixture：单工具、并行工具、失败/拒绝、缺失结果、一次 skill、重复扫描。
- 先用命令行导出 JSON 验证数字，暂不动 SwiftUI。

### Phase 1：被动扫描 MVP

- schema v3 + `agent_activity_events`。
- 优先做 Claude、opencode、Kimi、DSH：字段最直接，tool 与 skill 都有精确事件。
- 第二批做 Hermes、Pi、Codex；Codex 外层/inner tool 分层并保留 `derived` 标记。
- CLI 增加 `tt activity --range week --group tool|skill|agent`。

### Phase 2：可视化原型

按项目的 UI 习惯，先做单文件 HTML MVP，确认以下信息架构后再进 SwiftUI：

- 工具榜：调用数、成功/失败/未知、去重会话数、趋势。
- Skill 榜：调用数、使用 agent、最近使用、`exact/derived/unknown` 徽标。
- 会话详情：token/cost 与 tool/skill 时间线并排，不展示原始参数。

### Phase 3：可选实时采集

- Claude Code 可选用 `PreToolUse` / `PostToolUse` / `PostToolUseFailure` hooks 获得更稳定的 status 和 duration。
- 通用 agent 可选接受 OpenTelemetry `execute_tool` span。
- MCP 可选代理仅补足 MCP tool 的 duration/error；不应用它代替客户端日志，因为 Bash/Read/Edit 等内建工具不经过 MCP。

## GitHub 上值得参考的项目

### 1. TMA1 — 最接近的整体架构

- 仓库：https://github.com/tma1-ai/tma1
- 采用 JSONL + hooks + OpenTelemetry 的混合采集，已明确支持 Claude Code 和 Codex，仪表盘包含 tool activity。
- 可参考：多源数据统一、会话/工具关联、被动日志与实时 hook 共存。
- 不宜直接照搬：它的 GreptimeDB + 回馈到 agent 的架构对 TokenTracker MVP 过重。

### 2. ClaudeSec — 最值得参考的 transcript tailing

- 仓库：https://github.com/aanjaneyasinghdhoni/ClaudeSec
- 直接 tail Claude Code、Codex、Copilot CLI 的本地会话，展示工具、命令和文件操作；还可接 OTLP。
- 可参考：格式适配、实时 tail、“没观测到”与“没发生”分离、本地隐私。
- 限制：AGPL-3.0-only；可研究思路，不应在未审核许可证影响时复制源码。

### 3. Langfuse Codex Observability Plugin — Codex rollout 解析的直接参考

- 仓库：https://github.com/langfuse/codex-observability-plugin
- Codex Stop hook 读取 rollout JSONL，重建 turn、model step、tool execution、MCP tool、subagent 和 usage，再映射为 trace。
- 可参考：Codex 工具分类、子 agent 关联、中断 turn、重复上传防护；这是“从 rollout 统计工具调用”最直接的开源可行性证据。
- 限制：它依赖 hook 并默认上传 prompts、reasoning summary、tool 输入/输出到 Langfuse；TokenTracker 只应参考 parser/trace 结构，保持本地 metadata-only 默认。

### 4. observer — MCP 代理模式

- 仓库：https://github.com/valtors/observer
- 在 MCP client 和 server 之间代理 `tools/list` / `tools/call`，将名称、输入、输出、耗时、错误存入本地 SQLite。
- 可参考：call ID、duration/error 口径和默认只返回 metadata/hash 的隐私思路。
- 限制：只能看到 MCP 流量，看不到 agent 内建的 shell/read/edit。

### 5. AgentTrace — 轻量本地 SQLite + Dashboard

- 仓库：https://github.com/Klepsiphron/agenttrace
- 主打 local-first，存 tokens、tools、latency、cost，并支持 wrapper/SDK 采集。
- 可参考：简化的 run/trace/tool 结构和本地仪表盘信息密度。
- 限制：它的 wrapper/SDK 是主动接入，不是 TokenTracker 当前的零配置日志扫描。

### 6. Arize Phoenix / Langfuse — 成熟的 trace 产品形态

- Phoenix：https://github.com/Arize-ai/phoenix
- Langfuse observability docs：https://github.com/langfuse/langfuse-docs/blob/main/content/docs/observability/overview.mdx
- 可参考：trace 树、tool span、latency/cost 关联、输入输出 opt-in、跨框架 OpenTelemetry/OpenInference 接入。
- 限制：它们面向被仪器化的 LLM 应用，不会自动理解 TokenTracker 七种本地私有日志格式。

## 可复用的标准与官方能力

- **OpenTelemetry GenAI semantic conventions**
  https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-spans.md
  已定义 `execute_tool {gen_ai.tool.name}`、`gen_ai.tool.call.id`、tool type 和 error；arguments/result 为 opt-in 且被标为可能敏感。当前状态是 Development，内部 schema 应保留版本/适配层。
- **Claude Code hooks**
  https://code.claude.com/docs/en/hooks
  `PreToolUse`、`PostToolUse`、`PostToolUseFailure` 提供 `session_id`、`tool_name`、`tool_input`、`tool_response`、`tool_use_id` 和可选 `duration_ms`。这是 Claude 实时采集的权威备选，但安装 hook 会改动 agent 配置，不应作为默认 MVP。
- **Agent Skills specification**
  https://agentskills.io/specification
  定义了 `SKILL.md` 与三层渐进加载，但没有定义统一的运行时调用事件。因此 TokenTracker 需要每个客户端的 skill adapter。
- **OpenAI Responses/Codex 相关官方 schema**
  https://developers.openai.com/api/reference/cli/resources/beta/subresources/responses
  官方 schema 明确包含 custom/function/MCP/shell/apply-patch 等 tool-call item，也有 local/inline skill 定义；但“skill 被提供给环境”不等于“skill 在某会话被采用”。本地 rollout 仍要以实际 fixture 锁定。
- **MCP Inspector**
  https://github.com/modelcontextprotocol/inspector
  适合验证单个 MCP server 的 `tools/list` / `tools/call`，不是多 agent 历史统计产品。

## 风险与验收线

1. **格式漂移**：这些本地存储多数不是承诺稳定的公开 API。每个 parser 都要有真实脱敏 fixture 和“新事件不崩溃”测试。
2. **重复计数**：流式事件常同时有 delta、started、completed、result。只能选 canonical call event，结果事件仅用于补 status/duration。
3. **嵌套 agent**：子 agent 日志可能单独存储。要保留 parent session/call，否则“调用 Agent 工具”与“子 agent 内又调用 Bash”会混在一层。
4. **隐私**：命令、绝对路径、tool output 可含密钥和业务数据。MVP 只存 metadata；“显示详细参数”必须另做 opt-in 与脱敏设计。
5. **证据等级**：UI 必须显示 `exact`、`derived`、`unknown`，不用单一数字掩盖可观测性差异。

## 建议决策

建议继续，但把第一版定义为：

> **本机 agent activity 统计**：精确统计可观测的 tool calls；对 skill 使用显示来源和置信度；默认不存工具输入/输出正文。

这个范围与 TokenTracker 现有定位相符，也能在不修改七个 agent 配置的前提下先产出有价值的结果。
