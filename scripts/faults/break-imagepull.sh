#!/usr/bin/env bash
# break-imagepull.sh —— 故障注入：镜像拉取失败
# 运行位置：[master]（需要 kubectl）
# 影响：在 fault-imagepull 命名空间先建一个正常运行的演示 deployment，
#       再把镜像改成不存在的 tag → Pod 进入 ErrImagePull / ImagePullBackOff
# 难度：★☆☆
# 安全设计：
#   - 改动前把原始镜像字符串写入 /tmp/fault-backup-imagepull
#   - --restore 用备份镜像改回
#   - 幂等：镜像已含坏 tag 则拒绝重复注入
# 用法：
#   sudo bash break-imagepull.sh            # 注入故障
#   sudo bash break-imagepull.sh --restore  # 恢复原状
set -euo pipefail

NS="fault-imagepull"
DEP="fault-web"
GOOD_IMAGE="nginx:1.27-alpine"
BAD_IMAGE="nginx:1.27.99-notexist"
BACKUP="/tmp/fault-backup-imagepull"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# 注意：kubectl create deployment NAME --image=X 生成的容器名就是 NAME 本身，
# 所以 set image 的容器参数用 deployment 名（这里动态取一次，双保险）
container_name() {
  kubectl -n "${NS}" get deployment "${DEP}" -o jsonpath='{.spec.template.spec.containers[0].name}'
}

inject() {
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${NS}" create deployment "${DEP}" --image="${GOOD_IMAGE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${NS}" set resources deployment/"${DEP}" --requests=cpu=50m

  CUR="$(kubectl -n "${NS}" get deployment "${DEP}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  if [[ "${CUR}" == "${BAD_IMAGE}" ]]; then
    log "镜像已是坏 tag，故障已注入，跳过"
    return 0
  fi
  if [[ -f "${BACKUP}" ]]; then
    rm -f "${BACKUP}"   # 上一次注入后镜像被人工改过：以当前值为准重新备份
  fi
  printf '%s\n' "${CUR}" > "${BACKUP}"
  chmod 600 "${BACKUP}"

  kubectl -n "${NS}" rollout status deployment/"${DEP}" --timeout=180s \
    || log "旧副本未在 180s 内就绪（可能在拉镜像），故障注入继续"
  CNAME="$(container_name)"
  kubectl -n "${NS}" set image deployment/"${DEP}" "${CNAME}=${BAD_IMAGE}"

  cat <<'EOF'

[已注入故障] break-imagepull
[告警现象]（只描述现象，原因自己查）
  - kubectl -n fault-imagepull get pods：新 Pod 状态 ErrImagePull，随后 ImagePullBackOff
  - 事件：Failed to pull image ... not found / manifest unknown
  - 旧副本（注入前已 Running 的）不受影响，滚动更新卡住
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi
  ORIG="$(cat "${BACKUP}")"
  CNAME="$(container_name)"
  kubectl -n "${NS}" set image deployment/"${DEP}" "${CNAME}=${ORIG}"
  kubectl -n "${NS}" rollout status deployment/"${DEP}" --timeout=180s \
    || log "rollout 未在 180s 内完成，请稍后自行检查"
  rm -f "${BACKUP}"
  log "已恢复镜像 ${ORIG}。验证命令："
  echo "  kubectl -n ${NS} get pods   # 全部 Running，BackOff 副本消失"
  echo "  彻底清理演示资源：kubectl delete ns ${NS}"
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
