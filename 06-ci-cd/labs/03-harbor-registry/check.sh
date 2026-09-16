#!/usr/bin/env bash
# Lab 04 判分脚本 —— Harbor 私有镜像仓库（full 模式全部为只读 GET API 查询，不改动 Harbor 任何数据）
# 运行环境：Ubuntu，需要 curl 与 python3；Harbor 已按 task.md 部署且服务在运行
# 约定（可用环境变量覆盖）：
#   HARBOR_URL              默认 http://127.0.0.1:8080
#   HARBOR_ADMIN_PASSWORD   默认 Lab04Harbor（task.md 第 2 步约定的 harbor_admin_password）
#   HARBOR_HOME             默认 ~/labs/harbor-lab（SIMULATED 分支查 harbor.yml 与安装计划文档）
# 模式：
#   full      —— Harbor API 可达，按只读 API 逐项判分
#   simulated —— API 不可达（未完成安装/已 down），降级校验 harbor.yml 关键字段与安装计划文档
# 版本兼容（实测 v2.15 vs 旧版 API 差异，均先试新形式、失败回落旧形式）：
#   - projects 列表字段：2.x 返回 name（旧版为 project_name），两者都认
#   - artifacts 路径：2.10+ 仓库名用项目内叶名（demo-app，无需编码）；旧版为全名 %2F 编码
#   - artifacts 默认不带 tags/scan_overview，需显式 with_tag=true / with_scan_overview=true
#   - 项目机器人列表：2.10+ 移除了 /projects/{name}/robots，改用 /robots?q=Level=project,ProjectID=N
#   - retention 查询：GET /retentions?project_id= 仅允许 POST（405）；2.x 经项目 metadata.retention_id
#     再 GET /retentions/{id} 取规则
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

URL="${HARBOR_URL:-http://127.0.0.1:8080}"
PW="${HARBOR_ADMIN_PASSWORD:-Lab04Harbor}"
AUTH="admin:${PW}"
HARBOR_HOME="${HARBOR_HOME:-$HOME/labs/harbor-lab}"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl 未安装"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 未安装"; exit 1; }

# ---------- 模式识别 ----------
if curl -sf -u "$AUTH" "$URL/api/v2.0/projects?page_size=1" >/dev/null 2>&1; then
  MODE=full
  echo "MODE: full（Harbor API 在线，执行只读 API 判分）"
else
  MODE=simulated
  echo "MODE: simulated（Harbor API 不可达，校验 harbor.yml 与安装计划文档）"
fi

