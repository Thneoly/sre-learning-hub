# 04 · Python 运维工具箱：四个能写进简历的工具

> 模块：02-programming ｜ 建议时长：6 小时 ｜ 关联认证：PCA-自定义 exporter（第 2 节直接对应）

## 学习目标

- 能部署一个多线程节点巡检工具：并发采集、汇总 Markdown/JSON 报告
- 能用 `prometheus_client` 写 exporter，把任意系统状态变成 `/metrics` 指标
- 能实现通用告警机器人：webhook + 钉钉/企业微信适配、重试与限流
- 能解析 nginx access log 产出统计报告，并给核心函数写 pytest 单元测试

本章四个工具均可独立运行，产出物导向——写完放进 git 仓库就是简历素材。

---

## 1. 工具一：多线程巡检工具 node-inspector

需求：并发检查一批主机的存活、负载、磁盘、内存，输出 JSON + 人读报告。这是 paramiko/subprocess/argparse 的综合应用。

```python
# [任意节点] 保存为 node-inspector，chmod +x，在 ~/venvs/ops 里运行
#!/usr/bin/env python3
"""node-inspector: 并发采集主机状态，输出 JSON 与文本报告。"""
import argparse
import concurrent.futures
import json
import re
import subprocess
import sys
from datetime import datetime, timezone


def sh(cmd: list[str], timeout: int = 10) -> str:
    """本地/远程执行一条命令，返回 stdout；失败返回空串并带标记。"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def probe_ssh(host: str) -> dict:
    """单机采集：一次 ssh 拿全部数据，减少握手次数。"""
    script = (
        "hostname -f; "
        "cut -d' ' -f1 /proc/loadavg; "
        "awk '/MemTotal|MemAvailable/{print $2}' /proc/meminfo; "
        "df -PB1 / | tail -1 | awk '{print $2, $3, $5}'; "
        "systemctl is-active kubelet 2>/dev/null || echo unknown"
    )
    out = sh(["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", host, script], timeout=30)
    info = {"host": host, "ok": False}
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if len(lines) < 6:            # 6 行：fqdn/load/mem×2/df/kubelet
        return info
    total_kb, avail_kb = int(lines[2]), int(lines[3])
    disk_total, disk_used, disk_pct = lines[4].split()
    info.update(
        ok=True, fqdn=lines[0], load1=float(lines[1]),
        mem_used_pct=round(100 * (total_kb - avail_kb) / total_kb, 1),
        disk_total_gb=round(int(disk_total) / 1024**3, 1),
        disk_used_pct=int(disk_pct.rstrip("%")),
        kubelet=lines[5],
    )
    return info


def judge(r: dict, disk_warn: int, mem_warn: int) -> list[str]:
    """把采集结果翻译成告警语句：采集的终点是判断。"""
    issues = []
    if not r["ok"]:
        return [f"主机不可达或采集失败"]
    if r["disk_used_pct"] >= disk_warn:
        issues.append(f"磁盘使用率 {r['disk_used_pct']}% (阈值 {disk_warn}%)")
    if r["mem_used_pct"] >= mem_warn:
        issues.append(f"内存使用率 {r['mem_used_pct']}% (阈值 {mem_warn}%)")
    if r["load1"] > 8:
        issues.append(f"load1={r['load1']}")
    if r["kubelet"] not in ("active", "unknown"):
        issues.append(f"kubelet 状态 {r['kubelet']}")
    return issues


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("hosts", nargs="+", help="主机名或 IP 列表")
    ap.add_argument("-p", "--parallel", type=int, default=10)
    ap.add_argument("--disk-warn", type=int, default=85)
    ap.add_argument("--mem-warn", type=int, default=90)
    ap.add_argument("-o", "--output", default="inspect-report.json")
    args = ap.parse_args()

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as ex:
        futures = {ex.submit(probe_ssh, h): h for h in args.hosts}
        for fut in concurrent.futures.as_completed(futures):
            results.append(fut.result())

    findings = {}
    for r in sorted(results, key=lambda x: x["host"]):
        issues = judge(r, args.disk_warn, args.mem_warn)
        findings[r["host"]] = issues
        status = "FAIL" if issues else "OK"
        detail = "; ".join(issues) if issues else (
            f"load1={r['load1']} disk={r['disk_used_pct']}% mem={r['mem_used_pct']}%"
            if r["ok"] else "")
        print(f"[{status:>4}] {r['host']:<16} {detail}")

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "thresholds": {"disk_pct": args.disk_warn, "mem_pct": args.mem_warn},
        "hosts": results, "findings": findings,
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    bad = sum(1 for v in findings.values() if v)
    print(f"\n{len(results)} hosts checked, {bad} with issues -> {args.output}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
```

