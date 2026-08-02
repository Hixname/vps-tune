#!/usr/bin/env bash
# 妙妙屋X Debian VPS 调优包装脚本
# 固定使用 debian-vps-tuning v0.1.0-rc.8 的已审阅提交。

set -Eeuo pipefail

readonly WRAPPER_VERSION='2.0.0'
readonly UPSTREAM_COMMIT='7bdd57d9de275ae614132272fea0d92632218426'
readonly UPSTREAM_BASE="https://raw.githubusercontent.com/alieismy/debian-vps-tuning/${UPSTREAM_COMMIT}"
readonly UPSTREAM_DIR='/usr/local/lib/mmwx-vps-tune'
readonly WRAPPER_STATE_DIR='/var/lib/mmwx-vps-tune'
readonly WRAPPER_STATE_FILE="${WRAPPER_STATE_DIR}/wrapper.env"
readonly UPSTREAM_STATE_FILE='/var/lib/proxy-vps-tuning/state.json'
readonly UPSTREAM_SYSCTL_FILE='/etc/sysctl.d/90-proxy-vps.conf'
readonly SYSCTL_BACKUP_DIR="${WRAPPER_STATE_DIR}/sysctl-originals"
readonly SYSCTL_MIGRATION_MANIFEST="${WRAPPER_STATE_DIR}/sysctl-migrations.tsv"
readonly MAX_BUF_MAX=67108864
readonly MIB=1048576
readonly -a MANAGED_SYSCTL_KEYS=(
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.core.netdev_max_backlog
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_keepalive_time
  net.ipv4.tcp_keepalive_intvl
  net.ipv4.tcp_keepalive_probes
  vm.swappiness
)

ACTION="${1:-menu}"
TUNING_MODE_INPUT="${TUNING_MODE:-}"
PORT_SPEED_MBPS_INPUT="${PORT_SPEED_MBPS:-}"
BUFFER_TARGET_RTT_MS_INPUT="${BUFFER_TARGET_RTT_MS:-}"
ENABLE_SWAP_INPUT="${ENABLE_SWAP:-}"
SWAP_MB_INPUT="${SWAP_MB:-}"
PORT_SPEED_MBPS=''
UPSTREAM_PORT_SPEED_MBPS=''
BUFFER_TARGET_RTT_MS=''
TUNING_MODE=''
TUNING_MODE_LABEL=''
MODE_BUFFER_PERCENT=''
MODE_MIN_BUF=''
ENABLE_SWAP=''
SWAP_MB=''
BUF_MAX_VALUE='auto'
SELECTED_BUF_MAX=''
BUFFER_BDP_BYTES=''
BUFFER_REQUIRED_BYTES=''
BUFFER_COVERAGE_MS=''
AUTO_APPLY="${AUTO_APPLY:-0}"
AUTO_MIGRATE_SYSCTL="${AUTO_MIGRATE_SYSCTL:-0}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
MMWX_CONTAINER="${MMWX_CONTAINER:-mmw-agent}"

PROFILE=''
PROFILE_PATH=''
EXPECTED_SHA256=''
MEMORY_MIB=''
DEPLOYMENT_MODE='not-checked'
XRAY_MODE='not-checked'
PROXY_SERVICE_UNITS=''
DOWNLOAD_TMP=''
MIGRATION_PENDING=0
SYSCTL_CONFLICT_COUNT=0
SYSCTL_CONFLICT_FILES=()

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${DOWNLOAD_TMP:-}" ] && [ -f "$DOWNLOAD_TMP" ]; then
    rm -f -- "$DOWNLOAD_TMP"
  fi
  if [ "${MIGRATION_PENDING:-0}" = '1' ]; then
    if [ ! -f "$UPSTREAM_STATE_FILE" ]; then
      warn '安装未完成，正在恢复本次迁移的 sysctl 配置。'
      restore_sysctl_migrations 0 || warn '自动恢复 sysctl 迁移失败；请保留状态目录并人工检查。'
    else
      warn "安装未完成但上游状态已存在；迁移备份保留在 ${SYSCTL_BACKUP_DIR}，请执行恢复菜单。"
    fi
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
妙妙屋X Debian VPS 调优脚本 v2

用法：
  bash mmwx-vps-tune.sh menu
  bash mmwx-vps-tune.sh install
  bash mmwx-vps-tune.sh reinstall
  bash mmwx-vps-tune.sh preflight
  bash mmwx-vps-tune.sh status
  bash mmwx-vps-tune.sh restore
  bash mmwx-vps-tune.sh verify

动作：
  menu        显示编号主菜单；默认动作
  install     全新安装并选择调优档位
  reinstall   安全回滚当前管理状态后覆盖重装
  preflight   选择参数并只执行预检
  status      当前优化状态
  restore     恢复原始状态并清理脚本创建的 swap
  verify      生效检测

环境变量：
  TUNING_MODE=conservative|aggressive|extreme
  PORT_SPEED_MBPS=100..10000      VPS 套餐标称带宽；不设置时显示选择菜单
  BUFFER_TARGET_RTT_MS=20..500    目标 RTT；不设置时显示选择菜单
  ENABLE_SWAP=0|1                 没有活动 swap 时是否创建，默认 1
  SWAP_MB=512..4096               swap 大小，默认 1024
  AUTO_APPLY=0|1                  设为 1 跳过 APPLY 确认
  AUTO_MIGRATE_SYSCTL=0|1         设为 1 自动备份并迁移重复 sysctl 键
  INSTALL_DEPS=0|1                缺少依赖时自动安装，默认 1
  MMWX_CONTAINER=名称             Docker Agent 容器名，默认 mmw-agent

脚本不会升级系统、修改 UFW、修改妙妙屋X配置或自动重启 VPS。
三种档位分别使用 1.0x、1.5x、2.0x BDP 缓冲余量；超过 64 MiB 时安全拒绝。
EOF
}

