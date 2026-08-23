#!/usr/bin/env bash
# Lab 01 · reverse-proxy-ha 判分脚本（13 项，全部为只读检查）
# 环境假设：
#   - Ubuntu VM（22.04/24.04）已安装 docker 与 curl
#   - 实验栈处于完成终态：容器 lb-nginx / lb-app1 / lb-app2 均在运行
#   - nginx 端口映射为宿主机 8088；配置文件位于 /opt/nginx-lab/nginx.conf
#   - 本脚本不创建、不修改、不删除任何容器与配置（/tmp 下的临时响应体除外）
# 使用：chmod +x check.sh && ./check.sh    （或 bash check.sh）

set -u

BASE="http://127.0.0.1:8088"
CONF="/opt/nginx-lab/nginx.conf"
PASS=0
TOTAL=0

check() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
  fi
}

# 连续 40 次请求 /，统计后端归属，验证 3:1 加权（平滑加权轮询的期望值为 30:10）
dist_weight() {
  local a1=0 a2=0 i body
  for i in $(seq 1 40); do
    body="$(curl -s --max-time 3 "$BASE/")" || return 1
    case "$body" in
      app1*) a1=$((a1 + 1)) ;;
      app2*) a2=$((a2 + 1)) ;;
      *) return 1 ;;
    esac
  done
  echo "  -> 实测分布: app1=$a1 app2=$a2 (共 40 次)" >&2
  [ "$a1" -ge 24 ] && [ "$a1" -le 36 ] \
    && [ "$a2" -ge 4 ] && [ "$a2" -le 16 ] \
    && [ "$a1" -gt "$a2" ]
}

echo "== Lab 01 reverse-proxy-ha 检查 =="

# 1-2 容器终态
check "容器 lb-nginx 处于运行状态" \
  bash -c "docker inspect -f '{{.State.Running}}' lb-nginx | grep -qx true"

check "容器 lb-app1 与 lb-app2 均处于运行状态" \
  bash -c "for c in lb-app1 lb-app2; do docker inspect -f '{{.State.Running}}' \"\$c\" | grep -qx true || exit 1; done"

# 3-6 基本路由与响应头
check "GET / 返回 HTTP 200" \
  bash -c "curl -s --max-time 3 -o /dev/null -w '%{http_code}' '$BASE/' | grep -qx 200"

check "GET / 响应体来自后端(app1/app2)" \
  bash -c "curl -s --max-time 3 '$BASE/' | grep -Eq '^app[12]\$'"

check "响应头包含 X-Upstream" \
  bash -c "curl -s --max-time 3 -D - -o /dev/null '$BASE/' | grep -qi '^X-Upstream:'"

check "X-Upstream 值为实际命中的后端地址(IP:80)" \
  bash -c "curl -s --max-time 3 -D - -o /dev/null '$BASE/' | grep -qi '^X-Upstream: .*:80'"

# 7-8 代理路径与加权轮询
check "GET /api/user 返回 200 且来自后端" \
  bash -c "curl -s --max-time 3 -w '%{http_code}' -o /tmp/lab_api_body '$BASE/api/user' | grep -qx 200 && grep -Eq '^app[12]\$' /tmp/lab_api_body"

check "加权轮询分布接近 3:1(40 次请求)" \
  dist_weight

# 9-10 location 优先级陷阱修复
check "陷阱已修复：/api/v1/data.json 由后端响应" \
  bash -c "curl -s --max-time 3 -w '%{http_code}' -o /tmp/lab_trap_body '$BASE/api/v1/data.json' | grep -qx 200 && grep -Eq '^app[12]\$' /tmp/lab_trap_body"

check "静态规则仍生效：/assets/app.js 返回 static-asset" \
  bash -c "curl -s --max-time 3 '$BASE/assets/app.js' | grep -q '^static-asset\$'"

# 11 单后端直连路径恢复
check "/report/ 指向 app1 且已恢复(200)" \
  bash -c "curl -s --max-time 3 -o /dev/null -w '%{http_code}' '$BASE/report/metrics' | grep -qx 200"

# 12-13 配置静态检查（只读 grep）
check "配置中 /api/ 已使用 ^~ 修饰符" \
  bash -c "grep -Fq 'location ^~ /api/' '$CONF'"

check "配置中保留 weight=3 / weight=1 加权定义" \
  bash -c "grep -Fq 'weight=3' '$CONF' && grep -Fq 'weight=1' '$CONF'"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  exit 0
fi
exit 1
