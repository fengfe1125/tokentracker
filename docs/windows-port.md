# Windows 版：路径与键的规范

这些规则决定写进 `usage.db` 的键（`src_key`、`source_scope`、扫描游标、项目路径）。
**一旦发布就不能随意改**——改了会让旧行和新行对不上，需要写迁移。

## 根目录

默认值或环境变量覆盖后，统一经 `WinPaths.Expand`：展开 `~` 与 `%VAR%`，`Path.GetFullPath`，
反斜杠分隔，去掉末尾分隔符，**不改大小写**。

| 工具 | 默认位置 | 覆盖 |
|---|---|---|
| Claude Code | `%USERPROFILE%\.claude\projects` | `CLAUDE_PROJECTS_DIR` |
| Codex | `%USERPROFILE%\.codex\sessions`、`%USERPROFILE%\.codex\logs_2.sqlite` | `CODEX_SESSIONS_DIR`、`CODEX_LOGS_DB` |
| Kimi Code | `%USERPROFILE%\.kimi-code\server\events` | `KIMI_CODE_HOME` |
| DSH | `%USERPROFILE%\.dsh\sessions` | `DSH_SESSIONS_DIR` |
| Pi | `%USERPROFILE%\.pi\agent\sessions`、`%USERPROFILE%\.omp` | `PI_HOME` |
| opencode | `%USERPROFILE%\.local\share\opencode\opencode.db` | `OPENCODE_DB` |
| Hermes | `%USERPROFILE%\.hermes` 与 `%LOCALAPPDATA%\hermes` | `HERMES_HOME`（设置后只看它） |

## 键里的路径

1. **拼接路径**（Codex `legacy|<path>|<行号>`、各扫描器游标键）：规范根目录 + `\` + 枚举得到的相对路径。
2. **真实路径**（活动键 `<path>|…`、opencode / Hermes 的 `source_scope`）：`WinPaths.Real`
   = `GetFinalPathNameByHandleW` 去掉 `\\?\` 前缀，解析联接点、8.3 短名与磁盘上的大小写（对齐 CPython `ntpath.realpath`）。
3. **不会再打开的相对身份片段**（DSH 兜底会话 id）：统一用 `/` 分隔，与平台无关。
4. **`usage_events.project`**：按工具原始记录保存。
5. **项目路径表**（`project_sources` / `project_paths`）：Windows 全限定路径存 `Real()` 之后的值；
   POSIX 形式的外来路径（`/Users/...`）原样保存，不调 git。
6. **aggregate 摘要** = `sha256(json.dumps([scope, identity]))`（Python 兼容序列化，反斜杠转义为 `\\`），
   scope 字符串稳定则摘要稳定。

## 遍历顺序

目录遍历包含隐藏文件、不进入联接点 / 符号链接目录；按 `/` 分隔的相对路径做序号排序
（与 POSIX 上 `sorted()` 一致）。Codex 去重依赖处理顺序，不能改成 `\` 排序。

## 文件指纹

游标里的 `{"m","s","i","d"}` 在 Windows 上是：最后写入时间（纳秒）、大小、文件索引、卷序列号，
取自打开句柄上的 `GetFileInformationByHandle`（目录枚举的元数据对仍被写入的文件会滞后）。

## 与 Python CLI 共用

Python 包目前在 Windows 上无法 import（`fcntl`）。若以后让它支持 Windows，
其 `expand()` 需要在 nt 上加 `os.path.normpath`，才能与第 1 条的键一致。
