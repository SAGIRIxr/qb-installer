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
  -g <代理>     GitHub 加速代理，用于拉取所有 GitHub 文件
                （默认: https://ghfast.top/ ；传 -g "" 则直连 GitHub）
  -y            假定 yes：跳过最后的确认提示
  -h            显示此帮助并退出

示例:
  # 交互式
  bash <(wget -qO- ${SELF_RAW}/install.sh)
  # 全自动无人值守
  bash <(wget -qO- ${SELF_RAW}/install.sh) -u alice -p 's3cret' -c 2048 -q 5.0.5 -l v1.2.20 -s x64_v3 -y
  # 自定义 GitHub 代理 / 直连
  bash <(wget -qO- ${SELF_RAW}/install.sh) -g https://gh.example.com/
  bash <(wget -qO- ${SELF_RAW}/install.sh) -g ""
USAGE
}

# ---------- parse options ----------
USERNAME=""; PASSWORD=""; CACHE=""; DLPATH=""; QVER=""; LVER=""; SUFFIX=""
WEBPORT=""; BTPORT=""; ASSUME_YES=""
GH_PROXY="https://ghfast.top/"   # GitHub proxy prefix; -g overrides, -g "" disables
while getopts "u:p:c:d:q:l:s:w:i:g:yh" opt; do
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
    g) GH_PROXY=$OPTARG ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Normalise the proxy prefix to exactly one trailing slash when set.
# Every GitHub URL below is fetched as "${GH_PROXY}<full-github-url>", so the
# default https://ghfast.top/ yields https://ghfast.top/https://raw.github... .
[ -n "$GH_PROXY" ] && GH_PROXY="${GH_PROXY%/}/"

# interactive only if a real terminal is available
INTERACTIVE=""; if [ -r /dev/tty ] && [ -w /dev/tty ]; then INTERACTIVE=1; fi

# ---------- preflight ----------
[ "$(id -u)" -eq 0 ] || die "请以 root 身份运行本脚本。"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd（未找到 systemctl）。"

if [ -r /etc/os-release ]; then . /etc/os-release; fi
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) warn "本脚本仅在 Debian/Ubuntu 上测试过，将继续尝试。" ;;
esac

case "$(uname -m)" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="ARM64"  ;;
  *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac

# Only install what is actually missing. Everything below uses wget (not curl),
# so we never pull curl in — handy on boxes where the curl/libcurl4 versions are
# held back or the package state is otherwise messy.
need_pkgs=()
command -v wget >/dev/null 2>&1 || need_pkgs+=(wget)
command -v jq   >/dev/null 2>&1 || need_pkgs+=(jq)
[ -e /etc/ssl/certs/ca-certificates.crt ] || need_pkgs+=(ca-certificates)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
  info "正在安装缺少的依赖：${need_pkgs[*]} ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update 失败，将沿用当前的包列表继续。"
  apt-get install -y -qq --no-install-recommends "${need_pkgs[@]}" \
    || warn "apt-get 未能安装：${need_pkgs[*]}（若关键工具已存在则继续）。"
fi
# Hard requirement: a downloader. wget is used for every download below.
command -v wget >/dev/null 2>&1 || die "需要 wget，但它不可用且无法安装。"
# jq is optional: it is only used to read the live GitHub API. Without it the
# script falls back to the bundled per-arch manifest.
HAVE_JQ=""; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# ---------- obtain the list of available builds ----------
info "正在获取 ${ARCH} 架构可用的 qBittorrent 构建列表 ..."
BUILDS=()
# Primary source: the live GitHub API (auto-includes any newly uploaded build).
# Requires jq; skipped when jq is unavailable.
if [ -n "$HAVE_JQ" ]; then
  mapfile -t BUILDS < <(wget -qO- -T 20 -t 2 "${GH_PROXY}${API_BASE}/${ARCH}" 2>/dev/null \
    | jq -r '.[] | select(.type=="dir") | .name' 2>/dev/null \
    | grep '^qBittorrent-' | sort -V)
