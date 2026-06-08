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


mask_sensitive() {
  sed -E \
    -e 's#(socks5://)[^/@[:space:]]+@#\1***:***@#g' \
    -e 's#(PASSWORD=)[^[:space:]]+#\1***#g' \
    -e 's#(PASS=)[^[:space:]]+#\1***#g' \
    -e 's#(NAIVE_PASS=)[^[:space:]]+#\1***#g' \
    -e 's#(ANYTLS_PASS=)[^[:space:]]+#\1***#g' \
    -e 's#(SOCKS_PASS=)[^[:space:]]+#\1***#g'
}

check_host_net() {
  if command -v curl >/dev/null 2>&1; then
    curl -4fsS --connect-timeout 8 --max-time 15 https://api.ipify.org >/dev/null 2>&1 && return 0
  fi
  timeout 6 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1
}

section() { printf '\n== %s ==\n' "$*"; }

section "容器状态"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "(${TUN2SOCKS_NAME}|${ANYTLS_NAME}|${NAIVE_NAME}|${ENTRY_ANYTLS_NAME}|${ENTRY_NAIVE_HTTP_NAME}|${ENTRY_NAIVE_HTTPS_NAME})" || true

section "Docker 端口发布"
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E "(${ENTRY_ANYTLS_NAME}|${ENTRY_NAIVE_HTTP_NAME}|${ENTRY_NAIVE_HTTPS_NAME})" || true

echo
if docker ps --format '{{.Names}} {{.Ports}}' | grep -E "^(${ANYTLS_NAME}|${NAIVE_NAME}) " | grep -q '0\.0\.0\.0:'; then
  echo "警告：检测到业务容器直接发布端口，请检查配置。"
else
  echo "业务容器未直接发布宿主机端口：符合 socat 入口边界设计。"
fi

section "宿主机联网检测"
if check_host_net; then
  echo "宿主机联网正常。"
else
  echo "宿主机联网检测失败。"
fi

section "tun2socks 容器路由检查"
echo "默认目的地址路由（应走 tun）："
docker exec "$TUN2SOCKS_NAME" ip route get 1.1.1.1 2>/dev/null || true
echo "Docker 入口网关路由（应走 eth0）："
docker exec "$TUN2SOCKS_NAME" ip route get "$ENTRY_GATEWAY" 2>/dev/null || true
if [ -n "${SOCKS_ROUTE_IP:-}" ]; then
  echo "SOCKS5 服务器路由（应走 eth0）："
  docker exec "$TUN2SOCKS_NAME" ip route get "$SOCKS_ROUTE_IP" 2>/dev/null || true
else
  echo "未记录 SOCKS_ROUTE_IP，跳过 SOCKS5 直连路由检查。"
fi

echo "完整 IPv4 路由表："
docker exec "$TUN2SOCKS_NAME" ip -4 route 2>/dev/null || true

section "业务网络命名空间出口 IP"
if docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || docker pull "$CURL_IMAGE" >/dev/null 2>&1; then
  docker run --rm --network "container:$TUN2SOCKS_NAME" "$CURL_IMAGE" -4fsS --connect-timeout 15 --max-time 30 https://api.ipify.org || true
  echo
else
  echo "无法拉取验证用 curl 镜像，跳过出口 IP 检测。"
fi

section "socat 入口端口监听检查"
if command -v ss >/dev/null 2>&1; then
  ss -ltnp 2>/dev/null | grep -E ":(${ANYTLS_PORT}|${NAIVE_HTTP_PORT}|${NAIVE_HTTPS_PORT})\b" || true
else
  echo "系统未安装 ss，改用 docker port："
  docker port "$ENTRY_ANYTLS_NAME" || true
  docker port "$ENTRY_NAIVE_HTTP_NAME" || true
  docker port "$ENTRY_NAIVE_HTTPS_NAME" || true
fi

section "日志检查（敏感字段已尽量遮蔽）"
for name in "$TUN2SOCKS_NAME" "$ANYTLS_NAME" "$NAIVE_NAME" "$ENTRY_ANYTLS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_NAIVE_HTTPS_NAME"; do
  echo "---- $name ----"
  docker logs --tail=100 "$name" 2>&1 | mask_sensitive || true
done
