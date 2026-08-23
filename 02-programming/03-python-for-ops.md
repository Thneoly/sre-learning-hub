# 03 · Python 运维基础：为写工具而学

> 模块：02-programming ｜ 建议时长：5 小时 ｜ 关联认证：—（是第 4 章 exporter/巡检工具的地基）

## 学习目标

- 能读懂并编写面向运维的 Python：数据结构、`with`、异常处理、f-string，不追求语言学家式的全面
- 能用 `pathlib`/`shutil` 完成文件与路径处理，用 `subprocess` 安全地调用系统命令
- 能用 `requests` 调 REST API（含 kube-apiserver），用 `paramiko` 做批量 ssh
- 能用 `argparse` 写出 `--help` 可读、参数可校验的标准命令行工具，并用 venv 管好依赖

---

## 1. 语法速览：只学运维用得到的 20%

### 1.1 数据结构与控制流（对照 shell 的心智差异）

```python
# [任意节点] python3 交互式逐段执行
# 列表 = 有序可变，对应 shell 数组
nodes = ["cka000001", "cka000002", "cka000003"]
nodes.append("cka000004")
first, *rest = nodes                 # 解包：first 拿第一个，rest 拿剩下的

# 字典 = 运维最常用的结构：一行 JSON / 一个资源对象就是 dict
pod = {"name": "coredns", "ns": "kube-system", "restarts": 3}
print(pod["name"], pod.get("owner", "unknown"))  # .get 不存在时给默认值而非 KeyError

# 集合 = 去重与差集：对比"期望主机列表"和"实际在线列表"
expected = {"cka000001", "cka000002", "cka000003"}
actual   = {"cka000001", "cka000002"}
print(expected - actual)             # {'cka000003'} —— 掉线的机器

# 推导式：shell 里 for+awk 的活儿一行干完
lengths = {n: len(n) for n in nodes}
warn_pods = [p for p in [pod] if p["restarts"] > 2]

# for/else：else 在循环未被 break 时执行，"找没找到"分支很干净
for n in nodes:
    if n.startswith("worker"):
        print("found worker:", n)
        break
else:
    print("no worker found")
```

### 1.2 函数、异常与 with

```python
# [任意节点]
def fetch_nodes(api: str, timeout: float = 5.0) -> dict:
    """返回节点字典；网络错误向上抛，由调用方决定怎么处理。"""
    import requests
    resp = requests.get(api, timeout=timeout, verify=False)
    resp.raise_for_status()          # 4xx/5xx 转 raise_for_status
    return resp.json()

# 异常：捕获你处理的，其余放行。裸 except 是排查时的黑洞
try:
    data = fetch_nodes("https://127.0.0.1:6443/api/v1/nodes")
except requests.Timeout:
    print("api server timeout")
except requests.HTTPError as e:
    print(f"api error: {e.response.status_code}")
# 不写 except: pass —— 它会把打错变量名的 NameError 也吞掉

# with：自动关资源，等价 shell 的 trap + close
with open("/etc/hosts") as f:        # 出块自动 close，异常也会关
    for line in f:
        if "cka" in line:
            print(line.strip())
```

### 1.3 字符串与格式化

```python
# [任意节点]
node, pct = "cka000001", 87.456
print(f"{node}: disk {pct:.1f}%")        # f-string，保留 1 位小数
print(f"{pct:>8.1f}")                    # 右对齐 8 列，做表格
print(f"{1024**2:,}")                    # 千分位：1,048,576
print("k8s\nnewline".splitlines())       # 换行切割，处理多行命令输出必备
print("  kube-apiserver  ".strip())      # 去首尾空白
print("2026-08-22T10:00:00Z"[:10])       # 切片取日期
```

---

## 2. 文件与路径处理：pathlib

`pathlib.Path` 比 shell 拼字符串和旧式 `os.path` 都安全，天生的路径类型不惧空格。

