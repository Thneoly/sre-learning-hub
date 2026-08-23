# 02 · Shell 运维模式：把命令变成工具

> 模块：02-programming ｜ 建议时长：4 小时 ｜ 关联认证：—（CKS 排查、日常批量操作的生产力底座）

## 学习目标

- 能编写多节点批量 ssh 巡检脚本，并说明循环 ssh 与 pdsh/pssh 的取舍
- 能用 `trap` 保证脚本被 Ctrl-C / kill 时也执行清理，不留锁文件和临时目录
- 能用 `xargs -P` 做受控并行，把百台机器的采集时间从串行小时级压到分钟级
- 能套用"参数校验 / 统一日志 / 幂等"三件套，把一次性脚本改造成可交出去的工具

---

## 1. 批量 ssh：循环 vs pdsh

### 1.1 串行循环：10 台以内够用

```bash
# [master] 假设 ~/.ssh/config 已配好 cka000001..003 的免密
NODES="cka000001 cka000002 cka000003"

for NODE in $NODES; do
  echo "=== $NODE ==="
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$NODE" \
    'hostname -f; uptime; df -h / | tail -1' || echo "FAILED: $NODE" >&2
done
```

三个必须加的 ssh 选项：`ConnectTimeout` 防止网络黑洞挂死整个循环；`BatchMode=yes` 禁止交互式密码提示（没配免密的机器直接失败而不是卡住）；远程命令用**单引号**整体包裹，保证 `$` 在远端而不是本地展开。

### 1.2 串行的问题与并行的两条路

100 台 × 5 秒/台 = 8 分钟起。并行方案对比：

| 方案 | 适用 | 说明 |
|---|---|---|
| `for` + `ssh ... &` 后台 | 不推荐 | 并发不可控，输出交错难收集 |
| `xargs -P N` | 已有脚本改造 | 控制并发数，配合 `sh -c` 收集输出 |
| `pdsh` / `pssh` | 高频批量操作 | 原生并发、输出带主机前缀、失败汇总 |

```bash
# [任意节点] 安装并行工具
sudo apt-get update && sudo apt-get install -y pdsh parallel-ssh

# [任意节点] pdsh：-w 主机列表，-R ssh 指定模块，输出自动带 [host] 前缀
pdsh -w cka000001,cka000002,cka000003 -R ssh 'uptime'
pdsh -w cka00000[1-3] -R ssh 'df -h / | tail -1'

# [任意节点] pssh：结果写目录，天然知道谁失败了
pssh -H cka000001 -H cka000002 -H cka000003 -i 'uptime'
pssh -h nodes.txt --par 10 --out-dir /tmp/pssh-out 'kubectl version --short 2>/dev/null || docker --version'
```

选型结论：临时跑一把用 pdsh；要留存结果、要进脚本用 `xargs -P` 或 pssh（`--out-dir` 按主机落文件，事后可审计）。

### 1.3 用 xargs 做受控并行的批量 ssh

```bash
# [任意节点] 并发 10 路，每台机器的输出各自带前缀
cat nodes.txt | xargs -P 10 -I{} sh -c '
  echo "--- {} ---"
  ssh -o ConnectTimeout=5 -o BatchMode=yes {} "hostname -f; uptime" \
    || echo "FAILED: {}" >&2
'
```

`-P 10` 是并发上限，`-I{}` 把每行主机名替换进模板。输出顺序不再确定，所以每段先打印主机名前缀再打印结果。

---

## 2. trap：脚本的"无论如何都要清理"

### 2.1 问题：脚本半路死了会留下什么

```bash
# [任意节点] 反例：Ctrl-C 之后锁文件永远留在磁盘上
LOCK=/tmp/myjob.lock
touch $LOCK
long_running_task       # 这里按 Ctrl-C，下面两行永远不执行
rm -f $LOCK
```

### 2.2 trap 的用法

