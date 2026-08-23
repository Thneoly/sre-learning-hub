#!/usr/bin/env bash
# break-cni.sh —— 故障注入：CNI（Calico）被下线
# 运行位置：[master]（需要 kubectl）
# 影响：calico-node DaemonSet 的 nodeSelector 被塞进一个不存在的标签 →
#       DaemonSet 匹配不到任何节点，agent Pod 全部被删除；
#       同时 /etc/cni/net.d 下的 CNI 配置被移走 → kubelet 创建沙箱时找不到
#       网络配置，新 Pod 卡 ContainerCreating（network plugin is not ready）；
#       已运行 Pod 的 veth 还在，短期内不受影响
# 难度：★★☆
# 安全设计：
#   - DaemonSet 的 namespace 与 net.d 原始配置都备份在 /tmp/fault-backup-cni/ 下
#   - --restore 把 net.d 配置移回原位，并用 strategic merge patch 把坏 key 的
#     值置 null（即删除该键），不触碰 nodeSelector 里原有的其他键
#   - 幂等：备份目录已存在则拒绝重复注入
# 用法：
#   sudo bash break-cni.sh            # 注入故障
#   sudo bash break-cni.sh --restore  # 恢复原状
set -euo pipefail

BACKUP_DIR="/tmp/fault-backup-cni"
NETD="/etc/cni/net.d"
# 注意：DaemonSet 没有 spec.replicas、也没有 scale 子资源（kubectl scale ds 会 404），
# 下线 DaemonSet 的标准做法是给它一个匹配不到任何节点的 nodeSelector
BAD_KEY="fault-cni-disabled"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# 找到 calico-node DaemonSet 所在 namespace（manifest 安装在 kube-system，
# operator 安装在 calico-system）
find_cni() {
  kubectl get daemonset -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}' \
    | awk '$1 == "calico-node" {print $2; exit}'
}

inject() {
  if [[ -d "${BACKUP_DIR}" ]]; then
    log "备份目录 ${BACKUP_DIR} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi

  CNI_NS="$(find_cni || true)"
  if [[ -z "${CNI_NS}" ]]; then
    log "没有找到名为 calico-node 的 DaemonSet（本脚本假设 Calico 集群），放弃注入"
    exit 1
  fi
  if [[ ! -d "${NETD}" ]]; then
    log "目录 ${NETD} 不存在（非 Calico/kubeadm 布局），放弃注入"
    exit 1
  fi

  mkdir -p "${BACKUP_DIR}/net.d"
  chmod 700 "${BACKUP_DIR}"
  printf '%s\n' "${CNI_NS}" > "${BACKUP_DIR}/namespace"

  # 1) nodeSelector 塞进不存在的标签 → calico-node agent 全部下线
  kubectl patch daemonset calico-node -n "${CNI_NS}" \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"'"${BAD_KEY}"'":"true"}}}}}'
  kubectl rollout status daemonset/calico-node -n "${CNI_NS}" --timeout=120s \
    || log "calico Pod 终止较慢，请稍后自行 kubectl get pods -A | grep calico 确认"

  # 2) 移走 CNI 配置（agent 已死，不会再被自动写回；仅移非隐藏文件）
  find "${NETD}" -maxdepth 1 -type f ! -name '.*' -exec mv -t "${BACKUP_DIR}/net.d/" {} + \
    || log "net.d 下没有可移走的配置文件，继续"

  cat <<EOF

[已注入故障] break-cni
[告警现象]（只描述现象，原因自己查）
  - 节点约 1 分钟内变 NotReady：describe node 可见
    Ready=False ... NetworkReady=false reason:NetworkPluginNotReady
    message:"Network plugin returns error: cni plugin not initialized"
  - 新建 Pod 一直 Pending（FailedScheduling: untolerated taint node.kubernetes.io/not-ready）；
    已调度到节点的 Pod 卡 ContainerCreating（network plugin is not ready）
  - kubectl get pods -A | grep calico-node 为空（CNI agent Pod 全部消失）
  - 已有 Pod 继续运行，但 Pod IP 间互访逐步不通
EOF
}

restore() {
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    log "未找到备份目录 ${BACKUP_DIR}，无需恢复（可能未注入过故障）"
    return 0
  fi

  CNI_NS="$(cat "${BACKUP_DIR}/namespace" 2>/dev/null || echo kube-system)"

  # 1) net.d 配置放回原位
  if ls "${BACKUP_DIR}/net.d/" >/dev/null 2>&1; then
    mv "${BACKUP_DIR}"/net.d/* "${NETD}/" 2>/dev/null || true
  fi

  # 2) strategic merge patch 中把键的值置 null 即删除该键，不影响 nodeSelector 其他键
  kubectl patch daemonset calico-node -n "${CNI_NS}" \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"'"${BAD_KEY}"'":null}}}}}' \
    || log "恢复失败，请手工 kubectl -n ${CNI_NS} edit daemonset calico-node 检查 nodeSelector"
  rm -rf "${BACKUP_DIR}"

  log "已恢复 CNI 配置与 calico-node DaemonSet。验证命令："
  echo "  kubectl get pods -n ${CNI_NS} -o wide   # 每个节点都应有一个 calico-node Running"
  echo '  kubectl get pods -A | grep -Ev "Running|Completed"'
  echo '  kubectl run cni-test --image=busybox:1.36 -it --rm --restart=Never -- ping -c2 <另一Pod的IP>'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
