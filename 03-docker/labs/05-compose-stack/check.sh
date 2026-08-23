#!/usr/bin/env bash
# Lab 05 判分脚本
# 运行环境：装有 Docker（含 docker compose 插件）的 Ubuntu 22.04/24.04 VM，已完成 task.md 任务
# 前提假设：本脚本与 compose.yaml 位于同一目录（判分会 cd 到脚本所在目录），栈以项目名 lab05 运行中
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查；对 app 容器执行一次 python 解析探测，不改变栈状态
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
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose 插件不可用"; exit 1; }

# 切到脚本所在目录，保证能读到 compose.yaml
cd "$(dirname "$0")"

APP_CTR="lab05-app-1"
REDIS_CTR="lab05-redis-1"
WEB_CTR="lab05-web-1"

# 1. redis 服务运行中且 healthy
check "redis 服务运行中且 healthy" \
  bash -c "[ \"\$(docker inspect -f '{{.State.Status}}' $REDIS_CTR 2>/dev/null)\" = 'running' ] && [ \"\$(docker inspect -f '{{.State.Health.Status}}' $REDIS_CTR 2>/dev/null)\" = 'healthy' ]"

# 2. app 服务运行中且 healthy
check "app 服务运行中且 healthy" \
  bash -c "[ \"\$(docker inspect -f '{{.State.Status}}' $APP_CTR 2>/dev/null)\" = 'running' ] && [ \"\$(docker inspect -f '{{.State.Health.Status}}' $APP_CTR 2>/dev/null)\" = 'healthy' ]"

# 3. web 服务运行中且发布 8085->80
check "web 服务运行中且发布 8085->80" \
  bash -c "[ \"\$(docker inspect -f '{{.State.Running}}' $WEB_CTR 2>/dev/null)\" = 'true' ] && docker port $WEB_CTR 2>/dev/null | grep -q '80/tcp.*->.*:8085'"

# 4. 宿主机经 web 反代访问 app 成功（web -> app 链路）
check "curl http://localhost:8085/ 返回 hello from app" \
  bash -c 'curl -fsS --max-time 5 http://localhost:8085/ | grep -q "hello from app"'

# 5. app -> redis 链路（DNS + 协议连通）
check "curl http://localhost:8085/redis-ping 返回 PONG" \
  bash -c 'curl -fsS --max-time 5 http://localhost:8085/redis-ping | grep -q "PONG"'

# 6. app 容器内服务名 DNS 解析
check "app 容器可解析服务名 redis" \
  docker exec lab05-app-1 python -c "import socket; assert socket.gethostbyname('redis')"

# 7. app 镜像为本地构建（compose build 证据）
check "app 服务使用 compose 构建镜像 lab05-app" \
  bash -c "docker inspect -f '{{.Config.Image}}' $APP_CTR 2>/dev/null | grep -q 'lab05-app'"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
