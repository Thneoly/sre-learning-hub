#!/usr/bin/env bash
# Lab 08 判分脚本（Helm chart 生命周期终态检查）
# 运行环境：candidate VM（kubectl、curl 可用），已完成 task.md 全部任务
# 假设：release 名 demo-app，命名空间 helm-lab08，工作目录 ~/labs/helm-chart；
#       本地 registry（03-docker/labs/08 的 lab08-registry）在 localhost:5000 运行；
#       终态：release revision 数 >=4 且存在 deployed 记录；Deployment demo-app 健康
#       （replicas 2、probes/resources 生效、镜像不含坏 tag）；
#       chart 0.2.0 已推入 oci://localhost:5000/charts/demo-app 且已 pull 回 ~/labs/helm-chart/pulled/
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（kubectl 查询、curl GET、文件存在性），不修改集群与 registry
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

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl 未安装或不在 PATH"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl 不可用"; exit 1; }

WORK="$HOME/labs/helm-chart"
NS=helm-lab08

# 1. release Secret 命名与 revision 数
check "存在 sh.helm.release.v1.demo-app.v* 命名的 Secret" \
  bash -c 'kubectl -n helm-lab08 get secret -o name | grep -q "secret/sh.helm.release.v1.demo-app.v"'
check "release revision 数 >= 4" \
  bash -c '[ "$(kubectl -n helm-lab08 get secret -o name | grep -c "sh.helm.release.v1.demo-app.v")" -ge 4 ]'
check "存在 status=deployed 的 release Secret" \
  bash -c 'kubectl -n helm-lab08 get secret -l owner=helm,name=demo-app,status=deployed -o name | grep -q .'

# 2. Deployment 健康终态（回滚后的 rev2 内容）
check "Deployment demo-app 处于 Available" \
  bash -c '[ "$(kubectl -n helm-lab08 get deploy demo-app -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null)" = "True" ]'
check "Deployment demo-app 期望副本数为 2" \
  bash -c '[ "$(kubectl -n helm-lab08 get deploy demo-app -o jsonpath="{.spec.replicas}" 2>/dev/null)" = "2" ]'
check "Deployment demo-app 就绪副本数为 2" \
  bash -c '[ "$(kubectl -n helm-lab08 get deploy demo-app -o jsonpath="{.status.readyReplicas}" 2>/dev/null)" = "2" ]'
check "容器配置了 livenessProbe" \
  bash -c '[ -n "$(kubectl -n helm-lab08 get deploy demo-app -o jsonpath="{.spec.template.spec.containers[0].livenessProbe.httpGet.path}" 2>/dev/null)" ]'
check "resources.requests.memory 为 64Mi" \
  bash -c '[ "$(kubectl -n helm-lab08 get deploy demo-app -o jsonpath="{.spec.template.spec.containers[0].resources.requests.memory}" 2>/dev/null)" = "64Mi" ]'
check "当前镜像不含坏 tag" \
  bash -c '! kubectl -n helm-lab08 get deploy demo-app -o jsonpath="{.spec.template.spec.containers[0].image}" 2>/dev/null | grep -q this-tag-does-not-exist'

# 3. registry 中的 chart
check "registry catalog 含 charts/demo-app" \
  bash -c 'curl -fsS --max-time 5 http://localhost:5000/v2/_catalog | grep -q "charts/demo-app"'
check "chart 0.2.0 tag 已在 registry" \
  bash -c 'curl -fsS --max-time 5 http://localhost:5000/v2/charts/demo-app/tags/list | grep -q 0.2.0'
check "helm pull 回来的 demo-app-0.2.0.tgz 存在" \
  test -f "$WORK/pulled/demo-app-0.2.0.tgz"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