need_root() {
  [ "${EUID}" -eq 0 ] || die '请先进入 root shell 再运行。'
}

validate_wrapper_state_paths() {
  if [ -e "$WRAPPER_STATE_DIR" ] || [ -L "$WRAPPER_STATE_DIR" ]; then
    if [ ! -d "$WRAPPER_STATE_DIR" ] || [ -L "$WRAPPER_STATE_DIR" ] ||
      [ "$(stat -c '%u' "$WRAPPER_STATE_DIR" 2>/dev/null || true)" != '0' ]; then
      die "包装状态目录类型或所有权异常：${WRAPPER_STATE_DIR}"
    fi
  fi
  if [ -e "$SYSCTL_BACKUP_DIR" ] || [ -L "$SYSCTL_BACKUP_DIR" ]; then
    if [ ! -d "$SYSCTL_BACKUP_DIR" ] || [ -L "$SYSCTL_BACKUP_DIR" ] ||
      [ "$(stat -c '%u' "$SYSCTL_BACKUP_DIR" 2>/dev/null || true)" != '0' ]; then
      die "sysctl 备份目录类型或所有权异常：${SYSCTL_BACKUP_DIR}"
    fi
  fi
  if [ -e "$SYSCTL_MIGRATION_MANIFEST" ] || [ -L "$SYSCTL_MIGRATION_MANIFEST" ]; then
    if [ ! -f "$SYSCTL_MIGRATION_MANIFEST" ] || [ -L "$SYSCTL_MIGRATION_MANIFEST" ] ||
      [ "$(stat -c '%u' "$SYSCTL_MIGRATION_MANIFEST" 2>/dev/null || true)" != '0' ]; then
      die "sysctl 迁移清单类型或所有权异常：${SYSCTL_MIGRATION_MANIFEST}"
    fi
  fi
  if [ -d "$SYSCTL_BACKUP_DIR" ] && [ ! -f "$SYSCTL_MIGRATION_MANIFEST" ]; then
    die "存在 sysctl 备份目录但缺少迁移清单，拒绝猜测所有权：${SYSCTL_BACKUP_DIR}"
  fi
  if [ -f "$SYSCTL_MIGRATION_MANIFEST" ] && [ ! -d "$SYSCTL_BACKUP_DIR" ]; then
    die "存在 sysctl 迁移清单但缺少备份目录：${SYSCTL_MIGRATION_MANIFEST}"
  fi
}

read_saved_value() {
  local key="$1"
  if [ ! -f "$WRAPPER_STATE_FILE" ] || [ -L "$WRAPPER_STATE_FILE" ]; then
    return 0
  fi
  [ "$(stat -c '%u' "$WRAPPER_STATE_FILE" 2>/dev/null || true)" = '0' ] ||
    die "状态文件所有权异常：${WRAPPER_STATE_FILE}"
  awk -F= -v wanted="$key" '$1 == wanted {print $2; exit}' "$WRAPPER_STATE_FILE"
}

is_configuration_action() {
  case "$ACTION" in
    install | reinstall | preflight | apply) return 0 ;;
    *) return 1 ;;
  esac
}

choose_tuning_mode() {
  local saved default_mode choice
  if [ -n "$TUNING_MODE_INPUT" ]; then
    TUNING_MODE="$TUNING_MODE_INPUT"
    return 0
  fi

  saved="$(read_saved_value TUNING_MODE)"
  default_mode="${saved:-conservative}"
  if is_configuration_action && [ -r /dev/tty ]; then
    printf '\n请选择调优档位：\n' >/dev/tty
    printf '  1) 保守调优（推荐，1.0x BDP，最低 8 MiB）\n' >/dev/tty
    printf '  2) 激进调优（1.5x BDP，最低 16 MiB）\n' >/dev/tty
    printf '  3) 极限调优（2.0x BDP，最低 32 MiB，高内存压力）\n' >/dev/tty
    printf '直接回车使用当前/默认档位 %s：' "$default_mode" >/dev/tty
    IFS= read -r choice </dev/tty
    case "$choice" in
      '') TUNING_MODE="$default_mode" ;;
      1) TUNING_MODE='conservative' ;;
      2) TUNING_MODE='aggressive' ;;
      3) TUNING_MODE='extreme' ;;
      *) die '无效的调优档位。' ;;
    esac
  else
    TUNING_MODE="$default_mode"
  fi
}

choose_bandwidth() {
  local saved default_speed choice custom_speed
  if [ -n "$PORT_SPEED_MBPS_INPUT" ]; then
    PORT_SPEED_MBPS="$PORT_SPEED_MBPS_INPUT"
    return 0
  fi

  saved="$(read_saved_value PORT_SPEED_MBPS)"
  default_speed="${saved:-200}"
  if is_configuration_action && [ -r /dev/tty ]; then
    printf '\n请选择 VPS 套餐标称带宽：\n' >/dev/tty
    printf '  1) 200 Mbps\n' >/dev/tty
    printf '  2) 500 Mbps\n' >/dev/tty
    printf '  3) 1000 Mbps\n' >/dev/tty
    printf '  4) 自定义 100–10000 Mbps\n' >/dev/tty
    printf '直接回车使用当前/默认值 %s Mbps：' "$default_speed" >/dev/tty
    IFS= read -r choice </dev/tty
    case "$choice" in
      '') PORT_SPEED_MBPS="$default_speed" ;;
      1) PORT_SPEED_MBPS=200 ;;
      2) PORT_SPEED_MBPS=500 ;;
      3) PORT_SPEED_MBPS=1000 ;;
      4)
        printf '请输入套餐标称带宽 Mbps：' >/dev/tty
        IFS= read -r custom_speed </dev/tty
        PORT_SPEED_MBPS="$custom_speed"
        ;;
      *) die '无效的带宽选项。' ;;
    esac
  else
    PORT_SPEED_MBPS="$default_speed"
  fi
}

