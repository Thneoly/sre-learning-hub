#!/usr/bin/env bash
# Lab 01 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，且已完成 task.md 的任务（终态：web01 运行中、side01 已退出）
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查，不修改任何容器/镜像状态
set -u

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# check "描述" 命令...  命令退出码为 0 记 PASS
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

# 1. web01 存在且处于运行状态
check "web01 处于运行状态" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" web01 2>/dev/null)" = "true" ]'

# 2. web01 的 restart policy 为 unless-stopped
check "web01 的 RestartPolicy 为 unless-stopped" \
  bash -c '[ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" web01 2>/dev/null)" = "unless-stopped" ]'

# 3. 端口映射 8081 -> 80
check "web01 发布端口 8081->80" \
  bash -c 'docker inspect -f "{{json .HostConfig.PortBindings}}" web01 2>/dev/null | grep -q "8081" && docker port web01 2>/dev/null | grep -q "80/tcp.*->.*:8081"'

# 4. 页面可访问且是 nginx 欢迎页
check "curl http://localhost:8081 返回 nginx 欢迎页" \
  bash -c 'curl -fsS --max-time 5 http://localhost:8081/ | grep -qi "welcome to nginx"'

# 5. side01 存在且已退出（退出码 0）
check "side01 存在且状态为 exited" \
  bash -c '[ "$(docker inspect -f "{{.State.Status}}" side01 2>/dev/null)" = "exited" ] && [ "$(docker inspect -f "{{.State.ExitCode}}" side01 2>/dev/null)" = "0" ]'

# 6. side01 的 restart policy 为 no（不被自动重启）
check "side01 的 RestartPolicy 为 no" \
  bash -c '[ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" side01 2>/dev/null)" = "no" ]'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
