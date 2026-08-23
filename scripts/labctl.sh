#!/usr/bin/env bash
# labctl.sh —— learning-hub 练习平台 CLI（单文件，无外部依赖：bash + kubectl）
#
# 用法概览（详见 labctl --help）：
#   labctl list [模块]        列出 lab（编号/名称/难度/完成状态）
#   labctl show <lab>         查看 lab 题目 task.md
#   labctl check <lab>        运行 check.sh 判分并记入 ~/.labctl/scores.tsv
#   labctl scores [模块]      记分板（最佳成绩/尝试次数/汇总）
#   labctl solution <lab>     确认后展示 solution.md 前 80 行（防剧透）
#   labctl fault [名|random]  列出/执行故障注入脚本（restore 可恢复）
#   labctl drill              靶场抽卡：随机一条【靶场】现象 + 15 分钟限时提示
#   labctl timer <分钟>       简易倒计时
set -u

# ---------------------------------------------------------------- 基础配置 --
LABCTL_VERSION="1.0.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABCTL_HOME="${LABCTL_HOME:-$HOME/.labctl}"
SCORES_FILE="$LABCTL_HOME/scores.tsv"
SUDO_PASS="${LABCTL_SUDO_PASS:-123}"          # sudo 密码（可用环境变量覆盖）
SOLUTION_HEAD="${LABCTL_SOLUTION_HEAD:-80}"   # solution 防剧透行数
DRILL_MINUTES="${LABCTL_DRILL_MINUTES:-15}"   # 抽卡默认限时（分钟）
FAULTS_DIR="$ROOT/scripts/faults"
SCENARIOS_MD="$ROOT/SCENARIOS.md"

# ---------------------------------------------------------------- 颜色输出 --
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m';  C_B=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_MAG=$'\033[35m'; C_CYA=$'\033[36m'
else
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYA=""
fi
info()  { printf '%s\n' "${C_BLU}[i]${C_RST} $*"; }
ok()    { printf '%s\n' "${C_GRN}[✓]${C_RST} $*"; }
warn()  { printf '%s\n' "${C_YEL}[!]${C_RST} $*"; }
err()   { printf '%s\n' "${C_RED}[x]${C_RST} $*" >&2; }
die()   { err "$*"; exit 1; }

# ---------------------------------------------------------------- lab 发现 --
# lab id = 相对 ROOT 的目录路径，如 05-cka/labs/11-rbac-role-binding
all_lab_ids() {
  find "$ROOT" -type f -name task.md -path "*/labs/*" 2>/dev/null \
    | sed "s|^$ROOT/||; s|/task.md$||" | sort -u
}

# 模块目录（顶层 NN-xxx）
all_modules() { ls -d "$ROOT"/[0-9][0-9]-* 2>/dev/null | sed "s|^$ROOT/||"; }

resolve_module() { # $1=模块号|目录名|片段 → 输出模块目录名；失败返回 1
  local spec="$1" m first=""
  for m in $(all_modules); do
    [ "$m" = "$spec" ] && { echo "$m"; return 0; }
  done
  for m in $(all_modules); do
    case "$m" in
      "$spec"-*|*"-""$spec") first="$m" ;;
    esac
  done
  [ -n "$first" ] && { echo "$first"; return 0; }
  # 名称片段模糊匹配（如 cka / middleware / pca）
  for m in $(all_modules); do
    case "$m" in *"$spec"*) echo "$m"; return 0 ;; esac
  done
  return 1
}

resolve_lab() { # $1=编号|名字|路径 → 输出 lab id；0=唯一命中 2=多个 1=无
  local spec="$1" id base m n matches=()
  spec="${spec%/}"; spec="${spec#./}"
  while IFS= read -r id; do
    [ "$id" = "$spec" ] && { echo "$id"; return 0; }
  done < <(all_lab_ids)
  # 形如 05/11、05:11、05-cka 11 的写法 → 模块 + 编号
  m=""; n="$spec"
  case "$spec" in
    */*|*:*)
      m="${spec%%[/:]*}"; n="${spec##*[/:]}"
      m="$(resolve_module "$m" 2>/dev/null || true)"
      ;;
  esac
  for id in $(all_lab_ids); do
    [ -n "$m" ] && case "$id" in "$m"/*) ;; *) continue ;; esac
    base="${id##*/}"
    [ "$base" = "$n" ] && matches+=("$id")
  done
  [ "${#matches[@]}" -eq 1 ] && { echo "${matches[0]}"; return 0; }
  if [ "${#matches[@]}" -gt 1 ]; then printf '%s\n' "${matches[@]}"; return 2; fi
  # 前缀匹配（11-rbac / 11）
  for id in $(all_lab_ids); do
    [ -n "$m" ] && case "$id" in "$m"/*) ;; *) continue ;; esac
    base="${id##*/}"
    case "$base" in "$n"-*|"$n") matches+=("$id") ;; esac
  done
  if [ "${#matches[@]}" -eq 1 ]; then echo "${matches[0]}"; return 0; fi
  [ "${#matches[@]}" -gt 1 ] && { printf '%s\n' "${matches[@]}"; return 2; }
  return 1
}