choose_target_rtt() {
  local saved default_rtt choice custom_rtt
  if [ -n "$BUFFER_TARGET_RTT_MS_INPUT" ]; then
    BUFFER_TARGET_RTT_MS="$BUFFER_TARGET_RTT_MS_INPUT"
    return 0
  fi

  saved="$(read_saved_value BUFFER_TARGET_RTT_MS)"
  default_rtt="${saved:-200}"
  if is_configuration_action && [ -r /dev/tty ]; then
    printf '\n请选择需要覆盖的目标 RTT：\n' >/dev/tty
    printf '  1) 50 ms\n' >/dev/tty
    printf '  2) 100 ms\n' >/dev/tty
    printf '  3) 150 ms\n' >/dev/tty
    printf '  4) 200 ms（跨境线路常用）\n' >/dev/tty
    printf '  5) 300 ms\n' >/dev/tty
    printf '  6) 自定义 20–500 ms\n' >/dev/tty
    printf '直接回车使用当前/默认值 %s ms：' "$default_rtt" >/dev/tty
    IFS= read -r choice </dev/tty
    case "$choice" in
      '') BUFFER_TARGET_RTT_MS="$default_rtt" ;;
      1) BUFFER_TARGET_RTT_MS=50 ;;
      2) BUFFER_TARGET_RTT_MS=100 ;;
      3) BUFFER_TARGET_RTT_MS=150 ;;
      4) BUFFER_TARGET_RTT_MS=200 ;;
      5) BUFFER_TARGET_RTT_MS=300 ;;
      6)
        printf '请输入目标 RTT ms：' >/dev/tty
        IFS= read -r custom_rtt </dev/tty
        BUFFER_TARGET_RTT_MS="$custom_rtt"
        ;;
      *) die '无效的 RTT 选项。' ;;
    esac
  else
    BUFFER_TARGET_RTT_MS="$default_rtt"
  fi
}

load_saved_settings() {
  local saved=''
  choose_tuning_mode
  choose_bandwidth
  choose_target_rtt
  if [ -n "$ENABLE_SWAP_INPUT" ]; then
    ENABLE_SWAP="$ENABLE_SWAP_INPUT"
  else
    saved="$(read_saved_value ENABLE_SWAP)"
    ENABLE_SWAP="${saved:-1}"
  fi
  if [ -n "$SWAP_MB_INPUT" ]; then
    SWAP_MB="$SWAP_MB_INPUT"
  else
    saved="$(read_saved_value SWAP_MB)"
    SWAP_MB="${saved:-1024}"
  fi
}

