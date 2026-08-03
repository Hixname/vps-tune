#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MMWX_TUNE_SOURCE_ONLY=1
# shellcheck source=../mmwx-vps-tune.sh
source "${PROJECT_ROOT}/mmwx-vps-tune.sh"

assert_case() {
  local mode="$1" speed="$2" rtt="$3" expected_buf="$4" expected_upstream="$5"
  TUNING_MODE="$mode"
  PORT_SPEED_MBPS="$speed"
  BUFFER_TARGET_RTT_MS="$rtt"
  ENABLE_SWAP=1
  SWAP_MB=1024
  validate_inputs
  [ "$SELECTED_BUF_MAX" = "$expected_buf" ] || {
    printf '[x] %s/%s/%s 缓冲错误：expected=%s actual=%s\n' \
      "$mode" "$speed" "$rtt" "$expected_buf" "$SELECTED_BUF_MAX" >&2
    exit 1
  }
  [ "$UPSTREAM_PORT_SPEED_MBPS" = "$expected_upstream" ] || {
    printf '[x] %s Mbps 上游兼容输入错误。\n' "$speed" >&2
    exit 1
  }
}

assert_case conservative 200 200 8388608 200
assert_case conservative 200 175 8388608 200
assert_case conservative 1000 175 22020096 1000
assert_case conservative 1000 200 25165824 1000
assert_case aggressive 1000 200 37748736 1000
assert_case extreme 1000 200 50331648 1000
assert_case aggressive 2000 150 56623104 1000
assert_case conservative 2684 200 67108864 1000
assert_case aggressive 1789 200 67108864 1000
assert_case extreme 1342 200 67108864 1000

for rejected_case in 'conservative 2685' 'aggressive 1790' 'extreme 1343'; do
  read -r rejected_mode rejected_speed <<<"$rejected_case"
  if TUNING_MODE="$rejected_mode" PORT_SPEED_MBPS="$rejected_speed" \
    BUFFER_TARGET_RTT_MS=200 ENABLE_SWAP=1 SWAP_MB=1024 MMWX_TUNE_SOURCE_ONLY=1 \
    bash -c 'source "$1"; validate_inputs' _ "${PROJECT_ROOT}/mmwx-vps-tune.sh" \
    >/dev/null 2>&1; then
    printf '[x] %s/%s Mbps 超过 64 MiB 但没有被拒绝。\n' \
      "$rejected_mode" "$rejected_speed" >&2
    exit 1
  fi
done

assert_normalized() {
  local function_name="$1" input="$2" expected="$3" actual
  actual="$($function_name "$input")" || {
    printf '[x] %s 无法解析输入：%s\n' "$function_name" "$input" >&2
    exit 1
  }
  [ "$actual" = "$expected" ] || {
    printf '[x] %s 解析错误：input=%s expected=%s actual=%s\n' \
      "$function_name" "$input" "$expected" "$actual" >&2
    exit 1
  }
}

assert_normalized normalize_rtt_input '175' 175
assert_normalized normalize_rtt_input '175ms' 175
assert_normalized normalize_rtt_input '175 ms' 175
assert_normalized normalize_rtt_input ' 175 MS ' 175
assert_normalized normalize_bandwidth_input '1000' 1000
assert_normalized normalize_bandwidth_input '1000M' 1000
assert_normalized normalize_bandwidth_input '1000Mbps' 1000
assert_normalized normalize_bandwidth_input ' 1000 MBPS ' 1000

if normalize_rtt_input '175 seconds' >/dev/null 2>&1; then
  printf '[x] 不应接受非 ms 的 RTT 单位。\n' >&2
  exit 1
fi
if normalize_bandwidth_input '1Gbps' >/dev/null 2>&1; then
  printf '[x] 不应隐式把 Gbps 换算为 Mbps。\n' >&2
  exit 1
fi

managed_re="$(managed_sysctl_regex)"
printf '%s\n' 'net.core.default_qdisc=fq' | grep -Eq "$managed_re"
if printf '%s\n' '# net.core.default_qdisc=fq' | grep -Eq "$managed_re"; then
  printf '[x] 注释行不应被识别为活动 sysctl。\n' >&2
  exit 1
fi

printf '[+] 调优档位、BDP、带单位输入、上游兼容和 sysctl 正则测试通过。\n'
