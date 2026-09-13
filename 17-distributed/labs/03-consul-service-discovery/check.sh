#!/usr/bin/env bash
# Lab 03（17-distributed/labs/03-consul-service-discovery）判分脚本
# 运行环境：装有 Docker 与 curl 的 Ubuntu VM，且已完成 task.md 的全部任务
# 终态假设：
#   - 容器 dist-consul-1/2/3（hashicorp/consul:1.x）与 dist-web-1 全部 Running；
#     dist-consul-1 的 8500（HTTP API）与 8600（DNS）已发布到宿主
#   - KV 键 service/config/nginx/port 的值为 8080
#   - 服务 web 已通过 /v1/agent/service/register 注册到 dist-consul-1
#     （Service ID web-1，CheckID web-1-http），且已走过 passing → critical → passing 全程
#   - 记录文件位于 ~/dist-consul/：kv.txt / health-passing.txt / health-critical.txt / dns.txt
#     （leader-elect.txt 为可选任务，不判分）
# 用法：chmod +x check.sh && ./check.sh
# 说明：全部为只读检查（docker inspect / consul 只读子命令 / HTTP GET / 文件读取）
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
command -v curl  >/dev/null 2>&1 || { echo "ERROR: curl 未安装或不在 PATH"; exit 1; }

DIR="$HOME/dist-consul"

running() { test "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true"; }

# ---- 1~3. 三个 Consul server 容器在运行 ----
for c in dist-consul-1 dist-consul-2 dist-consul-3; do
  check "$c 容器在运行" running "$c"
done

# ---- 4. 假健康服务容器已恢复运行 ----
check "dist-web-1 容器在运行（健康服务已恢复）" running dist-web-1

# ---- 5. 集群 leader 存在 ----
LEADER=$(curl -s http://127.0.0.1:8500/v1/status/leader)
if [ -n "$LEADER" ] && [ "$LEADER" != '""' ]; then
  pass "集群 leader 存在（/v1/status/leader 返回 $LEADER）"
else
  fail "集群 leader 存在（/v1/status/leader 应返回非空地址）"
fi

# ---- 6. 成员表：3 个 alive 的 server ----
N=$(docker exec dist-consul-1 consul members 2>/dev/null \
    | awk 'NR>1 && $3=="alive" && $4=="server"' | wc -l)
check "consul members 显示 3 个 alive 的 server agent" test "$N" -eq 3

# ---- 7. KV 值正确 ----
V=$(docker exec dist-consul-1 consul kv get service/config/nginx/port 2>/dev/null)
check "KV service/config/nginx/port 的值为 8080" test "$V" = "8080"

# ---- 8. 服务 web 已注册进 catalog ----
if docker exec dist-consul-1 consul catalog services 2>/dev/null | grep -qx web; then
  pass "服务 web 已注册（consul catalog services 列出 web）"
else
  fail "服务 web 已注册（consul catalog services 应列出 web）"
fi

# ---- 9. 双态记录：passing ----
if [ -f "$DIR/health-passing.txt" ] && grep -q passing "$DIR/health-passing.txt"; then
  pass "health-passing.txt 记录了服务健康（passing）状态"
else
  fail "health-passing.txt 应存在且含 passing（健康态证据）"
fi

# ---- 10. 双态记录：critical ----
if [ -f "$DIR/health-critical.txt" ] && grep -q critical "$DIR/health-critical.txt"; then
  pass "health-critical.txt 记录了服务被摘除（critical）状态"
else
  fail "health-critical.txt 应存在且含 critical（kill 假服务后的证据）"
fi

# ---- 11. 当前 live 状态已恢复 passing ----
if curl -s http://127.0.0.1:8500/v1/health/service/web \
   | grep -q '"CheckID":"web-1-http"[^}]*"Status":"passing"'; then
  pass "web-1-http 当前状态为 passing（服务已恢复）"
else
  fail "web-1-http 当前状态应为 passing（先完成任务 8 的恢复步骤）"
fi

# ---- 12. DNS 解析结果 ----
if [ -f "$DIR/dns.txt" ] \
   && grep -Eq 'web\.service\.consul\.[[:space:]].*IN[[:space:]]+A[[:space:]]+[0-9]+\.' "$DIR/dns.txt"; then
  pass "dns.txt 含 web.service.consul 的 A 记录（DNS 服务发现证据）"
else
  fail "dns.txt 应含 web.service.consul 的 A 记录（dig 全量输出）"
fi

echo
echo "SCORE: $PASS/$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
