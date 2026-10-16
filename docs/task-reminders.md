# 任务提醒与卡片内审批

本功能在独立开发 App 中实现。已有 Codex CLI、Claude Code CLI 验收记录；2026-10-16 补充验证了 Codex 桌面本地任务和 Claude 桌面 Code Local 会话的真实事件及允许／拒绝往返。验收记录只对应下表列出的版本，不能替代当前连接状态。云端编排、Cloud、SSH、普通 Chat 和 Cowork 不在范围内。

## 使用方式

1. 在设置的「任务提醒与审批」中启用总开关和对应工具。正式偏好默认关闭；通知声音默认关闭。
2. 点击「配置接入…」，核对配置路径和 Hooks 修改前后内容，再应用。App 先备份原文件，保留其他 Hooks 和设置，只合并当前开发／生产通道自己的条目。
3. 在原工具中完成其要求的 Hooks 信任流程，重新开始会话。配置写入成功不代表已收到事件；设置分别展示四类客户端的配置状态、本次 App 运行收到的本地事件和历史版本验收记录。桌面候选目录不采用 TokenTracker 自身的 CODEX_HOME／CLAUDE_CONFIG_DIR；未经运行时观察或用户选择的目录标为「路径待确认」，不能写入。
4. 有效审批卡支持「允许一次」「拒绝一次」「前往原任务」。允许前需展开完整请求。关闭卡片或按 Esc 不发送决定。
5. 原状态栏和设置页都有「任务提醒」入口。圆环隐藏或不能显示时，仍能打开列表、查看卡片并处理有效审批。
6. 「移除接入…」也先展示差异，只移除当前通道标记的 TokenTracker Hook，不移除其他工具的配置。

系统通知需要 macOS 授权；点击通知只打开对应卡片。通知仅含工具和状态，不含项目名、路径、命令、参数或回复正文。专注模式可能阻止横幅展示。

「前往原任务」当前提供已识别原应用的激活回退，并明确提示用户在应用内选择原任务。尚无通过验收的精确会话链接或窗口定位，因此不会声称已打开某个具体会话，也不会调用 resume 创建等待会话的副本。

## 接入与数据边界

- `TokenTrackerHook` 是随 App 打包的原生 Swift 可执行文件。配置安装时复制到 App 专属 Application Support 下的稳定路径，避免开发包移动后 Hook 失效。产品运行不依赖 Python，也不开 TCP/HTTP 服务。
- 桌面来源由最近引擎的启动模式、已验证路径、宿主共同确定；Codex 的全局配置参数可以位于 app-server 子命令前。桌面内启动的交互 CLI／exec 保留 CLI 身份，不能仅凭父应用或 SessionStart.source 判定桌面；缺失或不明确的上下文保持「来源未确认」。新增来源字段可选，兼容历史事件。
- 同一实际配置目录仅安装一份；项目 Hooks 收到事件不代表用户级配置文件已安装。已观察的配置根只保存在运行内存；用户选择保存在 App 本地偏好。Claude 显式禁用／只允许受管理 Hooks、Codex features.hooks=false 会阻止安装；上游策略、信任和沙箱限制仍由原工具执行，不写入信任记录或绕过检查。
- Helper 先尝试连接 App；App 不在时立即返回空 JSON，不启动 App。仅读取官方 Hook stdin，不读取会话正文或 transcript 文件。
- Helper 与 App 使用当前用户的 Unix Socket。目录权限 0700、Socket 权限 0600，两端核对 peer UID；单个报文最多 1 MiB，审批最多同时等待 32 个连接。
- 官方事件在 `TaskHookEvent` 中归一化。共同接入 SessionStart、UserPromptSubmit、PermissionRequest、PostToolUse、Stop、SessionEnd；Codex 另接 Interrupt，Claude 另接 PostToolUseFailure、PermissionDenied 和 permission_prompt 通知。
- 不依据 Token 增长停顿推断完成。主会话 Stop 每轮提醒一次，文案为「本轮回复结束」。带子代理身份的 Stop 不生成主会话完成提醒；子会话结束不会取消父会话的待审批连接。
- 只有活跃 PermissionRequest 连接可以代答，随机请求 ID 与连接绑定，单次消费。审批最多等待 120 秒，上游配置 timeout 为 130 秒。过期、断连、取消、禁用功能或 App 退出均放弃代答，由原工具继续自己的审批流程。
- 决定输出仅包含官方 PermissionRequest 的 allow／deny，不改命令、规则或审批模式。通知型请求仅提供「前往原任务」。
- 点击决定后显示「决定已发送」或「拒绝决定已发送」。只有后续工具事件含可精确匹配的调用 ID，且唯一匹配当前会话、轮次、代理和工具时，才更新执行结果。缺少调用 ID 时不会猜测已经继续执行。
- 原用量通知和任务通知共用 `NotificationRouter`，由它持有唯一 `UNUserNotificationCenterDelegate`；原用量通知的导航与声音行为保留。
- 参数仅在 Helper／App 内存中暂存。处理或失效后清除；延迟超时闭包只保留请求 ID，不延长参数生命周期。历史 Codable 字段明确排除参数，产品日志不输出报文或命令。
- 历史仅含 ID、工具、会话／轮次／调用／代理标识、项目简称、时间、状态和源应用标识。开发版位于 `~/Library/Application Support/TokenTracker Dev/task-reminders.json`，生产版使用 `TokenTracker` 目录，文件权限 0600，最多 50 条、7 天。加载时过滤、启动时落盘清理；运行中复用现有周期检查清理过期记录，无新增常驻动画定时器。
- 重启后的等待／已发送请求降为「请回原任务处理」，不恢复审批连接、不重新发送决定、不自动弹历史通知。
- 不修改共享用量数据库 schema、Token 扫描、成本计算或公开统计载荷。

