#!/usr/bin/env bash
# 妙妙屋X Debian VPS 调优包装脚本
# 固定使用 debian-vps-tuning v0.1.0-rc.8 的已审阅提交。

set -Eeuo pipefail

readonly WRAPPER_VERSION='1.1.0'
readonly UPSTREAM_COMMIT='7bdd57d9de275ae614132272fea0d92632218426'
readonly UPSTREAM_BASE="https://raw.githubusercontent.com/alieismy/debian-vps-tuning/${UPSTREAM_COMMIT}"
readonly UPSTREAM_DIR='/usr/local/lib/mmwx-vps-tune'
readonly WRAPPER_STATE_DIR='/var/lib/mmwx-vps-tune'
readonly WRAPPER_STATE_FILE="${WRAPPER_STATE_DIR}/wrapper.env"
readonly UPSTREAM_STATE_FILE='/var/lib/proxy-vps-tuning/state.json'
readonly MAX_BUF_MAX=67108864

ACTION="${1:-apply}"
PORT_SPEED_MBPS_INPUT="${PORT_SPEED_MBPS:-}"
BUFFER_TARGET_RTT_MS_INPUT="${BUFFER_TARGET_RTT_MS:-}"
ENABLE_SWAP_INPUT="${ENABLE_SWAP:-}"
SWAP_MB_INPUT="${SWAP_MB:-}"
PORT_SPEED_MBPS=''
UPSTREAM_PORT_SPEED_MBPS=''
BUFFER_TARGET_RTT_MS=''
ENABLE_SWAP=''
SWAP_MB=''
BUF_MAX_VALUE='auto'
SELECTED_BUF_MAX=''
BUFFER_BDP_BYTES=''
BUFFER_COVERAGE_MS=''
AUTO_APPLY="${AUTO_APPLY:-0}"
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

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${DOWNLOAD_TMP:-}" ] && [ -f "$DOWNLOAD_TMP" ]; then
    rm -f -- "$DOWNLOAD_TMP"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
妙妙屋X Debian VPS 调优包装脚本

用法：
  PORT_SPEED_MBPS=200 bash mmwx-vps-tune.sh apply
  bash mmwx-vps-tune.sh preflight
  bash mmwx-vps-tune.sh verify
  bash mmwx-vps-tune.sh status
  bash mmwx-vps-tune.sh rollback
  bash mmwx-vps-tune.sh purge

动作：
  apply       自动预检，确认后应用；默认动作
  preflight   只执行预检，不应用调优
  verify      重启后验证调优和妙妙屋X服务
  status      查看调优、队列、监听端口和 swap 状态
  rollback    回滚网络和系统配置，保留脚本创建的 swap
  purge       回滚并清理脚本创建的 swap

环境变量：
  PORT_SPEED_MBPS=100..10000      VPS 套餐标称带宽；不设置时显示选择菜单
  BUFFER_TARGET_RTT_MS=20..500    目标 RTT，默认 200
  ENABLE_SWAP=0|1                 没有活动 swap 时是否创建，默认 1
  SWAP_MB=512..4096               swap 大小，默认 1024
  AUTO_APPLY=0|1                  设为 1 跳过 APPLY 确认
  INSTALL_DEPS=0|1                缺少依赖时自动安装，默认 1
  MMWX_CONTAINER=名称             Docker Agent 容器名，默认 mmw-agent

脚本不会升级系统、修改 UFW、修改妙妙屋X配置或自动重启 VPS。
超过 1000 Mbps 时，包装脚本会使用上游 1000 Mbps 兼容路径，并根据实际
带宽和目标 RTT 显式选择 16/32/64 MiB 缓冲；需求超过 64 MiB 时安全拒绝。
EOF
}

need_root() {
  [ "${EUID}" -eq 0 ] || die '请先进入 root shell 再运行。'
}

read_saved_value() {
  local key="$1"
  [ -f "$WRAPPER_STATE_FILE" ] && [ ! -L "$WRAPPER_STATE_FILE" ] || return 0
  [ "$(stat -c '%u' "$WRAPPER_STATE_FILE" 2>/dev/null || true)" = '0' ] ||
    die "状态文件所有权异常：${WRAPPER_STATE_FILE}"
  awk -F= -v wanted="$key" '$1 == wanted {print $2; exit}' "$WRAPPER_STATE_FILE"
}

