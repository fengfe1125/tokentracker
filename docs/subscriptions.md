# 订阅配额与余额

实现位于 `swift/Sources/TokenTrackerCore/Subscriptions/`，概览卡片在
`swift/Sources/TokenTrackerApp/Views/SubscriptionCardsView.swift`。

## 发现

只读约定位置，不遍历全盘、不读浏览器 Cookie、不执行配置脚本、不加载插件代码：

| 来源 | 位置 |
| --- | --- |
| Claude Code（当前登录） | 钥匙串 `Claude Code-credentials`、`$CLAUDE_CONFIG_DIR/.credentials.json` |
| Codex（当前登录） | `$CODEX_HOME/auth.json`；TokenTracker 已保存的 Codex 账号 |
| Kimi Code（当前登录） | `$KIMI_CODE_HOME/credentials/kimi-code.json` |
| OpenCode | `$XDG_DATA_HOME/opencode/auth.json`；`opencode.json(c)` 的自定义 `baseURL` |
| Pi | `$PI_CODING_AGENT_DIR/auth.json`（默认 `~/.pi/agent`） |
| Gemini CLI | `~/.gemini/oauth_creds.json`、`~/.gemini/.env` |
| Magpie | `$MAGPIE_HOME/logins.json`、`plugin-auth.json`、`providers.json`（不读其配额缓存） |
| DSH | `~/.dsh/.credentials.yaml` 与 `profiles/*/.credentials.yaml` 的 `refs` |
| Hermes | `$HERMES_HOME/.env` |
| 其他 | 进程环境变量；设置页添加的配置目录 |

去重：同一供应商下供应商账号 ID 相同或凭据完全相同才合并；查询后得到的账号 ID
（如 Claude profile）可再合并。不按邮箱合并，不叠加多把 Key 的余额。配给第三方中转
（`baseURL`/`*_BASE_URL` 非官方域名）的 Key 只列出原因，不发往官方接口。

## 查询

- 每家只把凭据发往登记的 https 域名，不跟随重定向，无 Cookie 与 URL 缓存。
- 不刷新、不轮换、不回写其他工具的登录态；过期凭据不发请求，显示“凭据失效”。
- 成功缓存 5 分钟；网络错误 1 分钟后重试；遵守 Retry-After（含强制刷新）；
  单请求 15 秒；最多 4 个并发。每分钟重新发现，凭据指纹变化立即失效缓存。
- 失败时展示 24 小时内的上一份官方结果并标注过期（`~/.tokentracker/subscription_cache.json`
  只存快照，不含凭据、邮箱、原始账号 ID 或路径）。
- Copilot、Gemini、MiniMax、Grok、WorkBuddy、ZCode 依赖非公开接口，卡片标注“非公开接口”。
- 菜单栏圆环只绑定 Claude/Codex/Kimi/OpenCode Go 的当前登录账号；无法唯一确定时不显示数据，
  不再使用本地 Token 估算。Python CLI 的 `quotas` 估算保持原样。

## 诊断

```bash
swift run --package-path swift tt-swift subscriptions --debug
```

输出供应商、状态、错误类别和脱敏来源；`--debug` 额外打印主机、状态码和响应顶层键名，
不打印凭据或数据值。会访问真实凭据对应的官方接口，只读取额度与余额。
