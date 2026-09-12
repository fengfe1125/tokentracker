# TokenTracker 公开统计

把本机 TokenTracker 统计到的 Token 用量发布成一个公开只读的 JSON，
再嵌进任何网站。**本机日志不出本机**，出去的只有聚合数字。

```
本机 macOS                    Cloudflare                    任意网站
TokenTracker.app  ──PUT──▶  tokentracker-stats  ──GET──▶  你的页面
+ tt-swift CLI     Bearer    D1 + 边缘缓存        CORS *
```

## 出去的到底是什么

`tt-swift export-public --pretty` 打印完整载荷。**发布前先自己读一遍。**

会公开：分日 token 数（365 天整数数组）、按 CLI 工具的 token 与成本、
连续天数、峰值日、最长连续对话时长、时区、应用版本。

**永不外发**：项目路径、会话 ID、会话标题、原始 prompt、模型名、
文件路径、主机名、账号信息。这条由四层保证：

1. 载荷是手写的 struct + 显式 `CodingKeys`，绝不对含数据库行的类型做反射编码。
2. `PublicStatsTests` 的白名单断言 —— 多一个字段就失败。
3. 反向测试：把已知敏感值种进库，断言序列化结果里搜不到。
4. **服务端校验器拒绝任何未知字段** —— 客户端哪怕出 bug，也只会拿到 400。

数据的**形状**本身也是信息：一张带尖峰的热力图加一个成本数字，
能让人推断出你的套餐档次甚至工作强度。这是你的知情选择。

服务只存它被告知的内容，**不做任何真实性背书** —— 别把别人的数字当已验证数据。

## 自部署

需要一个 Cloudflare 账号（免费档够用）。

```bash
git clone https://github.com/fengfe1125/TokenTracker
cd TokenTracker/web/worker
npx wrangler login          # 需要 d1:write 与 workers:write
./setup.sh <你的handle> <你的域名>
```

脚本会建 D1、应用 schema、部署 Worker、注册 handle，
并把发布 token 写进权限为 0600 的本地文件（**明文不打印到任何地方**）。
可重复执行，已完成的步骤会跳过。

### 本地跑一遍

```bash
npx wrangler d1 execute tokentracker-stats --local --file=./schema.sql
npx wrangler dev --port 8799
curl localhost:8799/healthz
```

