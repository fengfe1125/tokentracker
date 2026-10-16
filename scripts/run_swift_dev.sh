#!/usr/bin/env bash
# 构建并启动隔离的开发包，避免本地运行占用生产菜单栏身份。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

"$ROOT/scripts/build_swift_app.sh" --development
open "$ROOT/dist/TokenTracker Dev.app"
