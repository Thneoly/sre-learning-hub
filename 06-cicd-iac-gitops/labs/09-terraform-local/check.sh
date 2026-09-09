#!/usr/bin/env bash
# Lab 09 判分脚本（Terraform local provider 终态检查）
# 运行环境：candidate VM（Ubuntu，已完成 task.md 第 1~7 步，尚未 destroy）
# 假设：工作目录 ~/labs/terraform-local；out/dev 下 3 个文件、out/prod 下 env.yaml 存在；
#       artifacts/ 含 state-list.txt、drift-plan.txt、taint-plan.txt 三份存档；
#       terraform.tfstate.d/ 下有 dev 与 prod 两个 workspace 目录
# 用法：chmod +x check.sh && ./check.sh（务必在 destroy 之前运行）
# 说明：只读检查（文件存在性/内容 grep），不执行任何 terraform 命令，不改动 state
set -u

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

WORK="$HOME/labs/terraform-local"

# 1. dev 环境三个文件（漂移修复 + taint 重建后的终态）
check "out/dev/env.yaml 存在" \
  test -f "$WORK/out/dev/env.yaml"
check "out/dev/motd.txt 存在（漂移修复后恢复）" \
  test -f "$WORK/out/dev/motd.txt"
check "out/dev/runbook.md 存在（taint 重建后恢复）" \
  test -f "$WORK/out/dev/runbook.md"
check "motd.txt 内容含 welcome to dev" \
  grep -q "welcome to dev" "$WORK/out/dev/motd.txt"

# 2. tfvars 双环境产物
check "out/prod/env.yaml 存在（双环境产物）" \
  test -f "$WORK/out/prod/env.yaml"
check "dev 的 env.yaml 含 log_level: debug" \
  grep -q "log_level: debug" "$WORK/out/dev/env.yaml"
check "prod 的 env.yaml 含 log_level: warn" \
  grep -q "log_level: warn" "$WORK/out/prod/env.yaml"

# 3. 存档证据
check "artifacts/state-list.txt 存在且含 3 个 local_file 资源" \
  bash -c "[ \"\$(grep -c '^local_file\.' '$WORK/artifacts/state-list.txt' 2>/dev/null)\" = 3 ]"
check "drift-plan.txt 存在且含 1 to add（漂移被抓到的纯新建计划）" \
  grep -q "1 to add" "$WORK/artifacts/drift-plan.txt"
check "taint-plan.txt 存在且含 must be replaced（强制重建计划）" \
  grep -qi "must be replaced" "$WORK/artifacts/taint-plan.txt"

# 4. workspace 目录（state 隔离的证据）
check "workspace 目录 terraform.tfstate.d/dev 存在" \
  test -d "$WORK/terraform.tfstate.d/dev"
check "workspace 目录 terraform.tfstate.d/prod 存在" \
  test -d "$WORK/terraform.tfstate.d/prod"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