```python
# [任意节点] python3 交互式执行
from pathlib import Path

log_dir = Path("/var/log")
print(log_dir / "kubelet" / "kubelet.log")   # 用 / 拼路径，不再手写 os.path.join

p = Path("/var/log/pods/kube-system_coredns-abc123/etcd.log")
print(p.name)      # etcd.log
print(p.stem)      # etcd
print(p.suffix)    # .log
print(p.parent)    # .../kube-system_coredns-abc123
print(p.exists(), p.is_file())

for f in sorted(log_dir.glob("*.log")):      # glob 找文件
    print(f.name, f.stat().st_size)

# 读小文件 / 大文件
conf = Path("/etc/hosts").read_text()        # 一次性读入
with Path("/var/log/syslog").open() as f:    # 大文件逐行
    hits = [ln.strip() for ln in f if "oom" in ln.lower()]

# 写文件：原子写 = 先写临时再 rename，避免读到半个文件
target = Path("/tmp/report.txt")
tmp = target.with_suffix(".tmp")
tmp.write_text("generated\n")
tmp.replace(target)                          # rename 是原子的
```

```python
# [任意节点] 按大小轮转目录里的旧日志，保留每台最近 N 份（幂等）
import shutil
from pathlib import Path

def rotate(dirpath: str, pattern: str = "*.gz", keep: int = 5) -> list[str]:
    d = Path(dirpath)
    files = sorted(d.glob(pattern), key=lambda f: f.stat().st_mtime, reverse=True)
    removed = []
    for f in files[keep:]:
        f.unlink()
        removed.append(str(f))
    return removed

print(rotate("/var/log", "*.gz", keep=3))
```

目录级操作用 `shutil`：`shutil.copy2`（保留元数据）、`shutil.rmtree`（删目录树，删之前打印路径）、`shutil.disk_usage`（`total/used/free` 三元组，巡检必备）。

---

## 3. subprocess：安全地调命令

```python
# [任意节点]
import subprocess

# 基本形态：列表传参（不要拼字符串），capture 拿 stdout/stderr
r = subprocess.run(
    ["kubectl", "get", "nodes", "--no-headers"],
    capture_output=True, text=True, timeout=30,
)
print(r.returncode, r.stdout.count("\n"))

# 失败即抛异常，省去每个调用点都判 returncode
r = subprocess.run(
    ["kubectl", "get", "node", "not-exist"],
    capture_output=True, text=True, check=True,   # check=True: 非 0 抛 CalledProcessError
)

# 异常时把 stderr 带出来 —— 排查关键
try:
    r = subprocess.run(["kubectl", "get", "node", "not-exist"],
                       capture_output=True, text=True, check=True, timeout=30)
except subprocess.CalledProcessError as e:
    print("cmd failed:", e.returncode, e.stderr.strip())
except subprocess.TimeoutExpired:
    print("cmd timeout")

# 解析 kubectl 宽输出：按行按列切
def node_status() -> dict[str, str]:
    r = subprocess.run(["kubectl", "get", "nodes", "--no-headers"],
                       capture_output=True, text=True, check=True)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split(None, 2)      # name status rest
        out[parts[0]] = parts[1]
    return out

print(node_status())
```

三条铁律：参数用**列表**（杜绝注入与空格分词）；永远设 `timeout`（kubectl 卡死会把巡检脚本挂住）；`text=True` 让输出是 str 而不是 bytes。更结构化的数据直接让 kubectl 输出 JSON：

```python
# [任意节点]
import json
r = subprocess.run(["kubectl", "get", "pods", "-A", "-o", "json"],
                   capture_output=True, text=True, check=True)
for item in json.loads(r.stdout)["items"]:
    name = item["metadata"]["name"]
    ns = item["metadata"]["namespace"]
    phase = item["status"].get("phase")
    print(f"{ns}/{name}: {phase}")
```

---

## 4. requests：调 API

