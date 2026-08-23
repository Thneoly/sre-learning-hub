#!/usr/bin/env bash
# install-prom-stack.sh — 为 PCA 实验安装监控栈：Prometheus + Alertmanager + Grafana + node-exporter
#
# 路线：优先 Helm（prometheus-community/kube-prometheus-stack）；
#       无外网/无 Helm 时走离线 manifest（脚本末尾打印说明）。
#
# 用法：bash install-prom-stack.sh            （在能访问集群的 master 上，root 或普通用户均可）
# 可选变量：
#   GRAFANA_PASSWORD  初始 admin 密码（默认 prom-operator，装完请按提示修改）
#   HELM_REPO_URL     覆盖 chart 仓库地址（默认官方，国内可换镜像后 helm repo update）
#   CHART_VERSION     固定 chart 版本（默认最新）
#   http_proxy / https_proxy / no_proxy      走代理拉 chart 与镜像

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

export GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-prom-operator}"
export HELM_REPO_URL="${HELM_REPO_URL:-https://prometheus-community.github.io/helm-charts}"
export http_proxy="${http_proxy:-}"
export https_proxy="${https_proxy:-}"
export no_proxy="${no_proxy:-localhost,127.0.0.1,10.96.0.0/12,172.31.0.0/16,.svc,.cluster.local}"

NS="monitoring"
RELEASE="prom"
CHART_VERSION="${CHART_VERSION:-}"
VERSION_ARG=""
[ -n "${CHART_VERSION}" ] && VERSION_ARG="--version ${CHART_VERSION}"

# NodePort 规划（默认范围 30000-32767；避开 ingress-nginx 的 30080/30443）
PORT_PROM=30900
PORT_AM=30903
PORT_GRAFANA=30300