validate_inputs() {
  case "$TUNING_MODE" in
    conservative)
      TUNING_MODE_LABEL='保守调优'
      MODE_BUFFER_PERCENT=100
      MODE_MIN_BUF=$((8 * MIB))
      ;;
    aggressive)
      TUNING_MODE_LABEL='激进调优'
      MODE_BUFFER_PERCENT=150
      MODE_MIN_BUF=$((16 * MIB))
      ;;
    extreme)
      TUNING_MODE_LABEL='极限调优'
      MODE_BUFFER_PERCENT=200
      MODE_MIN_BUF=$((32 * MIB))
      ;;
    *) die 'TUNING_MODE 只能为 conservative、aggressive 或 extreme。' ;;
  esac

  [[ "$PORT_SPEED_MBPS" =~ ^[0-9]{3,5}$ ]] ||
    die 'PORT_SPEED_MBPS 必须是 100–10000 的整数。'
  PORT_SPEED_MBPS=$((10#$PORT_SPEED_MBPS))
  if [ "$PORT_SPEED_MBPS" -lt 100 ] || [ "$PORT_SPEED_MBPS" -gt 10000 ]; then
    die 'PORT_SPEED_MBPS 必须在 100–10000 之间。'
  fi

  [[ "$BUFFER_TARGET_RTT_MS" =~ ^[0-9]{2,3}$ ]] ||
    die 'BUFFER_TARGET_RTT_MS 必须是 20–500 的整数。'
  BUFFER_TARGET_RTT_MS=$((10#$BUFFER_TARGET_RTT_MS))
  if [ "$BUFFER_TARGET_RTT_MS" -lt 20 ] || [ "$BUFFER_TARGET_RTT_MS" -gt 500 ]; then
    die 'BUFFER_TARGET_RTT_MS 必须在 20–500 之间。'
  fi

  BUFFER_BDP_BYTES=$((PORT_SPEED_MBPS * 125 * BUFFER_TARGET_RTT_MS))
  BUFFER_REQUIRED_BYTES=$(((BUFFER_BDP_BYTES * MODE_BUFFER_PERCENT + 99) / 100))
  if [ "$BUFFER_REQUIRED_BYTES" -lt "$MODE_MIN_BUF" ]; then
    BUFFER_REQUIRED_BYTES="$MODE_MIN_BUF"
  fi
  SELECTED_BUF_MAX=$((((BUFFER_REQUIRED_BYTES + MIB - 1) / MIB) * MIB))
  if [ "$SELECTED_BUF_MAX" -gt "$MAX_BUF_MAX" ]; then
    local max_speed
    max_speed=$((MAX_BUF_MAX * 100 / (125 * BUFFER_TARGET_RTT_MS * MODE_BUFFER_PERCENT)))
    die "${TUNING_MODE_LABEL}下，${PORT_SPEED_MBPS} Mbps × ${BUFFER_TARGET_RTT_MS} ms 需要超过 64 MiB 缓冲；当前档位安全上限约为 ${max_speed} Mbps。请降低 RTT、带宽或调优档位。"
  fi
  BUFFER_COVERAGE_MS=$((SELECTED_BUF_MAX * 8 / (PORT_SPEED_MBPS * 1000)))
  if [ "$PORT_SPEED_MBPS" -le 1000 ]; then
    UPSTREAM_PORT_SPEED_MBPS="$PORT_SPEED_MBPS"
  else
    UPSTREAM_PORT_SPEED_MBPS=1000
  fi
  BUF_MAX_VALUE="$SELECTED_BUF_MAX"

  [ "$ENABLE_SWAP" = '0' ] || [ "$ENABLE_SWAP" = '1' ] ||
    die 'ENABLE_SWAP 只能为 0 或 1。'
  [[ "$SWAP_MB" =~ ^[0-9]{3,4}$ ]] || die 'SWAP_MB 必须是整数 MiB。'
  SWAP_MB=$((10#$SWAP_MB))
  if [ "$SWAP_MB" -lt 512 ] || [ "$SWAP_MB" -gt 4096 ]; then
    die 'SWAP_MB 必须在 512–4096 之间。'
  fi
  [ "$AUTO_APPLY" = '0' ] || [ "$AUTO_APPLY" = '1' ] ||
    die 'AUTO_APPLY 只能为 0 或 1。'
  [ "$AUTO_MIGRATE_SYSCTL" = '0' ] || [ "$AUTO_MIGRATE_SYSCTL" = '1' ] ||
    die 'AUTO_MIGRATE_SYSCTL 只能为 0 或 1。'
  [ "$INSTALL_DEPS" = '0' ] || [ "$INSTALL_DEPS" = '1' ] ||
    die 'INSTALL_DEPS 只能为 0 或 1。'
}

select_profile() {
  [ -r /etc/os-release ] || die '/etc/os-release 不可读。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = 'debian' ] || die "只支持 Debian 12/13；当前系统：${PRETTY_NAME:-unknown}"
  case "${VERSION_ID:-}" in
    12 | 13) ;;
    *) die "只支持 Debian 12/13；当前 VERSION_ID=${VERSION_ID:-unknown}" ;;
  esac
  [ "$(uname -m)" = 'x86_64' ] ||
    die "上游调优脚本只支持 x86_64/amd64；当前架构：$(uname -m)"

  MEMORY_MIB="$(awk '/^MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo)"
  [[ "$MEMORY_MIB" =~ ^[0-9]+$ ]] || die '无法读取物理内存。'
  if [ "$MEMORY_MIB" -ge 768 ] && [ "$MEMORY_MIB" -le 1536 ]; then
    PROFILE="debian${VERSION_ID}-1c1g-vps-tuning.sh"
  elif [ "$MEMORY_MIB" -gt 1536 ] && [ "$MEMORY_MIB" -le 3072 ]; then
    PROFILE="debian${VERSION_ID}-1c2g-vps-tuning.sh"
  else
    die "检测到 ${MEMORY_MIB} MiB RAM；上游脚本只支持 768–3072 MiB。"
  fi

  case "$PROFILE" in
    debian12-1c1g-vps-tuning.sh)
      EXPECTED_SHA256='042a79777cb53f66bb395786f1342ed17795d4aeb45497746260ff72a9d2c6a0'
      ;;
    debian12-1c2g-vps-tuning.sh)
      EXPECTED_SHA256='4334171284e2e3f093466d70cec4096a6ffd5ab149eacd6203011b8d44d4bd97'
      ;;
    debian13-1c1g-vps-tuning.sh)
      EXPECTED_SHA256='a4687b1a59882ff6a62caa470bc73b2e0a709cd5d1e58e48ebcb4079a24d3c5e'
      ;;
    debian13-1c2g-vps-tuning.sh)
      EXPECTED_SHA256='617233273d8ad9d527cc85957f46f5c52e1b515700d722a243ce5c80b2519fd8'
      ;;
    *) die "内部错误：未知档位 ${PROFILE}" ;;
  esac
  if [[ "$PROFILE" = *'-1c1g-'* ]] && [ "$SWAP_MB" -gt 2048 ]; then
    die '1 GiB 档位的 SWAP_MB 上限为 2048。'
  fi
  PROFILE_PATH="${UPSTREAM_DIR}/${PROFILE}"
}

missing_commands() {
  local cmd
  for cmd in curl sha256sum awk grep sed sysctl ip tc ss modprobe modinfo \
    systemctl swapon swapoff mkswap findmnt flock pgrep jq stat readlink install \
    cp mv chmod rmdir; do
    command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
  done
}

ensure_dependencies() {
  local missing
  missing="$(missing_commands)"
  [ -z "$missing" ] && return 0
  if [ "$INSTALL_DEPS" != '1' ]; then
    printf '%s\n' "$missing" >&2
    die '缺少上述命令；请安装依赖或设置 INSTALL_DEPS=1。'
  fi
  info '安装调优脚本所需的基础工具；不会执行系统大版本升级。'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl jq iproute2 procps kmod util-linux
  missing="$(missing_commands)"
  [ -z "$missing" ] || {
    printf '%s\n' "$missing" >&2
    die '安装后仍缺少必要命令。'
  }
}

