# Lab 01 · 批量巡检脚本 batch-inspect.sh

> 难度：★★☆ ｜ 考点：Shell 编程基本功（getopts / 函数 / 退出码），CKA/CKS 无直接考点，属运维地基 ｜ 前置：`02-programming/01-shell-fundamentals.md`、`02-programming/02-shell-ops-patterns.md` ｜ 预计 40 分钟

## 场景

你负责的 kubeadm 练习集群有若干台 Ubuntu 节点。每天早上你需要逐台 `ssh` 上去看 CPU、内存、磁盘和几个关键 systemd 服务（containerd、kubelet……），手工敲一遍既慢又容易漏。团队决定做一个批量巡检脚本：输入一份主机列表，脚本逐台采集、统一判级、输出汇总报告，任何一台异常都要能从退出码被上游 cron / CI 感知到。

你要实现的脚本名固定为 `batch-inspect.sh`，放在本 lab 目录（与 check.sh 同级）。

## 任务清单

1. **命令行接口**
   - `-f HOSTLIST`：必选，主机列表文件路径。
   - `-w KEY=VALUE`：可重复出现，`KEY` 只允许 `cpu` / `mem` / `disk`，值为非负整数百分比；默认 `cpu=80` `mem=85` `disk=90`。
   - `-h`：打印用法说明（内容需包含 `-w` 字样）到 stdout，退出码 `0`。
   - 参数缺失、`-f` 指向的文件不可读、`-w` 的 KEY 非法或值不是非负整数时：向 stderr 报错并以非 0 退出（建议 3）。

2. **主机列表格式**（check.sh 的 fixture 就长这样）
   - 每行一台主机：`host [service1,service2,...]`，服务列表可选，多个服务用逗号分隔。
   - `#` 开头的注释行和空行忽略。
   - `host` 为 `localhost` 或本机 `hostname` 时**直接在本机执行采集**（方便无 ssh 环境测试）；否则用 `ssh -o ConnectTimeout=5 -o BatchMode=yes` 连接，连不上视为该主机 FAIL。

3. **采集项**（每台主机）
   - CPU 使用率：读 `/proc/stat` 的 `cpu` 行，间隔 1 秒采样两次，按 `100*(Δtotal-Δidle)/Δtotal` 计算，输出整数百分比。
   - 内存使用率：`/proc/meminfo` 的 `MemTotal` 与 `MemAvailable`，`100*(total-available)/total`，整数百分比。
   - 磁盘使用率：`df -lP` 输出的每个本地挂载点，取所有挂载点中的**最大**使用率
     （注意是**小写 `-l`**——GNU df 没有 `-L`，写错会整条命令报错、磁盘项静默变 0）。
   - 服务状态：`systemctl is-active <service>`，记录 `active` / `inactive` / `failed` / `unknown`。

4. **输出格式**（逐字按下面的格式，check.sh 用正则判分）
   - 每台主机一行结果（数值为整数；该主机无服务时 `services=-`；FAIL 主机各数值字段为 `-`）：
     ```
     RESULT host=<host> cpu=<int> mem=<int> disk_max=<int> services=<svc:state,svc:state|-> status=<OK|WARN|FAIL>
     ```
   - 全部主机处理完后输出汇总（注意数字前后无空格）：
     ```
     SUMMARY total=<int> ok=<int> warn=<int> fail=<int>
     ```
   - RESULT / SUMMARY 之外允许有其他人类可读的明细行（建议每台主机前打印分节头和明细，便于阅读）。

5. **判级与退出码**
   - 任一阈值判断为 `>=`（CPU、内存、disk_max）或任一服务非 `active` → 该主机 `WARN`。
   - 主机不可达或采集数据不完整 → 该主机 `FAIL`。
   - 退出码：`0` = 全部 OK；`1` = 存在 WARN 且无 FAIL；`2` = 存在 FAIL；`3` = 参数错误。

6. **自测运行**（fixture 与 check.sh 一致）
   ```bash
   # [任意节点]
   cat > /tmp/hosts_ok.txt <<'EOF'
   # 正常 fixture：本机 + journald 服务
   localhost systemd-journald
   localhost
   EOF
   chmod +x batch-inspect.sh
   ./batch-inspect.sh -f /tmp/hosts_ok.txt            # 期望 exit 0，两行 RESULT status=OK
   ./batch-inspect.sh -f /tmp/hosts_ok.txt -w cpu=1 -w mem=1 -w disk=1   # 期望 exit 1，status=WARN
   ./batch-inspect.sh -h                              # 期望打印用法，exit 0
   ```

## 验收标准

- 在本目录运行 `bash check.sh`，得到 `SCORE: 8/8`。
- 三种运行（正常 / 低阈值 / 含不可达主机）的退出码分别为 0 / 1 / 2。
- 脚本无 bash 语法错误（`bash -n batch-inspect.sh` 通过），不依赖 bash 之外的额外软件包。

## 提示（卡住再看）

<details><summary>提示 1：远端采集怎么做才不被引号搞死</summary>

把采集逻辑写成一个**单引号 heredoc 生成的字符串**（`collect_sh=$(cat <<'EOS' ... EOS)`），通过 stdin 喂给 `bash -s`：本机是 `printf '%s\n' "$collect_sh" | bash -s -- "$svcs"`，远端是同一根管道换成 `ssh -o ConnectTimeout=5 -o BatchMode=yes host bash -s -- "$svcs"`。服务列表作为位置参数传进去，避免多层引号转义。
</details>

<details><summary>提示 2：阈值参数用 getopts 的嵌套 case 解析</summary>

`getopts ":f:w:h"` 里对 `-w` 的 `OPTARG` 再做一次 `case`：`cpu=*) W_CPU=${OPTARG#cpu=} ;;`。注意 optstring 第一个冒号开启"静默错误模式"，未知选项落到 `\?` 分支由你自己报错。
</details>

<details><summary>提示 3：CPU 采样与判级</summary>

`awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat` 一次拿到 (total, idle)，两次采样相减即可。判级顺序建议：先判 FAIL（不可达/数据缺失），再判各阈值与服务状态置 WARN；最后按 `fail>0 → 2`、`warn>0 → 1`、否则 `0` 退出。
</details>
