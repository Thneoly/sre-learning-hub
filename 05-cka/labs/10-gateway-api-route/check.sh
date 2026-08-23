#!/usr/bin/env bash
# Lab 10 判分脚本：Gateway API（Gateway + HTTPRoute）
# 假设：
#   - 在 master 节点运行，kubectl 已配置
#   - 已按 task.md 安装 Gateway API CRDs 与 NGINX Gateway Fabric v2.5.1
#     （controller 在 nginx-gateway namespace，GatewayClass 名为 nginx）
#   - 已按 task.md 完成：ns lab10-gateway、deploy/svc portal-web 与 portal-api、
#     gateway web-gateway、httproute portal-route（host portal.example.com）
# 只读检查（含两次 curl GET；对 Gateway/Service 状态各设短等待重试），不修改集群。
set -u

NS="lab10-gateway"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 (期望 [$2] 实际 [$3])"
  fi
}

# 1. Gateway API CRD 已安装
check "crd httproutes.gateway.networking.k8s.io 已安装" "httproutes.gateway.networking.k8s.io" \
  "$(kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.name}' 2>/dev/null)"

# 2. namespace 存在且 Active
check "namespace ${NS} 存在且 Active" "Active" \
  "$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"

# 3. 两个 Deployment 各 2 副本 Ready
for d in portal-web portal-api; do
  check "deployment ${d} 期望副本数为 2" "2" \
    "$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  r=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  check "deployment ${d} readyReplicas 为 2" "2" "${r:-0}"
done

# 4. Gateway 存在，class/listener 正确
check "gateway web-gateway 存在" "web-gateway" \
  "$(kubectl -n "$NS" get gateway web-gateway -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "gatewayClassName 为 nginx" "nginx" \
  "$(kubectl -n "$NS" get gateway web-gateway -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null)"
check "listener 端口为 80" "80" \
  "$(kubectl -n "$NS" get gateway web-gateway -o jsonpath='{.spec.listeners[0].port}' 2>/dev/null)"
check "listener 协议为 HTTP" "HTTP" \
  "$(kubectl -n "$NS" get gateway web-gateway -o jsonpath='{.spec.listeners[0].protocol}' 2>/dev/null)"

# 5. Gateway 被 controller 接受并完成部署（等待最多 120 秒）
acc=""
for _ in $(seq 1 12); do
  acc=$(kubectl -n "$NS" get gateway web-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [ "$acc" = "True" ] && break
  sleep 10
done
check "gateway Accepted 条件为 True" "True" "${acc:-}"

# 6. HTTPRoute 规则正确
check "httproute portal-route 存在" "portal-route" \
  "$(kubectl -n "$NS" get httproute portal-route -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "parentRef 指向 gateway web-gateway" "web-gateway" \
  "$(kubectl -n "$NS" get httproute portal-route \
     -o jsonpath='{.spec.parentRefs[0].name}' 2>/dev/null)"
check "hostname 为 portal.example.com" "portal.example.com" \
  "$(kubectl -n "$NS" get httproute portal-route -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)"
check "match 路径前缀为 /api" "/api" \
  "$(kubectl -n "$NS" get httproute portal-route \
     -o jsonpath='{.spec.rules[0].matches[0].path.value}' 2>/dev/null)"
backs=$(kubectl -n "$NS" get httproute portal-route \
  -o jsonpath='{.spec.rules[*].backendRefs[0].name}' 2>/dev/null)
check "backendRefs 为 portal-api 与 portal-web" "portal-api portal-web" "$backs"
bports=$(kubectl -n "$NS" get httproute portal-route \
  -o jsonpath='{.spec.rules[*].backendRefs[0].port}' 2>/dev/null)
check "backend 端口均为 80" "80 80" "$bports"

# 7. 数据面 Service 是 NodePort 且暴露 80（等待最多 60 秒）
np=""
for _ in $(seq 1 6); do
  np=$(kubectl -n "$NS" get svc web-gateway-nginx \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
  [ -n "$np" ] && break
  sleep 10
done
if [ -n "$np" ]; then
  ok "数据面 service web-gateway-nginx 在 80 端口有 nodePort(${np})"
else
  bad "数据面 service web-gateway-nginx 未暴露 80/nodePort（Gateway 是否已 Programmed？）"
fi

# 8/9. 端到端验证
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
if [ -n "$node_ip" ] && [ -n "$np" ]; then
  base="http://${node_ip}:${np}"
  web=$(curl -s --max-time 8 -H 'Host: portal.example.com' "${base}/" 2>/dev/null)
  case "$web" in
    *"Server name"*) ok "curl / 命中 portal-web" ;;
    *) bad "curl / 未命中 portal-web（body 前 80 字符: $(echo "$web" | head -c 80))" ;;
  esac
  api=$(curl -s --max-time 8 -H 'Host: portal.example.com' "${base}/api" 2>/dev/null)
  # whoami 新版镜像返回 JSON（"hostname":"..."），旧版返回纯文本（Hostname: ...），两者都认
  case "$api" in
    *"Hostname"*|*'"hostname"'*) ok "curl /api 命中 portal-api" ;;
    *) bad "curl /api 未命中 portal-api（body 前 80 字符: $(echo "$api" | head -c 80))" ;;
  esac
else
  bad "无法确定入口地址（node_ip=${node_ip} nodePort=${np}）"
fi

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
