#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly ASSET_DIR="/usr/local/share/xray"
readonly PORT="443"

reality_domain=""
server_address=""
force="false"
installer_tmp=""
config_tmp=""
asset_tmp_dir=""

cleanup() {
  [[ -z "${installer_tmp}" ]] || rm -f -- "${installer_tmp}"
  [[ -z "${config_tmp}" ]] || rm -f -- "${config_tmp}"
  [[ -z "${asset_tmp_dir}" ]] || rm -rf -- "${asset_tmp_dir}"
}
trap cleanup EXIT

info() {
  printf '\033[1;34m[信息]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[提醒]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  sudo bash install.sh
  sudo bash install.sh --domain example.com [--address 203.0.113.10] [--force]

参数：
  -d, --domain    REALITY 伪装站点域名（不要带协议、端口或路径）
  -a, --address   客户端连接的服务器公网 IP 或域名；默认自动探测
  -f, --force     无交互覆盖已有 Xray 配置
  -h, --help      显示帮助
EOF
}

while (($# > 0)); do
  case "$1" in
    -d | --domain)
      (($# >= 2)) || die "$1 缺少参数"
      reality_domain="$2"
      shift 2
      ;;
    -a | --address)
      (($# >= 2)) || die "$1 缺少参数"
      server_address="$2"
      shift 2
      ;;
    -f | --force)
      force="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1（使用 --help 查看帮助）"
      ;;
  esac
done

validate_domain() {
  local domain="$1"
  local label
  local -a labels

  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

  IFS='.' read -r -a labels <<<"$domain"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_address() {
  local address="$1"
  [[ -n "$address" && ${#address} -le 253 ]] || return 1
  case "$address" in
    *'/'* | *'?'* | *'#'* | *'@'* | *'['* | *']'*) return 1 ;;
  esac
  [[ "$address" =~ ^[A-Za-z0-9:.-]+$ ]]
}

has_tty() {
  { : </dev/tty && : >/dev/tty; } 2>/dev/null
}

prompt_domain() {
  while [[ -z "$reality_domain" ]]; do
    has_tty || die "无法读取交互输入；请使用 --domain 指定 REALITY 域名。"
    read -r -p "请输入 REALITY 伪装域名（例如 www.example.com）: " reality_domain </dev/tty
    reality_domain="${reality_domain%.}"
    if ! validate_domain "$reality_domain"; then
      warn "域名格式不正确，请不要包含 https://、端口或路径。"
      reality_domain=""
    fi
  done
}

install_dependencies() {
  if command -v curl >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    return
  fi

  info "安装基础依赖……"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl openssl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl openssl ca-certificates
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl openssl ca-certificates
  else
    die "未找到受支持的包管理器，请先安装 curl、openssl 和 ca-certificates。"
  fi
}

detect_public_address() {
  local detected=""

  detected="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$detected" ]]; then
    detected="$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  fi
  if validate_address "$detected"; then
    server_address="$detected"
    info "探测到服务器公网地址：${server_address}"
    return
  fi

  if has_tty; then
    while [[ -z "$server_address" ]]; do
      read -r -p "无法自动探测公网地址，请输入服务器公网 IP 或域名: " server_address </dev/tty
      if ! validate_address "$server_address"; then
        warn "服务器地址格式不正确。"
        server_address=""
      fi
    done
  else
    die "无法自动探测公网地址；非交互运行时请使用 --address 指定。"
  fi
}

confirm_overwrite() {
  [[ -s "$CONFIG_FILE" ]] || return
  [[ "$force" == "true" ]] && return

  if ! has_tty; then
    die "已存在 Xray 配置；如需覆盖，请添加 --force。"
  fi

  local answer=""
  warn "检测到已有配置：${CONFIG_FILE}。继续会生成新凭据，并使旧导入链接失效。"
  read -r -p "确认备份并覆盖吗？[y/N] " answer </dev/tty
  [[ "$answer" =~ ^[Yy]$ ]] || die "已取消。"
}

check_port_available() {
  local listeners=""

  command -v ss >/dev/null 2>&1 || return
  listeners="$(ss -H -ltnp "sport = :${PORT}" 2>/dev/null || true)"
  [[ -z "$listeners" ]] && return
  if grep -q '"xray"' <<<"$listeners"; then
    warn "TCP ${PORT} 当前由 Xray 占用，将更新现有节点配置。"
  else
    die "TCP ${PORT} 已被其他程序占用，请先释放该端口：${listeners}"
  fi
}

install_xray() {
  installer_tmp="$(mktemp /tmp/xray-install.XXXXXX.sh)"
  info "下载并运行 XTLS 官方 Xray 安装脚本……"
  curl -fL --retry 3 --connect-timeout 10 -o "$installer_tmp" "$XRAY_INSTALL_URL"
  bash "$installer_tmp" install
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装失败：未找到 ${XRAY_BIN}。"
}

download_geodata() {
  asset_tmp_dir="$(mktemp -d /tmp/xray-geodata.XXXXXX)"
  info "下载 Loyalsoldier 路由数据……"
  curl -fL --retry 3 --connect-timeout 10 -o "${asset_tmp_dir}/geoip.dat" "$GEOIP_URL"
  curl -fL --retry 3 --connect-timeout 10 -o "${asset_tmp_dir}/geosite.dat" "$GEOSITE_URL"
  [[ -s "${asset_tmp_dir}/geoip.dat" && -s "${asset_tmp_dir}/geosite.dat" ]] ||
    die "路由数据下载不完整。"

  install -d -m 0755 "$ASSET_DIR"
  install -m 0644 "${asset_tmp_dir}/geoip.dat" "${ASSET_DIR}/geoip.dat"
  install -m 0644 "${asset_tmp_dir}/geosite.dat" "${ASSET_DIR}/geosite.dat"
}

generate_credentials() {
  local key_output

  uuid="$("$XRAY_BIN" uuid | tr -d '\r\n')"
  key_output="$("$XRAY_BIN" x25519)"
  private_key="$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$key_output")"
  public_key="$(awk -F': *' 'tolower($1) ~ /(password|public)/ {print $2; exit}' <<<"$key_output")"
  short_id="$(openssl rand -hex 8)"

  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 生成失败。"
  [[ -n "$private_key" && -n "$public_key" ]] || die "REALITY X25519 密钥生成失败。"
  [[ "$short_id" =~ ^[0-9a-f]{16}$ ]] || die "Short ID 生成失败。"
}

write_config() {
  local backup=""

  install -d -m 0755 "$CONFIG_DIR"
  config_tmp="$(mktemp /tmp/xray-config.XXXXXX.json)"
  cat >"$config_tmp" <<EOF
{
  "log": {
    "loglevel": "info"
  },
  "geodata": {
    "cron": "30 4 * * 1",
    "outbound": "direct",
    "assets": [
      {
        "url": "${GEOIP_URL}",
        "file": "geoip.dat"
      },
      {
        "url": "${GEOSITE_URL}",
        "file": "geosite.dat"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${reality_domain}:443",
          "xver": 0,
          "serverNames": [
            "${reality_domain}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:google",
          "geosite:google-cn"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "geosite:cn"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

  info "校验 Xray 配置……"
  "$XRAY_BIN" run -test -config "$config_tmp"

  if [[ -s "$CONFIG_FILE" ]]; then
    backup="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$CONFIG_FILE" "$backup"
    info "旧配置已备份到：${backup}"
  fi
  install -m 0644 "$config_tmp" "$CONFIG_FILE"
}

allow_geodata_updates() {
  local service_user service_group

  service_user="$(systemctl show xray.service -p User --value 2>/dev/null || true)"
  [[ -n "$service_user" ]] || service_user="root"
  if id "$service_user" >/dev/null 2>&1; then
    service_group="$(id -gn "$service_user")"
    chown "root:${service_group}" "$CONFIG_FILE"
    chmod 0640 "$CONFIG_FILE"
    chown -R "${service_user}:${service_group}" "$ASSET_DIR"
    chmod 0755 "$ASSET_DIR"
    chmod 0644 "${ASSET_DIR}/geoip.dat" "${ASSET_DIR}/geosite.dat"
  else
    warn "无法识别 Xray 服务用户，定时更新 geodata 时可能没有写权限。"
  fi
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp"
    info "已在 UFW 放行 TCP ${PORT} 端口。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --add-port="${PORT}/tcp"
    info "已在 firewalld 放行 TCP ${PORT} 端口。"
  else
    warn "未检测到启用中的 UFW/firewalld；请确认云安全组和系统防火墙已放行 TCP ${PORT}。"
  fi
}

start_xray() {
  systemctl daemon-reload
  systemctl enable xray.service >/dev/null
  if ! systemctl restart xray.service; then
    journalctl -u xray.service -n 30 --no-pager >&2 || true
    die "Xray 启动失败，请根据上方日志排查。"
  fi
  systemctl is-active --quiet xray.service || die "Xray 服务未处于运行状态。"
}

print_result() {
  local uri_host="$server_address"
  local import_link

  [[ "$uri_host" == *:* ]] && uri_host="[${uri_host}]"
  import_link="vless://${uuid}@${uri_host}:${PORT}?encryption=none&security=reality&sni=${reality_domain}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision#Xray-REALITY"

  printf '\n\033[1;32m安装完成，Xray 正在运行。\033[0m\n\n'
  printf '服务器地址：%s\n' "$server_address"
  printf '端口：%s\n' "$PORT"
  printf 'UUID：%s\n' "$uuid"
  printf 'REALITY 公钥：%s\n' "$public_key"
  printf 'Short ID：%s\n' "$short_id"
  printf 'SNI：%s\n\n' "$reality_domain"
  printf '客户端导入链接：\n%s\n\n' "$import_link"
  printf '服务端配置：%s\n' "$CONFIG_FILE"
  printf '查看状态：systemctl status xray --no-pager\n'
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 权限运行，例如：sudo bash install.sh"
  [[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux。"
  command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd/systemctl。"

  prompt_domain
  validate_domain "$reality_domain" || die "REALITY 域名格式不正确。"
  [[ -z "$server_address" ]] || validate_address "$server_address" ||
    die "服务器地址格式不正确。"
  check_port_available
  confirm_overwrite
  install_dependencies
  [[ -n "$server_address" ]] || detect_public_address
  install_xray
  download_geodata
  generate_credentials
  write_config
  allow_geodata_updates
  open_firewall_port
  start_xray

  if ! "$XRAY_BIN" tls ping "${reality_domain}:443" >/dev/null 2>&1; then
    warn "Xray 未能确认伪装站点的 TLS 可用性；节点可能仍能启动，但建议更换支持 TLS 1.3 的目标域名。"
  fi
  print_result
}

main
