#!/usr/bin/env bash
# Lab 05 判分脚本 —— SonarQube 质量门禁（只读检查：文件/内核参数为只读查询，API 均为 GET）
# 运行环境：Ubuntu，需要 curl 与 python3；SonarQube compose 栈仍在运行（task.md 要求先判分再 down）
# 约定（可用环境变量覆盖）：
#   SONAR_URL               默认 http://localhost:9000
#   SONAR_ADMIN_PASSWORD    默认 Lab05Sonar123（task.md 第 3 步约定）
#   SONAR_LAB_DIR           默认 ~/labs/sonar-lab
# 用法：check.sh [lab目录]   目录缺省为 ~/labs/sonar-lab
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

URL="${SONAR_URL:-http://localhost:9000}"
PW="${SONAR_ADMIN_PASSWORD:-Lab05Sonar123}"
LAB="${1:-${SONAR_LAB_DIR:-$HOME/labs/sonar-lab}}"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl 未安装"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 未安装"; exit 1; }

# ---------- 1. 内核参数（只读） ----------
check "/etc/sysctl.d 下存在 vm.max_map_count=524288 的持久化配置" \
  bash -c "grep -rE '^vm.max_map_count=524288' /etc/sysctl.d/ 2>/dev/null | grep -q ."

check "当前 vm.max_map_count ≥ 524288" \
  bash -c "[ \$(sysctl -n vm.max_map_count) -ge 524288 ]"

# ---------- 2. compose 文件与内存限制（只读） ----------
COMPOSE="$LAB/docker-compose.yml"
check "docker-compose.yml 存在（$COMPOSE）" test -f "$COMPOSE"
check "sonarqube 服务内存限制 2g" \
  bash -c "grep -E 'mem_limit: *2g' '$COMPOSE'"
check "postgres 服务内存限制 512m" \
  bash -c "grep -E 'mem_limit: *512m' '$COMPOSE'"

# ---------- 3. 两次扫描的落盘证据 ----------
check "evidence/scan1.json 存在且 gate 状态为 ERROR（首次扫描被拦）" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if d.get("projectStatus",{}).get("status")=="ERROR" else 1)' "$LAB/evidence/scan1.json"

check "evidence/scan1.json 含 duplication 类未通过条件" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8"))["projectStatus"]; cs=d.get("conditions",[]); sys.exit(0 if d.get("status")=="ERROR" and any(c.get("status")=="ERROR" and "duplicat" in str(c.get("metricKey") or c.get("metric") or "").lower() for c in cs) else 1)' "$LAB/evidence/scan1.json"

check "evidence/scan2.json 存在且 gate 状态为 OK（修复后放行）" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if d.get("projectStatus",{}).get("status")=="OK" else 1)' "$LAB/evidence/scan2.json"

# ---------- 4. 在线 API 复核（GET，只读） ----------
check "SonarQube 在线且状态 UP" \
  bash -c "curl -su admin:'$PW' '$URL/api/system/status' | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get(\"status\")==\"UP\" else 1)'"

check "项目 demo-app 存在" \
  bash -c "curl -su admin:'$PW' '$URL/api/projects/search?projects=demo-app' | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(c[\"key\"]==\"demo-app\" for c in d.get(\"components\",[])) else 1)'"

check "duplicated_lines_density 历史一高一低（max≥5 且 min≤3，≥2 条记录）" \
  bash -c "curl -su admin:'$PW' '$URL/api/measures/search_history?metrics=duplicated_lines_density&component=demo-app' | python3 -c 'import sys,json; m=json.load(sys.stdin)[\"measures\"][0]; v=[float(x[\"value\"]) for x in m[\"history\"]]; sys.exit(0 if len(v)>=2 and max(v)>=5.0 and min(v)<=3.0 else 1)'"

check "当前 quality gate 状态为 OK" \
  bash -c "curl -su admin:'$PW' '$URL/api/qualitygates/project_status?projectKey=demo-app' | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get(\"projectStatus\",{}).get(\"status\")==\"OK\" else 1)'"

echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
