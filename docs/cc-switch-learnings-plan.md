# 借鉴 cc-switch 的三项改进计划

> 来源：cc-switch 实现调研（Session Manager / 字节游标扫描 / 发布机制）。
> 排序原则：用户价值 × 成本。① ③ 小而美先做，② 是性能债、数据量大再做。

## ① 会话标题 + 搜索（P0，约半天）

现状：会话表只有 project/model/时间，找历史会话靠肉眼翻；cc-switch 的核心体验
是"有标题、能搜"。

### 数据源验证（已实测）

| 工具 | 标题来源 | 实测样例 |
|---|---|---|
| claude | jsonl 首个 user 消息 content | "Investigate why the murmur-qq…" |
| codex | rollout 首个 user 消息（首行是 session_meta） | ✓ |
| opencode | `session.title` 列现成 | "寻找并点评立秋节日图片美丑" |
| pi | 首个 user 消息 | ✓ |
| kimi | 事件流首个 user 消息 | ✓ |
| hermes | `sessions.display_name`（扫描器已在读） | ✓ |
| dsh | zstd 事件流首个 user 消息 | ✓ |

### 改动

1. **DB**：新增 `session_meta(tool, session_id, title, updated_at)` 表
   （标题是会话级属性，不应塞进事件级的 usage_events）；迁移走现有
   migrations 机制，老库自动建表。
2. **扫描器**：各扫描器在增量解析时顺手提取标题（首条 user 消息截断 80 字符，
   已有的直接取列）；只在"无标题或标题变化"时 upsert，避免重写。
3. **API**：`/api/sessions` 响应并入 title；新增 `q=` 参数
   （SQL LIKE 匹配 title/project/session_id/model）。
4. **前端**：会话页顶部加搜索框（300ms 防抖）；项目列显示"标题 + project 小字"；
   详情抽屉标题用 title 兜底。

### 验收

- 存量会话下次扫描后自动补标题（幂等，无需全量）
- 搜索框输入秒级过滤；注入字符安全（沿用 esc 约定 + 参数化 SQL）
- 测试：标题提取 fixtures（7 工具各一）、q= 过滤、迁移幂等

## ② 更新检查（P1，约 2 小时）

现状：升级靠手动 `build_app.sh` + 覆盖安装，有新版本无从知晓。

### 改动

1. **版本**：TokenTracker.spec 写入版本号；`/api/version` 返回当前版本 + git 短哈希。
2. **检查**：App 启动后（延迟 30s，不阻塞启动）查 GitHub Releases
   （`repos/fengfe1125/tokentracker/releases/latest`），结果缓存 24h 到
   `~/.tokentracker/update_check.json`；离线/超时静默。
3. **UI**：设置页新增「关于」卡片：当前版本 + 有新版本时显示
   「有新版本 vX.Y.Z →」按钮（打开 release 页手动下载）。

### 明确不做

自动更新/Sparkle/签名公证 —— 需要开发者证书（$99/年），当前手动安装成本可接受。
发布侧加一个 `make release` 脚本（打包 + 上传 release asset）即可。

### 验收

- 设置页显示版本；断网时不报错不阻塞
- 测试：版本解析、缓存过期、网络失败静默

## ③ 字节游标增量扫描（P2，性能债，约 1 天）

现状：文件一变（mtime+size+inode 指纹）就全量重解析，靠 message.id 幂等去重。
正确性没问题，但大会话文件（10MB+）每改一个字节全读一遍。

### 目标（cc-switch 思路）

- 每文件记录 `{offset, tail_hash}`：offset = 上次解析到的字节位置（行对齐），
  tail_hash = 末尾 4KB 的指纹
- 增量：`seek(offset)` 只解析新增字节；尾行不完整（写入中）→ 回退到行首
- 防护：`tail_hash` 不匹配或 offset > 文件大小 → 文件被截断/轮转 → 归零全量重扫
- message.id 幂等键保留为兜底（双保险）

### 范围

先只改 **claude**（文件最大最多）；codex/kimi 同为 JSONL 行格式可复用同一
增量器（抽到 `_util.py`）。opencode/hermes 是 SQLite 快照，不涉及。

### 验收

- 基准：对真实 `~/.claude/projects` 跑 before/after（记录解析字节数与耗时）
- 正确性：全量重扫结果与增量扫描结果逐字节一致（已有幂等测试扩展）
- 尾部指纹误报/截断恢复的 fixtures 测试

## 执行顺序与边界

① → ③ → ②。每项独立提交，不动对方功能的既有口径。
全程保持 147+ 测试通过；每步打包安装实测后推送。
