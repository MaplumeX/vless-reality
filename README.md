# VLESS + REALITY 一键安装脚本

在 Linux 服务器上安装 Xray，并生成一套 VLESS + TCP/REALITY + XTLS Vision
节点配置。支持 systemd 发行版和使用 OpenRC 的 Alpine Linux，运行结束后会直接
输出可供客户端导入的 `vless://` 链接。

## 功能

- 使用 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 官方脚本安装或升级
  Xray；
- 自动识别 systemd 或 Alpine/OpenRC；Alpine 使用 XTLS 官方 Alpine 安装器；
- 由用户指定 REALITY 目标域名；
- 自动生成 UUID、X25519 密钥对和 8 字节 Short ID；
- 自动探测服务器公网 IPv4，IPv4 不可用时尝试 IPv6；
- 下载 Loyalsoldier 的 `geoip.dat` 和 `geosite.dat`；
- 每周一 04:30 通过 Xray 自动更新 geodata；
- 写入前使用 Xray 内核校验配置；
- 检查 TCP 443 端口是否被其他程序占用；
- 在已启用 UFW 或 firewalld 时自动放行 TCP 443；
- 启动 Xray 并输出客户端导入链接。

## 配置概览

| 项目 | 值 |
| --- | --- |
| 协议 | VLESS |
| 传输 | RAW/TCP |
| 安全 | REALITY |
| Flow | `xtls-rprx-vision` |
| 监听地址 | `::` |
| 监听端口 | `443` |
| 客户端指纹 | `chrome` |
| 国内域名与 IP | 阻断 |
| Google 及 Google CN 规则 | 直连 |

客户端导入链接使用 `type=tcp`，与服务端的 `network: raw` 兼容，并能被更多客户端
识别。

## 环境要求

- 使用 systemd 的 Linux 发行版，或使用 OpenRC 的 Alpine Linux；
- root 或 sudo 权限；
- Bash；
- 服务器能够访问 GitHub；
- TCP 443 没有被 Nginx、Caddy、Apache 等其他服务占用；
- 云厂商安全组和外部防火墙允许 TCP 443 入站。

脚本支持通过 `apk`、`apt-get`、`dnf`、`yum` 或 `zypper` 安装所需依赖。

## 快速开始

直接运行：

```bash
curl -fsSL https://raw.githubusercontent.com/MaplumeX/vless-reality/main/install.sh | sudo bash
```

Alpine 默认可能没有 Bash 和 curl，可用一条命令补齐依赖并安装：

```bash
sudo apk add --no-cache bash curl &&
  curl -fsSL https://raw.githubusercontent.com/MaplumeX/vless-reality/main/install.sh |
  sudo bash
```

根据提示输入 REALITY 目标域名，例如：

```text
请输入 REALITY 伪装域名（例如 www.example.com）: www.example.com
```

这里只填写域名，不要包含 `https://`、端口、路径或通配符。

如果服务器上还没有安装 `curl`，可以先安装：

```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y curl

# CentOS / RHEL / Fedora
sudo dnf install -y curl

# Alpine Linux
sudo apk add --no-cache bash curl
```

安装成功后，脚本会显示：

- 服务器公网地址和端口；
- UUID；
- REALITY 公钥；
- Short ID；
- SNI；
- 完整的 `vless://` 客户端导入链接。

请妥善保存导入链接，其中包含节点连接凭据。

## 命令行参数

```text
用法：
  sudo bash install.sh
  sudo bash install.sh --domain example.com [--address 203.0.113.10] [--force]

参数：
  -d, --domain    REALITY 目标域名，不带协议、端口或路径
  -a, --address   客户端连接的服务器公网 IP 或域名
  -f, --force     无交互覆盖已有 Xray 配置
  -h, --help      显示帮助
```

非交互安装示例：

```bash
curl -fsSL https://raw.githubusercontent.com/MaplumeX/vless-reality/main/install.sh |
  sudo bash -s -- \
    --domain www.example.com \
    --address 203.0.113.10 \
    --force
```

`--address` 可以省略，脚本会通过公网服务探测服务器地址。自动探测失败且当前是
交互式终端时，脚本会要求手动输入。

也可以克隆仓库后运行：

