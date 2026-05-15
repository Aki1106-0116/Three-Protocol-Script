#!/usr/bin/env bash
# jb-combo-installer.sh
# Debian/Ubuntu combo installer for exactly ONE of:
#   1) VLESS + XHTTP + TLS  + Hysteria2
#   2) NaiveProxy           + Hysteria2
#   3) VLESS + REALITY + Vision + Hysteria2
#
# Design:
# - XHTTP/Naive stacks use Caddy for public TCP 80/443, certificates, and web camouflage.
# - REALITY stack uses Xray on TCP 443 and Hysteria2 built-in ACME for HY2 certificates; no Caddy.
# - Hysteria2 ports may NOT be 80, 443, 2053, or 8443, including ranges.
# - When Caddy manages certificates for HY2, certificates are NOT copied or moved; HY2 reads Caddy's cert/key paths directly.
# - Run `jb` after installation to open the control panel.

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="jb-combo"
STATE_DIR="/etc/jb-combo"
STATE_FILE="${STATE_DIR}/state.env"
JB_CMD="/usr/local/bin/jb"
JB_CMD_FALLBACK="/usr/bin/jb"
THIS_SCRIPT="/usr/local/lib/jb-combo-installer.sh"
DEFAULT_SCRIPT_URL="https://raw.githubusercontent.com/Aki1106-0116/Three-Protocol-Script/refs/heads/main/jb-combo-installer.sh"
SCRIPT_DOWNLOAD_URL="${JB_INSTALLER_URL:-$DEFAULT_SCRIPT_URL}"

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_BIN="/usr/bin/caddy"
CADDY_DATA="/var/lib/caddy/.local/share/caddy"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_BIN="/usr/local/bin/hysteria"

WEB_ROOT="/var/www/jb-speedtest"
HY2_WEB_ROOT="/var/www/jb-hy2-site"
OUT_DIR="/root/jb-combo"
INFO_FILE="${OUT_DIR}/node-info.txt"
XRAY_CLIENT_JSON="${OUT_DIR}/xray-client.json"
HY2_CLIENT_JSON="${OUT_DIR}/hy2-client.json"
HY2_CLIENT_YAML="${OUT_DIR}/hy2-client.yaml"

RESERVED_HY2_PORTS=(80 443 2053 8443)
BASE_PACKAGES_INSTALLED=0

log() { echo -e "${BLUE}==>${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err() { echo -e "${RED}✗${NC} $*" >&2; }

pause_confirm() { read -r -p "${1:-按回车继续...}" _ || true; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "无法识别系统。仅支持 Debian / Ubuntu。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) err "当前系统是 ${PRETTY_NAME:-unknown}。本脚本仅支持 Debian / Ubuntu。"; exit 1 ;;
  esac
  if ! cmd_exists systemctl; then
    err "未检测到 systemd。"
    exit 1
  fi
  ok "系统检查通过：${PRETTY_NAME:-$ID}"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    return 0
  fi
  return 1
}

save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  local tmp="${STATE_FILE}.tmp" name val
  : > "$tmp"
  chmod 600 "$tmp"

  local vars=(
    STACK_MODE MAIN_MODE MANAGED_DOMAINS CADDY_REQUIRED WEB_ENABLED
    MAIN_DOMAIN MAIN_DOMAIN2 XHTTP_DOMAIN XHTTP_PATH XHTTP_UUID XHTTP_BACKEND_PORT
    NAIVE_DOMAIN NAIVE_USER NAIVE_PASS
    REALITY_ADDRESS REALITY_UUID REALITY_SNI REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID FP NODE_NAME
    HY2_DOMAIN HY2_PASSWORD HY2_PORT_MODE HY2_PORT HY2_FIRST_PORT HY2_END_PORT HY2_HOP_INTERVAL
    HY2_MIN_HOP_INTERVAL HY2_MAX_HOP_INTERVAL HY2_CERT_SOURCE HY2_CERT_PATH HY2_KEY_PATH HY2_ACME_EMAIL
  )

  for name in "${vars[@]}"; do
    if [[ -v "$name" ]]; then
      val="${!name}"
    else
      case "$name" in
        CADDY_REQUIRED|WEB_ENABLED) val="0" ;;
        FP) val="chrome" ;;
        HY2_HOP_INTERVAL) val="25" ;;
        *) val="" ;;
      esac
    fi
    printf '%s=%q\n' "$name" "$val" >> "$tmp"
  done

  mv -f "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

resolve_self_source() {
  local src="" candidate real_src real_dst
  for candidate in "${JB_INSTALLER_SOURCE:-}" "${BASH_SOURCE[0]:-}" "$0"; do
    [[ -n "$candidate" && -f "$candidate" && -s "$candidate" && -r "$candidate" ]] || continue
    src="$candidate"
    break
  done
  [[ -n "$src" ]] || return 1

  real_src="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
  real_dst="$(readlink -f "$THIS_SCRIPT" 2>/dev/null || printf '%s' "$THIS_SCRIPT")"

  # If already running from the persisted copy, do not copy a file onto itself.
  if [[ "$real_src" == "$real_dst" ]]; then
    return 2
  fi

  printf '%s' "$src"
}

install_self_command() {
  mkdir -p "$(dirname "$THIS_SCRIPT")" "$(dirname "$JB_CMD")"

  local src="" rc=0
  src="$(resolve_self_source)" || rc=$?
  if [[ "$rc" -eq 0 && -n "$src" ]]; then
    install -m 755 "$src" "$THIS_SCRIPT"
  elif [[ "$rc" -eq 2 && -s "$THIS_SCRIPT" ]]; then
    chmod 755 "$THIS_SCRIPT" 2>/dev/null || true
  elif [[ ! -s "$THIS_SCRIPT" ]]; then
    log "当前是一键远程运行模式，正在从 GitHub 保存控制面板主脚本"
    if cmd_exists curl; then
      curl -fsSL "$SCRIPT_DOWNLOAD_URL" -o "$THIS_SCRIPT"
    elif cmd_exists wget; then
      wget -qO "$THIS_SCRIPT" "$SCRIPT_DOWNLOAD_URL"
    else
      warn "无法保存控制面板脚本：系统没有 curl/wget。安装基础依赖后会再次尝试。"
      return 1
    fi
    chmod 755 "$THIS_SCRIPT"
  fi

  if [[ ! -s "$THIS_SCRIPT" ]]; then
    warn "控制面板主脚本仍不存在：$THIS_SCRIPT"
    return 1
  fi

  cat > "$JB_CMD" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT="$THIS_SCRIPT"
URL="$SCRIPT_DOWNLOAD_URL"
if [[ ! -s "\$SCRIPT" ]]; then
  mkdir -p "\$(dirname "\$SCRIPT")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "\$URL" -o "\$SCRIPT"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "\$SCRIPT" "\$URL"
  else
    echo "jb: missing \$SCRIPT and curl/wget is unavailable" >&2
    exit 1
  fi
  chmod 755 "\$SCRIPT"
fi
exec bash "\$SCRIPT" menu "\$@"
EOF
  chmod +x "$JB_CMD"

  # Some minimal systems or non-login root shells do not include /usr/local/bin in PATH.
  # Install a conservative /usr/bin fallback only when it is absent or already points to this script's wrapper.
  if [[ "$JB_CMD_FALLBACK" != "$JB_CMD" ]]; then
    if [[ ! -e "$JB_CMD_FALLBACK" || "$(readlink -f "$JB_CMD_FALLBACK" 2>/dev/null || true)" == "$(readlink -f "$JB_CMD" 2>/dev/null || true)" ]]; then
      ln -sf "$JB_CMD" "$JB_CMD_FALLBACK" 2>/dev/null || true
    fi
  fi

  ok "已安装控制面板命令：jb"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_ip() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
}

valid_host_address() {
  local h="$1"
  valid_domain "$h" || valid_ip "$h"
}