```bash
# [任意节点] 运行（退出码可直接接 cron / 告警）
~/venvs/ops/bin/python node-inspector cka000001 cka000002 cka000003 --disk-warn 80
```

要点：**一次 ssh 采全部指标**（脚本拼接在远端执行）而不是每指标连一次；`ThreadPoolExecutor` + `as_completed` 让先完成的先处理；JSON 报告给程序消费、终端摘要给人看；异常主机不中断整体（采集容错、结果标 FAIL）。

---

## 2. 工具二：简易 exporter（prometheus_client）

### 2.1 exporter 是什么

```
+-------------+  scrape /metrics   +------------------+   SQL/命令/ssh
| Prometheus  | -----------------> |  自研 exporter    | ------------->  数据源
+-------------+  (拉, 每 30s)      +------------------+                 (节点/DB/K8s)
                                        ^
                                        | Gauge / Counter 指标注册
                              prometheus_client 库自动暴露文本格式
```

写 exporter 的三步：定义指标类型 → 采集回调更新值 → 起 HTTP server。`Gauge`（可上可下的瞬时值，如磁盘百分比）、`Counter`（只增的累计值，如处理次数）。

```python
# [任意节点] 保存为 node-metrics-exporter.py，在 ~/venvs/ops 里运行
# pip install prometheus_client
#!/usr/bin/env python3
"""采集本机磁盘/内存/负载并暴露为 Prometheus 指标。"""
import os
import time
from pathlib import Path

from prometheus_client import Gauge, start_http_server

DISK_USED_PCT = Gauge("node_disk_used_percent", "root fs used percent", ["mountpoint"])
MEM_USED_PCT = Gauge("node_mem_used_percent", "memory used percent")
LOAD1 = Gauge("node_load1", "1min load average")
SCRAPES = Gauge("node_collector_last_success_unixtime", "last successful collect ts")


def collect() -> None:
    total_kb = avail_kb = 0
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            total_kb = int(line.split()[1])
        elif line.startswith("MemAvailable:"):
            avail_kb = int(line.split()[1])
    MEM_USED_PCT.set(round(100 * (total_kb - avail_kb) / total_kb, 2))

    stat = Path("/proc/loadavg").read_text().split()
    LOAD1.set(float(stat[0]))

    # 用 os.statvfs 拿根分区使用率（比解析 df 输出更干净）
    st = os.statvfs("/")
    used = st.f_blocks - st.f_bfree
    DISK_USED_PCT.labels(mountpoint="/").set(round(100 * used / st.f_blocks, 2))

    SCRAPES.set(time.time())


if __name__ == "__main__":
    start_http_server(9101)          # 端口避开 node_exporter 的 9100
    while True:
        collect()
        time.sleep(15)
```

```bash
# [任意节点] 启动并自测
~/venvs/ops/bin/python node-metrics-exporter.py &
sleep 2 && curl -s http://127.0.0.1:9101/metrics | grep '^node_'
# HELP node_disk_used_percent root fs used percent
# node_disk_used_percent{mountpoint="/"} 23.45
# node_load1 0.24
# node_mem_used_percent 41.12
```

