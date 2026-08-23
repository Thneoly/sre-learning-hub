#!/usr/bin/env bash
# Lab 04 判分脚本：Ingress 域名+路径路由
# 假设：
#   - 在 master 节点运行，kubectl 已配置
#   - 集群已装 ingress-nginx：controller Service 名 ingress-nginx-controller，
#     位于 ingress-nginx namespace，NodePort 暴露 80 端口
#   - 已按 task.md 完成：ns lab04-ingress、deploy/svc shop-web 与 shop-api、
#     ingress shop-ingress（host shop.example.com，/api->shop-api，/->shop-web）
# 只读检查（含两次 curl GET），不修改集群。
set -u

NS="lab04-ingress"
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

# 1. namespace 存在且 Active
phase=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
check "namespace ${NS} 存在且 Active" "Active" "$phase"

# 2. 两个 Deployment 各 2 副本 Ready
for d in shop-web shop-api; do
  rep=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  check "deployment ${d} 期望副本数为 2" "2" "$rep"
  ready=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  ready=${ready:-0}
  check "deployment ${d} readyReplicas 为 2" "2" "$ready"
done

# 3. 两个 Service 存在且 port 80
for s in shop-web shop-api; do
  sport=$(kubectl -n "$NS" get svc "$s" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
  check "service ${s} 存在且 port 80" "80" "$sport"
done

# 4. Ingress 存在，ingressClassName nginx
cls=$(kubectl -n "$NS" get ingress shop-ingress -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
check "ingress shop-ingress 使用 ingressClassName nginx" "nginx" "$cls"

# 5. host 正确
host=$(kubectl -n "$NS" get ingress shop-ingress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
check "host 为 shop.example.com" "shop.example.com" "$host"

# 6. 两条 path：/api 和 /（jsonpath 按数组顺序输出）
paths=$(kubectl -n "$NS" get ingress shop-ingress -o jsonpath='{.spec.rules[0].http.paths[*].path}' 2>/dev/null)
check "paths 为 /api 与 /" "/api /" "$paths"

# 7. 后端 Service 顺序正确：/api->shop-api，/->shop-web
backs=$(kubectl -n "$NS" get ingress shop-ingress \
  -o jsonpath='{.spec.rules[0].http.paths[*].backend.service.name}' 2>/dev/null)
check "backend 顺序为 shop-api 与 shop-web" "shop-api shop-web" "$backs"

# 8. 后端端口均为 80
bports=$(kubectl -n "$NS" get ingress shop-ingress \
  -o jsonpath='{.spec.rules[0].http.paths[*].backend.service.port.number}' 2>/dev/null)
check "backend 端口均为 80" "80 80" "$bports"

# 9/10. 通过 controller 实际访问验证路由
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
np=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)
if [ -z "$np" ]; then
  np=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
fi

if [ -n "$node_ip" ] && [ -n "$np" ]; then
  base="http://${node_ip}:${np}"
  web=$(curl -s --max-time 6 -H 'Host: shop.example.com' "${base}/" 2>/dev/null)
  case "$web" in
    *"Server name"*) ok "curl / 命中 shop-web（hello 镜像响应）" ;;
    *) bad "curl / 未命中 shop-web（body 前 80 字符: $(echo "$web" | head -c 80))" ;;
  esac
  api=$(curl -s --max-time 6 -H 'Host: shop.example.com' "${base}/api" 2>/dev/null)
  # whoami 新版镜像返回 JSON（"hostname":"..."），旧版返回纯文本（Hostname: ...），两者都认
  case "$api" in
    *"Hostname"*|*'"hostname"'*) ok "curl /api 命中 shop-api（whoami 镜像响应）" ;;
    *) bad "curl /api 未命中 shop-api（body 前 80 字符: $(echo "$api" | head -c 80))" ;;
  esac
else
  bad "无法确定 ingress-nginx 入口地址（node_ip=${node_ip} nodePort=${np}）"
fi

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
