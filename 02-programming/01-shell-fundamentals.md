# 01 · Shell 基础：从"能跑"到"不炸"

> 模块：02-programming ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点，但 CKA/CKS 排查与日常运维全部建立在这之上）

## 学习目标

- 能解释 quoting 的三种形式（`""` / `''` / 无引号）在变量展开与分词上的差异，并预判一条命令的实际参数
- 能操作 `[[ ]]` 完成字符串/数值/文件三类判断，并说明它与 `[ ]` 的关键区别
- 能写出带 `set -euo pipefail`、`trap` 清理的健壮脚本，而不是"能跑就行"的一次性脚本
- 能用 grep/sed/awk 完成日志筛选、字段提取、汇总统计，并把三者组合成管道

---

## 1. 变量与 quoting 陷阱

### 1.1 赋值与展开的基本规则

```bash
# [任意节点] 逐条执行观察输出
NAME=cka-node1          # 等号两边不能有空格，这是和 Python 最不一样的点
VERSION="1.29"          # 值带空格必须加引号
echo $VERSION           # 1.29
echo ${#NAME}           # 9 —— 字符串长度
echo ${NAME#cka-}       # node1 —— 删最短前缀
echo ${NAME/node/NODE}  # cka-NODE1 —— 替换
```

运维里最常用的展开惯用法：

| 写法 | 含义 | 典型用途 |
|---|---|---|
| `${VAR:-default}` | VAR 未设或为空时返回 default | `KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}` |
| `${VAR:?msg}` | VAR 未设时打印 msg 并退出 | 脚本入口强制参数 |
| `${VAR%suffix}` / `${VAR#prefix}` | 删后缀 / 删前缀 | 把 `pod.log.gz` 变 `pod.log` |
| `${VAR//old/new}` | 全局替换 | 把换行换成空格 |

### 1.2 三种 quoting 的分词差异（本节是 90% 脚本事故的来源）

```bash
# [任意节点]
MSG="hello world"
echo $MSG        # hello world —— 无引号：先展开，再按空格分词（这里 echo 有两个参数）
echo "$MSG"      # hello world —— 双引号：展开但保留为一个整体参数
echo '$MSG'      # $MSG —— 单引号：完全不展开
```

无引号的分词在遍历"带空格的值"时会炸：

```bash
# [任意节点]
PODS="nginx pod kube-proxy pod"
for p in $PODS; do echo "[$p]"; done    # 4 行：无引号被分词，空格丢失
for p in "$PODS"; do echo "[$p]"; done  # 1 行：整体是一个词
```

更致命的是 glob 展开：

```bash
# [任意节点]
FILE="*.log"
ls $FILE   # 无引号：*.log 被 shell 展开成当前目录所有 .log 文件
ls "$FILE" # 双引号：ls 收到字面量 *.log，可能报 No such file
```

结论：**展开变量一律 `"$VAR"`，只有你明确想要分词/glob 时才裸写**。数组遍历用 `"${arr[@]}"`：

```bash
# [任意节点]
NODES=("master" "worker 1" "worker 2")   # 元素里有空格
for n in "${NODES[@]}"; do echo "$n"; done # 3 行，正确
for n in ${NODES[@]};   do echo "$n"; done # 4 行，"worker 1" 被拆开
```

### 1.3 命令替换与算术

```bash
# [任意节点]
COUNT=$(kubectl get pods -A --no-headers | wc -l)   # $() 而不是反引号，可嵌套
echo $((COUNT + 1))                                 # 算术展开 $(( ))
NOW=$(date +%F_%H%M)
echo "report-$NOW.txt"
```

---

## 2. test 与 [[ ]]

### 2.1 为什么优先 `[[ ]]`

`[` 是普通命令（`/usr/bin/test`），`[[` 是 shell 关键字。区别体现在三件事：

