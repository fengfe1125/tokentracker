#!/usr/bin/env bash
# 开通 tokentracker-stats：建 D1、应用 schema、部署 Worker、注册一个 handle，
# 并把 token 直接写进 macOS 钥匙串。可重复执行，已存在的步骤会跳过。
#
# 前置：wrangler 需要有 d1:write 与 workers:write 权限。默认的 OAuth token
# 可能只有读权限，先跑一次 `npx wrangler login` 重新授权即可。
#
#   用法：./setup.sh <handle> [自定义域名]
#   例子：./setup.sh sakuramu tt.sakuramu.edu.kg

set -euo pipefail
cd "$(dirname "$0")"

HANDLE="${1:-}"
DOMAIN="${2:-tt.sakuramu.edu.kg}"
DB_NAME="tokentracker-stats"
KC_SERVICE="com.tokentracker.publish"

if [[ -z "$HANDLE" ]]; then echo "用法: ./setup.sh <handle> [域名]" >&2; exit 1; fi
if ! [[ "$HANDLE" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]]; then
  echo "✗ handle 只能是小写字母数字与连字符，2–31 位" >&2; exit 1
fi

wr() { npx --yes wrangler@4 "$@"; }

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. D1 ----
step "1/6 检查 D1 数据库 $DB_NAME"
# 按**名字**在当前账号里查，而不是信配置里的 id ——
# 别人 clone 这个仓库时配置里是别人的 id，直接用会对着一个不属于他的库部署。
DB_ID="$(wr d1 list --json 2>/dev/null | python3 -c "
import json,sys
try: rows = json.load(sys.stdin)
except Exception: rows = []
print(next((r['uuid'] for r in rows if r.get('name') == '$DB_NAME'), ''))" || true)"

if [[ -z "$DB_ID" ]]; then
  echo "  本账号下没有，创建中…"
  CREATE_OUT="$(wr d1 create "$DB_NAME" 2>&1 || true)"
  DB_ID="$(printf '%s' "$CREATE_OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  if [[ -z "$DB_ID" ]]; then
    printf '%s\n' "$CREATE_OUT" | tail -20 >&2
    echo "✗ 建库失败。若是 Authentication error，先跑：npx wrangler login" >&2
    exit 1
  fi
  echo "  ✓ 已创建"
fi

CONFIGURED="$(grep -o '"database_id": *"[^"]*"' wrangler.jsonc | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [[ "$CONFIGURED" != "$DB_ID" ]]; then
  DB_ID="$DB_ID" python3 -c "
import os, re, pathlib
p = pathlib.Path('wrangler.jsonc'); s = p.read_text()
p.write_text(re.sub(r'\"database_id\": *\"[^\"]*\"',
                    '\"database_id\": \"%s\"' % os.environ['DB_ID'], s, count=1))"
  echo "  ✓ database_id = $DB_ID（已写回 wrangler.jsonc）"
else
  echo "  ✓ database_id = $DB_ID"
fi

# ------------------------------------------------------------ 2. schema ----
step "2/6 应用 schema"
wr d1 execute "$DB_NAME" --remote --file=./schema.sql >/dev/null
echo "  ✓ handles / stats / reg_log 就绪"

# ------------------------------------------------------------ 3. 部署 ----
step "3/6 部署 Worker 到 $DOMAIN"
wr deploy 2>&1 | tail -5

# -------------------------------------------------------- 4. 客户端配置 ----
step "4/6 配置本机 TokenTracker"
TT="$(cd ../.. && pwd)/swift/.build/debug/tt-swift"
if [[ ! -x "$TT" ]]; then TT="$(command -v tt-swift || true)"; fi
if [[ ! -x "$TT" ]]; then
  echo "  ✗ 没找到 tt-swift。先在仓库根目录跑：swift build --package-path swift" >&2
  exit 1
fi
"$TT" publish --config "handle=$HANDLE" "endpoint=https://$DOMAIN" enabled=true

# ------------------------------------------------------------ 5. token ----
step "5/6 注册 handle：$HANDLE"
q() {
  wr d1 execute "$DB_NAME" --remote --json --command "$1" 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin)[0]['results'][0].popitem()[1])
except Exception: print('')"
}
EXISTS="$(q "SELECT COUNT(*) AS n FROM handles WHERE handle='$HANDLE'")"
HAS_LOCAL_TOKEN=no
if "$TT" publish --dry-run >/dev/null 2>&1; then
  # 本地能读到 token 吗？用一次不发请求的探测
  if security find-generic-password -a "$HANDLE" -s "$KC_SERVICE" >/dev/null 2>&1      || [[ -s "$HOME/.tokentracker/publish_token" ]]      || [[ -n "${TOKENTRACKER_PUBLISH_TOKEN:-}" ]]; then
    HAS_LOCAL_TOKEN=yes
  fi
fi

if [[ "$EXISTS" == "0" || "$HAS_LOCAL_TOKEN" == "no" ]]; then
  if [[ "$EXISTS" != "0" ]]; then
    echo "  handle 已存在但本机没有对应 token，重新签发…"
  fi
  # token 全程不进 argv、不进 stdout：只经管道交给 tt-swift 写入钥匙串。
  TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
  TOKEN_HASH="$(printf '%s' "$TOKEN" | shasum -a 256 | cut -d' ' -f1)"
  if [[ "$EXISTS" == "0" ]]; then
    wr d1 execute "$DB_NAME" --remote --command \
      "INSERT INTO handles (handle, token_hash, created_at) VALUES ('$HANDLE','$TOKEN_HASH',$(date +%s)000)" >/dev/null
  else
    wr d1 execute "$DB_NAME" --remote --command \
      "UPDATE handles SET token_hash='$TOKEN_HASH' WHERE handle='$HANDLE'" >/dev/null
  fi
  printf '%s\n' "$TOKEN" | "$TT" publish --set-token
  unset TOKEN TOKEN_HASH
  echo "    明文没有打印到任何地方；要换新的重跑本脚本即可。"
else
  echo "  ✓ handle 与本机 token 都已就绪，跳过"
fi

# ------------------------------------------------------------ 6. 验证 ----
step "6/6 验证"
echo -n "  健康检查: "; curl -sS "https://$DOMAIN/healthz" || true; echo
if [[ -x "$TT" ]]; then
  "$TT" publish --force
  echo -n "  读回: "; curl -sS "https://$DOMAIN/v1/stats/$HANDLE" | head -c 160; echo " …"
fi

printf '\n\033[1m完成。\033[0m 公开地址：https://%s/v1/stats/%s\n' "$DOMAIN" "$HANDLE"
