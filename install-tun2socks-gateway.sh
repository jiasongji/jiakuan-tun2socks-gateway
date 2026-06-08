#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'
	'

# Debian 12 + 宝塔面板 + Docker：tun2socks + socat 家宽 SOCKS5 出口网关交互式部署脚本。
# 默认不安装 Docker、不重启 Docker、不修改宿主机默认路由、不迁移 Docker 全局 data-root。

VERSION="2026-06-08.4"
DEFAULT_PROJECT_ROOT="${JIAKUAN_PROJECT_ROOT:-}"
DEFAULT_DOMAIN="${JIAKUAN_DOMAIN:-}"
DEFAULT_CERT_FILE=""
DEFAULT_CERT_KEY_FILE=""

DEFAULT_TUN2SOCKS_NAME="JiaKuan-Tun2Socks"
DEFAULT_ANYTLS_NAME="AnyTLS_JiaKuan"
DEFAULT_NAIVE_NAME="NaiveProxy_JiaKuan"
DEFAULT_ENTRY_ANYTLS_NAME="JiaKuan-Entry-AnyTLS"
DEFAULT_ENTRY_NAIVE_HTTP_NAME="JiaKuan-Entry-NaiveHTTP"
DEFAULT_ENTRY_NAIVE_HTTPS_NAME="JiaKuan-Entry-NaiveHTTPS"

DEFAULT_ENTRY_NET="jiakuan_entry_net"
DEFAULT_ENTRY_SUBNET="172.31.253.0/24"
DEFAULT_ENTRY_GATEWAY="172.31.253.1"
DEFAULT_TUN2SOCKS_IP="172.31.253.10"
DEFAULT_TUN_NAME="tun0"
DEFAULT_TUN_ADDR="198.18.0.1/15"
DEFAULT_TUN_GATEWAY="198.18.0.1"

DEFAULT_SOCKS_HOST=""
DEFAULT_SOCKS_PORT="1080"

DEFAULT_ANYTLS_PORT="${JIAKUAN_ANYTLS_PORT:-}"
DEFAULT_NAIVE_HTTP_PORT="${JIAKUAN_NAIVE_HTTP_PORT:-}"
DEFAULT_NAIVE_HTTPS_PORT="${JIAKUAN_NAIVE_HTTPS_PORT:-}"
DEFAULT_FAKE_HOST="https://soft.xiaoz.org"

DEFAULT_TUN2SOCKS_IMAGE="jiasongji/jiakuan-tun2socks:latest"
DEFAULT_ANYTLS_IMAGE="jiasongji/jiakuan-anytls:latest"
DEFAULT_NAIVE_IMAGE="jiasongji/jiakuan-naiveproxy:latest"
DEFAULT_SOCAT_IMAGE="jiasongji/jiakuan-socat:latest"
DEFAULT_CURL_IMAGE="jiasongji/jiakuan-curl:8.10.1"
DEFAULT_GITHUB_REPO_URL="https://github.com/jiasongji/jiakuan-tun2socks-gateway"

HOST_NET_OK_BEFORE="no"
IPTABLES_BACKUP_FILE=""

log() { printf '[1;32m[信息][0m %s
' "$*"; }
warn() { printf '[1;33m[提醒][0m %s
' "$*"; }
err() { printf '[1;31m[错误][0m %s
' "$*" >&2; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 执行：sudo -i 后再运行本脚本。"
    exit 1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }
}

gen_user() {
  printf 'u_%s
' "$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
}

gen_pass() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  echo
}

gen_high_port() {
  # 生成 20000-60999 范围内的高位端口，避免常见系统端口与多数面板端口。
  local n
  n="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
  if [ -z "$n" ]; then
    n="$RANDOM"
  fi
  echo $((20000 + n % 41000))
}

port_is_listening() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"
  else
    return 1
  fi
}

gen_unique_high_port() {
  local p used i
  for i in {1..80}; do
    p="$(gen_high_port)"
    used=" ${ANYTLS_PORT:-} ${NAIVE_HTTP_PORT:-} ${NAIVE_HTTPS_PORT:-} "
    if [[ "$used" != *" $p "* ]] && ! port_is_listening "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  # 极端情况下退回到最后一次生成值，后续端口占用检查仍会拦截。
  printf '%s\n' "$p"
}

prompt_default() {
  local var_name="$1" label="$2" default_value="$3" input=""
  if [ -n "$default_value" ]; then
    read -r -p "$label [$default_value]: " input
  else
    read -r -p "$label: " input
  fi
  if [ -z "$input" ]; then
    printf -v "$var_name" '%s' "$default_value"
  else
    printf -v "$var_name" '%s' "$input"
  fi
}

prompt_port_auto() {
  local var_name="$1" label="$2" default_value="$3" input="" port=""
  if [ -n "$default_value" ]; then
    read -r -p "${label} [${default_value}；输入 auto 自动生成高位端口]: " input
    input="${input:-$default_value}"
  else
    read -r -p "$label [回车自动生成高位端口]: " input
  fi
  if [ -z "$input" ] || [ "$input" = "auto" ] || [ "$input" = "AUTO" ]; then
    port="$(gen_unique_high_port)"
    printf -v "$var_name" '%s' "$port"
    log "已自动生成 ${label}：${port}"
  else
    printf -v "$var_name" '%s' "$input"
  fi
}

prompt_secret_optional() {
  local var_name="$1" label="$2" input=""
  read -r -s -p "${label}（无则直接回车）: " input
  echo
  printf -v "$var_name" '%s' "$input"
}

infer_project_root() {
  if [ -n "${JIAKUAN_PROJECT_ROOT:-}" ]; then
    printf '%s\n' "${JIAKUAN_PROJECT_ROOT%/}"
    return 0
  fi
  local script_dir pwd_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  pwd_dir="$(pwd -P 2>/dev/null || pwd)"
  for candidate in "$pwd_dir" "$script_dir"; do
    if [ "$(basename "$candidate")" = "jiakuan-proxy" ]; then
      printf '%s\n' "$(dirname "$candidate")"
      return 0
    fi
  done
  return 1
}

infer_domain_from_root() {
  local root="${1:-}" base=""
  [ -n "$root" ] || return 1
  base="$(basename "$root")"
  case "$base" in
    *.*) printf '%s\n' "$base"; return 0 ;;
  esac
  return 1
}

prompt_secret_auto() {
  local var_name="$1" label="$2" input=""
  read -r -s -p "$label [回车自动生成]: " input
  echo
  if [ -z "$input" ]; then
    input="$(gen_pass)"
  fi
  printf -v "$var_name" '%s' "$input"
}

prompt_user_auto() {
  local var_name="$1" label="$2" input=""
  read -r -p "$label [回车自动生成]: " input
  if [ -z "$input" ]; then
    input="$(gen_user)"
  fi
  printf -v "$var_name" '%s' "$input"
}

ask_yes_no() {
  local var_name="$1" label="$2" default_value="$3" input="" hint=""
  case "$default_value" in
    y|Y) hint="Y/n" ;;
    n|N) hint="y/N" ;;
    *) hint="y/n" ;;
  esac
  while true; do
    read -r -p "$label [$hint]: " input
    input="${input:-$default_value}"
    case "$input" in
      y|Y|yes|YES|Yes) printf -v "$var_name" '%s' "yes"; return 0 ;;
      n|N|no|NO|No) printf -v "$var_name" '%s' "no"; return 0 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

validate_port() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    err "$name 不是合法端口：$value"
    exit 1
  fi
}

validate_public_port() {
  local name="$1" value="$2"
  validate_port "$name" "$value"
  if [ "$value" -lt 1024 ]; then
    warn "${name} 当前为低位端口 ${value}；root 可以绑定，但请确认没有与系统服务冲突。"
  fi
}

validate_no_space() {
  local name="$1" value="$2"
  if [[ "$value" =~ [[:space:]] ]]; then
    err "$name 不能包含空白字符。"
    exit 1
  fi
}

