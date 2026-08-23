#!/usr/bin/env bash
# break-dns-config.sh —— 故障注入：Pod 级 DNS 配置错误
# 运行位置：[master]（需要 kubectl）
# 影响：在 fault-dns 命名空间建一个演示 deployment，并把它的 dnsPolicy 改为 None、
#       dnsConfig.nameservers 指向不可达地址 → 该命名空间 Pod 内所有域名解析失败；
#       其他命名空间不受影响
# 难度：★★☆
# 为什么必须是 dnsPolicy: None：
#   kubelet 的 appendDNSConfig 会把 dnsConfig.nameservers 追加在集群 DNS 之后
#   （resolv.conf 里排第二，解析器根本轮不到它），只加 nameserver 不改 policy
#   时故障不会复现；dnsPolicy: None 才会让 Pod 只用这份坏配置
# 安全设计：
#   - 演示资源只建在 fault-dns 命名空间；注入前把原 dnsPolicy 记到
#     /tmp/fault-backup-dns-config；--restore 改回原 policy 并移除 dnsConfig，
#     Pod 恢复使用集群默认 DNS（CoreDNS）
#   - 幂等：dnsConfig 已存在则跳过注入
# 用法：
#   sudo bash break-dns-config.sh            # 注入故障
#   sudo bash break-dns-config.sh --restore  # 恢复原状
set -euo pipefail

NS="fault-dns"
DEP="fault-dns-client"
IMAGE="busybox:1.36"
BACKUP="/tmp/fault-backup-dns-config"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

create_demo() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEP}
  namespace: ${NS}
  labels:
    app: ${DEP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEP}
  template:
    metadata:
      labels:
        app: ${DEP}
    spec:
      dnsPolicy: ClusterFirst
      containers:
      - name: client
        image: ${IMAGE}
        command: ["sh", "-c"]
        args: ["while true; do nslookup kubernetes.default; sleep 10; done"]
        resources:
          requests:
            cpu: 20m
EOF
  kubectl -n "${NS}" rollout status deployment/"${DEP}" --timeout=180s \
    || log "副本未在 180s 内就绪（可能在拉镜像），故障注入继续"
}

inject() {
  create_demo

  CUR="$(kubectl -n "${NS}" get deployment "${DEP}" -o jsonpath='{.spec.template.spec.dnsConfig}')"
  if [[ -n "${CUR}" ]]; then
    log "dnsConfig 已存在，故障已注入，跳过"
    return 0
  fi
  ORIG_POLICY="$(kubectl -n "${NS}" get deployment "${DEP}" -o jsonpath='{.spec.template.spec.dnsPolicy}')"
  ORIG_POLICY="${ORIG_POLICY:-ClusterFirst}"
  printf '%s\n' "${ORIG_POLICY}" > "${BACKUP}"
  chmod 600 "${BACKUP}"

  # 192.0.2.53 是 RFC 5737 TEST-NET-1 文档地址，永不可达
  kubectl -n "${NS}" patch deployment "${DEP}" --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/dnsPolicy","value":"None"},
    {"op":"add","path":"/spec/template/spec/dnsConfig",
     "value":{"nameservers":["192.0.2.53"],"options":[{"name":"ndots","value":"5"}]}}]'
  kubectl -n "${NS}" rollout status deployment/"${DEP}" --timeout=120s \
    || log "rollout 未在 120s 内完成，请稍后自行检查"

  cat <<'EOF'

[已注入故障] break-dns-config
[告警现象]（只描述现象，原因自己查）
  - 只有 fault-dns 命名空间的 Pod 解析失败：
    nslookup kubernetes.default → connection timed out; no servers could be reached
  - 其他命名空间（含 default）Pod 内解析一切正常
  - CoreDNS Pod Running，coredns 指标无异常
  - cat /etc/resolv.conf：nameserver 只有 192.0.2.53，看不到集群 DNS（10.96.0.10）
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi
  ORIG_POLICY="$(cat "${BACKUP}")"
  kubectl -n "${NS}" patch deployment "${DEP}" --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/dnsPolicy","value":"'"${ORIG_POLICY}"'"}]' \
    || log "dnsPolicy 恢复失败，请手工 kubectl -n ${NS} edit deployment ${DEP} 检查"
  kubectl -n "${NS}" patch deployment "${DEP}" --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/dnsConfig"}]' \
    || log "dnsConfig 不存在，可能已被人工修复"
  kubectl -n "${NS}" rollout status deployment/"${DEP}" --timeout=120s \
    || log "rollout 未在 120s 内完成，请稍后自行检查"
  rm -f "${BACKUP}"

  log "已移除错误 dnsConfig 并恢复 dnsPolicy=${ORIG_POLICY}。验证命令："
  echo "  kubectl -n ${NS} exec deploy/${DEP} -- cat /etc/resolv.conf   # nameserver 应为 10.96.0.10"
  echo "  kubectl -n ${NS} logs deploy/${DEP} --tail=5                   # nslookup 应返回正常结果"
  echo "  彻底清理演示资源：kubectl delete ns ${NS}"
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
