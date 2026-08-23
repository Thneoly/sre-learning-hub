#!/usr/bin/env bash
# Lab 02 判分脚本 —— TIME_WAIT / tcp_tw_reuse / tcpdump / conntrack
# 用法: bash check.sh [answers.txt 路径]    默认 ./answers.txt
# 建议: chmod +x check.sh && ./check.sh
# 说明: 只读检查(读 answers.txt、sysctl/pgrep/ss 查询),不修改系统状态,可独立拷贝运行。
# 环境假设:
#   - 已在本机完成实验并按 solution.md 清理;
#   - 第 9 项把 tcp_tw_reuse 与 answers.txt 中 TW_reuse_orig 记录的实验前原值比对
#     (内核 4.12+ 默认 2;先记录、后恢复,不要假定默认是 0);
#   - 8080 端口的 HTTP 服务已停止、压测进程已结束。
set -u

ANS=${1:-./answers.txt}
PASS=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; return 0; }
fail() { TOTAL=$((TOTAL+1)); echo "FAIL: $1"; return 0; }

# answers.txt 内关键字检查(文件不存在时恒为假,不报错中断)
has() { [ -f "$ANS" ] && grep -qiE -- "$1" "$ANS"; }

# 提取 B 节包序 tokens:只认严格格式 flags=SYN / SYN,ACK / ACK / PSH,ACK / FIN,ACK / RST
if [ -f "$ANS" ]; then
  TOKENS=$(grep -oE 'flags=(SYN|SYN,ACK|ACK|PSH,ACK|FIN,ACK|RST)' "$ANS" | sed 's/^flags=//')
else
  TOKENS=""
fi
N=$(printf '%s\n' "$TOKENS" | grep -c '.')

firstpos() { printf '%s\n' "$TOKENS" | grep -nx -- "$1" | head -n1 | cut -d: -f1; }
countof()  { printf '%s\n' "$TOKENS" | grep -cx -- "$1"; }

# ---- 1. answers.txt 存在且 A/B/C 三节齐全 ----
if [ -f "$ANS" ] && grep -q 'A · TIME_WAIT' "$ANS" && grep -q 'B · 包序解读' "$ANS" && grep -q 'C · conntrack' "$ANS"; then
  pass "answers.txt 存在且包含 A/B/C 三节"
else
  fail "answers.txt 存在且包含 A/B/C 三节"
fi

# ---- 2. 三组 TIME_WAIT 计数已记录为数字 ----
if has 'TW_baseline: *[0-9]+' && has 'TW_reuse0: *[0-9]+' && has 'TW_reuse2: *[0-9]+'; then
  pass "TW_baseline / TW_reuse0 / TW_reuse2 已记录数值"
else
  fail "TW_baseline / TW_reuse0 / TW_reuse2 已记录数值"
fi

# ---- 3. 记录了 tcp_tw_reuse=0 与 =2 的修改命令 ----
if has 'tcp_tw_reuse *= *0' && has 'tcp_tw_reuse *= *2'; then
  pass "记录了 tcp_tw_reuse=0 与 =2 修改命令"
else
  fail "记录了 tcp_tw_reuse=0 与 =2 修改命令"
fi

# ---- 4. 包序解读不少于 8 包 ----
if [ "$N" -ge 8 ]; then
  pass "包序解读 >= 8 包(实际 ${N} 包)"
else
  fail "包序解读 >= 8 包(实际 ${N} 包)"
fi

# ---- 5. 三次握手顺序:SYN < SYN,ACK < ACK ----
p_syn=$(firstpos 'SYN')
p_sa=$(firstpos 'SYN,ACK')
p_ack=$(firstpos 'ACK')
if [ -n "$p_syn" ] && [ -n "$p_sa" ] && [ -n "$p_ack" ] \
   && [ "$p_syn" -lt "$p_sa" ] && [ "$p_sa" -lt "$p_ack" ]; then
  pass "三次握手顺序正确(SYN -> SYN,ACK -> ACK)"
else
  fail "三次握手顺序正确(SYN -> SYN,ACK -> ACK)"
fi

# ---- 6. 数据阶段:PSH,ACK >= 2(请求与响应) ----
if [ "$(countof 'PSH,ACK')" -ge 2 ]; then
  pass "数据阶段 PSH,ACK >= 2(请求 + 响应)"
else
  fail "数据阶段 PSH,ACK >= 2(请求 + 响应)"
fi

# ---- 7. 挥手阶段:存在 FIN,ACK 且其后仍有纯 ACK ----
p_fin=$(firstpos 'FIN,ACK')
ack_after_fin=$(printf '%s\n' "$TOKENS" | grep -nx 'ACK' | awk -F: -v f="${p_fin:-0}" '$1>f{print $1; exit}')
if [ -n "$p_fin" ] && [ -n "$ack_after_fin" ]; then
  pass "四次挥手完整(存在 FIN,ACK 且其后有 ACK)"
else
  fail "四次挥手完整(存在 FIN,ACK 且其后有 ACK)"
fi

# ---- 8. C 节 conntrack 观察有实质记录(命令 + 数值) ----
csec=$(awk '/C · conntrack/{f=1} f' "$ANS" 2>/dev/null)
if printf '%s' "$csec" | grep -qi 'conntrack' && printf '%s' "$csec" | grep -q '[0-9]'; then
  pass "conntrack 观察已记录(命令 + 数值)"
else
  fail "conntrack 观察已记录(命令 + 数值)"
fi

# ---- 9. 清理:tcp_tw_reuse 已恢复为 answers.txt 里记录的实验前原值 ----
# (内核 4.12+ 默认是 2,运维也可能改成 1;"恢复"必须回到实验前的值而不是想当然的 0)
orig=$(sed -n 's/^TW_reuse_orig:[[:space:]]*//p' "$ANS" 2>/dev/null | head -n1 | tr -d '[:space:]')
cur=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)
if [ -n "$orig" ] && [ "$cur" = "$orig" ]; then
  pass "net.ipv4.tcp_tw_reuse 已恢复为实验前原值 ${cur}"
else
  fail "net.ipv4.tcp_tw_reuse 未恢复为实验前原值(记录 ${orig:-未记录},当前 ${cur:-未知})"
fi

# ---- 10. 清理:压测进程已结束且 8080 不再监听 ----
if [ -z "$(pgrep -x ab 2>/dev/null)" ] && [ -z "$(pgrep -f 'burst\.sh' 2>/dev/null)" ] \
   && ! ss -H -ltn 2>/dev/null | grep -q ':8080 '; then
  pass "现场已清理:无 ab/burst.sh,8080 未监听"
else
  fail "现场未清理:存在 ab/burst.sh 进程,或 8080 仍在监听"
fi

echo "SCORE: $PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  exit 0
else
  exit 1
fi
