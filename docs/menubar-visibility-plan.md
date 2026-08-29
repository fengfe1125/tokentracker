
## 七、执行结果与根因修正（2026-08-29）

实施中发现原计划基于的错误假设，实测修正：

1. **根因是 macOS 26 Tahoe StatusKit 门控**：系统设置 → 菜单栏 里需用户手动允许
   TokenTracker；`isVisible()` 对未批准/被隐藏项仍返回 True（探测盲区）。
   证据：单条目实验（isVisible=True 但屏幕不渲染）；ledger 里存在
   `com.tokentracker.desktop` 条目。
2. **attributedTitle 重复赋值会触发 Tahoe 消失缺陷** → 渲染层加缓存，
   纯文本/富文本只在变化时写入 button。
3. **NSVariableStatusItemLength 只按 setTitle_ 测量宽度** → 纯文本与富文本必须同设。
4. 自愈保留：isVisible 检测（治真删除）+ 每 60s 无条件重排轻推（治探测不到的卡隐藏）。
5. 设置页新增「状态栏图标不显示？」引导行，一键打开系统设置菜单栏面板。

遗留（需用户操作）：系统设置 → 菜单栏 → 允许 TokenTracker；
若列表中允许后仍不显示，为 Tahoe ledger 孤儿条目问题，需重置 ControlCenter 相关缓存。

## 八、最终根因与处置记录（2026-08-29 收尾）

1. **ledger 孤儿条目（用户列表里找不到 TokenTracker 的直接原因）**：
   `trackedApplications` 中 TokenTracker 被嵌套登记在 com.apple.Terminal 和
   com.openai.codex 的 menuItemLocations 下（早期从终端运行 dev/selfcheck 所致），
   顶层条目虽 isAllowed=true 但不生效。处置：备份后重写 plist，仅移除两处嵌套引用，
   重启 cfprefsd + ControlCenter → 图标恢复渲染。
2. **json 漏 import（标题永远 "⚡—" 的原因）**：重写 menubar.py 时丢失
   `import json`，`_get` 每轮抛 NameError 被裸 except 吞掉。已修并加回归测试。
3. 验证：截图确认 `⚡57.22M·C12%`（compact + 分段着色）正常渲染。
