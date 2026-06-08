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
  echo "[信息] 确保 Docker 入口网络可出站：${ENTRY_SUBNET}，经 ${bridge_if} 做本项目专属 NAT/FORWARD 规则。"
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

ensure_project_docker_egress_rules

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
