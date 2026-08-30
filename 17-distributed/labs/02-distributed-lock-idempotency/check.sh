#!/usr/bin/env bash
# Lab 02（17-distributed/labs/02-distributed-lock-idempotency）判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，且已完成 task.md 的全部任务
# 终态假设：
#   - 容器 dist-lock-redis（redis:7.2）运行中，宿主目录 ~/dist-lock 挂载为容器 /labs
#   - ~/dist-lock/unlock.lua 是"校验 token 再删"的释放脚本
#   - 正确姿势演示结束后锁 key lock:order:stock 不存在（已正确释放）
#   - ~/dist-lock/orders-before.txt：无幂等保护，同一 request_id 至少两条流水
#   - ~/dist-lock/orders-after.txt：加去重表后，同一 request_id 恰好一条流水
#   - ~/dist-lock/redlock-notes.md：含 antirez / kleppmann / fencing 关键词
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查；唯一例外是功能项 4/5 —— 判分对象是 unlock.lua 的写入行为本身，
#       按 STYLE.md 对 check.sh 的"自清理一次性探针"例外，写一个 lock:labcheck:<pid>
#       键做 Lua 正反两向验证：键名带 labcheck: 前缀与脚本 PID、PX 60s 兜底、
#       第 4 项成功即自删、第 5 项结束显式 DEL，不触碰任何实验数据键
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

DIR="$HOME/dist-lock"

R() { docker exec dist-lock-redis redis-cli --raw "$@" 2>/dev/null; }

# ---- 1. 容器运行中 ----
check "dist-lock-redis 容器在运行" \
  test "$(docker inspect -f '{{.State.Running}}' dist-lock-redis 2>/dev/null)" = "true"

# ---- 2. Redis 可用 ----
check "PING 返回 PONG" test "$(R PING)" = "PONG"

# ---- 3. unlock.lua 存在且静态检查（GET+ARGV 比较+DEL） ----
if [ -f "$DIR/unlock.lua" ] && grep -q 'GET' "$DIR/unlock.lua" \
   && grep -q 'ARGV\[1\]' "$DIR/unlock.lua" && grep -q 'DEL' "$DIR/unlock.lua"; then
  pass "unlock.lua 存在且含 GET/ARGV[1]/DEL 校验逻辑"
else
  fail "unlock.lua 存在且含 GET/ARGV[1]/DEL 校验逻辑"
fi

# ---- 4. 功能验证：token 匹配时 eval 返回 1（键被删除） ----
KC="lock:labcheck:$$"
TOK="tok-$$"
R SET "$KC" "$TOK" PX 60000 >/dev/null
RET=$(docker exec dist-lock-redis redis-cli --eval /labs/unlock.lua "$KC" , "$TOK" 2>/dev/null | tr -dc '0-9')
if [ "$RET" = "1" ] && [ "$(R EXISTS "$KC")" = "0" ]; then
  pass "Lua 释放：token 匹配返回 1 且锁被删除"
else
  fail "Lua 释放：token 匹配应返回 1 且锁被删除（实际返回：${RET:-空}）"
fi

# ---- 5. 功能验证：token 不匹配时 eval 返回 0（别人的锁不动） ----
R SET "$KC" "other-owner" PX 60000 >/dev/null
RET=$(docker exec dist-lock-redis redis-cli --eval /labs/unlock.lua "$KC" , "wrong-token" 2>/dev/null | tr -dc '0-9')
if [ "$RET" = "0" ] && [ "$(R EXISTS "$KC")" = "1" ]; then
  pass "Lua 释放：token 不匹配返回 0 且锁未被误删"
else
  fail "Lua 释放：token 不匹配应返回 0 且锁保留（实际返回：${RET:-空}）"
fi
R DEL "$KC" >/dev/null   # 清理一次性验证键

# ---- 6. 无幂等保护：同一请求两条流水 ----
if [ -f "$DIR/orders-before.txt" ] \
   && [ "$(grep -c 'req=' "$DIR/orders-before.txt")" -ge 2 ]; then
  pass "orders-before.txt 显示无幂等保护时重复下单产生了多条流水"
else
  fail "orders-before.txt 应含至少 2 条 req= 流水（无幂等保护实验）"
fi

# ---- 7. 加去重表后：同一请求恰好一条流水 ----
if [ -f "$DIR/orders-after.txt" ] \
   && [ "$(grep -c 'req=' "$DIR/orders-after.txt")" -eq 1 ]; then
  pass "orders-after.txt 显示加去重表后重放只剩一条流水"
else
  fail "orders-after.txt 应恰好只有 1 条 req= 流水（去重实验）"
fi

# ---- 8. RedLock 争议小结 ----
if [ -f "$DIR/redlock-notes.md" ] && grep -Eiq 'antirez' "$DIR/redlock-notes.md" \
   && grep -Eiq 'kleppmann' "$DIR/redlock-notes.md" && grep -Eiq 'fencing' "$DIR/redlock-notes.md"; then
  pass "redlock-notes.md 覆盖 antirez/kleppmann/fencing 三个要点"
else
  fail "redlock-notes.md 需包含 antirez、kleppmann、fencing 三个关键词"
fi

# ---- 9. 正确姿势的锁没有悬挂 ----
if [ "$(R EXISTS lock:order:stock)" = "0" ]; then
  pass "lock:order:stock 已正确释放（无悬挂锁）"
else
  fail "lock:order:stock 应已释放（正确姿势演示结束后该 key 不应存在）"
fi

echo
echo "SCORE: $PASS/$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
