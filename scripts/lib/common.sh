#!/usr/bin/env bash
# lib/common.sh — setup/ 与 faults/ 脚本的公共函数库
#
# 用法：在脚本开头 source 本文件（路径相对于调用脚本）：
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../lib/common.sh"
#
# 说明：各 lab 目录的 check.sh 是自带 helper 的独立脚本，【不】依赖本文件；
#       本文件只服务于 scripts/setup/*.sh 与 scripts/faults/*.sh。
#       因此拷贝 setup/faults 脚本时必须连同 lib/ 目录一起拷。
#
# 约定：
#   - 颜色输出统一走 log_info / log_ok / log_warn / log_err / banner
#   - 破坏性操作前调用 confirm "提示语"（ASSUME_YES=1 可免交互）
#   - 布尔检查用 pass / fail（内部计数，脚本末尾调用 exit_report）
#   - 轮询等待用 wait_for / wait_for_healthy / wait_for_cmd

set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色（非 TTY 时自动降级为纯文本，方便重定向到日志）
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_BOLD=$'\033[1m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_RED=''
  readonly C_GREEN=''
  readonly C_YELLOW=''
  readonly C_BLUE=''
  readonly C_BOLD=''
  readonly C_RESET=''
fi

_PASS_COUNT=0
_FAIL_COUNT=0

log_info()  { printf '%s[INFO]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
log_err()   { printf '%s[FAIL]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
banner()    { printf '\n%s========== %s ==========%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# pass/fail：布尔检查 helper，累计计数
# 用法：kubectl get -n kube-system ds/calico-node &>/dev/null && pass "calico 存在" || fail "calico 缺失"
pass() { _PASS_COUNT=$((_PASS_COUNT + 1)); printf '%s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { _FAIL_COUNT=$((_FAIL_COUNT + 1)); printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# exit_report：脚本结尾调用；有 fail 项时以非零码退出
# 注意：set -e 下 "cmd && pass || fail" 写法安全；exit_report 需作为脚本最后一条命令，
#       其非零返回码会成为脚本退出码。
exit_report() {
  local total=$((_PASS_COUNT + _FAIL_COUNT))
  printf '\n%s结果: %s 通过 / %s 失败 (共 %s 项)%s\n' \
    "$C_BOLD" "$_PASS_COUNT" "$_FAIL_COUNT" "$total" "$C_RESET"
  [ "$_FAIL_COUNT" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# confirm：交互确认。非交互（stdin 非 TTY）或 ASSUME_YES=1 时直接继续。
#   confirm "确定要在 master 上执行 kubeadm reset 吗" || exit 1
# ---------------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-}"
confirm() {
  local prompt="${1:-继续吗}"
  if [ "$ASSUME_YES" = "1" ]; then
    log_warn "非交互模式（ASSUME_YES=1），跳过确认: ${prompt}"
    return 0
  fi
  if [ ! -t 0 ]; then
    log_warn "stdin 非 TTY，默认继续: ${prompt}"
    return 0
  fi
  local reply
  read -r -p "$(printf '%s%s [y/N]%s ' "$C_YELLOW" "$prompt" "$C_RESET")" reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) log_info "已取消"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 等待函数
#   wait_for "描述" <超时秒> <间隔秒> '<命令>'      通用轮询
#   wait_for_healthy "ds/calico-node -n kube-system" [超时秒]
#   wait_for_cmd 'curl -fsSL http://...' [超时秒]
# ---------------------------------------------------------------------------
wait_for() {
  local desc="$1" timeout_s="$2" interval_s="$3" cmd="$4"
  local elapsed=0
  log_info "等待: ${desc}（最长 ${timeout_s}s）"
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if bash -c "$cmd" >/dev/null 2>&1; then
      log_ok "完成: ${desc}（耗时约 ${elapsed}s）"
      return 0
    fi
    sleep "$interval_s"
    elapsed=$((elapsed + interval_s))
    printf '  ... %ss\r' "$elapsed"
  done
  printf '\n'
  log_err "超时: ${desc}（${timeout_s}s）"
  return 1
}

# wait_for_healthy <资源> [超时秒]
#   资源写法同 kubectl wait，如 "ds/calico-node -n kube-system"、"deployment/metrics-server -n kube-system"。
#   Deployment 有 Available condition；StatefulSet/DaemonSet 实测（k8s 1.35）不上报
#   Available condition（DS status 只有副本计数字段），对 STS/DS 请改用
#   wait_for + jsonpath='{.status.readyReplicas}' / '{.status.numberReady}' 判断。
#   前提：调用方已 export KUBECONFIG（或存在 ~/.kube/config）。
wait_for_healthy() {
  local resource="$1" timeout_s="${2:-300}"
  wait_for "${resource} Available" "$timeout_s" 5 \
    "kubectl wait --for=condition=Available --timeout=5s ${resource}"
}

# wait_for_cmd <完整命令> [超时秒]：命令本身就是描述，懒人版 wait_for
wait_for_cmd() {
  local cmd="$1" timeout_s="${2:-120}"
  wait_for "命令成功: ${cmd}" "$timeout_s" 5 "$cmd"
}

# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------
# require_root：setup/faults 类脚本统一入口检查
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_err "请用 root 运行: sudo bash $0"
    exit 1
  fi
}

# pkg_installed <包名>：dpkg 级判断（docker 相关要区分 containerd 与 containerd.io）
pkg_installed() { dpkg -s "$1" &>/dev/null; }

# retry <次数> <命令...>：网络类操作重试
retry() {
  local n="$1"; shift
  local i
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    log_warn "第 ${i}/${n} 次失败，5s 后重试: $*"
    sleep 5
  done
  log_err "重试 ${n} 次仍失败: $*"
  return 1
}
