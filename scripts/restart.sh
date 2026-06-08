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
