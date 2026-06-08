#!/usr/bin/env bash
set -Eeuo pipefail

# 通用引导安装脚本：从任意目录启动，不绑定具体域名或项目根目录。
# 实际项目根目录、域名、证书路径会在 install-tun2socks-gateway.sh 中交互输入。

REPO_URL="${JIAKUAN_REPO_URL:-https://github.com/jiasongji/jiakuan-tun2socks-gateway.git}"
INSTALLER_DIR="${JIAKUAN_INSTALLER_DIR:-/tmp/jiakuan-tun2socks-gateway-installer}"
BRANCH="${JIAKUAN_BRANCH:-main}"

log() { printf '\033[1;32m[信息]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "请使用 root 执行：sudo -i 后再运行本脚本。"
  exit 1
fi

command -v git >/dev/null 2>&1 || { err "缺少 git，无法拉取安装器。请先安装 git，或手动上传仓库文件。"; exit 1; }

if [ -d "$INSTALLER_DIR/.git" ]; then
  log "更新安装器：$INSTALLER_DIR"
  git -C "$INSTALLER_DIR" fetch origin "$BRANCH"
  git -C "$INSTALLER_DIR" reset --hard "origin/$BRANCH"
else
  log "拉取安装器到临时目录：$INSTALLER_DIR"
  rm -rf "$INSTALLER_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$INSTALLER_DIR"
fi

cd "$INSTALLER_DIR"
chmod +x install-tun2socks-gateway.sh
exec bash install-tun2socks-gateway.sh
