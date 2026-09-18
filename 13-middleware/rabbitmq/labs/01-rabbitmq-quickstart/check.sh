#!/usr/bin/env bash
# Lab 01（rabbitmq/01-rabbitmq-quickstart）判分脚本
# 运行环境：装有 Docker 与 docker compose 插件的 Ubuntu 22.04/24.04 VM，且已完成 task.md 全部任务
# 终态假设：
#   - 容器 rabbit-lab（rabbitmq:3.13-management，healthy）与 rabbit-client 运行中，同属一个 compose 网络
#   - 管理用户 app/app-secret 可用；guest 未创建（compose 设了 RABBITMQ_DEFAULT_USER），
#     从 rabbit-client 请求 API 用 guest 登录应得 401
#   - vhost / 下：direct exchange orders.ex；队列 orders.q（binding orders.ex→orders.q，rk=order.new）
#   - orders.q 已被手动 ack 消费完：ready=0、unacked=0、HTTP API message_stats.ack >= 100
#   - policy dlx-wait 作用于 ^orders\.wait$：message-ttl + dead-letter-exchange + dead-letter-routing-key
#   - 死信链路闭环：orders.dlx→orders.dead（rk=order.new）存在，orders.dead 至少 1 条死信
#   - rabbitmq_prometheus 插件启用，宿主机 15692 的 /metrics 可访问
# 用法：chmod +x check.sh && ./check.sh
# 说明：全部为只读检查，不修改任何队列/消息/配置
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

# ---- 1/2. 两个容器运行中 ----
check "rabbit-lab 容器运行中" bash -c '
  [ "$(docker inspect -f "{{.State.Running}}" rabbit-lab 2>/dev/null)" = "true" ]'
check "rabbit-client 容器运行中" bash -c '
  [ "$(docker inspect -f "{{.State.Running}}" rabbit-client 2>/dev/null)" = "true" ]'

# ---- 3. Web UI/HTTP API 可用且 app 能认证（响应体含 rabbitmq_version） ----
check "管理 API 可用且 app 认证成功" bash -c '
  curl -su app:app-secret --max-time 10 http://localhost:15672/api/overview | grep -q "rabbitmq_version"'

# ---- 4. guest 从 client 容器远程登录被拒（401） ----
check "guest 远程登录被拒（401）" bash -c '
  docker exec rabbit-client python3 -c "
import sys, base64, urllib.request, urllib.error
req = urllib.request.Request(\"http://rabbit-lab:15672/api/overview\")
req.add_header(\"Authorization\", \"Basic \" + base64.b64encode(b\"guest:guest\").decode())
try:
    urllib.request.urlopen(req, timeout=10)
    sys.exit(1)   # guest 竟然登录成功，说明仍留有可远程使用的 guest
except urllib.error.HTTPError as e:
    sys.exit(0 if e.code == 401 else 1)
"'

# ---- 5. app 对 vhost / 拥有 configure/write/read 权限 ----
check "app 对 / 的 configure/write/read 权限齐全" bash -c '
  LINE=$(docker exec rabbit-lab rabbitmqctl -q list_user_permissions app 2>/dev/null | grep "^/" | head -1)
  [ -n "$LINE" ] && [ "$(printf "%s" "$LINE" | grep -o "\.\*" | wc -l)" -ge 3 ]'

# ---- 6. orders.ex 存在且类型为 direct ----
check "exchange orders.ex 存在且类型 direct" bash -c '
  docker exec rabbit-lab rabbitmqadmin -u app -p app-secret list exchanges name type 2>/dev/null \
    | grep "orders\.ex" | grep -q "direct"'

# ---- 7. orders.q 存在且 binding orders.ex→orders.q（rk=order.new） ----
check "队列 orders.q 与 binding（rk=order.new）存在" bash -c '
  docker exec rabbit-lab rabbitmqctl -q list_queues name 2>/dev/null | grep -q "^orders\.q"
  docker exec rabbit-lab rabbitmqctl -q list_bindings source_name destination_name routing_key 2>/dev/null \
    | grep "orders\.ex" | grep "orders\.q" | grep -q "order\.new"'

# ---- 8. 100 条消息已发布并手动 ack 消费完 ----
# rabbitmqctl 是实时读；HTTP API 的 message_stats 出自管理 DB（约 5s 刷新），任务完成后早已落库
check "orders.q 已消费完且为手动 ack（ready=0、unacked=0、ack>=100）" bash -c '
  LINE=$(docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready messages_unacknowledged 2>/dev/null | awk "\$1==\"orders.q\"")
  [ -n "$LINE" ] || exit 1
  R=$(printf "%s" "$LINE" | awk "{print \$2}")
  U=$(printf "%s" "$LINE" | awk "{print \$3}")
  [ "$R" = "0" ] && [ "$U" = "0" ] || exit 1
  ACK=$(curl -su app:app-secret --max-time 10 http://localhost:15672/api/queues/%2F/orders.q \
    | grep -o "\"ack\":[0-9]*" | head -1 | grep -o "[0-9]*$")
  [ -n "$ACK" ] && [ "$ACK" -ge 100 ]'

# ---- 9. policy dlx-wait：TTL + DLX + 重写路由 key 三键齐全 ----
check "policy dlx-wait 含 message-ttl/dead-letter-exchange/dead-letter-routing-key" bash -c '
  LINE=$(docker exec rabbit-lab rabbitmqctl -q list_policies 2>/dev/null | grep "dlx-wait" | head -1)
  [ -n "$LINE" ] || exit 1
  echo "$LINE" | grep -q "orders\\\\.wait"
  echo "$LINE" | grep -q "message-ttl"
  echo "$LINE" | grep -q "dead-letter-exchange"
  echo "$LINE" | grep -q "dead-letter-routing-key"'

# ---- 10. 死信链路闭环：binding 存在且 orders.dead 有死信 ----
check "死信链路闭环（orders.dlx→orders.dead 且死信 >= 1）" bash -c '
  docker exec rabbit-lab rabbitmqctl -q list_bindings source_name destination_name routing_key 2>/dev/null \
    | grep "orders\.dlx" | grep "orders\.dead" | grep -q "order\.new"
  N=$(docker exec rabbit-lab rabbitmqctl -q list_queues name messages 2>/dev/null | awk "\$1==\"orders.dead\" {print \$2}")
  [ -n "$N" ] && [ "$N" -ge 1 ]'

# ---- 11. 监控：/metrics 可访问且 rabbitmq_prometheus 已启用 ----
check "监控可用（/metrics 含队列深度指标且插件已启用）" bash -c '
  curl -s --max-time 10 http://localhost:15692/metrics | grep -q "^rabbitmq_queue_messages_ready"
  docker exec rabbit-lab rabbitmq-plugins list -e 2>/dev/null | grep -q "rabbitmq_prometheus"'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