## 界面行为

圆环的额度点击行为保留；待审批标记可主动打开卡片。卡片为 360 × 420 pt，完整参数区域可展开并滚动。列表优先排列待处理请求，然后按时间倒序，整行均可点击。

自动卡片使用不激活面板，不抢键盘焦点；主动点击后允许交互。审批优先于完成提醒。完成卡片 8 秒后收起，悬停暂停；审批卡片关闭只隐藏显示。任务卡片不采用外部点击自动关闭，以免展开请求时误触关闭；配额卡片原有外部点击行为保留。

自动卡片使用与刘海圆环相同的可见性判定，全屏和隐藏圆环时不自动弹出。全屏期间事件仍进入列表；系统通知只有在获得授权并启用后才投递。

## 验收记录

验收使用 `build/TokenTracker Dev.app`（`com.tokentracker.desktop.v2.dev`），配合 `TT_UI_PREVIEW=1`、虚构用量库和 `/tmp/tt-task-acceptance` 下的隔离客户端配置。预览偏好、历史与正式配置隔离；未修改登录、凭据或真实用量库。桌面验收使用现有账号与模型设置、独立临时项目。Claude 使用项目配置；Codex 因桌面读取用户级配置，预览备份后临时合并了 7 条开发通道 Hooks，并通过官方 /hooks 逐项审阅信任。测试后从当前文件仅移除这 7 条，核对非自有配置与原内容一致，保留备份。

CLI 闭环使用已安装的真实客户端，模型端由临时回环地址测试服务提供固定工具调用，凭据为虚构值。真正的 Hook 调用、权限请求、卡片点击和工具执行由客户端完成，没有用直接注入 App 的模拟事件代替客户端验收。测试服务属于临时验收设施，已停止，不是产品组件。

| 客户端 | 版本 | 真实事件 | 允许一次 | 拒绝一次 | 支持结论 |
| --- | --- | --- | --- | --- | --- |
| Codex CLI 原生 TUI | 0.162.1 | 已收到 | 原工具退出码 0，输出测试标记 | 原请求返回 PermissionRequest hook denied approval | 该版本已验收 |
| Claude Code CLI | 2.1.300 | 已收到 | 原 Bash 工具输出测试标记 | 原请求返回 Permission denied by hook | 该版本已验收 |
| Codex 桌面本地任务 | App 26.1007.71326 / 引擎 0.162.0-alpha.17.2 | 真实 PermissionRequest、Stop | 原请求退出码 0，输出 TT_CODEX_DESKTOP_TRUSTED_ALLOW_A | 原请求返回 PermissionRequest hook denied approval，未执行 | 此版本原请求闭环通过；桌面自身 UI 操作受工具限制 |
| Claude 桌面 Code Local | App 2.37337.1 / 引擎 2.1.295 | 真实 PermissionRequest、Stop | 原 Bash 工具输出 TT_CLAUDE_SOURCE_ALLOW_OK | 原请求返回 Permission denied by PermissionRequest hook | 此版本原请求闭环通过 |

Codex 的测试通过隔离 CODEX_HOME 中的正常 Hooks 信任操作进行，未使用跳过信任选项。本机版本的 `codex exec` 强制非交互审批策略，因此其非交互事件测试没有被当作审批闭环通过；allow／deny 验收使用真实 TUI。