suggest_labs() { # 模糊建议：整串子串 → 按 -/_ 切词再匹配；最多 6 条
  local spec="$1" id c=0 tok
  for id in $(all_lab_ids); do
    case "$id" in
      *"$spec"*) echo "$id"; c=$((c+1)); [ "$c" -ge 6 ] && return 0 ;;
    esac
  done
  [ "$c" -gt 0 ] && return 0
  local -a toks=()
  read -ra toks <<< "$(printf '%s' "$spec" | tr '_-' '  ')"
  for tok in "${toks[@]}"; do
    [ "${#tok}" -ge 3 ] || continue
    for id in $(all_lab_ids); do
      case "$id" in
        *"$tok"*) echo "$id"; c=$((c+1)); [ "$c" -ge 6 ] && break ;;
      esac
    done
    [ "$c" -gt 0 ] && return 0
  done
  [ "$c" -eq 0 ] && echo "（没有相近的 lab，先用 labctl list 浏览）"
}

# ---------------------------------------------------------------- 元数据 --
lab_task()   { echo "$ROOT/$1/task.md"; }
lab_check()  { echo "$ROOT/$1/check.sh"; }
lab_number() { local b="${1##*/}"; echo "${b%%-*}"; }
lab_title() { # task.md 首行 "# Lab NN · XXX" → XXX
  local t; t="$(head -1 "$(lab_task "$1")" 2>/dev/null)"
  t="${t#\# }"; echo "${t#Lab *· }" | sed 's/^Lab [0-9]*[ :：]*//'
}
lab_difficulty() { # 头部元数据行的 难度 字段（★★☆）
  head -6 "$(lab_task "$1")" 2>/dev/null | grep -m1 '难度' | grep -oE '★[★☆]*'
}

# ---------------------------------------------------------------- 记分 --
declare -A S_BEST=() S_TOT=() S_TRY=() S_LAST=()
load_scores() {
  [ -f "$SCORES_FILE" ] || return 0
  local dt lab sc tot
  while IFS='|' read -r dt lab sc tot; do
    case "$lab" in ""|\#*) continue ;; esac
    S_TRY[$lab]=$(( ${S_TRY[$lab]:-0} + 1 ))
    if [ -z "${S_BEST[$lab]:-}" ] || [ "${sc:-0}" -gt "${S_BEST[$lab]}" ]; then
      S_BEST[$lab]="${sc:-0}"; S_TOT[$lab]="${tot:-0}"
    fi
    S_LAST[$lab]="$dt"
  done < "$SCORES_FILE"
}
record_score() { # $1=lab $2=得分 $3=满分
  mkdir -p "$LABCTL_HOME"
  printf '%s|%s|%s|%s\n' "$(date '+%F %T')" "$1" "$2" "$3" >> "$SCORES_FILE"
}

