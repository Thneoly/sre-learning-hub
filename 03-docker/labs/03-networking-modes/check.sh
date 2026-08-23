#!/usr/bin/env bash
# Lab 03 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，已完成 task.md 任务
# 终态假设：网络 lab03net 存在；c1/c2 接入并运行中；h1 为 host 模式；p1 发布 8083->80；n1 为 none 模式
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查；其中对 c1 的 ping 测试会产生少量 ICMP 流量，不改变任何配置
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

# 1. 网络 lab03net 存在且为 bridge
check "网络 lab03net 存在且 driver 为 bridge" \
  bash -c '[ "$(docker network inspect -f "{{.Driver}}" lab03net 2>/dev/null)" = "bridge" ]'

# 2. lab03net 的 subnet 为 172.28.0.0/24
check "lab03net subnet 为 172.28.0.0/24" \
  bash -c 'docker network inspect -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}" lab03net 2>/dev/null | grep -q "^172\.28\.0\.0/24$"'

# 3. c1 运行中且接入 lab03net
check "c1 运行中且接入 lab03net" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" c1 2>/dev/null)" = "true" ] && docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" c1 2>/dev/null | grep -q lab03net'

# 4. c2 运行中且接入 lab03net
check "c2 运行中且接入 lab03net" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" c2 2>/dev/null)" = "true" ] && docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" c2 2>/dev/null | grep -q lab03net'

# 5. c1 可按容器名 ping 通 c2（embedded DNS 验证）
check "c1 可按名 ping 通 c2" \
  docker exec c1 ping -c 1 -W 3 c2

# 6. h1 以 host 模式运行
check "h1 运行中且 NetworkMode 为 host" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" h1 2>/dev/null)" = "true" ] && [ "$(docker inspect -f "{{.HostConfig.NetworkMode}}" h1 2>/dev/null)" = "host" ]'

# 7. p1 发布 8083->80 且 curl 可达
check "p1 运行中且发布 8083->80" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" p1 2>/dev/null)" = "true" ] && docker port p1 2>/dev/null | grep -q "80/tcp.*->.*:8083"'
check "curl http://localhost:8083 返回 nginx 页面" \
  bash -c 'curl -fsS --max-time 5 http://localhost:8083/ | grep -qi "welcome to nginx"'

# 8. n1 存在且为 none 模式
check "n1 存在且 NetworkMode 为 none" \
  bash -c '[ "$(docker inspect -f "{{.HostConfig.NetworkMode}}" n1 2>/dev/null)" = "none" ]'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