# kubeconfig 定位：显式 KUBECONFIG > root 的 admin.conf > 普通用户的 ~/.kube/config
if [ -z "${KUBECONFIG:-}" ] && [ "$(id -u)" -eq 0 ] && [ -f /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi
if ! kubectl get nodes >/dev/null 2>&1; then
  log_err "kubectl 无法访问集群（KUBECONFIG=${KUBECONFIG:-未设置}），先跑 kubeadm-single-node.sh"
  exit 1
fi
confirm "将在命名空间 ${NS} 安装 kube-prometheus-stack（NodePort 暴露），继续" || exit 1

banner "Step 1/4 · 检查/安装 Helm"
if command -v helm >/dev/null 2>&1; then
  log_ok "helm $(helm version --short 2>/dev/null) 已安装"
else
  log_info "安装 Helm（官方脚本）"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  command -v helm >/dev/null 2>&1 && pass "helm 安装成功" || { fail "helm 安装失败，改走脚本末尾的离线路线"; exit 1; }
fi

banner "Step 2/4 · 准备 chart 仓库"
helm repo add prometheus-community "${HELM_REPO_URL}" 2>/dev/null || log_info "chart 仓库已存在"
helm repo update
log_ok "chart 仓库就绪: ${HELM_REPO_URL}"

banner "Step 3/4 · 部署 kube-prometheus-stack（NodePort）"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

cat > /tmp/prom-values.yaml <<EOF
# 精简覆盖：全套组件保留，UI 一律 NodePort 暴露（仅练习环境，勿用于生产）
prometheus:
  service:
    type: NodePort
    nodePort: ${PORT_PROM}
  prometheusSpec:
    retention: 3d
    resources:
      requests: { cpu: 100m, memory: 512Mi }
      limits:   { memory: 1Gi }

alertmanager:
  service:
    type: NodePort
    nodePort: ${PORT_AM}
  alertmanagerSpec:
    retention: 48h

grafana:
  adminPassword: "${GRAFANA_PASSWORD}"
  service:
    type: NodePort
    nodePort: ${PORT_GRAFANA}
  defaultDashboardsEnabled: true
  sidecar:
    dashboards:
      enabled: true

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
EOF

# shellcheck disable=SC2086
helm upgrade --install "${RELEASE}" prometheus-community/kube-prometheus-stack \
  ${VERSION_ARG} \
  -n "${NS}" -f /tmp/prom-values.yaml \
  --timeout 10m
log_info "helm 发布完成，等待 Pod 就绪（镜像合计约 2 GB，首次拉取可能较久）"

# 注意 1：operator 创建的 Prometheus STS 名带 "prometheus-" 前缀（Prometheus CR 名 = prom-kube-prometheus-stack-prometheus）。
# 注意 2：StatefulSet 在 minReadySeconds=0 时不上报 Available condition（k8s 1.35 实测），
#         对 STS 用 readyReplicas 判断，不用 wait_for_healthy。
wait_for "prometheus STS 就绪" 600 5 \
  "kubectl get sts prometheus-prom-kube-prometheus-stack-prometheus -n ${NS} -o jsonpath='{.status.readyReplicas}' | grep -qE '[1-9]'" || true
wait_for "alertmanager STS 就绪" 300 5 \
  "kubectl get sts alertmanager-prom-kube-prometheus-stack-alertmanager -n ${NS} -o jsonpath='{.status.readyReplicas}' | grep -qE '[1-9]'" || true
wait_for_healthy "deployment/prom-grafana -n ${NS}" 300 || true
# node-exporter DS 名 = <release>-prometheus-node-exporter（子 chart 独立命名，不带 kube-prometheus-stack 前缀）；
# DaemonSet 无 Available condition（k8s 1.35 实测），用 numberReady 判断。
wait_for "node-exporter DS 就绪" 300 5 \
  "kubectl get ds prom-prometheus-node-exporter -n ${NS} -o jsonpath='{.status.numberReady}' | grep -qE '[1-9]'" || true

banner "Step 4/4 · 验证与访问信息"
kubectl get pods -n "${NS}"
kubectl get svc -n "${NS}"

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
[ -n "${NODE_IP}" ] || NODE_IP="<master节点IP>"

echo
printf '%s ──────────── 监控栈访问信息 ────────────%s\n' "$C_BOLD" "$C_RESET"
cat <<EOF
Prometheus UI : http://${NODE_IP}:${PORT_PROM}   （无认证，仅练习网络内开放）
Alertmanager  : http://${NODE_IP}:${PORT_AM}
Grafana       : http://${NODE_IP}:${PORT_GRAFANA}   用户 admin / 密码 ${GRAFANA_PASSWORD}

kubectl port-forward 备选（本地访问，不经 NodePort）：
  kubectl -n ${NS} port-forward svc/prom-grafana 3000:80
  kubectl -n ${NS} port-forward svc/prom-kube-prometheus-stack-prometheus 9090:9090

默认密码修改（两种方式任选）：
  1) helm upgrade 重新指定（长期生效）：
     helm upgrade ${RELEASE} prometheus-community/kube-prometheus-stack \\
       -n ${NS} -f /tmp/prom-values.yaml --set grafana.adminPassword='<新密码>'
  2) Grafana UI 内改：左下角 Administration → Users → admin → New password
     （方式 2 只改运行时，下次 helm upgrade 可能被 values 覆盖）
EOF

echo
printf '%s ──────────── 无外网时的离线 manifest 路线 ────────────%s\n' "$C_BOLD" "$C_RESET"
cat <<'EOF'
上述流程需要能访问 chart 仓库与镜像仓库。离线环境改为：
  1. 在有网的机器上渲染 manifest（不依赖目标集群）：
       helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
       helm repo update
       helm template prom prometheus-community/kube-prometheus-stack -n monitoring \
         -f /tmp/prom-values.yaml > kube-prom-stack.yaml
  2. 拷贝 kube-prom-stack.yaml 到练习机：kubectl apply -n monitoring -f kube-prom-stack.yaml
  3. 镜像离线导入：有网机器 docker pull 后 docker save 成 tar，
     练习机 containerd 导入：ctr -n k8s.io images import <tar>
     涉及镜像（以渲染结果为准）：quay.io/prometheus/prometheus、quay.io/prometheus/alertmanager、
     grafana/grafana、quay.io/prometheus/node-exporter、registry.k8s.io/kube-state-metrics/kube-state-metrics
  4. 注意：helm template 渲染的 manifest 不含 Helm 生命周期信息，之后不能 helm uninstall，
     卸载用 kubectl delete -f kube-prom-stack.yaml 与 kubectl delete ns monitoring。
EOF
kubectl top nodes >/dev/null 2>&1 && pass "kubectl top 可用（node-exporter/metrics 链路正常）" \
  || log_warn "kubectl top 暂无输出（metrics-server 未就绪或需 1~2 分钟预热）"
exit_report
