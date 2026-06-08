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


wait_container_running() {
  local name="$1" limit="${2:-45}" i state
  for ((i=1; i<=limit; i++)); do
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    if [ "$state" = "running" ]; then
      return 0
    fi
    sleep 2
  done
  echo "容器未按时进入 running：$name" >&2
  docker logs --tail=120 "$name" 2>/dev/null || true
  return 1
}

echo "按顺序启动 tun2socks 网关、业务容器、入口容器。"
docker start "$TUN2SOCKS_NAME" >/dev/null 2>&1 || true
wait_container_running "$TUN2SOCKS_NAME" 60

docker start "$ANYTLS_NAME" "$NAIVE_NAME" >/dev/null 2>&1 || true
wait_container_running "$ANYTLS_NAME" 45
wait_container_running "$NAIVE_NAME" 45

docker start "$ENTRY_ANYTLS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_NAIVE_HTTPS_NAME" >/dev/null 2>&1 || true
wait_container_running "$ENTRY_ANYTLS_NAME" 30
wait_container_running "$ENTRY_NAIVE_HTTP_NAME" 30
wait_container_running "$ENTRY_NAIVE_HTTPS_NAME" 30

echo "已完成启动。"