```yaml
# [master] 让练习集群里的 Prometheus 抓它（静态抓取，job 名自定义）
# Prometheus Operator 环境用 additionalScrapeConfigs 或 ServiceMonitor，以官方文档为准
scrape_configs:
  - job_name: 'node-custom'
    static_configs:
      - targets: ['cka000001:9101']
```

验证 PromQL：`node_disk_used_percent > 80` 能出结果即闭环完成。写进简历的表述：「基于 prometheus_client 开发自定义 node exporter，覆盖磁盘/内存/负载指标，接入 Prometheus 告警链路」。

---

## 3. 工具三：告警机器人

支持 Slack 风格 webhook 与钉钉/企业微信两类后端，统一 `notify()` 接口，带重试与简单限流。

```python
# [任意节点] 保存为 alerter.py
#!/usr/bin/env python3
"""alerter: 统一告警出口。支持 slack 兼容 webhook / 钉钉 / 企业微信。"""
import hashlib
import json
import os
import time

import requests


class Alerter:
    def __init__(self, backend: str = "slack"):
        self.backend = backend

    def _payload(self, level: str, title: str, body: str) -> dict:
        text = f"[{level}] {title}\n{body}"
        if self.backend == "dingtalk":
            return {"msgtype": "markdown",
                    "markdown": {"title": title,
                                 "text": f"### [{level}] {title}\n\n{body}"}}
        if self.backend == "wecom":   # 企业微信机器人
            return {"msgtype": "markdown",
                    "markdown": {"content": f"**[{level}] {title}**\n{body}"}}
        return {"text": text}          # slack/discord 兼容

    def _endpoint(self) -> str:
        env = {"slack": "ALERT_WEBHOOK_URL", "dingtalk": "DINGTALK_WEBHOOK",
               "wecom": "WECOM_WEBHOOK"}
        url = os.environ.get(env[self.backend], "")
        if not url:
            raise RuntimeError(f"env {env[self.backend]} not set")
        return url

    def notify(self, level: str, title: str, body: str,
               retries: int = 2, dedup_window: int = 300) -> bool:
        """dedup: 同一 (level,title,body) 在窗口内只发一次——告警风暴的阀门。"""
        fp = hashlib.md5(f"{level}{title}{body}".encode()).hexdigest()
        state = DedupState()            # 见下方，基于 /tmp 的极简去重
        if state.recent(fp, dedup_window):
            return True                 # 已发过，静默
        payload = self._payload(level, title, body)
        for attempt in range(retries + 1):
            try:
                r = requests.post(self._endpoint(), json=payload, timeout=5)
                if r.status_code == 200:
                    state.mark(fp)
                    return True
            except requests.RequestException:
                pass
            time.sleep(1 + attempt)     # 退避 1s, 2s
        return False


class DedupState:
    """用 /tmp 下的小文件记录指纹与时间戳，无外部依赖。"""
    DIR = "/tmp/alerter-dedup"

    def __init__(self):
        os.makedirs(self.DIR, exist_ok=True)

    def _f(self, fp: str) -> str:
        return os.path.join(self.DIR, fp)

    def recent(self, fp: str, window: int) -> bool:
        try:
            age = time.time() - os.path.getmtime(self._f(fp))
            return age < window
        except OSError:
            return False

    def mark(self, fp: str):
        with open(self._f(fp), "w") as f:
            f.write(str(time.time()))


if __name__ == "__main__":
    import sys
    backend, level, title, body = sys.argv[1:5]
    ok = Alerter(backend).notify(level, title, body)
    sys.exit(0 if ok else 1)
```

```bash
# [任意节点] 使用（钉钉机器人需在群里开启"自定义机器人"并复制 webhook）
export DINGTALK_WEBHOOK='https://oapi.dingtalk.com/robot/send?access_token=xxxx'
~/venvs/ops/bin/python alerter.py dingtalk warn '磁盘告警' 'cka000001 根分区 91%'
echo $?    # 0 = 送达；1 = 重试后仍失败
```

