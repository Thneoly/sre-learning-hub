# Lab 01 · 参考实现与讲解

> 本文给出 `batch-inspect.sh` 的完整参考实现，并逐段说明"为什么这么写"。先自己写完、跑过 check.sh 再来对照，收获最大。

## 总体设计

```
batch-inspect.sh
 ├─ 参数解析     getopts: -f / -w / -h，阈值校验
 ├─ 采集器       一段纯 bash 字符串 collect_sh（读 /proc、df、systemctl）
 │                本机:  printf ... | bash -s -- "$svcs"
 │                远端:  printf ... | ssh host bash -s -- "$svcs"
 ├─ 结果解析     awk 从采集输出提取 CPU/MEM/DISK/SVC 字段
 ├─ 判级         阈值比较 + 服务状态 → OK / WARN / FAIL
 └─ 汇总         SUMMARY 行 + 退出码 0/1/2
```

关键取舍：**采集逻辑只写一份**，本机与远端共用同一根 `bash -s` 管道。服务列表走位置参数而不是环境变量，因为 `ssh` 默认不转发环境变量；也不把服务名拼进命令字符串，避免引号转义和命令注入两个坑。

## 完整脚本

```bash
# [任意节点] 文件: batch-inspect.sh（chmod +x 后运行）
#!/usr/bin/env bash
# batch-inspect.sh - 批量主机巡检
# 用法: ./batch-inspect.sh -f hosts.txt [-w cpu=80] [-w mem=85] [-w disk=90]
# 退出码: 0=全部 OK  1=存在 WARN  2=存在 FAIL  3=参数/输入错误
set -u

W_CPU=80
W_MEM=85
W_DISK=90
HOSTLIST=""
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no)

usage() {
  cat <<'EOF'
Usage: batch-inspect.sh -f HOSTLIST [-w KEY=VALUE ...]

  -f HOSTLIST      主机列表文件，每行: "host [svc1,svc2,...]"，# 注释与空行忽略
  -w cpu=NUMBER    CPU 使用率告警阈值（百分比，默认 80）
  -w mem=NUMBER    内存使用率告警阈值（百分比，默认 85）
  -w disk=NUMBER   磁盘使用率告警阈值（百分比，默认 90）

  host 为 localhost 或本机 hostname 时直接本机执行，否则通过 ssh 连接。
  退出码: 0=全部 OK  1=存在 WARN  2=存在 FAIL  3=参数错误
EOF
}

while getopts ":f:w:h" opt; do
  case "$opt" in
    f) HOSTLIST=$OPTARG ;;
    w)
      case "$OPTARG" in
        cpu=*)  W_CPU=${OPTARG#cpu=} ;;
        mem=*)  W_MEM=${OPTARG#mem=} ;;
        disk=*) W_DISK=${OPTARG#disk=} ;;
        *)
          echo "ERROR: 非法阈值 '$OPTARG'（应为 cpu=N / mem=N / disk=N）" >&2
          usage
          exit 3
          ;;
      esac
      ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: 未知选项 -$OPTARG" >&2; usage; exit 3 ;;
    :)  echo "ERROR: 选项 -$OPTARG 缺少参数" >&2;  usage; exit 3 ;;
  esac
done

if [ -z "$HOSTLIST" ]; then
  echo "ERROR: 必须用 -f 指定主机列表文件" >&2
  usage
  exit 3
fi
if [ ! -r "$HOSTLIST" ]; then
  echo "ERROR: 无法读取主机列表文件: $HOSTLIST" >&2
  exit 3
fi
for v in "$W_CPU" "$W_MEM" "$W_DISK"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "ERROR: 阈值必须是非负整数: $v" >&2
    exit 3
  fi
done

# ---- 采集器：单引号 heredoc 保证内容原样保留，经 stdin 喂给 bash -s ----
collect_sh=$(cat <<'EOS'
set -u
svcs=${1:-}

cpu_pct() {
  set -- $(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)
  t1=$1; i1=$2
  sleep 1
  set -- $(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)
  t2=$1; i2=$2
  dt=$((t2-t1)); di=$((i2-i1))
  if [ "$dt" -le 0 ]; then echo 0; else echo $(( 100*(dt-di)/dt )); fi
}

echo "CPU $(cpu_pct)"
echo "MEM $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0) printf "%d", 100*(t-a)/t; else print 0}' /proc/meminfo)"
df -lP | awk 'NR>1 && $2+0>0 {sub(/%/,"",$5); print "DISK "$6" "$5}'
for s in $svcs; do
  st=$(systemctl is-active "$s" 2>/dev/null)
  [ -n "$st" ] || st=unknown
  echo "SVC $s $st"
done
EOS
)

run_collect() {
  # $1=host  $2=空格分隔的服务列表；返回 ssh/bash 的退出码
  local host=$1 svcs=$2
  if [ "$host" = "localhost" ] || [ "$host" = "$(hostname)" ]; then
    printf '%s\n' "$collect_sh" | bash -s -- "$svcs"
  else
    printf '%s\n' "$collect_sh" | ssh "${SSH_OPTS[@]}" "$host" bash -s -- "$svcs"
  fi
}

total=0
ok_n=0
warn_n=0
fail_n=0

while read -r host rest; do
  [ -z "$host" ] && continue
  total=$((total+1))
  svcs=${rest:-}
  svcs=${svcs//,/ }

  out=""
  if ! out=$(run_collect "$host" "$svcs" 2>/dev/null) || [ -z "$out" ]; then
    fail_n=$((fail_n+1))
    echo "---- $host ----"
    echo "  采集失败：主机不可达或采集器执行出错"
    echo "RESULT host=$host cpu=- mem=- disk_max=- services=- status=FAIL"
    continue
  fi

  cpu=$(printf '%s\n' "$out"      | awk '$1=="CPU"{print $2}')
  mem=$(printf '%s\n' "$out"      | awk '$1=="MEM"{print $2}')
  disk_max=$(printf '%s\n' "$out" | awk '$1=="DISK"{if($3+0>m)m=$3+0} END{printf "%d", m}')
  svc_str=$(printf '%s\n' "$out"  | awk '$1=="SVC"{printf "%s%s:%s",(n++?",":""),$2,$3}')
  [ -z "$svc_str" ] && svc_str="-"

  if ! [[ "$cpu" =~ ^[0-9]+$ ]] || ! [[ "$mem" =~ ^[0-9]+$ ]]; then
    fail_n=$((fail_n+1))
    echo "---- $host ----"
    echo "  采集数据不完整"
    echo "RESULT host=$host cpu=- mem=- disk_max=- services=$svc_str status=FAIL"
    continue
  fi

  st="OK"
  reason=""
  [ "$cpu" -ge "$W_CPU" ]       && { st="WARN"; reason="$reason cpu=${cpu}%>=${W_CPU}%;"; }
  [ "$mem" -ge "$W_MEM" ]       && { st="WARN"; reason="$reason mem=${mem}%>=${W_MEM}%;"; }
  [ "$disk_max" -ge "$W_DISK" ] && { st="WARN"; reason="$reason disk_max=${disk_max}%>=${W_DISK}%;"; }
  if printf '%s\n' "$svc_str" | tr ',' '\n' | awk -F: '$1!="-" && $2!="active"' | grep -q .; then
    st="WARN"
    reason="$reason svc_not_active"
  fi

  case "$st" in
    OK)   ok_n=$((ok_n+1)) ;;
    WARN) warn_n=$((warn_n+1)) ;;
  esac

  echo "---- $host ----"
  echo "  cpu=${cpu}% (阈值${W_CPU})  mem=${mem}% (阈值${W_MEM})  disk_max=${disk_max}% (阈值${W_DISK})"
  echo "  services: $svc_str"
  [ -n "$reason" ] && echo "  WARN 原因:$reason"
  echo "RESULT host=$host cpu=$cpu mem=$mem disk_max=$disk_max services=$svc_str status=$st"
done < <(grep -vE '^[[:space:]]*(#|$)' "$HOSTLIST")

echo "SUMMARY total=$total ok=$ok_n warn=$warn_n fail=$fail_n"

[ "$fail_n" -gt 0 ] && exit 2
[ "$warn_n" -gt 0 ] && exit 1
exit 0
```