```bash
# [任意节点]
#!/usr/bin/env bash
set -euo pipefail
TMPDIR_WORK=$(mktemp -d /tmp/collect.XXXXXX)
LOCK=/tmp/collect.lock

cleanup() {
  rm -rf "$TMPDIR_WORK"          # 本脚本创建的临时目录才允许删
  rm -f "$LOCK"
}
trap cleanup EXIT               # 无论正常退出、报错、Ctrl-C 都执行

# EXIT INT TERM 都挂上更稳（EXIT 在 bash 里覆盖大多数路径）
trap 'echo "interrupted" >&2; exit 130' INT TERM

exec 9>"$LOCK"                  # 以写方式打开锁文件，fd 9
flock -n 9 || { echo "another instance is running" >&2; exit 1; }

echo "working in $TMPDIR_WORK ..."
sleep 300
# 结束时无需手动 rm，EXIT trap 兜底
```

两个模式记住即可：

- `trap cleanup EXIT`——清理型，幂等操作（rm -f / umount / kubectl delete --ignore-not-found）
- `flock` + fd——防重入型，cron 里每分钟跑的脚本必须有，否则上一轮没跑完下一轮又启动

---

## 3. xargs 并行：不止 ssh

### 3.1 基本形态

```bash
# [任意节点]
# 串行压缩（慢）
find /var/log -name '*.log' -exec gzip {} \;

# 并行压缩，一次 8 个（快得多）
find /var/log -name '*.log' -print0 | xargs -0 -P 8 -n 1 gzip

# 批量删除 Evicted Pod（-r 按行替换）
kubectl get pods -A --no-headers \
  | awk '$4 == "Evicted" {print $2 " -n " $1}' \
  | xargs -r -n 3 kubectl delete pod

# 对 20 个 URL 并发探测
cat urls.txt | xargs -P 20 -n 1 curl -sS -o /dev/null -w '%{http_code} %{url_effective}\n'
```

`xargs` 关键参数：`-0` 配 `find -print0`（文件名带空格不炸）、`-P N` 并发数、`-n M` 每次传 M 个参数、`-r` 输入为空时不执行命令（否则会裸跑一次目标命令）、`-I{}` 整行模板替换。

### 3.2 收集并行结果

```bash
# [任意节点] 并发采集各节点磁盘，汇总成 CSV
#!/usr/bin/env bash
set -euo pipefail
OUT=$(mktemp /tmp/disk.XXXX.csv)
trap 'rm -f "$OUT"' EXIT

collect_one() {
  local node=$1
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$node" \
    "df -PB1 / | tail -1 | awk -v n=$node '{print n, \$2, \$3, \$4}'"
}
export -f collect_one   # 让 xargs 启动的子 shell 能看到该函数

cat nodes.txt | xargs -P 10 -I{} bash -c 'collect_one {}' >> "$OUT"
echo "node,total,used,avail"
awk '{$1=$1}1' OFS=, "$OUT"
```

---

## 4. 日志巡检脚本模板

目标：扫集群所有节点系统日志，汇总错误并给出结论。这个模板可以直接当日常巡检用。

```bash
# [任意节点] 保存为 /usr/local/bin/log-patrol，chmod +x
#!/usr/bin/env bash
# 巡检各节点系统日志：OOM、磁盘、kubelet 报错。只读，不改任何状态。
set -euo pipefail

NODES=${NODES:-"cka000001 cka000002 cka000003"}
PATTERN=${1:-'OOM|out of memory|No space left| kubelet.*error'}
SINCE=${2:-'-24h'}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

for NODE in $NODES; do
  log "scanning $NODE"
  if ! RESULT=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$NODE" \
      "journalctl --since '$SINCE' --no-pager 2>/dev/null | grep -iE '$PATTERN' | tail -20"); then
    log "WARN: $NODE unreachable or journalctl failed"
    continue
  fi
  if [[ -n $RESULT ]]; then
    echo "### $NODE"
    echo "$RESULT"
  fi
done

log "patrol finished"
```

运行 `log-patrol 'OOM|panic'` 输出各节点命中的日志片段；退出码恒为 0（巡检本身不该因单机失败而中断），异常通过 WARN 与输出内容暴露——这是巡检类脚本与执行类脚本在错误处理上的分界。

---

