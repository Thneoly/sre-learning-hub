#!/usr/bin/env bash
# reset-cluster.sh — 重置 kubeadm 集群并清理 CNI 残留
#
# 做什么：
#   1. kubeadm reset（停掉控制面与本节点的集群运行时状态）
#   2. 清理 CNI 残留：calico/flannel 虚拟接口、iptables 规则、/var/lib/cni、/run/flannel
#   3. 清理 kubeconfig 与证书目录（manifest 先备份到 ./backup-<时间戳>/）
#   4. 提示重跑 kubeadm-single-node.sh 或重新 join
#
# 用法：sudo bash reset-cluster.sh          （master 或 worker 上均可）
# 幂等：集群不存在时也能安全执行。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root

confirm "将执行 kubeadm reset 并清空 CNI/iptables，本节点集群数据将被销毁，继续" || exit 1

banner "Step 1/4 · kubeadm reset"
if command -v kubeadm >/dev/null 2>&1; then
  kubeadm reset -f || log_warn "kubeadm reset 返回非零（可能本就没有集群），继续清理残留"
else
  log_warn "未安装 kubeadm，跳过 reset，仅做残留清理"
fi
systemctl stop kubelet 2>/dev/null || true

banner "Step 2/4 · 清理 CNI 残留"
# 备份 manifest（想看"当时的静态 Pod 定义"排障时可来这里找；kubeadm reset 不删它们）
BACKUP_DIR="${SCRIPT_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
if [ -d /etc/kubernetes/manifests ]; then
  mkdir -p "${BACKUP_DIR}"
  cp -a /etc/kubernetes/manifests "${BACKUP_DIR}/" 2>/dev/null || true
  log_info "manifests 已备份到 ${BACKUP_DIR}/manifests（重跑 init 前这些文件会被新配置覆盖）"
fi

# 2a. 删除 CNI 虚拟接口：flannel 的 flannel.1/cni0、calico 的 tunl0(BIP)/vxlan-calico(VXLAN)
for iface in flannel.1 cni0 vxlan-calico tunl0 cali0; do
  if ip link show "$iface" &>/dev/null; then
    ip link delete "$iface" 2>/dev/null \
      && log_ok "已删除接口 ${iface}" \
      || log_warn "接口 ${iface} 删除失败（tunl0 是内核模块接口，删除报错可忽略）"
  else
    log_info "接口 ${iface} 不存在，跳过"
  fi
done
# 卸载 ipip 模块；有 Pod 残留引用时会失败，不影响
modprobe -r ipip 2>/dev/null || true

# 2b. 清理 CNI 运行时数据与配置
rm -rf /var/lib/cni/
rm -rf /var/lib/kubelet/
rm -rf /run/flannel
if [ -d /etc/cni/net.d ] && [ -n "$(ls -A /etc/cni/net.d 2>/dev/null)" ]; then
  mkdir -p "${BACKUP_DIR}/cni-conf"
  cp -a /etc/cni/net.d/. "${BACKUP_DIR}/cni-conf/" 2>/dev/null || true
  rm -rf /etc/cni/net.d/*
  log_ok "已清空 /etc/cni/net.d（原配置备份在 ${BACKUP_DIR}/cni-conf）"
fi

# 2c. iptables：先把策略放行避免误伤 ssh，再整表 flush
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
log_ok "iptables filter/nat/mangle 已清空（策略置 ACCEPT）"

banner "Step 3/4 · 清理 kubeconfig 与证书"
rm -f /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf
rm -f /etc/kubernetes/admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf
SUDO_USER_NAME="${SUDO_USER:-}"
if [ -n "${SUDO_USER_NAME}" ] && id "${SUDO_USER_NAME}" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "${SUDO_USER_NAME}" | cut -d: -f6)"
  rm -rf "${USER_HOME}/.kube"
  log_ok "已删除 ${USER_HOME}/.kube"
fi
rm -rf /root/.kube "${HOME:-/root}/.kube"
# /etc/kubernetes/pki 一并删除以保证绝对干净（重跑 init 会重新签发全套证书）。
# 想保留旧 CA 以复用证书的话，注释掉下一行。
rm -rf /etc/kubernetes/pki
systemctl restart containerd
log_ok "containerd 已重启"

banner "Step 4/4 · 下一步"
cat <<EOF
清理完成。当前节点回到"装好 kubeadm/kubelet/containerd 但无集群"的状态：
二进制、内核参数（br_netfilter/ip_forward）、swap 关闭都是持久化的，重跑不会重复配置。

[1] 重建单节点集群 : bash ${SCRIPT_DIR}/kubeadm-single-node.sh --cidr 172.31.0.0/16
[2] 或恢复 VMware 快照 "cluster-ready"（更快，见 scripts/README.md 的快照策略）
[3] 多节点环境的 worker 执行本脚本后重新 join：
      在 master 上 kubeadm token create --print-join-command，拿到命令到本机执行
EOF
pass "reset 完成"
exit_report
