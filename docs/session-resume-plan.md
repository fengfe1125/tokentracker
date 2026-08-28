# 会话记录 → 一键「继续会话」计划

> 目标：会话记录列表/详情抽屉里点一个按钮，直接在终端打开并恢复该会话。
> 参考：cc-switch Session Manager、AIEye、AgentCliMenu。

## 一、同类工具的做法（cc-switch 为主）

cc-switch 的 Session Manager resume 流程：

1. 会话行上有 **Resume 按钮**（▶ 图标），无可恢复命令时按钮禁用；
2. 点击后用**用户偏好的终端**（Terminal.app / iTerm2 / Ghostty / WezTerm / Kitty /
   Alacritty / Warp）打开，**自动 cd 到会话原始项目目录**再执行 resume 命令；
3. 终端启动失败时**把命令复制到剪贴板**兜底，用户手动粘贴；
4. v3.13.0 起支持恢复前**改选目录**（项目被移动/改名过的场景）。

## 二、各工具 resume 命令（本机实测，非道听途说）

| 工具 | 命令 | session_id 格式（库内实测） | 可恢复 |
|---|---|---|---|
| Claude Code | `claude --resume <uuid>` | uuid（= jsonl 文件名） | ✅ |
| Codex | `codex resume <uuid>` | uuid | ✅ |
| Kimi Code | `kimi --session session_<uuid>`（CLI 的会话 ID 带 `session_` 前缀，见 `~/.kimi-code/session_index.jsonl`；扫描器存的裸 uuid 需补回） | uuid | ✅ |
| opencode | `opencode --session <ses_*>` | `ses_...` | ✅ |
| Pi | `pi --session <id>`（支持部分 uuid） | uuid | ✅ |
| Hermes | `hermes --resume <session>` | `20260801_223831_db58bf` | ✅ |
| DSH | 本机无 dsh CLI，只有 zstd 日志 | — | ❌ 按钮禁用并注明 |

项目目录来源：

- codex / kimi / opencode / pi / hermes / dsh：DB `project` 字段已是真实路径（可能为空）；
- claude：DB 里是 slug（`-Users-sakura-Murmur`），**优先**读
  `~/.claude/projects/<slug>/<session_id>.jsonl` 首行的 `cwd` 字段（可靠），
  读不到再回退现有 slug→路径启发式（`desktop.open_in_finder` 同款逻辑）。

## 三、实现方案

### 1. 新增 `tokentracker/resume.py`（纯逻辑，零 AppKit 依赖，可单测）

> 实现时从计划的 `app/resume.py` 移到 `tokentracker/`：逻辑无桌面依赖，放进核心包后
> `tt serve` 浏览器模式也能通过 `/api/resume` 拿到命令（前端降级为复制命令）。

```python
RESUME_CMDS = {"claude": ["claude", "--resume"], "codex": ["codex", "resume"],
               "kimi": ["kimi", "--session"], "opencode": ["opencode", "--session"],
               "pi": ["pi", "--session"], "hermes": ["hermes", "--resume"]}

def resume_argv(tool, session_id) -> list[str] | None   # 不支持 → None
def resolve_cwd(tool, session_id, project) -> str | None # claude 读 jsonl cwd；路径不存在 → None
def shell_line(argv, cwd) -> str                        # shlex.quote 逐参数，cd && exec
```

- 所有插值一律 `shlex.quote`，绝不拼裸字符串（session_id/project 虽来自本地库，仍按不可信处理）；
- 用 `shutil.which` 探测 CLI 是否存在，不存在 → 返回不可用原因（如"未安装 kimi"）。

### 2. 服务端 + `desktop.py` Api 桥接

- `GET /api/resume?tool=&session_id=&project=` → `{"ok","reason","command","cwd","cwd_missing"}`，
  前端两种模式共用；
- `Api.resume_session(tool, session_id, project, cwd)`：按 settings 里的 `terminal_app`
  用 osascript / open 打开终端；失败自动 pbcopy 兜底；
- `Api.copy_resume_command(...)` / `Api.pick_resume_directory()`（pywebview 原生目录面板）。

```python
def resume_info(self, tool, session_id, project) -> dict
    # {"ok": bool, "reason": str, "command": str} —— 前端据此启用/禁用按钮
def resume_session(self, tool, session_id, project) -> dict
    # 按 settings 里的 terminal_app（默认 auto）用 osascript 打开终端并执行；
    # 失败自动 pbcopy 命令并返回 {"ok": False, "copied": True}
def copy_resume_command(self, tool, session_id, project) -> str
```

终端选择：`auto` = 依次探测 iTerm2 → WezTerm → Ghostty → Terminal.app（兜底必在）。
AppleScript 只传一段 `do script <quoted>`，命令本体先经 shlex.quote 再做 AppleScript 字符串转义。

### 3. 前端（app/web）

- **详情抽屉**：头部操作区加主按钮「▶ 继续会话」+ 次按钮「复制命令」；
  进抽屉时调 `resume_info` 决定启用/禁用与提示文案（DSH 显示"该工具不支持恢复"）；
- **会话列表行**：操作列加小号 ▶ 按钮（同样的可用性逻辑）；
- 无 pywebview 桥（纯浏览器 `tt serve`）时：按钮降级为「复制命令」（clipboard API）。

### 4. 设置页新增一项（复用刚做的设置体系）

- 「**终端 App**」下拉：自动 / Terminal / iTerm2 / WezTerm / Ghostty，
  键名 `terminal_app`，加入 `/api/settings` 白名单（值校验走同一 schema）。

### 5. 可选增强（列入 v1，工作量小）

- 项目目录不存在时：按钮文案变「选择目录并继续…」，走原生 `NSOpenPanel` 选目录
  （对应 cc-switch v3.13.0 的目录覆盖场景）；不选则只复制命令。

## 四、明确不做（YAGNI）

- 不做应用内嵌终端 / WebView 里跑 CLI；
- 不支持 Windows/Linux（本应用就是 macOS 状态栏应用）；
- 不做 resume 后回到 App 的会话联动刷新（现有 60s 自动扫描自然覆盖）；
- DSH 不做（无 CLI 入口）。

## 五、测试

- `tests/test_resume.py`：命令矩阵、引号/注入字符（`;`, `$()`, 空格、中文路径）、
  claude slug→cwd（构造假 jsonl）、CLI 缺失、目录缺失、DSH 禁用；
- `tests/test_server.py`：`terminal_app` 纳入 settings 白名单的校验用例；
- 自检：`TT_SELFCHECK=1` 跑一次，drawer 渲染 + `resume_info` 桥接无 JS 错误；
- 手动验收：真实恢复一条 claude 会话和一条 codex 会话。

## 六、改动清单（预估）

| 文件 | 改动 |
|---|---|
| `app/resume.py` | 新增，~120 行 |
| `app/desktop.py` | +3 个 Api 方法 |
| `tokentracker/server.py` | settings 白名单 +`terminal_app` |
| `app/web/index.html` / `app.js` / `app.css` | 抽屉按钮、行内按钮、设置项 |
| `tests/test_resume.py` | 新增 |
| `tests/test_server.py` | +1 用例 |
| `README.md` | 功能说明 + 支持矩阵 |