```bash
# [任意节点]
VAR=""                       # VAR 为空
[ $VAR = "x" ]               # 报错：展开后变成 [ = x ]，参数个数变了
[ "$VAR" = "x" ]             # 正确返回 false —— 必须自己记着加引号
[[ $VAR = "x" ]]             # 正确返回 false —— [[ ]] 内部不做分词，裸写也安全

[[ $NAME == cka-* ]]         # 右侧可用 glob 模式匹配（[ ] 做不到）
[[ $NAME == "cka-node1" ]]   # 加引号后 == 变成字面量比较而非模式匹配
[[ -z $VAR && -n $NAME ]]    # && 和 || 可以直接写在条件里
```

### 2.2 运维常用的判断清单

```bash
# [任意节点]
[[ -f /etc/hosts ]]            # 是普通文件且存在
[[ -d /var/log ]]              # 是目录
[[ -e /etc/kubernetes ]]        # 存在（不分类型）
[[ -r $f && -w $f ]]           # 可读且可写
[[ $EUID -ne 0 ]]              # 数值比较：-eq -ne -lt -le -gt -ge
[[ $1 == "-h" || $1 == "--help" ]]
[[ $STR =~ ^[0-9]+$ ]]         # 正则匹配（ERE），运维校验输入全靠它
```

注意 `[[ ]]` 里字符串比较用 `==`/`!=`，数值比较用 `-eq` 族；拿字符串运算符比较数字虽然常能工作，但 `10 < 9` 会按字典序得出错误结论。

---

## 3. 流程控制

### 3.1 if / case

```bash
# [任意节点] 检查核心组件静态 Pod 是否全部 Running
#!/usr/bin/env bash
UNHEALTHY=$(kubectl get pods -n kube-system -o wide --no-headers \
  | awk '$4 != "Running" && $4 != "Completed" {print $1}' | wc -l)

if (( UNHEALTHY == 0 )); then
  echo "OK: all kube-system pods healthy"
elif (( UNHEALTHY < 3 )); then
  echo "WARN: $UNHEALTHY unhealthy pods"
else
  echo "CRIT: $UNHEALTHY unhealthy pods"
fi
```

分支多时用 `case`，比串 `elif` 可读：

```bash
# [任意节点]
#!/usr/bin/env bash
case "${1:-}" in
  start)   systemctl start kubelet ;;
  stop)    systemctl stop kubelet ;;
  status)  systemctl status kubelet --no-pager ;;
  -h|--help|'') echo "usage: $0 {start|stop|status}" ;;
  *) echo "unknown action: $1" >&2; exit 2 ;;
esac
```

### 3.2 循环的三种形态

```bash
# [任意节点]
# 形态 1：明确列表
for NODE in cka000001 cka000002 cka000003; do
  ssh "$NODE" "hostname -f"
done

# 形态 2：遍历命令输出的每一行（用 while read，不要用 for 吃整段输出）
kubectl get nodes --no-headers | while read -r NAME STATUS ROLES VERSION; do
  printf '%-20s %-12s %s\n' "$NAME" "$STATUS" "$VERSION"
done

# 形态 3：逐行处理文件，-r 防止反斜杠被转义吃掉
while read -r LINE; do
  [[ $LINE == \#* || -z $LINE ]] && continue   # 跳过注释和空行
  echo "processing: $LINE"
done < /etc/hosts
```

`for` 循环吃命令输出（`for x in $(cat file)`）会在任何空白处分词，遇到带空格的路径就错；**逐行处理一律 `while IFS= read -r`**：

```bash
# [任意节点] 处理 find 结果的标准写法
find /var/log -name '*.gz' -print0 | while IFS= read -r -d '' f; do
  echo "found: $f"
done
```

---

## 4. 函数与返回值

bash 函数有两种"返回"：退出码（0-255 的整数）和 stdout（字符串）。

```bash
# [任意节点]
#!/usr/bin/env bash
# 返回字符串：用 stdout + 命令替换
cluster_nodes() {
  kubectl get nodes --no-headers | awk '{print $1}'
}
NODE_COUNT=$(cluster_nodes | wc -l)

# 返回成败：用退出码，配合 local 防止变量泄漏
is_healthy() {
  local node=$1
  [[ $(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == "True" ]]
}
if is_healthy cka000001; then
  echo "node ready"
fi
```

