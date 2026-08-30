#!/usr/bin/env bash
# Lab 01（17-distributed/labs/01-etcd-raft-observation）判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，且已完成 task.md 的全部任务
# 终态假设：
#   - compose 项目 dist-etcd 在跑：容器 dist-etcd-1/2/3 全部 Running
#   - docker 网络 dist-etcd-net（172.29.0.0/24）存在
#   - 3 成员全部 started、healthy，恰好 1 个 Leader（仲裁已恢复）
#   - ~/dist-etcd/ 下有四个记录文件：
#       leader-before.txt（初始 Leader endpoint，一行）
#       election.txt（第 1 行选举耗时毫秒整数；第 2 行新 Leader endpoint）
#       quorum-lost-error.txt（丢失过半后 put 的报错原文）
#       watch-output.txt（watch 捕获的 PUT 事件输出，含值 v3）
#   - key dist/lab/probe 存在，值为 v2 或 v3
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（endpoint status/health、member list、get），不修改集群任何数据
set -u

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 未安装或不在 PATH"; exit 1; }

DIR="$HOME/dist-etcd"

# ---- 1. 三个容器全部运行 ----
check "dist-etcd-1/2/3 均在运行" bash -c '
  for c in dist-etcd-1 dist-etcd-2 dist-etcd-3; do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = "true" ] || exit 1
  done'

# ---- 2. 网络 dist-etcd-net 存在且为 bridge ----
check "docker 网络 dist-etcd-net 存在（bridge）" bash -c '
  [ "$(docker network inspect -f "{{.Driver}}" dist-etcd-net 2>/dev/null)" = "bridge" ]'

# ---- 3. member list：3 个成员全部 started ----
# endpoint 查询用显式命令（不经过 helper，便于复制到任意环境单独跑）
if docker exec dist-etcd-1 etcdctl \
     --endpoints=http://dist-etcd-1:2379,http://dist-etcd-2:2379,http://dist-etcd-3:2379 \
     member list 2>/dev/null | grep -cw started | grep -qx 3; then
  pass "member list 显示 3 个成员且全部 started"
else
  fail "member list 显示 3 个成员且全部 started"
fi

# ---- 4. endpoint health：3 个端点全部 healthy ----
check "endpoint health：3 个端点全部 healthy" bash -c '
  docker exec dist-etcd-1 etcdctl \
    --endpoints=http://dist-etcd-1:2379,http://dist-etcd-2:2379,http://dist-etcd-3:2379 \
    --command-timeout=10s endpoint health'

# ---- 5. 恰好 1 个成员是 Leader ----
check "恰好 1 个成员是 Leader（IS LEADER=true 的行数为 1）" bash -c '
  [ "$(docker exec dist-etcd-1 etcdctl \
      --endpoints=http://dist-etcd-1:2379,http://dist-etcd-2:2379,http://dist-etcd-3:2379 \
      endpoint status -w table 2>/dev/null | grep -w true | grep -c "http://")" = "1" ]'

# ---- 6. leader-before.txt 存在且格式正确 ----
if [ -f "$DIR/leader-before.txt" ] \
   && grep -Eq '^http://dist-etcd-[123]:2379\s*$' "$DIR/leader-before.txt"; then
  pass "leader-before.txt 存在且为合法的成员 endpoint"
else
  fail "leader-before.txt 存在且为合法的成员 endpoint"
fi

# ---- 7. election.txt：耗时数值合理 + 新 Leader 与旧 Leader 不同 ----
OLD_LEADER=""
[ -f "$DIR/leader-before.txt" ] && OLD_LEADER=$(tr -d '[:space:]' < "$DIR/leader-before.txt")
if [ -f "$DIR/election.txt" ]; then
  MS=$(sed -n '1p' "$DIR/election.txt" | tr -d '[:space:]')
  NEW_LEADER=$(sed -n '2p' "$DIR/election.txt" | tr -d '[:space:]')
  if echo "$MS" | grep -Eq '^[0-9]+$' && [ "$MS" -ge 200 ] && [ "$MS" -le 600000 ]; then
    pass "election.txt 选举耗时为合理毫秒数（200ms~600s，实测 ${MS}ms）"
  else
    fail "election.txt 选举耗时为合理毫秒数（200ms~600s，当前值：${MS:-缺失}）"
  fi
  if echo "$NEW_LEADER" | grep -Eq '^http://dist-etcd-[123]:2379$' && [ "$NEW_LEADER" != "$OLD_LEADER" ]; then
    pass "election.txt 新 Leader 与初始 Leader 不同（${OLD_LEADER:-?} → ${NEW_LEADER}）"
  else
    fail "election.txt 新 Leader 与初始 Leader 不同（旧：${OLD_LEADER:-?} 新：${NEW_LEADER:-?}）"
  fi
else
  fail "election.txt 选举耗时为合理毫秒数（文件不存在）"
  fail "election.txt 新 Leader 与初始 Leader 不同（文件不存在）"
fi

# ---- 8. quorum-lost-error.txt：put 报错原文存在 ----
if [ -f "$DIR/quorum-lost-error.txt" ] && [ -s "$DIR/quorum-lost-error.txt" ] \
   && grep -Eiq 'etcdserver|timed out|deadline|unavailable' "$DIR/quorum-lost-error.txt"; then
  pass "quorum-lost-error.txt 记录了真实的仲裁丢失报错原文"
else
  fail "quorum-lost-error.txt 记录了真实的仲裁丢失报错原文（需含 etcdserver/超时类字样）"
fi

# ---- 9. watch-output.txt：捕获到 PUT 事件与值 v3 ----
if [ -f "$DIR/watch-output.txt" ] && grep -qw 'PUT' "$DIR/watch-output.txt" \
   && grep -qw 'v3' "$DIR/watch-output.txt"; then
  pass "watch-output.txt 捕获到 PUT 事件且值为 v3"
else
  fail "watch-output.txt 捕获到 PUT 事件且值为 v3"
fi

# ---- 10. 恢复后 key 可读 ----
VAL=$(docker exec dist-etcd-1 etcdctl --endpoints=http://dist-etcd-1:2379 \
        get dist/lab/probe --print-value-only 2>/dev/null | tr -d '[:space:]')
if echo "$VAL" | grep -Eq '^v[23]$'; then
  pass "恢复后 dist/lab/probe 可读，值为 ${VAL}（自愈成功）"
else
  fail "恢复后 dist/lab/probe 可读且值为 v2/v3（当前值：${VAL:-空}）"
fi

echo
echo "SCORE: $PASS/$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