# ---------------------------------------------------------------- 子命令 --
cmd_list() {
  local scope="" m id num title diff mark best tot tries
  [ "${1:-}" != "" ] && { scope="$(resolve_module "$1")" || die "未找到模块 '$1'（可用值见 labctl list，模块号如 05 或目录名 05-cka）"; }
  load_scores
  local -a mods=()
  if [ -n "$scope" ]; then mods=("$scope"); else mapfile -t mods < <(all_modules); fi
  local done_n=0 total_n=0
  for m in "${mods[@]}"; do
    local -a ids=()
    mapfile -t ids < <(all_lab_ids | grep "^$m/" )
    [ "${#ids[@]}" -eq 0 ] && continue
    local mdone=0
    for id in "${ids[@]}"; do
      total_n=$((total_n+1))
      if [ -n "${S_BEST[$id]:-}" ]; then
        done_n=$((done_n+1)); mdone=$((mdone+1))
      fi
    done
    printf '\n%s%s%s（已尝试 %d/%d）\n' "$C_B$C_CYA" "$m" "$C_RST" "$mdone" "${#ids[@]}"
    for id in "${ids[@]}"; do
      num="$(lab_number "$id")"; title="$(lab_title "$id")"
      diff="$(lab_difficulty "$id")"
      best="${S_BEST[$id]:-}"; tot="${S_TOT[$id]:-}"; tries="${S_TRY[$id]:-0}"
      if [ -n "$best" ] && [ "$best" = "$tot" ]; then mark="${C_GRN}✓ ${best}/${tot}${C_RST}"
      elif [ -n "$best" ]; then mark="${C_YEL}◐ ${best}/${tot}${C_RST}"
      else mark="${C_DIM}—${C_RST}"; fi
      printf '  %3s  %-6s %-14s %s\n' "$num" "$mark" "${diff:-}" "$title"
      [ "$tries" -gt 1 ] && printf '      %s(尝试 %d 次，最近 %s)%s\n' "$C_DIM" "$tries" "${S_LAST[$id]}" "$C_RST"
    done
  done
  printf '\n%s合计：%d 个 lab，已尝试 %d 个%s\n' "$C_B" "$total_n" "$done_n" "$C_RST"
  info "开始一个 lab：labctl show <编号>（如 labctl show 11），完成后 labctl check <编号>"
}

cmd_show() {
  [ "${1:-}" = "" ] && die "用法：labctl show <lab>（编号 / 名字 / 路径）"
  local ids id
  ids="$(resolve_lab "$1")"; rc=$?
  [ $rc -eq 1 ] && { err "未找到 lab '$1'，可能想找："; suggest_labs "$1" | sed 's/^/  /'; exit 1; }
  [ $rc -eq 2 ] && { err "'$1' 匹配到多个 lab，请指定其一："; echo "$ids" | sed 's/^/  /'; exit 1; }
  id="$ids"
  local t; t="$(lab_task "$id")"
  [ -f "$t" ] || die "缺少 task.md：$t"
  printf '%s%s —— 题目%s\n' "$C_B$C_MAG" "$id" "$C_RST"
  if [ -t 1 ] && [ -z "${LABCTL_NOPAGER:-}" ] && command -v less >/dev/null \
     && [ "$(wc -l < "$t")" -gt 60 ]; then
    less -R "$t"
  else
    cat "$t"
  fi
}

check_needs_root() { # check.sh 自述需要 root（用法注释 / id 判断）则返回 0
  grep -qE 'sudo[[:space:]]+(\./check\.sh|bash[[:space:]]+check\.sh)|\bid -u\b|\bEUID\b|require_root' "$1"
}

