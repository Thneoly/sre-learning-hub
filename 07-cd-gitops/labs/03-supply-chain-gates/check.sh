#!/usr/bin/env bash
# Lab 06 判分脚本 —— cosign 签名闸门 + Trivy 漏洞闸门（全部只读：读文件/grep/解析 YAML，不执行任何签名、扫描或 pipeline）
# 运行环境：Ubuntu，需要 python3 与 PyYAML（缺则：sudo apt install -y python3-yaml）
# 假设：已按 task.md 完成，目录 ~/labs/supply-chain-lab 下有 results/、cosign.pub、ci/.gitlab-ci.yml
# 用法：check.sh [lab目录]   目录缺省为 ~/labs/supply-chain-lab
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

# 读退出码文件并比对期望值（文件缺失/非数字均判 FAIL）
exit_is() {
  local file="$1" want="$2"
  [ -f "$file" ] || return 1
  local got
  got=$(tr -d '[:space:]' < "$file")
  [ "$got" = "$want" ]
}

# 读退出码文件并判定为非零（cosign 新版 v2.5+/v3 对 "no signatures" 返回专属退出码 10，旧版返回 1——判分只认"非零即被拒"）
exit_nonzero() {
  local file="$1"
  [ -f "$file" ] || return 1
  local got
  got=$(tr -d '[:space:]' < "$file")
  [ "$got" -ge 1 ] 2>/dev/null
}

LAB="${1:-$HOME/labs/supply-chain-lab}"
RES="$LAB/results"
CI_FILE="$LAB/ci/.gitlab-ci.yml"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 未安装"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: 缺少 PyYAML，先执行 sudo apt install -y python3-yaml"; exit 1; }

# ---------- 1. 四个 exit code 记录 ----------
check "cosign_sign.exit 存在且为 0（签名成功）" exit_is "$RES/cosign_sign.exit" 0
check "cosign_verify_signed.exit 存在且为 0（已签名镜像验证通过）" exit_is "$RES/cosign_verify_signed.exit" 0
check "cosign_verify_unsigned.exit 存在且非 0（未签名镜像验证被拒；新版 cosign 返回 10，旧版返回 1）" exit_nonzero "$RES/cosign_verify_unsigned.exit"
check "trivy_gate.exit 存在且为 1（HIGH/CRITICAL 超阈被拦）" exit_is "$RES/trivy_gate.exit" 1

# ---------- 2. 密钥对 ----------
check "cosign.pub 存在且为 PEM 公钥" \
  bash -c "test -f '$LAB/cosign.pub' && grep -q 'PUBLIC KEY' '$LAB/cosign.pub'"

# ---------- 3. 两次 pipeline 运行的落盘日志 ----------
# 注意 gitlab-ci-local 会把 script 命令行原样回显（$ 前缀行），命令里的 echo "BLOCKED..." 字样
# 不算闸门输出；真正的 job 输出行是 "> " 前缀——判 BLOCKED 只认输出行，判 DEPLOY OK 同理
check "pipeline-passed.log 存在且含 DEPLOY OK（deploy 执行）" \
  bash -c "test -f '$RES/pipeline-passed.log' && grep -qE '> *.*DEPLOY OK' '$RES/pipeline-passed.log'"
check "pipeline-passed.log 无 BLOCKED 输出（闸门全绿）" \
  bash -c "! grep -qE '> *.*BLOCKED' '$RES/pipeline-passed.log'"
check "pipeline-blocked.log 存在且含 BLOCKED 输出（闸门拦截）" \
  bash -c "test -f '$RES/pipeline-blocked.log' && grep -qE '> *.*BLOCKED' '$RES/pipeline-blocked.log'"
check "pipeline-blocked.log 无 DEPLOY OK（deploy 未执行）" \
  bash -c "! grep -q 'DEPLOY OK' '$RES/pipeline-blocked.log'"

# ---------- 4. .gitlab-ci.yml 结构（只读解析） ----------
check ".gitlab-ci.yml 存在且为合法 YAML" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if isinstance(d,dict) else 1)' "$CI_FILE"

check "verify-signature job 调 cosign verify 且带 --key" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("verify-signature",{}); s=" ".join(j.get("script",[])); sys.exit(0 if "cosign verify" in s and "--key" in s else 1)' "$CI_FILE"

check "scan-image job 调 trivy 且 --severity HIGH,CRITICAL 与 --exit-code 1" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("scan-image",{}); s=" ".join(j.get("script",[])); sys.exit(0 if "trivy" in s and "HIGH,CRITICAL" in s.replace(" ","") and "--exit-code 1" in s else 1)' "$CI_FILE"

check "deploy job 通过 needs 依赖两个闸门 job" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("deploy",{}); n=j.get("needs",[]); sys.exit(0 if "verify-signature" in n and "scan-image" in n else 1)' "$CI_FILE"

echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
