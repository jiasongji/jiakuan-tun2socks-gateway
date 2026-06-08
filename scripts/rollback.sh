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

get_entry_bridge_if() {
  local net_id bridge_name
  bridge_name="$(docker network inspect -f '{{ index .Options "com.docker.network.bridge.name" }}' "$ENTRY_NET" 2>/dev/null || true)"
  if [ -z "$bridge_name" ] || [ "$bridge_name" = "<no value>" ]; then
    net_id="$(docker network inspect -f '{{.Id}}' "$ENTRY_NET" 2>/dev/null || true)"
    [ -n "$net_id" ] || return 1
    bridge_name="br-${net_id:0:12}"
  fi
  printf '%s\n' "$bridge_name"
}

ensure_project_docker_egress_rules() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "[提醒] 未找到 iptables，无法补齐 Docker 自定义网络出站 NAT 规则。"
    return 0
  fi
  if ! docker network inspect "$ENTRY_NET" >/dev/null 2>&1; then
    echo "[提醒] Docker 网络 $ENTRY_NET 不存在，跳过出站 NAT 规则检查。"
    return 0
  fi
  local bridge_if
  bridge_if="$(get_entry_bridge_if || true)"
  if [ -z "$bridge_if" ] || ! ip link show "$bridge_if" >/dev/null 2>&1; then
    echo "[提醒] 未找到 $ENTRY_NET 对应 bridge 接口（推断值：${bridge_if:-空}），跳过出站 NAT 规则检查。"
    return 0
  fi
  echo "[信息] 确保 Docker 入口网络可出站：$ENTRY_SUBNET，经 $bridge_if 做本项目专属 NAT/FORWARD 规则。"
  iptables -t nat -C POSTROUTING -s "$ENTRY_SUBNET" ! -o "$bridge_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$ENTRY_SUBNET" ! -o "$bridge_if" -j MASQUERADE
  iptables -C FORWARD -o "$bridge_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -o "$bridge_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -C FORWARD -i "$bridge_if" ! -o "$bridge_if" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$bridge_if" ! -o "$bridge_if" -j ACCEPT
  iptables -C FORWARD -i "$bridge_if" -o "$bridge_if" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$bridge_if" -o "$bridge_if" -j ACCEPT
  iptables -t nat -C DOCKER -i "$bridge_if" -j RETURN 2>/dev/null || \
    iptables -t nat -I DOCKER 1 -i "$bridge_if" -j RETURN 2>/dev/null || true
}

remove_project_docker_egress_rules() {
  command -v iptables >/dev/null 2>&1 || return 0
  docker network inspect "$ENTRY_NET" >/dev/null 2>&1 || return 0
  local bridge_if
  bridge_if="$(get_entry_bridge_if || true)"
  [ -n "$bridge_if" ] || return 0
  while iptables -t nat -D POSTROUTING -s "$ENTRY_SUBNET" ! -o "$bridge_if" -j MASQUERADE 2>/dev/null; do :; done
  while iptables -D FORWARD -o "$bridge_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$bridge_if" ! -o "$bridge_if" -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -i "$bridge_if" -o "$bridge_if" -j ACCEPT 2>/dev/null; do :; done
  while iptables -t nat -D DOCKER -i "$bridge_if" -j RETURN 2>/dev/null; do :; done
}


SERVICE_NAME="jiakuan-tun2socks-gateway.service"

echo "开始回滚本方案创建的容器、网络与 systemd 服务。"
systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$SERVICE_NAME"
systemctl daemon-reload >/dev/null 2>&1 || true

remove_project_docker_egress_rules

docker rm -f \
  "$ENTRY_NAIVE_HTTPS_NAME" \
  "$ENTRY_NAIVE_HTTP_NAME" \
  "$ENTRY_ANYTLS_NAME" \
  "$NAIVE_NAME" \
  "$ANYTLS_NAME" \
  "$TUN2SOCKS_NAME" >/dev/null 2>&1 || true

docker network rm "$ENTRY_NET" >/dev/null 2>&1 || true

echo "回滚完成：未删除证书、宝塔站点、项目目录和无关 Docker 容器。"