cmd_check() {
  [ "${1:-}" = "" ] && die "用法：labctl check <lab>"
  local ids id rc
  ids="$(resolve_lab "$1")"; rc=$?
  [ $rc -eq 1 ] && { err "未找到 lab '$1'，可能想找："; suggest_labs "$1" | sed 's/^/  /'; exit 1; }
  [ $rc -eq 2 ] && { err "'$1' 匹配到多个 lab，请指定其一："; echo "$ids" | sed 's/^/  /'; exit 1; }
  id="$ids"
  local ck; ck="$(lab_check "$id")"
  [ -f "$ck" ] || die "缺少 check.sh：$ck"
  load_scores
  local prev_best="${S_BEST[$id]:-}"
  local out; out="$(mktemp)"
  printf '%s%s▶ 检查 %s%s\n' "$C_B$C_CYA" "" "$id" "$C_RST"
  if check_needs_root "$ck"; then
    info "该 lab 需要 root，通过 sudo 运行（密码可用 LABCTL_SUDO_PASS 覆盖）"
    ( cd "$ROOT/$id" && echo "$SUDO_PASS" | sudo -S -p '' bash ./check.sh ) > "$out" 2>&1
  else
    ( cd "$ROOT/$id" && bash ./check.sh ) > "$out" 2>&1
  fi
  rc=$?
  # 彩色回放（PASS 绿 / FAIL 红 / SCORE 高亮）
  while IFS= read -r line; do
    case "$line" in
      PASS:*) printf '%s\n' "${C_GRN}${line}${C_RST}" ;;
      FAIL:*) printf '%s\n' "${C_RED}${line}${C_RST}" ;;
      SCORE:*) printf '%s\n' "${C_B}${C_YEL}${line}${C_RST}" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$out"
  local sc tot
  sc="$(grep -oE 'SCORE:[[:space:]]*[0-9]+/[0-9]+' "$out" | tail -1 | grep -oE '[0-9]+' | head -1)"
  tot="$(grep -oE 'SCORE:[[:space:]]*[0-9]+/[0-9]+' "$out" | tail -1 | grep -oE '[0-9]+' | tail -1)"
  rm -f "$out"
  if [ -z "$sc" ] || [ -z "$tot" ]; then
    warn "未捕获 SCORE: X/Y（脚本异常？），本次不记分"
    exit "${rc:-1}"
  fi
  record_score "$id" "$sc" "$tot"
  if [ -z "$prev_best" ]; then
    ok "得分 ${sc}/${tot}（首次记录，已写入 $SCORES_FILE）"
  elif [ "$sc" -gt "$prev_best" ]; then
    ok "得分 ${sc}/${tot} ${C_B}新纪录${C_RST}（原最佳 ${prev_best}/${tot}）"
  elif [ "$sc" -eq "$prev_best" ]; then
    info "得分 ${sc}/${tot}，持平历史最佳"
  else
    warn "得分 ${sc}/${tot}，历史最佳仍为 ${prev_best}/${tot}（多练几次！）"
  fi
  [ "$sc" = "$tot" ] && ok "满分通过 ✓  查看下一个：labctl list"
  exit "$rc"
}