fi
# Fallback: the bundled manifest served over raw (no API rate limit, no jq),
# used when jq is missing, or the API is rate-limited (60/h per IP) / unreachable.
if [ "${#BUILDS[@]}" -eq 0 ]; then
  [ -n "$HAVE_JQ" ] && warn "GitHub API 不可用（可能被限流），改用内置的构建清单。"
  mapfile -t BUILDS < <(wget -qO- -T 20 -t 2 "${GH_PROXY}${SELF_RAW}/builds-${ARCH}.txt" 2>/dev/null \
    | grep '^qBittorrent-' | sort -V)
fi
[ "${#BUILDS[@]}" -gt 0 ] || die "无法获取构建列表（网络不可达）。请检查网络后重试。"

# ---------- resolve the build ----------
BUILD=""
if [ -n "$QVER" ]; then
  if [ -z "$LVER" ]; then
    warn "指定了 -q 但没有 -l（libtorrent 版本），无法用参数确定构建。"
  else
    cand="qBittorrent-${QVER} - libtorrent-${LVER}"
    [ -n "$SUFFIX" ] && cand="${cand} - ${SUFFIX}"
    for b in "${BUILDS[@]}"; do [ "$b" = "$cand" ] && { BUILD="$b"; break; }; done
    [ -z "$BUILD" ] && warn "在 ${ARCH} 下找不到指定的构建：${cand}"
  fi
fi
if [ -z "$BUILD" ]; then
  if [ -n "$INTERACTIVE" ]; then
    echo
    echo "可用构建（qBittorrent-<版本> - libtorrent-<版本> [- <CPU优化>]）："
    i=1; for b in "${BUILDS[@]}"; do printf "   %2d) %s\n" "$i" "$b"; i=$((i+1)); done
    echo
    while :; do
      ask "请选择一个构建 [1-${#BUILDS[@]}]: "; rd n
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#BUILDS[@]}" ]; then
        BUILD="${BUILDS[$((n-1))]}"; break
      fi
      warn "无效的选择。"
    done
  else
    err "未选择有效构建，且没有可交互的终端。"
    err "请用 -q/-l（及 -s）指定下列之一："
    printf '  %s\n' "${BUILDS[@]}" >&2
    exit 1
  fi
fi
info "已选择构建：${BUILD}"

# qBittorrent version number — decides which config format to write
QB_NUM=$(sed -n 's/^qBittorrent-\([0-9][0-9.]*\).*/\1/p' <<<"$BUILD")
[ -n "$QB_NUM" ] || die "无法从 '${BUILD}' 解析出 qBittorrent 版本号。"

# ---------- resolve remaining fields (flag value, else prompt, else default) ----------
# username (required)
if [ -z "$USERNAME" ]; then
  [ -n "$INTERACTIVE" ] || die "必须提供用户名（-u）。"
  while [ -z "$USERNAME" ]; do ask "WebUI 用户名: "; rd USERNAME; done
fi
# password (required)
if [ -z "$PASSWORD" ]; then
  [ -n "$INTERACTIVE" ] || die "必须提供密码（-p）。"
  while [ -z "$PASSWORD" ]; do ask "WebUI 密码: "; rd PASSWORD; done
fi
# cache (required, numeric)
if [ -z "$CACHE" ]; then
  [ -n "$INTERACTIVE" ] || die "必须提供磁盘缓存大小（-c）。"
  while :; do ask "磁盘缓存大小，单位 MiB（如 2048）: "; rd CACHE; [[ "$CACHE" =~ ^[0-9]+$ ]] && break; warn "缓存必须是数字。"; done
else
  [[ "$CACHE" =~ ^[0-9]+$ ]] || die "缓存（-c）必须是数字。"
fi
# download path (default)
DEF_DL="/home/${USERNAME}/qbittorrent/Downloads"
if [ -z "$DLPATH" ]; then
  if [ -n "$INTERACTIVE" ]; then ask "下载路径 [${DEF_DL}]: "; rd DLPATH; fi
  DLPATH="${DLPATH:-$DEF_DL}"
fi
# WebUI port (default 8080, numeric)
if [ -z "$WEBPORT" ]; then
  if [ -n "$INTERACTIVE" ]; then ask "WebUI 端口 [8080]: "; rd WEBPORT; fi
  WEBPORT="${WEBPORT:-8080}"
