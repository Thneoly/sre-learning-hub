# Lab 02 · TCP 协议栈实战:TIME_WAIT 洪峰与短连接生命周期

> 难度:★★★ ｜ 考点:TCP 状态机、内核参数、conntrack(CKA-网络 / CKS-网络策略底层 / 01-linux 第 5 章) ｜ 前置:无 ｜ 预计 60~90 分钟

## 场景

昨晚 22:00 峰值,网关服务大量报 `socket: Cannot assign requested address`,
值班同学留下一张 `ss -s` 截图:`timewait 3w+`。技术负责人让你在测试 VM 上完成三件事:

1. 复现"短连接风暴 → TIME_WAIT 堆积",并量化 `tcp_tw_reuse` 的实际效果;
2. 抓一次完整的 HTTP 短连接,给出**包级别**的按序解读;
3. 用 conntrack 表确认这类流量对连接跟踪的冲击(k8s 节点上 kube-proxy/Calico 全靠它,
   表满会静默丢弃新建连接——这是 CKA/CKS 都会碰的底层逻辑)。

短连接洪峰的制造命令在 `solution.md`(ab 与 curl 脚本两种),不要提前翻看分析部分。

## 任务清单

1. 准备:安装 `apache2-utils tcpdump conntrack`,在本机 8080 端口起一个 HTTP 服务,
   记录压测前的 TIME_WAIT 基线到 `answers.txt` 的 `TW_baseline`,
   并把 `sysctl -n net.ipv4.tcp_tw_reuse` 的当前值记入 `TW_reuse_orig`(收尾要恢复它)。
2. 从 `solution.md` 复制短连接压测命令制造 TIME_WAIT 洪峰;压测期间每秒采样
   `ss -H -tan state time-wait | wc -l`,观察 `ss -s` 的 timewait 计数。
3. 把 `net.ipv4.tcp_tw_reuse` 设为 0,重跑同样的压测,记录峰值到 `TW_reuse0`;
   再设为 2 重跑,记录 `TW_reuse2`;两次的 `sysctl -w` 命令原文记入 `sysctl_cmd`。
4. 用 tcpdump 在 `lo` 上抓**单次** curl 短连接的全生命周期(提示:`-c 12` 自动停止),
   把按序包解读写入 `answers.txt` B 节,格式必须严格为
   `序号 flags=SYN|SYN,ACK|ACK|PSH,ACK|FIN,ACK  说明=一句话`,不少于 8 包。
5. 用 `conntrack -L` 找到 8080 相关条目看状态字段,用 `conntrack -S` 与
   `/proc/sys/net/nf_conntrack_count` 记录条目数与 insert_failed/drop,写入 C 节。
6. 清理:停掉压测与 HTTP 服务,把 `tcp_tw_reuse` 恢复为**实验前记录的原值**
   (现代内核默认是 2;别想当然恢复成 0),删除抓包临时文件。
7. 运行判分脚本并全部通过:

```bash
# [任意节点]
cd 01-linux/labs/02-network-stack-lab
chmod +x check.sh
./check.sh ~/drill/answers.txt
```

## 验收标准

- `answers.txt` 三节齐全:A 节有 `TW_baseline/TW_reuse0/TW_reuse2` 三个数字与两次 sysctl 命令;
  B 节至少 8 个 `flags=` 行,握手、传输、挥手顺序正确;C 节有 conntrack 命令与数值。
- 现场已清理:`net.ipv4.tcp_tw_reuse` 等于实验前记录的 `TW_reuse_orig`,无 ab/压测脚本进程,8080 不再监听。
- `check.sh` 输出 `SCORE: 10/10`。

## answers.txt 模板

```bash
# [任意节点] 保存为 ~/drill/answers.txt,边做边填
# ===== A · TIME_WAIT 观察 =====
TW_baseline:
TW_reuse_orig:
TW_reuse0:
TW_reuse2:
sysctl_cmd:
结论(一行):

# ===== B · 包序解读 =====
# 严格一行一包,格式: 序号 flags=<SYN|SYN,ACK|ACK|PSH,ACK|FIN,ACK>  说明=<一句话>
# 从第一个 SYN 写到最后一个 ACK,不少于 8 包

# ===== C · conntrack =====
conntrack_观察(命令与看到的条目数、状态):
conntrack_drops(数值或 none):
```

## 提示(卡住再看)

<details><summary>提示 1:怎么只看 TIME_WAIT 数量</summary>

`ss -tan state time-wait | wc -l`(加 `-H` 去掉表头再数更准);`ss -s` 是汇总视图。
记得 TIME_WAIT 只出现在**主动关闭方**——本实验客户端与服务端都在本机,两头都能看到。
</details>

<details><summary>提示 2:怎么抓到"恰好一条"连接</summary>

先开 `sudo tcpdump -i lo -nn 'tcp port 8080' -c 12`,再另开终端执行一次
`curl -s -o /dev/null http://127.0.0.1:8080/`。压测期间千万别开着无上限的 tcpdump。
</details>

<details><summary>提示 3:conntrack 看什么</summary>

`sudo conntrack -L -p tcp --dport 8080` 看单条条目的 state(ESTABLISHED/TIME_WAIT)
与双向五元组;`sudo conntrack -S | grep -E 'insert|drop'` 看丢没丢;
`cat /proc/sys/net/nf_conntrack_count` 与 `nf_conntrack_max` 相除就是水位。
</details>