设计要点：后端差异收敛在 `_payload`/`_endpoint`，新增飞书只加一个分支；**去重窗口**是告警系统的第一道阀门（同文案 5 分钟内不重发）；重试带退避；webhook 一律环境变量注入。与第 2 章 shell 告警相比，Python 版多了去重、多后端与结构化配置。

---

## 4. 工具四：access log 分析脚本

```python
# [任意节点] 保存为 logstats.py，chmod +x
#!/usr/bin/env python3
"""logstats: 解析 nginx combined 格式 access log，产出统计报告。

combined 格式:
  $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent
"""
import argparse
import re
import sys
from collections import Counter

LOG_RE = re.compile(
    r'^(?P<ip>\S+) \S+ \S+ \[(?P<time>[^\]]+)\] '
    r'"(?P<method>\S+) (?P<path>\S+)[^"]*" '
    r'(?P<status>\d{3}) (?P<bytes>\d+)'
)


def parse_line(line: str) -> dict | None:
    m = LOG_RE.match(line)
    return m.groupdict() if m else None


def analyze(path: str, top: int = 10) -> dict:
    stats = {"total": 0, "bad": 0, "status": Counter(), "path": Counter(),
             "path_5xx": Counter(), "traffic": 0}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            rec = parse_line(line)
            if rec is None:
                stats["bad"] += 1
                continue
            stats["total"] += 1
            stats["status"][rec["status"]] += 1
            stats["path"][rec["path"]] += 1
            stats["traffic"] += int(rec["bytes"])
            if rec["status"].startswith("5"):
                stats["path_5xx"][rec["path"]] += 1
    return stats


def render(s: dict, top: int) -> str:
    out = [f"total={s['total']} unparsed={s['bad']} "
           f"traffic={s['traffic']/1024/1024:.1f}MB"]
    out.append("\nstatus:")
    for code, n in s["status"].most_common():
        out.append(f"  {code}: {n}")
    out.append("\ntop paths:")
    for p, n in s["path"].most_common(top):
        out.append(f"  {n:>7}  {p}")
    if s["path_5xx"]:
        out.append("\n5xx hotspots:")
        for p, n in s["path_5xx"].most_common(top):
            out.append(f"  {n:>7}  {p}")
    return "\n".join(out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("logfile")
    ap.add_argument("-t", "--top", type=int, default=10)
    args = ap.parse_args()
    print(render(analyze(args.logfile, args.top), args.top))
```

```bash
# [任意节点] 用 awk（第 1 章）生成测试日志再喂给脚本
for i in $(seq 1 500); do
  code=$(( RANDOM % 10 == 0 ? 500 : 200 ))
  echo "10.0.0.$(( RANDOM % 5 )) - - [22/Aug/2026:10:0$i +0000] \"GET /api/v$i HTTP/1.1\" $code $(( RANDOM * 100 ))"
done > /tmp/access.log
~/venvs/ops/bin/python logstats.py /tmp/access.log -t 5
```

对比第 1 章的 grep/awk 管道：shell 适合一次性探查，Python 版本的优势是**可测试、可扩展、可复用**（加一个"按小时分布"只需加一个 Counter）。解析与渲染分离（`parse_line`/`analyze`/`render`）正是为了让第 5 节能直接测解析函数。

---

## 5. pytest：给脚本写测试的意识

运维脚本要不要测试？规则：**纯函数（解析、判断、格式化）必须测，IO（ssh、API）不硬测**。把逻辑从 IO 里剥离出来，是可测试性的全部秘密。

