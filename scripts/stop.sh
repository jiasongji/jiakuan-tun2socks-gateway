#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/jiakuan.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "缺少配置文件：$ENV_FILE" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a


echo "停止入口容器、业务容器、tun2socks 网关。"
docker stop "$ENTRY_ANYTLS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_NAIVE_HTTPS_NAME" >/dev/null 2>&1 || true
docker stop "$NAIVE_NAME" "$ANYTLS_NAME" >/dev/null 2>&1 || true
docker stop "$TUN2SOCKS_NAME" >/dev/null 2>&1 || true
echo "已停止本方案容器。"
