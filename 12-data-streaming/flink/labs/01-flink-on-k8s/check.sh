#!/usr/bin/env bash
# Lab 01 (flink-on-k8s) 判分脚本
# 运行环境：kubeadm 单 master 练习集群的 master 节点（Ubuntu 22.04/24.04，可 kubectl，已装 curl）
# 终态假设（已完成 task.md 全部任务）：
#   - Flink Kubernetes Operator 装在 flink-operator namespace（helm release 名 flink-kubernetes-operator）
#   - namespace flink-lab 内：wordsrv Deployment 2 副本（FLOOD=0）、Service wordsrv/wordcount-rest
#   - FlinkDeployment wordcount 已从 savepoint 恢复并以 parallelism 1 运行（作业 RUNNING）
#   - master 本机目录 /var/flink-state/savepoints/ 下有 savepoint-*（单节点集群，hostPath 落在 master）
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（kubectl get/jsonpath、REST GET、ls），不修改集群与作业状态
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
command -v curl    >/dev/null 2>&1 || { echo "ERROR: curl 未安装或不在 PATH"; exit 1; }

# ---------------------------------------------------------------- 基础对象
check "Flink Operator 在 flink-operator namespace 中 Available" \
  bash -c 'A=$(kubectl -n flink-operator get deployment flink-kubernetes-operator -o jsonpath="{.status.availableReplicas}" 2>/dev/null); [ -n "$A" ] && [ "$A" -ge 1 ]'

check "namespace flink-lab 存在" \
  bash -c '[ -n "$(kubectl get namespace flink-lab -o name 2>/dev/null)" ]'

check "wordsrv Deployment 2 副本全部 Available" \
  bash -c 'A=$(kubectl -n flink-lab get deployment wordsrv -o jsonpath="{.status.availableReplicas}" 2>/dev/null); [ -n "$A" ] && [ "$A" -ge 2 ]'

check "Service wordsrv 存在且 endpoints 非空" \
  bash -c 'EP=$(kubectl -n flink-lab get endpoints wordsrv -o jsonpath="{.subsets[0].addresses[0].ip}" 2>/dev/null); [ -n "$EP" ]'

check "FlinkDeployment wordcount 存在" \
  bash -c 'kubectl -n flink-lab get flinkdeployments.flink.apache.org wordcount -o name 2>/dev/null | grep -q "wordcount"'

check "FlinkDeployment jobStatus.state 为 RUNNING" \
  bash -c '[ "$(kubectl -n flink-lab get flinkdeployments.flink.apache.org wordcount -o jsonpath="{.status.jobStatus.state}" 2>/dev/null)" = "RUNNING" ]'

check "Service wordcount-rest 存在且 endpoints 非空" \
  bash -c 'EP=$(kubectl -n flink-lab get endpoints wordcount-rest -o jsonpath="{.subsets[0].addresses[0].ip}" 2>/dev/null); [ -n "$EP" ]'

# wordsrv x2 + JobManager + TaskManager，至少 4 个 Running
check "flink-lab 内至少 4 个 Running Pod（JM+TM+2 个词源）" \
  bash -c 'RC=$(kubectl -n flink-lab get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l); [ -n "$RC" ] && [ "$RC" -ge 4 ]'

# ---------------------------------------------------------------- REST（经 port-forward）
PF_PORT=18081
kubectl -n flink-lab port-forward svc/wordcount-rest ${PF_PORT}:8081 >/dev/null 2>&1 &
PF_PID=$!

REST_OK=0
for _ in $(seq 1 15); do
  if curl -s -o /dev/null --max-time 2 http://127.0.0.1:${PF_PORT}/overview; then
    REST_OK=1
    break
  fi
  sleep 1
done

if [ "$REST_OK" -eq 1 ]; then
  check "REST: 至少 1 个 TaskManager 已注册" \
    bash -c 'curl -s --max-time 5 http://127.0.0.1:18081/taskmanagers | grep -q "\"id\""'

  check "REST: 存在 state=RUNNING 的作业" \
    bash -c 'curl -s --max-time 5 http://127.0.0.1:18081/jobs/overview | grep -q "\"state\":\"RUNNING\""'

  check "REST: 存在 checkpoint completed>=1 的作业" \
    bash -c 'for j in $(curl -s --max-time 5 http://127.0.0.1:18081/jobs/overview | grep -o "\"jid\":\"[0-9a-f]*\"" | cut -d\" -f4 | sort -u); do curl -s --max-time 5 http://127.0.0.1:18081/jobs/$j/checkpoints | grep -q "\"completed\":[1-9]" && exit 0; done; exit 1'

  check "REST: 存在从 savepoint 恢复（restored>=1）的作业" \
    bash -c 'for j in $(curl -s --max-time 5 http://127.0.0.1:18081/jobs/overview | grep -o "\"jid\":\"[0-9a-f]*\"" | cut -d\" -f4 | sort -u); do curl -s --max-time 5 http://127.0.0.1:18081/jobs/$j/checkpoints | grep -q "\"restored\":[1-9]" && exit 0; done; exit 1'
else
  echo "WARN: 18081 端口 port-forward 建立失败，REST 相关 4 项按 FAIL 计"
  fail "REST: 至少 1 个 TaskManager 已注册"
  fail "REST: 存在 state=RUNNING 的作业"
  fail "REST: 存在 checkpoint completed>=1 的作业"
  fail "REST: 存在从 savepoint 恢复（restored>=1）的作业"
fi

kill ${PF_PID} 2>/dev/null
wait ${PF_PID} 2>/dev/null

# ---------------------------------------------------------------- 主机状态目录
check "master 上 /var/flink-state/savepoints 下存在 savepoint" \
  bash -c 'ls /var/flink-state/savepoints 2>/dev/null | grep -q "^savepoint-"'

check "wordsrv 的 FLOOD 已切回 0" \
  bash -c 'kubectl -n flink-lab get deployment wordsrv -o yaml 2>/dev/null | grep -A1 "name: FLOOD" | grep -q "value: \"0\""'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