要点：

- `local` 必须加，否则函数内赋值会覆盖全局变量——排查这种 bug 极其耗时
- 需要返回"数据 + 成败"时，数据走 stdout、状态走退出码，不要混用
- `return` 只能返回 0-255，想传字符串就 echo 出来用 `$()` 接

---

## 5. set -euo pipefail：让脚本"错不起"

### 5.1 三个开关分别管什么

```bash
# [任意节点]
#!/usr/bin/env bash
set -euo pipefail
# -e          任一命令退出码非 0 → 立即退出脚本
# -u          引用未定义变量 → 报错退出（配合 ${VAR:-default} 使用）
# -o pipefail 管道的退出码 = 最后一个非 0 的命令，而不是只看末尾
```

为什么默认行为危险：不加 `-e` 时，`cd /wrong/path` 失败后脚本继续跑，后续命令在错误目录里执行——经典的"rm 删错目录"事故源头。不加 `pipefail` 时，`grep ERROR huge.log | head` 里 grep 根本没跑完也显示成功。

### 5.2 需要放行的场景

```bash
# [任意节点]
set -euo pipefail

# grep 没匹配到时退出码为 1，属于正常业务，不是错误
if grep -q 'etcd' /var/log/syslog; then
  echo "etcd log found"
else
  echo "no etcd log"
fi

# 或者显式吞掉退出码
NOTFOUND=$(grep 'OOM' /var/log/kern.log || true)

# 检查命令是否存在
command -v kubectl >/dev/null || { echo "kubectl not installed" >&2; exit 1; }
```

### 5.3 一个最小健壮模板

```bash
# [任意节点] 保存为 /usr/local/bin/node-report 后 chmod +x
#!/usr/bin/env bash
set -euo pipefail

log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { log "FATAL: $*" >&2; exit 1; }

main() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  command -v kubectl >/dev/null || die "kubectl not found"
  log "collecting node info"
  kubectl get nodes -o wide
  log "done"
}

main "$@"
```

`main "$@"` 把入口收到最后，前面全是函数定义——这是可维护 shell 脚本的标准骨架。

---

## 6. 文本三剑客

### 6.1 grep：找得到

```bash
# [任意节点] 实战中最高频的形态
grep -i 'error' app.log              # -i 忽略大小写
grep -c 'error' app.log              # 只数行数
grep -n 'error' app.log              # 带行号
grep -v 'healthz' app.log            # 反选：排除健康检查噪音
grep -E 'error|fail|panic' app.log   # -E 扩展正则，多模式
grep -r 'imagePullPolicy' ./manifests/  # 递归找目录
grep -l 'image:' ./manifests/*.yaml  # 只列命中的文件名
grep -A 3 'OOM' kern.log             # 命中行 + 后 3 行（看 OOM 上下文）
grep -B 2 -A 5 'panic' kubelet.log   # 前后文，排查崩溃必用
grep -w '8080' ports.txt             # 整词匹配，避免命中 18080
grep -F '10.244.1.5/24' calico.log   # -F 按字面量，IP/点号不进正则
```

### 6.2 sed：改得动（流编辑，不改原文件，除非 -i）

```bash
# [任意节点]
sed -n '10,20p' app.log          # 只打印 10-20 行（大文件看片段）
sed -n '/ERROR/p' app.log        # 等价 grep，按模式打印
sed 's/foo/bar/' file            # 每行第一个 foo 换成 bar
sed 's/foo/bar/g' file           # 全部替换，忘 g 是最常见错误
sed -i.bak 's/8080/9090/g' app.conf   # 原地改并留 .bak 备份
sed -i '/^#/d; /^$/d' conf       # 删注释行和空行
sed 's/^/  /' file               # 每行加两个空格缩进
sed -n 's/^Name: \(.*\)$/\1/p' meta.txt   # 捕获组提取
```

改集群配置时的安全姿势——先 dry-run 再落盘：

```bash
# [任意节点]
sed 's/replicas: 1/replicas: 3/' deploy.yaml | kubectl diff -f - || true
sed -i.bak 's/replicas: 1/replicas: 3/' deploy.yaml && kubectl apply -f deploy.yaml
```