## 逐段讲解

### 1. 参数解析：optstring 开头的冒号

`getopts ":f:w:h"` 中第一个 `:` 表示进入静默错误模式：未知选项不再由 getopts 自己打印报错，而是落入 `\?` 分支、坏选项字符放在 `OPTARG` 里，由我们统一输出中文错误、`usage` 和退出码 3。`-w` 的值（如 `cpu=75`）在 `OPTARG` 上再做一层 `case`，`${OPTARG#cpu=}` 剥掉前缀。**先解析后校验**：三个阈值最后统一用正则 `^[0-9]+$` 检查，把 `cpu=abc` 这类输入挡在跑采集之前。

### 2. 采集器：一份代码，两种执行方式

`collect_sh` 用**单引号 heredoc**（`<<'EOS'`）生成，内容原样保留，不做任何展开。执行时统一走 stdin：

- 本机：`printf '%s\n' "$collect_sh" | bash -s -- "$svcs"`
- 远端：`ssh ... "$host" bash -s -- "$svcs"`

服务列表作为位置参数 `$1` 传入。`ssh` 的远端命令由远端 shell 再解释一遍，把服务名拼进命令字符串会有转义和注入风险，而 `bash -s` + 位置参数天然隔离了这两层。注意 `ssh` 上多个空格分隔的参数会被远端再分词，所以本方案只支持简单词法的服务名（无空格、无特殊字符），对 systemd unit 名完全够用。

