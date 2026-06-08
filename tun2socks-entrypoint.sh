#!/bin/sh
set -eu

# tun2socks 容器入口：只修改本容器网络命名空间，不修改宿主机路由。
# 业务容器通过 --network container:<tun2socks容器名> 共享本命名空间。

log() { printf '[tun2socks入口] %s\n' "$*"; }
warn() { printf '[tun2socks入口][提醒] %s\n' "$*" >&2; }

: "${PROXY:?缺少 PROXY，例如 socks5://用户:密码@家宽IP:端口 或 socks5://家宽IP:端口}"
TUN="${TUN:-tun0}"
ADDR="${ADDR:-198.18.0.1/15}"
TUN_GATEWAY="${TUN_GATEWAY:-198.18.0.1}"
MTU="${MTU:-1500}"
LOGLEVEL="${LOGLEVEL:-info}"
FWMARK="${FWMARK:-0x22b}"
ETH_DEV="${ETH_DEV:-eth0}"
ENTRY_SUBNET="${ENTRY_SUBNET:-}"
TUN2SOCKS_IP="${TUN2SOCKS_IP:-}"
SOCKS_ROUTE_IP="${SOCKS_ROUTE_IP:-}"
EXTRA_TUN_ARGS="${EXTRA_TUN_ARGS:-}"

if [ "${DISABLE_IPV6:-1}" = "1" ]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
  if [ -d /proc/sys/net/ipv6/conf/"$ETH_DEV" ]; then
    sysctl -w "net.ipv6.conf.${ETH_DEV}.disable_ipv6=1" >/dev/null 2>&1 || true
  fi
fi

# 入口流量从 socat 容器进 eth0，关闭 rp_filter 可减少跨接口回包被丢弃的概率。
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${ETH_DEV}.rp_filter=0" >/dev/null 2>&1 || true

ETH_GW="$(ip -4 route show default 0.0.0.0/0 2>/dev/null | awk 'NR==1 {print $3}')"
if [ -z "$ETH_GW" ]; then
  warn "未检测到 $ETH_DEV 默认网关，仍会尝试启动；请检查 Docker bridge 网络。"
fi

log "创建 TUN 设备：$TUN，地址：$ADDR"
ip link del "$TUN" >/dev/null 2>&1 || true
ip tuntap add mode tun dev "$TUN"
ip addr add "$ADDR" dev "$TUN"
ip link set dev "$TUN" mtu "$MTU" up

# 明确保留 Docker 入口网段走 eth0，保证回包返回 socat 入口容器，不被送入家宽 SOCKS5。
if [ -n "$ENTRY_SUBNET" ]; then
  if [ -n "$TUN2SOCKS_IP" ]; then
    ip route replace "$ENTRY_SUBNET" dev "$ETH_DEV" src "$TUN2SOCKS_IP" || ip route replace "$ENTRY_SUBNET" dev "$ETH_DEV"
  else
    ip route replace "$ENTRY_SUBNET" dev "$ETH_DEV"
  fi
  log "已保留入口 Docker 子网直连：$ENTRY_SUBNET -> $ETH_DEV"
fi

# 明确保留 SOCKS5 服务器 IP 走 eth0，避免连接上游 SOCKS5 自身被送入 TUN 后形成路由环。
if [ -n "$SOCKS_ROUTE_IP" ] && [ -n "$ETH_GW" ]; then
  ip route replace "${SOCKS_ROUTE_IP}/32" via "$ETH_GW" dev "$ETH_DEV" || true
  log "已保留 SOCKS5 服务器直连：${SOCKS_ROUTE_IP}/32 -> $ETH_DEV via $ETH_GW"
fi

# 将本网络命名空间默认路由改到 TUN。宿主机路由不会被修改。
ip route del default >/dev/null 2>&1 || true
if ! ip route add default via "$TUN_GATEWAY" dev "$TUN" metric 1 2>/dev/null; then
  ip route add default dev "$TUN" metric 1
fi
if [ -n "$ETH_GW" ]; then
  ip route add default via "$ETH_GW" dev "$ETH_DEV" metric 200 >/dev/null 2>&1 || true
fi

log "当前路由表："
ip route || true
log "启动 tun2socks，日志级别：$LOGLEVEL"
# shellcheck disable=SC2086
exec tun2socks --device "$TUN" --proxy "$PROXY" --interface "$ETH_DEV" --loglevel "$LOGLEVEL" --fwmark "$FWMARK" $EXTRA_TUN_ARGS