normalize_host_address() {
  local h="$1" colon_count
  h="$(echo "${h:-}" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##')"
  if [[ "$h" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
    h="${BASH_REMATCH[1]}"
  else
    colon_count="$(grep -o ':' <<< "$h" | wc -l | tr -d ' ')"
    if [[ "$colon_count" == "1" && "$h" =~ :[0-9]+$ ]]; then
      h="${h%%:*}"
    fi
  fi
  printf '%s' "$h"
}

prompt_host_address() {
  local prompt="$1" default="${2:-}" h
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [默认 $default]: " h
      h="${h:-$default}"
    else
      read -r -p "$prompt: " h
    fi
    h="$(normalize_host_address "$h")"
    if valid_host_address "$h"; then
      printf '%s' "$h"
      return 0
    fi
    warn "连接地址格式不正确，请输入域名、IPv4 或 IPv6。"
  done
}

uri_host() {
  local h="$1"
  if valid_ip "$h" && [[ "$h" == *:* ]]; then
    printf '[%s]' "$h"
  else
    printf '%s' "$h"
  fi
}

normalize_domain() {
  local d="$1"
  d="$(echo "${d:-}" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##; s/:.*$//')"
  printf '%s' "$d"
}

prompt_domain() {
  local prompt="$1" default="${2:-}" d
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [默认 $default]: " d
      d="${d:-$default}"
    else
      read -r -p "$prompt: " d
    fi
    d="$(normalize_domain "$d")"
    if valid_domain "$d"; then
      printf '%s' "$d"
      return 0
    fi
    warn "域名格式不正确，请重新输入。"
  done
}

normalize_path() {
  local p="$1"
  p="${p%%\?*}"; p="${p%%#*}"
  [[ -z "$p" ]] && return 1
  [[ "$p" != /* ]] && p="/$p"
  [[ "$p" != "/" ]] && p="${p%/}"
  [[ "$p" == "/" ]] && return 1
  [[ "$p" =~ ^/[A-Za-z0-9._~/-]+$ ]] || return 1
  printf '%s' "$p"
}

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

json_escape() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1], ensure_ascii=False)[1:-1])
PY
}

yaml_quote() {
  python3 - "$1" <<'PY'
import sys
s=sys.argv[1]
print("'" + s.replace("'", "''") + "'")
PY
}

generate_password() { openssl rand -base64 24 | tr -d '\n' | tr '+/' '-_' | cut -c 1-24; }
generate_shortid() { openssl rand -hex 8; }
new_uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }

public_ip() { curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true; }

install_base_packages() {
  if [[ "${BASE_PACKAGES_INSTALLED:-0}" == "1" ]] && cmd_exists ss && cmd_exists curl && cmd_exists python3; then
    return 0
  fi
  log "更新 APT 并安装基础依赖"
  apt-get update
  apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring \
    apt-transport-https lsb-release unzip jq openssl uuid-runtime iproute2 python3 coreutils \
    acl procps lsof iptables nftables
  BASE_PACKAGES_INSTALLED=1
  ok "基础依赖安装完成"
}

ensure_port_tools() {
  if ! cmd_exists ss; then
    install_base_packages
  fi
}

port_in_use_tcp() {
  local port="$1"
  cmd_exists ss || return 1
  ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

port_in_use_udp() {
  local port="$1"
  cmd_exists ss || return 1
  ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
}

show_port_users() {
  echo "TCP 80/443："; ss -ltnp 2>/dev/null | grep -E '(:80|:443)\s' || true
  echo "UDP 端口："; ss -lunp 2>/dev/null | grep -E ':(80|443|2053|8443)\s' || true
}

stop_known_services() {
  for svc in caddy xray hysteria-server nginx apache2 httpd x-ui 3x-ui xui; do
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
      systemctl stop "$svc" >/dev/null 2>&1 || true
      systemctl disable "$svc" >/dev/null 2>&1 || true
    fi
  done
}

ensure_tcp_80_443_free_for_caddy() {
  ensure_port_tools
  if port_in_use_tcp 80 || port_in_use_tcp 443; then
    warn "Caddy 需要占用 TCP 80/443。当前端口被占用："
    show_port_users
    read -r -p "是否停止常见服务以释放端口？[y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { err "请先释放 TCP 80/443。"; exit 1; }
    stop_known_services
    sleep 2
  fi
  if port_in_use_tcp 80 || port_in_use_tcp 443; then
    err "TCP 80/443 仍被占用，请手动处理。"
    show_port_users
    exit 1
  fi
}

ensure_tcp_443_free_for_reality() {
  ensure_port_tools
  if port_in_use_tcp 443; then
    warn "REALITY 需要占用 TCP 443。当前端口被占用："
    show_port_users
    read -r -p "是否停止常见服务以释放 TCP 443？[y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { err "请先释放 TCP 443。"; exit 1; }
    stop_known_services
    sleep 2
  fi
  if port_in_use_tcp 443; then
    err "TCP 443 仍被占用，请手动处理。"
    show_port_users
    exit 1
  fi
}

hy2_reserved_port() {
  local p="$1" r
  for r in "${RESERVED_HY2_PORTS[@]}"; do [[ "$p" -eq "$r" ]] && return 0; done
  return 1
}

hy2_range_contains_reserved() {
  local start="$1" end="$2" r
  for r in "${RESERVED_HY2_PORTS[@]}"; do
    if (( r >= start && r <= end )); then return 0; fi
  done
  return 1
}

find_free_local_port() {
  local p
  for p in $(seq 10000 10199); do
    if ! port_in_use_tcp "$p"; then echo "$p"; return 0; fi
  done
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
}

install_caddy_official() {
  log "安装/升级 Caddy 官方包"
  install -d -m 0755 /usr/share/keyrings
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
  systemctl disable --now caddy >/dev/null 2>&1 || true
  ok "Caddy 安装完成：$(caddy version 2>/dev/null || echo unknown)"
}

install_go_latest() {
  if cmd_exists go; then
    local cur
    cur="$(go version 2>/dev/null | awk '{print $3}' || true)"
    [[ -n "$cur" ]] && ok "检测到 Go：$cur" && return 0
  fi
  log "安装 Go 官方最新版，用于构建 Naive Caddy"
  local version arch url tarball
  version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1)"
  [[ -n "$version" ]] || { err "无法获取 Go 最新版本。"; exit 1; }
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv6l" ;;
    *) err "暂不支持当前架构安装 Go：$(uname -m)"; exit 1 ;;
  esac
  url="https://go.dev/dl/${version}.linux-${arch}.tar.gz"
  tarball="/tmp/${version}.linux-${arch}.tar.gz"
  curl -fL "$url" -o "$tarball"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tarball"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  ok "Go 安装完成：$(go version)"
}

install_naive_caddy() {
  install_caddy_official
  install_go_latest
  log "用 xcaddy 构建带 Naive forwardproxy 插件的 Caddy"
  /usr/local/go/bin/go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
  /root/go/bin/xcaddy build --output /tmp/caddy-naive --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
  if [[ ! -x /tmp/caddy-naive ]]; then
    err "Naive Caddy 构建失败。"
    exit 1
  fi
  systemctl stop caddy >/dev/null 2>&1 || true
  install -m 755 /tmp/caddy-naive "$CADDY_BIN"
  ok "Naive Caddy 构建完成：$($CADDY_BIN version 2>/dev/null || echo unknown)"
}

install_xray_official() {
  log "安装/升级 Xray 官方最新版"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  [[ -x "$XRAY_BIN" ]] || { err "Xray 安装失败，未找到 $XRAY_BIN"; exit 1; }
  systemctl disable --now xray >/dev/null 2>&1 || true
  ok "Xray 安装完成：$($XRAY_BIN version | head -n 1)"
}


generate_reality_x25519_keys() {
  local output parsed

  if [[ ! -x "$XRAY_BIN" ]]; then
    err "未找到可执行的 Xray：$XRAY_BIN"
    err "请先确认 Xray 官方安装脚本是否成功完成。"
    exit 1
  fi

  output="$($XRAY_BIN x25519 2>&1)" || {
    err "Xray X25519 密钥生成命令执行失败：$XRAY_BIN x25519"
    printf '%s\n' "$output" >&2
    exit 1
  }

  parsed="$(XRAY_X25519_OUTPUT="$output" python3 - <<'PY'
import os, re, sys

out = os.environ.get("XRAY_X25519_OUTPUT", "")
data = {}
for line in out.splitlines():
    if ":" not in line:
        continue
    key, value = line.split(":", 1)
    key = re.sub(r"[\s_-]+", "", key.strip().lower())
    data[key] = value.strip()

private = data.get("privatekey")
# Xray newer releases may print "Password:" instead of "Public key:" for x25519.
# For REALITY client sharing, this value is the public-side key material expected by clients.
public = data.get("publickey") or data.get("password")

if not private:
    m = re.search(r"(?im)^\s*Private\s*key\s*:\s*(\S+)\s*$", out)
    if m:
        private = m.group(1)
if not public:
    m = re.search(r"(?im)^\s*Public\s*key\s*:\s*(\S+)\s*$", out)
    if m:
        public = m.group(1)

if not (private and public):
    sys.exit(1)

print(private)
print(public)
PY
  )" || {
    err "无法解析 Xray X25519 输出，可能是 Xray 输出格式再次变化。原始输出如下："
    printf '%s\n' "$output" >&2
    exit 1
  }

  REALITY_PRIVATE_KEY="$(printf '%s\n' "$parsed" | sed -n '1p')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$parsed" | sed -n '2p')"

  if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
    err "X25519 密钥解析结果为空。原始输出如下："
    printf '%s\n' "$output" >&2
    exit 1
  fi

  ok "REALITY X25519 密钥已生成。"
}

install_hysteria_official() {
  log "安装/升级 Hysteria2 官方最新版"
  bash <(curl -fsSL https://get.hy2.sh/)
  [[ -x "$HY2_BIN" ]] || { err "Hysteria2 安装失败，未找到 $HY2_BIN"; exit 1; }
  systemctl disable --now hysteria-server >/dev/null 2>&1 || true
  ok "Hysteria2 安装完成：$($HY2_BIN version 2>/dev/null | head -n 1 || echo installed)"
}

ensure_hysteria_capabilities() {
  local override_dir="/etc/systemd/system/hysteria-server.service.d"
  local override_file="${override_dir}/jb-combo-capabilities.conf"
  local caps=()

  # ACME HTTP-01 需要绑定 TCP/80；端口跳跃需要修改 nftables/iptables。
  [[ "${HY2_CERT_SOURCE:-}" == "acme" ]] && caps+=(CAP_NET_BIND_SERVICE)
  if [[ "${HY2_PORT_MODE:-}" == "hop" ]]; then
    caps+=(CAP_NET_ADMIN CAP_NET_RAW)
  fi
  if [[ "${HY2_PORT:-65535}" =~ ^[0-9]+$ ]] && (( HY2_PORT < 1024 )); then
    caps+=(CAP_NET_BIND_SERVICE)
  fi

  if ((${#caps[@]} == 0)); then
    rm -f "$override_file" 2>/dev/null || true
    return 0
  fi

  # 去重，避免 CapabilityBoundingSet 出现重复项。
  local unique=() cap seen
  for cap in "${caps[@]}"; do
    seen=0
    for existing in "${unique[@]:-}"; do
      [[ "$existing" == "$cap" ]] && { seen=1; break; }
    done
    (( seen == 0 )) && unique+=("$cap")
  done

  mkdir -p "$override_dir"
  cat > "$override_file" <<EOF
[Service]
AmbientCapabilities=${unique[*]}
CapabilityBoundingSet=${unique[*]}
NoNewPrivileges=false
EOF
}

create_speedtest_site() {
  log "生成 speedtest 伪装主页"
  mkdir -p "$WEB_ROOT/assets" "$WEB_ROOT/files" "$HY2_WEB_ROOT"
  cat > "$WEB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Private Network Speed Test</title><link rel="stylesheet" href="/assets/app.css"><link rel="icon" href="/favicon.ico"></head><body><main class="wrap"><section class="hero"><p class="eyebrow">Private Network Diagnostics</p><h1>Speed Test</h1><p class="sub">Measure connectivity to this private edge endpoint. This page is intended for internal network verification.</p><button id="start">Start test</button></section><section class="grid"><article class="card"><span class="label">Latency</span><strong id="latency">—</strong><small>HTTP round-trip</small></article><article class="card"><span class="label">Download</span><strong id="download">—</strong><small>sample object</small></article><article class="card"><span class="label">Endpoint</span><strong id="endpoint">Online</strong><small>status check</small></article></section><section class="panel"><h2>About this endpoint</h2><p>This service provides a simple private connectivity check for authorized network users. Test results may vary with routing, congestion, and client location.</p><pre id="log">Ready.</pre></section></main><script src="/assets/app.js"></script></body></html>
HTML
  cat > "$WEB_ROOT/404.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Not Found</title><link rel="stylesheet" href="/assets/app.css"></head><body><main class="wrap"><section class="hero"><p class="eyebrow">Private Network Diagnostics</p><h1>404</h1><p class="sub">The requested diagnostic resource was not found.</p><a class="button" href="/">Back to status page</a></section></main></body></html>
HTML
  cat > "$WEB_ROOT/assets/app.css" <<'CSS'
:root{color-scheme:light dark;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at top left,rgba(120,120,120,.18),transparent 28%),#101216;color:#f6f7f9}.wrap{width:min(980px,calc(100% - 32px));margin:0 auto;padding:56px 0}.hero{padding:36px;border:1px solid rgba(255,255,255,.10);border-radius:28px;background:rgba(255,255,255,.06);box-shadow:0 24px 80px rgba(0,0,0,.28)}.eyebrow{margin:0 0 10px;letter-spacing:.14em;text-transform:uppercase;font-size:12px;color:#b9c0ca}h1{margin:0;font-size:clamp(44px,7vw,86px);line-height:.95}.sub{max-width:680px;color:#c8ced8;font-size:18px;line-height:1.6}button,.button{display:inline-block;margin-top:14px;border:0;border-radius:999px;padding:13px 20px;background:#f7f7f8;color:#101216;font-weight:700;text-decoration:none;cursor:pointer}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;margin:18px 0}.card,.panel{border:1px solid rgba(255,255,255,.10);border-radius:24px;background:rgba(255,255,255,.055);padding:24px}.label{display:block;color:#aeb7c4;font-size:13px;text-transform:uppercase;letter-spacing:.12em}strong{display:block;margin:12px 0 6px;font-size:30px}small,.panel p{color:#c8ced8}pre{overflow:auto;background:rgba(0,0,0,.25);border-radius:16px;padding:16px;color:#dce3ee}@media(max-width:760px){.grid{grid-template-columns:1fr}.hero{padding:26px}}
CSS
  cat > "$WEB_ROOT/assets/app.js" <<'JS'
const $=id=>document.getElementById(id);function line(t){$('log').textContent+=`\n${new Date().toLocaleTimeString()}  ${t}`}async function latencyTest(){const s=[];for(let i=0;i<5;i++){const t0=performance.now();await fetch(`/assets/ping.txt?ts=${Date.now()}-${i}`,{cache:'no-store'});s.push(performance.now()-t0)}s.sort((a,b)=>a-b);return s[Math.floor(s.length/2)]}async function downloadTest(){const t0=performance.now();const r=await fetch(`/files/1mb.bin?ts=${Date.now()}`,{cache:'no-store'});const b=await r.blob();return b.size*8/((performance.now()-t0)/1000)/1000/1000}$('start').addEventListener('click',async()=>{$('log').textContent='Running diagnostics...';$('start').disabled=true;try{line('Latency test started');const ms=await latencyTest();$('latency').textContent=`${ms.toFixed(0)} ms`;line(`Median latency: ${ms.toFixed(1)} ms`);line('Download test started');const mbps=await downloadTest();$('download').textContent=`${mbps.toFixed(1)} Mbps`;line(`Estimated download: ${mbps.toFixed(2)} Mbps`);$('endpoint').textContent='Healthy';line('Diagnostics complete')}catch(e){$('endpoint').textContent='Error';line(`Error: ${e.message}`)}finally{$('start').disabled=false}});
JS
  printf 'pong\n' > "$WEB_ROOT/assets/ping.txt"
  printf 'User-agent: *\nDisallow: /internal/\n' > "$WEB_ROOT/robots.txt"
  printf '\000\000\001\000\001\000\020\020\000\000\001\000\040\000\000\000\000\000\026\000\000\000' > "$WEB_ROOT/favicon.ico"
  [[ -f "$WEB_ROOT/files/1mb.bin" ]] || dd if=/dev/urandom of="$WEB_ROOT/files/1mb.bin" bs=1M count=1 status=none
  cat > "$HY2_WEB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Speedtest</title><style>body{margin:0;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#111827;color:#f9fafb;display:grid;min-height:100vh;place-items:center}.card{max-width:680px;margin:24px;padding:40px;border:1px solid rgba(255,255,255,.12);border-radius:28px;background:rgba(255,255,255,.06);box-shadow:0 20px 80px rgba(0,0,0,.35)}h1{font-size:42px;margin:0 0 12px}p{line-height:1.7;color:#d1d5db}</style></head><body><main class="card"><h1>Speedtest 新站建设中</h1><p>该站点正在部署网络诊断与边缘测速功能。请稍后再访问。</p></main></body></html>
HTML
  cat > "$HY2_WEB_ROOT/404.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Not Found</title></head><body><h1>404 Not Found</h1></body></html>
HTML
  chown -R caddy:caddy "$WEB_ROOT" "$HY2_WEB_ROOT" 2>/dev/null || true
  chmod -R u=rwX,go=rX "$WEB_ROOT" "$HY2_WEB_ROOT"
}

hy2_masquerade_html() {
  cat <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Speedtest</title></head>
<body style="margin:0;font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#111827;color:#f9fafb;display:grid;min-height:100vh;place-items:center">
<main style="max-width:680px;margin:24px;padding:40px;border:1px solid rgba(255,255,255,.12);border-radius:28px;background:rgba(255,255,255,.06);box-shadow:0 20px 80px rgba(0,0,0,.35)">
<h1 style="font-size:42px;margin:0 0 12px">Speedtest 新站建设中</h1>
<p style="line-height:1.7;color:#d1d5db">该站点正在部署网络诊断与边缘测速功能。请稍后再访问。</p>
</main>
</body>
</html>
HTML
}

collect_fp() {
  echo "uTLS/客户端指纹：1) chrome  2) firefox"
  read -r -p "请选择 [默认 1]: " c
  case "${c:-1}" in 2) FP="firefox" ;; *) FP="chrome" ;; esac
}

collect_hy2_port() {
  ensure_port_tools
  echo
  echo "Hysteria2 端口模式："
  echo "  1) 端口跳跃 Port Hopping（默认，推荐）"
  echo "  2) 单端口"
  read -r -p "请选择 [默认 1]: " pm
  if [[ "${pm:-1}" == "2" ]]; then
    HY2_PORT_MODE="single"
    while true; do
      read -r -p "请输入 Hysteria2 UDP 端口 [回车随机 2000-65535，禁止 80/443/2053/8443]: " p
      [[ -z "$p" ]] && p="$(shuf -i 2000-65535 -n 1)"
      [[ "$p" =~ ^[0-9]+$ ]] || { warn "端口必须是数字。"; continue; }
      p=$((10#$p))
      (( p >= 1 && p <= 65535 )) || { warn "端口范围必须是 1-65535。"; continue; }
      hy2_reserved_port "$p" && { warn "端口 $p 被脚本禁止使用。"; continue; }
      port_in_use_udp "$p" && { warn "UDP $p 已被占用。"; continue; }
      HY2_PORT="$p"; HY2_FIRST_PORT=""; HY2_END_PORT=""; HY2_HOP_INTERVAL=""; HY2_MIN_HOP_INTERVAL=""; HY2_MAX_HOP_INTERVAL=""
      break
    done
  else
    HY2_PORT_MODE="hop"
    while true; do
      read -r -p "请输入起始/主端口 [默认随机 2500-10000]: " fp
      [[ -z "$fp" ]] && fp="$(shuf -i 2500-10000 -n 1)"
      [[ "$fp" =~ ^[0-9]+$ ]] || { warn "端口必须是数字。"; continue; }
      fp=$((10#$fp))
      (( fp >= 1 && fp < 65535 )) || { warn "起始端口必须是 1-65534。"; continue; }
      hy2_reserved_port "$fp" && { warn "端口 $fp 被脚本禁止使用。"; continue; }
      port_in_use_udp "$fp" && { warn "UDP $fp 已被占用。"; continue; }
      break
    done
    while true; do
      local def_end=$((fp+75)); (( def_end > 65535 )) && def_end=65535
      read -r -p "请输入结束端口 [默认 $def_end]: " ep
      ep="${ep:-$def_end}"
      [[ "$ep" =~ ^[0-9]+$ ]] || { warn "端口必须是数字。"; continue; }
      ep=$((10#$ep))
      (( ep > fp && ep <= 65535 )) || { warn "结束端口必须大于起始端口且不超过 65535。"; continue; }
      hy2_range_contains_reserved "$fp" "$ep" && { warn "端口范围 $fp-$ep 包含 80/443/2053/8443，禁止使用。"; continue; }
      local conflict=0 p
      for p in $(seq "$fp" "$ep"); do
        if port_in_use_udp "$p"; then conflict=1; warn "UDP $p 已被占用。"; break; fi
      done
      (( conflict == 0 )) || continue
      break
    done
    HY2_PORT="$fp"; HY2_FIRST_PORT="$fp"; HY2_END_PORT="$ep"
    echo "端口跳跃间隔：1) 固定 25s（默认）  2) 随机 15-25s"
    read -r -p "请选择 [默认 1]: " hi
    if [[ "${hi:-1}" == "2" ]]; then
      HY2_HOP_INTERVAL=""; HY2_MIN_HOP_INTERVAL="15"; HY2_MAX_HOP_INTERVAL="25"
    else
      HY2_HOP_INTERVAL="25"; HY2_MIN_HOP_INTERVAL=""; HY2_MAX_HOP_INTERVAL=""
    fi
  fi
}

collect_hy2_common() {
  read -r -p "Hysteria2 密码 [回车自动生成]: " hp
  HY2_PASSWORD="${hp:-$(generate_password)}"
  collect_hy2_port
}

find_caddy_cert_pair() {
  local domain="$1" cert key base
  base="${CADDY_DATA}/certificates"
  cert="$(find "$base" -type f -name "${domain}.crt" 2>/dev/null | sort | tail -n 1 || true)"
  key="$(find "$base" -type f -name "${domain}.key" 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "$cert" && -n "$key" && -s "$cert" && -s "$key" ]]; then
    echo "$cert|$key"
    return 0
  fi
  return 1
}

wait_for_caddy_cert() {
  local domain="$1" pair="" i
  log "等待 Caddy 为 ${domain} 签发/加载证书"
  for i in $(seq 1 60); do
    pair="$(find_caddy_cert_pair "$domain" || true)"
    if [[ -n "$pair" ]]; then
      HY2_CERT_PATH="${pair%%|*}"
      HY2_KEY_PATH="${pair#*|}"
      ok "找到证书：$HY2_CERT_PATH"
      return 0
    fi
    sleep 2
  done
  err "未能在 Caddy 存储中找到 ${domain} 的证书。请确认域名直连本机、TCP 80/443 放行，且 CDN 暂时关闭。"
  journalctl -u caddy --no-pager -n 100 >&2 || true
  exit 1
}

grant_cert_read_permissions() {
  local cert="$1" key="$2" user="hysteria"
  [[ -f "$cert" && -f "$key" ]] || return 0
  if id "$user" >/dev/null 2>&1 && cmd_exists setfacl; then
    local path dir cur part
    for path in "$cert" "$key"; do
      dir="$(dirname "$(readlink -f "$path")")"; cur=""
      IFS='/' read -ra parts <<< "$dir"
      for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        cur="$cur/$part"
        setfacl -m u:${user}:--x "$cur" 2>/dev/null || true
      done
    done
    setfacl -m u:${user}:r "$(readlink -f "$cert")" "$(readlink -f "$key")" 2>/dev/null || true
    setfacl -d -m u:${user}:r "$(dirname "$(readlink -f "$cert")")" 2>/dev/null || true
    setfacl -d -m u:${user}:r "$(dirname "$(readlink -f "$key")")" 2>/dev/null || true
  else
    # Fallback only. This does not move/copy certs; it only grants read/traverse permission.
    chmod o+x /var /var/lib /var/lib/caddy /var/lib/caddy/.local /var/lib/caddy/.local/share /var/lib/caddy/.local/share/caddy /var/lib/caddy/.local/share/caddy/certificates 2>/dev/null || true
    chmod o+r "$cert" "$key" 2>/dev/null || true
  fi
}

write_xhttp_xray_config() {
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  backup_file "$XRAY_CONFIG"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-xhttp-in",
      "listen": "127.0.0.1",
      "port": ${XHTTP_BACKEND_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${XHTTP_UUID}", "email": "xhttp@${XHTTP_DOMAIN}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto",
          "extra": { "xPaddingBytes": "100-1000" }
        }
      }
    }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ]
}
JSON
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/tmp/xray-test.log 2>&1 || { err "Xray 配置测试失败"; cat /tmp/xray-test.log; exit 1; }
}

write_reality_xray_config() {
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  backup_file "$XRAY_CONFIG"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-vision-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision", "email": "reality" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ "${REALITY_SHORT_ID}" ]
        }
      }
    }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ]
}
JSON
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/tmp/xray-test.log 2>&1 || { err "Xray REALITY 配置测试失败"; cat /tmp/xray-test.log; exit 1; }
}

write_caddyfile_xhttp_hy2() {
  mkdir -p /etc/caddy
  backup_file "$CADDYFILE"
  cat > "$CADDYFILE" <<CADDY
${XHTTP_DOMAIN} {
    encode zstd gzip
    header {
        -Server
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer-when-downgrade"
    }
    @xhttp path ${XHTTP_PATH} ${XHTTP_PATH}/*
    handle @xhttp {
        reverse_proxy h2c://127.0.0.1:${XHTTP_BACKEND_PORT} {
            flush_interval -1
        }
    }
    handle {
        root * ${WEB_ROOT}
        file_server
    }
    handle_errors {
        root * ${WEB_ROOT}
        rewrite * /404.html
        file_server
    }
}

${HY2_DOMAIN} {
    encode zstd gzip
    header {
        -Server
    }
    root * ${HY2_WEB_ROOT}
    file_server
    handle_errors {
        root * ${HY2_WEB_ROOT}
        rewrite * /404.html
        file_server
    }
}
CADDY
  caddy validate --config "$CADDYFILE" >/tmp/caddy-validate.log 2>&1 || { err "Caddyfile 校验失败"; cat /tmp/caddy-validate.log; exit 1; }
}

write_caddyfile_naive_hy2() {
  mkdir -p /etc/caddy
  backup_file "$CADDYFILE"
  cat > "$CADDYFILE" <<CADDY
{
    order forward_proxy before file_server
    log {
        exclude http.log.error
    }
}

${NAIVE_DOMAIN} {
    encode zstd gzip
    header {
        -Server
    }

    forward_proxy {
        basic_auth ${NAIVE_USER} ${NAIVE_PASS}
        hide_ip
        hide_via
        probe_resistance
    }

    root * ${WEB_ROOT}
    file_server

    handle_errors {
        root * ${WEB_ROOT}
        rewrite * /404.html
        file_server
    }
}
CADDY
  caddy validate --config "$CADDYFILE" >/tmp/caddy-validate.log 2>&1 || { err "Naive Caddyfile 校验失败"; cat /tmp/caddy-validate.log; exit 1; }
}

hy2_listen_value() {
  if [[ "${HY2_PORT_MODE}" == "hop" ]]; then
    echo ":${HY2_FIRST_PORT}-${HY2_END_PORT}"
  else
    echo ":${HY2_PORT}"
  fi
}

write_hy2_config_tls() {
  mkdir -p /etc/hysteria
  local certq keyq pwdq listen
  listen="$(hy2_listen_value)"
  certq="$(yaml_quote "$HY2_CERT_PATH")"; keyq="$(yaml_quote "$HY2_KEY_PATH")"; pwdq="$(yaml_quote "$HY2_PASSWORD")"
  cat > "$HY2_CONFIG" <<YAML
listen: ${listen}

tls:
  cert: ${certq}
  key: ${keyq}

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: ${pwdq}

bandwidth:
  up: 100 mbps
  down: 100 mbps

masquerade:
  type: string
  string:
    content: |
$(hy2_masquerade_html | sed 's/^/      /')
    headers:
      content-type: text/html; charset=utf-8
      server: nginx
    statusCode: 200
YAML
}

write_hy2_config_acme() {
  mkdir -p /etc/hysteria
  local pwdq emailq listen domainq
  listen="$(hy2_listen_value)"
  pwdq="$(yaml_quote "$HY2_PASSWORD")"; emailq="$(yaml_quote "$HY2_ACME_EMAIL")"; domainq="$(yaml_quote "$HY2_DOMAIN")"
  cat > "$HY2_CONFIG" <<YAML
listen: ${listen}

acme:
  domains:
    - ${domainq}
  email: ${emailq}
  ca: letsencrypt
  type: http
  http:
    altPort: 80

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: ${pwdq}

bandwidth:
  up: 100 mbps
  down: 100 mbps

masquerade:
  type: string
  string:
    content: |
$(hy2_masquerade_html | sed 's/^/      /')
    headers:
      content-type: text/html; charset=utf-8
      server: nginx
    statusCode: 200
YAML
}

write_service_restart_override() {
  local svc="$1"
  local dir="/etc/systemd/system/${svc}.service.d"
  local file="${dir}/jb-combo-restart.conf"
  mkdir -p "$dir"
  cat > "$file" <<'EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Restart=on-failure
RestartSec=5s
EOF
}

ensure_service_resilience() {
  local svc
  for svc in "$@"; do
    [[ -n "$svc" ]] || continue
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service" || [[ -f "/etc/systemd/system/${svc}.service" || -f "/lib/systemd/system/${svc}.service" || -f "/usr/lib/systemd/system/${svc}.service" ]]; then
      write_service_restart_override "$svc"
    fi
  done
  systemctl daemon-reload
}

remove_service_resilience_overrides() {
  local svc dir file
  for svc in caddy xray hysteria-server; do
    dir="/etc/systemd/system/${svc}.service.d"
    file="${dir}/jb-combo-restart.conf"
    rm -f "$file" 2>/dev/null || true
    rmdir "$dir" 2>/dev/null || true
  done
}

start_xray() {
  ensure_service_resilience xray
  systemctl enable --now xray
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || { err "Xray 启动失败"; journalctl -u xray --no-pager -n 100; exit 1; }
}

start_caddy() {
  ensure_service_resilience caddy
  systemctl enable --now caddy
  systemctl restart caddy
  sleep 2
  systemctl is-active --quiet caddy || { err "Caddy 启动失败"; journalctl -u caddy --no-pager -n 120; exit 1; }
}

start_hy2() {
  ensure_hysteria_capabilities
  ensure_service_resilience hysteria-server
  systemctl enable --now hysteria-server
  systemctl restart hysteria-server
  sleep 3
  systemctl is-active --quiet hysteria-server || { err "Hysteria2 启动失败"; journalctl -u hysteria-server --no-pager -n 120; exit 1; }
}

generate_hy2_outputs() {
  mkdir -p "$OUT_DIR"
  local server_host server_port_string auth_enc sni_enc link insecure="0"
  server_host="$HY2_DOMAIN"
  if [[ "$HY2_PORT_MODE" == "hop" ]]; then
    server_port_string="${HY2_FIRST_PORT}-${HY2_END_PORT}"
  else
    server_port_string="${HY2_PORT}"
  fi
  auth_enc="$(urlencode "$HY2_PASSWORD")"
  sni_enc="$(urlencode "$HY2_DOMAIN")"
  if [[ "$HY2_PORT_MODE" == "hop" ]]; then
    if [[ -n "${HY2_MIN_HOP_INTERVAL:-}" && -n "${HY2_MAX_HOP_INTERVAL:-}" ]]; then
      link="hysteria2://${auth_enc}@${server_host}:${HY2_PORT}?security=tls&mport=${HY2_FIRST_PORT}-${HY2_END_PORT}&mportHopInt=${HY2_MIN_HOP_INTERVAL}-${HY2_MAX_HOP_INTERVAL}&insecure=${insecure}&sni=${sni_enc}#$(urlencode "${HY2_DOMAIN} HY2")"
    else
      link="hysteria2://${auth_enc}@${server_host}:${HY2_PORT}?security=tls&mport=${HY2_FIRST_PORT}-${HY2_END_PORT}&mportHopInt=${HY2_HOP_INTERVAL:-25}&insecure=${insecure}&sni=${sni_enc}#$(urlencode "${HY2_DOMAIN} HY2")"
    fi
  else
    link="hysteria2://${auth_enc}@${server_host}:${HY2_PORT}?security=tls&insecure=${insecure}&sni=${sni_enc}#$(urlencode "${HY2_DOMAIN} HY2")"
  fi
  echo "$link" > "${OUT_DIR}/hy2-url.txt"

  cat > "$HY2_CLIENT_YAML" <<YAML
server: '${server_host}:${server_port_string}'
auth: '$(printf "%s" "$HY2_PASSWORD" | sed "s/'/''/g")'
tls:
  sni: '${HY2_DOMAIN}'
  insecure: false
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
socks5:
  listen: 127.0.0.1:5678
YAML
  if [[ "$HY2_PORT_MODE" == "hop" ]]; then
    cat >> "$HY2_CLIENT_YAML" <<YAML
transport:
  type: udp
  udp:
YAML
    if [[ -n "${HY2_MIN_HOP_INTERVAL:-}" && -n "${HY2_MAX_HOP_INTERVAL:-}" ]]; then
      cat >> "$HY2_CLIENT_YAML" <<YAML
    minHopInterval: ${HY2_MIN_HOP_INTERVAL}s
    maxHopInterval: ${HY2_MAX_HOP_INTERVAL}s
YAML
    else
      cat >> "$HY2_CLIENT_YAML" <<YAML
    hopInterval: ${HY2_HOP_INTERVAL:-25}s
YAML
    fi
  fi

  HY2_JSON_FILE="$HY2_CLIENT_JSON" \
  HY2_JSON_SERVER="${server_host}:${server_port_string}" \
  HY2_JSON_AUTH="$HY2_PASSWORD" \
  HY2_JSON_SNI="$HY2_DOMAIN" \
  HY2_JSON_PORT_MODE="$HY2_PORT_MODE" \
  HY2_JSON_HOP_INTERVAL="${HY2_HOP_INTERVAL:-25}" \
  HY2_JSON_MIN_HOP_INTERVAL="${HY2_MIN_HOP_INTERVAL:-}" \
  HY2_JSON_MAX_HOP_INTERVAL="${HY2_MAX_HOP_INTERVAL:-}" \
  python3 - <<'PY'
import json, os
obj = {
    "server": os.environ["HY2_JSON_SERVER"],
    "auth": os.environ["HY2_JSON_AUTH"],
    "tls": {"sni": os.environ["HY2_JSON_SNI"], "insecure": False},
    "quic": {
        "initStreamReceiveWindow": 16777216,
        "maxStreamReceiveWindow": 16777216,
        "initConnReceiveWindow": 33554432,
        "maxConnReceiveWindow": 33554432,
    },
    "socks5": {"listen": "127.0.0.1:5678"},
}
if os.environ["HY2_JSON_PORT_MODE"] == "hop":
    udp = {}
    min_i = os.environ.get("HY2_JSON_MIN_HOP_INTERVAL", "")
    max_i = os.environ.get("HY2_JSON_MAX_HOP_INTERVAL", "")
    if min_i and max_i:
        udp["minHopInterval"] = f"{min_i}s"
        udp["maxHopInterval"] = f"{max_i}s"
    else:
        udp["hopInterval"] = f"{os.environ.get('HY2_JSON_HOP_INTERVAL', '25')}s"
    obj["transport"] = {"type": "udp", "udp": udp}
with open(os.environ["HY2_JSON_FILE"], "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

generate_main_outputs() {
  mkdir -p "$OUT_DIR"
  local main_link="" name_enc path_enc extra extra_enc
  case "$MAIN_MODE" in
    xhttp)
      path_enc="$(urlencode "$XHTTP_PATH")"; extra='{"xPaddingBytes":"100-1000"}'; extra_enc="$(urlencode "$extra")"; name_enc="$(urlencode "${NODE_NAME:-${XHTTP_DOMAIN} XHTTP}")"
      main_link="vless://${XHTTP_UUID}@${XHTTP_DOMAIN}:443?mode=auto&path=${path_enc}&security=tls&alpn=h2&encryption=none&extra=${extra_enc}&insecure=0&host=${XHTTP_DOMAIN}&fp=${FP}&type=xhttp&allowInsecure=0&sni=${XHTTP_DOMAIN}#${name_enc}"
      cat > "$XRAY_CLIENT_JSON" <<JSON
{
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": { "vnext": [ { "address": "${XHTTP_DOMAIN}", "port": 443, "users": [ { "id": "${XHTTP_UUID}", "encryption": "none" } ] } ] },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": { "serverName": "${XHTTP_DOMAIN}", "allowInsecure": false, "alpn": ["h2"], "fingerprint": "${FP}" },
        "xhttpSettings": { "host": "${XHTTP_DOMAIN}", "path": "${XHTTP_PATH}", "mode": "auto", "extra": { "xPaddingBytes": "100-1000" } }
      }
    }
  ]
}
JSON
      ;;
    naive)
      name_enc="$(urlencode "${NODE_NAME:-${NAIVE_DOMAIN} Naive}")"
      main_link="naive+https://${NAIVE_USER}:$(urlencode "$NAIVE_PASS")@${NAIVE_DOMAIN}:443#${name_enc}"
      cat > "$XRAY_CLIENT_JSON" <<JSON
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASS}@${NAIVE_DOMAIN}:443"
}
JSON
      ;;
    reality)
      local reality_uri_host
      reality_uri_host="$(uri_host "$REALITY_ADDRESS")"
      name_enc="$(urlencode "${NODE_NAME:-REALITY Vision}")"
      main_link="vless://${REALITY_UUID}@${reality_uri_host}:443?encryption=none&security=reality&sni=${REALITY_SNI}&fp=${FP}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision&spx=%2F#${name_enc}"
      cat > "$XRAY_CLIENT_JSON" <<JSON
{
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": { "vnext": [ { "address": "${REALITY_ADDRESS}", "port": 443, "users": [ { "id": "${REALITY_UUID}", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": { "serverName": "${REALITY_SNI}", "fingerprint": "${FP}", "publicKey": "${REALITY_PUBLIC_KEY}", "shortId": "${REALITY_SHORT_ID}", "spiderX": "/" }
      }
    }
  ]
}
JSON
      ;;
  esac
  echo "$main_link" > "${OUT_DIR}/main-url.txt"
  generate_hy2_outputs
  cat > "$INFO_FILE" <<EOF
组合模式: ${STACK_MODE}
主节点模式: ${MAIN_MODE}
管理命令: jb

主节点链接:
${main_link}

Hysteria2 链接:
$(cat "${OUT_DIR}/hy2-url.txt")

主节点客户端 JSON: ${XRAY_CLIENT_JSON}
Hysteria2 客户端 YAML: ${HY2_CLIENT_YAML}
Hysteria2 客户端 JSON: ${HY2_CLIENT_JSON}

服务状态命令:
systemctl status xray --no-pager
systemctl status caddy --no-pager
systemctl status hysteria-server --no-pager
EOF
}

collect_xhttp_hy2_inputs() {
  warn "请先确保两个域名都 A/AAAA 直连本服务器，暂时不要开启 CDN，且 TCP 80/443 放行。"
  pause_confirm "确认后按回车继续..."
  XHTTP_DOMAIN="$(prompt_domain "请输入 XHTTP 域名")"
  while true; do
    HY2_DOMAIN="$(prompt_domain "请输入 Hysteria2 域名（必须不同于 XHTTP 域名）")"
    [[ "$HY2_DOMAIN" != "$XHTTP_DOMAIN" ]] && break
    warn "XHTTP + HY2 组合要求两个不同域名。"
  done
  XHTTP_UUID="$(new_uuid)"
  local def_path="/${XHTTP_UUID:0:8}" p
  while true; do
    read -r -p "请输入 XHTTP 路径 [默认 ${def_path}]: " p
    p="${p:-$def_path}"
    if XHTTP_PATH="$(normalize_path "$p")"; then break; fi
    warn "路径格式不正确。"
  done
  XHTTP_BACKEND_PORT="$(find_free_local_port)"
  collect_fp
  read -r -p "节点名称 [默认 ${XHTTP_DOMAIN} XHTTP + HY2]: " n
  NODE_NAME="${n:-${XHTTP_DOMAIN} XHTTP + HY2}"
  collect_hy2_common
  MAIN_MODE="xhttp"; STACK_MODE="xhttp_hy2"; MAIN_DOMAIN="$XHTTP_DOMAIN"; CADDY_REQUIRED="1"; WEB_ENABLED="1"; HY2_CERT_SOURCE="caddy"; MANAGED_DOMAINS="$XHTTP_DOMAIN $HY2_DOMAIN"
}

collect_naive_hy2_inputs() {
  warn "请先确保域名 A/AAAA 直连本服务器，暂时不要开启 CDN，且 TCP 80/443 放行。"
  pause_confirm "确认后按回车继续..."
  NAIVE_DOMAIN="$(prompt_domain "请输入 Naive/Hysteria2 共用域名")"
  HY2_DOMAIN="$NAIVE_DOMAIN"
  NAIVE_USER="u$(openssl rand -hex 4)"
  NAIVE_PASS="$(generate_password)"
  read -r -p "节点名称 [默认 ${NAIVE_DOMAIN} Naive + HY2]: " n
  NODE_NAME="${n:-${NAIVE_DOMAIN} Naive + HY2}"
  collect_hy2_common
  MAIN_MODE="naive"; STACK_MODE="naive_hy2"; MAIN_DOMAIN="$NAIVE_DOMAIN"; CADDY_REQUIRED="1"; WEB_ENABLED="1"; HY2_CERT_SOURCE="caddy"; MANAGED_DOMAINS="$NAIVE_DOMAIN"
}

collect_reality_hy2_inputs() {
  warn "REALITY 占用 TCP 443，不安装 Caddy，不申请网页证书。HY2 使用自身 ACME，需要 TCP 80 空闲且 HY2 域名直连本机。"
  pause_confirm "确认后按回车继续..."
  REALITY_ADDRESS="$(public_ip)"
  REALITY_ADDRESS="$(prompt_host_address "请输入 REALITY 连接地址（VPS IP 或域名）" "$REALITY_ADDRESS")"
  REALITY_SNI="$(prompt_domain "请输入 REALITY 目标 SNI" "nokia.com")"
  collect_fp
  REALITY_UUID="$(new_uuid)"
  generate_reality_x25519_keys
  REALITY_SHORT_ID="$(generate_shortid)"
  HY2_DOMAIN="$(prompt_domain "请输入 Hysteria2 ACME 域名")"
  HY2_ACME_EMAIL="acme-$(date +%s)@gmail.com"
  read -r -p "ACME 邮箱 [默认 ${HY2_ACME_EMAIL}]: " he
  HY2_ACME_EMAIL="${he:-$HY2_ACME_EMAIL}"
  read -r -p "节点名称 [默认 REALITY + HY2]: " n
  NODE_NAME="${n:-REALITY + HY2}"
  collect_hy2_common
  MAIN_MODE="reality"; STACK_MODE="reality_hy2"; MAIN_DOMAIN="$REALITY_ADDRESS"; CADDY_REQUIRED="0"; WEB_ENABLED="0"; HY2_CERT_SOURCE="acme"; MANAGED_DOMAINS="$HY2_DOMAIN"
}

install_stack_xhttp_hy2() {
  install_base_packages
  ensure_tcp_80_443_free_for_caddy
  install_caddy_official
  install_xray_official
  install_hysteria_official
  create_speedtest_site
  write_xhttp_xray_config
  write_caddyfile_xhttp_hy2
  start_xray
  start_caddy
  wait_for_caddy_cert "$HY2_DOMAIN"
  grant_cert_read_permissions "$HY2_CERT_PATH" "$HY2_KEY_PATH"
  write_hy2_config_tls
  start_hy2
  save_state
  generate_main_outputs
  install_self_command
}

install_stack_naive_hy2() {
  install_base_packages
  ensure_tcp_80_443_free_for_caddy
  install_naive_caddy
  install_hysteria_official
  create_speedtest_site
  write_caddyfile_naive_hy2
  start_caddy
  wait_for_caddy_cert "$HY2_DOMAIN"
  grant_cert_read_permissions "$HY2_CERT_PATH" "$HY2_KEY_PATH"
  write_hy2_config_tls
  systemctl disable --now xray >/dev/null 2>&1 || true
  start_hy2
  save_state
  generate_main_outputs
  install_self_command
}

install_stack_reality_hy2() {
  install_base_packages
  ensure_tcp_443_free_for_reality
  if port_in_use_tcp 80; then
    warn "HY2 ACME HTTP-01 需要 TCP 80 空闲。当前 TCP 80 被占用。"
    show_port_users
    read -r -p "是否停止常见服务释放 TCP 80？[y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { err "请先释放 TCP 80。"; exit 1; }
    stop_known_services
    sleep 2
    if port_in_use_tcp 80; then
      err "TCP 80 仍被占用，HY2 ACME HTTP-01 无法签发证书。"
      show_port_users
      exit 1
    fi
  fi
  install_xray_official
  install_hysteria_official
  write_reality_xray_config
  write_hy2_config_acme
  systemctl disable --now caddy >/dev/null 2>&1 || true
  start_xray
  start_hy2
  save_state
  generate_main_outputs
  install_self_command
}

install_selected_stack() {
  case "$STACK_MODE" in
    xhttp_hy2) install_stack_xhttp_hy2 ;;
    naive_hy2) install_stack_naive_hy2 ;;
    reality_hy2) install_stack_reality_hy2 ;;
    *) err "未知 STACK_MODE: $STACK_MODE"; exit 1 ;;
  esac
  print_result
}

cleanup_managed_caddy_certs() {
  load_state || true
  local d base
  base="${CADDY_DATA}/certificates"
  [[ -d "$base" ]] || return 0
  for d in ${MANAGED_DOMAINS:-}; do
    [[ -n "$d" ]] || continue
    find "$base" -type d -name "$d" -prune -exec rm -rf {} + 2>/dev/null || true
  done
}

uninstall_current_stack() {
  load_state || return 0
  warn "正在卸载当前组合：${STACK_MODE:-unknown}"
  systemctl stop xray caddy hysteria-server >/dev/null 2>&1 || true
  systemctl disable xray caddy hysteria-server >/dev/null 2>&1 || true
  remove_service_resilience_overrides
  cleanup_managed_caddy_certs
  rm -f "$XRAY_CONFIG" "$HY2_CONFIG" "$CADDYFILE"
  rm -rf "$WEB_ROOT" "$HY2_WEB_ROOT" "$OUT_DIR"
  rm -rf /etc/hysteria
  # Remove service/binary pieces installed by official installers; reinstallers will put them back when needed.
  rm -f /usr/local/bin/hysteria
  rm -f /etc/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server.service
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /lib/systemd/system/xray.service /lib/systemd/system/xray@.service
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  if [[ "${CADDY_REQUIRED:-0}" == "1" ]]; then
    apt-get purge -y caddy >/dev/null 2>&1 || true
    rm -f /usr/bin/caddy
    rm -rf /etc/caddy
  fi
  systemctl daemon-reload
  rm -f "$STATE_FILE"
  ok "当前组合已卸载。"
}

full_uninstall() {
  if load_state; then
    echo "当前组合：${STACK_MODE:-unknown}"
  fi
  read -r -p "确认彻底卸载脚本安装的一切？输入 YES 继续: " ans
  [[ "$ans" == "YES" ]] || { warn "已取消。"; return 0; }
  uninstall_current_stack || true
  apt-get purge -y caddy >/dev/null 2>&1 || true
  if [[ -e "$JB_CMD_FALLBACK" && "$(readlink -f "$JB_CMD_FALLBACK" 2>/dev/null || true)" == "$(readlink -f "$JB_CMD" 2>/dev/null || true)" ]]; then
    rm -f "$JB_CMD_FALLBACK"
  fi
  rm -f /usr/bin/caddy "$JB_CMD" "$THIS_SCRIPT"
  rm -rf "$STATE_DIR"
  ok "彻底卸载完成。"
}

choose_stack_initial() {
  echo
  echo "请选择要安装的组合："
  echo "  1) VLESS + XHTTP + TLS  + Hysteria2"
  echo "  2) NaiveProxy           + Hysteria2"
  echo "  3) VLESS + REALITY + Vision + Hysteria2"
  while true; do
    read -r -p "请输入选项 [1-3]: " ch
    case "$ch" in
      1) collect_xhttp_hy2_inputs; break ;;
      2) collect_naive_hy2_inputs; break ;;
      3) install_base_packages; install_xray_official; collect_reality_hy2_inputs; break ;;
      *) warn "请输入 1-3。" ;;
    esac
  done
}

switch_to_stack() {
  local target="$1"
  load_state || true
  warn "即将卸载当前组合并安装：$target"
  read -r -p "输入 SWITCH 确认: " ans
  [[ "$ans" == "SWITCH" ]] || { warn "已取消。"; return 0; }
  uninstall_current_stack || true
  case "$target" in
    xhttp_hy2) collect_xhttp_hy2_inputs ;;
    naive_hy2) collect_naive_hy2_inputs ;;
    reality_hy2) install_base_packages; install_xray_official; collect_reality_hy2_inputs ;;
  esac
  install_selected_stack
}

change_hy2_password() {
  load_state || return 1
  read -r -p "新 HY2 密码 [回车自动生成]: " p
  HY2_PASSWORD="${p:-$(generate_password)}"
  if [[ "$HY2_CERT_SOURCE" == "acme" ]]; then write_hy2_config_acme; else write_hy2_config_tls; fi
  save_state; generate_main_outputs; start_hy2
  ok "HY2 密码已更新。"
}

change_hy2_port() {
  load_state || return 1
  collect_hy2_port
  if [[ "$HY2_CERT_SOURCE" == "acme" ]]; then write_hy2_config_acme; else write_hy2_config_tls; fi
  save_state; generate_main_outputs; start_hy2
  ok "HY2 端口已更新。"
}

change_xhttp_path() {
  load_state || return 1
  [[ "$MAIN_MODE" == "xhttp" ]] || { warn "当前不是 XHTTP 模式。"; return 0; }
  local p
  while true; do
    read -r -p "请输入新 XHTTP 路径: " p
    if XHTTP_PATH="$(normalize_path "$p")"; then break; fi
    warn "路径格式不正确。"
  done
  write_xhttp_xray_config; write_caddyfile_xhttp_hy2; save_state; generate_main_outputs; start_xray; start_caddy
  ok "XHTTP 路径已更新。"
}

regen_main_uuid_or_credential() {
  load_state || return 1
  case "$MAIN_MODE" in
    xhttp)
      XHTTP_UUID="$(new_uuid)"; write_xhttp_xray_config; start_xray ;;
    reality)
      REALITY_UUID="$(new_uuid)"; write_reality_xray_config; start_xray ;;
    naive)
      NAIVE_USER="u$(openssl rand -hex 4)"; NAIVE_PASS="$(generate_password)"; write_caddyfile_naive_hy2; start_caddy ;;
  esac
  save_state; generate_main_outputs
  ok "主节点凭据已重新生成。"
}

change_fp() {
  load_state || return 1
  case "$MAIN_MODE" in xhttp|reality) collect_fp ;; *) warn "Naive 无 uTLS 指纹设置。"; return 0 ;; esac
  save_state; generate_main_outputs
  ok "客户端指纹参数已更新。"
}

change_reality_target() {
  load_state || return 1
  [[ "$MAIN_MODE" == "reality" ]] || { warn "当前不是 REALITY 模式。"; return 0; }
  REALITY_ADDRESS="$(prompt_host_address "新的 REALITY 连接地址" "$REALITY_ADDRESS")"
  REALITY_SNI="$(prompt_domain "新的 REALITY 目标 SNI" "$REALITY_SNI")"
  generate_reality_x25519_keys
  REALITY_SHORT_ID="$(generate_shortid)"
  write_reality_xray_config; save_state; generate_main_outputs; start_xray
  ok "REALITY 目标和密钥已更新。"
}

show_info() {
  load_state || { warn "尚未安装。"; return 0; }
  echo
  echo "当前组合：${STACK_MODE}"
  echo "主节点：${MAIN_MODE}"
  echo "管理域名：${MANAGED_DOMAINS:-无}"
  echo
  [[ -f "${OUT_DIR}/main-url.txt" ]] && { echo "主节点链接："; cat "${OUT_DIR}/main-url.txt"; echo; }
  [[ -f "${OUT_DIR}/hy2-url.txt" ]] && { echo "Hysteria2 链接："; cat "${OUT_DIR}/hy2-url.txt"; echo; }
  echo "详情文件：$INFO_FILE"
}

restart_all() {
  load_state || return 1
  case "${MAIN_MODE}" in
    xhttp|reality) ensure_service_resilience xray ;;
    naive) ensure_service_resilience caddy ;;
  esac
  if [[ "${CADDY_REQUIRED:-0}" == "1" ]]; then ensure_service_resilience caddy; fi
  ensure_service_resilience hysteria-server
  case "${MAIN_MODE}" in
    xhttp|reality) systemctl restart xray >/dev/null 2>&1 || true ;;
    naive) systemctl restart caddy >/dev/null 2>&1 || true ;;
  esac
  if [[ "${CADDY_REQUIRED:-0}" == "1" ]]; then systemctl restart caddy >/dev/null 2>&1 || true; fi
  systemctl restart hysteria-server >/dev/null 2>&1 || true
  sleep 2
  systemctl is-active --quiet hysteria-server && ok "Hysteria2 正常" || warn "Hysteria2 异常"
  if [[ "${MAIN_MODE}" =~ ^(xhttp|reality)$ ]]; then systemctl is-active --quiet xray && ok "Xray 正常" || warn "Xray 异常"; fi
  if [[ "${CADDY_REQUIRED:-0}" == "1" ]]; then systemctl is-active --quiet caddy && ok "Caddy 正常" || warn "Caddy 异常"; fi
}

menu() {
  require_root; check_os
  if ! load_state; then
    warn "尚未安装任何组合。"
    choose_stack_initial
    install_selected_stack
    exit 0
  fi
  while true; do
    echo
    echo "================ jb 组合节点控制面板 ================"
    echo "当前组合：${STACK_MODE}"
    echo "1) 查看节点信息/分享链接"
    echo "2) 重新生成主节点凭据（UUID 或 Naive 用户密码）"
    echo "3) 修改 XHTTP 路径（仅 XHTTP）"
    echo "4) 修改 uTLS 指纹（XHTTP/REALITY）"
    echo "5) 修改 REALITY 连接地址/目标 SNI，并重生成密钥"
    echo "6) 修改 Hysteria2 密码"
    echo "7) 修改 Hysteria2 端口/端口跳跃"
    echo "8) 重启并检查服务"
    echo "9) 卸载当前组合并安装 XHTTP + HY2"
    echo "10) 卸载当前组合并安装 Naive + HY2"
    echo "11) 卸载当前组合并安装 REALITY + Vision + HY2"
    echo "12) 彻底卸载"
    echo "0) 退出"
    read -r -p "请选择: " ch
    case "$ch" in
      1) show_info ;;
      2) regen_main_uuid_or_credential ;;
      3) change_xhttp_path ;;
      4) change_fp ;;
      5) change_reality_target ;;
      6) change_hy2_password ;;
      7) change_hy2_port ;;
      8) restart_all ;;
      9) switch_to_stack xhttp_hy2 ;;
      10) switch_to_stack naive_hy2 ;;
      11) switch_to_stack reality_hy2 ;;
      12) full_uninstall; exit 0 ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

print_result() {
  echo
  echo -e "${GREEN}================ 部署完成 ================${NC}"
  echo "组合模式：${STACK_MODE}"
  echo "管理命令：jb"
  echo
  echo "主节点链接："
  cat "${OUT_DIR}/main-url.txt"
  echo
  echo "Hysteria2 链接："
  cat "${OUT_DIR}/hy2-url.txt"
  echo
  echo "详情文件：$INFO_FILE"
  echo
  warn "注意："
  if [[ "${CADDY_REQUIRED:-0}" == "1" ]]; then
    echo "1) Caddy 负责证书签发/续签；HY2 只读 Caddy 证书路径，不复制、不搬动证书。"
    echo "2) 首次签发前请保持域名直连本机，暂时不要开启 CDN。"
    echo "3) 若后续开启 CDN，续签取决于 ACME HTTP-01 是否能正确回源到 Caddy。"
  else
    echo "1) REALITY 使用 TCP 443，不安装 Caddy，不需要网页证书。"
    echo "2) HY2 使用自身 ACME，HY2 域名需要直连本机，TCP 80 需要空闲。"
  fi
  echo "4) HY2 UDP 端口/端口范围已避开 80、443、2053、8443。"
  echo "5) 已为相关 systemd 服务写入异常退出自动重启策略：Restart=on-failure，RestartSec=5s。"
}

main() {
  require_root
  check_os
  install_self_command || true
  if [[ "${1:-}" == "menu" ]]; then menu; exit 0; fi
  if load_state; then
    warn "检测到已安装组合：${STACK_MODE}。输入 jb 进入控制面板，或选择切换/卸载。"
    menu
    exit 0
  fi
  choose_stack_initial
  install_selected_stack
}

main "$@"
