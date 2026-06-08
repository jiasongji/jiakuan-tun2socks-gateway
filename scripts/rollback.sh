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


SERVICE_NAME="jiakuan-tun2socks-gateway.service"

echo "开始回滚本方案创建的容器、网络与 systemd 服务。"
systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$SERVICE_NAME"
systemctl daemon-reload >/dev/null 2>&1 || true

docker rm -f \
  "$ENTRY_NAIVE_HTTPS_NAME" \
  "$ENTRY_NAIVE_HTTP_NAME" \
  "$ENTRY_ANYTLS_NAME" \
  "$NAIVE_NAME" \
  "$ANYTLS_NAME" \
  "$TUN2SOCKS_NAME" >/dev/null 2>&1 || true

docker network rm "$ENTRY_NET" >/dev/null 2>&1 || true

echo "回滚完成：未删除证书、宝塔站点、项目目录和无关 Docker 容器。"
