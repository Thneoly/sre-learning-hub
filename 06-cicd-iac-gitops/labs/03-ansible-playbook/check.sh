#!/usr/bin/env bash
# Lab 03 判分脚本（Ansible playbook 结构 + 部署终态检查）
# 运行环境：Ubuntu 22.04/24.04 VM，需要 ansible-playbook 在 PATH、python3 与 PyYAML（sudo apt install -y python3-yaml）
# 假设：已完成 task.md 的任务（终态：nginx 运行、首页含 ansible-lab、结果文件已生成）
#       最后一项 --check 干跑需要 root 权限（不弹密码）：建议 sudo ./check.sh 运行，或已配置 NOPASSWD
# 用法：check.sh [playbook 所在目录]   目录缺省为当前目录
# 说明：结构检查为只读解析；--check 是 Ansible 官方 dry-run 模式，不修改系统状态
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
PB="$TARGET/deploy-nginx.yml"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 未安装或不在 PATH"; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo "ERROR: ansible-playbook 未安装或不在 PATH"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: 缺少 PyYAML，先执行 sudo apt install -y python3-yaml"; exit 1; }

# ---------- playbook 结构检查 ----------

# 1. 文件存在
check "deploy-nginx.yml 存在" test -f "$PB"

# 2. 语法检查通过
check "ansible-playbook --syntax-check 通过" ansible-playbook --syntax-check "$PB"

# 3. play 头部：hosts localhost + connection local + become true
check "play 头部为 hosts=localhost / connection=local / become=true" \
  python3 -c 'import yaml,sys; p=yaml.safe_load(open(sys.argv[1],encoding="utf-8")); x=p[0] if isinstance(p,list) else {}; sys.exit(0 if x.get("hosts")=="localhost" and x.get("connection")=="local" and x.get("become") is True else 1)' "$PB"

# 4. 用 apt 模块安装 nginx
check "存在 apt 任务安装 nginx" \
  python3 -c '
import yaml,sys
tasks=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))[0].get("tasks",[])
ok=False
for t in tasks:
    for mod in ("ansible.builtin.apt","apt"):
        if mod in t and "nginx" in str(t[mod].get("name","")):
            ok=True
sys.exit(0 if ok else 1)' "$PB"

# 5. 用 template 模块渲染 /var/www/html/index.html
check "存在 template 任务部署 /var/www/html/index.html" \
  python3 -c '
import yaml,sys
tasks=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))[0].get("tasks",[])
ok=False
for t in tasks:
    for mod in ("ansible.builtin.template","template"):
        if mod in t and str(t[mod].get("dest","")).endswith("/var/www/html/index.html"):
            ok=True
sys.exit(0 if ok else 1)' "$PB"

# 6. 用 service 模块确保 nginx started + enabled
check "存在 service 任务（nginx started 且 enabled）" \
  python3 -c '
import yaml,sys
tasks=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))[0].get("tasks",[])
ok=False
for t in tasks:
    for mod in ("ansible.builtin.service","ansible.builtin.systemd","service","systemd"):
        if mod in t:
            a=t[mod]
            if a.get("name")=="nginx" and a.get("state")=="started" and a.get("enabled") is True:
                ok=True
sys.exit(0 if ok else 1)' "$PB"

# 7. 用 uri 模块对 http://localhost/ 做健康检查
check "存在 uri 健康检查任务（http://localhost/）" \
  python3 -c '
import yaml,sys
tasks=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))[0].get("tasks",[])
ok=False
for t in tasks:
    for mod in ("ansible.builtin.uri","uri"):
        if mod in t and str(t[mod].get("url","")).startswith("http://localhost/"):
            ok=True
sys.exit(0 if ok else 1)' "$PB"

# 8. 用 copy 写结果文件 /var/tmp/nginx-lab-status.json
check "存在 copy 任务写 /var/tmp/nginx-lab-status.json" \
  python3 -c '
import yaml,sys
tasks=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))[0].get("tasks",[])
ok=False
for t in tasks:
    for mod in ("ansible.builtin.copy","copy"):
        if mod in t and str(t[mod].get("dest",""))=="/var/tmp/nginx-lab-status.json":
            ok=True
sys.exit(0 if ok else 1)' "$PB"

# ---------- 部署终态检查（只读） ----------

# 9. 首页可访问且含 ansible-lab
check "curl http://localhost/ 返回 ansible-lab 页面" \
  bash -c 'curl -fsS --max-time 5 http://localhost/ | grep -q "ansible-lab"'

# 10. 结果文件存在且含 "status": "ok"
check "结果文件含 \"status\": \"ok\"" \
  bash -c 'grep -q "\"status\": \"ok\"" /var/tmp/nginx-lab-status.json'

# 11. nginx 已设为开机自启
check "systemctl is-enabled nginx 返回 enabled" \
  bash -c '[ "$(systemctl is-enabled nginx 2>/dev/null)" = "enabled" ]'

# 12. 幂等性：--check 干跑 changed=0（需要 root 且不弹密码；stdin 指向 /dev/null 防挂起）
check "--check 干跑 changed=0（系统已收敛）" \
  bash -c 'ansible-playbook --check "$1" </dev/null 2>&1 | grep -q "changed=0"' _ "$PB"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
