#!/usr/bin/env bash
# kubeadm-single-node.sh — 在干净的 Ubuntu 22.04/24.04 上从零搭好单节点 kubeadm 集群
#
# 产出：1 master（可调度）+ Calico + metrics-server + ingress-nginx + local-path 默认 SC
#
# 用法：
#   sudo bash kubeadm-single-node.sh                        # 默认 podCIDR 172.31.0.0/16
#   sudo bash kubeadm-single-node.sh --cidr 10.244.0.0/16   # 自定义 podCIDR（勿与宿主网段重叠）
#   sudo ASSUME_YES=1 bash kubeadm-single-node.sh           # 全程免交互
#
# 可选变量：APT_MIRROR / http_proxy / https_proxy / no_proxy（含义同 install-docker.sh）
# 幂等：任意步骤可重跑；已初始化的集群跳过 init，只补缺失组件。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root

# ---------------------------------------------------------------------------
# 参数与默认值
# ---------------------------------------------------------------------------
POD_CIDR="172.31.0.0/16"
K8S_VERSION="${K8S_VERSION:-v1.31}"          # apt 仓库大版本，小版本由仓库最新决定
CALICO_VER="${CALICO_VER:-v3.28.2}"
INGRESS_VER="${INGRESS_VER:-controller-v1.12.1}"
LPP_VER="${LPP_VER:-v0.0.30}"               # rancher local-path-provisioner

while [ $# -gt 0 ]; do
  case "$1" in
    --cidr)         POD_CIDR="$2"; shift 2 ;;
    --k8s-version)  K8S_VERSION="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_err "未知参数: $1（--help 查看）"; exit 1 ;;
  esac
done

export APT_MIRROR="${APT_MIRROR:-}"
export http_proxy="${http_proxy:-}"
export https_proxy="${https_proxy:-}"
export no_proxy="${no_proxy:-localhost,127.0.0.1,10.96.0.0/12,${POD_CIDR},.svc,.cluster.local}"
export DEBIAN_FRONTEND=noninteractive

UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
KUBECONFIG_ADMIN="/etc/kubernetes/admin.conf"
# 导出 KUBECONFIG：让本脚本与 wait_for_healthy 里的裸 kubectl 都能访问集群
export KUBECONFIG="${KUBECONFIG_ADMIN}"
KC="kubectl --kubeconfig=${KUBECONFIG_ADMIN}"

log_info "podCIDR=${POD_CIDR}  k8s=${K8S_VERSION}  ubuntu=${UBUNTU_CODENAME}"
confirm "将在本机初始化 Kubernetes 单节点集群（关 swap / 改内核参数 / 装 containerd+kubeadm），继续" || exit 1

# ---------------------------------------------------------------------------
banner "Step 1/8 · 关闭 swap"
if [ "$(swapon --show | wc -l)" -eq 0 ]; then
  log_ok "swap 已关闭"
else
  swapoff -a
  # 持久化：注释 /etc/fstab 中的 swap 行（原文件备份为 /etc/fstab.bak）
  [ -f /etc/fstab.bak ] || cp /etc/fstab /etc/fstab.bak
  sed -i -E '/\sswap\s|\/swap/s/^/# disabled-for-k8s /' /etc/fstab
  log_ok "swap 已关闭并从 fstab 注释（备份 /etc/fstab.bak）"
fi

# ---------------------------------------------------------------------------
banner "Step 2/8 · 内核模块（overlay / br_netfilter）与 sysctl"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null
sysctl -n net.bridge.bridge-nf-call-iptables | grep -q 1 && pass "br_netfilter 生效" || fail "br_netfilter 未生效"
sysctl -n net.ipv4.ip_forward | grep -q 1 && pass "ip_forward=1" || fail "ip_forward 未开启"

# ---------------------------------------------------------------------------
banner "Step 3/8 · containerd（SystemdCgroup）"
if pkg_installed containerd.io; then
  log_info "检测到 containerd.io（install-docker.sh 安装），复用，不再装发行版 containerd 包"
elif ! pkg_installed containerd; then
  apt-get update -y
  apt-get install -y containerd
fi
mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ] || ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  log_info "已写入 SystemdCgroup = true（kubelet 用 systemd cgroup 驱动，两边必须一致）"
else
  log_info "containerd 已配置 SystemdCgroup，跳过"
