#!/usr/bin/env bash
set -Eeuo pipefail

# 构建并推送本项目使用的 Docker 镜像到自己的 Docker Hub 账号。
# 默认命名空间为 jiasongji；如需更换：DOCKER_NAMESPACE=你的账号 bash scripts/docker-build-push.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

DOCKER_NAMESPACE="${DOCKER_NAMESPACE:-jiasongji}"
# 目标服务器通常为 Debian 12 amd64 VPS，因此默认发布 amd64。若需要多架构，可设置 BUILD_PLATFORMS=linux/amd64,linux/arm64。
BUILD_PLATFORMS="${BUILD_PLATFORMS:-linux/amd64}"

log() { printf '\033[1;32m[信息]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { err "缺少 docker 命令。"; exit 1; }
docker info >/dev/null 2>&1 || { err "Docker daemon 不可用。"; exit 1; }
docker buildx version >/dev/null 2>&1 || { err "缺少 docker buildx。"; exit 1; }

build_push() {
  local name="$1" tag="$2" dockerfile="$3"
  local image="${DOCKER_NAMESPACE}/${name}:${tag}"
  log "构建并推送：${image}，平台：${BUILD_PLATFORMS}"
  docker buildx build \
    --platform "$BUILD_PLATFORMS" \
    --push \
    -t "$image" \
    -f "$dockerfile" \
    .
}

build_push jiakuan-tun2socks latest docker/tun2socks/Dockerfile
build_push jiakuan-socat latest docker/socat/Dockerfile
build_push jiakuan-curl 8.10.1 docker/curl/Dockerfile
build_push jiakuan-anytls latest docker/anytls/Dockerfile
build_push jiakuan-naiveproxy latest docker/naiveproxy/Dockerfile

log "全部镜像已推送到 Docker Hub 命名空间：${DOCKER_NAMESPACE}"
