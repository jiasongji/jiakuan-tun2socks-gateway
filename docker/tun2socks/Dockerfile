# 家宽出口网关 tun2socks 镜像
# 基于官方 tun2socks 镜像封装本项目入口脚本，最终推送到自己的 Docker Hub 账号。
FROM xjasonlyu/tun2socks:latest

LABEL org.opencontainers.image.title="jiakuan-tun2socks" \
      org.opencontainers.image.description="家宽 SOCKS5 出口网关 tun2socks 容器镜像" \
      org.opencontainers.image.source="https://github.com/jiasongji/jiakuan-tun2socks-gateway"

COPY tun2socks-entrypoint.sh /jiakuan/tun2socks-entrypoint.sh
RUN chmod +x /jiakuan/tun2socks-entrypoint.sh

ENTRYPOINT ["/jiakuan/tun2socks-entrypoint.sh"]