if [ "$MODE" = full ]; then

  # 1. API 可达且凭据有效（projects 列表返回 200）
  check "Harbor API 可达且 admin 凭据有效" \
    curl -sf -u "$AUTH" "$URL/api/v2.0/projects?page_size=1"

  # 2. 私有项目 demo 存在（2.x 字段为 name，旧版为 project_name）
  check "私有项目 demo 存在" \
    bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/projects?page_size=100' | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if any((p.get(\"name\") or p.get(\"project_name\"))==\"demo\" for p in d) else 1)'"

  PID=$(curl -sf -u "$AUTH" "$URL/api/v2.0/projects?page_size=100" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next((str(p["project_id"]) for p in d if (p.get("name") or p.get("project_name"))=="demo"), ""))' 2>/dev/null || true)

  # 3. demo 项目下仓库列表非空
  check "demo 项目下仓库列表非空" \
    bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/repositories' | python3 -c 'import sys,json; sys.exit(0 if len(json.load(sys.stdin))>0 else 1)'"

  # 4. demo/demo-app 至少有一个 artifact，且带非空 tag
  #    2.10+ 路径用项目内叶名（demo-app）；旧版为全名 %2F 编码；tags 需 with_tag=true
  check "仓库 demo/demo-app 存在带 tag 的 artifact" \
    bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/repositories/demo-app/artifacts?with_tag=true' | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(a.get(\"tags\") for a in d) else 1)' || curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/repositories/demo%2Fdemo-app/artifacts?with_tag=true' | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(a.get(\"tags\") for a in d) else 1)'"

  # 5. 至少一个 artifact 的 Trivy 扫描状态为 Success（scan_overview 需显式请求）
  check "已有镜像完成 Trivy 扫描（scan_status=Success）" \
    bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/repositories/demo-app/artifacts?with_scan_overview=true' | python3 -c 'import sys,json; d=json.load(sys.stdin); ok=any(v.get(\"scan_status\")==\"Success\" for a in d for v in (a.get(\"scan_overview\") or {}).values()); sys.exit(0 if ok else 1)' || curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/repositories/demo%2Fdemo-app/artifacts?with_scan_overview=true' | python3 -c 'import sys,json; d=json.load(sys.stdin); ok=any(v.get(\"scan_status\")==\"Success\" for a in d for v in (a.get(\"scan_overview\") or {}).values()); sys.exit(0 if ok else 1)'"

  # 6. 机器人账户存在（CI 专用凭据）
  #    2.10+ 用 /robots?q=Level=project,ProjectID=N 查项目级机器人；旧版用 /projects/demo/robots
  if [ -n "${PID:-}" ]; then
    check "demo 项目下存在机器人账户" \
      bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/robots?q=Level=project,ProjectID=$PID' | python3 -c 'import sys,json; sys.exit(0 if len(json.load(sys.stdin))>0 else 1)' || curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/robots' | python3 -c 'import sys,json; sys.exit(0 if len(json.load(sys.stdin))>0 else 1)'"
  else
    check "demo 项目下存在机器人账户" \
      bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/projects/demo/robots' | python3 -c 'import sys,json; sys.exit(0 if len(json.load(sys.stdin))>0 else 1)'"
  fi

  # 7. retention 规则已配置（含 retain 动作）
  #    2.x：GET /retentions?project_id= 已只允许 POST（405），经项目 metadata.retention_id 取规则 ID；
  #    旧版：GET /retentions?project_id=N 返回规则数组
  if [ -n "${PID:-}" ]; then
    RID=$(curl -sf -u "$AUTH" "$URL/api/v2.0/projects/$PID" \
      | python3 -c 'import sys,json; print((json.load(sys.stdin).get("metadata") or {}).get("retention_id",""))' 2>/dev/null || true)
    if [ -n "${RID:-}" ] && [ "$RID" != "0" ]; then
      check "retention 规则已配置（存在 retain 动作）" \
        bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/retentions/$RID' | python3 -c '
import sys,json
d=json.load(sys.stdin)
rules=d.get(\"rules\",[]) if isinstance(d,dict) else [r for x in d for r in x.get(\"rules\",[])]
def act(r):
    a=r.get(\"action\")
    return a.get(\"type\") if isinstance(a,dict) else a
sys.exit(0 if any(act(r)==\"retain\" for r in rules) else 1)'"
    else
      check "retention 规则已配置（存在 retain 动作）" \
        bash -c "curl -sf -u '$AUTH' '$URL/api/v2.0/retentions?project_id=$PID' | python3 -c '
import sys,json
d=json.load(sys.stdin)
rules=d.get(\"rules\",[]) if isinstance(d,dict) else [r for x in d for r in x.get(\"rules\",[])]
def act(r):
    a=r.get(\"action\")
    return a.get(\"type\") if isinstance(a,dict) else a
sys.exit(0 if any(act(r)==\"retain\" for r in rules) else 1)'"
    fi
  else
    fail "retention 规则已配置（无法获取 demo 的 project_id，请确认项目存在）"
  fi

else

  # ---------- SIMULATED：校验 harbor.yml 关键字段 ----------
  YML="$HARBOR_HOME/harbor/harbor.yml"
  PLAN="$HARBOR_HOME/install-plan.md"

  echo "SIMULATED: Harbor 未在线运行，按配置结构判分"

  check "harbor.yml 已生成（$HARBOR_HOME/harbor/harbor.yml）" \
    test -f "$YML"
  check "harbor.yml 配置了 hostname" \
    bash -c "grep -E '^[[:space:]]*hostname:' '$YML'"
  check "harbor.yml 为 http 模式（配置了 http.port 且未启用 https 端口）" \
    bash -c "grep -A4 '^http:' '$YML' | grep -E 'port: 8080' && ! grep -E '^[[:space:]]*port: 443' '$YML'"
  check "harbor.yml 修改了 admin 初始密码（非注释行）" \
    bash -c "grep -E '^harbor_admin_password:' '$YML'"
  check "安装计划文档存在（install-plan.md）" \
    test -f "$PLAN"
  check "安装计划覆盖机器人账户/retention/扫描三个环节" \
    bash -c "grep -qi 'robot' '$PLAN' && grep -qi 'retention' '$PLAN' && grep -qiE 'trivy|scan' '$PLAN'"

fi

echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