service_loaded() {
  [ "$(systemctl show -p LoadState --value "$1" 2>/dev/null || true)" = 'loaded' ]
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

detect_mmwx() {
  systemctl show-environment >/dev/null 2>&1 ||
    die '当前环境没有可用的 systemd；不适合使用此包装脚本。'

  if service_loaded mmw-agent.service; then
    service_active mmw-agent.service || die 'mmw-agent.service 已安装但未运行；请先修复妙妙屋X Agent。'
    XRAY_MODE="$(awk -F: '/^[[:space:]]*xray_mode[[:space:]]*:/ {
      value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit
    }' /etc/mmw-agent/config.yaml 2>/dev/null || true)"
    XRAY_MODE="${XRAY_MODE:-external}"
    case "$XRAY_MODE" in
      embedded)
        DEPLOYMENT_MODE='systemd-agent-embedded'
        PROXY_SERVICE_UNITS='mmw-agent.service'
        ;;
      external)
        service_active xray.service ||
          die '配置为 external，但 xray.service 未运行；请先修复 Xray。'
        DEPLOYMENT_MODE='systemd-agent-external'
        PROXY_SERVICE_UNITS='mmw-agent.service xray.service'
        ;;
      *) die "无法识别 xray_mode：${XRAY_MODE}" ;;
    esac
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker inspect "$MMWX_CONTAINER" >/dev/null 2>&1; then
    local running network_mode
    running="$(docker inspect --format '{{.State.Running}}' "$MMWX_CONTAINER")"
    network_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$MMWX_CONTAINER")"
    [ "$running" = 'true' ] || die "Docker 容器 ${MMWX_CONTAINER} 未运行。"
    [ "$network_mode" = 'host' ] ||
      die "Docker Agent 必须使用 host 网络；当前为 ${network_mode}。"
    DEPLOYMENT_MODE='docker-agent-embedded'
    XRAY_MODE='embedded'
    PROXY_SERVICE_UNITS=''
    return 0
  fi

  if service_active xray.service; then
    DEPLOYMENT_MODE='systemd-xray'
    XRAY_MODE='external'
    PROXY_SERVICE_UNITS='xray.service'
    warn '检测到独立 Xray，但没有 mmw-agent.service；将按独立 Xray 验证。'
    return 0
  fi

  if service_loaded mmwx.service; then
    die '这里只检测到妙妙屋X主控端，没有 Agent/Xray；主控机不需要套用代理节点调优。'
  fi
  die '没有检测到 mmw-agent、mmw-agent Docker 容器或独立 xray.service。'
}

fetch_profile() {
  local actual
  install -d -o root -g root -m 0700 "$UPSTREAM_DIR"
  if [ -f "$PROFILE_PATH" ] && [ ! -L "$PROFILE_PATH" ]; then
    actual="$(sha256sum "$PROFILE_PATH" | awk '{print $1}')"
    if [ "$actual" = "$EXPECTED_SHA256" ]; then
      info "复用已校验的上游脚本：${PROFILE_PATH}"
      return 0
    fi
    warn '已有上游脚本哈希不匹配，将重新下载到临时文件。'
  fi

  DOWNLOAD_TMP="$(mktemp "${UPSTREAM_DIR}/${PROFILE}.tmp.XXXXXX")"
  info "下载固定提交 ${UPSTREAM_COMMIT:0:12} 的 ${PROFILE}"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
    -o "$DOWNLOAD_TMP" "${UPSTREAM_BASE}/${PROFILE}"
  actual="$(sha256sum "$DOWNLOAD_TMP" | awk '{print $1}')"
  [ "$actual" = "$EXPECTED_SHA256" ] ||
    die "上游脚本 SHA-256 校验失败：expected=${EXPECTED_SHA256} actual=${actual}"
  install -o root -g root -m 0700 "$DOWNLOAD_TMP" "$PROFILE_PATH"
  rm -f -- "$DOWNLOAD_TMP"
  DOWNLOAD_TMP=''
  info 'SHA-256 校验通过。'
}

scan_sysctl_conflicts() {
  local file canonical identity key escaped file_has_conflict seen_ids=$'\n'
  SYSCTL_CONFLICT_FILES=()
  SYSCTL_CONFLICT_COUNT=0
  shopt -s nullglob
  for file in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [ -f "$file" ] || continue
    canonical="$(readlink -f -- "$file" 2>/dev/null || true)"
    if [ -z "$canonical" ] || [ ! -f "$canonical" ]; then
      continue
    fi
    [ "$canonical" != "$UPSTREAM_SYSCTL_FILE" ] || continue
    case "$canonical" in
      *$'\n'* | *$'\t'* | *'|'*) die "sysctl 路径包含不支持的字符：${canonical}" ;;
    esac
    identity="$(stat -c '%d:%i' "$canonical")"
    case "$seen_ids" in
      *$'\n'"${identity}"$'\n'*) continue ;;
    esac
    seen_ids+="${identity}"$'\n'
    file_has_conflict=0
    for key in "${MANAGED_SYSCTL_KEYS[@]}"; do
      escaped="${key//./\\.}"
      if grep -Eq "^[[:space:]]*${escaped}[[:space:]]*=" "$canonical"; then
        warn "sysctl 冲突：${key} 已在 ${canonical} 中定义。"
        file_has_conflict=1
        SYSCTL_CONFLICT_COUNT=$((SYSCTL_CONFLICT_COUNT + 1))
      fi
    done
    if [ "$file_has_conflict" -eq 1 ]; then
      SYSCTL_CONFLICT_FILES+=("$canonical")
    fi
  done
  shopt -u nullglob
}

managed_sysctl_regex() {
  local key escaped regex='^[[:space:]]*('
  for key in "${MANAGED_SYSCTL_KEYS[@]}"; do
    escaped="${key//./\\.}"
    if [ "$regex" != '^[[:space:]]*(' ]; then
      regex+='|'
    fi
    regex+="$escaped"
  done
  regex+=')[[:space:]]*='
  printf '%s\n' "$regex"
}