## 接口

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/healthz` | — | 存活检查 |
| GET | `/v1/stats/:handle` | 公开 | 载荷；`ETag` + `If-None-Match` → 304 |
| PUT | `/v1/stats/:handle` | Bearer | 上报；≤64KB；每 10 分钟一次 |
| POST | `/v1/stats/:handle/rotate` | Bearer | 换 token，新值只返回一次 |
| POST | `/v1/handles` | Bearer ADMIN | 注册 handle |
| DELETE | `/v1/stats/:handle` | Bearer ADMIN | 删除 |

**发布后最多 5 分钟才全局可见**（边缘缓存 `s-maxage=300`）。
「我发了怎么没变」多半是这个，不是坏了。

安全边界：token 落库只存 SHA-256，比对走常量时间；
**PUT 上刻意不给任何 CORS 头**，浏览器因此无法被诱导带 token 发跨站写请求；
「从未注册」与「已注册未发布」返回完全相同的 404，杜绝 handle 枚举。

## 客户端

```bash
tt-swift export-public --pretty        # 只写 stdout，不联网
tt-swift publish --config handle=你的名 endpoint=https://你的域名 enabled=true
tt-swift publish --set-token           # 从 stdin 读 token，写入 0600 文件
tt-swift publish --set-token --keychain # 改写钥匙串（见下方说明，多数情况不要用）
tt-swift publish --dry-run             # 看载荷大小与本次决策
tt-swift publish --status
```

### token 存哪里

解析顺序：`TOKENTRACKER_PUBLISH_TOKEN` 环境变量 →
`~/.tokentracker/publish_token`（0600）→ 钥匙串。

**默认走文件，不走钥匙串**，因为钥匙串在 ad-hoc 签名下会反复弹密码框：
条目的 ACL 绑定创建它的那个二进制身份，而本项目全程 ad-hoc 签名 ——
App 的标识是 `com.tokentracker.desktop.v2`，`tt-swift` 的标识里直接带着
二进制哈希（`tt-swift-5555…`），**每次重新编译都变**。
于是「谁建的谁能读」永远不成立，每次读都被当成陌生程序而弹窗。
这个用 ad-hoc 签名无解，需要稳定的 Developer ID 证书。

0600 文件与本项目既有做法一致 —— `codex_accounts.json`、
`claude_cred_backup.json` 都是同目录下 0600 明文。

`--keychain` 留给用真实证书签名的情况。要从钥匙串切回文件，
删掉条目即可（条目不存在时 `SecItemCopyMatching` 静默返回 not-found，不弹窗）：

```bash
security delete-generic-password -a <你的handle> -s com.tokentracker.publish
```

忘了 token 也不用找回 —— 重跑 `web/worker/setup.sh` 会检测到本机没有
可用 token 并重新签发。

App 每次扫描结束后会尝试上报，三道闸决定发不发：

1. **内容去重** —— 剔除 `generated_at` 后算哈希，一样就不发。空闲机器上写入接近 0。
2. **最小间隔 15 分钟** —— 常量，不给用户一个能打爆额度的旋钮。
3. **失败退避** —— 60s 起翻倍，上限 6 小时，成功即清零。

必要性来自额度：`onFinish` 默认 60 秒一次 = 每天 1440 次，
而免费档 KV 每天只有 **1000 次写（全实例共享）**，D1 是 10 万行/天。
选 D1 正是因为 KV 那条线大约 10 个用户就会把整个实例锁死。
服务端另有 10 分钟 CAS 下限，行为异常的客户端在边缘就被挡住。

发布失败绝不影响扫描：所有错误落到 `~/.tokentracker/publish_state.json`。

真正发起的网络请求另存为 `~/.tokentracker/publish_history.json`，只保留最近
50 次成功或失败记录，不含 token、请求头或完整载荷。App 的设置页可以查看并清空。

设置页提供三种操作：自动上传开关、遵守去重/节流/退避的“按规则上传”，以及
需要二次确认的“强制上传”。强制上传只绕过客户端三道闸，不绕过配置与 token 校验。

## 嵌进自己的网站

```html
<!-- 裸 JSON，自己渲染（sakuramu.edu.kg 用的就是这条） -->
<script>
fetch('https://tt.sakuramu.edu.kg/v1/stats/sakuramu')
  .then(r => r.json())
  .then(d => { /* d.daily.tokens 是按日的整数数组 */ })
  .catch(() => {});   // 务必静默兜底，别让统计服务拖垮你的首页
</script>
```

载荷字段见 `swift/Tests/TokenTrackerCoreTests/Fixtures/public_stats_v1.json`。
两个可选键 `peak` 与 `longest_burst` 在无数据时**整个键省略**（不是 `null`）。

## 口径

- token 四列互斥（输入/输出/缓存读/缓存写），总量是四项之和，缓存读写计入。
- 日期在**发布时的本机时区**切分，载荷里钉死 `tz`；渲染时直接用预分桶的日期字符串，
  浏览器绝不重新从时间戳推导。
- `tokens_undated` 是无法定位到某一天的历史，计入总量但**不进热力图**。
  `tokens_dated + tokens_undated == tokens` 恒成立，校验器会强制这一点。
- **最长连续对话只统计有精确时间戳的工具**。`opencode` 与 `hermes` 全部走累计快照，
  它们的时间戳是扫描时刻而非事件时刻，纳入统计会得出「连续聊了 42 小时」这种数字。
  载荷里的 `caveats.snapshot_only_agents` 列出被排除的工具。
