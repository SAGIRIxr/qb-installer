#!/bin/bash
#
# qb-installer — standalone qBittorrent installer (interactive OR flag-driven)
# -----------------------------------------------------------------------------
# Installs ONLY qBittorrent (precompiled qbittorrent-nox) with a WebUI.
# It does NOT touch sysctl / kernel settings, does NOT install BBR, and does
# NOT install any other seedbox component. Just qBittorrent.
#
# The qbittorrent-nox binary is pulled from the same place the full seedbox
# installer uses: SAGIRIxr/Seedbox-Components-P.
#
# Run with no options for a fully interactive install, or pass options to skip
# the matching prompt (anything still missing is asked interactively):
#   bash <(wget -qO- https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main/install.sh)
#   bash <(wget -qO- .../install.sh) -u alice -p 's3cret' -c 2048 -q 5.0.5 -l v1.2.20 -s x64_v3 -y
# -----------------------------------------------------------------------------
set -o pipefail

BIN_REPO="SAGIRIxr/Seedbox-Components-P"
BIN_BASE="https://raw.githubusercontent.com/${BIN_REPO}/main/Torrent%20Clients/qBittorrent"
API_BASE="https://api.github.com/repos/${BIN_REPO}/contents/Torrent%20Clients/qBittorrent"
SELF_RAW="https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main"

# ---------- pretty output ----------
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
info(){ echo "${GRN}[*]${RST} $*"; }
warn(){ echo "${YLW}[!]${RST} $*" >&2; }
err(){  echo "${RED}[x]${RST} $*" >&2; }
ask(){  echo -ne "${CYN}[?]${RST} $*"; }
die(){  err "$*"; exit 1; }

# read always from the real terminal so the script also works when launched as
#   bash <(wget -qO- ...)
rd(){ read -r "$@" </dev/tty; }

usage(){
cat <<USAGE
qb-installer — 只安装 qBittorrent（不做系统调优，不装 BBR）。

用法:
  bash <(wget -qO- ${SELF_RAW}/install.sh) [选项]

不带任何选项即为全交互安装。给出下面任意选项可跳过对应的提问；仍然缺少的项会
交互询问（若主机没有终端，则报错退出，使无人值守运行明确失败）。

选项:
  -u <用户名>   WebUI 用户名
  -p <密码>     WebUI 密码
  -c <MiB>      磁盘缓存大小，单位 MiB（如 2048）
  -d <路径>     下载路径（默认: /home/<用户>/qbittorrent/Downloads）
  -q <版本>     qBittorrent 版本（如 5.0.5）
  -l <版本>     libtorrent 版本（如 v1.2.20 或 1_1_14）
  -s <后缀>     构建后缀 / CPU 优化（如 x64_v3），没有就不填
  -w <端口>     WebUI 端口（默认: 8080）
  -i <端口>     入站 / BT 端口（默认: 45000）
  -y            假定 yes：跳过最后的确认提示
  -h            显示此帮助并退出

示例:
  # 交互式
  bash <(wget -qO- ${SELF_RAW}/install.sh)
  # 全自动无人值守
  bash <(wget -qO- ${SELF_RAW}/install.sh) -u alice -p 's3cret' -c 2048 -q 5.0.5 -l v1.2.20 -s x64_v3 -y
USAGE
}

# ---------- parse options ----------
USERNAME=""; PASSWORD=""; CACHE=""; DLPATH=""; QVER=""; LVER=""; SUFFIX=""
WEBPORT=""; BTPORT=""; ASSUME_YES=""
while getopts "u:p:c:d:q:l:s:w:i:yh" opt; do
  case "$opt" in
    u) USERNAME=$OPTARG ;;
    p) PASSWORD=$OPTARG ;;
    c) CACHE=$OPTARG ;;
    d) DLPATH=$OPTARG ;;
    q) QVER=$OPTARG ;;
    l) LVER=$OPTARG ;;
    s) SUFFIX=$OPTARG ;;
    w) WEBPORT=$OPTARG ;;
    i) BTPORT=$OPTARG ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# interactive only if a real terminal is available
INTERACTIVE=""; if [ -r /dev/tty ] && [ -w /dev/tty ]; then INTERACTIVE=1; fi