### 6.3 awk：算得出（按列思考）

awk 逐行处理，`$1`/`$2` 是按分隔符切出的列，默认分隔符是连续空白：

```bash
# [任意节点]
awk '{print $1}' access.log                    # 第 1 列（客户端 IP）
awk '{print $1, $7}' access.log                # IP + 请求路径
awk -F: '{print $1, $7}' /etc/passwd           # -F 指定冒号分隔
awk 'NR==3 {print}' file                       # 只处理第 3 行
awk 'END {print NR}' file                      # 总行数
awk '$9 >= 500 {print $7}' access.log          # 条件过滤：状态码 >= 500 的路径
awk '{sum += $10} END {print sum/NR}' body.log # 求平均——awk 里变量不用声明
```

kubectl 的天然搭档（`--no-headers` 去掉表头后正好按列取）：

```bash
# [master]
kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed" {print $1, $2, $4}'
kubectl get nodes --no-headers | awk '{status[$2]++} END {for (s in status) print s, status[s]}'
kubectl get pods -A -o wide --no-headers | awk '{print $7}' | sort | uniq -c | sort -rn
```

### 6.4 三剑客组合：一次完整的日志排查

需求：从 nginx access log 中找出昨天 5xx 最多的前 10 个 URL，以及它们共同的客户端 IP 段。

```bash
# [任意节点] 一条管道，每一段只做一件事
grep -E ' (5[0-9]{2}) ' access.log \        # 1. grep: 圈定 5xx 行
  | awk '{print $7}' \                       # 2. awk: 取第 7 列 URL
  | sort | uniq -c \                         # 3. 排序去重计数
  | sort -rn | head -10                      # 4. 按次数倒序取前 10

# 找 5xx 的来源 IP 段（/24）
grep -E ' (5[0-9]{2}) ' access.log \
  | awk '{split($1, a, "."); print a[1]"."a[2]"."a[3]".0/24"}' \
  | sort | uniq -c | sort -rn | head
```

排查心法：**先 grep 缩小范围，再 awk 提取字段，最后 sort/uniq 汇总**。任何日志分析都能拆成这三步。

---

## 实战演练

在练习集群上完成以下练习，全部只读操作。

```bash
# [master] 1. quoting 实验：预判再验证
A="a b"
set -- $A      # 无引号分词后作为位置参数
echo $#        # 输出 2
set -- "$A"
echo $#        # 输出 1

# [master] 2. 用 [[ ]] 与 awk 做一次集群体检
cat > /tmp/k8s-check.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command -v kubectl >/dev/null || { echo "no kubectl" >&2; exit 1; }

NOT_READY=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}' | wc -l)
if (( NOT_READY == 0 )); then
  echo "OK: all nodes Ready"
else
  kubectl get nodes --no-headers | awk '$2 != "Ready" {print "WARN:", $1, $2}'
fi

kubectl get pods -A --no-headers \
  | awk '$4 != "Running" && $4 != "Completed" {print "POD-ISSUE:", $1, $2, $4}'
echo "restart-count by node:"
kubectl get pods -A -o wide --no-headers | awk '{n[$7]++} END {for (k in n) print k, n[k]}'
EOF
bash /tmp/k8s-check.sh

# [master] 3. 三剑客：统计 kube-system 里每个镜像的 Pod 数
kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \
  | sort | uniq -c | sort -rn
```

验证：`bash /tmp/k8s-check.sh` 正常退出且无 `unbound variable` 报错；第 3 步输出每行一个镜像加计数。

