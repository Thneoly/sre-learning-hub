#!/usr/bin/env bash
# break-rbac.sh —— 故障注入：业务依赖的 ClusterRoleBinding 被删
# 运行位置：[master]（需要 kubectl）
# 影响：先建一套演示用 RBAC + 一个依赖它的巡检 Pod（每 10 秒 kubectl get pods），
#       再删除 ClusterRoleBinding → Pod 内开始刷 Forbidden；
#       不动系统自带的任何 ClusterRole/ClusterRoleBinding
# 难度：★★☆
# 安全设计：
#   - 被删的 ClusterRoleBinding 的完整 YAML 在删除前备份到 /tmp/fault-backup-rbac.yaml
#     （内容就是本脚本自己写的演示对象，无 resourceVersion 等状态字段）
#   - --restore 重新 apply 备份文件
#   - 幂等：重复执行不会叠加破坏
# 用法：
#   sudo bash break-rbac.sh            # 注入故障
#   sudo bash break-rbac.sh --restore  # 恢复原状（演示资源保留，清理命令见结尾输出）
set -euo pipefail

NS="fault-rbac"
CRB_NAME="fault-demo-pod-reader-binding"
SA_NAME="fault-app-reader"
# tag 跟随集群次版本调整（kubectl 允许与 apiserver 相差一个 minor）。
# 注意：bitnami/kubectl 的版本 tag 已从 docker.io 下架（404），且 registry.k8s.io/kubectl
# 是无 shell 的最小镜像（跑不了 sh -c 循环）；alpine/k8s 带 sh+kubectl（走 docker.io 代理）
KUBECTL_IMAGE="alpine/k8s:1.35.0"
BACKUP="/tmp/fault-backup-rbac.yaml"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# 演示命名空间 + 巡检 Deployment（依赖 SA 的权限循环执行 kubectl get pods）
apply_demo() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${NS}" create serviceaccount "${SA_NAME}" --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rbac-checker
  namespace: ${NS}
  labels:
    app: rbac-checker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rbac-checker
  template:
    metadata:
      labels:
        app: rbac-checker
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
      - name: kubectl
        image: ${KUBECTL_IMAGE}
        command: ["sh", "-c"]
        args: ["while true; do kubectl get pods -n ${NS}; sleep 10; done"]
EOF
}

apply_bindings() {
  kubectl create clusterrole "${CRB_NAME%-binding}" --verb=get,list,watch --resource=pods \
    --dry-run=client -o yaml | kubectl apply -f -
  # 备份内容 = 我们自己写的这份 YAML（与集群中对象等价）
  cat > "${BACKUP}" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CRB_NAME%-binding}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NS}
EOF
  chmod 600 "${BACKUP}"
  kubectl apply -f "${BACKUP}"
}

inject() {
  apply_demo
  if kubectl get clusterrolebinding "${CRB_NAME}" >/dev/null 2>&1; then
    # 已存在：确保备份是最新内容，再执行删除（幂等）
    apply_bindings
  else
    if [[ -f "${BACKUP}" ]]; then
      log "检测到备份已存在且绑定已被删除，故障已注入，跳过"
      return 0
    fi
    apply_bindings
  fi

  kubectl -n "${NS}" rollout status deployment/rbac-checker --timeout=180s \
    || log "rbac-checker 未在 180s 内就绪（可能在拉镜像），故障注入继续"
  sleep 8

  # 注入：删掉业务依赖的 ClusterRoleBinding
  kubectl delete clusterrolebinding "${CRB_NAME}"

  cat <<'EOF'

[已注入故障] break-rbac
[告警现象]（只描述现象，原因自己查）
  - fault-rbac 命名空间的 rbac-checker Pod 仍为 Running，但日志持续刷：
    Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:fault-rbac:fault-app-reader" cannot list resource "pods"
  - 集群其他 workload 一切正常，节点 Ready，网络畅通
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi
  kubectl apply -f "${BACKUP}"
  log "已恢复 ClusterRoleBinding。验证命令："
  echo "  kubectl logs -n ${NS} deploy/rbac-checker --tail=20   # 不再出现 Forbidden"
  echo "  kubectl auth can-i list pods --as=system:serviceaccount:${NS}:${SA_NAME}   # 应输出 yes"
  echo "  彻底清理演示资源：kubectl delete ns ${NS}; kubectl delete clusterrole ${CRB_NAME%-binding}; kubectl delete clusterrolebinding ${CRB_NAME}"
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
