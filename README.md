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

## 默认端口

默认公网端口均在 `33801-33810` 范围内：

| 用途 | 宿主机端口 | 入口容器 | 后端目标 |
| --- | ---: | --- | --- |
| AnyTLS | 33801 | JiaKuan-Entry-AnyTLS | 172.31.253.10:33801 |
| NaiveProxy HTTP/伪装 | 33802 | JiaKuan-Entry-NaiveHTTP | 172.31.253.10:33802 |
| NaiveProxy HTTPS | 33803 | JiaKuan-Entry-NaiveHTTPS | 172.31.253.10:33803 |

## 一键部署

> 目标服务器需要已安装 Docker；脚本不会默认安装 Docker、不会默认重启 Docker、不会默认修改宿主机默认路由、不会默认迁移 Docker 全局数据目录。

```bash
mkdir -p /www/wwwroot/sjc.giize.com
cd /www/wwwroot/sjc.giize.com
if [ ! -d jiakuan-proxy/.git ]; then
  git clone https://github.com/jiasongji/jiakuan-tun2socks-gateway.git jiakuan-proxy
fi
cd jiakuan-proxy
git pull --ff-only || true
chmod +x install-tun2socks-gateway.sh
bash install-tun2socks-gateway.sh
```

## 交互项说明

脚本会询问：

- 项目根目录，默认 `/www/wwwroot/sjc.giize.com`
- 域名，默认 `sjc.giize.com`
- 证书 fullchain 路径与 privkey 路径
- 家宽 SOCKS5 IP/域名、端口、用户名、密码
- AnyTLS 端口与密码
- NaiveProxy HTTP/HTTPS 端口、用户名、密码、伪装地址
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
bash /www/wwwroot/sjc.giize.com/jiakuan-proxy/scripts/verify.sh

# 按正确顺序重启
systemctl restart jiakuan-tun2socks-gateway.service
# 或
bash /www/wwwroot/sjc.giize.com/jiakuan-proxy/scripts/restart.sh

# 停止本组容器
bash /www/wwwroot/sjc.giize.com/jiakuan-proxy/scripts/stop.sh

# 回滚本方案创建的容器、网络和 systemd 服务
bash /www/wwwroot/sjc.giize.com/jiakuan-proxy/scripts/rollback.sh
```

## 验证重点

脚本部署后会自动执行 `scripts/verify.sh`。人工复查时重点看：

1. 业务容器没有直接发布宿主机端口。
2. `JiaKuan-Tun2Socks` 中访问普通公网地址的路由走 `tun0`。
3. Docker 入口子网与 SOCKS5 服务器 IP 的路由走 `eth0`。
4. 以下命令输出应为家宽 SOCKS5 的出口 IP：

```bash
docker run --rm --network container:JiaKuan-Tun2Socks curlimages/curl:8.10.1 -4fsS https://api.ipify.org
```

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
docker run --rm --entrypoint tun2socks xjasonlyu/tun2socks:latest --help
```

并检查 `--device`、`--proxy`、`--interface`、`--loglevel`、`--fwmark` 等参数是否存在，然后才继续部署。官方 Wiki 的 Linux 示例使用 `--device`、`--proxy`、`--interface`；官方源码 `main.go` 也定义了这些参数。