### 3. CPU 采样：/proc/stat 两次快照

`/proc/stat` 第一行 `cpu` 是各 CPU 累计的 jiffies：user nice system idle iowait irq softirq steal……。总时间取 9 列之和，"空闲"取 idle+iowait。间隔 1 秒取两次差值，`100*(Δtotal-Δidle)/Δtotal` 就是采样窗口内的使用率。要点：

- 不能只读一次——那是开机以来的平均值，毫无意义。
- bash 算术是 64 位，jiffies 数量级不会溢出。
- `dt<=0` 的保护处理极短采样窗口的除零。

这也是 node_exporter（基于 /proc/stat 的 node_cpu_seconds_total）和 `top` 的基本原理。

### 4. 内存与磁盘

- 内存：用 `MemAvailable` 而不是 `MemFree`。Modern kernel 会把内存拿去做 page cache，`MemFree` 很小是正常现象，`MemAvailable` 才是"还能给进程用"的估计值。这是 `free -h` 中 `available` 列的同源数据。
- 磁盘：`df -lP` 输出 POSIX 格式（`-P` 防止挂载点名过长时折行，这是解析 df 的标准姿势；`-l` 只看本地文件系统，注意是**小写 l**——GNU df 没有 `-L` 选项，写成大写会整条命令报错，磁盘项静默变 0），awk 里 `$2+0>0` 过滤块数为 0 的伪文件系统，`sub(/%/,"",$5)` 去掉百分号。多挂载点取最大值，因为告警逻辑只关心"最满的那块盘"。

### 5. 判级与退出码：让机器能读懂

脚本有两条消费者：人（看明细行和 RESULT）和机器（cron / CI 只看退出码）。退出码设计成单调升级——`0` 干净、`1` 有隐患、`2` 有故障、`3` 你自己调用错了。在 crontab 里配 `|| curl -X POST webhook` 就能做最朴素的告警。判 FAIL 的条件只有两个：连不上（`out` 为空或 ssh 非 0）和采集数据不完整（cpu/mem 不是数字）；服务挂了判 WARN 而不是 FAIL，因为单服务异常通常不代表主机失联。

### 6. 解析输出的 awk 技巧

采集器输出的是**自带标签的行协议**（`CPU n` / `DISK mount pct` / `SVC name state`），主循环用 `$1=="CPU"` 这类条件提取。这比按行号取第 N 列健壮得多——挂载点数量随主机变化，行序不保证。`svc_str` 的 `(n++?",":"")` 是 awk 里"逗号放前面"的经典写法，拼出 `a:active,b:inactive` 形式。

## 运行演示

```bash
# [任意节点]
cd 02-programming/labs/01-shell-inspection
chmod +x batch-inspect.sh check.sh

cat > /tmp/hosts.txt <<'EOF'
# 练习集群节点
localhost systemd-journald
localhost containerd,kubelet
EOF

./batch-inspect.sh -f /tmp/hosts.txt
echo "exit=$?"
```

预期输出（数值随机器不同）：

```
---- localhost ----
  cpu=3% (阈值80)  mem=41% (阈值85)  disk_max=37% (阈值90)
  services: systemd-journald:active
RESULT host=localhost cpu=3 mem=41 disk_max=37 services=systemd-journald:active status=OK
---- localhost ----
  cpu=2% (阈值80)  mem=41% (阈值85)  disk_max=37% (阈值90)
  services: containerd:active,kubelet:active
RESULT host=localhost cpu=2 mem=41 disk_max=37 services=containerd:active,kubelet:active status=OK
SUMMARY total=2 ok=2 warn=0 fail=0
exit=0
```