choose_bandwidth() {
  local saved default_speed choice custom_speed
  if [ -n "$PORT_SPEED_MBPS_INPUT" ]; then
    PORT_SPEED_MBPS="$PORT_SPEED_MBPS_INPUT"
    return 0
  fi

  saved="$(read_saved_value PORT_SPEED_MBPS)"
  default_speed="${saved:-200}"
  if { [ "$ACTION" = 'apply' ] || [ "$ACTION" = 'preflight' ]; } && [ -r /dev/tty ]; then
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

load_saved_settings() {
  local saved=''
  choose_bandwidth
  if [ -n "$BUFFER_TARGET_RTT_MS_INPUT" ]; then
    BUFFER_TARGET_RTT_MS="$BUFFER_TARGET_RTT_MS_INPUT"
  else
    saved="$(read_saved_value BUFFER_TARGET_RTT_MS)"
    BUFFER_TARGET_RTT_MS="${saved:-200}"
  fi
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
  [[ "$PORT_SPEED_MBPS" =~ ^[0-9]{3,5}$ ]] ||
    die 'PORT_SPEED_MBPS 必须是 100–10000 的整数。'
  PORT_SPEED_MBPS=$((10#$PORT_SPEED_MBPS))
  [ "$PORT_SPEED_MBPS" -ge 100 ] && [ "$PORT_SPEED_MBPS" -le 10000 ] ||
    die 'PORT_SPEED_MBPS 必须在 100–10000 之间。'

  [[ "$BUFFER_TARGET_RTT_MS" =~ ^[0-9]{2,3}$ ]] ||
    die 'BUFFER_TARGET_RTT_MS 必须是 20–500 的整数。'
  BUFFER_TARGET_RTT_MS=$((10#$BUFFER_TARGET_RTT_MS))
  [ "$BUFFER_TARGET_RTT_MS" -ge 20 ] && [ "$BUFFER_TARGET_RTT_MS" -le 500 ] ||
    die 'BUFFER_TARGET_RTT_MS 必须在 20–500 之间。'

  BUFFER_BDP_BYTES=$((PORT_SPEED_MBPS * 125 * BUFFER_TARGET_RTT_MS))
  if [ "$BUFFER_BDP_BYTES" -le 16777216 ]; then
    SELECTED_BUF_MAX=16777216
  elif [ "$BUFFER_BDP_BYTES" -le 33554432 ]; then
    SELECTED_BUF_MAX=33554432
  elif [ "$BUFFER_BDP_BYTES" -le "$MAX_BUF_MAX" ]; then
    SELECTED_BUF_MAX="$MAX_BUF_MAX"
  else
    local max_speed
    max_speed=$((MAX_BUF_MAX / (125 * BUFFER_TARGET_RTT_MS)))
    die "${PORT_SPEED_MBPS} Mbps × ${BUFFER_TARGET_RTT_MS} ms 需要超过 64 MiB 缓冲；当前安全上限约为 ${max_speed} Mbps。请降低目标 RTT 或不要使用此脚本。"
  fi
  BUFFER_COVERAGE_MS=$((SELECTED_BUF_MAX * 8 / (PORT_SPEED_MBPS * 1000)))
  if [ "$PORT_SPEED_MBPS" -le 1000 ]; then
    UPSTREAM_PORT_SPEED_MBPS="$PORT_SPEED_MBPS"
    BUF_MAX_VALUE='auto'
  else
    UPSTREAM_PORT_SPEED_MBPS=1000
    BUF_MAX_VALUE="$SELECTED_BUF_MAX"
  fi

  [ "$ENABLE_SWAP" = '0' ] || [ "$ENABLE_SWAP" = '1' ] ||
    die 'ENABLE_SWAP 只能为 0 或 1。'
  [[ "$SWAP_MB" =~ ^[0-9]{3,4}$ ]] || die 'SWAP_MB 必须是整数 MiB。'
  SWAP_MB=$((10#$SWAP_MB))
  [ "$SWAP_MB" -ge 512 ] && [ "$SWAP_MB" -le 4096 ] ||
    die 'SWAP_MB 必须在 512–4096 之间。'
  [ "$AUTO_APPLY" = '0' ] || [ "$AUTO_APPLY" = '1' ] ||
    die 'AUTO_APPLY 只能为 0 或 1。'
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
    systemctl swapon swapoff mkswap findmnt flock pgrep jq stat readlink install; do
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

show_summary() {
  warn '上游 debian-vps-tuning 仍是 v0.1.0-rc.8 预发布版；请保留服务商控制台或快照。'
  info "包装脚本版本：${WRAPPER_VERSION}"
  info "档位：${PROFILE}；内存：${MEMORY_MIB} MiB"
  info "妙妙屋X部署：${DEPLOYMENT_MODE}；Xray模式：${XRAY_MODE}"
  info "套餐带宽：${PORT_SPEED_MBPS} Mbps；目标 RTT：${BUFFER_TARGET_RTT_MS} ms"
  info "理论 BDP：${BUFFER_BDP_BYTES} 字节；缓冲档位：${SELECTED_BUF_MAX} 字节；覆盖约 ${BUFFER_COVERAGE_MS} ms"
  if [ "$PORT_SPEED_MBPS" -gt 1000 ]; then
    warn "自定义带宽超过上游验证范围；使用上游 1000 Mbps 兼容输入和显式 ${SELECTED_BUF_MAX} 字节缓冲。"
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
  [ "$AUTO_APPLY" = '1' ] && return 0
  [ -r /dev/tty ] || die '没有交互终端；确认已建立快照后可设置 AUTO_APPLY=1。'
  printf '\n即将修改 sysctl、qdisc、journald，并可能创建 swap。\n' >/dev/tty
  printf '请确认服务商控制台可用且已保留当前 SSH 会话。输入 APPLY 继续：' >/dev/tty
  local answer=''
  IFS= read -r answer </dev/tty
  [ "$answer" = 'APPLY' ] || die '已取消，没有应用调优。'
}

prepare() {
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
  run_upstream preflight
}

apply_action() {
  prepare
  detect_mmwx
  show_summary
  if [ -f "$UPSTREAM_STATE_FILE" ]; then
    warn '检测到现有调优状态，将先显示状态；上游脚本会执行幂等验证或安全拒绝。'
    run_upstream status
  else
    run_upstream preflight
  fi
  confirm_apply
  run_upstream apply
  save_settings
  if ! strict_verify; then
    warn "调优已应用，但妙妙屋X严格验证失败。请运行：bash $0 rollback"
    return 1
  fi
  info '调优和妙妙屋X服务立即验证通过。'
  printf '\n请先新开一个 SSH 会话测试，然后手动执行 reboot。\n'
  printf '重启后运行：bash %q verify\n' "$0"
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
  systemctl --no-pager --full status mmw-agent.service xray.service 2>/dev/null || true
  if command -v docker >/dev/null 2>&1 && docker inspect "$MMWX_CONTAINER" >/dev/null 2>&1; then
    docker inspect --format 'Container={{.Name}} Running={{.State.Running}} Network={{.HostConfig.NetworkMode}}' "$MMWX_CONTAINER"
  fi
}

rollback_action() {
  prepare
  run_upstream rollback
  info '系统配置已回滚；上游默认保留其创建的应急 swap。'
}

purge_action() {
  prepare
  env PURGE_CREATED_SWAP=1 bash "$PROFILE_PATH" rollback
  info '系统配置已回滚，并已请求安全清理上游脚本创建的 swap。'
}

main() {
  case "$ACTION" in
    -h | --help | help)
      usage
      ;;
    apply | preflight | verify | status | rollback | purge)
      need_root
      case "$ACTION" in
        apply) apply_action ;;
        preflight) preflight_action ;;
        verify) verify_action ;;
        status) status_action ;;
        rollback) rollback_action ;;
        purge) purge_action ;;
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
