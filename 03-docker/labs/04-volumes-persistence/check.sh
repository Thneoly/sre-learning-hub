#!/usr/bin/env bash
# Lab 04 判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，已完成 task.md 任务
# 终态假设：volume webdata/appdata 存在且 webdata 内有标记文件；容器 b1（bind mount，8084）与
#           dv1、cv1（--volumes-from 关系）运行中
# 用法：chmod +x check.sh && ./check.sh
# 说明：检查 2/3 会临时启动一次性 alpine 容器读取 volume 内容（--rm，用完即删，不改动 lab 数据）
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

# 1. volume webdata 存在
check "volume webdata 存在" \
  docker volume inspect webdata

# 2. volume appdata 存在
check "volume appdata 存在" \
  docker volume inspect appdata

# 3. webdata 中的标记文件在容器删除后仍可读（数据持久化验证）
check "webdata/index.html 含 persisted-by-volume" \
  bash -c 'docker run --rm -v webdata:/webdata alpine cat /webdata/index.html | grep -q "persisted-by-volume"'

# 4. b1 运行中且挂载 bind mount（源为 ~/lab04/html）
check "b1 运行中且 bind mount 源为 lab04/html" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" b1 2>/dev/null)" = "true" ] && docker inspect -f "{{json .HostConfig.Binds}}" b1 | grep -q "lab04/html:/usr/share/nginx/html"'

# 5. curl 8084 返回 bind mount 页面内容
check "curl http://localhost:8084 返回 bind-mount-ok" \
  bash -c 'curl -fsS --max-time 5 http://localhost:8084/ | grep -q "bind-mount-ok"'

# 6. b1 的挂载为只读（:ro）
check "b1 的 bind mount 带 ro 选项" \
  bash -c 'docker inspect -f "{{json .HostConfig.Binds}}" b1 | grep -q "ro"'

# 7. cv1 运行中且 VolumesFrom 包含 dv1
check "cv1 运行中且 VolumesFrom 含 dv1" \
  bash -c '[ "$(docker inspect -f "{{.State.Running}}" cv1 2>/dev/null)" = "true" ] && docker inspect -f "{{json .HostConfig.VolumesFrom}}" cv1 | grep -q "dv1"'

# 8. appdata 在 cv1 与 dv1 之间共享（cv1 写入的文件 dv1 可读）
check "cv1 写入的 report.txt 可从独立容器经 appdata 读出" \
  bash -c 'docker run --rm -v appdata:/data alpine cat /data/report.txt | grep -q "written-by-cv1"'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