migrate_sysctl_conflicts() {
  local regex index=0 file backup tmp uid gid mode backup_hash post_hash
  [ "$SYSCTL_CONFLICT_COUNT" -gt 0 ] || return 0
  [ ! -e "$SYSCTL_MIGRATION_MANIFEST" ] ||
    die "检测到已有迁移清单且出现了新的 sysctl 冲突：${SYSCTL_MIGRATION_MANIFEST}。请先恢复原始状态并人工检查。"

  install -d -o root -g root -m 0700 "$WRAPPER_STATE_DIR" "$SYSCTL_BACKUP_DIR"
  : >"$SYSCTL_MIGRATION_MANIFEST"
  chmod 0600 "$SYSCTL_MIGRATION_MANIFEST"
  MIGRATION_PENDING=1
  regex="$(managed_sysctl_regex)"

  for file in "${SYSCTL_CONFLICT_FILES[@]}"; do
    case "$file" in
      /etc/sysctl.conf | /etc/sysctl.d/*.conf) ;;
      *) die "符号链接目标不在允许的 /etc sysctl 范围内，拒绝自动迁移：${file}" ;;
    esac
    if [ ! -f "$file" ] || [ -L "$file" ]; then
      die "只允许迁移普通文件：${file}"
    fi
    uid="$(stat -c '%u' "$file")"
    gid="$(stat -c '%g' "$file")"
    mode="$(stat -c '%a' "$file")"
    [ "$uid" = '0' ] || die "拒绝迁移非 root 所有的 sysctl 文件：${file}"

    index=$((index + 1))
    backup="${SYSCTL_BACKUP_DIR}/$(printf '%03d.conf' "$index")"
    [ ! -e "$backup" ] || die "迁移备份路径已存在：${backup}"
    cp -a -- "$file" "$backup"
    backup_hash="$(sha256sum "$backup" | awk '{print $1}')"
    tmp="$(mktemp "${file}.mmwx.XXXXXX")"
    awk -v managed_re="$regex" '$0 !~ managed_re {print}' "$file" >"$tmp"
    post_hash="$(sha256sum "$tmp" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\n' "$file" "$backup" "$backup_hash" "$post_hash" >>"$SYSCTL_MIGRATION_MANIFEST"
    install -o "$uid" -g "$gid" -m "$mode" "$tmp" "$file"
    rm -f -- "$tmp"
    info "已备份并迁移重复 sysctl 键：${file}"
  done
  info "sysctl 原始文件备份目录：${SYSCTL_BACKUP_DIR}"
}

restore_sysctl_migrations() {
  local apply_runtime="${1:-1}" original backup backup_hash post_hash current_hash
  local tmp failures=0
  [ -s "$SYSCTL_MIGRATION_MANIFEST" ] || {
    MIGRATION_PENDING=0
    if [ -e "$SYSCTL_MIGRATION_MANIFEST" ] && [ ! -L "$SYSCTL_MIGRATION_MANIFEST" ]; then
      rm -f -- "$SYSCTL_MIGRATION_MANIFEST"
      rmdir -- "$SYSCTL_BACKUP_DIR" 2>/dev/null || true
    fi
    return 0
  }
  MIGRATION_PENDING=0

  while IFS=$'\t' read -r original backup backup_hash post_hash; do
    if [ -z "$original" ] || [ -z "$backup" ]; then
      continue
    fi
    case "$original" in
      /etc/sysctl.conf | /etc/sysctl.d/*.conf) ;;
      *) warn "迁移清单包含不允许的原路径：${original}"; failures=$((failures + 1)); continue ;;
    esac
    case "$backup" in
      "${SYSCTL_BACKUP_DIR}"/*.conf) ;;
      *) warn "迁移清单包含不允许的备份路径：${backup}"; failures=$((failures + 1)); continue ;;
    esac
    if [ ! -f "$backup" ] || [ -L "$backup" ] ||
      [ "$(sha256sum "$backup" 2>/dev/null | awk '{print $1}')" != "$backup_hash" ]; then
      warn "sysctl 备份缺失或哈希异常：${backup}"
      failures=$((failures + 1))
      continue
    fi
    if [ ! -f "$original" ] || [ -L "$original" ]; then
      warn "sysctl 原路径类型已经改变，拒绝覆盖：${original}"
      failures=$((failures + 1))
      continue
    fi
    current_hash="$(sha256sum "$original" | awk '{print $1}')"
    if [ "$current_hash" = "$backup_hash" ]; then
      info "sysctl 文件已经是原始版本：${original}"
      continue
    fi
    if [ "$current_hash" != "$post_hash" ]; then
      warn "sysctl 文件迁移后被外部修改，拒绝覆盖：${original}"
      failures=$((failures + 1))
      continue
    fi
    tmp="$(mktemp "${original}.mmwx-restore.XXXXXX")"
    cp --preserve=all -- "$backup" "$tmp"
    mv -f -- "$tmp" "$original"
    info "已恢复原始 sysctl 文件：${original}"
  done <"$SYSCTL_MIGRATION_MANIFEST"

  [ "$failures" -eq 0 ] || return 1
  while IFS=$'\t' read -r original backup backup_hash post_hash; do
    : "$original" "$backup_hash" "$post_hash"
    case "$backup" in
      "${SYSCTL_BACKUP_DIR}"/*.conf) rm -f -- "$backup" ;;
      *) return 1 ;;
    esac
  done <"$SYSCTL_MIGRATION_MANIFEST"
  rm -f -- "$SYSCTL_MIGRATION_MANIFEST"
  rmdir -- "$SYSCTL_BACKUP_DIR" 2>/dev/null || true
  if [ "$apply_runtime" = '1' ]; then
    sysctl --system >/dev/null || {
      warn '原始 sysctl 文件已恢复，但 sysctl --system 执行失败。'
      return 1
    }
  fi
}

handle_sysctl_conflicts() {
  local answer=''
  scan_sysctl_conflicts
  [ "$SYSCTL_CONFLICT_COUNT" -gt 0 ] || return 0
  warn "检测到 ${SYSCTL_CONFLICT_COUNT} 个重复 sysctl 定义，已按真实文件路径去重。"
  if [ "$AUTO_MIGRATE_SYSCTL" != '1' ]; then
    [ -r /dev/tty ] || die '非交互模式发现 sysctl 冲突；审查后可显式设置 AUTO_MIGRATE_SYSCTL=1。'
    printf '\n脚本可以逐文件完整备份，只移除本项目接管的重复键，并在恢复菜单中还原。\n' >/dev/tty
    printf '输入 MIGRATE 允许迁移；其他输入取消：' >/dev/tty
    IFS= read -r answer </dev/tty
    [ "$answer" = 'MIGRATE' ] || die '已取消；没有修改 sysctl 文件。'
  fi
  migrate_sysctl_conflicts
  scan_sysctl_conflicts
  [ "$SYSCTL_CONFLICT_COUNT" -eq 0 ] || die '迁移后仍存在 sysctl 冲突，已停止。'
}

show_summary() {
  warn '上游 debian-vps-tuning 仍是 v0.1.0-rc.8 预发布版；请保留服务商控制台或快照。'
  info "包装脚本版本：${WRAPPER_VERSION}"
  info "档位：${PROFILE}；内存：${MEMORY_MIB} MiB"
  info "妙妙屋X部署：${DEPLOYMENT_MODE}；Xray模式：${XRAY_MODE}"
  info "调优策略：${TUNING_MODE_LABEL}；BDP 缓冲余量：${MODE_BUFFER_PERCENT}%"
  info "套餐带宽：${PORT_SPEED_MBPS} Mbps；目标 RTT：${BUFFER_TARGET_RTT_MS} ms"
  info "理论 BDP：${BUFFER_BDP_BYTES} 字节；余量后需求：${BUFFER_REQUIRED_BYTES} 字节"
  info "socket 缓冲上限：${SELECTED_BUF_MAX} 字节；覆盖约 ${BUFFER_COVERAGE_MS} ms"
  if [ "$PORT_SPEED_MBPS" -gt 1000 ]; then
    warn "自定义带宽超过上游验证范围；使用上游 1000 Mbps 兼容输入和显式 ${SELECTED_BUF_MAX} 字节缓冲。"
  fi
  if [ "$TUNING_MODE" = 'extreme' ]; then
    warn '极限调优会提高单连接可增长的 socket 内存上限；1 GiB VPS 必须观察可用内存和 swap。'
  fi
  info "自动 swap：${ENABLE_SWAP}；大小：${SWAP_MB} MiB"
}

run_upstream() {
  local upstream_action="$1"
  env \
    PORT_SPEED_MBPS="$UPSTREAM_PORT_SPEED_MBPS" \
    BUFFER_TARGET_RTT_MS="$BUFFER_TARGET_RTT_MS" \
    BUF_MAX="$BUF_MAX_VALUE" \
    ENABLE_SWAP="$ENABLE_SWAP" \
    SWAP_MB="$SWAP_MB" \
    bash "$PROFILE_PATH" "$upstream_action"
}

strict_verify() {
  if [ "$DEPLOYMENT_MODE" = 'docker-agent-embedded' ]; then
    run_upstream verify
    [ "$(docker inspect --format '{{.State.Running}}' "$MMWX_CONTAINER")" = 'true' ] ||
      die "Docker 容器 ${MMWX_CONTAINER} 未运行。"
    [ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$MMWX_CONTAINER")" = 'host' ] ||
      die "Docker 容器 ${MMWX_CONTAINER} 不再使用 host 网络。"
    info "Docker Agent ${MMWX_CONTAINER} 正在运行且使用 host 网络。"
  else
    env \
      PORT_SPEED_MBPS="$UPSTREAM_PORT_SPEED_MBPS" \
      BUFFER_TARGET_RTT_MS="$BUFFER_TARGET_RTT_MS" \
      BUF_MAX="$BUF_MAX_VALUE" \
      ENABLE_SWAP="$ENABLE_SWAP" \
      SWAP_MB="$SWAP_MB" \
      REQUIRE_PROXY_SERVICE=1 \
      PROXY_SERVICE_UNITS="$PROXY_SERVICE_UNITS" \
      bash "$PROFILE_PATH" verify
  fi
}

save_settings() {
  local tmp
  install -d -o root -g root -m 0700 "$WRAPPER_STATE_DIR"
  tmp="$(mktemp "${WRAPPER_STATE_FILE}.tmp.XXXXXX")"
  {
    printf 'TUNING_MODE=%s\n' "$TUNING_MODE"
    printf 'PORT_SPEED_MBPS=%s\n' "$PORT_SPEED_MBPS"
    printf 'UPSTREAM_PORT_SPEED_MBPS=%s\n' "$UPSTREAM_PORT_SPEED_MBPS"
    printf 'BUFFER_TARGET_RTT_MS=%s\n' "$BUFFER_TARGET_RTT_MS"
    printf 'BUF_MAX=%s\n' "$BUF_MAX_VALUE"
    printf 'ENABLE_SWAP=%s\n' "$ENABLE_SWAP"
    printf 'SWAP_MB=%s\n' "$SWAP_MB"
    printf 'PROFILE=%s\n' "$PROFILE"
    printf 'UPSTREAM_COMMIT=%s\n' "$UPSTREAM_COMMIT"
  } >"$tmp"
  install -o root -g root -m 0600 "$tmp" "$WRAPPER_STATE_FILE"
  rm -f -- "$tmp"
}

confirm_apply() {
  local expected='APPLY' answer=''
  [ "$AUTO_APPLY" = '1' ] && return 0
  [ -r /dev/tty ] || die '没有交互终端；确认已建立快照后可设置 AUTO_APPLY=1。'
  printf '\n即将修改 sysctl、qdisc、journald，并可能创建 swap。\n' >/dev/tty
  if [ "$TUNING_MODE" = 'extreme' ]; then
    expected='EXTREME'
  fi
  printf '请确认服务商控制台可用且已保留当前 SSH 会话。输入 %s 继续：' "$expected" >/dev/tty
  IFS= read -r answer </dev/tty
  [ "$answer" = "$expected" ] || die '已取消，没有应用调优。'
}

prepare() {
  validate_wrapper_state_paths
  load_saved_settings
  validate_inputs
  select_profile
  ensure_dependencies
  fetch_profile
}

preflight_action() {
  prepare
  detect_mmwx
  show_summary
  scan_sysctl_conflicts
  [ "$SYSCTL_CONFLICT_COUNT" -eq 0 ] ||
    die '预检发现重复 sysctl；使用“全新安装”或“覆盖重新安装”可在确认后备份并迁移。'
  run_upstream preflight
}

perform_install() {
  [ ! -f "$UPSTREAM_STATE_FILE" ] || die '检测到现有优化状态；请使用“覆盖重新安装”。'
  handle_sysctl_conflicts
  run_upstream preflight
  confirm_apply
  run_upstream apply
  save_settings
  MIGRATION_PENDING=0
  if ! strict_verify; then
    warn "调优已应用，但妙妙屋X严格验证失败。请运行：bash $0 restore"
    return 1
  fi
  info '调优和妙妙屋X服务立即验证通过。'
  printf '\n请先新开一个 SSH 会话测试，然后手动执行 reboot。\n'
  printf '重启后运行：bash %q verify\n' "$0"
}

install_action() {
  prepare
  detect_mmwx
  show_summary
  perform_install
}

confirm_reinstall() {
  local answer=''
  [ "$AUTO_APPLY" = '1' ] && return 0
  [ -r /dev/tty ] || die '覆盖重装需要交互确认；自动化时需显式设置 AUTO_APPLY=1。'
  printf '\n覆盖重装会先清理当前管理状态和脚本创建的 swap，再使用新参数安装。\n' >/dev/tty
  printf '输入 REINSTALL 继续：' >/dev/tty
  IFS= read -r answer </dev/tty
  [ "$answer" = 'REINSTALL' ] || die '已取消覆盖重装。'
}

reinstall_action() {
  prepare
  detect_mmwx
  show_summary
  if [ -f "$UPSTREAM_STATE_FILE" ]; then
    confirm_reinstall
    env PURGE_CREATED_SWAP=1 bash "$PROFILE_PATH" rollback
    info '旧的管理状态已安全清理，sysctl 原始备份继续保留供最终恢复。'
  else
    warn '没有检测到现有管理状态，将按全新安装继续。'
  fi
  perform_install
}

verify_action() {
  prepare
  detect_mmwx
  show_summary
  strict_verify
  info '重启后验证通过。'
}

status_action() {
  prepare
  show_summary
  run_upstream status
  if [ -s "$SYSCTL_MIGRATION_MANIFEST" ]; then
    info "存在可恢复的 sysctl 原始备份：${SYSCTL_BACKUP_DIR}"
  else
    info '没有由 v2 自动迁移的 sysctl 备份。'
  fi
  systemctl --no-pager --full status mmw-agent.service xray.service 2>/dev/null || true
  if command -v docker >/dev/null 2>&1 && docker inspect "$MMWX_CONTAINER" >/dev/null 2>&1; then
    docker inspect --format 'Container={{.Name}} Running={{.State.Running}} Network={{.HostConfig.NetworkMode}}' "$MMWX_CONTAINER"
  fi
}

rollback_action() {
  prepare
  run_upstream rollback
  restore_sysctl_migrations 1 || die '上游已回滚，但自动迁移的 sysctl 原文件未能安全恢复。'
  info '系统配置和迁移的 sysctl 文件已回滚；上游默认保留其创建的应急 swap。'
}

confirm_restore() {
  local answer=''
  [ "$AUTO_APPLY" = '1' ] && return 0
  [ -r /dev/tty ] || die '恢复原始状态需要交互确认；自动化时需显式设置 AUTO_APPLY=1。'
  printf '\n将恢复原始 qdisc/sysctl/journald，并清理脚本创建的 swap。\n' >/dev/tty
  printf '输入 RESTORE 继续：' >/dev/tty
  IFS= read -r answer </dev/tty
  [ "$answer" = 'RESTORE' ] || die '已取消恢复。'
}

restore_action() {
  prepare
  confirm_restore
  if [ -f "$UPSTREAM_STATE_FILE" ]; then
    env PURGE_CREATED_SWAP=1 bash "$PROFILE_PATH" rollback
  else
    info '没有检测到上游管理状态。'
  fi
  restore_sysctl_migrations 1 || die '拒绝覆盖被外部修改的 sysctl 文件；原始备份和清单已保留。'
  rm -f -- "$WRAPPER_STATE_FILE"
  rmdir -- "$WRAPPER_STATE_DIR" 2>/dev/null || true
  info '已恢复脚本可证明和管理的原始状态，并清理脚本创建的 swap。'
}

show_main_menu() {
  local choice=''
  [ -r /dev/tty ] || die '主菜单需要交互终端；自动化请直接指定 install/reinstall/status/restore/verify。'
  printf '\n妙妙屋X Debian VPS 调优 v%s\n' "$WRAPPER_VERSION" >/dev/tty
  printf '  1. 全新安装（保守 / 激进 / 极限）\n' >/dev/tty
  printf '  2. 覆盖重新安装\n' >/dev/tty
  printf '  3. 当前优化状态\n' >/dev/tty
  printf '  4. 恢复到原始状态\n' >/dev/tty
  printf '  5. 生效检测\n' >/dev/tty
  printf '  0. 退出\n' >/dev/tty
  printf '请选择：' >/dev/tty
  IFS= read -r choice </dev/tty
  case "$choice" in
    1) ACTION='install'; install_action ;;
    2) ACTION='reinstall'; reinstall_action ;;
    3) ACTION='status'; status_action ;;
    4) ACTION='restore'; restore_action ;;
    5) ACTION='verify'; verify_action ;;
    0) info '已退出；没有执行操作。' ;;
    *) die '无效的主菜单选项。' ;;
  esac
}

main() {
  case "$ACTION" in
    -h | --help | help)
      usage
      ;;
    menu)
      need_root
      show_main_menu
      ;;
    install | reinstall | apply | preflight | verify | status | restore | rollback | purge)
      need_root
      case "$ACTION" in
        install | apply) install_action ;;
        reinstall) reinstall_action ;;
        preflight) preflight_action ;;
        verify) verify_action ;;
        status) status_action ;;
        rollback) rollback_action ;;
        restore | purge) restore_action ;;
      esac
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

if [ "${MMWX_TUNE_SOURCE_ONLY:-0}" != '1' ]; then
  main
fi
