#!/usr/bin/env bash
# Lab 07 判分脚本（多环境晋升 GitOps 终态检查）
# 运行环境：练习集群 master / candidate VM（Ubuntu，kubectl 可用），已完成 task.md 全部任务
# 假设：ArgoCD 装在 argocd 命名空间；工作目录 ~/labs/env-promotion；
#       终态：overlays/staging 已建（ns demo-staging / count 2 / 128Mi）；
#       Application demo-app-dev（automated）与 demo-app-staging（手动）均 Synced+Healthy；
#       两环境镜像均已晋升为 nginx:1.27.4-alpine；
#       image-updater 注解已写入 apps/demo-app-dev.yaml 并应用到集群；
#       notify/feishu-webhook.log 已落盘含 msg_type；git log 含 promote 提交
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（kubectl 查询、文件读取、git log），不修改集群与仓库
set -u

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl 未安装或不在 PATH"; exit 1; }

WORK="$HOME/labs/env-promotion"

# 1. ArgoCD 存活
check "argocd-server Deployment 处于 Available" \
  bash -c '[ "$(kubectl -n argocd get deploy argocd-server -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null)" = "True" ]'

# 2. overlays/staging 结构与差异
check "overlays/staging/kustomization.yaml 存在" \
  test -f "$WORK/overlays/staging/kustomization.yaml"
check "staging overlay 声明 namespace demo-staging" \
  grep -q "namespace: demo-staging" "$WORK/overlays/staging/kustomization.yaml"
check "staging overlay 副本数为 2" \
  grep -q "count: 2" "$WORK/overlays/staging/kustomization.yaml"
check "staging overlay 资源请求含 128Mi" \
  grep -q "128Mi" "$WORK/overlays/staging/kustomization.yaml"

# 3. 两个 Application 的状态与策略
check "Application demo-app-dev 存在且 Healthy" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app-dev -o jsonpath="{.status.health.status}" 2>/dev/null)" = "Healthy" ]'
check "Application demo-app-dev 为 Synced" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app-dev -o jsonpath="{.status.sync.status}" 2>/dev/null)" = "Synced" ]'
check "demo-app-dev 配置了 automated 自动同步" \
  bash -c '[ -n "$(kubectl -n argocd get application.argoproj.io demo-app-dev -o jsonpath="{.spec.syncPolicy.automated}")" ]'
check "Application demo-app-staging 存在且 Healthy" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app-staging -o jsonpath="{.status.health.status}" 2>/dev/null)" = "Healthy" ]'
check "Application demo-app-staging 为 Synced" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app-staging -o jsonpath="{.status.sync.status}" 2>/dev/null)" = "Synced" ]'
check "demo-app-staging 未配置 automated（手动同步）" \
  bash -c '[ -z "$(kubectl -n argocd get application.argoproj.io demo-app-staging -o jsonpath="{.spec.syncPolicy.automated}")" ]'

# 4. 晋升终态（两环境镜像一致，staging 规格更高）
check "demo-dev 环境 demo-api 镜像为 nginx:1.27.4-alpine" \
  bash -c '[ "$(kubectl -n demo-dev get deploy demo-api -o jsonpath="{.spec.template.spec.containers[0].image}" 2>/dev/null)" = "nginx:1.27.4-alpine" ]'
check "demo-staging 环境 demo-api 镜像为 nginx:1.27.4-alpine" \
  bash -c '[ "$(kubectl -n demo-staging get deploy demo-api -o jsonpath="{.spec.template.spec.containers[0].image}" 2>/dev/null)" = "nginx:1.27.4-alpine" ]'
check "demo-staging 副本数为 2 且就绪 2" \
  bash -c '[ "$(kubectl -n demo-staging get deploy demo-api -o jsonpath="{.spec.replicas}/{.status.readyReplicas}" 2>/dev/null)" = "2/2" ]'

# 5. Image Updater 配置（文档级验证：文件字段 + 集群注解）
check "apps/demo-app-dev.yaml 含 image-list 注解（demo-app=nginx）" \
  grep -q "argocd-image-updater.argoproj.io/image-list: demo-app=nginx" "$WORK/apps/demo-app-dev.yaml"
check "apps/demo-app-dev.yaml 含 write-back-method: git" \
  grep -q "argocd-image-updater.argoproj.io/write-back-method: git" "$WORK/apps/demo-app-dev.yaml"
check "apps/demo-app-dev.yaml 含 write-back-target kustomization:overlays/dev" \
  grep -q "argocd-image-updater.argoproj.io/write-back-target: kustomization:overlays/dev" "$WORK/apps/demo-app-dev.yaml"
check "集群内 Application 已带 image-list 注解" \
  bash -c 'kubectl -n argocd get application.argoproj.io demo-app-dev -o jsonpath="{.metadata.annotations.argocd-image-updater\.argoproj\.io/image-list}" 2>/dev/null | grep -q nginx'

# 6. 飞书通知落盘
check "通知落盘文件 notify/feishu-webhook.log 存在" \
  test -f "$WORK/notify/feishu-webhook.log"
check "落盘内容含 msg_type" \
  grep -q "msg_type" "$WORK/notify/feishu-webhook.log"
check "落盘内容为 text 类型消息" \
  grep -q '"text"' "$WORK/notify/feishu-webhook.log"

# 7. 晋升的 Git 记录
check "git log 含 promote 提交记录" \
  bash -c "git -C \"$WORK\" log --oneline 2>/dev/null | grep -qi promote"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
