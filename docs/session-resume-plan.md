# 会话恢复实现说明

TokenTracker 的会话详情窗口可以在终端中继续 Claude Code、Codex、Kimi、opencode、Pi 和 Hermes 会话。
DSH 没有可用 CLI，因此不显示可执行恢复动作。

## 行为

- 根据工具和 session ID 生成参数数组，不通过字符串拼接执行命令。
- 自动恢复扫描器记录的项目目录；目录移动后允许用户重新选择。
- 支持 Terminal、iTerm2、WezTerm 和 Ghostty，自动模式按可用性选择。
- 终端启动失败时把完整命令复制到剪贴板。
- Claude 子代理伪会话或源日志已经不存在时，不提供必然失败的恢复按钮。

实现位于 `swift/Sources/TokenTrackerCore/Resume/Resume.swift`，界面入口位于独立会话详情窗口。

## 验证

`ResumeTests` 覆盖各工具参数、shell 转义、CLI 缺失、目录缺失、Claude cwd 恢复、
终端选择、AppleScript 转义、打开失败和剪贴板降级。涉及真实终端的授权与打开行为需要在 macOS 上人工验收。
