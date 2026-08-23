#!/usr/bin/env bash
# Lab 01 判分脚本（GitLab CI pipeline 结构检查）
# 运行环境：Ubuntu 22.04/24.04，需要 python3 与 PyYAML（缺则：sudo apt install -y python3-yaml）
# 假设：已完成 task.md 的任务，存在项目目录 ~/labs/ci-demo 且其中含 .gitlab-ci.yml
# 用法：check.sh [项目目录]   目录缺省为当前目录
# 说明：只读检查 .gitlab-ci.yml 的语法结构与关键 job，不执行任何 pipeline job
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

TARGET="${1:-.}"
CI_FILE="$TARGET/.gitlab-ci.yml"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 未安装或不在 PATH"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: 缺少 PyYAML，先执行 sudo apt install -y python3-yaml"; exit 1; }

# 0. 文件存在
check ".gitlab-ci.yml 存在" test -f "$CI_FILE"

# 1. 是合法 YAML（能被 yaml.safe_load 解析且为 dict）
check "文件是合法 YAML" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if isinstance(d,dict) else 1)' "$CI_FILE"

# 2. stages 依次为 lint, build, test, image
check "stages 顺序为 [lint, build, test, image]" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if d.get("stages")==["lint","build","test","image"] else 1)' "$CI_FILE"

# 3. lint job 存在且属于 lint stage
check "lint job 存在且 stage 为 lint" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if d.get("lint",{}).get("stage")=="lint" else 1)' "$CI_FILE"

# 4. lint job 用 python 3.12 镜像且 script 含 ruff check
check "lint job image 为 python:3.12-slim 且执行 ruff check" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("lint",{}); s=" ".join(j.get("script",[])); sys.exit(0 if str(j.get("image","")).startswith("python:3.12") and "ruff check" in s else 1)' "$CI_FILE"

# 5. build job 存在且属于 build stage
check "build job 存在且 stage 为 build" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if d.get("build",{}).get("stage")=="build" else 1)' "$CI_FILE"

# 6. build job 声明 artifacts 且 paths 包含 dist/
check "build job 产出 artifacts（dist/）" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("build",{}); sys.exit(0 if "dist/" in j.get("artifacts",{}).get("paths",[]) else 1)' "$CI_FILE"

# 7. test job 属于 test stage 且 script 含 pytest
check "test job 存在且执行 pytest" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("test",{}); s=" ".join(j.get("script",[])); sys.exit(0 if j.get("stage")=="test" and "pytest" in s else 1)' "$CI_FILE"

# 8. test job 通过 dependencies 引用 build
check "test job 通过 dependencies 引用 build 的 artifacts" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("test",{}); sys.exit(0 if "build" in j.get("dependencies",[]) else 1)' "$CI_FILE"

# 9. image-build job 属于 image stage 且执行 docker build
check "image-build job 存在且执行 docker build" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("image-build",{}); s=" ".join(j.get("script",[])); sys.exit(0 if j.get("stage")=="image" and "docker build" in s else 1)' "$CI_FILE"

# 10. image-build 的镜像 tag 使用了 CI_COMMIT_SHORT_SHA 或 CI_PIPELINE_IID
check "image-build 的 tag 使用 CI_COMMIT_SHORT_SHA 或 CI_PIPELINE_IID" \
  python3 -c 'import yaml,sys; j=yaml.safe_load(open(sys.argv[1],encoding="utf-8")).get("image-build",{}); b=yaml.safe_dump(j,default_flow_style=False); sys.exit(0 if ("CI_COMMIT_SHORT_SHA" in b or "CI_PIPELINE_IID" in b) else 1)' "$CI_FILE"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
