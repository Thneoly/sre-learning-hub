#!/usr/bin/env bash
# break-static-pod.sh —— 故障注入：静态 Pod manifest 被移走
# 运行位置：[master]（kube-scheduler 静态 Pod 所在的控制面节点）
# 影响：kube-scheduler 静态 Pod 被 kubelet 删除 → 新建 Pod 永远 Pending；
#       已运行的 Pod 与 Service 不受影响
# 难度：★★☆
# 安全设计：
#   - 把移出的 manifest 完整保存在 /tmp/fault-backup-static-pod/ 下
#   - --restore 时移动回原位即可，不依赖 kubectl（纯文件操作）
#   - 幂等：备份目录已存在则拒绝重复注入
# 用法：
#   sudo bash break-static-pod.sh            # 注入故障
#   sudo bash break-static-pod.sh --restore  # 恢复原状
set -euo pipefail

MANIFEST_DIR="/etc/kubernetes/manifests"
MANIFEST="${MANIFEST_DIR}/kube-scheduler.yaml"
BACKUP_DIR="/tmp/fault-backup-static-pod"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

inject() {
  if [[ -d "${BACKUP_DIR}" ]]; then
    log "备份目录 ${BACKUP_DIR} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi
  if [[ ! -f "${MANIFEST}" ]]; then
    log "找不到 ${MANIFEST}（可能已移出或不是 kubeadm master），放弃注入"
    exit 1
  fi

  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}"
  # kubelet 监视 manifests 目录：文件一移走，对应 Pod 即被删除
  mv "${MANIFEST}" "${BACKUP_DIR}/kube-scheduler.yaml"

  cat <<'EOF'

[已注入故障] break-static-pod
[告警现象]（只描述现象，原因自己查）
  - kubectl -n kube-system get pods：kube-scheduler-<节点名> Pod 消失（不是 CrashLoop）
  - 新建 Deployment 的 Pod 一直 Pending，Events 里只有
    "FailedScheduling: no nodes available to schedule pods" 类信息
  - get/delete 已有资源一切正常（apiserver 没问题）
EOF
}

restore() {
  if [[ ! -f "${BACKUP_DIR}/kube-scheduler.yaml" ]]; then
    log "未找到备份 ${BACKUP_DIR}/kube-scheduler.yaml，无需恢复（可能未注入过故障）"
    return 0
  fi

  mv "${BACKUP_DIR}/kube-scheduler.yaml" "${MANIFEST}"
  rmdir "${BACKUP_DIR}" 2>/dev/null || true

  log "已把 manifest 放回 ${MANIFEST_DIR}，kubelet 约 10~30 秒内重建静态 Pod。验证命令："
  echo '  kubectl -n kube-system get pods | grep scheduler   # 应重新出现并 Running'
  echo '  kubectl get events --sort-by=.lastTimestamp | tail'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