2026-10-15 完成两种 CLI 的 allow／deny 真实往返、稳定 Helper 安装路径验证和自动卡片不抢焦点检查。2026-10-16 在最终开发版继续完成以下验证：

| 检查 | 结果 |
| --- | --- |
| 相关自动测试 | 45 项通过：9 项 Core、36 项 App，其中 12 项任务提醒模型／Socket 测试 |
| 覆盖范围 | 归一化、主子会话、去重、历史隐私／过期清理、多请求隔离、单次审批、断连、超时、迟到决定、退出放弃代答、重启不恢复审批、配置合并卸载、原用量通知路由、现有 HUD／配额回归；新增来源识别、桌面内 CLI 防误判、子命令前配置参数、目录确认、共享安装、来源历史兼容 |
| 开发版 release 构建 | 通过，包含独立 Helper |
| 签名与本地化 | App 深度严格签名验证通过，中英文 strings 校验通过 |
| Hooks 设置 UI | 安装预览／应用已验证；卸载预览／应用再次验证，仅移除自身条目，保留原环境字段和已有 Stop Hook，并保留两份备份 |
| 列表及卡片 | 实际点击列表整行打开卡片、展开完整请求、Esc 收起、重启后审批无按钮、原应用回退提示均已验证 |
| 隐藏圆环回退 | 隐藏圆环后仍能通过列表打开卡片 |
| 全屏真实事件 | 全屏中收到真实 Claude CLI PermissionRequest，未弹自动卡片；退出全屏后列表仍为等待审批，点击拒绝后原 CLI 返回 Permission denied by hook |
| 隐私 | 预览历史不含 arguments；自动测试还断言私密测试参数不进入历史，完成／中断后清除内存参数引用 |
| 系统通知拒绝路径 | 已验证，授权失败后开关保持关闭，应用内提醒可用 |
| 系统通知成功／点击 | 未通过真实 UI 验收：本机开发 App 未取得系统通知授权；单元路由测试不能替代横幅与点击验证 |
| 桌面实际卡片 | 两款桌面真实请求均展开完整参数后点击；修正后的 Codex 桌面／Claude 桌面 Code 来源标签已在卡片核对；允许／拒绝仅作用于当前原请求 |
| 最终设置实际 UI | 最终构建启动后检查四类客户端的独立配置／事件／版本验收文案、未确认路径禁用写入、共享目录说明；截图检查文本和按钮无重叠。验收结束关闭开发预览的任务提醒总开关，避免缓存中的临时 Hooks 干扰其他任务 |
| Claude 桌面超时 | 真实请求超时后没有默认允许，原生审批仍可处理；随后在原客户端拒绝 |
| Codex 桌面验收方式 | 由 Codex 原生任务接口创建桌面管理的本地测试会话；执行引擎与 rollout 元数据核对为 Desktop。本机 CUA 禁止控制 Codex 自身，未用其他 GUI 技术绕过；因此桌面自身界面点击验收仍缺失 |
| 并发桌面与通知／焦点 | 自动测试覆盖多请求隔离；两款桌面同时等待、桌面自身焦点／全屏／Space 切换及通知允许／点击尚未完整实际复验，不能由 CLI 验收推导通过 |
| 其他实机场景 | 通知允许路径、外接屏拔插、锁屏唤醒、多 Space、深色与减少动态效果尚未逐项完成本功能的真实验收 |

复验命令：

```sh
swift test --package-path swift --filter 'TaskHookTests|TokenTrackerAppTests'
./scripts/build_swift_app.sh --development
codesign --verify --deep --strict 'build/TokenTracker Dev.app'
```

本次桌面测试和构建日志分别为 `/tmp/tt-desktop-tests.log`、`/tmp/tt-desktop-build.log`；隔离运行日志为 `/tmp/tt-desktop-ui-final.log`。这些本机临时文件不是稳定发布工件。

本次未执行提交、推送、Release、系统安装或替换 `/Applications` 中的版本。保留工作区原有修改。产品运行不新增网络轮询；原用量采集和费用口径不随本功能改变。

桌面验收证据（2026-10-16）：Claude 独立 Local 会话 `50514ec2-3aaf-4fd8-aa13-2c19905998d6`；Codex 桌面测试会话 `01a142ad-4d29-77a0-9d4c-b12c16a107b7`。原始结果只检查这些独立测试会话，不读取其他任务正文。Claude 最初一次拒绝试验被用户误点原生「通过」干扰，已排除；独立拒绝复测返回真实 Hook 拒绝。Codex 信任前的测试没有收到事件，同样不计作通过。