## 5. 告警脚本：调用 webhook

巡检发现问题后，把结论推到 IM。以 Slack/Discord 风格 webhook 和企业微信为例（钉钉机器人同理，换 URL 与 JSON 字段）。

```bash
# [任意节点] 保存为 /usr/local/bin/alert-webhook，chmod +x
#!/usr/bin/env bash
# 用法: alert-webhook <级别 info|warn|crit> <标题> <正文>
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 <level> <title> <body>" >&2; exit 2; }
LEVEL=$1; TITLE=$2; BODY=$3

# webhook 地址来自环境变量，绝不硬编码进脚本（会随代码仓库泄漏）
WEBHOOK_URL=${ALERT_WEBHOOK_URL:-}
[[ -n $WEBHOOK_URL ]] || { echo "ALERT_WEBHOOK_URL not set, skip" >&2; exit 0; }

case $LEVEL in
  crit) EMOJI=":rotating_light:" ;;
  warn) EMOJI=":warning:" ;;
  *)    EMOJI=":information_source:" ;;
esac

HOST=$(hostname -s)
PAYLOAD=$(jq -n \
  --arg text "$EMOJI *[$LEVEL]* $TITLE @ $HOST"$'\n'"$BODY" \
  '{text: $text}')

# 5s 超时 + 重试一次；告警通道挂了不能把调用方拖死
curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' \
     -d "$PAYLOAD" "$WEBHOOK_URL" \
  || curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' \
     -d "$PAYLOAD" "$WEBHOOK_URL" \
  || { echo "FATAL: webhook failed twice" >&2; exit 1; }
```

```bash
# [任意节点] 配合巡检使用
export ALERT_WEBHOOK_URL='https://hooks.example.com/services/T000/B000/xxxx'
OOM_COUNT=$(journalctl -k --since -24h --no-pager | grep -ci 'out of memory' || true)
if (( OOM_COUNT > 0 )); then
  alert-webhook warn "内核 OOM $OOM_COUNT 次" "最近 24h kernel log 出现 OOM，请检查内存压力"
fi
```

要点：URL 走环境变量；`jq -n --arg` 构造 JSON（手拼字符串遇到引号/换行必炸）；curl 必须带 `--max-time`；告警失败要有日志但不应让业务脚本崩溃——注意这里选择 `exit 1` 还是继续，取决于你是把告警当"必须送达"还是"尽力而为"。

---

## 6. 脚本工程化：参数校验 / 日志 / 幂等

一次脚本和可交接工具的差距就在这三件事。下面是完整模板（清理 etcd 备份场景）：

```bash
# [任意节点] 保存为 /usr/local/bin/etcd-backup-clean，chmod +x
#!/usr/bin/env bash
# 清理过期的 etcd 快照，只保留最近 N 份。
# 特性：参数校验、分级日志、幂等（重复执行结果一致）、锁防重入、dry-run。
set -euo pipefail

BACKUP_DIR=/var/lib/backups/etcd
KEEP=${KEEP:-5}
DRY_RUN=0

usage() {
  cat <<EOF
usage: $(basename "$0") [-n] [-k KEEP] [-d DIR]
  -n         dry-run，只打印将删除的文件
  -k KEEP    保留最近 KEEP 份（默认 5）
  -d DIR     快照目录（默认 $BACKUP_DIR）
EOF
}

log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "${LOG_TAG:-INFO}" "$*"; }
err() { LOG_TAG=ERROR log "$*" >&2; }

while getopts ":nk:d:h" opt; do
  case $opt in
    n) DRY_RUN=1 ;;
    k) KEEP=$OPTARG ;;
    d) BACKUP_DIR=$OPTARG ;;
    h) usage; exit 0 ;;
    :) err "option -$OPTARG needs a value"; usage; exit 2 ;;
    \?) err "unknown option -$OPTARG"; usage; exit 2 ;;
  esac
done

# ---- 参数校验：不合法就在碰任何文件之前失败 ----
[[ -d $BACKUP_DIR ]] || { err "dir not found: $BACKUP_DIR"; exit 1; }
[[ $KEEP =~ ^[0-9]+$ ]] && (( KEEP >= 1 )) || { err "KEEP must be >= 1"; exit 1; }

# ---- 锁：防 cron 重入 ----
exec 9>/tmp/etcd-backup-clean.lock
flock -n 9 || { err "another instance running"; exit 0; }

# ---- 幂等清理：按时间排序，删到只剩 KEEP 份；重跑无副作用 ----
mapfile -t SNAPS < <(ls -1t "$BACKUP_DIR"/snapshot-*.db 2>/dev/null || true)
TOTAL=${#SNAPS[@]}
log "found $TOTAL snapshots, keep $KEEP, dir=$BACKUP_DIR dry_run=$DRY_RUN"

if (( TOTAL <= KEEP )); then
  log "nothing to clean"
  exit 0
fi

for f in "${SNAPS[@]:KEEP}"; do
  if (( DRY_RUN )); then
    log "would delete: $f"
  else
    rm -f -- "$f"
    log "deleted: $f"
  fi
done

log "done, remaining: $(ls -1 "$BACKUP_DIR"/snapshot-*.db 2>/dev/null | wc -l)"
```

