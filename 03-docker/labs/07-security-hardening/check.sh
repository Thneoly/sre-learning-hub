#!/usr/bin/env bash
# Lab 07 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，已完成 task.md 任务
# 终态假设：lab07-base / lab07-nocap / lab07-noroot / lab07-hard 四个容器均在运行
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（inspect + exec 读状态/探测 tmpfs 可写性），不改变容器配置
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

# 读取容器内 1 号进程视角的 CapEff 位图
capeff() {
  docker exec "$1" sh -c 'grep CapEff /proc/self/status' 2>/dev/null | tr -d ' \t' | cut -d: -f2
}
# 导出给下面 bash -c 子 shell 使用（函数不导出的话子 shell 里 $(capeff ...) 会 command not found）
export -f capeff

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 未安装或不在 PATH"; exit 1; }

# 1. lab07-base 运行中且保留默认 capabilities
check "lab07-base 运行中且 CapEff 非零" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab07-base 2>/dev/null)" = "true" ] && [ -n "$(capeff lab07-base)" ] && [ "$(capeff lab07-base)" != "0000000000000000" ]'

# 2. lab07-nocap 运行中且 CapEff 全零
check "lab07-nocap 运行中且 CapEff 为 0000000000000000" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab07-nocap 2>/dev/null)" = "true" ] && [ "$(capeff lab07-nocap)" = "0000000000000000" ]'

# 3. lab07-noroot 运行中且 uid 为 1000
check "lab07-noroot 运行中且 id -u 为 1000" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab07-noroot 2>/dev/null)" = "true" ] && [ "$(docker exec lab07-noroot id -u 2>/dev/null | tr -d "[:space:]")" = "1000" ]'

# 4. lab07-hard 运行中且 SecurityOpt 含 no-new-privileges
check "lab07-hard 运行中且含 no-new-privileges" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab07-hard 2>/dev/null)" = "true" ] && docker inspect -f "{{json .HostConfig.SecurityOpt}}" lab07-hard | grep -q "no-new-privileges"'

# 5. lab07-hard 丢弃全部 capability 且未新增
check "lab07-hard CapDrop=ALL 且 CapAdd 为空" \
  bash -c 'docker inspect -f "{{json .HostConfig.CapDrop}}" lab07-hard | grep -q "ALL" && [ -z "$(docker inspect -f "{{range .HostConfig.CapAdd}}{{.}}{{end}}" lab07-hard)" ]'

# 6. lab07-hard rootfs 只读
check "lab07-hard ReadonlyRootfs 为 true" \
  bash -c '[ "$(docker inspect -f "{{.HostConfig.ReadonlyRootfs}}" lab07-hard 2>/dev/null)" = "true" ]'

# 7. lab07-hard 以非 root 运行（uid 1000）
check "lab07-hard id -u 为 1000" \
  bash -c '[ "$(docker exec lab07-hard id -u 2>/dev/null | tr -d "[:space:]")" = "1000" ]'

# 8. lab07-hard 的 /tmp（tmpfs）仍可写
check "lab07-hard 的 /tmp 可写（tmpfs 生效）" \
  bash -c 'docker exec lab07-hard sh -c "touch /tmp/check-probe && test -f /tmp/check-probe"'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
