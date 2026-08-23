#!/usr/bin/env bash
# Lab 03 判分脚本：Service NodePort 暴露
# 假设：
#   - 在 master 节点运行，kubectl 已配置；单节点练习集群，NodePort 可在本机 curl
#   - 已按 task.md 完成：ns lab03-nodeport、deploy front-web(3副本)、
#     svc front-web-svc(NodePort 30080)
# 只读检查（含一次 curl GET），不修改集群。
set -u

NS="lab03-nodeport"
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

# 2. Deployment 存在且 3 副本 Ready
rep=$(kubectl -n "$NS" get deploy front-web -o jsonpath='{.spec.replicas}' 2>/dev/null)
check "deployment front-web 期望副本数为 3" "3" "$rep"
ready=$(kubectl -n "$NS" get deploy front-web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
ready=${ready:-0}
check "deployment front-web readyReplicas 为 3" "3" "$ready"

# 3. Service 类型 NodePort
type=$(kubectl -n "$NS" get svc front-web-svc -o jsonpath='{.spec.type}' 2>/dev/null)
check "service front-web-svc 类型为 NodePort" "NodePort" "$type"

# 4. port 80 / targetPort 80
port=$(kubectl -n "$NS" get svc front-web-svc -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
check "service port 为 80" "80" "$port"
tport=$(kubectl -n "$NS" get svc front-web-svc -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)
check "service targetPort 为 80" "80" "$tport"

# 5. nodePort 30080
nport=$(kubectl -n "$NS" get svc front-web-svc -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
check "nodePort 为 30080" "30080" "$nport"

# 6. selector 匹配 app=front-web
sel=$(kubectl -n "$NS" get svc front-web-svc -o jsonpath='{.spec.selector.app}' 2>/dev/null)
check "selector 匹配 app=front-web" "front-web" "$sel"

# 7. Endpoints 有 3 个后端地址
eps=$(kubectl -n "$NS" get endpoints front-web-svc \
  -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')
check "endpoints 有 3 个后端 IP" "3" "$eps"

# 8. 节点本地 curl NodePort 返回 nginx 页面
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
if [ -n "$node_ip" ]; then
  body=$(curl -s --max-time 5 "http://${node_ip}:30080/" 2>/dev/null)
  case "$body" in
    *Welcome*nginx*|*nginx*Welcome*)
      ok "curl http://${node_ip}:30080 返回 nginx 页面" ;;
    *)
      bad "curl http://${node_ip}:30080 未返回 nginx 页面（body 前 80 字符: $(echo "$body" | head -c 80))" ;;
  esac
else
  bad "无法获取节点 InternalIP，跳过 curl 验证"
fi

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