换到真实集群时，把 `localhost` 换成 `cka000001` 等可免密 ssh 的主机名即可（`BatchMode=yes` 确保没配好密钥时直接失败而不是卡在密码提示上）。

## check.sh 通过结果

```bash
# [任意节点]
bash check.sh
```

```
PASS: batch-inspect.sh 存在且 bash -n 语法检查通过
PASS: -h 输出包含 -w 的用法说明且退出码为 0
PASS: 缺少 -f 参数时以非 0 退出 (rc=3)
PASS: hosts_ok fixture 全部 OK，退出码 0
PASS: RESULT 行格式正确且 journald 为 active、status=OK
PASS: SUMMARY 行为 total=2 ok=2 warn=0 fail=0
PASS: 低阈值 (-w cpu=1 -w mem=1 -w disk=1) 触发 WARN，退出码 1，warn=2
PASS: 不可达主机判 FAIL，退出码 2，SUMMARY fail=1
----------------------------------------
SCORE: 8/8
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| ssh 远端一直卡住 | 没设 `BatchMode=yes`，等密码输入 | 加 `-o BatchMode=yes -o ConnectTimeout=5` |
| `ssh host 'bash -s -- $svcs'` 服务名带空格就碎 | 远端 shell 二次分词 | 只接受简单词法的服务名，或改用 base64 传参 |
| WARN 永远不触发 | 用 `>` 而不是 `>=` 判断，或阈值解析后没剥前缀 | `${OPTARG#cpu=}` 后统一正则校验 |
| RESULT 行 grep 不中 | SUMMARY/RESULT 多了空格或用了中文冒号 | 严格按 task.md 的格式逐字输出 |
| `df` 输出被折行 | 没加 `-P` | `df -lP` 是脚本解析 df 的唯一正确姿势（`-l` 必须小写，GNU df 无 `-L`） |
| `disk_max` 恒为 0 | `df -LP` 报 invalid option 后 DISK 行一条都没有 | 改成 `df -lP`，改完手动跑一遍采集器看 DISK 行 |
| set -e 与采集失败冲突 | ssh 失败直接退出整个脚本 | 本方案不用 `set -e`，用显式 `if ! out=$(...)` 捕获 |

## 收尾自查

<details><summary>为什么用 MemAvailable 而不是 MemFree？</summary>

MemFree 是完全空闲的物理内存；内核会尽量把回收成本低的内存拿去做 page cache，所以 MemFree 低不代表内存紧张。MemAvailable 是内核基于 watermark、可回收 slab、cache 等估算出的"可给新进程用"的量，才是容量判断依据。`free` 命令的 available 列即来自 /proc/meminfo 的同一字段。
</details>

<details><summary>如果把 sleep 1 去掉，CPU 值会变成什么？</summary>

只读一次 /proc/stat 拿不到差值，dt=0 会除零；参考实现里退化为输出 0。更隐蔽的错误做法是拿"开机以来平均值"——机器跑了 30 天后这个值几乎不动，完全失去巡检意义。采样窗口必须在采集时现场制造。
</details>

<details><summary>为什么退出码要区分 1 和 2，统一非 0 不行吗？</summary>

统一非 0 时，上游只能知道"有事"，无法决定处置动作。WARN（磁盘快满了）通常是白天处理，FAIL（主机失联）要立刻打电话。cron / CI / Ansible 都以退出码为协议，单调分级的退出码让脚本可以无脑串联进更大的自动化链路。
</details>

<details><summary>服务名如果来自用户输入，这套方案有什么注入风险？</summary>

服务列表走的是 stdin + 位置参数，主脚本不拼接命令，所以本地安全；但 ssh 场景下 `ssh host bash -s -- "$svcs"` 的参数会在远端被 shell 再分词一次，含空格或元字符的服务名会被拆散或解释。彻底的做法是把服务列表也通过 stdin/编码传输，或用 `ssh host bash -s -- "$svcs"` 之外的结构化协议（如远端固定脚本 + 参数文件）。本 lab 限定服务名为 systemd unit 名（字母数字、`-`、`.`、`@`），风险可控。
</details>
