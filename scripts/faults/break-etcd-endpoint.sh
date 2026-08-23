#!/usr/bin/env bash
# break-etcd-endpoint.sh —— 故障注入：apiserver 连不上 etcd
# 运行位置：[master]（kubeadm 静态 Pod 部署 apiserver 的集群）
# 影响：kube-apiserver 起不来 → 整个控制面失联，kubectl 全部超时/拒绝连接；
#       已有业务 Pod 继续运行（数据面不依赖 apiserver）
# 难度：★★★
# 安全设计：
#   - 修改前把 /etc/kubernetes/manifests/kube-apiserver.yaml 备份到
#     /tmp/fault-backup-etcd-endpoint/
#   - --restore 只用文件操作，不依赖 kubectl（apiserver 挂掉时也能恢复）
#   - 幂等：备份目录已存在则拒绝重复注入
# 用法：
#   sudo bash break-etcd-endpoint.sh            # 注入故障
#   sudo bash break-etcd-endpoint.sh --restore  # 恢复原状
set -euo pipefail

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_DIR="/tmp/fault-backup-etcd-endpoint"
BAD_ARG="--etcd-servers=https://127.0.0.1:2399"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

inject() {
  if [[ -d "${BACKUP_DIR}" ]]; then
    log "备份目录 ${BACKUP_DIR} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi

  if [[ ! -f "${MANIFEST}" ]]; then
    log "找不到 ${MANIFEST}，本脚本只能在 master（控制面）节点上运行"
    exit 1
  fi
  if ! grep -q -- '--etcd-servers=' "${MANIFEST}"; then
    log "manifest 中没有 --etcd-servers 参数（非典型 kubeadm 部署），放弃注入"
    exit 1
  fi

  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}"
  cp -a "${MANIFEST}" "${BACKUP_DIR}/kube-apiserver.yaml"

  # 幂等改写：无论原值是什么，统一替换为错误端口
  sed -i "s|--etcd-servers=.*|${BAD_ARG}|" "${MANIFEST}"

  cat <<'EOF'

[已注入故障] break-etcd-endpoint
[告警现象]（只描述现象，原因自己查）
  - kubectl get nodes 报 The connection to the server ...:6443 was refused 或超时
  - kubelet 在 20~60 秒内检测到变化并重建 apiserver 容器，容器反复崩溃
  - 已有业务 Pod 与 Service 转发不受影响（转发规则在 kube-proxy/iptables 里）
EOF
}

restore() {
  if [[ ! -f "${BACKUP_DIR}/kube-apiserver.yaml" ]]; then
    log "未找到备份 ${BACKUP_DIR}/kube-apiserver.yaml，无需恢复（可能未注入过故障）"
    return 0
  fi

  cp -a "${BACKUP_DIR}/kube-apiserver.yaml" "${MANIFEST}"
  rm -rf "${BACKUP_DIR}"

  log "已还原 apiserver manifest。kubelet 会在约 1~2 分钟内重建容器。验证命令："
  echo '  crictl ps | grep kube-apiserver   # 容器应为 Running 且不再重启'
  echo '  kubectl get nodes                 # apiserver 恢复后即可正常返回'
  echo '  journalctl -u kubelet --since -5min | grep -i apiserver'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
