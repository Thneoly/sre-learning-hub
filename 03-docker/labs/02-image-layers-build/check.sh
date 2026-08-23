#!/usr/bin/env bash
# Lab 02 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，已完成 task.md 任务
# 终态假设：镜像 lab02-single / lab02-multi 已构建，容器 lab02-web 运行中（8082->8080）
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查，不修改镜像/容器状态
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

# 1. lab02-single 镜像存在
check "镜像 lab02-single 存在" \
  docker image inspect lab02-single

# 2. lab02-multi 镜像存在
check "镜像 lab02-multi 存在" \
  docker image inspect lab02-multi

# 3. lab02-multi 明显小于 lab02-single（至少小 50MB）
check "lab02-multi SIZE 比 lab02-single 至少小 50MB" \
  bash -c 'S=$(docker image inspect -f "{{.Size}}" lab02-single); M=$(docker image inspect -f "{{.Size}}" lab02-multi); [ $((S - M)) -gt 52428800 ]'

# 4. lab02-multi 的 history 含 COPY 产物层，且层数极少（multi-stage 证据）
#    注：BuildKit（Docker 23+ 默认）的 history 不显示 --from=build，只显示 COPY <src> <dst> # buildkit
check "lab02-multi history 含 COPY 产物层（多阶段证据）" \
  bash -c 'docker history lab02-multi --no-trunc --format "{{.CreatedBy}}" | grep -q "^COPY " && [ "$(docker image inspect -f "{{len .RootFS.Layers}}" lab02-multi)" -le 3 ]'

# 5. lab02-web 容器运行中且由 lab02-multi 创建
check "lab02-web 运行中且使用 lab02-multi 镜像" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab02-web 2>/dev/null)" = "true" ] && [ "$(docker inspect -f "{{.Config.Image}}" lab02-web 2>/dev/null)" = "lab02-multi" ]'

# 6. 页面可访问且内容正确
check "curl http://localhost:8082 返回 hello from lab02" \
  bash -c 'curl -fsS --max-time 5 http://localhost:8082/ | grep -q "hello from lab02"'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