三件套拆解：

| 特性 | 实现手段 | 不做会怎样 |
|---|---|---|
| 参数校验 | `getopts` + 正则 + 前置检查，失败打印 usage 退出 2 | 错误参数深入执行到一半才炸，留下半成品状态 |
| 日志输出 | 统一 `时间 [级别] 消息`，错误进 stderr | 事后无法从 cron 邮件里还原当时发生了什么 |
| 幂等 | 删除类操作天然幂等；创建类先查后建；清理基于"保留 N 份"而非"删指定名" | cron 重跑或人工补跑造成重复删除/重复创建 |

---

## 实战演练

```bash
# [任意节点] 1. trap 实验：证明 Ctrl-C 也会清理
cat > /tmp/trap-demo.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMP=$(mktemp -d /tmp/trap-demo.XXXXXX)
trap 'rm -rf "$TMP"; echo "cleaned $TMP"' EXIT
echo "workdir: $TMP"; touch "$TMP/data"
sleep 60
EOF
chmod +x /tmp/trap-demo.sh
/tmp/trap-demo.sh &      # 后台运行
sleep 1 && kill -INT %1  # 模拟 Ctrl-C
wait; ls -d /tmp/trap-demo.* 2>/dev/null || echo "tmp cleaned: OK"

# [任意节点] 2. xargs 并行对比串行
seq 1 20 > /tmp/nums.txt
time (cat /tmp/nums.txt | xargs -P 10 -n 1 sleep 0.5)   # 约 1 秒
time (cat /tmp/nums.txt | xargs -P 1  -n 1 sleep 0.5)   # 约 10 秒

# [任意节点] 3. 跑通巡检与告警（webhook 用本地 mock）
python3 -m http.server 18080 --directory /tmp >/dev/null 2>&1 &   # 仅验证脚本自身行为
log-patrol 'OOM' || true
ALERT_WEBHOOK_URL='http://127.0.0.1:18080/hook' alert-webhook warn '演练' '测试消息'
kill %1
```

验证：步骤 1 结束后 `ls /tmp/trap-demo.*` 无输出；步骤 2 两种并发的时间差约 10 倍；步骤 3 告警脚本对 mock server 发出 POST（`python3 http.server` 会记录请求行到 stdout）。

---

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 批量 ssh 卡死在某一台 | 未设 ConnectTimeout，TCP 黑洞 | `-o ConnectTimeout=5 -o BatchMode=yes` |
| 远程命令里的变量在本地变成了空 | 双引号让 `$` 本地展开 | 远程命令整体用单引号，需传变量时 `ssh n "cmd $LOCALVAR"` 只对该变量单独引号包裹 |
| xargs 报 "argument line too long" 或删错文件 | 空格/特殊字符文件名被拆 | `find -print0` + `xargs -0` |
| `xargs` 在输入为空时仍然执行了一次目标命令 | 默认行为会裸跑 | 加 `-r`（GNU findutils） |
| cron 里脚本每分钟叠着一个跑 | 无锁，上一轮未结束 | `exec 9>lock; flock -n 9 || exit 0` |
| 脚本退出但临时文件/挂载残留 | 异常路径没有清理 | `trap cleanup EXIT`，清理函数只删自己创建的东西 |
| webhook 偶发把脚本拖挂 | curl 无超时 | `--max-time 5` + 有限次重试 + 失败降级为日志 |
| 告警 JSON 报 400 | 手拼字符串遇正文引号/换行断裂 | `jq -n --arg` 构造 payload |