cmd_scores() {
  local scope="" m
  [ "${1:-}" != "" ] && { scope="$(resolve_module "$1")" || die "未找到模块 '$1'"; }
  load_scores
  [ -f "$SCORES_FILE" ] || { info "还没有任何记分（$SCORES_FILE 不存在）。先做一次：labctl check <lab>"; return 0; }
  printf '%s%-46s %-9s %-6s %-19s%s\n' "$C_B" "LAB" "最佳" "次数" "最近" "$C_RST"
  local id full=0 try=0 sum=0 total_labs=0
  while IFS= read -r id; do
    [ -n "$scope" ] && case "$id" in "$scope"/*) ;; *) continue ;; esac
    total_labs=$((total_labs+1))
    [ -z "${S_BEST[$id]:-}" ] && continue
    try=$((try+1))
    if [ "${S_BEST[$id]}" = "${S_TOT[$id]}" ]; then full=$((full+1)); fi
    if [ "${S_TOT[$id]:-0}" -gt 0 ]; then sum=$(( sum + S_BEST[$id] * 100 / S_TOT[$id] )); fi
    printf '%-46s %-9s %-6s %-19s\n' "$id" "${S_BEST[$id]}/${S_TOT[$id]}" "${S_TRY[$id]}" "${S_LAST[$id]}"
  done < <(all_lab_ids)
  printf '\n'
  ok "完成（满分）${full}/${total_labs} 个 lab ｜ 已尝试 ${try} 个 ｜ 平均得分率 $(( try>0 ? sum/try : 0 ))%"
  info "记分文件：$SCORES_FILE（字段：日期时间|lab|得分|满分）"
}

cmd_solution() {
  [ "${1:-}" = "" ] && die "用法：labctl solution <lab>"
  local ids id rc
  ids="$(resolve_lab "$1")"; rc=$?
  [ $rc -eq 1 ] && { err "未找到 lab '$1'，可能想找："; suggest_labs "$1" | sed 's/^/  /'; exit 1; }
  [ $rc -eq 2 ] && { err "'$1' 匹配到多个 lab，请指定其一："; echo "$ids" | sed 's/^/  /'; exit 1; }
  id="$ids"
  local sol; sol="$ROOT/$id/solution.md"
  [ -f "$sol" ] || die "缺少 solution.md：$sol"
  printf '%s即将查看 %s 的答案。建议先独立完成并 labctl check，再对照复盘。%s\n' "$C_YEL" "$id" "$C_RST"
  printf '确认要看答案? [y/N] '
  local a; read -r a
  case "$a" in y|Y|yes|是) ;; *) info "已取消（保持悬念也是练习的一部分）"; return 0 ;; esac
  printf '\n%s%s（防剧透：仅前 %s 行，完整见 %s）%s\n\n' "$C_DIM" "" "$SOLUTION_HEAD" "$sol" "$C_RST"
  head -"$SOLUTION_HEAD" "$sol"
  printf '%s…… %s（后面还有 %d 行）%s\n' "$C_DIM" "" "$(( $(wc -l < "$sol") - SOLUTION_HEAD ))" "$C_RST"
}

# ---------------------------------------------------------------- faults --
fault_scripts() { ls "$FAULTS_DIR"/break-*.sh 2>/dev/null | sort; }
fault_name()   { local b; b="${1##*/}"; b="${b#break-}"; echo "${b%.sh}"; }

fault_injected() { # /tmp/fault-backup-<name> 存在 → 判定已注入
  ls -d /tmp/fault-backup-"$1"* >/dev/null 2>&1
}

cmd_fault() {
  local sub="${1:-}" name script
  case "$sub" in
    ""|list)
      printf '%s%s可用故障（scripts/faults/break-*.sh，均支持 --restore）%s\n' "$C_B$C_CYA" "" "$C_RST"
      local s nm diff desc marker
      while IFS= read -r s; do
        nm="$(fault_name "$s")"
        diff="$(sed -n 's/^# 难度：\(.*\)$/\1/p' "$s" | head -1)"
        desc="$(sed -n 's/^# 影响：\(.*\)$/\1/p' "$s" | head -1)"
        if fault_injected "$nm"; then marker="${C_RED}[已注入]${C_RST}"; else marker="${C_DIM}[未注入]${C_RST}"; fi
        printf '  %-18s %-6s %-10s %s\n' "$nm" "${diff:-}" "$marker" "${desc:-}"
      done < <(fault_scripts)
      info "注入：labctl fault <名>（3 秒倒计时后执行）｜ 恢复：labctl fault restore <名|all>"
      ;;
    random)
      local n pick
      mapfile -t all_f < <(fault_scripts)
      n="${#all_f[@]}"
      [ "$n" -eq 0 ] && die "没有找到故障脚本（$FAULTS_DIR/break-*.sh）"
      pick=$(( RANDOM % n ))
      run_fault "${all_f[$pick]}"
      ;;
    restore)
      shift
      if [ "${1:-}" = "all" ]; then
        local s
        while IFS= read -r s; do
          info "恢复 $(fault_name "$s") ……"
          ( cd "$FAULTS_DIR" && echo "$SUDO_PASS" | sudo -S -p '' bash "$s" --restore )
        done < <(fault_scripts)
        ok "全部故障已尝试恢复。验证：kubectl get nodes && kubectl get pods -A | grep -Ev 'Running|Completed'"
      else
        [ "${1:-}" = "" ] && die "用法：labctl fault restore <名|all>"
        script="$(resolve_fault "$1")" || exit 1
        ( cd "$FAULTS_DIR" && echo "$SUDO_PASS" | sudo -S -p '' bash "$script" --restore )
        ok "已执行恢复。验证：kubectl get nodes && kubectl get pods -A | grep -Ev 'Running|Completed'"
      fi
      ;;
    *)
      script="$(resolve_fault "$sub")" || exit 1
      run_fault "$script"
      ;;
  esac
}

resolve_fault() { # 名字（可省 break- 前缀/.sh 后缀）→ 脚本绝对路径
  local n="$1" s nm
  for s in $(fault_scripts); do
    nm="$(fault_name "$s")"
    case "$nm" in "$n"|"break-$n"|"break-$n.sh"|"$n.sh") echo "$s"; return 0 ;; esac
  done
  err "未找到故障 '$n'，可用值："
  fault_scripts | while IFS= read -r s; do fault_name "$s"; done | sed 's/^/  /' >&2
  return 1
}

