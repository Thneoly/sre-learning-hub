#!/usr/bin/env bash
# break-scheduler-pod.sh —— 故障注入：节点资源被低优先级 Pod 占满
# 运行位置：[master]（需要 kubectl；假设单 master 集群，业务 Pod 都落在 master 上，
#           多节点集群请把本脚本里的对象改到目标节点，否则业务可能被调度去别的节点）
# 影响：创建一个低优先级"资源海绵"Deployment，请求几乎全部可分配 CPU，
#       之后创建的演示业务 Pod 全部 Pending（Insufficient cpu）
# 难度：★★☆
# 安全设计：
#   - 所有对象都建在独立命名空间 fault-sched，并把命名空间记到
#     /tmp/fault-backup-scheduler-pod
#   - --restore 删除该命名空间与演示 PriorityClass（海绵与演示业务一起清理）
#   - 幂等：备份已存在则拒绝重复注入
# 用法：
#   sudo bash break-scheduler-pod.sh            # 注入故障
#   sudo bash break-scheduler-pod.sh --restore  # 恢复原状
set -euo pipefail

NS="fault-sched"
BACKUP="/tmp/fault-backup-scheduler-pod"
IMAGE="nginx:1.27-alpine"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# CPU 值转 millicores："4"→4000，"440m"→440，"1.5"→1000（取整，宁可少算）
to_milli() {
  local v="${1:-}"
  case "${v}" in
    *m) echo "${v%m}" ;;
    "") echo 0 ;;
    *.*) echo "${v%%.*}000" ;;
    *)   echo "$(( v * 1000 ))" ;;
  esac
}

# 节点上已被占用的 CPU requests 总和（Pending Pod 没有 nodeName，天然被排除）
used_milli() {
  kubectl get pods -A --field-selector "spec.nodeName=${1}" \
    --output jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}{end}' \
    | awk '{ if ($0 ~ /m$/) { sub(/m$/, "", $0); s += $0 } else if ($0 != "") { s += $0 * 1000 } } END { printf "%.0f\n", s + 0 }'
}

# 容忍控制面 taint（单 master 集群若未去 taint，Pod 必须容忍才能落上去；无 taint 时无害）
TOLERATIONS='      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule'

inject() {
  if [[ -f "${BACKUP}" ]]; then
    log "备份 ${BACKUP} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi

  NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
  ALLOC_M="$(to_milli "$(kubectl get node "${NODE}" -o jsonpath='{.status.allocatable.cpu}')")"
  USED_M="$(used_milli "${NODE}")"
  HOG_M=$(( ALLOC_M - USED_M - 50 ))
  if (( HOG_M < 50 )); then
    HOG_M=50   # 节点本就接近满载，海绵给最小值即可让业务 Pod Pending
  fi
  log "节点 ${NODE}：allocatable=${ALLOC_M}m，已用 requests=${USED_M}m，海绵将请求 cpu=${HOG_M}m"

  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

  # 0) 低优先级 PriorityClass：海绵 value=10，业务默认 0，抢占不会自动发生
  cat <<'EOF' | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: fault-low
value: 10
globalDefault: false
description: "fault-sched 演示用：低优先级资源海绵"
EOF

  # 1) 资源海绵：请求几乎全部剩余 CPU
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fault-sponge
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fault-sponge
  template:
    metadata:
      labels:
        app: fault-sponge
    spec:
      priorityClassName: fault-low
${TOLERATIONS}
      containers:
      - name: sponge
        image: ${IMAGE}
        resources:
          requests:
            cpu: ${HOG_M}m
            memory: 64Mi
EOF
  kubectl -n "${NS}" rollout status deployment/fault-sponge --timeout=180s \
    || log "海绵未在 180s 内就绪（可能在拉镜像），故障注入继续"

  printf '%s\n' "${NS}" > "${BACKUP}"
  chmod 600 "${BACKUP}"

  # 2) 之后创建的"业务"Pod：请求 100m，落不下去
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fault-app
  namespace: ${NS}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fault-app
  template:
    metadata:
      labels:
        app: fault-app
    spec:
${TOLERATIONS}
      containers:
      - name: app
        image: ${IMAGE}
        resources:
          requests:
            cpu: 100m
EOF

  sleep 8

  cat <<'EOF'

[已注入故障] break-scheduler-pod
[告警现象]（只描述现象，原因自己查）
  - kubectl -n fault-sched get pods：fault-app 两个副本一直 Pending，0/2 READY
  - describe pod 事件：FailedScheduling - "Insufficient cpu"
  - 集群节点 Ready，kube-scheduler / kube-controller-manager 正常运行
  - 已有业务 Pod 不受影响，只是新 Pod 上不去
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi
  kubectl delete namespace "${NS}" --ignore-not-found --timeout=90s
  kubectl delete priorityclass fault-low --ignore-not-found
  rm -f "${BACKUP}"
  log "已删除海绵与演示业务（namespace ${NS}）及 PriorityClass fault-low。验证命令："
  echo '  kubectl get ns fault-sched   # 应已消失'
  echo '  kubectl describe node | grep -A8 "Allocated resources"   # CPU requests 应回落'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