fi
systemctl enable --now containerd
systemctl restart containerd
systemctl is-active containerd >/dev/null && pass "containerd running" || fail "containerd 异常"

# ---------------------------------------------------------------------------
banner "Step 4/8 · 安装 kubeadm / kubelet / kubectl（${K8S_VERSION}）"
if [ -n "${APT_MIRROR}" ]; then
  K8S_APT_HOST="${APT_MIRROR}/kubernetes-new/core/stable/${K8S_VERSION}/main"
else
  K8S_APT_HOST="pkgs.k8s.io/core:/stable:/${K8S_VERSION}/main"
fi
if ! pkg_installed kubeadm; then
  apt-get update -y
  apt-get install -y ca-certificates curl gpg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    curl -fsSL "https://${K8S_APT_HOST}/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://${K8S_APT_HOST}/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -y
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
else
  log_ok "kubeadm 已安装（$(kubeadm version -o short 2>/dev/null || echo unknown)），跳过"
fi
systemctl enable --now kubelet

# ---------------------------------------------------------------------------
banner "Step 5/8 · 预拉镜像（官方源失败自动切阿里云）"
IMAGE_REPO="registry.k8s.io"
if kubeadm config images pull --image-repository "${IMAGE_REPO}" 2>/dev/null; then
  log_ok "镜像从 registry.k8s.io 拉取完成"
else
  log_warn "官方源拉取失败，改用 registry.aliyuncs.com/google_containers"
  IMAGE_REPO="registry.aliyuncs.com/google_containers"
  kubeadm config images pull --image-repository "${IMAGE_REPO}"
fi

# ---------------------------------------------------------------------------
banner "Step 6/8 · kubeadm init（podCIDR=${POD_CIDR}）"
if [ -f "${KUBECONFIG_ADMIN}" ] && ${KC} get nodes >/dev/null 2>&1; then
  log_ok "集群已初始化，跳过 init（当前节点: $(${KC} get nodes -o jsonpath='{.items[0].metadata.name}')）"
else
  kubeadm init \
    --pod-network-cidr="${POD_CIDR}" \
    --image-repository="${IMAGE_REPO}" \
    --ignore-preflight-errors=NumCPU,Mem \
    --token-ttl=0
  # --token-ttl=0：join token 永不过期，方便随时扩 worker（仅练习环境）
fi

# kubeconfig 分发：root 一份；若是 sudo 触发的，给日常账号也来一份
install -d -m 700 /root/.kube
install -m 600 "${KUBECONFIG_ADMIN}" /root/.kube/config
log_ok "kubeconfig 已写入 /root/.kube/config"
SUDO_USER_NAME="${SUDO_USER:-}"
if [ -n "${SUDO_USER_NAME}" ] && id "${SUDO_USER_NAME}" >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "${SUDO_USER_NAME}" | cut -d: -f6)"
  install -d -m 700 -o "${SUDO_USER_NAME}" -g "${SUDO_USER_NAME}" "${USER_HOME}/.kube"
  install -m 600 -o "${SUDO_USER_NAME}" -g "${SUDO_USER_NAME}" "${KUBECONFIG_ADMIN}" "${USER_HOME}/.kube/config"
  log_ok "kubeconfig 已写入 ${USER_HOME}/.kube/config（属主 ${SUDO_USER_NAME}）"
fi

# ---------------------------------------------------------------------------
banner "Step 7/8 · Calico（CIDR 对齐 ${POD_CIDR}）"
if ${KC} get ds -n kube-system calico-node >/dev/null 2>&1; then
  log_ok "calico-node 已存在，跳过"
else
  CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/calico.yaml"
  curl -fsSL "${CALICO_URL}" -o /tmp/calico.yaml
  # 打开 CALICO_IPV4POOL_CIDR 注释块并替换为实际 podCIDR（manifest 默认注释着 192.168.0.0/16）
  # 用捕获组保留各行原有缩进——不同 Calico 版本的注释缩进不同，写死缩进会弄坏 YAML（实测 v3.29.2 踩坑）
  sed -i -E \
    -e "s@^([[:space:]]*)#[[:space:]]*- name: CALICO_IPV4POOL_CIDR@\1- name: CALICO_IPV4POOL_CIDR@" \
    -e "s@^([[:space:]]*)#[[:space:]]*value: \"192\.168\.0\.0/16\"@\1value: \"${POD_CIDR}\"@" \
    /tmp/calico.yaml
  # 应用前做一次语法预检，替换坏了就中止而不是半途报错
  if ! ${KC} apply --dry-run=client -f /tmp/calico.yaml >/dev/null 2>&1; then
    fail "calico.yaml 语法预检失败（CIDR 替换可能弄坏了缩进），请手工检查 /tmp/calico.yaml"
  fi
  if grep -q "value: \"${POD_CIDR}\"" /tmp/calico.yaml; then
    pass "calico.yaml CIDR 已设为 ${POD_CIDR}"
  else
    fail "calico.yaml CIDR 替换失败，请手工编辑 /tmp/calico.yaml 后 kubectl apply -f /tmp/calico.yaml"
  fi
  ${KC} apply -f /tmp/calico.yaml
