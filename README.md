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
