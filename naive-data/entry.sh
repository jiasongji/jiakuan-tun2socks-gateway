#!/usr/bin/env bash
set -Eeuo pipefail

# NaiveProxy/Caddy 启动入口。认证信息通过 Docker 环境变量注入，Caddyfile 本身不保存明文密码。
required_vars=(DOMAIN NAIVE_HTTP_PORT NAIVE_HTTPS_PORT NAIVE_USER NAIVE_PASS FAKE_HOST)
for v in "${required_vars[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "缺少环境变量：$v" >&2
    exit 1
  fi
done

if [ ! -f /data/Caddyfile ]; then
  echo "缺少 /data/Caddyfile" >&2
  exit 1
fi

if [ -x /app/caddy ]; then
  CADDY_BIN=/app/caddy
else
  CADDY_BIN=caddy
fi

echo "检查并格式化 Caddyfile"
"$CADDY_BIN" fmt --overwrite /data/Caddyfile

echo "启动 NaiveProxy/Caddy"
exec "$CADDY_BIN" run --config /data/Caddyfile --adapter caddyfile
