# 订阅配额与余额

实现位于 `swift/Sources/TokenTrackerCore/Subscriptions/`；概览卡片在
`swift/Sources/TokenTrackerApp/Views/SubscriptionCardsView.swift`，设置页账号管理在
`SubscriptionAccountsView.swift`。

## 账号来源：只用 TokenTracker 自己的账号

查询只使用 `~/.tokentracker/subscription_accounts.json`（0600，原子替换）中的账号，
不读取其他软件的配置或登录态。ad-hoc 签名每次更新都会让钥匙串重新弹窗授权，
因此与发布 Token 一样使用仅本人可读的文件。

| 方式 | 供应商 |
| --- | --- |
| 粘贴授权码（PKCE） | Claude、Gemini |
| 设备码 | Codex、Kimi（中国区/国际区）、GitHub Copilot、Grok |
| 浏览器登录后自动轮询 | WorkBuddy、WorkBuddy AI、ZCode（Z.ai/BigModel） |
| API Key（手动添加或一键导入） | DeepSeek、OpenCode Go、MiniMax（中国区/国际区）、Kimi |

- 自己登录得到的是 TokenTracker 独立的会话，由 TokenTracker 在过期前 5 分钟或收到 401 时
  用自己的刷新令牌续期，与 Claude Code、Codex、Magpie 等互不影响。刷新被拒时卡片显示
  “凭据失效”，需在设置中重新登录。ZCode 会话没有刷新令牌，到期后需重新登录。
- 一键导入只复制一次本机配置中可直接查询的 API Key（OpenCode、Pi、Magpie、DSH、Hermes、
  Gemini CLI、环境变量），不导入 OAuth 登录态，不导入配给第三方中转的 Key；之后不再读取原文件。
- 同一账号（账号 ID 相同或凭据相同）重复登录/添加时只保留一条记录。多把 Key 分别展示，不叠加。
- 菜单栏圆环（Claude/Codex/Kimi/OpenCode Go）使用设置页指定的账号；未指定且该供应商只有一个
  账号时使用它；无法确定时不显示数据，不使用本地 Token 估算。

## 查询

- 每家只把凭据发往登记的 https 域名（登录与查询分别登记），不跟随重定向，无 Cookie 与 URL 缓存。
- 成功缓存 5 分钟；网络错误 1 分钟后重试；遵守 Retry-After（含强制刷新）；单请求 15 秒；
  最多 4 个并发。
- 失败时展示 24 小时内的上一份官方结果并标注过期（`~/.tokentracker/subscription_cache.json`
  只存快照，不含凭据、邮箱、原始账号 ID 或路径）。
- Copilot、Gemini、MiniMax、Grok、WorkBuddy、ZCode 依赖非公开接口，卡片标注“非公开接口”。

## 诊断

```bash
swift run --package-path swift tt-swift subscriptions [--import-keys] [--list-only] [--debug]
```

输出供应商、状态、错误类别和来源；`--debug` 额外打印主机、状态码和响应顶层键名，
不打印凭据或数据值。会访问官方接口，只读取额度与余额。