validate_inputs() {
  [ -n "$DOMAIN" ] || { err "域名不能为空。"; exit 1; }
  [ -n "$SOCKS_HOST" ] || { err "SOCKS5 IP/域名不能为空。"; exit 1; }
  validate_port "SOCKS5 端口" "$SOCKS_PORT"
  validate_public_port "AnyTLS 端口" "$ANYTLS_PORT"
  validate_public_port "NaiveProxy HTTP 端口" "$NAIVE_HTTP_PORT"
  validate_public_port "NaiveProxy HTTPS 端口" "$NAIVE_HTTPS_PORT"
  if [ "$ANYTLS_PORT" = "$NAIVE_HTTP_PORT" ] || [ "$ANYTLS_PORT" = "$NAIVE_HTTPS_PORT" ] || [ "$NAIVE_HTTP_PORT" = "$NAIVE_HTTPS_PORT" ]; then
    err "AnyTLS、NaiveProxy HTTP、NaiveProxy HTTPS 三个公网端口不能重复。"
    exit 1
  fi
  if { [ -n "$SOCKS_USER" ] && [ -z "$SOCKS_PASS" ]; } || { [ -z "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; }; then
    err "SOCKS5 用户名和密码必须同时填写；两者都留空表示无认证。"
    exit 1
  fi
  validate_no_space "NaiveProxy 用户名" "$NAIVE_USER"
  validate_no_space "NaiveProxy 密码" "$NAIVE_PASS"
  validate_no_space "AnyTLS 密码" "$ANYTLS_PASS"
  if [ ! -f "$CERT_FILE" ]; then
    err "证书 fullchain 文件不存在：$CERT_FILE"
    exit 1
  fi
  if [ ! -f "$CERT_KEY_FILE" ]; then
    err "证书私钥文件不存在：$CERT_KEY_FILE"
    exit 1
  fi
}

check_host_net() {
  local ok=0
  if command -v curl >/dev/null 2>&1; then
    curl -4fsS --connect-timeout 8 --max-time 15 https://api.ipify.org >/dev/null 2>&1 && ok=1 || true
  fi
  if [ "$ok" -ne 1 ]; then
    timeout 6 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && ok=1 || true
  fi
  [ "$ok" -eq 1 ]
}

rawurlencode() {
  local s="$1" out="" i c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

resolve_socks_ip() {
  if [[ "$SOCKS_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SOCKS_ROUTE_IP="$SOCKS_HOST"
    return 0
  fi
  if command -v getent >/dev/null 2>&1; then
    SOCKS_ROUTE_IP="$(getent ahostsv4 "$SOCKS_HOST" | awk '{print $1; exit}')"
  fi
  if [ -z "${SOCKS_ROUTE_IP:-}" ] && command -v dig >/dev/null 2>&1; then
    SOCKS_ROUTE_IP="$(dig +short A "$SOCKS_HOST" | awk 'NR==1 {print}')"
  fi
  if [ -z "${SOCKS_ROUTE_IP:-}" ]; then
    err "无法解析 SOCKS5 域名：${SOCKS_HOST}。请改填 IPv4 地址，或先修复宿主机 DNS。"
    exit 1
  fi
}

build_socks_proxy_url() {
  local u p
  if [ -n "$SOCKS_USER" ]; then
    u="$(rawurlencode "$SOCKS_USER")"
    p="$(rawurlencode "$SOCKS_PASS")"
    TUN2SOCKS_PROXY_URL="socks5://${u}:${p}@${SOCKS_ROUTE_IP}:${SOCKS_PORT}"
  else
    TUN2SOCKS_PROXY_URL="socks5://${SOCKS_ROUTE_IP}:${SOCKS_PORT}"
  fi
}

sanitize_text() {
  local text="$1"
  if [ -n "${SOCKS_PASS:-}" ]; then
    text="${text//$SOCKS_PASS/***}"
  fi
  if [ -n "${NAIVE_PASS:-}" ]; then
    text="${text//$NAIVE_PASS/***}"
  fi
  if [ -n "${ANYTLS_PASS:-}" ]; then
    text="${text//$ANYTLS_PASS/***}"
  fi
  printf '%s' "$text"
}

host_socks_curl_test() {
  local args
  args=(-4fsS --connect-timeout 12 --max-time 30)
  if [ -n "${SOCKS_USER:-}" ]; then
    args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS:-}")
  fi
  args+=(--socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://api.ipify.org)
  curl "${args[@]}"
}

docker_socks_curl_test() {
  local network="${1:-}" docker_args curl_args
  docker_args=(run --rm)
  if [ -n "$network" ]; then
    docker_args+=(--network "$network")
  fi
  curl_args=(-4fsS --connect-timeout 15 --max-time 30)
  if [ -n "${SOCKS_USER:-}" ]; then
    curl_args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS:-}")
  fi
  curl_args+=(--socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://api.ipify.org)
  docker "${docker_args[@]}" "$CURL_IMAGE" "${curl_args[@]}"
}

preflight_upstream_socks_host() {
  log "预检测上游 SOCKS5：${SOCKS_ROUTE_IP}:${SOCKS_PORT}"
  if [ -n "${SOCKS_USER:-}" ] && [ -z "${SOCKS_PASS:-}" ]; then
    warn "已填写 SOCKS5 用户名但密码为空；如果上游 SOCKS5 要求账号密码认证，这通常会导致认证失败。"
  fi

  if ! timeout 8 bash -c "</dev/tcp/${SOCKS_ROUTE_IP}/${SOCKS_PORT}" >/dev/null 2>&1; then
    err "上游 SOCKS5 TCP 端口不可达或拒绝连接：${SOCKS_ROUTE_IP}:${SOCKS_PORT}"
    err "请先确认家宽 SOCKS5 服务端正在监听该端口、VPS 源 IP 已放行、防火墙/安全组未拦截。脚本不会继续替换现有部署。"
    exit 1
  fi

  local out
  if command -v curl >/dev/null 2>&1; then
    if out="$(host_socks_curl_test 2>&1)"; then
      log "上游 SOCKS5 显式出口检测通过，出口 IP：$out"
    else
      out="$(sanitize_text "$out")"
      err "上游 SOCKS5 显式出口检测失败，脚本不会继续替换现有部署。"
      err "常见原因：SOCKS5 账号密码错误、服务端白名单未放行、本端填错端口、上游服务端仅支持内网访问。"
      err "curl 错误：$out"
      exit 1
    fi
  else
    warn "宿主机未安装 curl，只完成 TCP 端口连通性检查；后续会用 Docker curl 镜像继续验证。"
  fi
}

preflight_upstream_socks_entry_network() {
  log "预检测 Docker 入口网络通过上游 SOCKS5 出口。"
  local out
  if docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || docker pull "$CURL_IMAGE" >/dev/null 2>&1; then
    if out="$(docker_socks_curl_test "$ENTRY_NET" 2>&1)"; then
      log "Docker 入口网络显式 SOCKS5 出口检测通过，出口 IP：$out"
    else
      out="$(sanitize_text "$out")"
      err "Docker 入口网络无法通过上游 SOCKS5 出口，脚本不会继续启动业务容器。"
      err "请检查 Docker 自定义网络出站、上游 SOCKS5 认证、服务端白名单和防火墙。"
      err "curl 错误：$out"
      exit 1
    fi
  else
    err "无法拉取验证用 curl 镜像：$CURL_IMAGE。脚本不会跳过关键出口验证。"
    exit 1
  fi
}

backup_iptables() {
  mkdir -p "$PROJECT_DIR/backups"
  if command -v iptables-save >/dev/null 2>&1; then
    IPTABLES_BACKUP_FILE="$PROJECT_DIR/backups/iptables-before-$(date +%Y%m%d-%H%M%S).rules"
    iptables-save >"$IPTABLES_BACKUP_FILE"
    chmod 600 "$IPTABLES_BACKUP_FILE" || true
    log "已备份 iptables：$IPTABLES_BACKUP_FILE"
  else
    warn "未找到 iptables-save，无法创建 iptables 备份。"
  fi
}

restore_iptables_if_needed() {
  if [ -n "${IPTABLES_BACKUP_FILE:-}" ] && [ -f "$IPTABLES_BACKUP_FILE" ] && command -v iptables-restore >/dev/null 2>&1; then
    warn "正在恢复 iptables 备份：$IPTABLES_BACKUP_FILE"
    iptables-restore <"$IPTABLES_BACKUP_FILE" || true
  fi
}

cleanup_old_iptables_rules() {
  [ "$CLEAN_OLD_IPTABLES" = "yes" ] || return 0
  if ! command -v iptables >/dev/null 2>&1; then
    warn "未找到 iptables，跳过旧规则清理。"
    return 0
  fi
  log "只清理旧 RedSocks 方案可能残留的 jiakuan 专属 iptables 规则。"
  while iptables -w -t nat -D PREROUTING -s 172.31.251.0/24 -p tcp -m conntrack --ctstate NEW -j JIAKUAN_REDSOCKS 2>/dev/null; do :; done
  while iptables -w -t nat -D PREROUTING -s 172.31.251.0/24 -p udp --dport 53 -j REDIRECT --to-ports 33809 2>/dev/null; do :; done
  while iptables -w -D DOCKER-USER -s 172.31.251.0/24 ! -p tcp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; do :; done
  iptables -w -t nat -F JIAKUAN_REDSOCKS 2>/dev/null || true
  iptables -w -t nat -X JIAKUAN_REDSOCKS 2>/dev/null || true
  docker network rm jiakuan_net >/dev/null 2>&1 || true
}

collect_inputs() {
  echo
  log "开始交互式配置。直接回车使用方括号内默认值。"
  log "AnyTLS/NaiveProxy 本地账号密码直接回车会自动生成；上游 SOCKS5 账号密码留空表示无认证。"
  echo

  local inferred_root="" inferred_domain="" project_root_default=""
  inferred_root="$(infer_project_root 2>/dev/null || true)"
  inferred_domain="$(infer_domain_from_root "$inferred_root" 2>/dev/null || true)"

  prompt_default DOMAIN "域名" "${DEFAULT_DOMAIN:-$inferred_domain}"
  if [ -z "$DOMAIN" ]; then
    err "域名不能为空。请填写实际绑定证书的域名，例如 example.com。"
    exit 1
  fi

  project_root_default="${DEFAULT_PROJECT_ROOT:-}"
  if [ -z "$project_root_default" ] && [ -n "$inferred_root" ] && [ "$(basename "$inferred_root")" = "$DOMAIN" ]; then
    project_root_default="$inferred_root"
  fi
  if [ -z "$project_root_default" ]; then
    project_root_default="/www/wwwroot/$DOMAIN"
  fi
  prompt_default PROJECT_ROOT "项目根目录" "$project_root_default"
  PROJECT_ROOT="${PROJECT_ROOT%/}"
  PROJECT_DIR="$PROJECT_ROOT/jiakuan-proxy"

  prompt_default CERT_FILE "证书 fullchain 路径" "${DEFAULT_CERT_FILE:-/www/server/panel/vhost/cert/$DOMAIN/fullchain.pem}"
  prompt_default CERT_KEY_FILE "证书 privkey 路径" "${DEFAULT_CERT_KEY_FILE:-/www/server/panel/vhost/cert/$DOMAIN/privkey.pem}"

  echo
  prompt_default TUN2SOCKS_NAME "tun2socks 容器名" "$DEFAULT_TUN2SOCKS_NAME"
  prompt_default ANYTLS_NAME "AnyTLS 容器名" "$DEFAULT_ANYTLS_NAME"
  prompt_default NAIVE_NAME "NaiveProxy 容器名" "$DEFAULT_NAIVE_NAME"
  prompt_default ENTRY_ANYTLS_NAME "AnyTLS 入口 socat 容器名" "$DEFAULT_ENTRY_ANYTLS_NAME"
  prompt_default ENTRY_NAIVE_HTTP_NAME "NaiveProxy HTTP 入口 socat 容器名" "$DEFAULT_ENTRY_NAIVE_HTTP_NAME"
  prompt_default ENTRY_NAIVE_HTTPS_NAME "NaiveProxy HTTPS 入口 socat 容器名" "$DEFAULT_ENTRY_NAIVE_HTTPS_NAME"

  echo
  prompt_default ENTRY_NET "Docker 入口网络名" "$DEFAULT_ENTRY_NET"
  prompt_default ENTRY_SUBNET "Docker 入口网络子网" "$DEFAULT_ENTRY_SUBNET"
  prompt_default ENTRY_GATEWAY "Docker 入口网络网关" "$DEFAULT_ENTRY_GATEWAY"
  prompt_default TUN2SOCKS_IP "tun2socks 固定 IP" "$DEFAULT_TUN2SOCKS_IP"
  prompt_default TUN_NAME "TUN 设备名" "$DEFAULT_TUN_NAME"
  prompt_default TUN_ADDR "TUN 地址" "$DEFAULT_TUN_ADDR"
  prompt_default TUN_GATEWAY "TUN 默认路由网关" "$DEFAULT_TUN_GATEWAY"

  echo
  log "--- 家宽 SOCKS5（已有上游服务；留空账号密码表示无认证，不会自动生成） ---"
  prompt_default SOCKS_HOST "家宽 SOCKS5 IP/域名" "$DEFAULT_SOCKS_HOST"
  prompt_default SOCKS_PORT "家宽 SOCKS5 端口" "$DEFAULT_SOCKS_PORT"
  prompt_default SOCKS_USER "家宽 SOCKS5 用户名，若无认证直接回车" ""
  prompt_secret_optional SOCKS_PASS "家宽 SOCKS5 密码"

  echo
  log "--- AnyTLS / NaiveProxy 本地服务 ---"
  prompt_port_auto ANYTLS_PORT "AnyTLS 端口" "$DEFAULT_ANYTLS_PORT"
  prompt_secret_auto ANYTLS_PASS "AnyTLS 密码"
  prompt_port_auto NAIVE_HTTP_PORT "NaiveProxy HTTP/伪装端口" "$DEFAULT_NAIVE_HTTP_PORT"
  prompt_port_auto NAIVE_HTTPS_PORT "NaiveProxy HTTPS 端口" "$DEFAULT_NAIVE_HTTPS_PORT"
  prompt_user_auto NAIVE_USER "NaiveProxy 用户名"
  prompt_secret_auto NAIVE_PASS "NaiveProxy 密码"
  prompt_default FAKE_HOST "NaiveProxy 反代/伪装地址" "$DEFAULT_FAKE_HOST"

  echo
  prompt_default TUN2SOCKS_IMAGE "tun2socks 镜像" "$DEFAULT_TUN2SOCKS_IMAGE"
  prompt_default ANYTLS_IMAGE "AnyTLS 镜像" "$DEFAULT_ANYTLS_IMAGE"
  prompt_default NAIVE_IMAGE "NaiveProxy 镜像" "$DEFAULT_NAIVE_IMAGE"
  prompt_default SOCAT_IMAGE "socat 镜像" "$DEFAULT_SOCAT_IMAGE"
  prompt_default CURL_IMAGE "验证用 curl 镜像" "$DEFAULT_CURL_IMAGE"

  echo
  ask_yes_no CLEAN_OLD_REDSOCKS "是否清理旧的 JiaKuan-RedSocks 方案容器和旧启动守护" "y"
  ask_yes_no CLEAN_OLD_IPTABLES "是否清理旧的 jiakuan iptables 残留规则" "y"
  ask_yes_no INSTALL_SYSTEMD "是否安装 systemd 启动守护" "y"
  ask_yes_no MIGRATE_DOCKER_ROOT "是否迁移 Docker 全局 data-root 到 $PROJECT_ROOT/docker-data（高风险，默认否）" "n"

  echo
  prompt_default GITHUB_REPO_URL "GitHub 仓库地址（用于文档记录）" "$DEFAULT_GITHUB_REPO_URL"
  ask_yes_no GITHUB_AUTO_SYNC "是否尝试在服务器上用 gh 创建/更新该仓库（不提交 jiakuan.env）" "n"

  validate_inputs
}

ensure_project_dirs() {
  mkdir -p "$PROJECT_DIR/naive-data" "$PROJECT_DIR/scripts" "$PROJECT_DIR/logs" "$PROJECT_DIR/backups" "$PROJECT_DIR/systemd"
  chmod 700 "$PROJECT_DIR"
}

write_env_file() {
  local env_file="$PROJECT_DIR/jiakuan.env"
  {
    for var in PROJECT_ROOT PROJECT_DIR DOMAIN CERT_FILE CERT_KEY_FILE       TUN2SOCKS_NAME ANYTLS_NAME NAIVE_NAME ENTRY_ANYTLS_NAME ENTRY_NAIVE_HTTP_NAME ENTRY_NAIVE_HTTPS_NAME       ENTRY_NET ENTRY_SUBNET ENTRY_GATEWAY TUN2SOCKS_IP TUN_NAME TUN_ADDR TUN_GATEWAY       SOCKS_HOST SOCKS_PORT SOCKS_USER SOCKS_PASS SOCKS_ROUTE_IP       ANYTLS_PORT ANYTLS_PASS NAIVE_HTTP_PORT NAIVE_HTTPS_PORT NAIVE_USER NAIVE_PASS FAKE_HOST       TUN2SOCKS_IMAGE ANYTLS_IMAGE NAIVE_IMAGE SOCAT_IMAGE CURL_IMAGE GITHUB_REPO_URL; do
      printf '%s=%q
' "$var" "${!var}"
    done
  } >"$env_file"
  chmod 600 "$env_file"
  log "已写入敏感配置：${env_file}（权限 600，已被 .gitignore 排除）"
}

write_static_files() {
  log "写入项目模板文件：$PROJECT_DIR"
  cat >"$PROJECT_DIR/.gitignore" <<'GITIGNORE_EOF'
# 敏感配置
jiakuan.env
.env
*.env

# 证书、私钥、令牌
*.key
*.pem
*.p12
*.pfx
*.crt
*.csr
*token*
*secret*

# 运行产物
logs/
backups/
docker-data/
*.rules
*.log
*.pid
install-summary*.txt

# 系统文件
.DS_Store
Thumbs.db
GITIGNORE_EOF

  cat >"$PROJECT_DIR/jiakuan.env.example" <<'ENV_EXAMPLE_EOF'
# jiakuan.env 示例：复制为 jiakuan.env 后按实际值填写。
# 真实 jiakuan.env 由 install-tun2socks-gateway.sh 交互生成，权限应为 600，不得提交到 GitHub。
PROJECT_ROOT=/www/wwwroot/example.com
PROJECT_DIR=/www/wwwroot/example.com/jiakuan-proxy
DOMAIN=example.com
CERT_FILE=/www/server/panel/vhost/cert/example.com/fullchain.pem
CERT_KEY_FILE=/www/server/panel/vhost/cert/example.com/privkey.pem

TUN2SOCKS_NAME=JiaKuan-Tun2Socks
ANYTLS_NAME=AnyTLS_JiaKuan
NAIVE_NAME=NaiveProxy_JiaKuan
ENTRY_ANYTLS_NAME=JiaKuan-Entry-AnyTLS
ENTRY_NAIVE_HTTP_NAME=JiaKuan-Entry-NaiveHTTP
ENTRY_NAIVE_HTTPS_NAME=JiaKuan-Entry-NaiveHTTPS

ENTRY_NET=jiakuan_entry_net
ENTRY_SUBNET=172.31.253.0/24
ENTRY_GATEWAY=172.31.253.1
TUN2SOCKS_IP=172.31.253.10
TUN_NAME=tun0
TUN_ADDR=198.18.0.1/15
TUN_GATEWAY=198.18.0.1

SOCKS_HOST=home-socks.example.com
SOCKS_PORT=1080
SOCKS_USER=
SOCKS_PASS=
SOCKS_ROUTE_IP=203.0.113.10

ANYTLS_PORT=21366
ANYTLS_PASS=请替换为强随机密码
NAIVE_HTTP_PORT=21367
NAIVE_HTTPS_PORT=21368
NAIVE_USER=请替换为用户名
NAIVE_PASS=请替换为强随机密码
FAKE_HOST=https://soft.xiaoz.org

TUN2SOCKS_IMAGE=jiasongji/jiakuan-tun2socks:latest
ANYTLS_IMAGE=jiasongji/jiakuan-anytls:latest
NAIVE_IMAGE=jiasongji/jiakuan-naiveproxy:latest
SOCAT_IMAGE=jiasongji/jiakuan-socat:latest
CURL_IMAGE=jiasongji/jiakuan-curl:8.10.1

GITHUB_REPO_URL=https://github.com/jiasongji/jiakuan-tun2socks-gateway
ENV_EXAMPLE_EOF

  cat >"$PROJECT_DIR/tun2socks-entrypoint.sh" <<'TUN_ENTRY_EOF'
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

log "创建 TUN 设备：${TUN}，地址：${ADDR}"
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
exec tun2socks -device "$TUN" -proxy "$PROXY" -interface "$ETH_DEV" -loglevel "$LOGLEVEL" -fwmark "$FWMARK" $EXTRA_TUN_ARGS
TUN_ENTRY_EOF

  chmod +x "$PROJECT_DIR/tun2socks-entrypoint.sh"
  cat >"$PROJECT_DIR/naive-data/Caddyfile" <<'CADDYFILE_EOF'
{
    http_port {$NAIVE_HTTP_PORT}
    https_port {$NAIVE_HTTPS_PORT}
    auto_https off
    order forward_proxy before reverse_proxy
}

:{$NAIVE_HTTP_PORT} {
    reverse_proxy {$FAKE_HOST} {
        header_up Host {upstream_hostport}
    }
}

:{$NAIVE_HTTPS_PORT}, {$DOMAIN} {
    tls /cert/fullchain.pem /cert/privkey.pem
    route {
        forward_proxy {
            basic_auth {$NAIVE_USER} {$NAIVE_PASS}
            hide_ip
            hide_via
            probe_resistance
        }
        reverse_proxy {$FAKE_HOST} {
            header_up Host {upstream_hostport}
        }
    }
}
CADDYFILE_EOF

  chmod 644 "$PROJECT_DIR/naive-data/Caddyfile"
  cat >"$PROJECT_DIR/naive-data/entry.sh" <<'NAIVE_ENTRY_EOF'
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
NAIVE_ENTRY_EOF

  chmod +x "$PROJECT_DIR/naive-data/entry.sh"
  cat >"$PROJECT_DIR/scripts/start.sh" <<'START_SH_EOF'
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
START_SH_EOF

  chmod +x "$PROJECT_DIR/scripts/start.sh"
  cat >"$PROJECT_DIR/scripts/stop.sh" <<'STOP_SH_EOF'
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
STOP_SH_EOF

  chmod +x "$PROJECT_DIR/scripts/stop.sh"
  cat >"$PROJECT_DIR/scripts/restart.sh" <<'RESTART_SH_EOF'
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


if systemctl list-unit-files jiakuan-tun2socks-gateway.service >/dev/null 2>&1; then
  systemctl restart jiakuan-tun2socks-gateway.service
else
  bash "$PROJECT_DIR/scripts/stop.sh"
  bash "$PROJECT_DIR/scripts/start.sh"
fi
RESTART_SH_EOF

  chmod +x "$PROJECT_DIR/scripts/restart.sh"
  cat >"$PROJECT_DIR/scripts/verify.sh" <<'VERIFY_SH_EOF'
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

VERIFY_FAILED=0

mask_sensitive() {
  sed -E \
    -e 's#(socks5://)[^/@[:space:]]+@#\1***:***@#g' \
    -e 's#(PASSWORD=)[^[:space:]]+#\1***#g' \
    -e 's#(PASS=)[^[:space:]]+#\1***#g' \
    -e 's#(NAIVE_PASS=)[^[:space:]]+#\1***#g' \
    -e 's#(ANYTLS_PASS=)[^[:space:]]+#\1***#g' \
    -e 's#(SOCKS_PASS=)[^[:space:]]+#\1***#g'
}

mark_fail() {
  VERIFY_FAILED=1
  echo "[失败] $*" >&2
}

check_host_net() {
  if command -v curl >/dev/null 2>&1; then
    curl -4fsS --connect-timeout 8 --max-time 15 https://api.ipify.org >/dev/null 2>&1 && return 0
  fi
  timeout 6 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1
}

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

docker_socks_curl() {
  local network="${1:-}" docker_args curl_args
  docker_args=(run --rm)
  if [ -n "$network" ]; then
    docker_args+=(--network "$network")
  fi
  curl_args=(-4fsS --connect-timeout 15 --max-time 30)
  if [ -n "${SOCKS_USER:-}" ]; then
    curl_args+=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS:-}")
  fi
  curl_args+=(--socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" https://api.ipify.org)
  docker "${docker_args[@]}" "$CURL_IMAGE" "${curl_args[@]}"
}

section() { printf '\n== %s ==\n' "$*"; }

section "容器状态"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "(${TUN2SOCKS_NAME}|${ANYTLS_NAME}|${NAIVE_NAME}|${ENTRY_ANYTLS_NAME}|${ENTRY_NAIVE_HTTP_NAME}|${ENTRY_NAIVE_HTTPS_NAME})" || true
for name in "$TUN2SOCKS_NAME" "$ANYTLS_NAME" "$NAIVE_NAME" "$ENTRY_ANYTLS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_NAIVE_HTTPS_NAME"; do
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if [ "$state" != "running" ]; then
    mark_fail "容器未运行：$name（当前状态：${state:-不存在}）"
  fi
done

section "Docker 端口发布"
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E "(${ENTRY_ANYTLS_NAME}|${ENTRY_NAIVE_HTTP_NAME}|${ENTRY_NAIVE_HTTPS_NAME})" || true

echo
if docker ps --format '{{.Names}} {{.Ports}}' | grep -E "^(${ANYTLS_NAME}|${NAIVE_NAME}) " | grep -q '0\.0\.0\.0:'; then
  mark_fail "检测到业务容器直接发布宿主机端口，请检查配置。"
else
  echo "业务容器未直接发布宿主机端口：符合 socat 入口边界设计。"
fi

section "宿主机联网检测"
if check_host_net; then
  echo "宿主机联网正常。"
else
  mark_fail "宿主机联网检测失败。"
fi

section "tun2socks 容器路由检查"
echo "默认目的地址路由（应走 tun）："
default_route="$(docker exec "$TUN2SOCKS_NAME" ip route get 1.1.1.1 2>/dev/null || true)"
printf '%s\n' "$default_route"
if ! printf '%s\n' "$default_route" | grep -q " dev ${TUN_NAME} "; then
  mark_fail "默认目的地址未走 ${TUN_NAME}。"
fi

echo "Docker 入口网关路由（应走 eth0）："
entry_route="$(docker exec "$TUN2SOCKS_NAME" ip route get "$ENTRY_GATEWAY" 2>/dev/null || true)"
printf '%s\n' "$entry_route"
if ! printf '%s\n' "$entry_route" | grep -q " dev eth0 "; then
  mark_fail "Docker 入口网关路由未走 eth0。"
fi

if [ -n "${SOCKS_ROUTE_IP:-}" ]; then
  echo "SOCKS5 服务器路由（应走 eth0）："
  socks_route="$(docker exec "$TUN2SOCKS_NAME" ip route get "$SOCKS_ROUTE_IP" 2>/dev/null || true)"
  printf '%s\n' "$socks_route"
  if ! printf '%s\n' "$socks_route" | grep -q " dev eth0 "; then
    mark_fail "SOCKS5 服务器路由未走 eth0，可能形成路由环。"
  fi
else
  mark_fail "未记录 SOCKS_ROUTE_IP，无法检查 SOCKS5 直连路由。"
fi

echo "完整 IPv4 路由表："
docker exec "$TUN2SOCKS_NAME" ip -4 route 2>/dev/null || true

section "Docker 入口网络出站 NAT 检查"
if command -v iptables >/dev/null 2>&1 && docker network inspect "$ENTRY_NET" >/dev/null 2>&1; then
  bridge_if="$(get_entry_bridge_if || true)"
  echo "入口网络：${ENTRY_NET}，子网：${ENTRY_SUBNET}，bridge：${bridge_if:-未识别}"
  if [ -n "${bridge_if:-}" ] && iptables -t nat -C POSTROUTING -s "$ENTRY_SUBNET" ! -o "$bridge_if" -j MASQUERADE 2>/dev/null; then
    echo "NAT 规则存在：$ENTRY_SUBNET -> MASQUERADE"
  else
    mark_fail "未检测到本项目 Docker 入口网络 NAT 规则，容器可能无法连接上游 SOCKS5。"
  fi
else
  mark_fail "iptables 或 Docker 入口网络不可用，无法检查 NAT 规则。"
fi

section "入口 Docker 网络显式 SOCKS5 出口 IP"
if docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || docker pull "$CURL_IMAGE" >/dev/null 2>&1; then
  if out="$(docker_socks_curl "$ENTRY_NET" 2>&1)"; then
    printf '显式 SOCKS5 出口 IP：%s\n' "$out"
  else
    printf '%s\n' "$out" | mask_sensitive
    mark_fail "入口 Docker 网络无法通过上游 SOCKS5 出口。请检查 SOCKS5 端口、认证、服务端白名单和防火墙。"
  fi
else
  mark_fail "无法拉取验证用 curl 镜像，无法执行入口网络 SOCKS5 出口测试。"
fi

section "业务网络命名空间出口 IP"
if docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || docker pull "$CURL_IMAGE" >/dev/null 2>&1; then
  if out="$(docker run --rm --network "container:$TUN2SOCKS_NAME" "$CURL_IMAGE" -4fsS --connect-timeout 15 --max-time 30 https://api.ipify.org 2>&1)"; then
    printf '业务命名空间出口 IP：%s\n' "$out"
  else
    printf '%s\n' "$out" | mask_sensitive
    mark_fail "业务网络命名空间出口 IP 检测失败，业务容器实际出站不可用。"
  fi
else
  mark_fail "无法拉取验证用 curl 镜像，无法执行业务出口 IP 检测。"
fi

section "socat 入口端口监听检查"
if command -v ss >/dev/null 2>&1; then
  ss_output="$(ss -ltnp 2>/dev/null | grep -E ":(${ANYTLS_PORT}|${NAIVE_HTTP_PORT}|${NAIVE_HTTPS_PORT})\b" || true)"
  printf '%s\n' "$ss_output"
  for p in "$ANYTLS_PORT" "$NAIVE_HTTP_PORT" "$NAIVE_HTTPS_PORT"; do
    if ! printf '%s\n' "$ss_output" | grep -Eq ":${p}\b"; then
      mark_fail "宿主机未监听入口端口：$p。"
    fi
  done
else
  echo "系统未安装 ss，改用 docker port："
  docker port "$ENTRY_ANYTLS_NAME" || true
  docker port "$ENTRY_NAIVE_HTTP_NAME" || true
  docker port "$ENTRY_NAIVE_HTTPS_NAME" || true
fi

section "NaiveProxy 认证提示"
if docker logs --tail=200 "$NAIVE_NAME" 2>&1 | grep -Fq '"Proxy-Authorization":[]'; then
  echo "提醒：NaiveProxy 日志出现空 Proxy-Authorization；如果客户端无法使用，请优先核对 NaiveProxy 客户端用户名和密码。"
fi

section "日志检查（敏感字段已尽量遮蔽）"
for name in "$TUN2SOCKS_NAME" "$ANYTLS_NAME" "$NAIVE_NAME" "$ENTRY_ANYTLS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_NAIVE_HTTPS_NAME"; do
  echo "---- $name ----"
  docker logs --tail=100 "$name" 2>&1 | mask_sensitive || true
done

section "验证结论"
if [ "$VERIFY_FAILED" -eq 0 ]; then
  echo "验证通过。"
else
  echo "验证失败：上方 [失败] 项需要处理。"
fi
exit "$VERIFY_FAILED"
VERIFY_SH_EOF

  chmod +x "$PROJECT_DIR/scripts/verify.sh"
  cat >"$PROJECT_DIR/scripts/rollback.sh" <<'ROLLBACK_SH_EOF'
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
ROLLBACK_SH_EOF

  chmod +x "$PROJECT_DIR/scripts/rollback.sh"
  cat >"$PROJECT_DIR/systemd/jiakuan-tun2socks-gateway.service.example" <<SYSTEMD_EOF
[Unit]
Description=家宽 SOCKS5 出口网关（tun2socks + socat + AnyTLS + NaiveProxy）
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/scripts/start.sh
ExecStop=$PROJECT_DIR/scripts/stop.sh
TimeoutStartSec=180
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

  cat >"$PROJECT_DIR/README.md" <<'README_EOF'
# 家宽 SOCKS5 出口网关：tun2socks + socat + Docker

适用环境：Debian 12 + 宝塔面板 + 已安装 Docker。

目标是在 VPS 上部署 AnyTLS 与 NaiveProxy，但让业务容器访问目标网站时，经由另一台家宽服务器提供的 SOCKS5 出口。

## 架构

```text
公网客户端
  ↓
宿主机 Docker 端口映射（只发布 socat 入口容器端口）
  ↓
socat 入口容器
  ↓
JiaKuan-Tun2Socks 网络命名空间中的 AnyTLS / NaiveProxy
  ↓
tun2socks 默认路由
  ↓
家宽 SOCKS5
  ↓
目标网站
```

关键原则：

- AnyTLS 与 NaiveProxy 不直接发布宿主机端口。
- 只有三个 socat 入口容器发布宿主机端口。
- AnyTLS 与 NaiveProxy 使用 `--network container:JiaKuan-Tun2Socks` 共享 tun2socks 网络命名空间。
- tun2socks 容器内保留 Docker 入口子网走 `eth0`，回包仍返回 socat，避免非对称路由。
- tun2socks 容器内保留 SOCKS5 服务器 IP 走 `eth0`，避免连接上游 SOCKS5 自身进入 TUN 形成路由环。
- 脚本会补齐本项目 Docker 入口网络的专属 NAT/FORWARD 规则，保证自定义 bridge 容器能连接上游 SOCKS5；这些规则只匹配 `ENTRY_SUBNET` 与本项目 bridge，回滚时会删除。

## 默认端口

公网端口不再限制在固定范围；直接回车会自动生成不重复的高位端口。下表仅为示例：

| 用途 | 宿主机端口 | 入口容器 | 后端目标 |
| --- | ---: | --- | --- |
| AnyTLS | 自动生成，例如 21366 | JiaKuan-Entry-AnyTLS | 172.31.253.10:同宿主机端口 |
| NaiveProxy HTTP/伪装 | 自动生成，例如 21367 | JiaKuan-Entry-NaiveHTTP | 172.31.253.10:同宿主机端口 |
| NaiveProxy HTTPS | 自动生成，例如 21368 | JiaKuan-Entry-NaiveHTTPS | 172.31.253.10:同宿主机端口 |


## Docker 镜像策略

本项目默认使用自己 Docker Hub 账号下的项目专用镜像，避免目标服务器直接依赖第三方命名空间：

| 用途 | 默认镜像 | 说明 |
| --- | --- | --- |
| tun2socks 网关 | `jiasongji/jiakuan-tun2socks:latest` | 基于官方 tun2socks 镜像封装本项目入口脚本 |
| AnyTLS | `jiasongji/jiakuan-anytls:latest` | 基于自己账号下已有 AnyTLS 镜像封装 |
| NaiveProxy | `jiasongji/jiakuan-naiveproxy:latest` | 基于自己账号下已有 NaiveProxy 镜像封装 |
| socat 入口 | `jiasongji/jiakuan-socat:latest` | 基于 socat 镜像封装 |
| 验证 curl | `jiasongji/jiakuan-curl:8.10.1` | 验证出口 IP 使用 |

也可以使用仓库内的 GitHub Actions 工作流“发布 Docker 镜像”在云端构建推送。工作流需要仓库 Secrets：`DOCKERHUB_USERNAME` 与 `DOCKERHUB_TOKEN`，不会把明文凭据写入代码。

如需重新构建并推送这些镜像，在本机 Docker 已登录后执行：

```bash
cd /Users/mac/Desktop/Srv/Proxy-VPS/VP-SJC/jiakuan-tun2socks-gateway
BUILD_PLATFORMS=linux/amd64 DOCKER_NAMESPACE=jiasongji bash scripts/docker-build-push.sh
```

目标服务器通常是 Debian 12 amd64 VPS，因此默认平台是 `linux/amd64`。如果要同时发布 ARM64，可改为：

```bash
BUILD_PLATFORMS=linux/amd64,linux/arm64 DOCKER_NAMESPACE=jiasongji bash scripts/docker-build-push.sh
```

## 一键部署

> 目标服务器需要已安装 Docker；脚本不会默认安装 Docker、不会默认重启 Docker、不会默认修改宿主机默认路由、不会默认迁移 Docker 全局数据目录。

```bash
INSTALLER_DIR=/tmp/jiakuan-tun2socks-gateway-installer
rm -rf "$INSTALLER_DIR"
git clone https://github.com/jiasongji/jiakuan-tun2socks-gateway.git "$INSTALLER_DIR"
bash "$INSTALLER_DIR/bootstrap-install.sh"
```

也可以用环境变量预填域名或项目根目录，仍会进入交互确认：

```bash
JIAKUAN_DOMAIN=example.com JIAKUAN_PROJECT_ROOT=/www/wwwroot/example.com bash /tmp/jiakuan-tun2socks-gateway-installer/bootstrap-install.sh
```

公网端口也可用环境变量预填；不预填时在交互中直接回车会自动生成高位端口：

```bash
JIAKUAN_ANYTLS_PORT=21366 JIAKUAN_NAIVE_HTTP_PORT=21367 JIAKUAN_NAIVE_HTTPS_PORT=21368 \
  bash /tmp/jiakuan-tun2socks-gateway-installer/bootstrap-install.sh
```

## 交互项说明

脚本会询问：

- 域名：无固定默认值；如果当前目录是 `<域名>/jiakuan-proxy`，会自动推断。
- 项目根目录：默认 `/www/wwwroot/<域名>`；也可输入任意绝对路径，例如 `/data/sites/example.com`。
- 证书 fullchain 路径与 privkey 路径
- 家宽 SOCKS5 IP/域名、端口、用户名、密码
- AnyTLS 端口与密码；端口留空自动生成高位端口
- NaiveProxy HTTP/HTTPS 端口、用户名、密码、伪装地址；端口留空自动生成高位端口
- Docker 网络名、子网、tun2socks 固定 IP
- 是否清理旧 RedSocks 方案容器
- 是否清理旧 jiakuan iptables 残留规则
- 是否安装 systemd 启动守护
- 是否迁移 Docker 全局 data-root（默认否，选择后仍需二次输入 `MIGRATE`）
- GitHub 仓库地址，以及是否尝试在服务器上用 `gh` 同步模板文件

随机生成规则：

- AnyTLS 密码直接回车会自动生成强随机密码。
- NaiveProxy 用户名直接回车会自动生成用户名。
- NaiveProxy 密码直接回车会自动生成强随机密码。
- 家宽 SOCKS5 用户名/密码直接回车表示该上游 SOCKS5 无认证，不会自动生成远端无法生效的凭据。

真实敏感配置写入 `jiakuan.env`，权限为 `600`，并被 `.gitignore` 排除。

## 常用命令

```bash
# 验证容器、端口、路由、出口 IP 和日志
bash <项目根目录>/jiakuan-proxy/scripts/verify.sh

# 按正确顺序重启
systemctl restart jiakuan-tun2socks-gateway.service
# 或
bash <项目根目录>/jiakuan-proxy/scripts/restart.sh

# 停止本组容器
bash <项目根目录>/jiakuan-proxy/scripts/stop.sh

# 回滚本方案创建的容器、网络和 systemd 服务
bash <项目根目录>/jiakuan-proxy/scripts/rollback.sh
```

## 验证重点

脚本部署后会自动执行 `scripts/verify.sh`。人工复查时重点看：

1. 业务容器没有直接发布宿主机端口。
2. `JiaKuan-Tun2Socks` 中访问普通公网地址的路由走 `tun0`。
3. Docker 入口子网与 SOCKS5 服务器 IP 的路由走 `eth0`。
4. 本项目 Docker 入口网络存在专属 MASQUERADE/FORWARD 规则，临时容器能显式通过上游 SOCKS5 出口。
5. 以下命令输出应为家宽 SOCKS5 的出口 IP：

```bash
docker run --rm --network container:JiaKuan-Tun2Socks jiasongji/jiakuan-curl:8.10.1 -4fsS https://api.ipify.org
```

从 `2026-06-08.4` 版本开始，上游 SOCKS5 与业务出口属于关键验证项：

- 安装前会先检测上游 SOCKS5 TCP 端口与显式 SOCKS5 出口；失败时不会替换现有同名部署。
- 创建 Docker 入口网络后，会再检测入口网络能否显式通过 SOCKS5 出口；失败时不会启动业务容器。
- 部署后的 `scripts/verify.sh` 会对关键项返回非零退出码；自动验证失败时安装脚本会回滚本次新部署。

## 常见故障判断

- `connect: connection refused`：上游 SOCKS5 的 IP/端口没有监听、端口填错、服务端防火墙拒绝或源 IP 未放行；这不是 tun2socks 参数问题。
- `SOCKS5 authentication failed` 或显式 SOCKS5 出口检测失败：优先核对上游 SOCKS5 用户名/密码。上游 SOCKS5 用户名/密码留空表示无认证，不会自动生成。
- NaiveProxy 日志出现空 `Proxy-Authorization`：通常是客户端没有带 NaiveProxy 认证或用户名/密码不匹配；请使用部署完成摘要里显示的 NaiveProxy 用户名和密码。
- 宿主机端口正常监听但业务出口 IP 检测失败：优先看 `JiaKuan-Tun2Socks` 日志中的上游 SOCKS5 连接错误。

## DNS 与 UDP 说明

本方案优先保证 AnyTLS / NaiveProxy 的 TCP 出站经由家宽 SOCKS5。tun2socks 可以处理 TCP/UDP 包，但 DNS 与 UDP 是否可用取决于上游 SOCKS5 是否支持 UDP 转发，以及业务程序的解析方式。若上游 SOCKS5 不支持 UDP，可能出现域名解析失败或 UDP 流量不可用；此时应另行设计可信 DNS 方案，例如上游侧解析、DoH/DoT 或支持 UDP 的代理链路。

## 安全与回滚

- 脚本部署前后都会检测宿主机联网。
- 如果部署前联网正常、部署后联网异常，脚本会删除本次创建的容器和网络，并恢复可用的 iptables 备份。
- 清理旧 iptables 时只处理本项目旧规则名或旧网段，不会清空全部 iptables。
- 回滚不会删除证书、宝塔站点、无关 Docker 容器。

## tun2socks 参数验证来源

安装脚本会在目标服务器上执行：

```bash
docker run --rm --entrypoint tun2socks jiasongji/jiakuan-tun2socks:latest --help
```

并检查 `-device`、`-proxy`、`-interface`、`-loglevel`、`-fwmark` 等参数是否存在，然后才继续部署。官方 Wiki 的 Linux 示例使用 `-device`、`-proxy`、`-interface`；官方源码 `main.go` 也定义了这些参数。
README_EOF

  cat >"$PROJECT_DIR/tutorial.html" <<'TUTORIAL_EOF'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>家宽 SOCKS5 出口网关部署教程</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.75; margin: 0; color: #172033; background: #f6f8fb; }
    main { max-width: 980px; margin: 0 auto; padding: 32px 18px 64px; }
    section { background: #fff; border: 1px solid #e6eaf2; border-radius: 14px; padding: 22px; margin: 18px 0; box-shadow: 0 8px 28px rgba(20, 30, 55, .06); }
    h1, h2 { line-height: 1.25; }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    pre { background: #0f172a; color: #e2e8f0; padding: 16px; border-radius: 12px; overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; }
    th, td { border-bottom: 1px solid #e6eaf2; padding: 10px; text-align: left; }
    .warn { background: #fff7ed; border-color: #fed7aa; }
    .ok { background: #ecfdf5; border-color: #bbf7d0; }
  </style>
</head>
<body>
<main>
  <h1>家宽 SOCKS5 出口网关部署教程</h1>
  <section>
    <h2>方案目标</h2>
    <p>公网客户端连接 VPS 的本地端口；AnyTLS 与 NaiveProxy 访问外部网站时，实际出口走另一台家宽服务器提供的 SOCKS5。</p>
    <pre>公网客户端 → socat 入口容器 → tun2socks 网络命名空间 → 家宽 SOCKS5 → 目标网站</pre>
  </section>
  <section>
    <h2>为什么能避免非对称路由</h2>
    <p>公网入口只进入 socat 容器，socat 再连接 Docker bridge 内固定 IP。tun2socks 容器内为 Docker 入口子网保留 eth0 直连路由，所以业务容器给 socat 的回包仍走 eth0 返回，不会被默认 TUN 路由送往 SOCKS5。脚本还会补齐本项目 Docker 入口网络的专属 NAT/FORWARD 规则，确保自定义 bridge 容器可以连接上游 SOCKS5。</p>
  </section>
  <section>
    <h2>一键执行</h2>
    <pre>INSTALLER_DIR=/tmp/jiakuan-tun2socks-gateway-installer
rm -rf "$INSTALLER_DIR"
git clone https://github.com/jiasongji/jiakuan-tun2socks-gateway.git "$INSTALLER_DIR"
bash "$INSTALLER_DIR/bootstrap-install.sh"</pre>
    <p>脚本会先询问域名，再默认给出 <code>/www/wwwroot/&lt;域名&gt;</code> 作为项目根目录；也可以输入任意绝对路径。</p>
  </section>
  <section>
    <h2>默认端口</h2>
    <p>公网端口不再限制固定范围。交互时直接回车会自动生成不重复的高位端口，也可以手动输入任意未占用的合法 TCP 端口。</p>
    <table>
      <tr><th>服务</th><th>宿主机端口</th><th>入口容器</th><th>后端目标</th></tr>
      <tr><td>AnyTLS</td><td>自动生成，例如 21366</td><td>JiaKuan-Entry-AnyTLS</td><td>172.31.253.10:同宿主机端口</td></tr>
      <tr><td>NaiveProxy HTTP</td><td>自动生成，例如 21367</td><td>JiaKuan-Entry-NaiveHTTP</td><td>172.31.253.10:同宿主机端口</td></tr>
      <tr><td>NaiveProxy HTTPS</td><td>自动生成，例如 21368</td><td>JiaKuan-Entry-NaiveHTTPS</td><td>172.31.253.10:同宿主机端口</td></tr>
    </table>
  </section>
  <section>
    <h2>验证命令</h2>
    <pre>bash &lt;项目根目录&gt;/jiakuan-proxy/scripts/verify.sh

docker run --rm --network container:JiaKuan-Tun2Socks jiasongji/jiakuan-curl:8.10.1 -4fsS https://api.ipify.org</pre>
    <p>新版脚本会把上游 SOCKS5 显式出口、Docker 入口网络出口、业务命名空间出口都作为关键验证。若失败，安装脚本会回滚本次新部署，不会再伪装成部署成功。</p>
  </section>
  <section>
    <h2>常见故障判断</h2>
    <ul>
      <li><code>connect: connection refused</code>：优先检查上游 SOCKS5 IP/端口是否监听、源 IP 是否放行、防火墙是否拦截。</li>
      <li>显式 SOCKS5 出口检测失败：优先核对上游 SOCKS5 用户名和密码；上游账号密码留空表示无认证。</li>
      <li>NaiveProxy 日志出现空 <code>Proxy-Authorization</code>：通常是客户端没有带 NaiveProxy 认证或用户名密码不匹配。</li>
    </ul>
  </section>
  <section>
    <h2>回滚命令</h2>
    <pre>bash &lt;项目根目录&gt;/jiakuan-proxy/scripts/rollback.sh</pre>
  </section>
  <section class="warn">
    <h2>风险提示</h2>
    <ul>
      <li>脚本不会默认迁移 Docker 全局 data-root；如选择迁移，必须二次输入 <code>MIGRATE</code>。</li>
      <li>真实密码写入 <code>jiakuan.env</code>，权限为 600，不提交到 GitHub。</li>
      <li>若上游 SOCKS5 不支持 UDP，DNS 或 UDP 业务可能不可用；本方案优先保证 TCP 出口。</li>
      <li>脚本会添加仅匹配本项目 Docker 入口子网的 NAT/FORWARD 规则，回滚脚本会删除这些规则。</li>
    </ul>
  </section>
</main>
</body>
</html>
TUTORIAL_EOF

  if [ -r "${BASH_SOURCE[0]}" ] && [ "$(readlink -f "${BASH_SOURCE[0]}")" != "$(readlink -f "$PROJECT_DIR/install-tun2socks-gateway.sh" 2>/dev/null || true)" ]; then
    cp "${BASH_SOURCE[0]}" "$PROJECT_DIR/install-tun2socks-gateway.sh"
    chmod +x "$PROJECT_DIR/install-tun2socks-gateway.sh"
  fi
  if [ -r "$(dirname "${BASH_SOURCE[0]}")/bootstrap-install.sh" ]; then
    cp "$(dirname "${BASH_SOURCE[0]}")/bootstrap-install.sh" "$PROJECT_DIR/bootstrap-install.sh"
    chmod +x "$PROJECT_DIR/bootstrap-install.sh"
  fi
}

verify_tun2socks_image_params() {
  log "拉取并验证 tun2socks 镜像参数：$TUN2SOCKS_IMAGE"
  docker pull "$TUN2SOCKS_IMAGE"
  local help_file="$PROJECT_DIR/backups/tun2socks-help-$(date +%Y%m%d-%H%M%S).txt"
  if ! docker run --rm --entrypoint tun2socks "$TUN2SOCKS_IMAGE" --help >"$help_file" 2>&1; then
    warn "tun2socks --help 返回非零状态，继续检查输出内容。"
  fi
  chmod 600 "$help_file" || true
  # Go flag 帮助通常显示单横线参数，例如 -device；部分命令行也兼容双横线。
  # 因此这里同时兼容 -device 与 --device，避免把有效镜像误判为无效。
  for flag in device proxy interface loglevel fwmark; do
    if ! grep -Eq "(^|[[:space:]])--?${flag}([[:space:]]|$)" "$help_file"; then
      err "当前 ${TUN2SOCKS_IMAGE} 帮助信息未发现参数 -${flag}。已保存帮助输出：${help_file}"
      exit 1
    fi
  done
  log "tun2socks 参数验证通过，帮助输出已保存到 backups 目录。"
}


ensure_tun_device() {
  if [ -e /dev/net/tun ]; then
    return 0
  fi
  warn "未发现 /dev/net/tun，尝试加载 tun 模块并创建设备节点。"
  modprobe tun >/dev/null 2>&1 || true
  mkdir -p /dev/net
  if [ ! -e /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 2>/dev/null || true
  fi
  chmod 666 /dev/net/tun 2>/dev/null || true
  if [ ! -e /dev/net/tun ]; then
    err "无法创建 /dev/net/tun，请先在宿主机启用 TUN 设备。"
    exit 1
  fi
}

pull_other_images() {
  log "拉取业务与入口镜像。"
  docker pull "$ANYTLS_IMAGE"
  docker pull "$NAIVE_IMAGE"
  docker pull "$SOCAT_IMAGE"
  docker pull "$CURL_IMAGE" || warn "验证用 curl 镜像拉取失败，部署可继续，出口 IP 自动验证可能跳过。"
}

migrate_docker_root_if_requested() {
  [ "$MIGRATE_DOCKER_ROOT" = "yes" ] || return 0
  echo
  warn "迁移 Docker 全局 data-root 会停止 Docker，并影响宝塔中所有 Docker 容器。"
  read -r -p "如确认迁移，请输入 MIGRATE：" confirm
  if [ "$confirm" != "MIGRATE" ]; then
    err "未输入 MIGRATE，取消迁移并退出。"
    exit 1
  fi
  require_cmd rsync
  require_cmd python3
  local target="$PROJECT_ROOT/docker-data"
  local current
  current="$(docker info --format '{.DockerRootDir}' 2>/dev/null || true)"
  [ -n "$current" ] || { err "无法读取当前 DockerRootDir。"; exit 1; }
  if [ "$current" = "$target" ]; then
    log "Docker data-root 已是目标目录：$target"
    return 0
  fi
  mkdir -p "$target"
  backup_iptables
  log "停止 Docker 并同步数据：$current -> $target"
  systemctl stop docker
  rsync -aHAX --numeric-ids "$current/" "$target/"
  mkdir -p /etc/docker
  if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  python3 - "$target" <<'PYJSON'
import json, os, sys
path='/etc/docker/daemon.json'
target=sys.argv[1]
data={}
if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as f:
        text=f.read().strip()
        if text:
            data=json.loads(text)
data['data-root']=target
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('
')
PYJSON
  systemctl start docker
  log "Docker data-root 迁移完成。"
}

cleanup_current_project_containers() {
  log "移除同名旧容器（仅限本方案容器名）。"
  docker rm -f "$ENTRY_NAIVE_HTTPS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_ANYTLS_NAME" "$NAIVE_NAME" "$ANYTLS_NAME" "$TUN2SOCKS_NAME" >/dev/null 2>&1 || true
}

cleanup_old_redsocks_if_requested() {
  [ "$CLEAN_OLD_REDSOCKS" = "yes" ] || return 0
  log "清理旧 RedSocks 方案容器与旧启动守护（不触碰名为 naiveproxy 的独立容器）。"
  docker rm -f JiaKuan-RedSocks >/dev/null 2>&1 || true
  systemctl disable --now jiakuan-docker-only.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/jiakuan-docker-only.service
  systemctl daemon-reload >/dev/null 2>&1 || true
}

check_public_ports_available() {
  if ! command -v ss >/dev/null 2>&1; then
    warn "未找到 ss，跳过宿主机端口占用预检查。"
    return 0
  fi
  for p in "$ANYTLS_PORT" "$NAIVE_HTTP_PORT" "$NAIVE_HTTPS_PORT"; do
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then
      err "公网端口 $p 已被占用。请释放端口，或重新运行脚本换成其他空闲端口；直接回车可自动生成高位端口。"
      exit 1
    fi
  done
}

ensure_docker_network() {
  if docker network inspect "$ENTRY_NET" >/dev/null 2>&1; then
    local subnet
    subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$ENTRY_NET" 2>/dev/null || true)"
    if [ "$subnet" != "$ENTRY_SUBNET" ]; then
      err "Docker 网络 ${ENTRY_NET} 已存在但子网为 ${subnet}，不等于期望 ${ENTRY_SUBNET}。请手动检查后重试。"
      exit 1
    fi
    log "Docker 网络已存在：$ENTRY_NET ($ENTRY_SUBNET)"
  else
    log "创建 Docker bridge 网络：$ENTRY_NET ($ENTRY_SUBNET)"
    docker network create --driver bridge --subnet "$ENTRY_SUBNET" --gateway "$ENTRY_GATEWAY" "$ENTRY_NET" >/dev/null
  fi
}


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
    warn "未找到 iptables，无法补齐 Docker 自定义网络出站 NAT 规则。"
    return 0
  fi
  if ! docker network inspect "$ENTRY_NET" >/dev/null 2>&1; then
    warn "Docker 网络 $ENTRY_NET 不存在，跳过出站 NAT 规则检查。"
    return 0
  fi
  local bridge_if
  bridge_if="$(get_entry_bridge_if || true)"
  if [ -z "$bridge_if" ] || ! ip link show "$bridge_if" >/dev/null 2>&1; then
    warn "未找到 $ENTRY_NET 对应 bridge 接口（推断值：${bridge_if:-空}），跳过出站 NAT 规则检查。"
    return 0
  fi
  log "确保 Docker 入口网络可出站：${ENTRY_SUBNET}，经 ${bridge_if} 做本项目专属 NAT/FORWARD 规则。"
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

rollback_new_stack() {
  warn "开始回滚本方案新建容器、网络和 systemd 服务。"
  systemctl disable --now jiakuan-tun2socks-gateway.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/jiakuan-tun2socks-gateway.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  docker rm -f "$ENTRY_NAIVE_HTTPS_NAME" "$ENTRY_NAIVE_HTTP_NAME" "$ENTRY_ANYTLS_NAME" "$NAIVE_NAME" "$ANYTLS_NAME" "$TUN2SOCKS_NAME" >/dev/null 2>&1 || true
  remove_project_docker_egress_rules
  docker network rm "$ENTRY_NET" >/dev/null 2>&1 || true
  restore_iptables_if_needed
}

post_host_net_guard() {
  if [ "$HOST_NET_OK_BEFORE" = "yes" ] && ! check_host_net; then
    err "部署前宿主机联网正常，但当前检测异常，执行自动回滚。"
    rollback_new_stack
    err "已回滚。请检查 Docker/宝塔防火墙/上游网络后再重试。"
    exit 1
  fi
}

wait_container_running() {
  local name="$1" limit="${2:-45}" i state
  for ((i=1; i<=limit; i++)); do
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    if [ "$state" = "running" ]; then
      return 0
    fi
    sleep 2
  done
  docker logs --tail=120 "$name" 2>/dev/null || true
  err "容器未正常运行：$name"
  exit 1
}

run_tun2socks() {
  log "启动 ${TUN2SOCKS_NAME}（不发布宿主机端口）。"
  docker run -d     --name "$TUN2SOCKS_NAME"     --hostname "$TUN2SOCKS_NAME"     --restart unless-stopped     --network "$ENTRY_NET"     --ip "$TUN2SOCKS_IP"     --cap-add NET_ADMIN     --device /dev/net/tun     --sysctl net.ipv6.conf.all.disable_ipv6=1     --sysctl net.ipv6.conf.default.disable_ipv6=1     -e "PROXY=$TUN2SOCKS_PROXY_URL"     -e "TUN=$TUN_NAME"     -e "ADDR=$TUN_ADDR"     -e "TUN_GATEWAY=$TUN_GATEWAY"     -e "ENTRY_SUBNET=$ENTRY_SUBNET"     -e "ENTRY_GATEWAY=$ENTRY_GATEWAY"     -e "TUN2SOCKS_IP=$TUN2SOCKS_IP"     -e "SOCKS_ROUTE_IP=$SOCKS_ROUTE_IP"     -e "LOGLEVEL=info"     -e "DISABLE_IPV6=1"     -v "$PROJECT_DIR/tun2socks-entrypoint.sh:/jiakuan/tun2socks-entrypoint.sh:ro"     --entrypoint /jiakuan/tun2socks-entrypoint.sh     "$TUN2SOCKS_IMAGE" >/dev/null
  wait_container_running "$TUN2SOCKS_NAME" 60
  post_host_net_guard
}

run_business_containers() {
  log "启动 ${ANYTLS_NAME}，共享 ${TUN2SOCKS_NAME} 网络命名空间。"
  docker run -d     --name "$ANYTLS_NAME"     --restart unless-stopped     --network "container:$TUN2SOCKS_NAME"     "$ANYTLS_IMAGE"     /app/anytls-server -l ":$ANYTLS_PORT" -p "$ANYTLS_PASS" >/dev/null

  log "启动 ${NAIVE_NAME}，共享 ${TUN2SOCKS_NAME} 网络命名空间。"
  docker run -d     --name "$NAIVE_NAME"     --restart unless-stopped     --network "container:$TUN2SOCKS_NAME"     -e "DOMAIN=$DOMAIN"     -e "NAIVE_HTTP_PORT=$NAIVE_HTTP_PORT"     -e "NAIVE_HTTPS_PORT=$NAIVE_HTTPS_PORT"     -e "NAIVE_USER=$NAIVE_USER"     -e "NAIVE_PASS=$NAIVE_PASS"     -e "FAKE_HOST=$FAKE_HOST"     -v "$PROJECT_DIR/naive-data:/data"     -v "$CERT_FILE:/cert/fullchain.pem:ro"     -v "$CERT_KEY_FILE:/cert/privkey.pem:ro"     "$NAIVE_IMAGE"     /bin/bash /data/entry.sh >/dev/null

  wait_container_running "$ANYTLS_NAME" 45
  wait_container_running "$NAIVE_NAME" 45
  post_host_net_guard
}

run_entry_containers() {
  log "启动三个 socat 入口容器，并只在这些入口容器发布宿主机端口。"
  docker run -d --name "$ENTRY_ANYTLS_NAME" --restart unless-stopped --network "$ENTRY_NET"     -p "0.0.0.0:$ANYTLS_PORT:$ANYTLS_PORT/tcp"     "$SOCAT_IMAGE"     "TCP-LISTEN:$ANYTLS_PORT,fork,reuseaddr" "TCP:$TUN2SOCKS_IP:$ANYTLS_PORT" >/dev/null

  docker run -d --name "$ENTRY_NAIVE_HTTP_NAME" --restart unless-stopped --network "$ENTRY_NET"     -p "0.0.0.0:$NAIVE_HTTP_PORT:$NAIVE_HTTP_PORT/tcp"     "$SOCAT_IMAGE"     "TCP-LISTEN:$NAIVE_HTTP_PORT,fork,reuseaddr" "TCP:$TUN2SOCKS_IP:$NAIVE_HTTP_PORT" >/dev/null

  docker run -d --name "$ENTRY_NAIVE_HTTPS_NAME" --restart unless-stopped --network "$ENTRY_NET"     -p "0.0.0.0:$NAIVE_HTTPS_PORT:$NAIVE_HTTPS_PORT/tcp"     "$SOCAT_IMAGE"     "TCP-LISTEN:$NAIVE_HTTPS_PORT,fork,reuseaddr" "TCP:$TUN2SOCKS_IP:$NAIVE_HTTPS_PORT" >/dev/null

  wait_container_running "$ENTRY_ANYTLS_NAME" 30
  wait_container_running "$ENTRY_NAIVE_HTTP_NAME" 30
  wait_container_running "$ENTRY_NAIVE_HTTPS_NAME" 30
  post_host_net_guard
}

install_systemd_unit() {
  [ "$INSTALL_SYSTEMD" = "yes" ] || return 0
  log "安装 systemd 启动守护：jiakuan-tun2socks-gateway.service"
  cat >/etc/systemd/system/jiakuan-tun2socks-gateway.service <<SERVICE
[Unit]
Description=家宽 SOCKS5 出口网关（tun2socks + socat + AnyTLS + NaiveProxy）
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/scripts/start.sh
ExecStop=$PROJECT_DIR/scripts/stop.sh
TimeoutStartSec=180
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable jiakuan-tun2socks-gateway.service >/dev/null
}

github_sync_if_requested() {
  [ "$GITHUB_AUTO_SYNC" = "yes" ] || return 0
  if ! command -v gh >/dev/null 2>&1; then
    warn "未安装 gh，无法自动创建或更新 GitHub 仓库。请手动提交模板文件。"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh 未登录，无法自动更新 GitHub。请先执行 gh auth login。"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn "未安装 git，无法自动更新 GitHub。"
    return 0
  fi
  local owner_repo
  owner_repo="$(printf '%s
' "$GITHUB_REPO_URL" | sed -E 's#https://github.com/##; s#\.git$##')"
  if [ -z "$owner_repo" ] || [ "$owner_repo" = "$GITHUB_REPO_URL" ]; then
    warn "GitHub 仓库地址无法解析 owner/repo，跳过自动同步。"
    return 0
  fi
  cd "$PROJECT_DIR"
  if [ ! -d .git ]; then
    git init -b main
  fi
  if ! gh repo view "$owner_repo" >/dev/null 2>&1; then
    gh repo create "$owner_repo" --public --description "家宽 SOCKS5 出口网关：tun2socks + socat + AnyTLS + NaiveProxy" || return 0
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "https://github.com/${owner_repo}.git"
  else
    git remote add origin "https://github.com/${owner_repo}.git"
  fi
  git add bootstrap-install.sh install-tun2socks-gateway.sh README.md .gitignore jiakuan.env.example tun2socks-entrypoint.sh naive-data/Caddyfile naive-data/entry.sh scripts/*.sh systemd/*.service.example tutorial.html
  git rm --cached jiakuan.env >/dev/null 2>&1 || true
  if git diff --cached --quiet; then
    log "GitHub 模板文件无新变化，跳过提交。"
  else
    git commit -m "更新 tun2socks 家宽出口网关部署模板"
    git push -u origin main
  fi
}

run_verify() {
  log "开始自动验证。"
  if ! bash "$PROJECT_DIR/scripts/verify.sh"; then
    err "自动验证失败，开始回滚本次新部署，避免留下不可用服务。"
    rollback_new_stack
    err "已回滚。请根据上方验证失败项修复后重新部署。"
    exit 1
  fi
}

final_summary() {
  cat <<EOF

==================== 部署完成摘要 ====================
项目目录：$PROJECT_DIR
GitHub 仓库：$GITHUB_REPO_URL

宿主机发布端口（仅 socat 入口容器发布）：
- AnyTLS：0.0.0.0:$ANYTLS_PORT -> $TUN2SOCKS_IP:$ANYTLS_PORT
- NaiveProxy HTTP/伪装：0.0.0.0:$NAIVE_HTTP_PORT -> $TUN2SOCKS_IP:$NAIVE_HTTP_PORT
- NaiveProxy HTTPS：0.0.0.0:$NAIVE_HTTPS_PORT -> $TUN2SOCKS_IP:$NAIVE_HTTPS_PORT

共享 tun2socks 网络命名空间的业务容器：
- $ANYTLS_NAME
- $NAIVE_NAME

本地客户端需要保存的凭据（仅在此处显示一次）：
- AnyTLS 密码：$ANYTLS_PASS
- NaiveProxy 用户名：$NAIVE_USER
- NaiveProxy 密码：$NAIVE_PASS

上游 SOCKS5：${SOCKS_HOST}:${SOCKS_PORT}（认证：$([ -n "${SOCKS_USER}" ] && echo "有" || echo "无")）
敏感配置文件：$PROJECT_DIR/jiakuan.env（权限 600，不提交 GitHub）

验证命令：
  bash $PROJECT_DIR/scripts/verify.sh

回滚命令：
  bash $PROJECT_DIR/scripts/rollback.sh
======================================================
EOF
}

main() {
  need_root
  require_cmd docker
  collect_inputs
  ensure_project_dirs
  resolve_socks_ip
  build_socks_proxy_url
  write_static_files
  write_env_file

  if check_host_net; then
    HOST_NET_OK_BEFORE="yes"
    log "部署前宿主机联网正常。"
  else
    warn "部署前宿主机联网检测失败；后续不会以联网异常为依据自动回滚，但仍会尽力部署。"
  fi

  backup_iptables
  github_sync_if_requested
  migrate_docker_root_if_requested

  if ! docker info >/dev/null 2>&1; then
    err "Docker 不可用或 daemon 未运行。脚本不会自动安装或重启 Docker，请先修复 Docker。"
    exit 1
  fi

  cleanup_old_redsocks_if_requested
  cleanup_old_iptables_rules
  post_host_net_guard
  preflight_upstream_socks_host
  verify_tun2socks_image_params
  pull_other_images
  ensure_docker_network
  ensure_project_docker_egress_rules
  preflight_upstream_socks_entry_network
  cleanup_current_project_containers
  check_public_ports_available
  ensure_tun_device
  run_tun2socks
  run_business_containers
  run_entry_containers
  install_systemd_unit
  post_host_net_guard
  run_verify
  final_summary
}

main "$@"
