#!/usr/bin/env bash
# Lab 08 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，已完成 task.md 任务
# 终态假设：lab08-registry 容器（registry:2，5000 端口，volume lab08-data）运行中，
#           仓库 lab/nginx 已 push，且 localhost:5000/lab/nginx:alpine 已 pull 回本地
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（inspect / curl GET），不修改 registry 内容
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
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl 不可用"; exit 1; }

# 1. lab08-registry 运行中且 restart policy 为 always
check "lab08-registry 运行中且 RestartPolicy 为 always" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" lab08-registry 2>/dev/null)" = "true" ] && [ "$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" lab08-registry 2>/dev/null)" = "always" ]'

# 2. 发布端口 5000->5000
check "lab08-registry 发布 5000->5000" \
  bash -c 'docker port lab08-registry 2>/dev/null | grep -q "5000/tcp.*->.*:5000"'

# 3. Registry API v2 存活（返回 {}）
check "GET /v2/ 返回 {}" \
  bash -c '[ "$(curl -fsS --max-time 5 http://localhost:5000/v2/ 2>/dev/null)" = "{}" ]'

# 4. catalog 含 lab/nginx
check "/v2/_catalog 含 lab/nginx" \
  bash -c 'curl -fsS --max-time 5 http://localhost:5000/v2/_catalog | grep -q "lab/nginx"'

# 5. lab/nginx 的 tags 含 alpine
check "/v2/lab/nginx/tags/list 含 alpine" \
  bash -c 'curl -fsS --max-time 5 http://localhost:5000/v2/lab/nginx/tags/list | grep -q "alpine"'

# 6. 本地存在从 registry 拉回的镜像
check "本地存在镜像 localhost:5000/lab/nginx:alpine" \
  docker image inspect localhost:5000/lab/nginx:alpine

# 7. registry 容器挂载了 volume lab08-data
check "lab08-registry 挂载 volume lab08-data" \
  bash -c 'docker inspect -f "{{json .Mounts}}" lab08-registry | grep -q "lab08-data"'

# 8. volume lab08-data 存在
check "volume lab08-data 存在" \
  docker volume inspect lab08-data

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
