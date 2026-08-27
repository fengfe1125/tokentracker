# TokenTracker 线条图标

## 源稿与资产

[Figma：TokenTracker · App Icon](https://www.figma.com/design/HFAWys8F1N3MDP3HXZvGIB)，位于 jiwo 团队草稿。
App 原稿节点 `2:2`；透明符号节点 `2:7`；深浅背景尺寸校验节点 `3:2`、`3:18`。
源稿由可编辑路径组成；无文字、渐变、位图、脚本或外部资源。

| 文件 | 用途 |
| --- | --- |
| `assets/icon.svg` | Figma 直接导出的 1024 × 1024 矢量原稿 |
| `assets/icon_1024.png` | Figma 直接导出的 RGBA PNG，四周透明 |
| `assets/icon.icns` | 从该 PNG 离线生成的 macOS 图标 |
| `app/web/brand.svg` | Figma 导出的透明符号，同时用作两页 favicon |
| `app/web/brand.css` | 共用 CSS mask，浅色页面 `#C15F3F`，深色页面 `#D97757` |

底板 `#FAF8F5`，在 1024 画布中四周留 64 像素透明边距；底板边长 896、圆角 200。
开口圆环和折线线宽均为 56，使用圆头和圆角。透明符号裁为 640 × 640，保留线条周围空白。

![App 图标](../assets/icon_1024.png)

## 更新与离线构建

1. 在 Figma 修改可编辑矢量；检查 16、32、64、1024 像素和深浅背景。
2. 导出 SVG 和 1024 PNG，覆盖对应源资产；透明符号单独导出。使用节点内容导出，避免包含 Figma 画布背景。
3. 在 macOS 执行 `bash scripts/build_icon.sh`，生成 ICNS 并一同提交。PNG 不被改写。
4. 执行 `python3 scripts/check_icon.py` 及回归测试，然后打包。

ICNS 包含 16、32、128、256、512 点的 1× 和 2× 表示，实际像素覆盖 16–1024。
旧的程序绘图脚本已移除。`scripts/build_app.sh` 只验证并消费已提交的资产；不联网获取设计、不生成或覆盖图标。
首次安装 PyInstaller/pywebview 依赖仍可能联网，与图标资产无关。
应用名称、Bundle ID `com.tokentracker.desktop`、状态栏逻辑、配额配置和数据库不变。

## 本地验收（2026-08-27）

- Figma：1024 原稿、16/32/64 实际尺寸在深浅背景下可辨认；小尺寸仍可分辨圆环与折线。
- 自动检查：SVG 仅允许路径/分组及安全属性；PNG 为 1024 RGBA、外缘透明；ICNS 尺寸齐全。脚本、外链、嵌入位图和不完整 ICNS 的回归样例均被拒绝。
- Python：103 项测试通过；JavaScript 语法和前端回归通过。额外覆盖意外导出不透明画布背景；ICNS 的 1024 像素内容必须与 PNG 原稿相同。
- 浏览器：使用 `tests/browser_fixture.py` 的虚构数据检查两页；标题栏 16px、侧栏 34px、深色页 24px 标识无灰底，均加载 `/app/brand.svg`。控制台无错误，注入标记未出现。
- macOS arm64：`bash scripts/build_app.sh` 成功；包内 ICNS 与仓库逐字节相同，共用 SVG/CSS 已打包。
- `codesign --verify --deep --strict` 通过；签名是本地 ad-hoc 签名，不是 Developer ID 签名或 Apple 公证。
- 原生打包窗口：侧栏线条标识清晰，无旧渐变方块；红绿灯保留，会话页切换正常。这里只检查 UI，未将真实 OAuth 作为测试对象。

原生安装验收由发布时执行：先备份旧 App，再替换同一路径并启动，保留 Dock 固定项；不清空 Dock 配置。
