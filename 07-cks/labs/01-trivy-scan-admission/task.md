# Lab 01 · Trivy 镜像扫描与高危镜像阻断

> 难度：★★☆ ｜ 考点：CKS-微服务漏洞扫描（Trivy） ｜ 前置：无 ｜ 预计 30~40 分钟

## 场景

你是平台安全负责人。团队往 `cks-lab01` namespace 部署服务前，要求建立一道"镜像准入关"：

1. 任何镜像部署前必须用 Trivy 扫描；
2. 存在 `HIGH` 或 `CRITICAL` 级别漏洞的镜像**不允许**进入集群；
3. 扫描结论要留档（ blocked / allowed 清单），供审计追溯。

今天要上线的两个候选镜像：`nginx:1.16`（老版本）和 `nginx:alpine`（当前最新版，alpine 基底）。
安全团队已经预判 `nginx:1.16` 满是漏洞——你需要用工具证明它，并把它挡在门外。

> 注意：漏洞库每天都在更新，"干净镜像"是会过期的。本 lab 以 `nginx:alpine` 为放行样例（2026-08 实测 0 个 HIGH/CRITICAL）；若你运行时它也扫出漏洞，换一个当前干净的镜像即可，闸门机制不变。

## 任务清单

1. 在 master 上安装 Trivy（apt 仓库或官方 install 脚本二选一），确认 `trivy --version` 可用。
2. 扫描 `nginx:1.16`，只输出 `HIGH,CRITICAL` 级别：确认漏洞数 > 0。
3. 编写准入闸门脚本 `/usr/local/bin/image-gate.sh`：参数为镜像名，发现 HIGH/CRITICAL 漏洞时退出码非 0（提示：`trivy image --exit-code 1`），并赋予可执行权限。
4. 用闸门脚本分别测试 `nginx:1.16` 与 `nginx:alpine`，确认前者被拒、后者放行。
5. 创建 namespace `cks-lab01`；把扫描结论写入 ConfigMap `image-gate-report`（data 键：`blocked`、`allowed`、`tool=trivy`）。
6. 只有通过闸门的镜像才允许部署：在 `cks-lab01` 里运行名为 `web` 的 Pod（镜像 `nginx:alpine`），要求 Running。

## 验收标准

- `trivy image -s HIGH,CRITICAL nginx:1.16` 输出漏洞总数 > 0
- `/usr/local/bin/image-gate.sh nginx:1.16` 非零退出，`image-gate.sh nginx:alpine` 退出码 0
- `kubectl -n cks-lab01 get configmap image-gate-report -o yaml` 能看到三条 data 记录
- `kubectl -n cks-lab01 get pod web` 为 Running，镜像 `nginx:alpine`；集群中没有 `nginx:1.16` 的 Pod 被创建

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/01-trivy-scan-admission
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：Trivy 怎么装</summary>

Ubuntu 22.04/24.04 直接用 apt：

```bash
# [master]
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO- https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
```
</details>

<details><summary>提示 2：让 trivy 在发现漏洞时返回非零</summary>

`trivy image --severity HIGH,CRITICAL --exit-code 1 <image>`：有匹配漏洞时进程退出码为 1，没有则为 0。再配合 `--quiet` 压掉进度日志，脚本里就能用 `if trivy ...` 直接判断。
</details>

<details><summary>提示 3：闸门怎么和 kubectl 结合</summary>

模式是 `if image-gate.sh nginx:alpine; then kubectl -n cks-lab01 run web --image=nginx:alpine; fi`——被拒的镜像根本不会到达 apiserver，这就是最朴素的"准入控制"。生产上等价物是 OPA Gatekeeper / Kyverno，见模块 04 章节内容。
</details>
