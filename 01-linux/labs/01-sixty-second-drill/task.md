# Lab 01 · 60 秒应急排查演练:CPU / 内存 / 磁盘

> 难度:★★☆ ｜ 考点:Linux 故障定位(CKA 故障排查基础 / PCA 的 node_exporter 指标语义) ｜ 前置:无 ｜ 预计 40~60 分钟

## 场景

你是这台 Ubuntu 服务器的值班工程师。今晚连续来了三条告警,每条只给你 60 秒:
**定位根因 → 在 `answers.txt` 留下记录 → 恢复现场**。三个场景的故障注入命令与还原命令
都放在 `solution.md`(自己注入、自己排查;或让同伴注入后不告诉你是哪一条)。

环境要求:Ubuntu 22.04/24.04,2 vCPU / 4 GB 内存起步。可以是装有 Docker 的独立 VM,
也可以是练习集群的**非 master 节点**——CPU/内存打满会拖垮 master 上的组件,不要在 master 上做。

### 场景 1 · CPU

> [P1] HighCPUUsage: `node_cpu_seconds_total{mode="idle"}` 5m 平均值 < 10%
> instance=10.0.30.11,持续 5 分钟,SSH 登录明显变卡。

### 场景 2 · 内存

> [P1] LowMemoryAvailable: `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` < 10%,
> 持续 3 分钟;业务容器间歇性被 OOM kill,重启后又涨回去。

### 场景 3 · 磁盘

> [P1] FileSystemSpaceLow: `node_filesystem_avail_bytes{mountpoint="/"}` / total < 5%;
> 应用日志开始报 `No space left on device`,cron 任务大面积失败。

三条告警对应的注入对象分别是:**CPU 打满(stress-ng)、内存泄漏(python 脚本)、磁盘写满(fallocate)**。
怎么注入见 `solution.md`,排查手段自选。

## 任务清单

1. 准备:创建 `~/drill` 工作目录,按 `solution.md` 第 0 节安装工具,创建 `answers.txt`(模板见下)。
2. 三个场景依次执行:运行 `solution.md` 中该场景的注入命令 → 开始计时 60 秒排查 → 把结论写进 `answers.txt` → 执行还原命令 → 进入下一轮。
3. 每个场景在 `answers.txt` 里必须填满 Q1~Q4:定位对象、用过的命令、根因一句话、还原命令。
4. 三轮全部结束后自查现场:无残留压测进程、泄漏脚本已删、`/` 使用率回到 90% 以下。
5. 运行判分脚本并全部通过:

```bash
# [任意节点]
cd 01-linux/labs/01-sixty-second-drill
chmod +x check.sh
./check.sh ~/drill/answers.txt
```

## 验收标准

- `answers.txt` 按模板填满三个场景,Q1 均指向注入的真实对象(stress-ng 进程 / python 泄漏进程 / 大文件路径)。
- 现场已清理:系统里查不到 stress/stress-ng、memleak.py 进程,`/var/log/diag-big.bin` 不存在。
- `check.sh` 输出 `SCORE: 10/10`。

## answers.txt 模板

```bash
# [任意节点] 保存为 ~/drill/answers.txt,每轮排查结束后填写
# ===== 场景 1 · CPU =====
Q1 进程名与 PID:
Q2 排查命令(至少两条):
Q3 根因一句话:
Q4 还原命令:

# ===== 场景 2 · 内存 =====
Q1 进程名与 PID(附 RSS 数值):
Q2 排查命令(至少两条):
Q3 根因一句话:
Q4 还原命令:

# ===== 场景 3 · 磁盘 =====
Q1 占用空间的文件路径与大小:
Q2 排查命令(至少两条):
Q3 根因一句话:
Q4 还原命令:
```

## 提示(卡住再看)

<details><summary>提示 1:场景 1 排不动 CPU 从哪来</summary>

`top` 打开后按大写 `P` 按 %CPU 排序;或一步到位 `ps -eo pid,comm,pcpu --sort=-pcpu | head`。
注意区分"瞬时高"与"持续高":再跑一次 `pidstat -u 1 3` 看是否稳定。
</details>

<details><summary>提示 2:场景 2 available 低但 top 里谁都不像凶手</summary>

按内存排:`ps -eo pid,comm,rss --sort=-rss | head`。RSS 最大且还在涨的那个就是;
用 `watch -n1 cat /proc/<PID>/status | grep VmRSS` 确认"持续增长"这个泄漏特征。
</details>

<details><summary>提示 3:场景 3 df 说满了,du 找不到大文件</summary>

`df` 看的是文件系统,`du` 看的是目录树,两者不一致通常是挂载点遮蔽或已删除但被进程持有的句柄。
本场景先做 `sudo du -xh --max-depth=1 / 2>/dev/null | sort -rh | head`,一路下钻;
`-x` 关键,它让 du 不跨文件系统。
</details>
