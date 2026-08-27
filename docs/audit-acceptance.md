# 审查问题修复验收（2026-08-27）

基线：`ac5321c`；分支：`codex/fix-audit-findings`。以下对应原审查的 2 项 PR 问题和 12 项项目问题。验证全部使用虚构日志、临时数据库、模拟时钟和模拟配额；未拿真实用量库试错，未读取真实 OAuth/钥匙串作为测试输入。

## 逐项对应

| 编号 | 问题 / 修复 | 回归与结果 |
|---|---|---|
| R1 | 配额请求失败仍保留状态栏旧值 → 清空 entries 和菜单配额行，降级今日 Token | `test_menubar.py::test_failed_quota_refresh_clears_previous_value_and_lines`，通过 |
| R2 | 从 note 猜测旧数据 → 窗口明确 source/stale，菜单标题复用同一选窗逻辑 | `test_title_and_menu_use_the_selected_windows_source`、`test_source_marker_does_not_depend_on_note`，平台切换及偏好保存通过 |
| A1 | 动态模型/项目/配额字段进入 innerHTML → 文本与属性转义 | `test_frontend.js` 两套界面及详情渲染；隔离浏览器实际显示载荷为文本，无注入 img/onerror，脚本标记为空 |
| A2 | Codex 缓存输入重复计费 → 四类互斥 Token 入库与分别计价 | `test_sqlite_normalizes_cached_input_before_pricing`，费用 **$0.56**；各统计接口统一 tokens/cache_write |
| A3 | 标准 Codex JSONL 漏导入 → 识别元数据、turn、token_count、ISO 时间和累计差量 | `test_scanners.py` 覆盖重复通知、重复扫描、last-only 接续、同 turn 双来源、部分来源补缺和源切换回滚，通过 |
| A4 | OpenCode/Hermes 累计用量被归到创建/最后时间 → 持久化快照、保留未分配存量、记录观察差量 | `test_aggregate_scanners.py`：历史 1000 + 新增 100，能定位的当天为100；跨日/月另报摘要；重置不产生负 Token；重复扫描不重计 |
| A5 | 仅刷新页面、不扫描日志 → Python 服务启动及每60秒调度，手动/自动互斥 | `test_server.py` 可控时钟验证100/160/220秒调度、互斥、错误恢复、stop；CLI默认不自动扫描，显式选项及退出路径通过 |
| A6 | Claude 百分比根据大小猜单位 → 直接读接口百分比 | `test_official_utilization_is_already_percent`：0.5→0.5%、1→1%；无效数值过滤，通过 |
| A7 | stale 回退绕过失败退避 → 最后成功与请求/重试状态分离 | `test_billing.py` 成功/失败120秒、force不绕429、Retry-After秒数/HTTP-date、非JSON错误体、长退避期间24小时过期，全部通过 |
| A8 | SQL 在SUM之外加缓存 → 四类总量逐行聚合 | `test_four_classes_sum_inside_each_row`：窗口/配额/统计/模型/会话/趋势均为 **340** |
| A9 | 并发缓存读改写丢平台 → 线程锁+flock+唯一临时文件+原子替换 | 5进程磁盘并发不丢provider；同平台同时force只发一次请求；缓存测试重复三轮通过 |
| A10 | 读取后保存文件状态导致尾部漏扫 → 保存读取前状态（ns/inode/size） | JSONL各scanner的EOF追加测试，下轮读到新增事件，通过 |
| A11 | DSH无头记录按basename撞键 → 完整相对路径身份 | 两目录同名文件均导入；旧fallback键仅在有效载荷匹配且新行已写入后替换，通过 |
| A12 | Claude顶层usage时message为空崩溃 → 先验证message类型，再兼容顶层usage | 缺失、null、非字典message均不崩溃，正确入库，通过 |

## 迁移与补充边界

- 虚构 v0 库先备份再事务迁移；已提交 WAL 数据包含在备份中，备份副本可独立升级。
- 验证总量保留、旧 Codex 原始值留档和费用来源标记、迁移失败完整回滚、重复升级安全。
- `time_quality` 区分 exact / observed / unallocated。跨分桶区间不被硬塞到单个小时/日期，限定范围返回单独摘要。
- 两连接同时更新快照：最终 **120**，无丢增量；写事务覆盖读取基线到写入事件。
- Hermes root=100、profile=900，旧全局行=900：先匹配来源再认领，合计 **1000**。多个下降来源无法判定时保留旧记录并报告潜在重叠。
- 官方累计费用由未知变为$2：历史估价与差量合计校准到 **$2**，校准事件为零 Token、时间未分配；覆盖费用来源切换、重置、扫描间价格回填。
- 显式 `scan --reset` 同时清所选工具快照，避免已清事件因旧基线而无法恢复；命令明确警告时间信息损失。迁移不调用reset。
- CLI/页面显示计数器重置与无法映射旧历史的警告，原始详情保留在扫描状态。

## 最终执行记录

| 检查 | 结果 |
|---|---|
| `python3 -m unittest discover -s tests -v` | **91项通过**（0.679秒；回环HTTP测试在获准环境执行） |
| `node tests/test_frontend.js` | 通过；真实渲染函数、恶意文本、四类总量、混合配额来源、时间质量与扫描警告 |
| `node --check app/web/app.js` | 通过；旧页面内联JS亦由渲染测试解析执行 |
| `git diff --check` | 通过 |
| `.venv/bin/python -c 'import app.menubar'` | 实际PyObjC导入通过 |
| 隔离浏览器 `/app/` 与 `/` | 恶意字段可见为纯文本；注入img=0、onerror属性=0、data-review-probe=null；全历史1440、当天440、未分配1000；详情显示观察区间；旧页面无console error/warn |
| macOS arm64 / Python3.13 / PyInstaller6.22.2 | 使用项目spec在临时目录打包成功；可执行文件存在，`LSUIElement=true` |
| `codesign --verify --deep --strict` | 通过（本地ad-hoc签名，不是发行公证） |

本次构建产物：`/tmp/tokentracker-fixed-build.BNFWX5/dist/TokenTracker.app`。日志：`/tmp/tokentracker-audit/final-tests.log`、`final-build.log`。临时文件可能被系统清理；长期可复跑入口是仓库测试和构建spec。

## 明确未验证 / 执行边界

- 未测试真实订阅/OAuth/钥匙串/外部凭据刷新，未进行联网官方配额请求。
- 未对安装版或本次构建执行原生菜单点击、真实隐藏/唤回的GUI验收；菜单业务逻辑、调度生命周期和PyObjC导入已分别测试。
- 未运行图标重生成脚本，使用仓库现有图标直接由spec打包，避免改动既有图标资产；未做Apple发行签名/公证。
- 未替换已安装App，未推送、合并PR，未改变用户配额上限。
- 源日志已丢失且旧身份不可靠时，保留记录并报告不确定性；无法凭空重建准确日期或证明所有来源完全无重叠。