fi

# 单节点：去掉 control-plane taint，让 master 可调度普通 Pod
if ${KC} taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null; then
  log_ok "已移除 control-plane taint（单节点可调度）"
else
  log_info "taint 不存在（可能已移除），继续"
fi

# ---------------------------------------------------------------------------
banner "Step 8/8 · 增强组件：metrics-server / ingress-nginx / local-path SC"
# metrics-server：自签 kubelet 证书环境下需 --kubelet-insecure-tls（仅练习环境，CKS 里是反面教材）
if ${KC} get deployment -n kube-system metrics-server >/dev/null 2>&1; then
  log_ok "metrics-server 已存在，跳过"
else
  ${KC} apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  ${KC} patch deployment -n kube-system metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
    || log_warn "metrics-server patch 失败（可能已带该参数），继续"
fi

# ingress-nginx：baremetal 版（DaemonSet + NodePort 30080/30432）
if ${KC} get deployment -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
  log_ok "ingress-nginx 已存在，跳过"
else
  ${KC} apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VER}/deploy/static/provider/baremetal/deploy.yaml"
fi

# local-path-provisioner：轻量动态存储，并设为默认 StorageClass
if ${KC} get deployment -n local-path-storage local-path-provisioner >/dev/null 2>&1; then
  log_ok "local-path-provisioner 已存在，跳过"
else
  ${KC} apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LPP_VER}/deploy/local-path-storage.yaml"
fi
${KC} patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  && log_ok "local-path 已设为默认 StorageClass" \
  || log_warn "设置默认 SC 失败（local-path 可能未就绪），稍后手工执行同命令"

# ---------------------------------------------------------------------------
banner "等待核心组件就绪"
wait_for_healthy "ds/calico-node -n kube-system" 300 || true
wait_for_healthy "deployment/metrics-server -n kube-system" 300 || true
wait_for_healthy "deployment/ingress-nginx-controller -n ingress-nginx" 300 || true
wait_for "节点 Ready" 300 5 "${KC} get nodes -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

# ---------------------------------------------------------------------------
banner "验证清单"
NODE_NAME="$(hostname)"
${KC} get nodes -o wide
${KC} get pods -A
echo
printf '%s ──────────── 集群就绪 ────────────%s\n' "$C_BOLD" "$C_RESET"
cat <<EOF
[1] 节点状态 : kubectl get nodes    → ${NODE_NAME} 应为 Ready
[2] 系统 Pod : kubectl get pods -A  → kube-system / calico-node 全 Running
[3] 指标链路 : kubectl top nodes    → 有输出说明 metrics-server 正常（首次约需 1~2 分钟）
[4] 动态存储 : kubectl get sc       → local-path 标记 (DEFAULT)
[5] ingress  : kubectl get svc -n ingress-nginx ingress-nginx-controller → 记下 80/443 的 NodePort
[6] 快照提醒 : 现在回 VMware 打快照 "cluster-ready"（见 scripts/README.md）
EOF
echo
printf '%s ──────────── kubeconfig 提示 ────────────%s\n' "$C_BOLD" "$C_RESET"
cat <<EOF
  root 会话     : 已写入 /root/.kube/config（sudo -i 后直接 kubectl）
  普通用户     : ${SUDO_USER_NAME:-<你的用户名>} 的 ~/.kube/config 已就绪；无则手工执行：
                 mkdir -p ~/.kube
                 sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config
                 sudo chown \$(id -u):\$(id -g) ~/.kube/config
  加入新节点   : kubeadm token create --print-join-command（多节点见 setup/MULTI-NODE.md）
  重置集群     : bash ${SCRIPT_DIR}/reset-cluster.sh
EOF
exit_report
