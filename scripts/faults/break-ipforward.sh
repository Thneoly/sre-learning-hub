#!/usr/bin/env bash
# break-ipforward.sh —— 故障注入：宿主机关闭 IP 转发
# 运行位置：[任意节点]（在哪个节点注入，哪个节点的 Pod 转发受损）
# 影响：net.ipv4.ip_forward=0 → 该节点上 Pod 对外/跨节点访问不通，
#       Service 转发异常；节点本身的 SSH/管理流量不受影响（INPUT 链不走 FORWARD）
# 难度：★★☆
# 安全设计：
#   - 修改前把 net.ipv4.ip_forward 原始值写入 /tmp/fault-backup-ipforward
#   - --restore 时写回原值（正常集群应为 1）
#   - 幂等：备份已存在则拒绝重复注入
# 用法：
#   sudo bash break-ipforward.sh            # 注入故障
#   sudo bash break-ipforward.sh --restore  # 恢复原状
set -euo pipefail

KEY="net.ipv4.ip_forward"
BACKUP="/tmp/fault-backup-ipforward"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

inject() {
  if [[ -f "${BACKUP}" ]]; then
    log "备份 ${BACKUP} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi

  CUR="$(sysctl -n "${KEY}")"
  printf '%s\n' "${CUR}" > "${BACKUP}"
  chmod 600 "${BACKUP}"

  if [[ "${CUR}" != "1" ]]; then
    log "当前 ${KEY}=${CUR}（正常应为 1），继续注入"
  fi

  sysctl -w "${KEY}=0" > /dev/null

  cat <<'EOF'

[已注入故障] break-ipforward
[告警现象]（只描述现象，原因自己查）
  - 本节点 Pod 内 curl 外网 / 其他节点 Pod IP 全部超时
  - 从其他节点 curl 本节点 Pod IP 不通，但节点之间互相 ping 正常
  - 同节点 Pod 间部分场景也不通
  - 所有容器状态 Running，无 CrashLoop，日志无异常
  - 注意：若故障过几分钟自己消失，这本身也是一条排查线索
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi
  ORIG="$(cat "${BACKUP}")"
  sysctl -w "${KEY}=${ORIG}" > /dev/null
  rm -f "${BACKUP}"

  log "已恢复 ${KEY}=${ORIG}。验证命令："
  echo '  sysctl -n net.ipv4.ip_forward   # 应为原值（正常集群为 1）'
  echo '  kubectl run -it --rm net-test --image=busybox:1.36 --restart=Never -- wget -qO- --timeout=3 http://1.1.1.1'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