# ---------- preflight ----------
[ "$(id -u)" -eq 0 ] || die "Please run this script as root."
command -v systemctl >/dev/null 2>&1 || die "systemd is required (systemctl not found)."

if [ -r /etc/os-release ]; then . /etc/os-release; fi
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) warn "This script is only tested on Debian/Ubuntu; continuing anyway." ;;
esac

case "$(uname -m)" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="ARM64"  ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

info "Installing prerequisites (wget curl ca-certificates jq) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends wget curl ca-certificates jq >/dev/null 2>&1 \
  || die "Failed to install prerequisites (wget/curl/ca-certificates/jq)."

# ---------- obtain the list of available builds ----------
info "Fetching available qBittorrent builds for ${ARCH} ..."
# Primary source: the live GitHub API (auto-includes any newly uploaded build).
mapfile -t BUILDS < <(curl -fsSL "${API_BASE}/${ARCH}" 2>/dev/null \
  | jq -r '.[] | select(.type=="dir") | .name' 2>/dev/null \
  | grep '^qBittorrent-' | sort -V)
# Fallback: the bundled manifest served over raw (raw has no API rate limit),
# used when the unauthenticated API is rate-limited (60/h per IP) or unreachable.
if [ "${#BUILDS[@]}" -eq 0 ]; then
  warn "GitHub API unavailable (rate-limited?); falling back to the bundled build list."
  mapfile -t BUILDS < <(curl -fsSL "${SELF_RAW}/builds-${ARCH}.txt" 2>/dev/null \
    | grep '^qBittorrent-' | sort -V)
fi
[ "${#BUILDS[@]}" -gt 0 ] || die "Could not obtain the build list (network unreachable). Please check connectivity and retry."

# ---------- resolve the build ----------
BUILD=""
if [ -n "$QVER" ]; then
  if [ -z "$LVER" ]; then
    warn "-q was given without -l (libtorrent version); cannot resolve a build from flags."
  else
    cand="qBittorrent-${QVER} - libtorrent-${LVER}"
    [ -n "$SUFFIX" ] && cand="${cand} - ${SUFFIX}"
    for b in "${BUILDS[@]}"; do [ "$b" = "$cand" ] && { BUILD="$b"; break; }; done
    [ -z "$BUILD" ] && warn "Requested build not found for ${ARCH}: ${cand}"
  fi
fi
if [ -z "$BUILD" ]; then
  if [ -n "$INTERACTIVE" ]; then
    echo
    echo "Available builds  (qBittorrent-<ver> - libtorrent-<ver> [- <cpu-opt>]):"
    i=1; for b in "${BUILDS[@]}"; do printf "   %2d) %s\n" "$i" "$b"; i=$((i+1)); done
    echo
    while :; do
      ask "Select a build [1-${#BUILDS[@]}]: "; rd n
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#BUILDS[@]}" ]; then
        BUILD="${BUILDS[$((n-1))]}"; break
      fi
      warn "Invalid choice."
    done
  else
    err "No valid build selected and no terminal available for interactive choice."
    err "Pass -q/-l (and -s) matching one of these:"
    printf '  %s\n' "${BUILDS[@]}" >&2
    exit 1
  fi
fi
info "Selected build: ${BUILD}"

# qBittorrent version number — decides which config format to write
QB_NUM=$(sed -n 's/^qBittorrent-\([0-9][0-9.]*\).*/\1/p' <<<"$BUILD")
[ -n "$QB_NUM" ] || die "Could not parse the qBittorrent version from '${BUILD}'."

# ---------- resolve remaining fields (flag value, else prompt, else default) ----------
# username (required)
if [ -z "$USERNAME" ]; then
  [ -n "$INTERACTIVE" ] || die "Username is required (-u)."
  while [ -z "$USERNAME" ]; do ask "WebUI username: "; rd USERNAME; done
fi
# password (required)
if [ -z "$PASSWORD" ]; then
  [ -n "$INTERACTIVE" ] || die "Password is required (-p)."
  while [ -z "$PASSWORD" ]; do ask "WebUI password: "; rd PASSWORD; done
