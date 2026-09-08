# TokenTracker 线条图标

## 源稿与资产

[Figma：TokenTracker · App Icon](https://www.figma.com/design/HFAWys8F1N3MDP3HXZvGIB)
位于 jiwo 团队草稿。App 原稿节点 `2:2`，由可编辑路径组成，无文字、渐变、脚本或外部资源。

| 文件 | 用途 |
|---|---|
| `assets/icon.svg` | Figma 导出的 1024 × 1024 矢量原稿 |
| `assets/icon_1024.png` | Figma 导出的 RGBA PNG，四周透明 |
| `assets/icon.icns` | macOS App 打包图标 |

底板颜色为 `#FAF8F5`；1024 画布四周保留 64 像素透明边距，开口圆环和折线使用圆头与圆角。

![App 图标](../assets/icon_1024.png)

## 更新与验证

1. 在 Figma 修改矢量源稿，检查 16、32、64 和 1024 像素显示。
2. 导出 SVG 与 1024 PNG 并覆盖仓库资产。
3. 执行 `bash scripts/build_icon.sh` 生成 ICNS。
4. 执行 `python3 scripts/check_icon.py` 和 `python3 -m unittest tests.test_icon_assets -v`。
5. 执行 `./scripts/build_swift_app.sh`，确认包内 ICNS 与仓库文件一致。

验证器会检查 SVG 不含脚本、链接、文字和声明，PNG 为带透明边缘的 1024 RGBA，
ICNS 包含完整的 1×/2× 表示且 1024 图与 PNG 一致。
