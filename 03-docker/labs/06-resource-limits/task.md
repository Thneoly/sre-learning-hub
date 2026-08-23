# Lab 06 · CPU/内存限制与 throttling 观察

> 难度：★★☆ ｜ 考点：CKA-资源管理（requests/limits 的底层机制） ｜ 前置：lab 01 ｜ 预计 30~40 分钟

## 场景

一台 VM 上跑了十几个容器，某个 CPU 密集型任务把其他服务全拖卡了。你要用 `--cpus` / `--memory` 给它上枷锁，并且不能只会"设置完就跑"——你要能指着 cgroup 文件里的 `nr_throttled` 数字告诉同事："看，它每秒都在被内核掐断"。这套 cgroup v2 的 cpu.max / memory.max 正是 Kubernetes `resources.limits` 的底层实现，CKA/CKS 排查资源问题时最终都会落到这几个文件。

## 任务清单

1. 启动受限容器 `lab06-cpu`：`--cpus 0.5 --memory 128m`，镜像是 alpine，负载为死循环 `while true; do :; done`。
2. 启动对照组 `lab06-free`：同样的死循环，不加任何限制。
3. `docker stats --no-stream` 对比两者 CPU%（受限约 50%，对照接近 100% 单核）。
4. 在 `lab06-cpu` 容器内读 cgroup v2 文件：`/sys/fs/cgroup/cpu.max` 应为 `50000 100000`；`/sys/fs/cgroup/memory.max` 应为 `134217728`。
5. 读 `/sys/fs/cgroup/cpu.stat`，记录 `nr_periods` 与 `nr_throttled`，等 30 秒后再读一次，验证 `nr_throttled` 持续增长（正在被限流）。
6. 用 `docker inspect` 确认 daemon 侧的等价参数：`HostConfig.NanoCpus = 500000000`、`HostConfig.Memory = 134217728`。
7. （选做）内存压测：`docker run --rm -m 64m alpine dd if=/dev/zero of=/dev/shm/big bs=1M count=200` 撞上 `memory.max`，观察 OOMKill（`Exited (137)`、`OOMKilled=true`）。

## 验收标准

- `lab06-cpu` 运行中，`NanoCpus=500000000`、`Memory=134217728`，容器内 `cpu.max` 为 `50000 100000`；
- `lab06-cpu` 的 `cpu.stat` 中 `nr_throttled > 0` 且随时间增长；
- `lab06-free` 运行中且 `NanoCpus=0`（无 CPU 限制）。

完成后运行判分脚本：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：--cpus 0.5 对应 cgroup 里的什么？</summary>

`--cpus` 是 `--cpu-period`/`--cpu-quota` 的封装：period 固定 100000us，quota = 0.5 x 100000 = 50000us。cgroup v2 文件 `cpu.max` 内容即 `50000 100000`。含义：每 100ms 周期内该 cgroup 最多用 50ms CPU 时间，超了就冻结到下一周期（throttle）。
</details>

<details><summary>提示 2：哪里读 nr_throttled？</summary>

cgroup v2 下（Ubuntu 22.04/24.04 默认），容器内有独立 cgroup namespace，直接 `docker exec lab06-cpu cat /sys/fs/cgroup/cpu.stat` 就是本容器的统计；宿主机上也可以从 `/sys/fs/cgroup/system.slice/docker-<full-id>.scope/cpu.stat` 读。
</details>

<details><summary>提示 3：--cpus 和 --cpuset-cpus 有什么区别？</summary>

`--cpus` 是**时间配额**（可跨核借用，总量受限）；`--cpuset-cpus` 是**核亲和**（钉在指定 CPU 上跑，不限时长）。K8s 的 `cpus` limit 走配额语义，Guaranteed QoS 的 `cpu: 2` 对应 quota=200000。
</details>