fi
# cache (required, numeric)
if [ -z "$CACHE" ]; then
  [ -n "$INTERACTIVE" ] || die "Cache size is required (-c)."
  while :; do ask "Disk cache size in MiB (e.g. 2048): "; rd CACHE; [[ "$CACHE" =~ ^[0-9]+$ ]] && break; warn "Cache must be a number."; done
else
  [[ "$CACHE" =~ ^[0-9]+$ ]] || die "Cache (-c) must be a number."
fi
# download path (default)
DEF_DL="/home/${USERNAME}/qbittorrent/Downloads"
if [ -z "$DLPATH" ]; then
  if [ -n "$INTERACTIVE" ]; then ask "Download path [${DEF_DL}]: "; rd DLPATH; fi
  DLPATH="${DLPATH:-$DEF_DL}"
fi
# WebUI port (default 8080, numeric)
if [ -z "$WEBPORT" ]; then
  if [ -n "$INTERACTIVE" ]; then ask "WebUI port [8080]: "; rd WEBPORT; fi
  WEBPORT="${WEBPORT:-8080}"
fi
[[ "$WEBPORT" =~ ^[0-9]+$ ]] || die "WebUI port (-w) must be a number."
# incoming/BT port (default 45000, numeric)
if [ -z "$BTPORT" ]; then
  if [ -n "$INTERACTIVE" ]; then ask "Incoming (BT) port [45000]: "; rd BTPORT; fi
  BTPORT="${BTPORT:-45000}"
fi
[[ "$BTPORT" =~ ^[0-9]+$ ]] || die "Incoming port (-i) must be a number."

# ---------- summary + confirm ----------
echo
info "About to install:"
echo "    build       : ${BUILD}"
echo "    username    : ${USERNAME}"
echo "    cache       : ${CACHE} MiB"
echo "    downloads   : ${DLPATH}"
echo "    WebUI port  : ${WEBPORT}"
echo "    BT port     : ${BTPORT}"
echo
if [ -z "$ASSUME_YES" ] && [ -n "$INTERACTIVE" ]; then
  ask "Proceed? [Y/n]: "; rd YN
  case "$YN" in [Nn]*) die "Aborted by user." ;; esac
fi

# ---------- create user ----------
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  info "Creating user ${USERNAME} ..."
  useradd -m -s /bin/bash "$USERNAME" || die "Failed to create user ${USERNAME}."
fi

# ---------- stop any running instance ----------
if pgrep -if qbittorrent-nox >/dev/null 2>&1; then
  warn "qbittorrent-nox is already running; stopping it ..."
  systemctl stop "qbittorrent-nox@${USERNAME}" >/dev/null 2>&1
  pkill -if qbittorrent-nox >/dev/null 2>&1
  sleep 1
fi
if [ -e /usr/bin/qbittorrent-nox ]; then
  warn "Replacing existing /usr/bin/qbittorrent-nox"
  rm -f /usr/bin/qbittorrent-nox
fi

# ---------- download the binary ----------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ENC_BUILD="${BUILD// /%20}"
info "Downloading qbittorrent-nox ..."
wget -q "${BIN_BASE}/${ARCH}/${ENC_BUILD}/qbittorrent-nox" -O "${TMP}/qbittorrent-nox" \
  || die "Failed to download qbittorrent-nox for '${BUILD}'."
[ -s "${TMP}/qbittorrent-nox" ] || die "Downloaded qbittorrent-nox is empty."
install -m 0755 "${TMP}/qbittorrent-nox" /usr/bin/qbittorrent-nox

# ---------- directories ----------
mkdir -p "$DLPATH" "/home/${USERNAME}/.config/qBittorrent"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}" 2>/dev/null
# the download path may live outside the home dir
chown -R "${USERNAME}:${USERNAME}" "$DLPATH" 2>/dev/null

# ---------- systemd service ----------
info "Creating systemd service ..."
cat >/etc/systemd/system/qbittorrent-nox@.service <<'EOF'
[Unit]
Description=qBittorrent-nox
After=network.target

[Service]
Type=exec
User=%i
LimitNOFILE=infinity
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure
TimeoutStopSec=10
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "qbittorrent-nox@${USERNAME}" >/dev/null 2>&1

# ---------- qBittorrent internal IO tuning (qB config only, not system sysctl) ----------
if systemd-detect-virt -q; then
  aio=8;  low_buffer=3072; buffer=12288; buffer_factor=200