```bash
git clone https://github.com/MaplumeX/vless-reality.git
cd vless-reality
sudo ./install.sh
```

如果已经存在 Xray 配置，交互模式会要求确认后再覆盖；非交互模式必须显式添加
`--force`。每次重新运行都会生成新的 UUID、密钥和 Short ID，原导入链接将随之
失效。

## 如何选择 REALITY 目标域名

建议选择满足以下条件的站点：

- 支持 TLS 1.3；
- 使用标准 TCP 443 端口；
- 从服务器所在网络访问稳定；
- 域名与服务器网络环境相对匹配；
- 不需要额外跳转才能建立 TLS 连接。

不要填写自己的节点域名。REALITY 目标域名是握手时使用的外部 TLS 站点，并不需要
解析到当前服务器。

REALITY 会将认证失败的连接转发到目标站点。避免选择可能让服务器被滥用为大流量
转发器的 CDN 目标。安装完成后，脚本会使用 `xray tls ping` 检查目标站点；检查
失败时会给出警告，但不会删除已经生成的配置。

## 生成的配置

主要文件和服务：

| 用途 | 位置 |
| --- | --- |
| Xray 程序 | `/usr/local/bin/xray` |
| 服务端配置 | `/usr/local/etc/xray/config.json` |
| GeoIP | `/usr/local/share/xray/geoip.dat` |
| GeoSite | `/usr/local/share/xray/geosite.dat` |
| systemd 服务 | `xray.service` |
| OpenRC 服务 | `/etc/init.d/xray` |

重新安装时，systemd 环境会直接覆盖 `config.json`，不保留备份。OpenRC 官方安装器
使用多文件配置目录；为了避免旧配置与新配置合并冲突，脚本会删除目录中的旧 JSON
配置，再写入单个 `config.json`，同样不保留备份。

脚本生成的路由规则与项目目标配置保持一致：

1. `geosite:google` 和 `geosite:google-cn` 使用 `direct`；
2. `geosite:cn` 使用 `block`；
3. `geoip:cn` 使用 `block`；
4. 其他流量默认直连。

这意味着节点无法访问大多数中国大陆域名和 IP。如果不需要这一限制，请安装后自行
修改 `routing.rules`，然后重新校验并启动服务。

## 常用运维命令

systemd 常用命令：

```bash
systemctl status xray --no-pager
journalctl -u xray.service -n 100 --no-pager
journalctl -u xray.service -f
systemctl restart xray.service
```

OpenRC/Alpine 常用命令：

```bash
rc-service xray status
rc-service xray restart
rc-update add xray default
```

两种环境都可以直接校验配置：

```bash
/usr/local/bin/xray run -test \
  -config /usr/local/etc/xray/config.json
```

查看版本：

```bash
/usr/local/bin/xray version
```

## 常见问题

### TCP 443 已被占用

脚本会在安装前停止，并显示监听该端口的程序。可以用以下命令进一步检查：

```bash
ss -lntp 'sport = :443'
```

停止或调整占用 443 的服务后，再重新运行脚本。

### 服务正常运行，但客户端无法连接

依次检查：

1. 云厂商安全组是否允许 TCP 443 入站；
2. UFW、firewalld、nftables 或 iptables 是否允许 TCP 443；
3. 客户端是否支持 VLESS、REALITY 和 XTLS Vision；
4. 客户端中的 UUID、公钥、Short ID、SNI 是否与脚本输出完全一致；
5. 服务器能否访问所填写目标域名的 TCP 443。

### 自动探测到的公网地址不正确

NAT、多出口或代理环境可能影响自动探测。重新运行时通过 `--address` 指定客户端
实际应该连接的公网 IP 或域名：

```bash
sudo ./install.sh \
  --domain www.example.com \
  --address node.example.net \
  --force
```

## 安全提示

- 不要公开分享客户端导入链接、UUID、REALITY 私钥或 Short ID；
- 建议定期更新 Xray；
- 定期检查 Xray 服务状态和日志中的异常连接；
- 不要将来源不明的域名作为 REALITY 目标；
- 本脚本会修改 Xray 配置及 UFW/firewalld 规则，请先了解服务器上已有服务。

请在遵守所在地法律法规以及服务商使用条款的前提下使用本项目。