```python
# [任意节点] 保存为 test_logstats.py，与 logstats.py 同目录
"""只测纯函数：解析正确性、脏行容错、统计正确性。"""
from logstats import parse_line, analyze


def test_parse_standard_line():
    line = ('10.0.0.1 - - [22/Aug/2026:10:00:00 +0000] '
            '"GET /api/v1 HTTP/1.1" 200 512')
    rec = parse_line(line)
    assert rec["ip"] == "10.0.0.1"
    assert rec["method"] == "GET"
    assert rec["path"] == "/api/v1"
    assert rec["status"] == "200"


def test_parse_garbage_returns_none():
    assert parse_line("not a log line at all") is None
    assert parse_line("") is None


def test_analyze_counts(tmp_path):
    log = tmp_path / "a.log"
    log.write_text(
        '10.0.0.1 - - [22/Aug/2026:10:00:00 +0000] "GET /a HTTP/1.1" 200 100\n'
        '10.0.0.2 - - [22/Aug/2026:10:00:01 +0000] "GET /a HTTP/1.1" 500 100\n'
        'garbage line\n'
    )
    s = analyze(str(log))
    assert s["total"] == 2
    assert s["bad"] == 1
    assert s["path_5xx"]["/a"] == 1
    assert s["traffic"] == 200
```

```bash
# [任意节点] 在 ~/venvs/ops 里
pip install pytest && pytest test_logstats.py -v
# test_parse_standard_line PASSED
# test_parse_garbage_returns_none PASSED
# test_analyze_counts PASSED
```

pytest 最小集就够用：函数名 `test_` 开头即测试；`assert` 即断言；`tmp_path` fixture 提供临时目录（自动清理，等价 shell 的 trap+mktemp）；先写脏样例再写正常样例——**解析器的健壮性是被脏数据逼出来的**。改代码后跑一遍测试，就是运维工具的回归保障。

---

## 实战演练

```bash
# [任意节点] 1. 巡检：对本机与远端各跑一次
~/venvs/ops/bin/python node-inspector $(hostname) cka000001 --disk-warn 10
cat inspect-report.json | python3 -m json.tool | head -20

# [任意节点] 2. exporter 全链路
~/venvs/ops/bin/python node-metrics-exporter.py &
sleep 2
curl -s http://127.0.0.1:9101/metrics | grep -E '^node_(disk|load)'
kill %1

# [任意节点] 3. 告警机器人去重验证（连续两次，第二次应静默）
export ALERT_WEBHOOK_URL='https://httpbin.org/post'
~/venvs/ops/bin/python - <<'EOF'
from alerter import Alerter
a = Alerter("slack")
print("first :", a.notify("warn", "演练", "dedup test"))
print("second:", a.notify("warn", "演练", "dedup test"))  # 窗口内直接 True 且不发包
EOF
rm -rf /tmp/alerter-dedup   # 清理指纹

# [任意节点] 4. 测试驱动改代码：把 LOG_RE 的 method 分组改坏，看测试如何报警
pytest test_logstats.py -v   # 先全绿；改坏后 re-run 应见 FAILED
```

验证：步骤 1 生成 `inspect-report.json` 且退出码反映异常主机数；步骤 2 curl 出 `node_` 开头指标；步骤 3 第二次调用不产生新请求（httpbin 侧只收到一次）；步骤 4 体会"测试红了=改坏了"。

---

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| exporter 指标 Prometheus 抓不到 | 防火墙/绑定 127.0.0.1/端口冲突 | 监听 0.0.0.0、端口避开 9100、`curl :port/metrics` 本机先通 |
| 指标名带非法字符或单位混乱 | Prometheus 命名规范（snake_case、单位后缀） | `_bytes`/`_seconds`/`_percent` 后缀，名前缀统一（如 `node_`） |
| labels 里放了高基数值（user_id/path 全量） | 每个唯一 label 组合一条时间序列，Prometheus 内存爆炸 | label 只放有限枚举（mountpoint、device），路径类放日志不放指标 |
| 多线程采集偶发结果错乱 | 共享 dict 无锁并发写 | 每线程只写自己的局部 dict，主线程 `as_completed` 收集后再汇总 |
| 钉钉返回 errcode 310000 | 关键词/加签校验失败 | 机器人安全设置匹配关键词（如"告警"）或按官方文档配加签 secret |
| 告警风暴刷屏 | 无去重无静默 | 指纹+时间窗去重（本章），进阶用 Alertmanager grouping |
| 正则解析线上日志命中率低 | 日志格式与 regex 不符（引号内含转义引号等） | 先拿真实样本若干条跑通再上量，`bad` 计数保留监控解析失败率 |
| pytest 找不到被测模块 | 运行目录/`sys.path` 问题 | 测试文件与被测文件同目录，从该目录执行 `pytest` |