fi
[[ "$WEBPORT" =~ ^[0-9]+$ ]] || die "WebUI 端口（-w）必须是数字。"
# incoming/BT port (default 45000, numeric)
if [ -z "$BTPORT" ]; then
  if [ -n "$INTERACTIVE" ]; then ask "入站/BT 端口 [45000]: "; rd BTPORT; fi
  BTPORT="${BTPORT:-45000}"
fi
[[ "$BTPORT" =~ ^[0-9]+$ ]] || die "入站端口（-i）必须是数字。"

# ---------- summary + confirm ----------
echo
info "即将安装："
echo "    构建      : ${BUILD}"
echo "    用户名    : ${USERNAME}"
echo "    缓存      : ${CACHE} MiB"
echo "    下载路径  : ${DLPATH}"
echo "    WebUI 端口: ${WEBPORT}"
echo "    BT 端口   : ${BTPORT}"
echo "    GitHub代理: ${GH_PROXY:-<直连>}"
echo
if [ -z "$ASSUME_YES" ] && [ -n "$INTERACTIVE" ]; then
  ask "确认安装? [Y/n]: "; rd YN
  case "$YN" in [Nn]*) die "已取消。" ;; esac
fi

# ---------- create user ----------
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  info "正在创建用户 ${USERNAME} ..."
  useradd -m -s /bin/bash "$USERNAME" || die "创建用户 ${USERNAME} 失败。"
fi

# ---------- stop any running instance ----------
if pgrep -if qbittorrent-nox >/dev/null 2>&1; then
  warn "检测到 qbittorrent-nox 正在运行，正在停止 ..."
  systemctl stop "qbittorrent-nox@${USERNAME}" >/dev/null 2>&1
  pkill -if qbittorrent-nox >/dev/null 2>&1
  sleep 1
fi
if [ -e /usr/bin/qbittorrent-nox ]; then
  warn "替换已存在的 /usr/bin/qbittorrent-nox"
  rm -f /usr/bin/qbittorrent-nox
fi

# ---------- download the binary ----------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ENC_BUILD="${BUILD// /%20}"
info "正在下载 qbittorrent-nox ..."
wget -q "${GH_PROXY}${BIN_BASE}/${ARCH}/${ENC_BUILD}/qbittorrent-nox" -O "${TMP}/qbittorrent-nox" \
  || die "下载 qbittorrent-nox 失败（构建：${BUILD}）。"
[ -s "${TMP}/qbittorrent-nox" ] || die "下载到的 qbittorrent-nox 是空文件。"
install -m 0755 "${TMP}/qbittorrent-nox" /usr/bin/qbittorrent-nox

# ---------- directories ----------
mkdir -p "$DLPATH" "/home/${USERNAME}/.config/qBittorrent"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}" 2>/dev/null
# the download path may live outside the home dir
chown -R "${USERNAME}:${USERNAME}" "$DLPATH" 2>/dev/null

# ---------- systemd service ----------
info "正在创建 systemd 服务 ..."
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
  wget -q "${GH_PROXY}${BIN_BASE}/${ARCH}/qb_password_gen" -O "${TMP}/qb_password_gen" && chmod +x "${TMP}/qb_password_gen" \
    || die "下载 qb_password_gen 失败。"
  "${TMP}/qb_password_gen" "$PASSWORD"
}

CONF="/home/${USERNAME}/.config/qBittorrent/qBittorrent.conf"
info "正在写入 qBittorrent 配置 ..."

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
info "正在启动 qBittorrent ..."
systemctl restart "qbittorrent-nox@${USERNAME}"
sleep 2

if systemctl is-active --quiet "qbittorrent-nox@${USERNAME}"; then
  ipaddr=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  info "qBittorrent 已安装并成功运行！"
  echo "    面板地址: http://${ipaddr:-<服务器IP>}:${WEBPORT}"
  echo "    用户名  : ${USERNAME}"
  echo "    下载到  : ${DLPATH}"
  echo "    服务管理: systemctl {status|restart|stop} qbittorrent-nox@${USERNAME}"
else
  err "服务启动失败。请用以下命令查看日志："
  err "    journalctl -u qbittorrent-nox@${USERNAME} --no-pager -n 50"
  exit 1
fi
