#!/bin/bash
#
# qb-installer — standalone, interactive qBittorrent installer
# -----------------------------------------------------------------------------
# Installs ONLY qBittorrent (precompiled qbittorrent-nox) with a WebUI.
# It does NOT touch sysctl / kernel settings, does NOT install BBR, and does
# NOT install any other seedbox component. Just qBittorrent.
#
# The qbittorrent-nox binary is pulled from the same place the full seedbox
# installer uses: SAGIRIxr/Seedbox-Components-P.
#
# Usage:
#   bash <(wget -qO- https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main/install.sh)
# -----------------------------------------------------------------------------
set -o pipefail

BIN_REPO="SAGIRIxr/Seedbox-Components-P"
BIN_BASE="https://raw.githubusercontent.com/${BIN_REPO}/main/Torrent%20Clients/qBittorrent"
API_BASE="https://api.github.com/repos/${BIN_REPO}/contents/Torrent%20Clients/qBittorrent"

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

# ---------- choose a build ----------
info "Fetching available qBittorrent builds for ${ARCH} ..."
mapfile -t BUILDS < <(curl -fsSL "${API_BASE}/${ARCH}" 2>/dev/null \
  | jq -r '.[] | select(.type=="dir") | .name' 2>/dev/null \
  | grep '^qBittorrent-' | sort -V)
[ "${#BUILDS[@]}" -gt 0 ] || die "Could not list builds (GitHub API unreachable or rate-limited). Please try again in a few minutes."

echo
echo "Available builds  (qBittorrent-<ver> - libtorrent-<ver> [- <cpu-opt>]):"
i=1; for b in "${BUILDS[@]}"; do printf "   %2d) %s\n" "$i" "$b"; i=$((i+1)); done
echo
BUILD=""
while :; do
  ask "Select a build [1-${#BUILDS[@]}]: "; rd n
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#BUILDS[@]}" ]; then
    BUILD="${BUILDS[$((n-1))]}"; break
  fi
  warn "Invalid choice."
done
info "Selected build: ${BUILD}"

# qBittorrent version number — decides which config format to write
QB_NUM=$(sed -n 's/^qBittorrent-\([0-9][0-9.]*\).*/\1/p' <<<"$BUILD")
[ -n "$QB_NUM" ] || die "Could not parse the qBittorrent version from '${BUILD}'."

# ---------- interactive prompts ----------
echo
ask "WebUI username: "; rd USERNAME
[ -n "$USERNAME" ] || die "Username cannot be empty."
ask "WebUI password: "; rd PASSWORD
[ -n "$PASSWORD" ] || die "Password cannot be empty."

while :; do
  ask "Disk cache size in MiB (e.g. 2048): "; rd CACHE
  [[ "$CACHE" =~ ^[0-9]+$ ]] && break; warn "Cache must be a number."
done

DEF_DL="/home/${USERNAME}/qbittorrent/Downloads"
ask "Download path [${DEF_DL}]: "; rd DLPATH
DLPATH="${DLPATH:-$DEF_DL}"

while :; do
  ask "WebUI port [8080]: "; rd WEBPORT; WEBPORT="${WEBPORT:-8080}"
  [[ "$WEBPORT" =~ ^[0-9]+$ ]] && break; warn "Port must be a number."
done
while :; do
  ask "Incoming (BT) port [45000]: "; rd BTPORT; BTPORT="${BTPORT:-45000}"
  [[ "$BTPORT" =~ ^[0-9]+$ ]] && break; warn "Port must be a number."
done

echo
info "About to install:"
echo "    build       : ${BUILD}"
echo "    username    : ${USERNAME}"
echo "    cache       : ${CACHE} MiB"
echo "    downloads   : ${DLPATH}"
echo "    WebUI port  : ${WEBPORT}"
echo "    BT port     : ${BTPORT}"
echo
ask "Proceed? [Y/n]: "; rd YN
case "$YN" in [Nn]*) die "Aborted by user." ;; esac

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