```python
# [任意节点] pip install requests 后执行（第 7 节的 venv 里装）
import requests

# 调 kube-apiserver 健康检查与 metrics 类端点
for endpoint in ("livez", "readyz", "healthz"):
    r = requests.get(f"https://127.0.0.1:6443/{endpoint}",
                     verify=False, timeout=5)
    print(endpoint, r.status_code, r.text[:40])

# 调一个公开 JSON API，走一遍完整请求-响应模型
r = requests.get("https://httpbin.org/get", params={"q": "sre"}, timeout=10)
print(r.status_code, r.headers["Content-Type"], r.json()["args"])

# POST JSON（第 4 章告警机器人的核心动作）
payload = {"text": "disk usage > 90%"}
r = requests.post("https://httpbin.org/post", json=payload, timeout=10)
print(r.json()["json"])
```

会话与重试（对 apiserver 高频采集时必须复用连接）：

```python
# [任意节点]
import requests
from requests.adapters import HTTPAdapter, Retry

s = requests.Session()
s.mount("https://", HTTPAdapter(max_retries=Retry(total=3, backoff_factor=0.5,
                                                  status_forcelist=[502, 503, 504])))
# 之后所有请求走 s.get / s.post
```

调 Kubernetes API 时，认证走 ServiceAccount 或 kubeconfig；`verify` 参数可指向 CA 证书文件，生产上不要用 `verify=False`（练习环境除外）。

---

## 5. paramiko：批量 ssh

paramiko 是 Python 的 ssh 协议库，ssh 循环的进阶形态：能拿到结构化结果、能 sftp 传文件、能和线程池组合并发。

```python
# [任意节点] venv 里 pip install paramiko 后执行
import paramiko

def run_remote(host: str, cmd: str, user: str = "ubuntu", key: str = "~/.ssh/id_rsa") -> tuple[int, str]:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())  # 练习环境；生产应加载 known_hosts
    try:
        client.connect(host, username=user, key_filename=key, timeout=5)
        _, stdout, stderr = client.exec_command(cmd, timeout=30)
        out = stdout.read().decode() + stderr.read().decode()
        return stdout.channel.recv_exit_status(), out
    finally:
        client.close()

rc, out = run_remote("cka000001", "hostname -f && uptime")
print(rc, out)

# 并发版：线程池 10 路
from concurrent.futures import ThreadPoolExecutor

hosts = ["cka000001", "cka000002", "cka000003"]
with ThreadPoolExecutor(max_workers=10) as ex:
    for host, (rc, out) in zip(hosts, ex.map(lambda h: run_remote(h, "df -h / | tail -1"), hosts)):
        print(f"{host} rc={rc}: {out.strip()}")
```

paramiko 每主机一个 TCP 连接、每次 `connect` 有握手开销，批量场景务必配线程池复用并发，而不是 for 循环串行 connect。若只是跑命令，第 2 章的 `xargs -P`/pdsh 更轻；需要"采集 → 解析 → 汇总"一条龙时才值得上 paramiko。

---

## 6. argparse：标准 CLI

