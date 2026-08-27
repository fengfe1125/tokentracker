#!/usr/bin/env bash
# TokenTracker 桌面应用打包脚本（macOS）
# 产物：dist/TokenTracker.app —— 自包含 .app，双击即用（无需预装 Python）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PY="$ROOT/.venv/bin/python"
export PYINSTALLER_CONFIG_DIR="$ROOT/.cache/pyinstaller"

echo "==> 检查依赖环境"
if [ ! -x "$PY" ]; then
  echo "    创建 venv 并安装 pywebview / pyinstaller ..."
  python3 -m venv "$ROOT/.venv"
  "$ROOT/.venv/bin/pip" -q install --upgrade pip
  "$ROOT/.venv/bin/pip" -q install pywebview pyinstaller
fi
"$PY" -c "import webview, PyInstaller" 2>/dev/null || "$ROOT/.venv/bin/pip" -q install pywebview pyinstaller

echo "==> 校验仓库中已确认的图标（不重绘、不联网导出）"
"$PY" scripts/check_icon.py

echo "==> PyInstaller 打包（首次较慢）"
rm -rf build dist
"$ROOT/.venv/bin/pyinstaller" --noconfirm --clean "$ROOT/TokenTracker.spec"

echo ""
echo "✅ 完成：dist/TokenTracker.app"
echo "   运行：open dist/TokenTracker.app"
echo "   重新打包：./scripts/build_app.sh"
