#!/usr/bin/env bash
# break-endpoints.sh —— 故障注入：Service 没有后端（Endpoints 变空）
# 运行位置：[master]（需要 kubectl）
# 影响：先在 fault-ep 命名空间建一套演示 deployment+svc（一切正常），
#       再改 Service 的 selector 使其匹配不到任何 Pod → Endpoints 为空，
#       访问 ClusterIP 立即 connection refused / 超时
# 难度：★★☆
# 安全设计：
#   - 改动前把 Service 原始 selector（键=值，取自集群现场）写入 /tmp/fault-backup-endpoints
#   - --restore 用备份值改回 selector
#   - 幂等：selector 已是坏值则拒绝重复注入
# 用法：
#   sudo bash break-endpoints.sh            # 注入故障
#   sudo bash break-endpoints.sh --restore  # 恢复原状
set -euo pipefail

NS="fault-ep"
DEP="fault-web"
SVC="fault-web-svc"
GOOD_VAL="fault-web"
BAD_VAL="fault-web-typo"
BACKUP="/tmp/fault-backup-endpoints"

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
    app: ${GOOD_VAL}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${GOOD_VAL}
  template:
    metadata:
      labels:
        app: ${GOOD_VAL}
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
EOF
  # 只在 Service 不存在时创建：避免重复注入时 apply 把坏 selector 又刷回正常值
  if ! kubectl -n "${NS}" get svc "${SVC}" >/dev/null 2>&1; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
spec:
  selector:
    app: ${GOOD_VAL}
  ports:
  - port: 80
    targetPort: 80
EOF
  fi
  kubectl -n "${NS}" rollout status deployment/"${DEP}" --timeout=180s \
    || log "副本未在 180s 内就绪（可能在拉镜像），故障注入继续"
}

inject() {
  create_demo

  CUR="$(kubectl -n "${NS}" get svc "${SVC}" -o jsonpath='{.spec.selector.app}')"
  if [[ "${CUR}" == "${BAD_VAL}" ]]; then
    log "Service selector 已是坏值，故障已注入，跳过"
    return 0
  fi
  printf 'app=%s\n' "${CUR}" > "${BACKUP}"
  chmod 600 "${BACKUP}"

  kubectl -n "${NS}" patch svc "${SVC}" --type=json \
    -p '[{"op":"replace","path":"/spec/selector/app","value":"'"${BAD_VAL}"'"}]'

  cat <<'EOF'

[已注入故障] break-endpoints
[告警现象]（只描述现象，原因自己查）
  - curl fault-web-svc.fault-ep.svc.cluster.local 返回 connection refused 或一直挂起
  - kubectl -n fault-ep get endpoints fault-web-svc 显示 ENDPOINTS 为 <none>
  - 后端 Pod 全部 Running，deployment READY 2/2，无重启
  - Pod 直接用 Pod IP 访问是通的，只有走 Service VIP 不通
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi
  local sel key val
  sel="$(cat "${BACKUP}")"
  key="${sel%%=*}"
  val="${sel#*=}"
  kubectl -n "${NS}" patch svc "${SVC}" --type=json \
    -p '[{"op":"replace","path":"/spec/selector/'"${key}"'","value":"'"${val}"'"}]'
  rm -f "${BACKUP}"

  log "已恢复 Service selector。验证命令："
  echo "  kubectl -n ${NS} get endpoints ${SVC}   # 应出现两个 Pod IP"
  echo "  kubectl run -it --rm ep-test --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=3 ${SVC}.${NS}.svc.cluster.local"
  echo "  彻底清理演示资源：kubectl delete ns ${NS}"
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