```python
# [任意节点] 保存为 /usr/local/bin/k8s-top 后 chmod +x
#!/usr/bin/env python3
"""k8s-top: 列出重启次数最多 / 非 Running 的 Pod。"""
import argparse
import json
import subprocess
import sys


def get_pods() -> list[dict]:
    r = subprocess.run(["kubectl", "get", "pods", "-A", "-o", "json"],
                       capture_output=True, text=True, check=True)
    return json.loads(r.stdout)["items"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-n", "--top", type=int, default=10, help="显示条数 (默认 10)")
    ap.add_argument("--min-restarts", type=int, default=0, help="重启次数下限")
    ap.add_argument("--all", action="store_true", help="包含 Running 的 Pod")
    args = ap.parse_args()

    pods = []
    for it in get_pods():
        name = f'{it["metadata"]["namespace"]}/{it["metadata"]["name"]}'
        phase = it["status"].get("phase", "Unknown")
        restarts = sum(c.get("restartCount", 0) for c in it["status"].get("containerStatuses", []))
        if not args.all and phase == "Running" and restarts < args.min_restarts:
            continue
        pods.append((restarts, name, phase))

    pods.sort(reverse=True)
    for restarts, name, phase in pods[: args.top]:
        print(f"{restarts:>6}  {phase:<10} {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

argparse 要点：`type=int` 让参数自动转型（传错直接报错并打印 usage）；`action="store_true"` 做 flag；`--top` 的 `dest` 自动是 `args.top`；`description=__doc__` 复用模块 docstring 进 `--help`。返回值经 `sys.exit(main())` 传给 shell——工具的退出码是给 cron 和上层脚本看的，不是装饰。

---

## 7. venv 与依赖管理

系统 Python 不许 `pip install` 污染（Ubuntu 23.04+ 直接拒绝），每个工具一个 venv：

```bash
# [任意节点]
# 在家目录为运维工具建一个独立环境
python3 -m venv ~/venvs/ops
source ~/venvs/ops/bin/activate        # 激活后 python/pip 都指向 venv 内

pip install --upgrade pip
pip install requests paramiko prometheus_client pytest
pip freeze > requirements.txt          # 锁版本，换机器可复现
# 新机器恢复：
#   python3 -m venv ~/venvs/ops && source ~/venvs/ops/bin/activate
#   pip install -r requirements.txt

# 不进入 venv 也能用：
~/venvs/ops/bin/python mytool.py
deactivate                             # 退出 venv
```

requirements.txt 的纪律：只放直接依赖、`pip freeze` 生成后人工过目、提交进工具的 git 仓库。cron 里跑 venv 工具时写绝对路径解释器（`~/venvs/ops/bin/python`），不依赖激活状态。

---

## 实战演练

```bash
# [任意节点] 1. 建环境并验证依赖
python3 -m venv ~/venvs/ops && source ~/venvs/ops/bin/activate
pip install --quiet requests paramiko && python3 -c "import requests, paramiko; print('deps OK')"

# [任意节点] 2. pathlib + subprocess 小工具：找出 /var/log 下最大的 5 个文件
python3 - <<'EOF'
from pathlib import Path
files = [(f.stat().st_size, str(f)) for f in Path("/var/log").rglob("*") if f.is_file()]
for size, name in sorted(files, reverse=True)[:5]:
    print(f"{size/1024/1024:>8.1f} MB  {name}")
EOF

# [任意节点] 3. 调 apiserver 健康端点
python3 - <<'EOF'
import requests, urllib3
urllib3.disable_warnings()
for ep in ("livez", "readyz"):
    r = requests.get(f"https://127.0.0.1:6443/{ep}", verify=False, timeout=5)
    print(ep, r.status_code, r.text[:60])
EOF

