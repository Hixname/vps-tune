#!/usr/bin/env bash
# mmwx-vps-tune GitHub bootstrap installer

set -Eeuo pipefail

readonly INSTALLER_VERSION='2.1.0'
readonly EXPECTED_MAIN_SHA256='ffe2635174ee118879c3fb0760e7db8af8f29db454d9ca051387dc15e10be5e3'
readonly INSTALL_PATH='/usr/local/sbin/mmwx-vps-tune'
readonly DEFAULT_REPOSITORY='Hixname/vps-tune'

REPOSITORY="${MMWX_TUNE_REPO:-$DEFAULT_REPOSITORY}"
REF="${MMWX_TUNE_REF:-main}"
ACTION="${1:-menu}"
TEMP_DIR=''

info() { printf '[+] %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

[ "${EUID}" -eq 0 ] || die '请以 root 权限运行安装器。'
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die 'MMWX_TUNE_REPO 必须使用 GitHub用户名/仓库名 格式。'
if [[ ! "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$REF" == *'..'* ]]; then
  die 'MMWX_TUNE_REF 包含不安全字符。'
fi
case "$ACTION" in
  menu | install | reinstall | apply | preflight | verify | status | restore | rollback | purge) ;;
  *) die "不支持的动作：${ACTION}" ;;
esac

for command_name in awk bash curl install mktemp rm sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "缺少必要命令：${command_name}"
done

TEMP_DIR="$(mktemp -d)"
readonly MAIN_URL="https://raw.githubusercontent.com/${REPOSITORY}/${REF}/mmwx-vps-tune.sh"
readonly DOWNLOAD_PATH="${TEMP_DIR}/mmwx-vps-tune.sh"

info "安装器版本：${INSTALLER_VERSION}"
info "下载：${MAIN_URL}"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
  -o "$DOWNLOAD_PATH" "$MAIN_URL"

actual_sha256="$(sha256sum "$DOWNLOAD_PATH" | awk '{print $1}')"
[ "$actual_sha256" = "$EXPECTED_MAIN_SHA256" ] ||
  die "主脚本 SHA-256 校验失败：expected=${EXPECTED_MAIN_SHA256} actual=${actual_sha256}"

bash -n "$DOWNLOAD_PATH" || die '主脚本 Bash 语法检查失败。'
install -o root -g root -m 0700 "$DOWNLOAD_PATH" "$INSTALL_PATH"
info "安装完成：${INSTALL_PATH}"
info "开始执行：${ACTION}"

trap - EXIT
cleanup
exec "$INSTALL_PATH" "$ACTION"
