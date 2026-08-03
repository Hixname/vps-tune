#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

bash -n mmwx-vps-tune.sh
bash -n install.sh
bash -n tests/static-check.sh
bash -n tests/formula-test.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -P SCRIPTDIR \
    mmwx-vps-tune.sh install.sh tests/static-check.sh tests/formula-test.sh
else
  printf '[!] shellcheck 未安装，仅完成 Bash 语法检查。\n' >&2
fi

expected_main="$(sed -n "s/^readonly EXPECTED_MAIN_SHA256='\\([0-9a-f]\\{64\\}\\)'$/\\1/p" install.sh)"
actual_main="$(sha256sum mmwx-vps-tune.sh | awk '{print $1}')"
[ "$expected_main" = "$actual_main" ] || {
  printf '[x] install.sh 内置主脚本哈希不匹配。\n' >&2
  exit 1
}

sha256sum -c SHA256SUMS

grep -Fq "readonly UPSTREAM_COMMIT='7bdd57d9de275ae614132272fea0d92632218426'" mmwx-vps-tune.sh
grep -Fq "readonly WRAPPER_VERSION='2.1.0'" mmwx-vps-tune.sh
grep -Fq "readonly INSTALLER_VERSION='2.1.0'" install.sh
grep -Fq "readonly DEFAULT_REPOSITORY='Hixname/vps-tune'" install.sh
grep -Fq "PORT_SPEED_MBPS=100..10000" mmwx-vps-tune.sh
grep -Fq "1. 全新安装（保守 / 激进 / 极限）" mmwx-vps-tune.sh
grep -Fq "适用于 1H1G/1H2G 日常节点" mmwx-vps-tune.sh
grep -Fq 'normalize_rtt_input()' mmwx-vps-tune.sh
grep -Fq 'normalize_bandwidth_input()' mmwx-vps-tune.sh
grep -Fq 'show_runtime_diagnostics()' mmwx-vps-tune.sh
grep -Fq "readonly SYSCTL_MIGRATION_MANIFEST=" mmwx-vps-tune.sh

bash tests/formula-test.sh

printf '[+] 静态检查通过。\n'