# [任意节点] 4. k8s-top 工具
chmod +x /usr/local/bin/k8s-top && k8s-top --top 5
```

验证：步骤 1 打印 `deps OK`；步骤 2 输出按大小降序的 5 个文件；步骤 3 两个端点均返回 200 且 `ok`；步骤 4 输出重启次数倒序的 Pod 列表。

---

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `pip install` 报 externally-managed-environment | Ubuntu 23.04+/24.04 的 PEP 668 保护系统 Python | 用 venv：`python3 -m venv` + 激活后再 pip |
| subprocess 输出带 `b'...'` 前缀 | 缺 `text=True`，拿到 bytes | 加 `text=True` 或手动 `.decode()` |
| 命令带管道时不生效 | `["sh", "-c", "a | b"]` 才有管道，列表传参无 shell | 需要 shell 特性时显式 `shell=False` + `sh -c`，并理解注入风险 |
| requests 卡死直到 TCP 超时 | 未设 `timeout` | 一律 `timeout=5`；采集场景配 Session + Retry |
| `except: pass` 后脚本"没报错但也没结果" | 裸 except 吞了 NameError/KeyError 等真 bug | 只捕获具体异常类型，至少打日志 |
| 字典取 `pod["status"]["podIP"]` 抛 KeyError | Pod 未调度时字段不存在 | 用 `.get()` 链或先判 phase |
| cron 里跑 venv 脚本报 No module named | cron 不加载你的 activate | shebang 或 crontab 里写 venv 的绝对路径 python |
| paramiko 批量极慢 | 串行 connect，每台握手 | `ThreadPoolExecutor(max_workers=10)` 并发 |

---

## 自测

<details><summary>1. subprocess 为什么强制用列表传参而不是拼一个命令字符串？</summary>

列表参数直接经 execve 传给子进程，每个元素就是一个 argv，空格、分号、`$(...)` 都是普通字符，不存在再解析；拼字符串就得加 `shell=True`，让 `/bin/sh` 重新解析一遍，任何来自外部的输入（文件名、用户参数）都可能被解释为命令注入。列表形式还天然规避了 shell 分词问题。需要管道等 shell 特性时，用 `["sh", "-c", "..."]` 显式声明，且字符串里的变量部分自己控制来源。
</details>

<details><summary>2. `Path.read_text()` 和逐行 `open()` 何时选哪个？读一个 5GB 日志用前者会怎样？</summary>

`read_text()` 一次性把整个文件载入内存成单个 str，适合配置文件等小文件（简单、原子性好）；5GB 日志会瞬间吃掉约 5GB+ 内存，触发 OOM killer。大文件必须 `with open(...) as f:` 逐行迭代——Python 的文件迭代器有缓冲，内存占用恒定。判断标准：文件大小是否可控。同类决策在 shell 里对应 `cat` vs `while read`。
</details>

<details><summary>3. `except Exception` 和裸 `except:` 差在哪？为什么规范代码禁后者？</summary>

裸 `except:` 连 `KeyboardInterrupt`（Ctrl-C）、`SystemExit` 都会捕获，程序无法被正常中断退出，`sys.exit()` 都失效；它掩盖一切编程错误（拼错变量、类型错误），让故障表现为"沉默地跳过"。`except Exception` 只捕获常规异常，放行系统级退出信号。工程上再进一步：只捕你打算处理的具体异常，其余让它炸——栈回溯比吞掉更有价值。
</details>

<details><summary>4. venv 解决了什么问题？为什么 Ubuntu 24.04 直接禁止系统 pip install？</summary>

解决依赖冲突与系统污染：不同工具需要不同版本的同一个库，全局 site-packages 只能有一份；系统包管理器（apt）管理的 Python 组件和 pip 装的混在一起，升级互相破坏。PEP 668（externally-managed-environment）就是 apt 与 pip 双头管理的补丁——强制隔离，系统 Python 只归 apt，应用依赖归 venv/容器。运维含义：每个工具独立 venv + requirements.txt 锁版本，跨机器可复现。
</details>

<details><summary>5. `sys.exit(main())` 这个写法解决什么问题？返回 0/1/2 各代表什么惯例？</summary>

把函数的执行结果变成进程退出码，让 cron、CI、上层 shell 能基于 `$?` 做分支。惯例：0 成功；1 一般性失败（业务异常，如目标不存在）；2 用法错误（参数错、缺参数——argparse 报错默认就是 2）。区分它们的价值：监控里"脚本本身坏了"（语法/依赖问题）与"检查发现了异常"（该告警）是完全不同的事件，退出码就是两者的分界信号。
</details>

---

## 延伸阅读

- Python 官方教程（Subprocess / pathlib 章节）：https://docs.python.org/3/tutorial/
- subprocess 官方文档：https://docs.python.org/3/library/subprocess.html
- pathlib 官方文档：https://docs.python.org/3/library/pathlib.html
- requests 快速上手：https://requests.readthedocs.io/en/latest/user/quickstart/
- paramiko 官方文档：https://docs.paramiko.org/