---

## 自测

<details><summary>1. 为什么"一次 ssh 采全部指标"比"每个指标一次 ssh"快得多？差距主要在哪？</summary>

每次 ssh 都要完整走 TCP 握手 + 密钥交换 + 认证 + 通道建立，耗时通常数百毫秒，而远端命令本身只要几毫秒。N 个指标 × M 台主机时，串行连接开销是 N×M 次握手；合并成一条远端脚本则只有 M 次。这是把"网络往返次数"当第一优化目标思维的直接体现——与数据库"避免 N+1 查询"同源。
</details>

<details><summary>2. Gauge 和 Counter 的区别是什么？把"磁盘使用率"做成 Counter 会怎样？</summary>

Counter 只增不减（重启归零），Prometheus 用 `rate()`/`increase()` 求其变化速率；Gauge 可升可降，表达瞬时状态。磁盘使用率上下波动，做成 Counter 后 rate 计算毫无意义，且下降时会被当作"重启归零"产生虚假增量；正确做法是 Gauge，告警直接 `node_disk_used_percent > 85`。同理：请求数/错误数用 Counter，队列长度/连接数/温度用 Gauge。
</details>

<details><summary>3. exporter 里 label 使用不当如何拖垮 Prometheus？举一个具体反例。</summary>

label 每个唯一取值组合都会生成独立时间序列。反例：`http_requests_total{path=$full_path}`，带参数的 URL 几乎每条请求都是新 path，一天就能造出百万序列，Prometheus 内存与查询都崩。正确姿势：低基数枚举（method、status、mountpoint）进 label，高基数信息（完整 path、user、trace id）留在日志系统里查。指标维度设计永远先问"这个 label 最多有多少种取值"。
</details>

<details><summary>4. 告警去重为什么用 (level, title, body) 的指纹，而不用 title？去重窗口设 300 秒的取舍是什么？</summary>

只按 title 去重会把"磁盘告警 cka000001 91%"和"磁盘告警 cka000002 93%"合并成一条，丢失第二台机器的故障信号；指纹含 body 才能区分"同源重复"与"不同故障"。窗口 300 秒是及时性与噪音的平衡：太短（30s）风暴挡不住，太长（1h）期间真的恢复又复发会被吞掉。生产系统的完整解法是分级窗口 + Alertmanager 的 group_wait/repeat_interval，本工具是它的极简版。
</details>

<details><summary>5. 为什么"解析函数不碰文件、分析函数接收路径、渲染函数只吃 dict"这种拆分让测试变容易？</summary>

拆分后各函数依赖单一：`parse_line(str)->dict` 是纯函数，测试只需构造字符串，不需要任何文件或网络；`analyze` 接收路径，用 pytest 的 `tmp_path` 造临时日志即可测；`render` 只依赖 dict，断言输出字符串。如果三者糊在一个 `main()` 里，测试就得准备真实日志文件、捕获 stdout、模拟 argv。可测试性设计原则：把"计算"从"IO"里拎出来——这也是第 3 章"采集与判断分离"的延续。
</details>

---

## 延伸阅读

- prometheus_client（Python）：https://github.com/prometheus/client_python
- Prometheus 指标与标签命名规范：https://prometheus.io/docs/practices/naming/
- Metrics 指标类型说明：https://prometheus.io/docs/concepts/metric_types/
- pytest 快速入门：https://docs.pytest.org/en/stable/getting-started/
- 钉钉自定义机器人接入：https://open.dingtalk.com/document/robots/custom-robot-access
