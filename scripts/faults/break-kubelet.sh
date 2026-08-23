#!/usr/bin/env bash
# break-kubelet.sh —— 故障注入：kubelet 认证配置损坏
# 运行位置：[master]（kubeadm 节点通用；在 worker 上跑则该 worker 故障）
# 影响：kubelet 反复启动失败 → 节点约 40~60 秒后 NotReady；
#       节点上已有 Pod 继续运行，但无法新建/删除 Pod
# 难度：★★☆
# 安全设计：
#   - 修改前把 /var/lib/kubelet/config.yaml 完整备份到 /tmp/fault-backup-kubelet/
#   - --restore 时把原文件覆盖回去并重启 kubelet
#   - 幂等：备份目录已存在则拒绝重复注入
# 用法：
#   sudo bash break-kubelet.sh            # 注入故障
#   sudo bash break-kubelet.sh --restore  # 恢复原状
set -euo pipefail

KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
BACKUP_DIR="/tmp/fault-backup-kubelet"
BAD_CA="/etc/kubernetes/pki/nonexistent-ca.crt"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

inject() {
  if [[ -d "${BACKUP_DIR}" ]]; then
    log "备份目录 ${BACKUP_DIR} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi

  if [[ ! -f "${KUBELET_CONFIG}" ]]; then
    log "找不到 ${KUBELET_CONFIG}，本脚本只能在 kubeadm 部署的节点上运行"
    exit 1
  fi
  if ! grep -q 'clientCAFile:' "${KUBELET_CONFIG}"; then
    log "config.yaml 中没有 clientCAFile 字段（非典型 kubeadm 配置），放弃注入"
    exit 1
  fi

  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}"
  cp -a "${KUBELET_CONFIG}" "${BACKUP_DIR}/config.yaml"

  # 幂等改写：authentication.x509.clientCAFile 指向不存在的文件，kubelet 启动即失败。
  # kubelet 是 Type=notify，restart 会阻塞到 job 超时（约 90s）才返回非零，放后台执行
  sed -i "s|clientCAFile: .*|clientCAFile: ${BAD_CA}|" "${KUBELET_CONFIG}"
  (systemctl restart kubelet || true) >/dev/null 2>&1 &
  log "kubelet 正在后台重启（会启动失败），约 1 分钟后本节点 NotReady"

  cat <<'EOF'

[已注入故障] break-kubelet
[告警现象]（只描述现象，原因自己查）
  - kubectl get nodes：本节点约 40~60 秒后变为 NotReady
  - 节点上现有 Pod 不受影响（容器还在跑），但无法在该节点新建/删除 Pod
  - 该节点上的 Pod 无法执行 kubectl logs / exec
EOF
}

restore() {
  if [[ ! -f "${BACKUP_DIR}/config.yaml" ]]; then
    log "未找到备份 ${BACKUP_DIR}/config.yaml，无需恢复（可能未注入过故障）"
    return 0
  fi

  cp -a "${BACKUP_DIR}/config.yaml" "${KUBELET_CONFIG}"
  systemctl restart kubelet
  rm -rf "${BACKUP_DIR}"

  log "已还原 kubelet 配置并重启。验证命令："
  echo '  kubectl get nodes -w   # 约 30 秒内节点恢复 Ready'
  echo '  systemctl status kubelet'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