run_fault() { # $1=脚本；倒计时 3 秒后 sudo 执行
  local s="$1" nm
  nm="$(fault_name "$s")"
  printf '%s%s⚡ 即将注入故障 break-%s（%s）%s\n' "$C_B$C_RED" "" "$nm" "$s" "$C_RST"
  printf '  恢复命令：%slabctl fault restore %s%s（或 bash %s --restore）\n' "$C_YEL" "$nm" "$C_RST" "$s"
  printf '  %s 秒后开始，Ctrl+C 取消：' 3
  local i
  for i in 3 2 1; do printf ' %s…' "$i"; sleep 1; done
  printf '\n%s\n' "----------------------------------------"
  ( cd "$FAULTS_DIR" && echo "$SUDO_PASS" | sudo -S -p '' bash "$s" )
  printf '%s\n' "----------------------------------------"
  warn "开始只看现象排障；卡住再查 scripts/faults/FIXES.md 对应章节"
  printf '  完成后恢复：%slabctl fault restore %s%s\n' "$C_YEL" "$nm" "$C_RST"
}

# ---------------------------------------------------------------- drill --
cmd_drill() {
  [ -f "$SCENARIOS_MD" ] || die "找不到 $SCENARIOS_MD"
  local -a entries=()
  mapfile -t entries < <(grep '【靶场】' "$SCENARIOS_MD" | grep '^[[:space:]]*-')
  [ "${#entries[@]}" -eq 0 ] && die "SCENARIOS.md 中没有【靶场】条目"
  local pick line
  pick=$(( RANDOM % ${#entries[@]} )); line="${entries[$pick]}"
  local phen hint ref fname
  phen="$(echo "$line" | sed -e 's/^[[:space:]]*-[[:space:]]*【靶场】\*\*现象\*\*：//' -e 's/[[:space:]]*→[[:space:]]*先查.*//')"
  hint="$(echo "$line"  | sed -n 's/.*先查：\(.*\)→ *详见.*/\1/p' | sed 's/^ *//; s/ *$//')"
  ref="$(echo "$line"   | sed -n 's/.*→ *详见：//p')"
  fname="$(echo "$ref" | grep -oE 'break-[a-z-]+' | head -1)"
  local n=$(( ${#entries[@]} )) idx=$((pick+1))
  printf '%s%s🎯 靶场抽卡（第 %d/%d 条）%s\n\n' "$C_B$C_MAG" "" "$idx" "$n" "$C_RST"
  printf '%s现象（只看现象，先别说答案）%s\n' "$C_B" ""
  printf '  %s%s%s\n\n' "$C_YEL" "$phen" "$C_RST"
  if [ -n "$fname" ]; then
    printf '注入命令：%ssudo bash scripts/faults/%s.sh%s（labctl fault %s）\n\n' "$C_CYA" "$fname" "$C_RST" "${fname#break-}"
  fi
  local start end
  start=$(date +%s); end=$(( start + DRILL_MINUTES * 60 ))
  printf '%s限时 %s 分钟%s：%s 开始 → %s 结束（epoch %d → %d）\n' "$C_B" "$DRILL_MINUTES" "$C_RST" \
    "$(date -d "@$start" '+%H:%M:%S')" "$(date -d "@$end" '+%H:%M:%S')" "$start" "$end"
  info "倒计时不阻塞；如需提醒可另开终端运行：labctl timer $DRILL_MINUTES"
  printf '\n%s流程%s：先说第一跳命令 → 定位根因 → 手工修复验证 → 对照复盘\n' "$C_DIM" ""
  printf '%s复盘（做完再看，剧透预警）%s：\n' "$C_DIM" ""
  printf '%s  先查：%s\n' "$C_DIM" "$hint${C_RST}"
  printf '%s  详见：%s%s\n' "$C_DIM" "$ref" "$C_RST"
  printf '%s  完整排障手册：scripts/faults/FIXES.md%s\n' "$C_DIM" "$C_RST"
}

# ---------------------------------------------------------------- timer --
cmd_timer() {
  local mins="${1:-}"
  [[ "$mins" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "用法：labctl timer <分钟>（如 labctl timer 15）"
  local total start end now left
  total=$(awk -v m="$mins" 'BEGIN{printf "%d", m*60}')
  [ "$total" -le 0 ] && die "分钟数必须大于 0"
  start=$(date +%s); end=$(( start + total ))
  printf '%s⏱ 倒计时 %s 分钟：%s → %s%s\n' "$C_B$C_CYA" "$mins" \
    "$(date -d "@$start" '+%H:%M:%S')" "$(date -d "@$end" '+%H:%M:%S')" "$C_RST"
  if [ ! -t 1 ]; then
    info "当前为非交互输出，不阻塞；结束时刻见上（epoch $end）"
    return 0
  fi
  while :; do
    now=$(date +%s); left=$(( end - now ))
    [ "$left" -le 0 ] && break
    printf '\r  剩余 %02d:%02d （Ctrl+C 提前结束）  ' $(( left/60 )) $(( left%60 ))
    sleep 1
  done
  printf '\r%*s\r' 40 ''
  printf '%s%s⏰ 时间到！%s（%s）\a\n' "$C_B$C_YEL" "" "$C_RST" "$(date '+%H:%M:%S')"
}

# ---------------------------------------------------------------- help --
usage() {
  cat <<EOF
${C_B}labctl${C_RST} v$LABCTL_VERSION —— learning-hub 练习平台 CLI
仓库根：$ROOT

${C_B}用法${C_RST}：labctl <子命令> [参数]

  ${C_CYA}list${C_RST} [模块号|模块目录名]   列出全部/单模块 lab（编号、名称、难度、完成状态与最佳得分）
  ${C_CYA}show${C_RST} <lab>                查看 lab 题目 task.md（交互终端自动用 less 分页）
  ${C_CYA}check${C_RST} <lab>               运行该 lab 的 check.sh（需 root 的自动 sudo），捕获 SCORE: X/Y 记分
  ${C_CYA}scores${C_RST} [模块]             记分板：每 lab 最佳成绩 / 尝试次数 / 最近时间 + 汇总
  ${C_CYA}solution${C_RST} <lab>            确认后展示 solution.md 前 $SOLUTION_HEAD 行（防剧透）
  ${C_CYA}fault${C_RST} [名|random]         列出/执行故障注入脚本；random 随机抽一个（3 秒倒计时）
  ${C_CYA}fault restore${C_RST} <名|all>    恢复指定/全部故障
  ${C_CYA}drill${C_RST}                     靶场抽卡：随机一条【靶场】现象 + ${DRILL_MINUTES} 分钟限时提示（不阻塞）
  ${C_CYA}timer${C_RST} <分钟>              简易倒计时（结束响铃）

${C_B}<lab> 的写法${C_RST}（都能模糊匹配，多个命中时会列出来让你挑）：
  11                  编号（在多个模块重号时自动提示）
  11-rbac-role-binding lab 目录名
  05/11、05:11         模块 + 编号
  05-cka/labs/11-rbac-role-binding  完整路径

${C_B}示例${C_RST}：
  labctl list 05                  # 看 05-cka 模块的 20 个 lab
  labctl show 11                  # 读题（RBAC Role 与 RoleBinding）
  labctl check 05:11              # 做完判分，写入 ~/.labctl/scores.tsv
  labctl scores                   # 记分板（完成数/总数、平均得分率）
  labctl solution 11              # 卡住了？确认后看前 $SOLUTION_HEAD 行答案
  labctl fault random             # 随机注入一个故障（先打 VM 快照更稳）
  labctl fault restore all        # 全部恢复，kubectl get nodes 验证
  labctl drill                    # 抽一条【靶场】现象，限时排障

${C_B}环境变量${C_RST}：LABCTL_SUDO_PASS（sudo 密码，默认 123）｜ LABCTL_HOME（记分目录，默认 ~/.labctl）
                  LABCTL_DRILL_MINUTES（抽卡限时，默认 15）｜ LABCTL_NOPAGER=1（show 不分页）｜ NO_COLOR
EOF
}

# ---------------------------------------------------------------- 入口 --
main() {
  local cmd="${1:-}"
  [ -z "$cmd" ] && { usage; exit 1; }
  case "$cmd" in
    -h|--help|help)    usage; exit 0 ;;
    -V|--version)      echo "labctl $LABCTL_VERSION"; exit 0 ;;
    list)              shift; cmd_list "$@" ;;
    show)              shift; cmd_show "$@" ;;
    check)             shift; cmd_check "$@" ;;
    scores)            shift; cmd_scores "$@" ;;
    solution)          shift; cmd_solution "$@" ;;
    fault)             shift; cmd_fault "$@" ;;
    drill)             cmd_drill ;;
    timer)             shift; cmd_timer "$@" ;;
    *) err "未知子命令 '$cmd'"; usage; exit 1 ;;
  esac
}

main "$@"
