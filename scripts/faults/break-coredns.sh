#!/usr/bin/env bash
# break-coredns.sh —— 故障注入：集群 DNS 解析异常
# 运行位置：[master]（kubeadm + Calico 单 master 集群，root 或 sudo 执行）
# 影响：CoreDNS ConfigMap 的 Corefile 中 forward 上游被指向死地址，
#       Pod 内解析外部域名失败，业务大量报 "no such host" / SERVFAIL；
#       CoreDNS Pod 本身 Running，表面看不出来
# 难度：★★☆
# 安全设计：
#   - 注入前把 CoreDNS ConfigMap 的 Corefile 原始内容备份到 /tmp/fault-backup-coredns
#   - --restore 时用备份原样还原并滚动重启 CoreDNS
#   - 幂等：备份已存在则拒绝重复注入
# 用法：
#   sudo bash break-coredns.sh            # 注入故障
#   sudo bash break-coredns.sh --restore  # 恢复原状
set -euo pipefail

CM_NS="kube-system"
CM_NAME="coredns"
BACKUP="/tmp/fault-backup-coredns"
TMP="/tmp/corefile.broken.$$"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

inject() {
  if [[ -f "${BACKUP}" ]]; then
    log "备份 ${BACKUP} 已存在，故障可能已注入过，跳过（如需重做请先 --restore）"
    return 0
  fi

  kubectl get configmap "${CM_NAME}" -n "${CM_NS}" -o jsonpath='{.data.Corefile}' > "${BACKUP}"
  chmod 600 "${BACKUP}"

  # kubeadm 生成的 Corefile 里 forward 行带 8 空格缩进，且可能是块形式：
  #     forward . /etc/resolv.conf {
  #        max_concurrent 1000
  #     }
  if ! grep -Eq '^[[:space:]]*forward[[:space:]]+\.' "${BACKUP}"; then
    log "Corefile 中没有 forward 行，放弃注入，清理备份"
    rm -f "${BACKUP}"
    exit 1
  fi

  # 幂等改写：无论上游原来写的是什么，统一指向本机无人监听的端口。
  # 块形式保留行尾的 '{'，保证改写后的 Corefile 仍是合法配置（CoreDNS 能启动）
  awk '
    /^[[:space:]]*forward[[:space:]]+\./ {
      line = "        forward . 127.0.0.1:5353"
      if ($0 ~ /\{[[:space:]]*$/) line = line " {"
      print line; next
    }
    { print }
  ' "${BACKUP}" > "${TMP}"

  kubectl create configmap "${CM_NAME}" -n "${CM_NS}" \
    --from-file=Corefile="${TMP}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "${TMP}"

  kubectl rollout restart deployment/"${CM_NAME}" -n "${CM_NS}"
  kubectl rollout status deployment/"${CM_NAME}" -n "${CM_NS}" --timeout=120s \
    || log "rollout 未在 120s 内完成，请稍后自行 kubectl -n kube-system get pods 检查"

  cat <<'EOF'

[已注入故障] break-coredns
[告警现象]（只描述现象，原因自己查）
  - Pod 内执行 nslookup baidu.com 失败：connection timed out; no servers could be reached
    或 server can't find baidu.com: SERVFAIL
  - 业务日志刷 Get "https://xxx": dial tcp: lookup xxx on 10.96.0.10:53: no such host
  - CoreDNS Pod 状态 Running，READY 1/1，重启次数 0
  - 集群内部完整 FQDN（kubernetes.default.svc.cluster.local）仍可解析；
    但裸短名（kubernetes.default）也会 SERVFAIL——它不命中 kubernetes 插件，被转发到坏上游
EOF
}

restore() {
  if [[ ! -f "${BACKUP}" ]]; then
    log "未找到备份 ${BACKUP}，无需恢复（可能未注入过故障）"
    return 0
  fi

  kubectl create configmap "${CM_NAME}" -n "${CM_NS}" \
    --from-file=Corefile="${BACKUP}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment/"${CM_NAME}" -n "${CM_NS}"
  kubectl rollout status deployment/"${CM_NAME}" -n "${CM_NS}" --timeout=120s \
    || log "rollout 未在 120s 内完成，请稍后自行检查"
  rm -f "${BACKUP}"

  log "已恢复 CoreDNS ConfigMap。验证命令："
  echo '  kubectl run -it --rm dns-test --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default'
}

case "${1:-}" in
  --restore) restore ;;
  "")        inject ;;
  *)         echo "用法: $0 [--restore]"; exit 1 ;;
esac