else
  disk_name=$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}')
  rota=$(cat "/sys/block/${disk_name}/queue/rotational" 2>/dev/null)
  if [ "${rota}" = "0" ]; then
    aio=8; low_buffer=5120; buffer=20480; buffer_factor=200   # SSD/NVMe
  else
    aio=4; low_buffer=3072; buffer=10240; buffer_factor=150   # HDD
  fi
fi

# ---------- generate WebUI password hash ----------
gen_pbkdf2(){
  wget -q "${BIN_BASE}/${ARCH}/qb_password_gen" -O "${TMP}/qb_password_gen" && chmod +x "${TMP}/qb_password_gen" \
    || die "Failed to download qb_password_gen."
  "${TMP}/qb_password_gen" "$PASSWORD"
}

CONF="/home/${USERNAME}/.config/qBittorrent/qBittorrent.conf"
info "Writing qBittorrent configuration ..."

case "$QB_NUM" in
  4.1.*)
    md5password=$(printf '%s' "$PASSWORD" | md5sum | awk '{print $1}')
    cat >"$CONF" <<EOF
[BitTorrent]
Session\AsyncIOThreadsCount=$aio
Session\SendBufferLowWatermark=$low_buffer
Session\SendBufferWatermark=$buffer
Session\SendBufferWatermarkFactor=$buffer_factor

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
Connection\PortRangeMin=$BTPORT
Downloads\DiskWriteCacheSize=$CACHE
Downloads\SavePath=$DLPATH
Queueing\QueueingEnabled=false
WebUI\Password_ha1=@ByteArray($md5password)
WebUI\Port=$WEBPORT
WebUI\Username=$USERNAME
WebUI\Locale=zh_CN
EOF
    ;;
  4.2.*|4.3.*)
    PBKDF2password=$(gen_pbkdf2)
    cat >"$CONF" <<EOF
[BitTorrent]
Session\AsyncIOThreadsCount=$aio
Session\SendBufferLowWatermark=$low_buffer
Session\SendBufferWatermark=$buffer
Session\SendBufferWatermarkFactor=$buffer_factor

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
Connection\PortRangeMin=$BTPORT
Downloads\DiskWriteCacheSize=$CACHE
Downloads\SavePath=$DLPATH
Queueing\QueueingEnabled=false
WebUI\Password_PBKDF2="@ByteArray($PBKDF2password)"
WebUI\Port=$WEBPORT
WebUI\Username=$USERNAME
WebUI\Locale=zh_CN
EOF
    ;;
  *)  # 4.4 / 4.5 / 4.6 / 5.0 and newer
    PBKDF2password=$(gen_pbkdf2)
    cat >"$CONF" <<EOF
[Application]
MemoryWorkingSetLimit=$CACHE

[BitTorrent]
Session\AsyncIOThreadsCount=$aio
Session\DefaultSavePath=$DLPATH
Session\DiskCacheSize=$CACHE
Session\Port=$BTPORT
Session\QueueingSystemEnabled=false
Session\SendBufferLowWatermark=$low_buffer
Session\SendBufferWatermark=$buffer
Session\SendBufferWatermarkFactor=$buffer_factor

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
WebUI\Password_PBKDF2="@ByteArray($PBKDF2password)"
WebUI\Port=$WEBPORT
WebUI\Username=$USERNAME
General\Locale=zh_CN
EOF
    ;;
esac

chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"

# ---------- start ----------
info "Starting qBittorrent ..."
systemctl restart "qbittorrent-nox@${USERNAME}"
sleep 2

if systemctl is-active --quiet "qbittorrent-nox@${USERNAME}"; then
  ipaddr=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  info "qBittorrent is installed and running!"
  echo "    WebUI   : http://${ipaddr:-<server-ip>}:${WEBPORT}"
  echo "    user    : ${USERNAME}"
  echo "    save to : ${DLPATH}"
  echo "    service : systemctl {status|restart|stop} qbittorrent-nox@${USERNAME}"
else
  err "The service failed to start. Check logs with:"
  err "    journalctl -u qbittorrent-nox@${USERNAME} --no-pager -n 50"
  exit 1
fi
