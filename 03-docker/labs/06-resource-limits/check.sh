#!/usr/bin/env bash
# Lab 06 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM（cgroup v2，systemd 驱动），已完成 task.md 任务
# 终态假设：lab06-cpu（--cpus 0.5 --memory 128m）与 lab06-free（无限制）均在运行且负载未停
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（docker inspect / exec cat / stats），不修改容器状态
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

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 未安装或不在 PATH"; exit 1; }

# 0. 前提：cgroup v2（Ubuntu 22.04/24.04 默认满足）
check "宿主机使用 cgroup v2" \
  bash -c '[ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ]'

# 1. lab06-cpu 运行中
check "lab06-cpu 运行中" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab06-cpu 2>/dev/null)" = "true" ]'

# 2. CPU 配额 --cpus 0.5（NanoCpus = 500000000）
check "lab06-cpu NanoCpus 为 500000000（--cpus 0.5）" \
  bash -c '[ "$(docker inspect -f "{{.HostConfig.NanoCpus}}" lab06-cpu 2>/dev/null)" = "500000000" ]'

# 3. 内存限制 128m（Memory = 134217728 字节）
check "lab06-cpu Memory 为 134217728（128MiB）" \
  bash -c '[ "$(docker inspect -f "{{.HostConfig.Memory}}" lab06-cpu 2>/dev/null)" = "134217728" ]'

# 4. 容器内 cgroup v2 cpu.max 为 "50000 100000"
check "lab06-cpu 容器内 cpu.max 为 50000 100000" \
  bash -c '[ "$(docker exec lab06-cpu cat /sys/fs/cgroup/cpu.max 2>/dev/null)" = "50000 100000" ]'

# 5. 容器内 memory.max 为 134217728
check "lab06-cpu 容器内 memory.max 为 134217728" \
  bash -c '[ "$(docker exec lab06-cpu cat /sys/fs/cgroup/memory.max 2>/dev/null)" = "134217728" ]'

# 6. 已发生且持续发生 CPU 限流（nr_throttled > 0）
check "lab06-cpu 的 nr_throttled 大于 0（发生限流）" \
  bash -c 'T=$(docker exec lab06-cpu cat /sys/fs/cgroup/cpu.stat 2>/dev/null | awk "\$1==\"nr_throttled\"{print \$2}"); [ -n "$T" ] && [ "$T" -gt 0 ]'

# 7. 对照组 lab06-free 运行中且无 CPU 限制（NanoCpus = 0）
check "lab06-free 运行中且 NanoCpus 为 0（无限制）" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab06-free 2>/dev/null)" = "true" ] && [ "$(docker inspect -f "{{.HostConfig.NanoCpus}}" lab06-free 2>/dev/null)" = "0" ]'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