---

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `[ $VAR = x ]` 偶发 `unary operator expected` | VAR 为空时展开成零个词 | 换 `[[ $VAR == x ]]` 或加引号 |
| for 循环处理文件名时"多出一个文件" | 文件名带空格被分词 | `find -print0` + `while IFS= read -r -d ''` |
| `[[ $1 == $PATTERN ]]` 结果诡异 | 右侧变量被当成 glob 模式 | 右侧加引号 `"$PATTERN"` 变字面量比较 |
| 脚本在交互 shell 正常、cron 里失败 | cron 环境 PATH 极简 | 脚本内用绝对路径，或开头 `PATH=/usr/sbin:/usr/bin:/sbin:/bin` |
| `sed -i` 后配置坏了没备份 | 原地修改无回滚 | `sed -i.bak`，重要配置先 `kubectl diff` |
| grep 在 `set -e` 下把脚本干掉了 | 无匹配时 grep 返回 1 | `if grep -q ...` 或 `grep ... || true` |
| `wc -l` 结果带空格导致 `[[ $n -gt 5 ]]` 报错 | 命令替换保留了前导空白 | 数值比较用 `(( $(wc -l < file) > 5 ))` 或 awk 内完成比较 |

---

## 自测

<details><summary>1. `echo $MSG` 和 `echo "$MSG"` 在 MSG="hello world" 时输出一样，为什么仍然必须用后者？</summary>

无引号时 shell 先展开 `$MSG` 再做 word splitting 和 glob 展开：值里的空格会把一个参数拆成多个、`*` 会被展开成文件列表。输出恰好一样只是 echo 的表现掩盖了参数个数差异。换成 `rm -rf $DIR/`、`scp`、`kubectl delete pod $PODS` 这类命令，拆词就是真实事故。双引号保证"一个变量永远是一个参数"。
</details>

<details><summary>2. 管道 `set -o pipefail` 前后，`false | true` 的退出码分别是什么？为什么这影响日志脚本？</summary>

不加 pipefail 时退出码是 `true` 的 0，`false` 的失败被吞掉；加 pipefail 后是非 0（返回最右边的非零退出码）。日志脚本里 `grep ERROR huge.log | head -10` 常触发 SIGPIPE 让 grep 提前死亡退出码 141，`curl ... | jq` 里 curl 网络失败而 jq 读到空输入成功返回 0——不设 pipefail 脚本会"假成功"。
</details>

<details><summary>3. `[[ $x == foo-* ]]` 和 `[[ $x == "foo-*" ]]` 结果可能不同，区别在哪？</summary>

前者右侧是 glob 模式，做模式匹配（foo- 开头即真）；后者右侧加引号后是字面量，要求 x 恰好等于字符串 `foo-*`。`==` 在 `[[ ]]` 里默认按模式匹配解释，这是它比 `[ ]` 强的地方，也是最容易踩的语义陷阱——右侧来自变量时尤其要注意是否加引号。
</details>

<details><summary>4. 为什么 `for LINE in $(cat file)` 处理不了含空格的行，而 `while IFS= read -r LINE` 可以？</summary>

`$(cat file)` 的替换结果会被 shell 按空白（空格、tab、换行）重新分词，行内空格即边界，无法区分"行分隔"和"字段分隔"。`read -r LINE` 每次精确读一行到换行符为止，`IFS=` 置空防止行首行尾空白被裁剪，`-r` 防止反斜杠转义被处理。因此逐行处理的标准写法是 `while IFS= read -r LINE; do ...; done < file`。
</details>

<details><summary>5. 要统计 access.log 里每个 URL 的平均响应时间（第 7 列 URL、第 10 列耗时 ms），纯 awk 怎么写？为什么不用 grep+循环？</summary>

`awk '{sum[$7]+=$10; cnt[$7]++} END {for (u in sum) printf "%-40s %d %.1fms\n", u, cnt[u], sum[u]/cnt[u]}' access.log`。awk 的关联数组一次扫描完成分组聚合；用 shell 循环对每个 URL 再 grep 一遍全文件是 O(N×M) 的重复 IO，且循环里调外部命令的进程创建开销在大日志下不可接受。
</details>

---

## 延伸阅读

- GNU Bash Manual – Shell Parameter Expansion：https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion
- ShellCheck（写完脚本必跑）：https://www.shellcheck.net/
- Google Shell Style Guide：https://google.github.io/styleguide/shellguide.html
- GNU Awk User's Guide：https://www.gnu.org/software/gawk/manual/