---

## 自测

<details><summary>1. 为什么批量 ssh 必须加 `-o BatchMode=yes`，不加会发生什么？</summary>

不加时如果某台机器没配免密（或 key 变了），ssh 会弹出交互式密码/确认提示。交互脚本里你能看到并处理；但在 cron、CI 或 xargs 并行管道里没有 tty，ssh 或者挂死等待输入、或者反复失败，导致整批任务卡住。BatchMode 让认证不可用立即失败退出非 0，外层脚本才能捕获并继续处理其他主机。
</details>

<details><summary>2. `trap cleanup EXIT` 和 `trap cleanup EXIT INT TERM` 两种写法，后者存在的意义是什么？</summary>

bash 在收到 INT/TERM 默认会终止自己，随后 EXIT trap 也会触发，所以多数情况下前者够用。但存在边角：某些 shell 版本/场景下信号导致的状态不完整、或在 trap 里需要区分"正常结束"与"被中断"做不同处理（例如中断时要输出不同退出码、发告警）。显式挂 INT TERM 可以在信号处理里先做事再 `exit`，掌握退出路径的主动权，而不是依赖默认行为传导到 EXIT。
</details>

<details><summary>3. 并发数是不是越大越好？用 xargs -P 200 去 ssh 200 台机器有什么风险？</summary>

不是。风险包括：本机进程/fd/内存压力；ssh 并发建立的 TCP 连接与远端 sshd 负载（MaxStartups 默认限制并发未认证连接，超了直接拒绝）；目标机同时执行重任务（如同时 yum/apt、同时日志采集打满磁盘 IO）；输出交错不可读。正确做法是分批（-P 10~20），失败主机收集后重试，用有限并发换取可控性——这也是后面 Ansible 默认 fork=5 的设计哲学。
</details>

<details><summary>4. 巡检脚本为什么故意"单机失败继续跑"，而清理脚本要 `set -e` 立即失败？设计依据是什么？</summary>

依据是失败半径与信息完整性。巡检是只读的信息收集，一台不可达不影响其他台的诊断价值，提前退出反而掩盖问题（少扫的机器恰恰可能就是故障机），所以捕获失败、记 WARN、继续。清理/变更脚本写状态，失败后继续执行可能基于错误假设操作（比如 umount 失败还去 rm 挂载点下的内容），必须 fail fast 并保留现场。只读容错、变更严格，是运维脚本错误处理的分界线。
</details>

<details><summary>5. 什么是幂等？`mkdir`、`rm -f`、`kubectl apply`、`systemctl restart` 各自幂等吗？</summary>

幂等 = 同一操作执行多次与执行一次效果相同。`mkdir` 不幂等（二次报错），改 `mkdir -p` 后幂等；`rm -f` 幂等（不存在也不报错）；`kubectl apply` 幂等（声明式收敛到期望状态）；`systemctl restart` 幂等性弱——多次执行结果状态一致（running）但副作用（重启中断服务）重复发生，cron 里反复 restart 是事故。设计幂等的通用手段：先查后做、用"保留最近 N 份"这类目标态描述代替"删除指定文件"、给操作加存在性判断。
</details>

---

## 延伸阅读

- GNU Parallel tutorial（比 xargs 更强的并行工具）：https://www.gnu.org/software/parallel/parallel_tutorial.html
- flock(1) 手册：`man flock`
- pdsh GitHub：https://github.com/chaos/pdsh
- ShellCheck：https://www.shellcheck.net/
