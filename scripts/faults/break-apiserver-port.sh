#!/usr/bin/env bash
# break-apiserver-port.sh —— 故障注入：apiserver 监听端口被改
# 运行位置：[master]（kubeadm 静态 Pod 部署 apiserver 的集群）
# 影响：kube-apiserver 的 --secure-port 改成 6444 → apiserver 在新端口稳定起来，
#       所有客户端（kubectl/controller-manager/scheduler/kubelet）仍连 6443 →
#       kubectl 全部 connection refused
# 难度：★★★
# 安全设计：
#   - 修改前把 /etc/kubernetes/manifests/kube-apiserver.yaml 备份到
#     /tmp/fault-backup-apiserver-port/
#   - --restore 只做文件操作（apiserver 失联时不需要 kubectl）
#   - 幂等：备份目录已存在则拒绝重复注入
# 用法：
#   sudo bash break-apiserver-port.sh            # 注入故障
#   sudo bash break-apiserver-port.sh --restore  # 恢复原状
set -euo pipefail

MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_DIR="/tmp/fault-backup-apiserver-port"
BAD_PORT="6444"
GOOD_PORT="6443"

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

  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}"
  cp -a "${MANIFEST}" "${BACKUP_DIR}/kube-apiserver.yaml"

  # kubeadm 会写明 --secure-port=6443；万一没写（非 kubeadm 默认部署），手动补一行
  if grep -q -- '--secure-port=' "${MANIFEST}"; then
    sed -i "s|--secure-port=[0-9]*|--secure-port=${BAD_PORT}|" "${MANIFEST}"
  else
    TMPF="/tmp/kube-apiserver.yaml.$$"
    awk -v extra="    - --secure-port=${BAD_PORT}" '
      { print }
      /^ *- kube-apiserver$/ { print extra }
    ' "${MANIFEST}" > "${TMPF}"
    cat "${TMPF}" > "${MANIFEST}"   # 用 cat 覆盖以保留原文件权限属主
    rm -f "${TMPF}"
  fi

  # 探针端口与 secure-port 一起迁移，保证 apiserver 在新端口"健康稳定"，故障形态
  # 纯粹是端口错位。两种 kubeadm manifest 风格都要覆盖：
  #   旧风格：liveness/readiness/startup 探针直接写 port: 6443
  #   新风格（v1.31+）：探针写 port: probe-port，解析到 ports 段的 containerPort: 6443
  sed -i "s|port: ${GOOD_PORT}|port: ${BAD_PORT}|g" "${MANIFEST}"
  sed -i "s|containerPort: ${GOOD_PORT}|containerPort: ${BAD_PORT}|g" "${MANIFEST}"

  cat <<'EOF'

[已注入故障] break-apiserver-port
[告警现象]（只描述现象，原因自己查）
  - kubectl 任意命令报 The connection to the server ...:6443 was refused
  - 与"apiserver 挂了"不同：ss -lntp 看到 6443 没人监听，但机器上有个新端口在监听，
    crictl ps 里 apiserver 容器 Running 且不重启
  - kubelet/controller-manager/scheduler 日志刷 connection refused
  - 已有业务 Pod 继续运行（数据面不依赖 apiserver）
EOF
}

restore() {
  if [[ ! -f "${BACKUP_DIR}/kube-apiserver.yaml" ]]; then
    log "未找到备份 ${BACKUP_DIR}/kube-apiserver.yaml，无需恢复（可能未注入过故障）"
    return 0
  fi
  cp -a "${BACKUP_DIR}/kube-apiserver.yaml" "${MANIFEST}"
  rm -rf "${BACKUP_DIR}"

  log "已还原 manifest（--secure-port=6443）。kubelet 约 1~2 分钟内重建容器。验证命令："
  echo '  ss -lntp | grep 6443          # 6443 重新被 kube-apiserver 监听'
  echo '  crictl ps | grep apiserver    # 容器 Running'
  echo '  kubectl get nodes'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
